import 'dart:async';
import 'dart:io';
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:boardly/utils/file_utils.dart';

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

  final Map<String, Timer> _ignoredPaths = {};

  final Set<String> _manualIgnorePaths = {};

  final Map<String, Timer> _debounceTimers = {};

  bool _isPaused = false;
  bool _isDisposed = false;

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

  void pause() {
    _isPaused = true;
    logger.i("⏸️ File Monitor PAUSED");
  }

  void resume() {
    if (_isDisposed) return;
    Timer(const Duration(milliseconds: 500), () {
      if (_isDisposed) return;
      _isPaused = false;
      logger.i("▶️ File Monitor RESUMED");
    });
  }

  void startIgnoring(String path) {
    if (_isDisposed) return;
    final normalized = _normalizePath(path);
    _manualIgnorePaths.add(normalized);
  }

  void stopIgnoring(String path) {
    if (_isDisposed) return;
    final normalized = _normalizePath(path);
    Timer(const Duration(milliseconds: 500), () {
      _manualIgnorePaths.remove(normalized);
    });
  }

  void ignorePath(String path) {
    if (_isDisposed) return;

    final normalized = _normalizePath(path);
    _ignoredPaths[normalized]?.cancel();

    _ignoredPaths[normalized] = Timer(const Duration(seconds: 3), () {
      _ignoredPaths.remove(normalized);
    });
  }

  String _normalizePath(String path) {
    return p.canonicalize(path);
  }

  Future<void> startMonitoring() async {
    try {
      final filesDirPath = await BoardStorage.getBoardFilesDirAuto(boardId);
      final directory = Directory(filesDirPath);

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      logger.i('👀 Starting ROBUST file/folder monitor for: $filesDirPath');

      await Future.delayed(const Duration(milliseconds: 1000));

      if (_isDisposed) return;

      _watcherSubscription = directory
          .watch(
            events:
                FileSystemEvent.modify |
                FileSystemEvent.create |
                FileSystemEvent.move |
                FileSystemEvent.delete,
            recursive: true,
          )
          .listen(
            (event) => _handleFileSystemEvent(event),
            onError: (e) => logger.e('File Watcher Error: $e'),
          );
    } catch (e) {
      logger.e('Failed to start file monitor: $e');
    }
  }

  void _handleFileSystemEvent(FileSystemEvent event) {
    if (_isPaused) return;

    final String path = event.path;
    final String normalizedPath = _normalizePath(path);
    final String fileName = p.basename(path);

    if (_isSystemFile(fileName)) return;

    if (_ignoredPaths.containsKey(normalizedPath)) return;

    if (_manualIgnorePaths.contains(normalizedPath)) return;

    String? destinationPath;
    if (event is FileSystemMoveEvent && event.destination != null) {
      destinationPath = event.destination!;
      final normalizedDest = _normalizePath(destinationPath);

      if (_ignoredPaths.containsKey(normalizedDest)) return;
      if (_manualIgnorePaths.contains(normalizedDest)) return;
    }

    if (event.isDirectory) {
      _handleFolderEvent(event, path, destinationPath);
      return;
    }

    _handleFileEvent(event, path, destinationPath, fileName);
  }

  bool _isSystemFile(String fileName) {
    return fileName == 'meta.json' ||
        fileName.startsWith('meta.json') ||
        fileName == 'Thumbs.db' ||
        fileName == 'desktop.ini' ||
        fileName == '.DS_Store' ||
        fileName.startsWith(r'~$') ||
        fileName.endsWith('.tmp') ||
        fileName.endsWith('.part') ||
        (fileName.startsWith('.') && fileName.length > 1);
  }

  void _handleFolderEvent(
    FileSystemEvent event,
    String path,
    String? destPath,
  ) {
    if (event is FileSystemCreateEvent) {
      _debounce(path, () {
        if (_ignoredPaths.containsKey(_normalizePath(path))) return;
        if (_manualIgnorePaths.contains(_normalizePath(path))) return;
        onFolderAdded?.call(path);
      }, duration: 500);
    } else if (event is FileSystemDeleteEvent) {
      onFolderDeleted?.call(path);
    } else if (event is FileSystemMoveEvent && destPath != null) {
      onFolderRenamed?.call(path, destPath);
    }
  }

  void _handleFileEvent(
    FileSystemEvent event,
    String path,
    String? destPath,
    String fileName,
  ) {
    if (event is FileSystemDeleteEvent) {
      onFileDeleted?.call(path);
      return;
    }

    if (event is FileSystemMoveEvent && destPath != null) {
      onFileRenamed?.call(path, destPath);
      return;
    }

    if (event is FileSystemCreateEvent || event is FileSystemModifyEvent) {
      Timer(const Duration(milliseconds: 200), () async {
        if (_isPaused) return;
        final normalized = _normalizePath(path);
        if (_ignoredPaths.containsKey(normalized)) return;
        if (_manualIgnorePaths.contains(normalized)) return;

        if (!await File(path).exists()) return;

        if (event is FileSystemCreateEvent) {
          onFileAdded?.call(path);
        }

        _debounce(path, () async {
          if (await File(path).exists()) {
            await _processFileChange(path, fileName);
          }
        }, duration: 1000);
      });
    }
  }

  void _debounce(String tag, Function() action, {int duration = 1000}) {
    if (_debounceTimers.containsKey(tag)) {
      _debounceTimers[tag]?.cancel();
    }
    _debounceTimers[tag] = Timer(Duration(milliseconds: duration), action);
  }

  Future<void> _processFileChange(String filePath, String fileName) async {
    if (_isPaused) return;
    final normalized = _normalizePath(filePath);
    if (_ignoredPaths.containsKey(normalized)) return;
    if (_manualIgnorePaths.contains(normalized)) return;

    final String? itemId = getFileIdCallback(filePath);
    if (itemId == null) return;

    final file = File(filePath);

    try {
      if (!await file.exists()) return;

      if (!await _isFileStable(file)) {
        logger.w('⚠️ File $fileName unstable/locked. Skipping broadcast.');
        return;
      }

      File fileToSend = file;
      bool isShadowCopy = false;

      try {
        final raf = await file.open(mode: FileMode.read);
        await raf.close();
      } catch (e) {
        try {
          final tempDir = Directory.systemTemp;
          final tempPath = p.join(
            tempDir.path,
            'noty_shadow_${DateTime.now().millisecondsSinceEpoch}_$fileName',
          );
          await file.copy(tempPath);
          fileToSend = File(tempPath);
          isShadowCopy = true;
        } catch (_) {
          return;
        }
      }

      if (rtcManager != null) {
        logger.i('📂 Streaming updated file: $fileName');
        final String fileHash = await _calculateFileHash(fileToSend.path);

        await rtcManager!.broadcastFile(
          filePath,
          fileName,
          fileToSend,
          customFileId: itemId,
          fileHash: fileHash,
        );
      }

      if (isShadowCopy) {
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            if (await fileToSend.exists()) await fileToSend.delete();
          } catch (_) {}
        });
      }
    } catch (e) {
      logger.e('❌ Error processing file $fileName: $e');
    }
  }

  Future<bool> _isFileStable(File file) async {
    int attempts = 0;
    int lastLength = -1;
    while (attempts < 5) {
      try {
        final stat = await file.stat();
        final length = stat.size;
        if (length == lastLength && length >= 0) return true;
        lastLength = length;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
      attempts++;
    }
    return false;
  }

  Future<String> _calculateFileHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return "";
    int attempts = 0;
    while (attempts < 3) {
      try {
        final hash = await compute(calculateMd5InIsolate, filePath);
        if (hash.isNotEmpty) return hash;
        throw Exception("Empty hash result");
      } catch (e) {
        attempts++;
        if (attempts >= 3) return "";
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    return "";
  }

  void stop() {
    _isDisposed = true;
    _watcherSubscription?.cancel();
    _debounceTimers.values.forEach((timer) => timer.cancel());
    _debounceTimers.clear();
    _ignoredPaths.values.forEach((timer) => timer.cancel());
    _ignoredPaths.clear();
    _manualIgnorePaths.clear();
    logger.i('File monitor stopped');
  }
}
