// lib/services/file_monitor_service.dart

import 'dart:async';
import 'dart:io';
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

class FileMonitorService {
  final WebRTCManager? rtcManager;
  final String boardId;
  final String? Function(String filePath) getFileIdCallback;

  final Function(String path)? onFileAdded;
  final Function(String oldPath, String newPath)? onFileRenamed;
  final Function(String path)? onFileDeleted;

  final Function(String path)? onFolderAdded;
  final Function(String oldPath, String newPath)? onFolderRenamed;
  final Function(String path)? onFolderDeleted;

  StreamSubscription<FileSystemEvent>? _watcherSubscription;
  final Set<String> _ignoredFiles = {};
  final Map<String, Timer> _debounceTimers = {};

  FileMonitorService({
    this.rtcManager,
    required this.boardId,
    required this.getFileIdCallback,
    this.onFileAdded,
    this.onFileRenamed,
    this.onFileDeleted,
    this.onFolderAdded,
    this.onFolderRenamed,
    this.onFolderDeleted,
  });

  Future<void> startMonitoring() async {
    try {
      final filesDirPath = await BoardStorage.getBoardFilesDirAuto(boardId);
      final directory = Directory(filesDirPath);

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      logger.i('👀 Starting Full file/folder monitor for: $filesDirPath');
      await Future.delayed(const Duration(milliseconds: 1000));

      _watcherSubscription = directory
          .watch(
            events:
                FileSystemEvent.modify |
                FileSystemEvent.create |
                FileSystemEvent.move |
                FileSystemEvent.delete,
            recursive: true,
          )
          .listen((event) {
            _handleFileSystemEvent(event);
          }, onError: (e) => logger.e('File Watcher Error: $e'));
    } catch (e) {
      logger.e('Failed to start file monitor: $e');
    }
  }

  void _handleFileSystemEvent(FileSystemEvent event) {
    String filePath = event.path;
    String? destinationPath;

    if (event is FileSystemMoveEvent) {
      if (event.destination != null) {
        destinationPath = event.destination!;
      }
    }

    final String fileName = p.basename(filePath);

    if (fileName == 'Thumbs.db' ||
        fileName == 'desktop.ini' ||
        fileName == '.DS_Store' ||
        fileName.startsWith('~\$') ||
        fileName.endsWith('.tmp') ||
        fileName.endsWith('.part') ||
        fileName.startsWith('.')) {
      return;
    }

    if (_ignoredFiles.contains(fileName.toLowerCase())) {
      return;
    }

    if (event.isDirectory) {
      if (event is FileSystemCreateEvent) {
        if (_debounceTimers.containsKey(filePath)) {
          _debounceTimers[filePath]?.cancel();
        }
        _debounceTimers[filePath] = Timer(
          const Duration(milliseconds: 500),
          () {
            _debounceTimers.remove(filePath);
            if (_ignoredFiles.contains(fileName.toLowerCase())) return;
            onFolderAdded?.call(filePath);
          },
        );
      } else if (event is FileSystemDeleteEvent) {
        onFolderDeleted?.call(filePath);
      } else if (event is FileSystemMoveEvent && destinationPath != null) {
        onFolderRenamed?.call(filePath, destinationPath);
      }
      return;
    }

    if (event is FileSystemDeleteEvent) {
      onFileDeleted?.call(filePath);
      return;
    }

    if (event is FileSystemMoveEvent && destinationPath != null) {
      onFileRenamed?.call(filePath, destinationPath);
      return;
    }
    if (event is FileSystemCreateEvent) {
      Timer(const Duration(milliseconds: 1000), () async {
        if (!await File(filePath).exists()) {
          return;
        }
        if (_ignoredFiles.contains(fileName.toLowerCase())) {
          return;
        }
        onFileAdded?.call(filePath);
      });
    }

    if (_debounceTimers.containsKey(filePath)) {
      _debounceTimers[filePath]?.cancel();
    }

    final targetPath = destinationPath ?? filePath;

    _debounceTimers[targetPath] = Timer(
      const Duration(milliseconds: 1000),
      () async {
        _debounceTimers.remove(targetPath);
        if (await File(targetPath).exists()) {
          await _processFileChange(targetPath, p.basename(targetPath));
        }
      },
    );
  }

  Future<void> _processFileChange(String filePath, String fileName) async {
    final file = File(filePath);
    final String? itemId = getFileIdCallback(filePath);
    if (itemId == null) return;

    if (_ignoredFiles.contains(fileName.toLowerCase())) return;

    try {
      if (!await file.exists()) return;

      int attempts = 0;
      int lastLength = -1;
      bool isReady = false;

      while (attempts < 5) {
        try {
          final stat = await file.stat();
          final length = stat.size;
          if (length == lastLength) {
            isReady = true;
            break;
          }
          lastLength = length;
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      if (!isReady) {
        logger.w('⚠️ File $fileName unstable. Skipping.');
        return;
      }

      File fileToSend = file;
      bool isShadowCopy = false;

      try {
        final raf = await file.open(mode: FileMode.read);
        await raf.close();
      } catch (e) {
        logger.w('⚠️ File locked: $fileName. Creating Shadow Copy...');
        try {
          final tempDir = Directory.systemTemp;
          final tempPath = p.join(
            tempDir.path,
            'noty_shadow_${DateTime.now().millisecondsSinceEpoch}_$fileName',
          );
          await file.copy(tempPath);
          fileToSend = File(tempPath);
          isShadowCopy = true;
        } catch (copyError) {
          logger.e('❌ Failed to create shadow copy: $copyError');
          return;
        }
      }

      if (rtcManager != null) {
        logger.i('📂 Streaming updated file: $fileName');

        final String fileHash = await _calculateFileHash(fileToSend);

        await rtcManager!.broadcastFile(
          filePath,
          fileName,
          fileToSend,
          customFileId: itemId,
          fileHash: fileHash,
        );
      } else {
        logger.i(
          '📂 File changed locally: $fileName (No WebRTC connection, skipping broadcast)',
        );
      }

      if (isShadowCopy) {
        try {
          await Future.delayed(const Duration(seconds: 2));
          if (await fileToSend.exists()) await fileToSend.delete();
        } catch (_) {}
      }
    } catch (e) {
      logger.e('❌ Error processing file $fileName: $e');
    }
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      final stream = file.openRead();
      final digest = await md5.bind(stream).first;
      return digest.toString();
    } catch (e) {
      logger.e("Hash error: $e");
      return "";
    }
  }

  /// Use this to ignore a file OR folder name from the next event.
  /// Useful when creating folders via UI ('F' key) to avoid feedback loops.
  void ignoreNextChange(String name) {
    final lowerName = name.toLowerCase();
    _ignoredFiles.add(lowerName);

    // Keep it ignored for a bit longer to be safe (OS events can be delayed)
    Timer(const Duration(seconds: 5), () {
      _ignoredFiles.remove(lowerName);
    });
  }

  void stop() {
    _watcherSubscription?.cancel();
    _debounceTimers.values.forEach((timer) => timer.cancel());
    _debounceTimers.clear();
    logger.i('File monitor stopped');
  }
}
