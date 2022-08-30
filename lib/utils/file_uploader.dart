import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity/connectivity.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sodium/flutter_sodium.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/errors.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/core/network.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/upload_locks_db.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/events/subscription_purchased_event.dart';
import 'package:photos/main.dart';
import 'package:photos/models/encryption_result.dart';
import 'package:photos/models/file.dart';
import 'package:photos/models/file_type.dart';
import 'package:photos/models/upload_url.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/local_sync_service.dart';
import 'package:photos/services/sync_service.dart';
import 'package:photos/utils/crypto_util.dart';
import 'package:photos/utils/file_download_util.dart';
import 'package:photos/utils/file_uploader_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FileUploader {
  static const kMaximumConcurrentUploads = 4;
  static const kMaximumConcurrentVideoUploads = 2;
  static const kMaximumThumbnailCompressionAttempts = 2;
  static const kMaximumUploadAttempts = 4;
  static const kBlockedUploadsPollFrequency = Duration(seconds: 2);
  static const kFileUploadTimeout = Duration(minutes: 50);

  final _logger = Logger("FileUploader");
  final _dio = Network.instance.getDio();
  final LinkedHashMap _queue = LinkedHashMap<String, FileUploadItem>();
  final _uploadLocks = UploadLocksDB.instance;
  final kSafeBufferForLockExpiry = const Duration(days: 1).inMicroseconds;
  final kBGTaskDeathTimeout = const Duration(seconds: 5).inMicroseconds;
  final _uploadURLs = Queue<UploadURL>();

  // Maintains the count of files in the current upload session.
  // Upload session is the period between the first entry into the _queue and last entry out of the _queue
  int _totalCountInUploadSession = 0;
  // _uploadCounter indicates number of uploads which are currently in progress
  int _uploadCounter = 0;
  int _videoUploadCounter = 0;
  ProcessType _processType;
  bool _isBackground;
  SharedPreferences _prefs;

  FileUploader._privateConstructor() {
    Bus.instance.on<SubscriptionPurchasedEvent>().listen((event) {
      _uploadURLFetchInProgress = null;
    });
  }
  static FileUploader instance = FileUploader._privateConstructor();

  Future<void> init(bool isBackground) async {
    _prefs = await SharedPreferences.getInstance();
    _isBackground = isBackground;
    _processType =
        isBackground ? ProcessType.background : ProcessType.foreground;
    final currentTime = DateTime.now().microsecondsSinceEpoch;
    await _uploadLocks.releaseLocksAcquiredByOwnerBefore(
      _processType.toString(),
      currentTime,
    );
    await _uploadLocks
        .releaseAllLocksAcquiredBefore(currentTime - kSafeBufferForLockExpiry);
    if (!isBackground) {
      await _prefs.reload();
      final isBGTaskDead = (_prefs.getInt(kLastBGTaskHeartBeatTime) ?? 0) <
          (currentTime - kBGTaskDeathTimeout);
      if (isBGTaskDead) {
        await _uploadLocks.releaseLocksAcquiredByOwnerBefore(
          ProcessType.background.toString(),
          currentTime,
        );
        _logger.info("BG task was found dead, cleared all locks");
      }
      _pollBackgroundUploadStatus();
    }
    Bus.instance.on<LocalPhotosUpdatedEvent>().listen((event) {
      if (event.type == EventType.deletedFromDevice ||
          event.type == EventType.deletedFromEverywhere) {
        removeFromQueueWhere(
          (file) {
            for (final updatedFile in event.updatedFiles) {
              if (file.generatedID == updatedFile.generatedID) {
                return true;
              }
            }
            return false;
          },
          InvalidFileError("File already deleted"),
        );
      }
    });
  }

  Future<File> upload(File file, int collectionID) {
    // If the file hasn't been queued yet, queue it
    _totalCountInUploadSession++;
    if (!_queue.containsKey(file.localID)) {
      final completer = Completer<File>();
      _queue[file.localID] = FileUploadItem(file, collectionID, completer);
      _pollQueue();
      return completer.future;
    }

    // If the file exists in the queue for a matching collectionID,
    // return the existing future
    final item = _queue[file.localID];
    if (item.collectionID == collectionID) {
      _totalCountInUploadSession--;
      return item.completer.future;
    }

    // Else wait for the existing upload to complete,
    // and add it to the relevant collection
    return item.completer.future.then((uploadedFile) {
      return CollectionsService.instance
          .addToCollection(collectionID, [uploadedFile]).then((aVoid) {
        return uploadedFile;
      });
    });
  }

  int getCurrentSessionUploadCount() {
    return _totalCountInUploadSession;
  }

  void clearQueue(final Error reason) {
    final List<String> uploadsToBeRemoved = [];
    _queue.entries
        .where((entry) => entry.value.status == UploadStatus.notStarted)
        .forEach((pendingUpload) {
      uploadsToBeRemoved.add(pendingUpload.key);
    });
    for (final id in uploadsToBeRemoved) {
      _queue.remove(id).completer.completeError(reason);
    }
    _totalCountInUploadSession = 0;
  }

  void removeFromQueueWhere(final bool Function(File) fn, final Error reason) {
    final List<String> uploadsToBeRemoved = [];
    _queue.entries
        .where((entry) => entry.value.status == UploadStatus.notStarted)
        .forEach((pendingUpload) {
      if (fn(pendingUpload.value.file)) {
        uploadsToBeRemoved.add(pendingUpload.key);
      }
    });
    for (final id in uploadsToBeRemoved) {
      _queue.remove(id).completer.completeError(reason);
    }
    _totalCountInUploadSession -= uploadsToBeRemoved.length;
  }

  void _pollQueue() {
    if (SyncService.instance.shouldStopSync()) {
      clearQueue(SyncStopRequestedError());
    }
    if (_queue.isEmpty) {
      // Upload session completed
      _totalCountInUploadSession = 0;
      return;
    }
    if (_uploadCounter < kMaximumConcurrentUploads) {
      var pendingEntry = _queue.entries
          .firstWhere(
            (entry) => entry.value.status == UploadStatus.notStarted,
            orElse: () => null,
          )
          ?.value;

      if (pendingEntry != null &&
          pendingEntry.file.fileType == FileType.video &&
          _videoUploadCounter >= kMaximumConcurrentVideoUploads) {
        // check if there's any non-video entry which can be queued for upload
        pendingEntry = _queue.entries
            .firstWhere(
              (entry) =>
                  entry.value.status == UploadStatus.notStarted &&
                  entry.value.file.fileType != FileType.video,
              orElse: () => null,
            )
            ?.value;
      }
      if (pendingEntry != null) {
        pendingEntry.status = UploadStatus.inProgress;
        _encryptAndUploadFileToCollection(
          pendingEntry.file,
          pendingEntry.collectionID,
        );
      }
    }
  }

  Future<File> _encryptAndUploadFileToCollection(
    File file,
    int collectionID, {
    bool forcedUpload = false,
  }) async {
    _uploadCounter++;
    if (file.fileType == FileType.video) {
      _videoUploadCounter++;
    }
    final localID = file.localID;
    try {
      final uploadedFile =
          await _tryToUpload(file, collectionID, forcedUpload).timeout(
        kFileUploadTimeout,
        onTimeout: () {
          final message = "Upload timed out for file " + file.toString();
          _logger.severe(message);
          throw TimeoutException(message);
        },
      );
      _queue.remove(localID).completer.complete(uploadedFile);
      return uploadedFile;
    } catch (e) {
      if (e is LockAlreadyAcquiredError) {
        _queue[localID].status = UploadStatus.inBackground;
        return _queue[localID].completer.future;
      } else {
        _queue.remove(localID).completer.completeError(e);
        return null;
      }
    } finally {
      _uploadCounter--;
      if (file.fileType == FileType.video) {
        _videoUploadCounter--;
      }
      _pollQueue();
    }
  }

  Future<File> _tryToUpload(
    File file,
    int collectionID,
    bool forcedUpload,
  ) async {
    final connectivityResult = await (Connectivity().checkConnectivity());
    final canUploadUnderCurrentNetworkConditions =
        (connectivityResult == ConnectivityResult.wifi ||
            Configuration.instance.shouldBackupOverMobileData());
    if (!canUploadUnderCurrentNetworkConditions && !forcedUpload) {
      throw WiFiUnavailableError();
    }
    final fileOnDisk = await FilesDB.instance.getFile(file.generatedID);
    final wasAlreadyUploaded = fileOnDisk.uploadedFileID != null &&
        fileOnDisk.updationTime != -1 &&
        fileOnDisk.collectionID == collectionID;
    if (wasAlreadyUploaded) {
      debugPrint("File is already uploaded ${fileOnDisk.tag()}");
      return fileOnDisk;
    }

    try {
      await _uploadLocks.acquireLock(
        file.localID,
        _processType.toString(),
        DateTime.now().microsecondsSinceEpoch,
      );
    } catch (e) {
      _logger.warning("Lock was already taken for " + file.toString());
      throw LockAlreadyAcquiredError();
    }

    final tempDirectory = Configuration.instance.getTempDirectory();
    final encryptedFilePath = tempDirectory +
        file.generatedID.toString() +
        (_isBackground ? "_bg" : "") +
        ".encrypted";
    final encryptedThumbnailPath = tempDirectory +
        file.generatedID.toString() +
        "_thumbnail" +
        (_isBackground ? "_bg" : "") +
        ".encrypted";
    MediaUploadData mediaUploadData;
    var uploadCompleted = false;

    try {
      _logger.info(
        "Trying to upload " +
            file.toString() +
            ", isForced: " +
            forcedUpload.toString(),
      );
      try {
        mediaUploadData = await getUploadDataFromEnteFile(file);
      } catch (e) {
        if (e is InvalidFileError) {
          await _onInvalidFileError(file, e);
        } else {
          rethrow;
        }
      }

      Uint8List key;
      final bool isUpdatedFile =
          file.uploadedFileID != null && file.updationTime == -1;
      if (isUpdatedFile) {
        _logger.info("File was updated " + file.toString());
        key = decryptFileKey(file);
      } else {
        key = null;
        // check if the file is already uploaded and can be mapping to existing
        // stuff
        final isMappedToExistingUpload = await _mapToExistingUploadWithSameHash(
          mediaUploadData,
          file,
          collectionID,
        );
        if (isMappedToExistingUpload) {
          debugPrint(
            "File success mapped to existing uploaded ${file.toString()}",
          );
          return file;
        }
      }

      if (io.File(encryptedFilePath).existsSync()) {
        await io.File(encryptedFilePath).delete();
      }
      final encryptedFile = io.File(encryptedFilePath);
      final fileAttributes = await CryptoUtil.encryptFile(
        mediaUploadData.sourceFile.path,
        encryptedFilePath,
        key: key,
      );
      final thumbnailData = mediaUploadData.thumbnail;

      final encryptedThumbnailData =
          await CryptoUtil.encryptChaCha(thumbnailData, fileAttributes.key);
      if (io.File(encryptedThumbnailPath).existsSync()) {
        await io.File(encryptedThumbnailPath).delete();
      }
      final encryptedThumbnailFile = io.File(encryptedThumbnailPath);
      await encryptedThumbnailFile
          .writeAsBytes(encryptedThumbnailData.encryptedData);

      final thumbnailUploadURL = await _getUploadURL();
      final String thumbnailObjectKey =
          await _putFile(thumbnailUploadURL, encryptedThumbnailFile);

      final fileUploadURL = await _getUploadURL();
      final String fileObjectKey = await _putFile(fileUploadURL, encryptedFile);

      final metadata = await file.getMetadataForUpload(mediaUploadData);
      final encryptedMetadataData = await CryptoUtil.encryptChaCha(
        utf8.encode(jsonEncode(metadata)),
        fileAttributes.key,
      );
      final fileDecryptionHeader = Sodium.bin2base64(fileAttributes.header);
      final thumbnailDecryptionHeader =
          Sodium.bin2base64(encryptedThumbnailData.header);
      final encryptedMetadata =
          Sodium.bin2base64(encryptedMetadataData.encryptedData);
      final metadataDecryptionHeader =
          Sodium.bin2base64(encryptedMetadataData.header);
      if (SyncService.instance.shouldStopSync()) {
        throw SyncStopRequestedError();
      }
      File remoteFile;
      if (isUpdatedFile) {
        remoteFile = await _updateFile(
          file,
          fileObjectKey,
          fileDecryptionHeader,
          await encryptedFile.length(),
          thumbnailObjectKey,
          thumbnailDecryptionHeader,
          await encryptedThumbnailFile.length(),
          encryptedMetadata,
          metadataDecryptionHeader,
        );
        // Update across all collections
        await FilesDB.instance.updateUploadedFileAcrossCollections(remoteFile);
      } else {
        final encryptedFileKeyData = CryptoUtil.encryptSync(
          fileAttributes.key,
          CollectionsService.instance.getCollectionKey(collectionID),
        );
        final encryptedKey =
            Sodium.bin2base64(encryptedFileKeyData.encryptedData);
        final keyDecryptionNonce =
            Sodium.bin2base64(encryptedFileKeyData.nonce);
        remoteFile = await _uploadFile(
          file,
          collectionID,
          encryptedKey,
          keyDecryptionNonce,
          fileAttributes,
          fileObjectKey,
          fileDecryptionHeader,
          await encryptedFile.length(),
          thumbnailObjectKey,
          thumbnailDecryptionHeader,
          await encryptedThumbnailFile.length(),
          encryptedMetadata,
          metadataDecryptionHeader,
        );
        if (mediaUploadData.isDeleted) {
          _logger.info("File found to be deleted");
          remoteFile.localID = null;
        }
        await FilesDB.instance.update(remoteFile);
      }
      if (!_isBackground) {
        Bus.instance.fire(LocalPhotosUpdatedEvent([remoteFile]));
      }
      _logger.info("File upload complete for " + remoteFile.toString());
      uploadCompleted = true;
      return remoteFile;
    } catch (e, s) {
      if (!(e is NoActiveSubscriptionError ||
          e is StorageLimitExceededError ||
          e is WiFiUnavailableError ||
          e is SilentlyCancelUploadsError ||
          e is FileTooLargeForPlanError)) {
        _logger.severe("File upload failed for " + file.toString(), e, s);
      }
      rethrow;
    } finally {
      await _onUploadDone(
        mediaUploadData,
        uploadCompleted,
        file,
        encryptedFilePath,
        encryptedThumbnailPath,
      );
    }
  }

  /*
  // _mapToExistingUpload links the current file to be uploaded with the
  // existing files. If the link is successful, it returns true other false.
   When false, we should go ahead and re-upload or update the file
    It performs following checks:
    a) Uploaded file with same localID and destination collection. Delete the
     fileToUpload entry
    b) Uploaded file in destination collection but with missing localID.
     Update the localID for uploadedFile and delete the fileToUpload entry
    c) A uploaded file exist with same localID but in a different collection.
    or
    d) Uploaded file in different collection but missing localID.
    For both c and d, perform add to collection operation.
    e) File already exists but different localID. Re-upload
    In case the existing files already have local identifier, which is
    different from the {fileToUpload}, then most probably device has
    duplicate files.
  */
  Future<bool> _mapToExistingUploadWithSameHash(
    MediaUploadData mediaUploadData,
    File fileToUpload,
    int toCollectionID,
  ) async {
    if (fileToUpload.uploadedFileID != -1 &&
        fileToUpload.uploadedFileID != null) {
      _logger.warning('file is already uploaded, skipping mapping logic');
      return false;
    }
    final List<String> hash = [mediaUploadData.fileHash];
    if (fileToUpload.fileType == FileType.livePhoto) {
      hash.add(mediaUploadData.zipHash);
    }
    final List<File> existingFiles =
        await FilesDB.instance.getUploadedFilesWithHashes(
      hash,
      fileToUpload.fileType,
      Configuration.instance.getUserID(),
    );
    if (existingFiles?.isEmpty ?? true) {
      return false;
    } else {
      debugPrint("Found some matches");
    }
    // case a
    final File sameLocalSameCollection = existingFiles.firstWhere(
      (element) =>
          element.uploadedFileID != -1 &&
          element.collectionID == toCollectionID &&
          element.localID == fileToUpload.localID,
      orElse: () => null,
    );
    if (sameLocalSameCollection != null) {
      debugPrint(
        "sameLocalSameCollection: \n toUpload  ${fileToUpload.tag()} "
        "\n existing: ${sameLocalSameCollection.tag()}",
      );
      // should delete the fileToUploadEntry
      FilesDB.instance.deleteByGeneratedID(fileToUpload.generatedID);
      return true;
    }

    // case b
    final File fileMissingLocalButSameCollection = existingFiles.firstWhere(
      (element) =>
          element.uploadedFileID != -1 &&
          element.collectionID == toCollectionID &&
          element.localID == null,
      orElse: () => null,
    );
    if (fileMissingLocalButSameCollection != null) {
      // update the local id of the existing file and delete the fileToUpload
      // entry
      debugPrint(
        "fileMissingLocalButSameCollection: \n toUpload  ${fileToUpload.tag()} "
        "\n existing: ${fileMissingLocalButSameCollection.tag()}",
      );
      fileMissingLocalButSameCollection.localID = fileToUpload.localID;
      await FilesDB.instance.insert(fileMissingLocalButSameCollection);
      await FilesDB.instance.deleteByGeneratedID(fileToUpload.generatedID);
      return true;
    }

    // case c and d
    final File fileExistsButDifferentCollection = existingFiles.firstWhere(
      (element) =>
          element.uploadedFileID != -1 &&
          element.collectionID != toCollectionID,
      orElse: () => null,
    );
    if (fileExistsButDifferentCollection != null) {
      debugPrint(
        "fileExistsButDifferentCollection: \n toUpload  ${fileToUpload.tag()} "
        "\n existing: ${fileExistsButDifferentCollection.tag()}",
      );
      await CollectionsService.instance
          .linkLocalFileToExistingUploadedFileInAnotherCollection(
              toCollectionID, fileToUpload, fileExistsButDifferentCollection);
      return true;
    }
    // case e
    return false;
  }

  Future<void> _onUploadDone(
    MediaUploadData mediaUploadData,
    bool uploadCompleted,
    File file,
    String encryptedFilePath,
    String encryptedThumbnailPath,
  ) async {
    if (mediaUploadData != null && mediaUploadData.sourceFile != null) {
      // delete the file from app's internal cache if it was copied to app
      // for upload. Shared Media should only be cleared when the upload
      // succeeds.
      if (io.Platform.isIOS ||
          (uploadCompleted && file.isSharedMediaToAppSandbox())) {
        await mediaUploadData.sourceFile.delete();
      }
    }
    if (io.File(encryptedFilePath).existsSync()) {
      await io.File(encryptedFilePath).delete();
    }
    if (io.File(encryptedThumbnailPath).existsSync()) {
      await io.File(encryptedThumbnailPath).delete();
    }
    await _uploadLocks.releaseLock(file.localID, _processType.toString());
  }

  Future _onInvalidFileError(File file, InvalidFileError e) async {
    final String ext = file.title == null ? "no title" : extension(file.title);
    _logger.severe(
      "Invalid file: (ext: $ext) encountered: " + file.toString(),
      e,
    );
    await FilesDB.instance.deleteLocalFile(file);
    await LocalSyncService.instance.trackInvalidFile(file);
    throw e;
  }

  Future<File> _uploadFile(
    File file,
    int collectionID,
    String encryptedKey,
    String keyDecryptionNonce,
    EncryptionResult fileAttributes,
    String fileObjectKey,
    String fileDecryptionHeader,
    int fileSize,
    String thumbnailObjectKey,
    String thumbnailDecryptionHeader,
    int thumbnailSize,
    String encryptedMetadata,
    String metadataDecryptionHeader, {
    int attempt = 1,
  }) async {
    final request = {
      "collectionID": collectionID,
      "encryptedKey": encryptedKey,
      "keyDecryptionNonce": keyDecryptionNonce,
      "file": {
        "objectKey": fileObjectKey,
        "decryptionHeader": fileDecryptionHeader,
        "size": fileSize,
      },
      "thumbnail": {
        "objectKey": thumbnailObjectKey,
        "decryptionHeader": thumbnailDecryptionHeader,
        "size": thumbnailSize,
      },
      "metadata": {
        "encryptedData": encryptedMetadata,
        "decryptionHeader": metadataDecryptionHeader,
      }
    };
    try {
      final response = await _dio.post(
        Configuration.instance.getHttpEndpoint() + "/files",
        options: Options(
          headers: {"X-Auth-Token": Configuration.instance.getToken()},
        ),
        data: request,
      );
      final data = response.data;
      file.uploadedFileID = data["id"];
      file.collectionID = collectionID;
      file.updationTime = data["updationTime"];
      file.ownerID = data["ownerID"];
      file.encryptedKey = encryptedKey;
      file.keyDecryptionNonce = keyDecryptionNonce;
      file.fileDecryptionHeader = fileDecryptionHeader;
      file.thumbnailDecryptionHeader = thumbnailDecryptionHeader;
      file.metadataDecryptionHeader = metadataDecryptionHeader;
      return file;
    } on DioError catch (e) {
      if (e.response?.statusCode == 413) {
        throw FileTooLargeForPlanError();
      } else if (e.response?.statusCode == 426) {
        _onStorageLimitExceeded();
      } else if (attempt < kMaximumUploadAttempts) {
        _logger.info("Upload file failed, will retry in 3 seconds");
        await Future.delayed(const Duration(seconds: 3));
        return _uploadFile(
          file,
          collectionID,
          encryptedKey,
          keyDecryptionNonce,
          fileAttributes,
          fileObjectKey,
          fileDecryptionHeader,
          fileSize,
          thumbnailObjectKey,
          thumbnailDecryptionHeader,
          thumbnailSize,
          encryptedMetadata,
          metadataDecryptionHeader,
          attempt: attempt + 1,
        );
      }
      rethrow;
    }
  }

  Future<File> _updateFile(
    File file,
    String fileObjectKey,
    String fileDecryptionHeader,
    int fileSize,
    String thumbnailObjectKey,
    String thumbnailDecryptionHeader,
    int thumbnailSize,
    String encryptedMetadata,
    String metadataDecryptionHeader, {
    int attempt = 1,
  }) async {
    final request = {
      "id": file.uploadedFileID,
      "file": {
        "objectKey": fileObjectKey,
        "decryptionHeader": fileDecryptionHeader,
        "size": fileSize,
      },
      "thumbnail": {
        "objectKey": thumbnailObjectKey,
        "decryptionHeader": thumbnailDecryptionHeader,
        "size": thumbnailSize,
      },
      "metadata": {
        "encryptedData": encryptedMetadata,
        "decryptionHeader": metadataDecryptionHeader,
      }
    };
    try {
      final response = await _dio.put(
        Configuration.instance.getHttpEndpoint() + "/files/update",
        options: Options(
          headers: {"X-Auth-Token": Configuration.instance.getToken()},
        ),
        data: request,
      );
      final data = response.data;
      file.uploadedFileID = data["id"];
      file.updationTime = data["updationTime"];
      file.fileDecryptionHeader = fileDecryptionHeader;
      file.thumbnailDecryptionHeader = thumbnailDecryptionHeader;
      file.metadataDecryptionHeader = metadataDecryptionHeader;
      return file;
    } on DioError catch (e) {
      if (e.response?.statusCode == 426) {
        _onStorageLimitExceeded();
      } else if (attempt < kMaximumUploadAttempts) {
        _logger.info("Update file failed, will retry in 3 seconds");
        await Future.delayed(const Duration(seconds: 3));
        return _updateFile(
          file,
          fileObjectKey,
          fileDecryptionHeader,
          fileSize,
          thumbnailObjectKey,
          thumbnailDecryptionHeader,
          thumbnailSize,
          encryptedMetadata,
          metadataDecryptionHeader,
          attempt: attempt + 1,
        );
      }
      rethrow;
    }
  }

  Future<UploadURL> _getUploadURL() async {
    if (_uploadURLs.isEmpty) {
      await fetchUploadURLs(_queue.length);
    }
    try {
      return _uploadURLs.removeFirst();
    } catch (e) {
      if (e is StateError && e.message == 'No element' && _queue.isNotEmpty) {
        _logger.warning("Oops, uploadUrls has no element now, fetching again");
        return _getUploadURL();
      } else {
        rethrow;
      }
    }
  }

  Future<void> _uploadURLFetchInProgress;

  Future<void> fetchUploadURLs(int fileCount) async {
    _uploadURLFetchInProgress ??= Future<void>(() async {
      try {
        final response = await _dio.get(
          Configuration.instance.getHttpEndpoint() + "/files/upload-urls",
          queryParameters: {
            "count": min(42, fileCount * 2), // m4gic number
          },
          options: Options(
            headers: {"X-Auth-Token": Configuration.instance.getToken()},
          ),
        );
        final urls = (response.data["urls"] as List)
            .map((e) => UploadURL.fromMap(e))
            .toList();
        _uploadURLs.addAll(urls);
      } on DioError catch (e, s) {
        if (e.response != null) {
          if (e.response.statusCode == 402) {
            final error = NoActiveSubscriptionError();
            clearQueue(error);
            throw error;
          } else if (e.response.statusCode == 426) {
            final error = StorageLimitExceededError();
            clearQueue(error);
            throw error;
          } else {
            _logger.severe("Could not fetch upload URLs", e, s);
          }
        }
        rethrow;
      } finally {
        _uploadURLFetchInProgress = null;
      }
    });
    return _uploadURLFetchInProgress;
  }

  void _onStorageLimitExceeded() {
    clearQueue(StorageLimitExceededError());
    throw StorageLimitExceededError();
  }

  Future<String> _putFile(
    UploadURL uploadURL,
    io.File file, {
    int contentLength,
    int attempt = 1,
  }) async {
    final fileSize = contentLength ?? await file.length();
    _logger.info(
      "Putting object for " +
          file.toString() +
          " of size: " +
          fileSize.toString(),
    );
    final startTime = DateTime.now().millisecondsSinceEpoch;
    try {
      await _dio.put(
        uploadURL.url,
        data: file.openRead(),
        options: Options(
          headers: {
            Headers.contentLengthHeader: fileSize,
          },
        ),
      );
      _logger.info(
        "Upload speed : " +
            (fileSize / (DateTime.now().millisecondsSinceEpoch - startTime))
                .toString() +
            " kilo bytes per second",
      );

      return uploadURL.objectKey;
    } on DioError catch (e) {
      if (e.message.startsWith(
            "HttpException: Content size exceeds specified contentLength.",
          ) &&
          attempt == 1) {
        return _putFile(
          uploadURL,
          file,
          contentLength: (await file.readAsBytes()).length,
          attempt: 2,
        );
      } else if (attempt < kMaximumUploadAttempts) {
        final newUploadURL = await _getUploadURL();
        return _putFile(
          newUploadURL,
          file,
          contentLength: (await file.readAsBytes()).length,
          attempt: attempt + 1,
        );
      } else {
        _logger.info(
          "Upload failed for file with size " + fileSize.toString(),
          e,
        );
        rethrow;
      }
    }
  }

  Future<void> _pollBackgroundUploadStatus() async {
    final blockedUploads = _queue.entries
        .where((e) => e.value.status == UploadStatus.inBackground)
        .toList();
    for (final upload in blockedUploads) {
      final file = upload.value.file;
      final isStillLocked = await _uploadLocks.isLocked(
        file.localID,
        ProcessType.background.toString(),
      );
      if (!isStillLocked) {
        final completer = _queue.remove(upload.key).completer;
        final dbFile =
            await FilesDB.instance.getFile(upload.value.file.generatedID);
        if (dbFile.uploadedFileID != null) {
          _logger.info("Background upload success detected");
          completer.complete(dbFile);
        } else {
          _logger.info("Background upload failure detected");
          completer.completeError(SilentlyCancelUploadsError());
        }
      }
    }
    Future.delayed(kBlockedUploadsPollFrequency, () async {
      await _pollBackgroundUploadStatus();
    });
  }
}

class FileUploadItem {
  final File file;
  final int collectionID;
  final Completer<File> completer;
  UploadStatus status;

  FileUploadItem(
    this.file,
    this.collectionID,
    this.completer, {
    this.status = UploadStatus.notStarted,
  });
}

enum UploadStatus {
  notStarted,
  inProgress,
  inBackground,
  completed,
}

enum ProcessType {
  background,
  foreground,
}
