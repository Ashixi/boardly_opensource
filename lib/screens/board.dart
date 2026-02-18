import 'dart:async';
import 'dart:io';
import 'dart:math'; // Для Random, sqrt, max, min
import 'dart:ui' as ui;
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/models/board_items.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/models/connection_model.dart';
import 'package:boardly/screens/board_painter.dart';
import 'package:boardly/screens/start_screen.dart';
import 'package:boardly/services/file_monitor_service.dart';
import 'package:boardly/services/localization.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:boardly/widgets/board_minimap_painter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:boardly/utils/file_utils.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cross_file/cross_file.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:path/path.dart' as p;
import 'dart:convert';
import 'dart:io' as io;
import 'package:crypto/crypto.dart';
import 'dart:collection';

import 'package:boardly/mixins/board_monitoring_mixin.dart'; // шлях до твого файлу

// Future<String> _calculateMd5InIsolate(String filePath) async {
//   final file = File(filePath);
//   if (!file.existsSync()) return "";

//   try {
//     final stream = file.openRead();
//     final digest = await md5.bind(stream).first;
//     return digest.toString();
//   } catch (e) {
//     return "";
//   }
// }

enum SidebarMode { none, explorer, users, tags }

class CanvasBoard extends StatefulWidget {
  final BoardModel? board;
  final Function(Connection)? onOpenConnectionBoard;
  final Function(BoardModel)? onBoardUpdated;
  final WebRTCManager? webRTCManager;
  final int nestingLevel;

  const CanvasBoard({
    super.key,
    this.board,
    this.onOpenConnectionBoard,
    this.onBoardUpdated,
    this.webRTCManager,
    this.nestingLevel = 0,
  });

  @override
  State<CanvasBoard> createState() => CanvasBoardState();
}

class CanvasBoardState extends State<CanvasBoard> with FileLogicMixin {
  List<BoardItem> items = [];
  double scale = 1.0;
  Offset offset = Offset.zero;
  BoardItem? selectedItem;
  Offset? dragStartLocalPos;
  Connection? _draggedConnection;
  bool _dragging = false;
  Connection? _highlightedConnection;
  BoardItem? _linkTargetItem; // <--- ДОДАЙТЕ ЦЮ ЗМІННУ ДЛЯ "ПРИМАГНІЧУВАННЯ"
  final Queue<Future<void> Function()> _incomingQueue = Queue();
  bool _isProcessingIncoming = false;

  final Set<String> _locallyProcessingFiles = {};
  bool get _isNestedFolder =>
      widget.board?.isConnectionBoard == true && widget.onBoardUpdated != null;

  bool _isSpacePressed = false;
  bool _isCtrlPressed = false;
  bool _isFPressed = false;
  bool _isAltPressed = false;
  bool _isMapOpen = false;

  Timer? _saveDebounceTimer;

  bool _isArrowCreationMode = false;
  Offset? _tempArrowStart;
  Offset? _tempArrowEnd;
  BoardItem? _arrowStartItem;
  Color _currentArrowColor = Colors.black;
  double _currentArrowWidth = 2.0;

  Size? _canvasSize;
  Offset lastTapPosition = Offset.zero;
  DateTime? lastTapTime;
  int tapCount = 0;

  final Map<String, bool> _incomingFileIsInitial = {};
  final Map<String, Map<String, String>> _connectedUsers = {};

  late FocusNode _focusNode;

  List<BoardItem> _folderSelection = [];

  String? _currentUserPublicId;
  bool _isHost = false;
  final Map<String, DateTime> _downloadLastActiveTime = {};
  Offset? _dragStartGlobalPos;
  bool _isMounted = false;
  String? _myPeerId;
  bool _isDisposed = false;
  final Map<String, String> _pendingUpdates = {};
  Timer? _updateRetryTimer;

  FileMonitorService? _fileMonitorService;

  final Map<String, IOSink> _incomingFileWriters = {};
  final Map<String, String> _incomingFilePaths = {};
  final Map<String, String> _incomingFileOriginalPaths = {};
  final Map<String, int> _incomingFileExpectedSizes = {};

  Map<String, ui.Image> _loadedIcons = {};

  SidebarMode _sidebarMode = SidebarMode.none;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    items = widget.board?.items ?? [];

    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);

    _checkOwnership();

    if (widget.board != null) {
      // if (widget.onOpenConnectionBoard != null) {
      //   // widget.board!.isConnectionBoard = false;
      // }
      syncOrphanFiles();
    }
    _isMounted = true;

    _updateRetryTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _processPendingUpdates();
      _cleanupStaleDownloads();
    });

    _myPeerId = widget.webRTCManager?.myPeerId;

    _setupWebRTCListener();
    _initializeConnectionState();
    _registerRtcListeners();

    if (widget.board?.id != null) {
      logger.i('🚀 Initializing Local/Remote FileMonitorService...');

      _fileMonitorService = FileMonitorService(
        rtcManager: widget.webRTCManager,
        boardId: widget.board!.id!,

        getFileIdCallback: (String filePath) {
          final item = items.firstWhereOrNull(
            (i) =>
                i.originalPath == filePath ||
                p.basename(i.originalPath) == p.basename(filePath),
          );
          return item?.id;
        },

        // FILE callbacks
        onFileAdded: (String path) => handleExternalFileAdded(path),
        onFileRenamed:
            (String old, String newP) => _handleExternalFileRenamed(old, newP),
        onFileDeleted: (String path) => _handleExternalFileDeleted(path),

        // FOLDER callbacks
        onFolderAdded: (String path) => handleExternalFolderAdded(path),
        onFolderRenamed:
            (String old, String newP) => handleExternalFolderRenamed(old, newP),
        onFolderDeleted: (String path) => handleExternalFolderDeleted(path),
      );

      _fileMonitorService!.startMonitoring();
    }

    _loadAllIcons();
  }

  Future<void> _loadAllIcons() async {
    final types = [
      'avi',
      'csv',
      'docx',
      'exe',
      'gif',
      'mov',
      'ods',
      'odt',
      'rtf',
      'svg',
      'xls',
      'pdf',
      'doc',
      'txt',
      'jpg',
      'jpeg',
      'png',
      'rar',
      'zip',
      'mp4',
      'mp3',
      'exe',
      'folder',
      'default',
      'json',
      'py',
      'cpp',
      'css',
      'html',
      'ppt',
      'rust',
      'js',
      'ogg',
    ];
    final Map<String, ui.Image> tempIcons = {};

    for (final type in types) {
      try {
        final image = await _loadImageFromAsset('assets/icons/$type.png');
        tempIcons[type] = image;
      } catch (e) {
        logger.w("⚠️ Не вдалося завантажити іконку для $type: $e");
      }
    }

    if (mounted) {
      setState(() {
        _loadedIcons = tempIcons;
      });
    }
  }

  // ДОДАНО: Метод обробки вхідної черги
  void _processIncomingQueue() async {
    if (_isProcessingIncoming) return;
    _isProcessingIncoming = true;

    while (_incomingQueue.isNotEmpty) {
      try {
        final task = _incomingQueue.removeFirst();
        await task();
      } catch (e) {
        logger.e("Error processing incoming message: $e");
      }
    }

    _isProcessingIncoming = false;
  }

  Future<ui.Image> _loadImageFromAsset(String assetName) async {
    final data = await rootBundle.load(assetName);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void scrollToItem(BoardItem item) {
    final itemCenter = item.position + const Offset(50, 50);
    _safeSetState(() {
      offset = -itemCenter * scale;
      selectedItem = item;
    });
  }

  // Future<File?> _findLocalFileForItem(BoardItem item) async {
  //   File candidate = File(item.originalPath);
  //   if (await candidate.exists()) return candidate;
  //   if (widget.board?.id == null) return null;
  //   try {
  //     final dirName = widget.board!.id!;
  //     final String boardFilesDir = await BoardStorage.getBoardFilesDirAuto(
  //       dirName,
  //     );

  //     final candidates = [
  //       p.join(boardFilesDir, item.fileName),
  //       p.join(boardFilesDir, item.id),
  //     ];
  //     for (final path in candidates) {
  //       candidate = File(path);
  //       if (await candidate.exists()) {
  //         if (item.originalPath != path) {
  //           _updateItemPath(item, path);
  //         }
  //         return candidate;
  //       }
  //     }
  //   } catch (e) {
  //     logger.w("Error searching for local file: $e");
  //   }
  //   return null;
  // }

  // void _handleExternalFolderAdded(String path) {
  //   if (!mounted) return;
  //   final folderName = p.basename(path);

  //   // 1. Жорстка перевірка: чи вже є така папка в UI?
  //   final exists =
  //       widget.board?.connections?.any((c) => c.name == folderName) ?? false;

  //   // Якщо папка вже є в логіці програми - ігноруємо івент від файлової системи
  //   if (exists) {
  //     logger.i("📂 Folder detected but already exists in board: $folderName");
  //     return;
  //   }

  //   // Також перевіряємо, чи це не службова папка
  //   if (folderName == 'files' || folderName.startsWith('.')) return;

  //   logger.i("📂 Valid External Folder Detected: $folderName");

  //   // ... далі твій код створення Connection ...
  //   Offset position = const Offset(200, 200);
  //   if ((widget.board?.connections?.isNotEmpty ?? false)) {
  //     final lastPos = widget.board!.connections!.last.collapsedPosition;
  //     if (lastPos != null) position = lastPos + const Offset(20, 20);
  //   }

  //   final newFolder = Connection(
  //     id:
  //         UniqueKey()
  //             .toString(), // Краще генерувати ID на основі імені, якщо хочеш уникнути дублів при пересинхронізації, але UniqueKey ок для нових
  //     name: folderName,
  //     itemIds: [],
  //     boardId: widget.board!.id,
  //     isCollapsed: true,
  //     collapsedPosition: position,
  //     colorValue: Colors.blue.value,
  //   );

  //   _safeSetState(() {
  //     widget.board?.connections ??= [];
  //     widget.board!.connections!.add(newFolder);
  //   });
  //   _saveBoard();

  //   if (widget.webRTCManager != null) {
  //     widget.webRTCManager!.broadcastFolderCreate(newFolder);
  //     // Важливо: відправити оновлення, щоб інші знали структуру
  //     widget.webRTCManager!.broadcastConnectionUpdate(
  //       widget.board!.connections!,
  //     );
  //   }
  // }

  // void _handleExternalFolderRenamed(String oldPath, String newPath) {
  //   if (!mounted) return;
  //   final oldName = p.basename(oldPath);
  //   final newName = p.basename(newPath);

  //   final conn = widget.board?.connections?.firstWhereOrNull(
  //     (c) => c.name == oldName,
  //   );

  //   if (conn != null) {
  //     logger.i("✏️ Folder Renamed: $oldName -> $newName");
  //     _safeSetState(() {
  //       conn.name = newName;
  //       // ... (код оновлення шляхів айтемів залишається без змін) ...
  //       for (var itemId in conn.itemIds) {
  //         final itemIndex = items.indexWhere((i) => i.id == itemId);
  //         if (itemIndex != -1) {
  //           final item = items[itemIndex];
  //           if (item.originalPath.contains(oldName)) {
  //             final newItemPath = item.originalPath.replaceFirst(
  //               oldName,
  //               newName,
  //             );
  //             items[itemIndex] = item.copyWith(
  //               path: newItemPath,
  //               originalPath: newItemPath,
  //               shortcutPath: newItemPath,
  //             );
  //           }
  //         }
  //       }
  //     });
  //     _saveBoard();
  //     if (widget.webRTCManager != null) {
  //       widget.webRTCManager!.broadcastConnectionUpdate(
  //         widget.board!.connections!,
  //       );
  //       widget.webRTCManager!.broadcastFolderRename(conn.id, oldName, newName);
  //     }
  //   }
  // }

  // void _handleExternalFolderDeleted(String path) {
  //   if (!mounted) return;
  //   final folderName = p.basename(path);

  //   final conn = widget.board?.connections?.firstWhereOrNull(
  //     (c) => c.name == folderName,
  //   );
  //   if (conn != null) {
  //     logger.i("🗑️ Folder Deleted: $folderName");

  //     final connId = conn.id;

  //     _safeSetState(() {
  //       widget.board!.connections!.remove(conn);
  //     });
  //     _saveBoard();

  //     if (widget.webRTCManager != null) {
  //       widget.webRTCManager!.broadcastFolderDelete(connId, folderName);
  //       widget.webRTCManager!.broadcastConnectionUpdate(
  //         widget.board!.connections!,
  //       );
  //     }
  //   }
  // }

  Future<void> _safeWriteBytes(File file, List<int> bytes) async {
    int attempts = 0;
    while (attempts < 3) {
      try {
        await file.writeAsBytes(bytes, flush: true);
        return;
      } catch (e) {
        attempts++;
        await Future.delayed(const Duration(milliseconds: 500));
        if (attempts == 3) rethrow;
      }
    }
  }

  void _cleanupStaleDownloads() {
    final now = DateTime.now();
    final List<String> staleIds = [];
    _incomingFileWriters.forEach((id, sink) {
      final lastActive = _downloadLastActiveTime[id] ?? DateTime.now();
      if (now.difference(lastActive).inSeconds > 60) {
        staleIds.add(id);
      }
    });
    for (final id in staleIds) {
      _incomingFileWriters[id]?.close();
      _incomingFileWriters.remove(id);
      _incomingFilePaths.remove(id);
      _incomingFileOriginalPaths.remove(id);
      _downloadLastActiveTime.remove(id);
    }
  }

  void _setupConnectionCallbacks() {
    if (widget.webRTCManager == null) return;

    widget.webRTCManager!.onConnected = (String myPeerId) {
      if (_isDisposed || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed && mounted) {
          setState(() {
            _myPeerId = myPeerId;
          });
        }
      });
    };

    widget.webRTCManager!.onDisconnected = () {
      if (_isDisposed || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed && mounted) {
          setState(() {
            _myPeerId = null;
          });
        }
      });
    };
  }

  Future<String> _calculateFileHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return "";

    int attempts = 0;
    // Пробуємо 3 рази, якщо файл заблокований
    while (attempts < 3) {
      try {
        // Використовуємо compute для важкої роботи
        final hash = await compute(calculateMd5InIsolate, filePath);

        if (hash.isNotEmpty) return hash;

        // Якщо хеш пустий, можливо файл ще пишеться, спробуємо ще раз
        throw Exception("Empty hash result");
      } catch (e) {
        attempts++;
        if (attempts >= 3) {
          // Тут можна додати твій logger, якщо передаси його, або просто повернути пусте
          debugPrint(
            "⚠️ Failed to calculate hash for $filePath after 3 attempts",
          );
          return "";
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    return "";
  }

  Future<void> _processPendingUpdates() async {
    if (_pendingUpdates.isEmpty) return;

    // 🔥 СТАВИМО НА ПАУЗУ ВЕСЬ МОНІТОР НА ЧАС МАСОВОГО ОНОВЛЕННЯ
    _fileMonitorService?.pause();

    final List<String> processedTargets = [];

    try {
      for (final entry in _pendingUpdates.entries) {
        final targetPath = entry.key; // Це повний шлях
        final sourceTempPath = entry.value;
        final targetFile = File(targetPath);
        final sourceFile = File(sourceTempPath);

        if (!await sourceFile.exists()) {
          processedTargets.add(targetPath);
          continue;
        }

        // Додатково додаємо в ігнор, щоб resume() не зловив "хвіст" подій
        _fileMonitorService?.ignorePath(targetPath);

        try {
          if (await targetFile.exists()) {
            try {
              await targetFile.delete();
            } catch (_) {
              // Якщо файл все ще заблокований, пропускаємо і спробуємо в наступному циклі
              continue;
            }
          }
          await sourceFile.rename(targetPath);
          processedTargets.add(targetPath);

          logger.i("Pending update processed for: ${p.basename(targetPath)}");
        } catch (e) {
          logger.e("Error applying pending update: $e");
        }
      }
    } finally {
      // 🔥 ВІДНОВЛЮЄМО РОБОТУ МОНІТОРА
      _fileMonitorService?.resume();
    }

    // Очищаємо список оброблених
    for (final target in processedTargets) {
      _pendingUpdates.remove(target);
    }
  }

  void _initializeConnectionState() {
    if (widget.webRTCManager != null) {
      if (widget.webRTCManager!.isConnected) {
        if (mounted) {
          setState(() {
            _myPeerId = widget.webRTCManager!.myPeerId;
          });
        }
      }
    }
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      RawKeyboard.instance.addListener(_handleKey);
    } else {
      _isSpacePressed = false;
      _isCtrlPressed = false;
      _isFPressed = false;
      _isAltPressed = false;
      RawKeyboard.instance.removeListener(_handleKey);
    }
  }

  @override
  void didUpdateWidget(CanvasBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.board != oldWidget.board) {
      items = widget.board?.items ?? [];
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _isMounted = false;

    _saveDebounceTimer?.cancel();

    // if (widget.board != null && !_isNestedFolder) {
    //   if (widget.board != null && !_isNestedFolder) {
    //     widget.board!.items = List.from(items);
    //     widget.board!.connections ??= [];

    //     BoardStorage.saveBoard(widget.board!).catchError((e) {
    //       logger.w("Warning: Failed to save board on dispose: $e");
    //     });
    // }

    if (widget.webRTCManager != null) {
      widget.webRTCManager!.removeConnectedListener(_onBoardConnected);
      widget.webRTCManager!.removeDisconnectedListener(_onBoardDisconnected);
    }

    RawKeyboard.instance.removeListener(_handleKey);
    _focusNode.dispose();

    _updateRetryTimer?.cancel();
    if (!_isNestedFolder) {
      _cleanupCurrentBoardFiles();
    }

    for (var sink in _incomingFileWriters.values) {
      try {
        sink.close();
      } catch (e) {
        logger.e("Error closing sink in dispose: $e");
      }
    }
    _incomingFileWriters.clear();
    _incomingFilePaths.clear();
    _incomingFileOriginalPaths.clear();

    _fileMonitorService?.stop();

    _searchController.dispose();

    super.dispose();
  }

  void _registerRtcListeners() {
    if (widget.webRTCManager == null) return;
    widget.webRTCManager!.addConnectedListener(_onBoardConnected);
    widget.webRTCManager!.addDisconnectedListener(_onBoardDisconnected);

    widget.webRTCManager!.onSessionFull = () {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (ctx) => AlertDialog(
              title: Text(S.t('session_full_title')),
              content: Text(S.t('session_full_guest')),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pop(context);
                  },
                  child: Text(S.t('close')),
                ),
              ],
            ),
      );
    };

    // widget.webRTCManager!.onHostLimitReached = () {
    //   if (!mounted) return;
    //   ScaffoldMessenger.of(context).showSnackBar(
    //     SnackBar(
    //       content: Text(S.t('session_full_host')),
    //       backgroundColor: Colors.orange,
    //       duration: const Duration(seconds: 4),
    //       action: SnackBarAction(
    //         label: "PRO",
    //         textColor: Colors.white,
    //         onPressed: () {
    //           showDialog(
    //             context: context,
    //             builder: (context) => const PaymentDialog(),
    //           );
    //         },
    //       ),
    //     ),
    //   );
    // };
  }

  void _toggleSidebar(SidebarMode mode) {
    setState(() {
      if (_sidebarMode == mode) {
        _sidebarMode = SidebarMode.none;
        _searchController.clear();
        _searchQuery = "";
      } else {
        _sidebarMode = mode;
      }
    });
  }

  void _onBoardConnected(String myPeerId) {
    if (_isDisposed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed && mounted) {
        setState(() {
          _myPeerId = myPeerId;
        });
      }
    });
  }

  void _onBoardDisconnected() {
    if (_isDisposed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed && mounted) {
        setState(() {
          _myPeerId = null;
        });
      }
    });
  }

  void _handleFileContentRequest(
    Map<String, dynamic> data,
    String toPeerId,
  ) async {
    final filePath = data['path'] as String;
    try {
      final item = items.firstWhereOrNull((i) => i.path == filePath);
      if (item == null) return;
      final File? fileToRead = await findLocalFileForItem(item);
      if (fileToRead == null) return;
      final Uint8List fileBytes = await fileToRead.readAsBytes();
      final String contentBase64 = base64Encode(fileBytes);
      final message = {
        'type': 'full-file-content',
        'path': filePath,
        'content_base64': contentBase64,
      };
      widget.webRTCManager!.sendMessageToPeer(toPeerId, message);
    } catch (e) {
      logger.e('Error handling file content request: $e');
    }
  }

  Future<void> _handleFullFileContent(Map<String, dynamic> data) async {
    final filePath = data['path'] as String;
    final contentBase64 = data['content_base64'] as String?;
    if (contentBase64 == null) return;

    try {
      final Uint8List fileBytes = base64Decode(contentBase64);
      final String fileName = p.basename(filePath);
      final bool isGuest = !_isHost;

      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnectedBoard: isGuest,
      );

      final existingItem = items.firstWhereOrNull(
        (i) =>
            i.originalPath == filePath ||
            p.basename(i.originalPath) == fileName,
      );

      String finalFilePath;
      if (existingItem != null) {
        finalFilePath = existingItem.originalPath;
        if (!finalFilePath.contains(dirName)) {
          finalFilePath = p.join(boardFilesDir, fileName);
        }
      } else {
        finalFilePath = p.join(boardFilesDir, fileName);
        int counter = 1;
        while (await File(finalFilePath).exists()) {
          final ext = p.extension(fileName);
          final baseName = p.basenameWithoutExtension(fileName);
          finalFilePath = p.join(boardFilesDir, '${baseName}_$counter$ext');
          counter++;
        }
      }

      // 🔥 ЗАХИСТ МОНІТОРА
      // 1. Ігноруємо повний шлях
      _fileMonitorService?.ignorePath(finalFilePath);
      // 2. Пауза
      _fileMonitorService?.pause();

      try {
        // Фізичний запис файлу
        await _safeWriteBytes(File(finalFilePath), fileBytes);
      } finally {
        // 3. Відновлення
        _fileMonitorService?.resume();
      }

      if (existingItem != null) {
        final index = items.indexWhere((i) => i.id == existingItem.id);
        if (index != -1) {
          _safeSetState(() {
            items[index] = existingItem.copyWith(originalPath: finalFilePath);
          });
        }
      } else {
        final newItem = BoardItem(
          id: UniqueKey().toString(),
          path: finalFilePath,
          shortcutPath: finalFilePath,
          originalPath: finalFilePath,
          position: Offset(100, 100 + items.length * 120),
          type: p.extension(fileName).replaceFirst('.', ''),
          fileName: fileName,
        );
        _safeSetState(() {
          items.add(newItem);
        });
      }
      await _saveBoard();
    } catch (e) {
      logger.e('Failed to save received file content: $e');
    }
  }

  Future<void> _checkOwnership() async {
    final userData = await AuthStorage.getUserData();
    if (!mounted) return;
    setState(() {
      _currentUserPublicId = userData?.publicId;
      if (widget.board?.isJoined == true) {
        _isHost = false;
      } else if (widget.board?.ownerId != null &&
          _currentUserPublicId != null) {
        _isHost = widget.board!.ownerId == _currentUserPublicId;
      } else {
        _isHost = true;
      }
    });
  }

  void _handleFileChunk(Map<String, dynamic> data) {
    final String fileId = data['fileId'];
    final String base64Chunk = data['data'];
    final IOSink? sink = _incomingFileWriters[fileId];
    if (sink == null) return;
    _downloadLastActiveTime[fileId] = DateTime.now();
    try {
      final bytes = base64Decode(base64Chunk);
      sink.add(bytes);
    } catch (e) {
      logger.e('Error writing file chunk: $e');
    }
  }

  Future<void> _handleFileAvailable(
    Map<String, dynamic> data,
    String announcerPeerId,
  ) async {
    final String fileId = data['fileId'];
    final String fileName = data['fileName'];
    final String? remoteHash = data['fileHash'];
    final bool isInitial = data['isInitial'] ?? false;

    if (_incomingFileWriters.containsKey(fileId)) return;

    final existingItem = items.firstWhereOrNull(
      (i) => i.id == fileId || i.fileName == fileName,
    );

    bool needToDownload = true;

    if (existingItem != null) {
      final localFile = await findLocalFileForItem(existingItem);
      if (localFile != null && await localFile.exists()) {
        if (remoteHash != null && remoteHash.isNotEmpty) {
          final String localHash = await _calculateFileHash(localFile.path);

          if (localHash.isNotEmpty && localHash == remoteHash) {
            needToDownload = false;
          } else {
            logger.i(
              "Hash mismatch ($fileName). Local: $localHash, Remote: $remoteHash. Downloading...",
            );
          }
        } else {
          needToDownload = true;
        }
      }
    }

    if (!needToDownload) return;

    _incomingFileIsInitial[fileId] = isInitial;

    widget.webRTCManager!.requestFile(announcerPeerId, fileId, fileName);
  }

  Future<void> _handleFileRequestCommand(
    Map<String, dynamic> data,
    String requesterId,
  ) async {
    final String fileId = data['fileId'];
    final item = items.firstWhereOrNull((i) => i.id == fileId);
    if (item != null) {
      File file = File(item.originalPath);
      if (!await file.exists() && widget.board?.id != null) {
        final dirName = widget.board!.id!;
        final hostFilesDir = await BoardStorage.getBoardFilesDirAuto(dirName);

        final candidatePath = p.join(hostFilesDir, item.fileName);
        if (await File(candidatePath).exists()) {
          file = File(candidatePath);
        }
      }
      if (await file.exists()) {
        await widget.webRTCManager!.sendFileToPeer(
          requesterId,
          file.path,
          item.fileName,
          file,
          fileId: item.id,
        );
      }
    }
  }

  Future<void> _handleRemoteFileRename(Map<String, dynamic> data) async {
    final String fileId = data['fileId'];
    final String oldName = data['oldName'];
    final String newName = data['newName'];

    final itemIndex = items.indexWhere((i) => i.id == fileId);
    if (itemIndex == -1) return;

    final item = items[itemIndex];

    // Формуємо нові шляхи
    final String oldPath = item.originalPath;
    final String dir = p.dirname(oldPath);
    final String newPath = p.join(dir, newName);
    final newExt = p.extension(newPath).replaceFirst('.', '').toLowerCase();

    final File oldFile = File(oldPath);

    // Перевіряємо чи файл існує фізично перед тим як щось робити
    if (await oldFile.exists()) {
      // 🔥 Ігноруємо шляхи, щоб FileMonitor не зреагував на наші ж зміни
      _fileMonitorService?.ignorePath(oldPath);
      _fileMonitorService?.ignorePath(newPath);
      _fileMonitorService?.pause();

      try {
        // 1. Спочатку фізичне перейменування!
        await oldFile.rename(newPath);
        logger.i("Remote rename applied: $oldName -> $newName");

        // 2. Тільки якщо rename пройшов успішно — оновлюємо UI та модель
        _safeSetState(() {
          items[itemIndex] = item.copyWith(
            fileName: newName,
            path: newPath,
            originalPath: newPath,
            shortcutPath: newPath,
            type: newExt.isNotEmpty ? newExt : item.type,
          );
        });

        // Зберігаємо зміни в JSON конфіг дошки
        _saveBoard();
      } catch (e) {
        logger.e("Failed to apply remote rename: $e");
        // Тут можна показати юзеру SnackBar, що синхронізація імені не вдалася
      } finally {
        _fileMonitorService?.resume();
      }
    } else {
      logger.w("Remote rename requested, but local file not found: $oldPath");
    }
  }

  Future<void> _handleRemoteFolderRename(Map<String, dynamic> data) async {
    final String connectionId = data['connectionId'];
    final String oldName = data['oldName'];
    final String newName = data['newName'];

    final conn = widget.board?.connections?.firstWhereOrNull(
      (c) => c.id == connectionId,
    );
    if (conn == null) return;

    _safeSetState(() {
      conn.name = newName;
    });

    // Шукаємо папку
    final currentFilesDir = await _getCurrentFilesDir();
    final oldDirPath = p.join(currentFilesDir, oldName);
    final newDirPath = p.join(currentFilesDir, newName);

    final dir = Directory(oldDirPath);
    if (await dir.exists()) {
      // 🔥 FIX: Ігноруємо стару і нову назву папки
      _fileMonitorService?.ignorePath(oldDirPath);
      _fileMonitorService?.ignorePath(newDirPath);
      _fileMonitorService?.pause();

      try {
        await dir.rename(newDirPath);
        logger.i("Remote folder rename applied: $oldName -> $newName");

        // Оновлюємо шляхи для всіх файлів
        _safeSetState(() {
          for (final itemId in conn.itemIds) {
            final index = items.indexWhere((i) => i.id == itemId);
            if (index != -1) {
              final item = items[index];
              if (p.isWithin(oldDirPath, item.originalPath)) {
                final relative = p.relative(
                  item.originalPath,
                  from: oldDirPath,
                );
                final newItemPath = p.join(newDirPath, relative);

                items[index] = item.copyWith(
                  path: newItemPath,
                  originalPath: newItemPath,
                  shortcutPath: newItemPath,
                );
              }
            }
          }
        });
      } catch (e) {
        logger.e("Failed to apply remote folder rename: $e");
      } finally {
        _fileMonitorService?.resume();
      }
    }

    _saveBoard();
  }

  Future<void> _handleRemoteFolderCreate(Map<String, dynamic> data) async {
    try {
      final folderData = data['folder'];
      final newConnection = Connection.fromJson(folderData);

      final existsInUi =
          widget.board?.connections?.any((c) => c.id == newConnection.id) ??
          false;

      final currentFilesDir = await _getCurrentFilesDir();
      final newFolderPath = p.join(currentFilesDir, newConnection.name);
      final directory = Directory(newFolderPath);

      if (!await directory.exists()) {
        logger.i("📂 Remote Create: Creating directory $newFolderPath");

        _fileMonitorService?.ignorePath(newFolderPath);
        _fileMonitorService?.pause();

        try {
          await directory.create(recursive: true);
        } finally {
          _fileMonitorService?.resume();
        }
      }

      if (!existsInUi) {
        _safeSetState(() {
          widget.board?.connections ??= [];
          widget.board!.connections!.add(newConnection);
        });
        await _saveBoard();
      }
    } catch (e) {
      logger.e("Error handling remote folder create: $e");
    }
  }

  Future<void> _handleRemoteFolderDelete(Map<String, dynamic> data) async {
    try {
      final String connectionId = data['connectionId'];
      final String folderName = data['folderName'];

      final conn = widget.board?.connections?.firstWhereOrNull(
        (c) => c.id == connectionId,
      );

      if (conn != null) {
        _safeSetState(() {
          widget.board!.connections!.remove(conn);

          // 🔥 ВИПРАВЛЕННЯ: Видаляємо айтеми зі списку, замість перенесення в корінь
          items.removeWhere((item) => item.connectionId == connectionId);
        });
      }

      final currentFilesDir = await _getCurrentFilesDir();
      final folderPath = p.join(currentFilesDir, folderName);
      final directory = Directory(folderPath);

      if (await directory.exists()) {
        logger.i("🗑️ Remote Delete: Deleting directory $folderPath");

        _fileMonitorService?.ignorePath(folderPath);
        _fileMonitorService?.pause();

        try {
          await directory.delete(recursive: true);
        } finally {
          _fileMonitorService?.resume();
        }
      }

      await _saveBoard();
    } catch (e) {
      logger.e("Error handling remote folder delete: $e");
    }
  }

  void _setupWebRTCListener() {
    if (widget.webRTCManager == null) return;

    // 🔥 ДОДАНО async
    widget.webRTCManager!.onDataReceived = (String from, dynamic data) async {
      if (!_isMounted) return;
      final type = data['type'];

      // 1. Швидкий шлях (Handshake): обробляємо миттєво
      if (type == 'identity' || type == 'request-slot') {
        final pubId = data['publicId'];
        if (pubId != null) {
          if (_isHost && widget.board!.blockedPublicIds.contains(pubId)) {
            logger.w("🚫 Blocked user tried to connect: $pubId");
            widget.webRTCManager!.disconnectPeer(from);
            return;
          }

          _safeSetState(() {
            _connectedUsers.removeWhere(
              (key, value) => value['publicId'] == pubId,
            );

            _connectedUsers[from] = {
              'publicId': pubId,
              'username': data['username'] ?? 'Anonymous',
            };
          });
        }
        return;
      }

      // 2. Важкі операції: кладемо в ЛОКАЛЬНУ чергу (якщо вона у вас є в Board)
      // Або, якщо ви використовуєте чергу всередині RTCManager, то тут можна просто викликати await методів.

      // АЛЕ, оскільки в RTCManager ми вже зробили чергу _incomingQueue,
      // то onDataReceived викликається ВЖЕ всередині черги RTCManager!

      // Тому тут ми просто робимо await. Ніякої додаткової черги тут не треба,
      // інакше буде подвійна черга.

      if (!mounted) return;

      try {
        switch (type) {
          case 'peer-left':
            _safeSetState(() => _connectedUsers.remove(from));
            logger.i("RTC: Peer $from left");
            break;

          case 'item-update':
            _handleItemUpdate(data);
            break;

          case 'connection-update':
            _handleConnectionUpdate(data);
            break;

          case 'folder-create':
            // ЧЕКАЄМО завершення створення папки на диску
            await _handleRemoteFolderCreate(data);
            break;

          case 'folder-delete':
            await _handleRemoteFolderDelete(data);
            break;

          case 'folder-rename':
            await _handleRemoteFolderRename(data);
            break;

          case 'file-move':
            // ЧЕКАЄМО переміщення (запуститься тільки коли folder-create завершиться)
            await _handleRemoteFileMove(data);
            break;

          case 'file-rename':
            await _handleRemoteFileRename(data);
            break;

          case 'item-add':
            _handleItemAdd(data);
            break;

          case 'item-delete':
            await _handleItemDelete(data);
            break;

          case 'board-description-update':
            _handleBoardDescriptionUpdate(data);
            break;

          case 'request-file-content':
            _handleFileContentRequest(data, from);
            break;

          case 'full-file-content':
            await _handleFullFileContent(data);
            break;

          case 'file-available':
            await _handleFileAvailable(data, from);
            break;

          case 'request-file':
            await _handleFileRequestCommand(data, from);
            break;

          case 'file-transfer-start':
            await _handleFileTransferStart(data);
            break;

          case 'file-chunk':
            _handleFileChunk(data);
            break;

          case 'file-transfer-end':
            await _handleFileTransferEnd(data, from);
            break;

          case 'connection-move':
            _handleConnectionMove(data);
            break;

          case 'full-board':
            if (!_isHost) {
              try {
                final boardModel = BoardModel.fromJson(
                  jsonDecode(data['board']),
                );
                _handleFullBoardReceived(boardModel, from);
              } catch (e) {
                logger.e("Помилка парсингу дошки: $e");
              }
            }
            break;
        }
      } catch (e) {
        logger.e("Error handling message in board listener: $e");
      }
    };

    widget.webRTCManager!.onDataChannelOpen = (String peerId) async {
      final userData = await AuthStorage.getUserData();
      if (userData != null) {
        widget.webRTCManager!.sendMessageToPeer(peerId, {
          'type': 'identity',
          'publicId': userData.publicId,
          'username': userData.username,
        });
      }

      if (items.isNotEmpty) {
        await _performInitialSync(peerId);
      }
    };
  }

  Future<void> _performInitialSync(String peerId) async {
    if (widget.webRTCManager == null) return;

    logger.i("🔄 Performing Initial Sync with $peerId");

    // Відправляємо метадані дошки
    try {
      final boardJson = jsonEncode(widget.board!.toJson());
      widget.webRTCManager!.sendFullBoardToPeer(peerId, boardJson);
    } catch (e) {
      logger.e("Failed to send board meta: $e");
      return;
    }

    await Future.delayed(const Duration(milliseconds: 1000));

    // Використовуємо нову розумну чергу
    await widget.webRTCManager!.syncBoardSmartly(
      peerId,
      items,
      widget.board?.connections ?? [],
      _myPeerId,
    );
  }

  Future<void> _handleFileTransferStart(Map<String, dynamic> data) async {
    final String fileId = data['fileId'];
    final String fileName = data['fileName'];
    final int fileSize = data['fileSize'];

    try {
      if (_incomingFileWriters.containsKey(fileId)) {
        await _incomingFileWriters[fileId]?.close();
        _incomingFileWriters.remove(fileId);
      }

      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnectedBoard: !_isHost,
      );

      final dir = Directory(boardFilesDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final uniqueTempName =
          '${fileName}_${DateTime.now().microsecondsSinceEpoch}.part';
      final String tempFilePath = p.join(boardFilesDir, uniqueTempName);

      _fileMonitorService?.startIgnoring(tempFilePath);

      final IOSink sink = File(tempFilePath).openWrite();

      _incomingFileWriters[fileId] = sink;
      _incomingFilePaths[fileId] = tempFilePath;
      _incomingFileOriginalPaths[fileId] = data['originalPath'];
      _incomingFileExpectedSizes[fileId] = fileSize;
      _downloadLastActiveTime[fileId] = DateTime.now();

      logger.i('📥 Started receiving file: $fileName -> $tempFilePath');
    } catch (e) {
      logger.e('Error starting file transfer: $e');
    }
  }

  Future<void> _handleFileTransferEnd(
    Map<String, dynamic> data,
    String from,
  ) async {
    if (!mounted) return;

    final String fileId = data['fileId'];
    final IOSink? sink = _incomingFileWriters.remove(fileId);
    final String? tempFilePath = _incomingFilePaths.remove(fileId);
    final String? originalRemotePath = _incomingFileOriginalPaths.remove(
      fileId,
    );
    final int? expectedSize = _incomingFileExpectedSizes.remove(fileId);
    final bool isInitialSync = _incomingFileIsInitial.remove(fileId) ?? false;

    _downloadLastActiveTime.remove(fileId);

    if (sink == null || tempFilePath == null) return;

    try {
      await sink.flush();
      await sink.close();

      // 🔥 Перестаємо ігнорувати temp файл (хоча ми його зараз видалимо/перейменуємо)
      // Але важливо зняти ігнор, щоб не засмічувати пам'ять
      _fileMonitorService?.stopIgnoring(tempFilePath);

      // Невелика пауза для Windows
      await Future.delayed(const Duration(milliseconds: 100));

      final tempFile = File(tempFilePath);
      if (!await tempFile.exists()) return;

      final int actualSize = await tempFile.length();
      if (expectedSize != null && actualSize != expectedSize) {
        logger.w("Size mismatch. Deleting corrupted temp file.");
        try {
          await tempFile.delete();
        } catch (_) {}
        return;
      }

      final existingItem = items.firstWhereOrNull((i) => i.id == fileId);

      // Визначаємо ім'я та папку призначення
      String rawName =
          existingItem?.fileName ??
          (originalRemotePath != null
              ? p.basename(originalRemotePath)
              : 'file');
      String finalFileName =
          rawName.replaceAll(RegExp(r'[\u0000-\u001F]'), '').trim();

      String? targetConnId = existingItem?.connectionId ?? data['connectionId'];

      // Будуємо шлях
      String targetFilePath;
      bool useExistingPath = false;

      if (existingItem != null &&
          await File(existingItem.originalPath).exists()) {
        targetFilePath = existingItem.originalPath;
        useExistingPath = true;
      } else {
        String currentDir = await BoardStorage.getBoardFilesDirAuto(
          widget.board!.id!,
        );

        // Логіка для папок
        if (targetConnId != null && !_isNestedFolder) {
          final conn = widget.board?.connections?.firstWhereOrNull(
            (c) => c.id == targetConnId,
          );
          if (conn != null) {
            currentDir = p.join(currentDir, conn.name);
          }
        }

        final dir = Directory(currentDir);
        if (!await dir.exists()) await dir.create(recursive: true);
        targetFilePath = p.join(currentDir, finalFileName);
      }

      // Обробка конфліктів та переміщення файлу
      final targetFile = File(targetFilePath);
      bool isConflict = false;
      String moveDestination = targetFilePath;

      if (await targetFile.exists() && !useExistingPath) {
        if (!isConflict && existingItem == null) {
          int counter = 1;
          final baseName = p.basenameWithoutExtension(finalFileName);
          final ext = p.extension(finalFileName);
          final dir = p.dirname(moveDestination);
          while (await File(moveDestination).exists()) {
            moveDestination = p.join(dir, '${baseName}_$counter$ext');
            counter++;
          }
          finalFileName = p.basename(moveDestination);
          targetFilePath =
              moveDestination; // Оновлюємо targetFilePath до унікального шляху
        }
      }

      // 🔥 START IGNORING FINAL PATH: Ігноруємо кінцевий файл, бо ми його створюємо
      _fileMonitorService?.startIgnoring(targetFilePath);

      bool isLocked = false;

      try {
        if (await File(targetFilePath).exists() && !isConflict) {
          try {
            await File(targetFilePath).delete();
          } catch (_) {
            isLocked = true;
          }
        }

        if (!isLocked) {
          try {
            await tempFile.rename(targetFilePath);
          } catch (_) {
            await tempFile.copy(targetFilePath);
            await tempFile.delete();
          }
        }
      } catch (e) {
        logger.e("Error saving received file: $e");
      }

      // 🔥 STOP IGNORING: Знімаємо ігнор
      _fileMonitorService?.stopIgnoring(targetFilePath);

      if (!mounted) return;

      // Оновлення UI
      if (existingItem != null) {
        final index = items.indexWhere((i) => i.id == fileId);
        if (index != -1) {
          _safeSetState(() {
            items[index] = items[index].copyWith(
              originalPath: targetFilePath,
              path: targetFilePath,
              shortcutPath: targetFilePath,
            );
          });
        }
      } else {
        final newItem = BoardItem(
          id: fileId,
          path: targetFilePath,
          shortcutPath: targetFilePath,
          originalPath: targetFilePath,
          position: Offset(100, 100 + items.length * 50),
          type: p.extension(finalFileName).replaceFirst('.', ''),
          fileName: finalFileName,
          connectionId: targetConnId,
        );
        _safeSetState(() => items.add(newItem));
      }

      if (!isLocked) triggerSaveBoard();
    } catch (e) {
      logger.e('Failed to finalize received file: $e');
      // На всяк випадок знімаємо ігнор при помилці
      if (tempFilePath != null) _fileMonitorService?.stopIgnoring(tempFilePath);
    }
  }

  List<BoardItem> _getVisibleItems() {
    if (widget.board == null) return [];

    // ЯКЩО ЦЕ ВКЛАДЕНА ДОШКА (Папка)
    if (widget.board?.isConnectionBoard == true) {
      // 🔥 ВИПРАВЛЕННЯ: Просто показуємо файли з connectionId папки
      return items
          .where((item) => item.connectionId == widget.board!.id)
          .toList();
    }

    // ЯКЩО ЦЕ ГОЛОВНА ДОШКА
    final allConnections = widget.board?.connections ?? [];
    final collapsedConnIds =
        allConnections.where((c) => c.isCollapsed).map((c) => c.id).toSet();

    return items.where((item) {
      // 🔥 ВИПРАВЛЕННЯ: Файли без папки завжди видимі
      if (item.connectionId == null) return true;

      // Якщо файл у папці, і ця папка згорнута — не малюємо
      if (collapsedConnIds.contains(item.connectionId)) return false;

      return true;
    }).toList();
  }

  // lib/screens/board.dart

  void _handleFullBoardReceived(BoardModel receivedBoard, String from) async {
    // 1. ЗАХИСТ ХОСТА: Хост ніколи не приймає повний стан від гостя.
    if (_isHost) return;

    logger.i("📥 Full Board Sync: Merging data (Union Strategy)...");

    // 2. ПАУЗА МОНІТОРА: Щоб зміни, які ми зараз застосуємо, не тригерили зворотню відправку
    _fileMonitorService?.pause();

    try {
      final dirName = receivedBoard.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnectedBoard: true,
      );

      // Мапа для швидкого пошуку існуючих локальних файлів
      final Map<String, BoardItem> localItemsMap = {
        for (var item in items) item.id: item,
      };

      final List<BoardItem> mergedItems = [];
      final Set<String> processedIds = {};

      // 3. ОБРОБКА ВХІДНИХ ДАНИХ (Від Хоста)
      for (var hostItem in receivedBoard.items) {
        // Санітизація імені файлу
        final safeFileName =
            p
                .basename(hostItem.fileName)
                .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
                .trim();

        // Шукаємо, чи є у нас вже такий файл (за ID або за іменем)
        final existingLocalItem =
            localItemsMap[hostItem.id] ??
            items.firstWhereOrNull((i) => i.fileName == safeFileName);

        String localPath;

        // ЛОГІКА ВИЗНАЧЕННЯ ШЛЯХУ
        if (existingLocalItem != null &&
            await File(existingLocalItem.originalPath).exists()) {
          // Якщо файл вже є фізично - залишаємо наш локальний шлях
          localPath = existingLocalItem.originalPath;
        } else {
          // Якщо немає - будуємо шлях, де він МАЄ бути
          if (hostItem.connectionId != null) {
            final conn = receivedBoard.connections?.firstWhereOrNull(
              (c) => c.id == hostItem.connectionId,
            );
            if (conn != null) {
              // Шлях: Board/Folder/File
              localPath = p.join(boardFilesDir, conn.name, safeFileName);
            } else {
              // Fallback: якщо папки ще немає в списку (рідкісний кейс)
              localPath = p.join(boardFilesDir, safeFileName);
            }
          } else {
            // Шлях: Board/File
            localPath = p.join(boardFilesDir, safeFileName);
          }
        }

        // Додаємо в список мерджу
        mergedItems.add(
          hostItem.copyWith(
            fileName: safeFileName,
            path: localPath,
            originalPath: localPath,
            shortcutPath: localPath,
          ),
        );

        processedIds.add(hostItem.id);
      }

      // 4. ЗВОРОТНЯ СИНХРОНІЗАЦІЯ (Reverse Sync)
      // Зберігаємо локальні файли, яких немає у Хоста, і повідомляємо про них
      for (var localItem in items) {
        // Ігноруємо папки (вони обробляються окремо в connections) та вже оброблені файли
        if (!processedIds.contains(localItem.id) &&
            localItem.type != 'folder') {
          // Перевірка фізичної наявності (щоб не синхронізувати "биті" посилання)
          if (await File(localItem.originalPath).exists()) {
            logger.i(
              "➕ Found local item missing on Host: ${localItem.fileName}. Keeping and broadcasting.",
            );

            mergedItems.add(localItem); // Залишаємо у себе

            // Відправляємо хосту та іншим, що у нас є цей файл
            if (widget.webRTCManager != null) {
              // Оголошуємо файл
              widget.webRTCManager!.broadcastItemAdd(localItem);

              // Запускаємо стрім файлу, щоб хост міг його завантажити
              // Робимо це з маленькою затримкою, щоб не забити канал одразу
              widget.webRTCManager!.scheduleTask(() async {
                await _streamFileToPeers(localItem, localItem.originalPath);
              });
            }
          }
        }
      }

      // 5. ЗАСТОСУВАННЯ ЗМІН (State Update)
      _safeSetState(() {
        widget.board?.id = receivedBoard.id;
        widget.board?.description = receivedBoard.description;

        widget.board?.items = mergedItems;
        items = mergedItems;

        // Мерджимо папки (Connections)
        _mergeConnections(receivedBoard.connections ?? []);

        widget.board?.isJoined = true;
      });

      // Зберігаємо оновлений стан
      _saveBoard();

      // 6. ЗАВАНТАЖЕННЯ ВІДСУТНІХ ФАЙЛІВ
      // Перевіряємо, яких файлів фізично немає, і просимо їх
      int requestDelay = 0;
      for (var item in mergedItems) {
        if (item.type == 'folder') continue;

        if (!await File(item.originalPath).exists()) {
          // Розподіляємо запити у часі, щоб не створити DDOS ефект на хоста
          Future.delayed(Duration(milliseconds: requestDelay), () {
            if (mounted && widget.webRTCManager != null) {
              logger.i("Requesting missing content for: ${item.fileName}");
              widget.webRTCManager?.requestFile(
                'broadcast',
                item.id,
                item.fileName,
              );
            }
          });
          requestDelay += 200; // +200мс для кожного наступного файлу
        }
      }
    } catch (e) {
      logger.e("Error handling full board sync: $e");
    } finally {
      // 7. ВІДНОВЛЕННЯ МОНІТОРА
      // Даємо час системі "заспокоїтись" перед увімкненням монітора
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _fileMonitorService?.resume();
        }
      });
    }
  }

  // Допоміжний метод для мерджу папок (додай його поруч, якщо немає)
  void _mergeConnections(List<Connection> remoteConnections) {
    widget.board?.connections ??= [];

    // Сет ID remote папок для швидкої перевірки
    final remoteIds = remoteConnections.map((c) => c.id).toSet();

    // 1. Оновлюємо або додаємо папки від Хоста
    for (var remoteConn in remoteConnections) {
      final localIndex = widget.board!.connections!.indexWhere(
        (c) => c.id == remoteConn.id,
      );

      if (localIndex != -1) {
        // Оновлюємо, але ЗБЕРІГАЄМО наш стан згортання (isCollapsed)
        final localConn = widget.board!.connections![localIndex];

        // Копіюємо remote дані, але перезаписуємо isCollapsed нашим значенням
        final mergedConn = Connection.fromJson(remoteConn.toJson());
        mergedConn.isCollapsed = localConn.isCollapsed;
        // Позицію теж можна залишити локальну, якщо хочеш незалежне переміщення папок:
        // mergedConn.collapsedPosition = localConn.collapsedPosition;

        widget.board!.connections![localIndex] = mergedConn;
      } else {
        // Нова папка
        widget.board!.connections!.add(remoteConn);
      }
    }

    // 2. (Опціонально) Якщо у нас є локальна папка, якої немає у Хоста -> відправляємо її
    // Це потрібно, щоб папка, створена офлайн, не зникла
    for (var localConn in widget.board!.connections!) {
      if (!remoteIds.contains(localConn.id)) {
        logger.i(
          "Found local folder missing on Host: ${localConn.name}. Broadcasting create.",
        );
        if (widget.webRTCManager != null) {
          widget.webRTCManager!.broadcastFolderCreate(localConn);
          // Також треба відправити файли з цієї папки (це робить цикл Reverse Sync вище)
        }
      }
    }
  }

  void _checkMissingFiles() async {
    for (var item in items) {
      if (item.type == 'folder') continue;
      final file = File(item.originalPath);
      if (!await file.exists()) {
        // Файлу фізично немає, просимо його у мережі
        logger.i("Missing file content for ${item.fileName}, requesting...");
        widget.webRTCManager?.requestFile('broadcast', item.id, item.fileName);
      }
    }
  }

  // void _handleExternalFileAdded(String path) async {
  //   if (!mounted) return;

  //   final fileName = p.basename(path);

  //   if (_locallyProcessingFiles.contains(fileName.toLowerCase())) {
  //     return;
  //   }

  //   final existing = items.firstWhereOrNull(
  //     (i) => i.originalPath == path || i.fileName == fileName,
  //   );
  //   if (existing != null) return;

  //   logger.i("📂 External file detected: $path");

  //   final parentDirName = p.basename(p.dirname(path));
  //   String? assignedConnectionId;

  //   if (widget.board?.id != null &&
  //       parentDirName != widget.board!.id &&
  //       parentDirName != 'files') {
  //     final conn = widget.board?.connections?.firstWhereOrNull(
  //       (c) => c.name == parentDirName,
  //     );

  //     if (conn != null) {
  //       assignedConnectionId = conn.id;
  //       logger.i("🔗 Auto-assigning file to folder: ${conn.name}");
  //     }
  //   }

  //   final ext = p.extension(path).replaceFirst('.', '').toLowerCase();

  //   Offset position = const Offset(100, 100);
  //   if (items.isNotEmpty) {
  //     final lastItem = items.last;
  //     position = lastItem.position + const Offset(20, 20);
  //   }

  //   final newItem = BoardItem(
  //     id: UniqueKey().toString(),
  //     path: path,
  //     shortcutPath: path,
  //     originalPath: path,
  //     position: position,
  //     type: ext.isEmpty ? 'file' : ext,
  //     fileName: fileName,
  //     connectionId: assignedConnectionId,
  //   );

  //   _safeSetState(() {
  //     items.add(newItem);

  //     if (assignedConnectionId != null) {
  //       final conn = widget.board?.connections?.firstWhereOrNull(
  //         (c) => c.id == assignedConnectionId,
  //       );
  //       conn?.itemIds.add(newItem.id);
  //     }
  //   });

  //   await _saveBoard();
  //   _broadcastItemAdd(item: newItem);
  //   _streamFileToPeers(newItem, path);
  // }

  void _handleExternalFileRenamed(String oldPath, String newPath) {
    if (!mounted) return;

    final index = items.indexWhere(
      (i) => i.originalPath == oldPath || i.fileName == p.basename(oldPath),
    );

    if (index != -1) {
      final oldItem = items[index];
      final newName = p.basename(newPath);
      final newExt = p.extension(newPath).replaceFirst('.', '').toLowerCase();

      logger.i("✏️ File renamed externally: ${oldItem.fileName} -> $newName");

      final updatedItem = oldItem.copyWith(
        originalPath: newPath,
        path: newPath,
        shortcutPath: newPath,
        fileName: newName,
        type: newExt.isNotEmpty ? newExt : oldItem.type,
      );

      _safeSetState(() {
        items[index] = updatedItem;
      });

      _saveBoard();

      widget.webRTCManager?.broadcastItemUpdate(updatedItem);
      widget.webRTCManager?.broadcastFileRename(
        updatedItem.id,
        oldItem.fileName,
        newName,
      );
    } else {
      handleExternalFileAdded(newPath);
    }
  }

  void _handleExternalFileDeleted(String path) {
    if (!mounted) return;

    final index = items.indexWhere(
      (i) => i.originalPath == path || i.fileName == p.basename(path),
    );
    if (index != -1) {
      final item = items[index];
      logger.i("🗑️ File deleted externally: ${item.fileName}");

      _safeSetState(() {
        items.removeAt(index);
        _cleanUpConnections();
      });

      _saveBoard();
      widget.webRTCManager?.broadcastItemDelete(item.id);
    }
  }

  void _handleItemUpdate(Map<String, dynamic> data) {
    final updatedItem = BoardItem.fromJson(data['item']);
    final index = items.indexWhere((i) => i.id == updatedItem.id);
    if (index != -1) {
      items[index] = updatedItem;
    }
  }

  void _handleConnectionMove(Map<String, dynamic> data) {
    final String id = data['id'];
    final Map<String, dynamic> posData = data['position'];

    final conn = widget.board?.connections?.firstWhereOrNull((c) => c.id == id);
    if (conn != null) {
      _safeSetState(() {
        final newPos = Offset(
          (posData['dx'] as num).toDouble(),
          (posData['dy'] as num).toDouble(),
        );

        // Рахуємо дельту, щоб посунути і самі файли
        final delta = newPos - (conn.collapsedPosition ?? newPos);

        conn.collapsedPosition = newPos;

        // Рухаємо файли разом з папкою
        for (final itemId in conn.itemIds) {
          final item = items.firstWhereOrNull((i) => i.id == itemId);
          if (item != null) {
            item.position += delta;
          }
        }
        // ВАЖЛИВО: Ми НЕ чіпаємо conn.isCollapsed.
        // Це дозволяє рухати папку, не згортаючи її насильно у інших юзерів.
      });
    }
  }

  void _handleConnectionUpdate(Map<String, dynamic> data) {
    final List<dynamic> connsData = data['connections'];
    final remoteConnections =
        connsData.map((c) => Connection.fromJson(c)).toList();

    _safeSetState(() {
      widget.board?.connections ??= [];

      for (final remoteConn in remoteConnections) {
        final localConn = widget.board!.connections!.firstWhereOrNull(
          (c) => c.id == remoteConn.id,
        );

        if (localConn == null) {
          widget.board!.connections!.add(remoteConn);
        } else {
          // Оновлюємо існуючу
          bool myCollapsedState = localConn.isCollapsed;
          Offset? myPos = localConn.collapsedPosition;

          localConn.name = remoteConn.name;

          final Set<String> mergedIds = Set.from(localConn.itemIds)
            ..addAll(remoteConn.itemIds);
          localConn.itemIds = mergedIds.toList();

          localConn.colorValue = remoteConn.colorValue;
          localConn.collapsedPosition = remoteConn.collapsedPosition;

          // Відновлюємо наш стан згортання
          localConn.isCollapsed = myCollapsedState;
        }
      }
    });
  }

  // board.dart

  // У файлі lib/screens/board.dart

  Future<void> _handleItemAdd(Map<String, dynamic> data) async {
    try {
      var newItem = BoardItem.fromJson(data['item']);

      // --- ФІЛЬТРАЦІЯ КОНТЕКСТУ (Fix visual ghosts) ---

      // 1. Визначаємо ID поточної дошки/папки, де ми знаходимось
      // Якщо _isNestedFolder = true, то ID поточної view - це widget.board.id
      // Якщо ми в корені, то ми показуємо елементи, де connectionId == null (або items без батька)

      bool shouldShowInUI = false;

      if (_isNestedFolder) {
        // Ми всередині папки. Показуємо тільки якщо item.connectionId співпадає з нашою папкою
        if (newItem.connectionId == widget.board?.id) {
          shouldShowInUI = true;
        }
      } else {
        // Ми в корені (Main Board).
        // Показуємо, якщо item.connectionId == null (файл в корені)
        // АБО якщо item.connectionId вказує на папку, яка є на цій дошці (щоб оновити лічильник файлів всередині папки, але не малювати файл на канвасі)

        // Але тут нюанс: BoardPainter малює items. Якщо файл в папці, він має бути в items списку?
        // У твоїй логіці _getVisibleItems() фільтрує. Тож можна додавати в items, але переконатись, що _getVisibleItems працює.

        shouldShowInUI =
            true; // В корені зберігаємо все, _getVisibleItems відфільтрує згорнуті
      }

      // Якщо файл дублюється
      if (items.any((i) => i.id == newItem.id)) {
        return;
      }

      // --- ЛОГІКА ШЛЯХІВ (Як було раніше) ---
      if (!_isHost && widget.board?.id != null) {
        final dirName = widget.board!.id!;
        final String boardFilesDir = await BoardStorage.getBoardFilesDir(
          dirName,
          isConnectedBoard: true,
        ); // Use safe getter

        String localPath;
        if (newItem.connectionId != null) {
          final conn = widget.board?.connections?.firstWhereOrNull(
            (c) => c.id == newItem.connectionId,
          );
          if (conn != null) {
            localPath = p.join(boardFilesDir, conn.name, newItem.fileName);
          } else {
            localPath = p.join(boardFilesDir, newItem.fileName);
          }
        } else {
          localPath = p.join(boardFilesDir, newItem.fileName);
        }

        newItem = newItem.copyWith(
          path: localPath,
          originalPath: localPath,
          shortcutPath: localPath,
        );
      }

      // Додаємо в список тільки якщо це актуально для поточного контексту (або це корінь, який тримає все)
      // Але для вкладених папок (Nested) - ми не повинні зберігати файли сусідніх папок!
      if (_isNestedFolder && !shouldShowInUI) {
        logger.i(
          "Item received for another folder/context. Ignoring in this view.",
        );
        return;
      }

      _safeSetState(() {
        items.add(newItem);

        // Оновлюємо Connection, якщо файл прилетів у папку
        if (newItem.connectionId != null) {
          final conn = widget.board?.connections?.firstWhereOrNull(
            (c) => c.id == newItem.connectionId,
          );
          if (conn != null && !conn.itemIds.contains(newItem.id)) {
            conn.itemIds.add(newItem.id);
          }
        }
      });
    } catch (e) {
      logger.e("Error in _handleItemAdd: $e");
    }
  }

  Future<void> _handleItemDelete(Map<String, dynamic> data) async {
    final itemId = data['id'] as String;
    final itemToDelete = items.firstWhereOrNull((i) => i.id == itemId);
    if (itemToDelete != null) {
      await _deleteItemFile(itemToDelete);
    }
    _safeSetState(() {
      items.removeWhere((i) => i.id == itemId);
      _cleanUpConnections();
    });
  }

  void _handleBoardDescriptionUpdate(Map<String, dynamic> data) {
    widget.board?.description = data['description'] as String;
  }

  void _safeSetState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      // Можна виконати fn() навіть якщо не mounted, щоб оновити дані моделі,
      // але не оновлювати UI.
      fn();
    }
  }

  void _handleKey(RawKeyEvent event) {
    if (_isNestedFolder) return;

    final isSpace = event.logicalKey == LogicalKeyboardKey.space;
    final isCtrl =
        event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight;
    final isAlt =
        event.logicalKey == LogicalKeyboardKey.altLeft ||
        event.logicalKey == LogicalKeyboardKey.altRight;

    final isF = event.physicalKey == PhysicalKeyboardKey.keyF;
    final isM = event.physicalKey == PhysicalKeyboardKey.keyM;

    if (event is RawKeyDownEvent) {
      if (isSpace) _safeSetState(() => _isSpacePressed = true);
      if (isCtrl) _safeSetState(() => _isCtrlPressed = true);
      if (isAlt) _safeSetState(() => _isAltPressed = true);

      if (isF && !_isFPressed) {
        _safeSetState(() {
          _isFPressed = true;
          _folderSelection.clear();
        });
      }

      if (isM && !_isMapOpen) {
        _showMapOverlay();
      }
    } else if (event is RawKeyUpEvent) {
      if (isSpace) _safeSetState(() => _isSpacePressed = false);
      if (isCtrl) _safeSetState(() => _isCtrlPressed = false);
      if (isAlt) _safeSetState(() => _isAltPressed = false);
      if (isF && _isFPressed) _onFKeyReleased();
    }
  }

  void _onFKeyReleased() {
    _safeSetState(() {
      _isFPressed = false;
    });

    if (_folderSelection.length >= 2) {
      _createFolderFromSelection();
    } else if (_folderSelection.length == 1) {
      final item = _folderSelection.first;
      if (item.connectionId == null) {
        _showAddToFolderDialog(item);
      }
      _safeSetState(() => _folderSelection.clear());
    } else {
      _safeSetState(() => _folderSelection.clear());
    }
  }

  Future<void> _createFolderFromSelection() async {
    if (widget.nestingLevel >= 10) {
      _showErrorSnackbar("Максимальний рівень вкладеності!");
      return;
    }
    if (_folderSelection.isEmpty) return;

    // За замовчуванням папка буде синьою
    const int defaultColorValue = 0xFF2196F3; // Colors.blue.value
    String folderName = S.t('new_folder');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String tempName = folderName;
        // Прибрали StatefulBuilder, бо колір більше не змінюємо динамічно
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(S.t('create_folder')),
          content: SizedBox(
            width: 300,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(labelText: S.t('folder_name')),
                    onChanged: (v) => tempName = v,
                  ),
                  // Тут був вибір кольору — ми його видалили
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(S.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                folderName = tempName.trim();
                if (folderName.isEmpty) folderName = S.t('new_folder');
                Navigator.pop(ctx, true);
              },
              child: Text(S.t('create')),
            ),
          ],
        );
      },
    );

    if (result != true) {
      _safeSetState(() => _folderSelection.clear());
      return;
    }

    // 1. СТАВИМО МОНІТОР НА ПАУЗУ!
    _fileMonitorService?.pause();

    try {
      final currentFilesDir = await _getCurrentFilesDir();
      final newFolderPath = p.join(currentFilesDir, folderName);
      final directory = Directory(newFolderPath);

      // Створюємо об'єкт Connection
      final firstItem = _folderSelection.first;
      final folderPos = firstItem.position;

      final newFolder = Connection(
        id: UniqueKey().toString(),
        name: folderName,
        itemIds: _folderSelection.map((i) => i.id).toList(),
        boardId: widget.board!.id,
        isCollapsed: true,
        collapsedPosition: folderPos,
        colorValue: defaultColorValue, // Використовуємо фіксований колір
      );

      // Фізичне створення папки
      if (!await directory.exists()) {
        _fileMonitorService?.ignorePath(newFolderPath);
        await directory.create(recursive: true);
      }

      // Додаємо папку в локальний стейт
      _safeSetState(() {
        widget.board?.connections ??= [];
        widget.board!.connections!.add(newFolder);
      });

      // Оголошуємо всім про створення папки
      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastFolderCreate(newFolder);
      }

      // Переміщуємо файли
      for (final item in _folderSelection) {
        final oldFile = File(item.originalPath);
        final fileName = p.basename(item.originalPath);

        if (await oldFile.exists()) {
          final newPath = p.join(newFolderPath, fileName);

          _fileMonitorService?.ignorePath(item.originalPath);
          _fileMonitorService?.ignorePath(newPath);

          try {
            await oldFile.rename(newPath);
          } catch (e) {
            await oldFile.copy(newPath);
            await oldFile.delete();
          }

          // Оновлюємо шляхи в об'єкті
          item.originalPath = newPath;
          item.path = newPath;
          item.shortcutPath = newPath;

          if (item.connectionId != null && item.connectionId != newFolder.id) {
            final oldConn = widget.board?.connections?.firstWhereOrNull(
              (c) => c.id == item.connectionId,
            );
            oldConn?.itemIds.remove(item.id);
          }
          item.connectionId = newFolder.id;

          if (widget.webRTCManager != null) {
            widget.webRTCManager!.scheduleTask(() async {
              widget.webRTCManager!.broadcastFileMove(
                item.id,
                newFolder.id,
                fileName,
              );
            });
          }
        }
      }

      _safeSetState(() => _folderSelection.clear());
      await _saveBoard();

      _showFolderCreationFeedback(folderName);

      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastConnectionUpdate(
          widget.board!.connections!,
        );
      }
    } catch (e) {
      logger.e("Error creating folder: $e");
      _showErrorSnackbar("Помилка створення папки");
    } finally {
      // 2. ВІДНОВЛЮЄМО МОНІТОР
      _fileMonitorService?.resume();
    }
  }

  Future<void> _handleRemoteFileMove(Map<String, dynamic> data) async {
    final String fileId = data['fileId'];
    final String? targetConnectionId = data['targetConnectionId'];
    final String targetFileName = data['fileName'];

    final index = items.indexWhere((i) => i.id == fileId);
    if (index == -1) return;
    final item = items[index];

    final currentFilesDir = await _getCurrentFilesDir();
    String targetDirPath = currentFilesDir;

    if (targetConnectionId != null) {
      final conn = widget.board?.connections?.firstWhereOrNull(
        (c) => c.id == targetConnectionId,
      );
      if (conn != null) {
        targetDirPath = p.join(currentFilesDir, conn.name);
      }
    }

    final newPath = p.join(targetDirPath, targetFileName);
    if (item.originalPath == newPath) return;

    // --- FIX STARTS HERE: Smart Local File Resolution ---
    File oldFile = File(item.originalPath);
    if (!await oldFile.exists()) {
      // If the stored path (e.g. C:\Users\illia...) doesn't exist, try to find it locally
      final possibleLocalPath = p.join(currentFilesDir, item.fileName);
      if (await File(possibleLocalPath).exists()) {
        logger.i(
          "🔧 Smart Resolve: Found file at $possibleLocalPath instead of ${item.originalPath}",
        );
        oldFile = File(possibleLocalPath);
      } else if (item.connectionId != null) {
        // Check inside the old folder if known
        final oldConn = widget.board?.connections?.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        if (oldConn != null) {
          final oldConnPath = p.join(
            currentFilesDir,
            oldConn.name,
            item.fileName,
          );
          if (await File(oldConnPath).exists()) {
            oldFile = File(oldConnPath);
          }
        }
      }
    }
    // --- FIX ENDS ---

    if (await oldFile.exists()) {
      _fileMonitorService?.ignorePath(oldFile.path); // Ignore ACTUAL path
      _fileMonitorService?.ignorePath(newPath);
      _fileMonitorService?.pause();

      try {
        final dir = Directory(targetDirPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        await oldFile.rename(newPath);
        logger.i(
          "📦 Remote Move Applied: ${p.basename(oldFile.path)} -> $targetFileName",
        );
      } catch (e) {
        logger.e("Failed to move/rename file remotely: $e");
        // Don't return, update UI anyway if file is physically lost but logically moved
      } finally {
        _fileMonitorService?.resume();
      }
    }

    // Update State
    _safeSetState(() {
      items[index] = item.copyWith(
        path: newPath,
        originalPath: newPath,
        shortcutPath: newPath,
        fileName: targetFileName,
        connectionId: targetConnectionId,
      );

      // Update connection lists... (rest of your logic)
      if (item.connectionId != null &&
          item.connectionId != targetConnectionId) {
        widget.board?.connections
            ?.firstWhereOrNull((c) => c.id == item.connectionId)
            ?.itemIds
            .remove(fileId);
      }
      if (targetConnectionId != null) {
        final newConn = widget.board?.connections?.firstWhereOrNull(
          (c) => c.id == targetConnectionId,
        );
        if (newConn != null && !newConn.itemIds.contains(fileId)) {
          newConn.itemIds.add(fileId);
        }
      }
    });

    triggerSaveBoard(); // Use Debounced Save
  }

  List<Connection>? _getVisibleConnections() {
    final allConnections = widget.board?.connections;
    if (allConnections == null) return null;

    if (widget.board?.isConnectionBoard == true) {
      return allConnections;
    }

    return allConnections.where((child) {
      final isHiddenByAnyParent = allConnections.any((possibleParent) {
        if (possibleParent.id == child.id) return false;

        final isAncestor =
            child.itemIds.isNotEmpty &&
            child.itemIds.every((id) => possibleParent.itemIds.contains(id));

        if (!isAncestor) return false;

        return possibleParent.isCollapsed;
      });

      return !isHiddenByAnyParent;
    }).toList();
  }

  void _openFolderAsBoard(Connection folder) {
    // Перевіряємо, чи є куди викликати.
    // Цей колбек зазвичай передається з MainScreen і відкриває новий CanvasBoard для цієї папки.
    if (widget.onOpenConnectionBoard != null) {
      widget.onOpenConnectionBoard!(folder);
    } else {
      debugPrint("Error: onOpenConnectionBoard callback is null");
    }
  }

  void _showFolderCreationFeedback(String folderName) {
    OverlayEntry? entry;

    // Отримуємо перекладені тексти
    final title = S.t('folder_created_title');
    final subMsg = S.t('folder_added_msg');

    entry = OverlayEntry(
      builder:
          (context) => Positioned(
            // Відступ зверху (20% висоти екрану)
            top: MediaQuery.of(context).size.height * 0.2,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack, // Додав "пружну" анімацію
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.8 + (0.2 * value),
                        child: child,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      // Напівпрозорий чорний фон (як ти хотів)
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 15,
                          spreadRadius: 2,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Colors.greenAccent,
                          size: 28,
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "'$folderName' $subMsg", // Формуємо рядок: 'Проект' додано в Explorer
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
    );

    // Вставляємо оверлей
    Overlay.of(context).insert(entry);

    // Прибираємо через 2.5 секунди
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (entry != null && entry.mounted) {
        entry.remove();
      }
    });
  }

  Future<void> _confirmDeleteFolder(Connection conn) async {
    final confirm =
        await showDialog<bool>(
          context: context,
          builder:
              (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text(S.t('delete_folder_title') ?? 'Видалити папку?'),
                content: Text(
                  "Ви впевнені, що хочете видалити папку '${conn.name}' та всі файли в ній?",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(S.t('cancel')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    child: Text(S.t('delete')),
                  ),
                ],
              ),
        ) ??
        false;

    if (confirm) {
      await _deleteFolder(conn);
    }
  }

  Future<void> _deleteFolder(Connection conn) async {
    // 1. Ставимо монітор на паузу, щоб він не сварився на видалення
    _fileMonitorService?.pause();

    try {
      final currentFilesDir = await _getCurrentFilesDir();
      final folderPath = p.join(currentFilesDir, conn.name);
      final dir = Directory(folderPath);

      // 2. Фізичне видалення
      if (await dir.exists()) {
        _fileMonitorService?.ignorePath(folderPath);
        await dir.delete(recursive: true);
      }

      // 3. Оновлення стану (видаляємо папку і файли з UI)
      _safeSetState(() {
        widget.board!.connections!.remove(conn);
        items.removeWhere((item) => item.connectionId == conn.id);
      });

      // 4. Зберігаємо і повідомляємо інших
      await _saveBoard();

      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastFolderDelete(conn.id, conn.name);
        widget.webRTCManager!.broadcastConnectionUpdate(
          widget.board!.connections!,
        );
      }

      _showErrorSnackbar(
        "Папку '${conn.name}' видалено",
      ); // Можна замінити на зелений SnackBar
    } catch (e) {
      logger.e("Error deleting folder via UI: $e");
      _showErrorSnackbar("Помилка видалення папки");
    } finally {
      // 5. Відновлюємо монітор
      _fileMonitorService?.resume();
    }
  }

  Widget _buildExplorer() {
    // Якщо йде пошук - використовуємо стару "плоску" логіку для зручності
    if (_searchQuery.isNotEmpty) {
      return _buildFlatSearchResults();
    }

    // Якщо пошуку немає - будуємо гарне дерево
    return Material(
      color: Colors.white,
      child: Column(
        children: [
          // --- ШАПКА ---
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Icon(Icons.folder_copy_outlined, color: Colors.grey),
                const SizedBox(width: 8),
                const Text(
                  "Explorer",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => _toggleSidebar(SidebarMode.none),
                ),
              ],
            ),
          ),

          // --- ПОШУК ---
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: S.t('search_hint') ?? "Search...",
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),

          // --- ДЕРЕВО ПАПОК ---
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Починаємо будувати дерево з кореня поточної дошки
                if (widget.board?.id != null)
                  ..._buildExplorerTree(widget.board!.id!),

                // Якщо пусто
                if (items.isEmpty &&
                    (widget.board?.connections?.isEmpty ?? true))
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Center(
                      child: Text(
                        S.t('folder_empty') ?? "Empty",
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- НОВИЙ МЕТОД: Рекурсивна побудова дерева ---
  // --- ОНОВЛЕНИЙ МЕТОД З ВІЗУАЛІЗАЦІЄЮ РІВНІВ ---
  List<Widget> _buildExplorerTree(String parentTargetId, {int level = 0}) {
    final allConnections = widget.board?.connections ?? [];

    // 1. Знаходимо папки цього рівня
    final childConnections =
        allConnections.where((c) {
          return c.boardId == parentTargetId;
        }).toList();

    // 2. Знаходимо файли цього рівня
    final childFiles =
        items.where((i) {
          if (!_isNestedFolder && parentTargetId == widget.board?.id) {
            return i.connectionId == null;
          }
          return i.connectionId == parentTargetId;
        }).toList();

    List<Widget> widgets = [];

    // Розрахунок відступу: 16 пікселів базовий + 24 пікселі за кожен рівень вкладеності
    final double indent = 16.0 + (level * 12.0);

    // --- ПАПКИ ---
    for (final conn in childConnections) {
      widgets.add(
        Padding(
          // Додаємо невеликий відступ зліва для всієї папки, якщо це не корінь
          padding: EdgeInsets.only(left: level > 0 ? 12.0 : 0),
          child: Container(
            decoration: BoxDecoration(
              // Візуальна лінія зліва для вкладених папок
              border:
                  level > 0
                      ? Border(
                        left: BorderSide(
                          color: Colors.grey.shade300,
                          width: 1.5,
                        ),
                      )
                      : null,
            ),
            child: Theme(
              key: ValueKey("tree_conn_${conn.id}"),
              data: Theme.of(context).copyWith(
                dividerColor:
                    Colors
                        .transparent, // Прибираємо лінії розділення ExpansionTile
                splashColor: Colors.transparent,
              ),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 0,
                ),
                // Зменшуємо відступи всередині самої плитки
                childrenPadding: EdgeInsets.zero,

                leading: const Icon(
                  Icons.folder,
                  color: Colors.amber,
                  size: 20,
                ),
                title: Text(
                  conn.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.grey[800],
                  ),
                ),
                collapsedIconColor: Colors.grey,
                iconColor: Colors.blue,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.login, size: 16),
                      color: Colors.blue,
                      tooltip: S.t('open'),
                      onPressed: () => _openFolderAsBoard(conn),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      color: Colors.red.withOpacity(0.7),
                      tooltip: S.t('delete'),
                      onPressed: () => _confirmDeleteFolder(conn),
                    ),
                  ],
                ),
                // 🔥 РЕКУРСІЯ: Передаємо рівень + 1
                children: _buildExplorerTree(conn.id, level: level + 1),
              ),
            ),
          ),
        ),
      );
    }

    // --- ФАЙЛИ ---
    for (final file in childFiles) {
      widgets.add(
        Padding(
          // Для файлів робимо відступ трохи більшим, щоб вони були під назвою папки
          padding: EdgeInsets.only(left: indent),
          child: Container(
            decoration: BoxDecoration(
              // Лінія зліва, щоб візуально прив'язати файл до гілки дерева
              border: Border(
                left: BorderSide(
                  color: level > 0 ? Colors.grey.shade300 : Colors.transparent,
                  width: 1.5,
                ),
              ),
            ),
            child: ListTile(
              key: ValueKey("tree_file_${file.id}"),
              dense: true,
              visualDensity:
                  VisualDensity.compact, // Робимо рядки компактнішими
              contentPadding: const EdgeInsets.only(left: 12.0, right: 8.0),

              leading: _getFileIcon(
                file.type,
              ), // Твій метод іконки (можна зменшити розмір всередині методу)

              title: Text(
                file.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  // Кореневі файли трохи темніші/важливіші, вкладені — світліші
                  color: level == 0 ? Colors.black87 : Colors.black54,
                  fontWeight: level == 0 ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
              onTap: () {
                scrollToItem(file);
                _safeSetState(() => selectedItem = file);
              },
              trailing: IconButton(
                icon: Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: Colors.grey[400],
                ),
                onPressed: () => _openFile(file),
              ),
            ),
          ),
        ),
      );
    }

    return widgets;
  }

  // --- Старий метод для пошуку (Плоский список) ---
  Widget _buildFlatSearchResults() {
    // Тут твоя старая логіка фільтрації, я виніс її в окремий віджет для чистоти
    final filter = _searchQuery.toLowerCase();
    final allConnections = widget.board?.connections ?? [];

    final filteredConnections =
        allConnections.where((c) {
          if (c.name.toLowerCase().contains(filter)) return true;
          final filesInFolder = items.where((i) => i.connectionId == c.id);
          return filesInFolder.any(
            (f) => f.fileName.toLowerCase().contains(filter),
          );
        }).toList();

    final filteredFiles =
        items.where((i) {
          return i.fileName.toLowerCase().contains(filter);
        }).toList();

    return Material(
      color: Colors.white,
      child: Column(
        children: [
          // Шапка і пошук (дублюються або можна винести в обгортку)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Icon(Icons.search, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  "Search: $_searchQuery",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _searchQuery = "";
                      _searchController.clear();
                    });
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: ListView(
              children: [
                ...filteredConnections.map((conn) {
                  // ... твоя стара логіка відображення папок ...
                  // (скопіюй вміст map з твого попереднього коду, якщо хочеш зберегти дизайн пошуку)
                  return ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(conn.name),
                    onTap: () => _openFolderAsBoard(conn),
                  );
                }),
                ...filteredFiles.map((file) {
                  return ListTile(
                    leading: _getFileIcon(file.type),
                    title: Text(file.fileName),
                    onTap: () => scrollToItem(file),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Допоміжний метод для іконок (якщо у вас його ще немає окремо)
  Widget _getFileIcon(String type) {
    return const Icon(Icons.insert_drive_file, color: Colors.white54, size: 20);
  }

  Future<String> _getCurrentFilesDir() async {
    // 1. Якщо це головна дошка - ЗАВЖДИ повертаємо корінь файлів дошки.
    // Не намагаємося вгадати папку по файлах, бо файли можуть бути переміщені у підпапки!
    if (!_isNestedFolder && widget.board?.id != null) {
      return await BoardStorage.getBoardFilesDirAuto(widget.board!.id!);
    }

    // 2. Якщо ми зараз всередині папки (isConnectionBoard == true),
    // то нам треба шлях саме цієї папки.
    if (_isNestedFolder && items.isNotEmpty) {
      // Тут старий метод допустимий, бо ми дійсно всередині папки,
      // і всі файли тут мають бути в одному місці.
      // АЛЕ краще брати шлях з widget.board path, якщо ти його передаєш.
      // Поки лишаємо так для вкладеності, але з перевіркою:
      final firstFile = items.first;
      return p.dirname(firstFile.originalPath);
    }

    // Fallback
    return await BoardStorage.getBoardFilesDirAuto(widget.board!.id!);
  }
  // void _createVisualLinksFromSelection() {
  //   _safeSetState(() {
  //     widget.board?.links ??= [];
  //     for (int i = 0; i < _linkItems.length - 1; i++) {
  //       final from = _linkItems[i];
  //       final to = _linkItems[i + 1];
  //       final exists = widget.board!.links!.any(
  //         (l) => l.fromItemId == from.id && l.toItemId == to.id,
  //       );
  //       if (!exists) {
  //         final link = BoardLink(
  //           id: UniqueKey().toString(),
  //           fromItemId: from.id,
  //           toItemId: to.id,
  //           colorValue:
  //               _currentArrowColor.value,
  //           strokeWidth: _currentArrowWidth,
  //         );
  //         widget.board!.links!.add(link);
  //       }
  //     }
  //     // Очищаємо список, щоб прибрати світіння
  //     _linkItems.clear();
  //   });
  //   _saveBoard();
  // }

  Future<void> _showAddToFolderDialog(BoardItem item) async {
    final connections = widget.board?.connections;
    if (connections == null || connections.isEmpty) return;

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                S.t('add_to_folder'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ), //
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children:
                      connections
                          .map(
                            (conn) => ListTile(
                              leading: Icon(
                                Icons.folder,
                                color: Color(conn.colorValue),
                              ),
                              title: Text(conn.name),
                              subtitle: Text(
                                "${conn.itemIds.length} ${S.t('objects')}",
                              ), //
                              onTap: () {
                                Navigator.pop(ctx);
                                _addItemToFolder(item, conn);
                              },
                            ),
                          )
                          .toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _createNewFile() async {
    final List<String>? result = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        final nameController = TextEditingController();
        final extController = TextEditingController();
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(S.t('create_file')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(labelText: S.t('file_name')),
              ),
              TextField(
                controller: extController,
                decoration: InputDecoration(labelText: S.t('format')),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(S.t('cancel')),
            ),
            ElevatedButton(
              onPressed:
                  () => Navigator.pop(context, [
                    nameController.text.trim(),
                    extController.text.trim(),
                  ]),
              child: Text(S.t('create')),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    String name = result[0];
    String ext = result[1].replaceAll('.', '');
    final String fullFileName = '$name.$ext';

    if (widget.board?.id == null) return;

    _locallyProcessingFiles.add(fullFileName.toLowerCase());

    try {
      final currentDir = await _getCurrentFilesDir();
      String filePath = p.join(currentDir, fullFileName);

      final dir = io.Directory(currentDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      int counter = 1;
      while (await io.File(filePath).exists()) {
        filePath = p.join(currentDir, '${name}_$counter.$ext');
        counter++;
      }

      final finalFileName = p.basename(filePath);
      if (finalFileName != fullFileName) {
        _locallyProcessingFiles.add(finalFileName.toLowerCase());
      }

      // 🔥 ЗАХИСТ МОНІТОРА
      // 1. Ігноруємо повний шлях до нового файлу
      _fileMonitorService?.ignorePath(filePath);
      // 2. Пауза
      _fileMonitorService?.pause();

      try {
        final file = io.File(filePath);
        await file.create();
      } finally {
        // 3. Відновлення
        _fileMonitorService?.resume();
      }

      Offset centerPos = _canvasCenter();
      if (_canvasSize != null) {
        centerPos = (_canvasCenter() - offset) / scale;
        centerPos += Offset(items.length * 20.0, items.length * 20.0);
      }

      final newItem = BoardItem(
        id: UniqueKey().toString(),
        path: filePath,
        shortcutPath: filePath,
        originalPath: filePath,
        position: centerPos,
        type: ext.toLowerCase(),
        fileName: finalFileName,
        connectionId: _isNestedFolder ? widget.board?.id : null,
      );

      _safeSetState(() => items.add(newItem));
      _broadcastItemAdd(item: newItem);
      _streamFileToPeers(newItem, filePath);
      await _saveBoard();
    } catch (e) {
      _showErrorSnackbar("Помилка створення файлу: $e");
    } finally {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _locallyProcessingFiles.remove(fullFileName.toLowerCase());
      });
    }
  }

  void _addItemToFolder(BoardItem item, Connection folder) {
    _safeSetState(() {
      if (item.connectionId != null && item.connectionId != folder.id) {
        final old = widget.board?.connections?.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        old?.itemIds.remove(item.id);
      }
      item.connectionId = folder.id;
      if (!folder.itemIds.contains(item.id)) {
        folder.itemIds.add(item.id);
      }
    });
    _saveBoard();
  }

  void _toggleFolder(Connection folder) {
    _safeSetState(() {
      folder.isCollapsed = !folder.isCollapsed;
      if (folder.isCollapsed) {
        final firstItem = items.firstWhereOrNull(
          (i) => i.id == folder.itemIds.first,
        );
        folder.collapsedPosition =
            firstItem?.position ?? const Offset(100, 100);
      }
    });
  }

  Future<void> _saveBoard() async {
    // 🔥 FIX: РАДИКАЛЬНА ПЕРЕВІРКА
    // Якщо у нас є колбек onBoardUpdated, це означає, що ми знаходимось у вкладеній дошці (папці).
    // У цьому випадку ми НІКОЛИ не повинні зберігати дані на диск напряму.
    // Ми лише передаємо оновлений стан батьківській дошці через колбек.
    if (widget.onBoardUpdated != null) {
      if (widget.board != null) {
        widget.board!.items = List.from(items);
        widget.board!.connections ??= [];

        // Передаємо зміни нагору (в Main Screen або батьківську дошку)
        widget.onBoardUpdated!(widget.board!);
        logger.i("📤 Nested board updated via callback. Storage skipped.");
      }
      return; // ⛔️ STOP. Далі не йдемо.
    }

    // Якщо ми тут — значить, це ГОЛОВНА дошка (root board).
    if (!mounted || widget.board == null) return;

    try {
      widget.board!.items = List.from(items);
      widget.board!.connections ??= [];

      // Зберігаємо на диск тільки головну дошку
      await BoardStorage.saveBoard(widget.board!);

      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastConnectionUpdate(
          widget.board!.connections!,
        );

        if (widget.board!.description != null) {
          widget.webRTCManager!.broadcastBoardDescriptionUpdate(
            widget.board!.description!,
          );
        }
      }
    } catch (e) {
      logger.e("❌ Помилка збереження дошки: \$e");
    }
  }

  void _broadcastItemAdd({required BoardItem item}) {
    if (widget.webRTCManager == null) return;
    widget.webRTCManager!.broadcastItemAdd(item);
  }

  Future<void> _streamFileToPeers(BoardItem item, String originalPath) async {
    if (widget.webRTCManager == null) return;
    try {
      final file = File(originalPath);
      final fileName = item.fileName;
      if (!await file.exists()) {
        return;
      }
      await widget.webRTCManager!.broadcastFile(
        originalPath,
        fileName,
        file,
        customFileId: item.id,
      );
    } catch (e) {
      logger.e('Error streaming file ${item.fileName}: $e');
    }
  }

  void _showBlockedUsersDialog() {
    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              final blockedIds = widget.board!.blockedPublicIds;
              return AlertDialog(
                title: Row(
                  children: [
                    const Icon(Icons.block, color: Colors.red),
                    const SizedBox(width: 10),
                    Text(S.t('blocked_ids')),
                  ],
                ), //
                content: SizedBox(
                  width: 400,
                  height: 350,
                  child:
                      blockedIds.isEmpty
                          ? Center(child: Text(S.t('blacklist_empty'))) //
                          : ListView.builder(
                            itemCount: blockedIds.length,
                            itemBuilder:
                                (context, index) => ListTile(
                                  title: Text(
                                    blockedIds[index],
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    tooltip: S.t('unblock'), //
                                    onPressed: () {
                                      setState(
                                        () => widget.board!.blockedPublicIds
                                            .remove(blockedIds[index]),
                                      );
                                      setDialogState(() {});
                                      _saveBoard();
                                    },
                                  ),
                                ),
                          ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(S.t('close')),
                  ),
                ],
              );
            },
          ),
    );
  }

  // Future<void> _syncOrphanFiles() async {
  //   if (widget.board?.id == null) return;

  //   await Future.delayed(const Duration(milliseconds: 500));
  //   if (!mounted) return;

  //   try {
  //     String filesDir;
  //     if (_isNestedFolder) {
  //       filesDir = await BoardStorage.getBoardFilesDirAuto(widget.board!.id!);
  //     } else {
  //       filesDir = await BoardStorage.getBoardFilesDirAuto(widget.board!.id!);
  //     }

  //     final dir = Directory(filesDir);
  //     if (!await dir.exists()) return;

  //     List<BoardItem> restoredItems = [];

  //     await for (var entity in dir.list()) {
  //       if (entity is File) {
  //         final fileName = p.basename(entity.path);
  //         if (fileName.startsWith('.')) continue;

  //         final exists = items.any(
  //           (i) =>
  //               i.fileName == fileName ||
  //               p.basename(i.originalPath) == fileName,
  //         );

  //         if (!exists) {
  //           logger.i("🛠️ Found orphan file: $fileName. Restoring...");

  //           final ext = p.extension(fileName).replaceAll('.', '').toLowerCase();

  //           String? connId = _isNestedFolder ? widget.board?.id : null;

  //           restoredItems.add(
  //             BoardItem(
  //               id: UniqueKey().toString(),
  //               path: entity.path,
  //               shortcutPath: entity.path,
  //               originalPath: entity.path,
  //               position: Offset(
  //                 150.0 + (restoredItems.length * 30),
  //                 150.0 + (restoredItems.length * 30),
  //               ),
  //               type: ext.isEmpty ? 'file' : ext,
  //               fileName: fileName,
  //               connectionId: connId,
  //             ),
  //           );
  //         }
  //       }
  //     }

  //     if (restoredItems.isNotEmpty) {
  //       _safeSetState(() {
  //         items.addAll(restoredItems);
  //       });
  //       _saveBoard();

  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(
  //           content: Text("Відновлено ${restoredItems.length} файлів"),
  //           duration: const Duration(seconds: 3),
  //           backgroundColor: Colors.green,
  //         ),
  //       );
  //     }
  //   } catch (e) {
  //     logger.e("Error syncing orphan files: $e");
  //   }
  // }

  void _pickFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );

      if (result != null && result.paths.isNotEmpty) {
        if (widget.board?.id == null) return;
        List<BoardItem> newItems = [];

        final currentDir = await _getCurrentFilesDir();
        await Directory(currentDir).create(recursive: true);

        for (String? originalPath in result.paths) {
          if (originalPath != null && originalPath.isNotEmpty) {
            final file = File(originalPath);
            if (!await file.exists()) continue;

            final fileName = p.basename(originalPath);
            final ext = p.extension(fileName);
            final nameNoExt = p.basenameWithoutExtension(fileName);

            String finalFileName = fileName;
            String destinationPath = p.join(currentDir, finalFileName);
            int counter = 1;

            while (await File(destinationPath).exists()) {
              finalFileName = '${nameNoExt}_$counter$ext';
              destinationPath = p.join(currentDir, finalFileName);
              counter++;
            }

            _locallyProcessingFiles.add(finalFileName.toLowerCase());

            // Ігноруємо повний шлях призначення
            _fileMonitorService?.ignorePath(destinationPath);
            // Пауза перед копіюванням
            _fileMonitorService?.pause();

            try {
              await file.copy(destinationPath);

              // ... (створення BoardItem) ...
              final fileType = ext.replaceFirst('.', '').toLowerCase();
              final newItem = BoardItem(
                id: UniqueKey().toString(),
                path: destinationPath,
                shortcutPath: destinationPath,
                originalPath: destinationPath,
                position: Offset(
                  100,
                  100 + (items.length + newItems.length) * 120,
                ),
                type: fileType,
                fileName: finalFileName,
                connectionId: _isNestedFolder ? widget.board?.id : null,
              );
              newItems.add(newItem);
              _broadcastItemAdd(item: newItem);
              _streamFileToPeers(newItem, destinationPath);
            } catch (e) {
              logger.e("Помилка копіювання файлу: $e");
            } finally {
              // Відновлюємо
              _fileMonitorService?.resume();

              Future.delayed(const Duration(seconds: 3), () {
                if (mounted) {
                  _locallyProcessingFiles.remove(finalFileName.toLowerCase());
                }
              });
            }
          }
        }
        if (newItems.isNotEmpty) {
          _safeSetState(() => items.addAll(newItems));
          await _saveBoard();
        }
      }
    } catch (e) {
      _showErrorSnackbar('Не вдалося вибрати файли: $e');
    }
  }

  Future<bool> _confirmAddDuplicate(String fileName) async {
    return await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: const Text('Файл вже існує'),
                content: Text(
                  '"$fileName" вже доданий на дошку. Додати знову?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Скасувати'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Додати'),
                  ),
                ],
              ),
        ) ??
        false;
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showMapOverlay() {
    setState(() => _isMapOpen = true);

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Map",
      barrierColor: Colors.black.withOpacity(0.6),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final mapWidth = MediaQuery.of(context).size.width * 0.7;
                final mapHeight = MediaQuery.of(context).size.height * 0.7;

                return Container(
                  width: mapWidth,
                  height: mapHeight,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (details) {
                        _navigateToPointOnMap(
                          details.localPosition,
                          Size(mapWidth, mapHeight),
                        );
                        Navigator.pop(context);
                      },
                      child: CustomPaint(
                        size: Size(mapWidth, mapHeight),
                        painter: BoardMiniMapPainter(
                          items: items,
                          themeColor: const Color(0xFF009688),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      setState(() => _isMapOpen = false);
    });
  }

  void _navigateToPointOnMap(Offset tapPos, Size mapSize) {
    if (items.isEmpty) return;

    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (var item in items) {
      if (item.position.dx < minX) minX = item.position.dx;
      if (item.position.dx > maxX) maxX = item.position.dx;
      if (item.position.dy < minY) minY = item.position.dy;
      if (item.position.dy > maxY) maxY = item.position.dy;
    }

    maxX += 100;
    maxY += 100;
    const double contentPadding = 200.0;
    minX -= contentPadding;
    minY -= contentPadding;
    maxX += contentPadding;
    maxY += contentPadding;

    final double contentWidth = maxX - minX;
    final double contentHeight = maxY - minY;

    final double scaleX = mapSize.width / contentWidth;
    final double scaleY = mapSize.height / contentHeight;
    final double mapScale = min(scaleX, scaleY);

    final double mapOffsetX = (mapSize.width - contentWidth * mapScale) / 2;
    final double mapOffsetY = (mapSize.height - contentHeight * mapScale) / 2;

    final double targetX = (tapPos.dx - mapOffsetX) / mapScale + minX;
    final double targetY = (tapPos.dy - mapOffsetY) / mapScale + minY;
    final Offset targetPoint = Offset(targetX, targetY);

    setState(() {
      offset = -targetPoint * scale;
    });
  }

  Future<void> _deleteItemFile(BoardItem item) async {
    try {
      final file = File(item.path);

      // 🔥 FIX: Якщо ми самі видаляємо файл, монітор має мовчати
      _fileMonitorService?.ignorePath(item.path);
      _fileMonitorService?.pause();

      try {
        if (await file.exists()) await file.delete();

        if (item.originalPath != item.path) {
          final orig = File(item.originalPath);
          // Ігноруємо також оригінальний шлях, якщо він відрізняється
          _fileMonitorService?.ignorePath(item.originalPath);
          if (await orig.exists()) await orig.delete();
        }
      } finally {
        _fileMonitorService?.resume();
      }
    } catch (_) {}
  }

  Future<void> _cleanupCurrentBoardFiles() async {}

  void _cleanUpConnections() {
    widget.board?.connections?.removeWhere((connection) {
      connection.itemIds.removeWhere(
        (id) => !items.any((item) => item.id == id),
      );
      return connection.itemIds.isEmpty;
    });
    for (final item in items) {
      if (item.connectionId != null) {
        if (widget.board?.connections?.any((c) => c.id == item.connectionId) !=
            true) {
          item.connectionId = null;
        }
      }
    }
  }

  void _showArrowSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        Color selectedColor = _currentArrowColor;
        double selectedWidth = _currentArrowWidth;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(S.t('arrow_settings_title')),
              contentPadding: const EdgeInsets.all(20),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      S.t('arrow_thickness'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Slider(
                      value: selectedWidth,
                      min: 1.0,
                      max: 10.0,
                      divisions: 9,
                      label: selectedWidth.toString(),
                      onChanged: (val) {
                        setDialogState(() => selectedWidth = val);
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      S.t('arrow_color'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),

                    RainbowColorPicker(
                      selectedColor: selectedColor,
                      onColorChanged: (newColor) {
                        setDialogState(() => selectedColor = newColor);
                      },
                    ),

                    const SizedBox(height: 20),
                    Text(
                      S.t('preview_label'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 40,
                      width: double.infinity,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Container(
                        height: selectedWidth,
                        width: 200,
                        decoration: BoxDecoration(
                          color: selectedColor,
                          borderRadius: BorderRadius.circular(selectedWidth),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(S.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _currentArrowColor = selectedColor;
                      _currentArrowWidth = selectedWidth;
                    });
                    Navigator.pop(context);
                  },
                  child: Text(S.t('save')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Offset _localToItemSpace(Offset localPos) {
    if (_canvasSize == null) return Offset.zero;
    final center = Offset(_canvasSize!.width / 2, _canvasSize!.height / 2);
    return (localPos - center - offset) / scale;
  }

  BoardItem? _hitTest(
    Offset globalPos, {
    double hitAreaWidth = 100.0,
    double hitAreaHeight = 100.0,
  }) {
    if (_canvasSize == null) return null;

    final itemPos = _localToItemSpace(globalPos);

    for (final item in items.reversed) {
      if (item.connectionId != null) {
        final conn = widget.board?.connections?.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        if (conn != null && conn.isCollapsed) continue;
      }

      final itemRect = Rect.fromLTWH(
        item.position.dx,
        item.position.dy,
        hitAreaWidth,
        hitAreaHeight,
      );
      if (itemRect.contains(itemPos)) return item;
    }
    return null;
  }

  BoardLink? _hitTestLink(Offset globalPos) {
    if (widget.board?.links == null) return null;
    final localPos = _localToItemSpace(globalPos);

    for (final link in widget.board!.links!) {
      final from = items.firstWhereOrNull((i) => i.id == link.fromItemId);
      final to = items.firstWhereOrNull((i) => i.id == link.toItemId);
      if (from == null || to == null) continue;

      final center1 = from.position + const Offset(50, 50);
      final center2 = to.position + const Offset(50, 50);

      final start = _getRectIntersection(center1, center2, 50.0);
      final end = _getRectIntersection(center2, center1, 50.0);

      final double dist = _distanceToSegment(localPos, start, end);

      if (dist < 10.0) {
        return link;
      }
    }
    return null;
  }

  Offset _getRectIntersection(Offset from, Offset to, double halfSize) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;

    if (dx == 0 && dy == 0) return from;

    double scaleX =
        (dx != 0) ? (dx > 0 ? halfSize : -halfSize) / dx : double.infinity;
    double scaleY =
        (dy != 0) ? (dy > 0 ? halfSize : -halfSize) / dy : double.infinity;

    double scale = (scaleX.abs() < scaleY.abs()) ? scaleX : scaleY;

    return from + Offset(dx * scale, dy * scale);
  }

  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    double t =
        ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = max(0, min(1, t));
    final Offset projection = Offset(
      a.dx + t * (b.dx - a.dx),
      a.dy + t * (b.dy - a.dy),
    );
    return (p - projection).distance;
  }

  Offset _globalToItemSpace(Offset globalPos) {
    if (_canvasSize == null) return Offset.zero;
    final center = Offset(_canvasSize!.width / 2, _canvasSize!.height / 2);
    return (globalPos - center - offset) / scale;
  }

  Offset _canvasCenter() {
    return _canvasSize != null
        ? Offset(_canvasSize!.width / 2, _canvasSize!.height / 2)
        : Offset.zero;
  }

  void _showContextMenu(Offset screenPos) async {
    final link = _hitTestLink(screenPos);
    if (link != null) {
      final renderBox = context.findRenderObject() as RenderBox;
      final globalPos = renderBox.localToGlobal(screenPos);

      await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPos.dx,
          globalPos.dy,
          _canvasSize!.width - globalPos.dx,
          _canvasSize!.height - globalPos.dy,
        ),
        items: [
          PopupMenuItem(
            child: Text(
              S.t('delete_arrow'),
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () {
              _safeSetState(() {
                widget.board?.links?.remove(link);
              });
              _saveBoard();
            },
          ),
        ],
      );
      return;
    }

    final item = _hitTest(screenPos);
    if (item == null) return;

    final bool isInsideFolderBoard = _isNestedFolder;

    final parentConnection = widget.board?.connections?.firstWhereOrNull(
      (c) => c.itemIds.contains(item.id),
    );

    if (!isInsideFolderBoard &&
        parentConnection != null &&
        item.connectionId == null) {
      item.connectionId = parentConnection.id;
    }

    _safeSetState(() {
      selectedItem = item;
      _isSpacePressed = false;
      _isCtrlPressed = false;
      _isAltPressed = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_isMounted || _canvasSize == null) return;

      final renderBox = context.findRenderObject() as RenderBox;
      final globalMenuPos = renderBox.localToGlobal(screenPos);

      final bool isRootHost = _isHost && widget.onOpenConnectionBoard != null;

      await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(
          globalMenuPos.dx,
          globalMenuPos.dy,
          _canvasSize!.width - globalMenuPos.dx,
          _canvasSize!.height - globalMenuPos.dy,
        ),
        items: [
          PopupMenuItem(child: Text(S.t('open')), onTap: () => _openFile(item)),

          PopupMenuItem(
            child: Text(S.t('add_tag')),
            onTap: () => _showTagDialog(item),
          ),

          PopupMenuItem(
            child: Text(
              S.t('delete_file'),
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () {
              widget.webRTCManager?.broadcastItemDelete(item.id);
              _safeSetState(() {
                _deleteItemFile(item);
                items.remove(item);

                // 🔥 ВИПРАВЛЕННЯ ТУТ 🔥
                // Якщо ми на головній дошці — робимо повну чистку.
                // Якщо ми в папці — НЕ МОЖНА викликати _cleanUpConnections(),
                // бо вона видалить файли з усіх інших папок (оскільки items тут неповний).
                if (!isInsideFolderBoard) {
                  _cleanUpConnections();
                } else {
                  // В папці ми вручну видаляємо ID тільки з поточної папки
                  final currentFolderId = widget.board?.id;
                  if (currentFolderId != null) {
                    final folderConn = widget.board?.connections
                        ?.firstWhereOrNull((c) => c.id == currentFolderId);
                    folderConn?.itemIds.remove(item.id);
                  }
                }

                selectedItem = null;
              });
              _saveBoard();
            },
          ),
        ],
      );

      if (_isMounted) {
        _safeSetState(() {
          selectedItem = null;
        });
      }
    });
  }

  List<String> _getAllExistingTags() {
    final allTags = <String>{};
    for (final item in items) {
      allTags.addAll(item.tags);
    }
    return allTags.toList()..sort();
  }

  Future<void> _showTagDialog(BoardItem item) async {
    final itemIndex = items.indexWhere((i) => i.id == item.id);
    if (itemIndex == -1) return;

    String newTag = '';
    final allTags = _getAllExistingTags();
    List<String> tempTags = List.from(item.tags);

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('${S.t('tags_for')} ${item.fileName}'),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        hintText: S.t('enter_new_tag'),
                        prefixText: '#',
                      ),
                      onChanged: (value) => newTag = value.trim(),
                    ),
                    const SizedBox(height: 16),
                    if (allTags.isNotEmpty) ...[
                      Text(
                        S.t('existing_tags'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children:
                            allTags.map((tag) {
                              final isSelected = tempTags.contains(tag);
                              return GestureDetector(
                                onTap: () {
                                  setStateDialog(() {
                                    if (isSelected) {
                                      tempTags.remove(tag);
                                    } else {
                                      tempTags.add(tag);
                                    }
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        isSelected
                                            ? Colors.blue[400]
                                            : Colors.grey[300],
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    '#$tag',
                                    style: TextStyle(
                                      color:
                                          isSelected
                                              ? Colors.white
                                              : Colors.black,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(S.t('cancel')),
                ),
                TextButton(
                  onPressed: () {
                    if (newTag.isNotEmpty && !tempTags.contains(newTag)) {
                      tempTags.add(newTag);
                    }

                    _safeSetState(() {
                      items[itemIndex] = items[itemIndex].copyWith(
                        tags: tempTags,
                      );
                    });

                    _saveBoard();
                    Navigator.pop(context);
                  },
                  child: Text(S.t('save')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _updateItemPath(BoardItem item, String newPath) {
    final index = items.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      if (items[index].originalPath != newPath) {
        _safeSetState(() {
          items[index] = items[index].copyWith(originalPath: newPath);
        });
        _saveBoard();
      }
    }
  }

  // У файлі lib/screens/board.dart

  // board.dart

  Future<void> _openFile(BoardItem item) async {
    // Якщо файл ще вантажиться
    if (_incomingFileWriters.containsKey(item.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⏳ Файл ще завантажується...'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    try {
      logger.i("📂 Attempting to open: ${item.originalPath}");

      File fileToOpen = File(item.originalPath);
      bool exists = await fileToOpen.exists();
      logger.i("🔍 Exists strictly at path? $exists");

      // РОЗУМНИЙ ПОШУК (Smart Resolve)
      if (!exists && widget.board?.id != null) {
        logger.i("⚠️ File not found at strict path. Trying smart resolve...");

        final dirName = widget.board!.id!;
        final boardDir = await BoardStorage.getBoardFilesDirAuto(dirName);
        final fileName = p.basename(item.fileName); // Використовуємо чисте ім'я

        // Список кандидатів, де може бути файл
        List<String> candidates = [
          p.join(boardDir, fileName), // В корені дошки
          p.join(boardDir, item.id), // По ID (рідко, але буває)
        ];

        // Якщо файл приписаний до папки, шукаємо там
        if (item.connectionId != null) {
          final conn = widget.board?.connections?.firstWhereOrNull(
            (c) => c.id == item.connectionId,
          );
          if (conn != null) {
            candidates.insert(
              0,
              p.join(boardDir, conn.name, fileName),
            ); // Пріоритет: папка
          }
        }

        for (final path in candidates) {
          if (await File(path).exists()) {
            logger.i("✅ Found file at alternative path: $path");
            fileToOpen = File(path);
            // Оновлюємо шлях в моделі, щоб наступного разу відкрилось миттєво
            _updateItemPath(item, path);
            exists = true;
            break;
          }
        }
      }

      if (!exists) {
        logger.e("❌ File physically missing.");
        _showErrorSnackbar('Файл не знайдено фізично. Запитую у хоста...');
        // Запит відновлення файлу
        widget.webRTCManager?.requestFile('broadcast', item.id, item.fileName);
        return;
      }

      // Відкриття
      final uri = Uri.file(fileToOpen.path);
      logger.i("🚀 Launching: $uri");

      if (!await launchUrl(uri)) {
        // Fallback для десктопів
        if (Platform.isWindows) {
          await Process.run('explorer', [fileToOpen.path]);
        } else if (Platform.isMacOS) {
          await Process.run('open', [fileToOpen.path]);
        } else if (Platform.isLinux) {
          await Process.run('xdg-open', [fileToOpen.path]);
        }
      }
    } catch (e) {
      logger.e("Open Error: $e");
      _showErrorSnackbar('Помилка відкриття: $e');
    }
  }

  Future<void> _launchFile(String path) async {
    final uri = Uri.file(path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (Platform.isWindows) {
        await Process.run('explorer', [path], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path], runInShell: false);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path], runInShell: false);
      }
    }
  }

  Color _generateConnectionColor(String id) {
    final hash = id.hashCode;
    return HSLColor.fromAHSL(1.0, (hash % 360).toDouble(), 0.7, 0.6).toColor();
  }

  void _handleDoubleTap(Offset globalPos) {
    final folder = _hitTestCollapsedFolder(globalPos);
    if (folder != null) {
      if (_isFPressed) {
        _toggleFolder(folder);
      } else {
        widget.onOpenConnectionBoard?.call(folder);
      }
      return;
    }

    final item = _hitTest(globalPos);
    if (item != null) {
      if (_isFPressed && item.connectionId != null) {
        final conn = widget.board?.connections?.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        if (conn != null) {
          _safeSetState(() {
            conn.isCollapsed = true;
            conn.collapsedPosition = item.position;
          });
          _saveBoard();
          return;
        }
      }

      if (_isAltPressed) {
        _showNotesDialog(item);
      } else {
        _openFile(item);
      }
    }
  }

  void _handleTapDown(TapDownDetails details) {
    if (_isArrowCreationMode) return;
    lastTapPosition = details.localPosition;
    final now = DateTime.now();
    if (lastTapTime != null &&
        now.difference(lastTapTime!) < const Duration(milliseconds: 300)) {
      tapCount++;
    } else {
      tapCount = 1;
    }
    lastTapTime = now;

    if (tapCount == 2) {
      _handleDoubleTap(details.localPosition);
      tapCount = 0;
      return;
    }

    final folder = _hitTestCollapsedFolder(details.localPosition);
    if (folder != null) {
      _safeSetState(() => selectedItem = null);
      return;
    }

    final item = _hitTest(
      details.localPosition,
      hitAreaWidth: 100.0,
      hitAreaHeight: 100.0,
    );

    if (_isFPressed && item != null) {
      _safeSetState(() {
        if (_folderSelection.contains(item)) {
          _folderSelection.remove(item);
        } else {
          _folderSelection.add(item);
        }
      });
      return;
    }

    if (item != null) {
      _safeSetState(() => selectedItem = item);
    } else {
      _safeSetState(() => selectedItem = null);
    }
  }

  Connection? _getConnectionsContainingItem(BoardItem item) {
    if (item.connectionId == null) return null;
    return widget.board?.connections?.firstWhereOrNull(
      (conn) => conn.id == item.connectionId,
    );
  }

  Connection? _hitTestCollapsedFolder(Offset localPos) {
    if (widget.board?.connections == null) return null;
    final itemPos = _localToItemSpace(localPos);

    for (final conn in widget.board!.connections!) {
      if (conn.isCollapsed && conn.collapsedPosition != null) {
        final folderRect = Rect.fromLTWH(
          conn.collapsedPosition!.dx,
          conn.collapsedPosition!.dy,
          100.0,
          100.0,
        );
        if (folderRect.contains(itemPos)) return conn;
      }
    }
    return null;
  }

  void _showNotesDialog(BoardItem item) {
    _isAltPressed = false;

    final TextEditingController controller = TextEditingController(
      text: item.notes ?? '',
    );
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(S.t('notes')),
            content: TextField(
              controller: controller,
              maxLines: null,
              decoration: InputDecoration(hintText: S.t('enter_note_hint')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(S.t('cancel')),
              ),
              TextButton(
                onPressed: () {
                  _safeSetState(() {
                    item.notes = controller.text;
                  });
                  _saveBoard();
                  Navigator.pop(context);
                },
                child: Text(S.t('save')),
              ),
            ],
          ),
    );
  }

  void _removeItemFromConnection(BoardItem item) {
    if (item.connectionId == null) return;
    final connection = widget.board?.connections?.firstWhereOrNull(
      (c) => c.id == item.connectionId,
    );
    _safeSetState(() {
      connection?.itemIds.remove(item.id);
      item.connectionId = null;
      _cleanUpConnections();
    });
    _saveBoard();
  }

  Widget _buildSidebarBtn({
    required SidebarMode mode,
    required IconData icon,
    required String tooltip,
  }) {
    return _BoardActionButton(
      icon: icon,
      tooltip: tooltip,
      isActive: _sidebarMode == mode,
      onPressed: () => _toggleSidebar(mode),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        // 1. Скасовуємо таймер, щоб він не спрацював під час нашого запису
        _saveDebounceTimer?.cancel();

        try {
          if (widget.board != null && !_isNestedFolder) {
            // Оновлюємо модель актуальними даними
            widget.board!.items = List.from(items);
            widget.board!.connections ??= [];

            // Чекаємо завершення запису
            await BoardStorage.saveBoard(widget.board!);
            logger.i("✅ Board saved successfully on exit");
          }
        } catch (e) {
          logger.e("Error saving on exit: $e");
        }

        if (mounted) {
          Navigator.pop(context);
        }
      },
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    _canvasSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return DropTarget(
                      onDragDone: (details) {
                        final renderBox =
                            context.findRenderObject() as RenderBox;
                        final localPos = renderBox.globalToLocal(
                          details.globalPosition,
                        );
                        _handleFileDrop(details.files, localPos);
                      },
                      child: Listener(
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent &&
                              event.scrollDelta.dy != 0 &&
                              event.kind == PointerDeviceKind.mouse) {
                            final oldScale = scale;
                            final focalPoint = event.localPosition;
                            final delta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                            double newScale = scale * delta;
                            if (newScale < 0.5) newScale = 0.5;
                            if (newScale > 5.0) newScale = 5.0;

                            final center = Offset(
                              _canvasSize!.width / 2,
                              _canvasSize!.height / 2,
                            );
                            final focalPointScene =
                                (focalPoint - center - offset) / oldScale;

                            _safeSetState(() {
                              scale = newScale;
                              offset =
                                  focalPoint -
                                  center -
                                  focalPointScene * newScale;
                            });
                          }
                        },
                        onPointerDown: (event) {
                          if (event.kind == PointerDeviceKind.mouse &&
                              event.buttons == kSecondaryMouseButton) {
                            _showContextMenu(event.localPosition);
                          } else if (event.kind == PointerDeviceKind.mouse &&
                              event.buttons == kPrimaryMouseButton) {
                            final item = _hitTest(event.localPosition);
                            if (item == null && !_isArrowCreationMode) {
                              _safeSetState(() => selectedItem = null);
                            }
                          }
                        },
                        child: Focus(
                          focusNode: _focusNode,
                          autofocus: true,
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent || event is KeyUpEvent) {
                              final isSpacePressed =
                                  event.logicalKey == LogicalKeyboardKey.space;
                              final isCtrlPressed =
                                  event.logicalKey ==
                                      LogicalKeyboardKey.controlLeft ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.controlRight;

                              final isAltPressed =
                                  event.logicalKey ==
                                      LogicalKeyboardKey.altLeft ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.altRight;
                              final isM =
                                  event.physicalKey == PhysicalKeyboardKey.keyM;
                              final isF =
                                  event.physicalKey == PhysicalKeyboardKey.keyF;

                              if (event is KeyDownEvent) {
                                _safeSetState(() {
                                  if (isSpacePressed) _isSpacePressed = true;
                                  if (isCtrlPressed) _isCtrlPressed = true;
                                  if (isAltPressed) _isAltPressed = true;
                                });
                                if (isF && !_isFPressed) {
                                  _safeSetState(() {
                                    _isFPressed = true;
                                    _folderSelection.clear();
                                  });
                                }
                                if (isM && !_isMapOpen) {
                                  _showMapOverlay();
                                }
                                return KeyEventResult.handled;
                              } else if (event is KeyUpEvent) {
                                _safeSetState(() {
                                  if (isSpacePressed) _isSpacePressed = false;
                                  if (isCtrlPressed) _isCtrlPressed = false;
                                  if (isAltPressed) _isAltPressed = false;
                                });
                                if (isF && _isFPressed) _onFKeyReleased();
                                return KeyEventResult.handled;
                              }
                            }
                            return KeyEventResult.ignored;
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (details) {
                              _focusNode.requestFocus();
                              _handleTapDown(details);
                            },
                            onPanStart: (details) {
                              final worldPos = _localToItemSpace(
                                details.localPosition,
                              );

                              if (_isArrowCreationMode) {
                                // --- ЗМІНЕНО ---
                                // Збільшуємо hitAreaHeight до 140, щоб ловити клік по тексту під іконкою
                                final item = _hitTest(
                                  details.localPosition,
                                  hitAreaHeight: 140,
                                );
                                // ---------------

                                if (item != null) {
                                  _arrowStartItem = item;
                                  final startPosLocal =
                                      item.position + const Offset(50, 50);
                                  _safeSetState(() {
                                    _tempArrowStart = startPosLocal;
                                    _tempArrowEnd = worldPos;
                                  });
                                }
                                return;
                              }

                              final folder = _hitTestCollapsedFolder(
                                details.localPosition,
                              );
                              if (folder != null) {
                                _safeSetState(() {
                                  _draggedConnection = folder;
                                  selectedItem = null;
                                });
                                dragStartLocalPos =
                                    worldPos - folder.collapsedPosition!;
                                return;
                              }

                              if (_isSpacePressed || _isCtrlPressed) {
                                return;
                              }

                              final item = _hitTest(details.localPosition);
                              if (item == null) return;

                              selectedItem = item;
                              dragStartLocalPos = worldPos - item.position;
                            },
                            onPanUpdate: (details) {
                              final worldPos = _localToItemSpace(
                                details.localPosition,
                              );

                              if (_isArrowCreationMode &&
                                  _arrowStartItem != null) {
                                _safeSetState(() {
                                  _tempArrowEnd = worldPos;
                                });
                                return;
                              }

                              if (_isSpacePressed || _isCtrlPressed) {
                                _safeSetState(() => offset += details.delta);
                                return;
                              }
                              if (_draggedConnection != null) {
                                final newPos =
                                    worldPos -
                                    (dragStartLocalPos ?? Offset.zero);
                                final dx =
                                    newPos.dx -
                                    _draggedConnection!.collapsedPosition!.dx;
                                final dy =
                                    newPos.dy -
                                    _draggedConnection!.collapsedPosition!.dy;
                                final delta = Offset(dx, dy);

                                _safeSetState(() {
                                  _draggedConnection!.collapsedPosition =
                                      newPos;
                                  for (final itemId
                                      in _draggedConnection!.itemIds) {
                                    final item = items.firstWhereOrNull(
                                      (i) => i.id == itemId,
                                    );
                                    if (item != null) item.position += delta;
                                  }
                                });
                                return;
                              }
                              if (selectedItem != null) {
                                _safeSetState(() {
                                  selectedItem!.position =
                                      worldPos -
                                      (dragStartLocalPos ?? Offset.zero);
                                });
                              }
                            },
                            onPanEnd: (details) {
                              if (_isArrowCreationMode &&
                                  _arrowStartItem != null) {
                                BoardItem? endItem;
                                for (final item in items.reversed) {
                                  // --- ЗМІНЕНО ---
                                  // Тут також збільшуємо висоту зони до 140
                                  final rect = Rect.fromLTWH(
                                    item.position.dx,
                                    item.position.dy,
                                    100,
                                    140, // Було 100, ставимо 140 (враховуємо текст)
                                  );
                                  // ----------------

                                  if (rect.contains(_tempArrowEnd!)) {
                                    endItem = item;
                                    break;
                                  }
                                }

                                if (endItem != null &&
                                    endItem != _arrowStartItem) {
                                  _safeSetState(() {
                                    widget.board?.links ??= [];
                                    final exists = widget.board!.links!.any(
                                      (l) =>
                                          l.fromItemId == _arrowStartItem!.id &&
                                          l.toItemId == endItem!.id,
                                    );
                                    if (!exists) {
                                      widget.board!.links!.add(
                                        BoardLink(
                                          id: UniqueKey().toString(),
                                          fromItemId: _arrowStartItem!.id,
                                          toItemId: endItem!.id,
                                          colorValue: _currentArrowColor.value,
                                          strokeWidth: _currentArrowWidth,
                                        ),
                                      );
                                      _saveBoard();
                                    }
                                  });
                                }
                                _safeSetState(() {
                                  _arrowStartItem = null;
                                  _tempArrowStart = null;
                                  _tempArrowEnd = null;
                                });
                                return;
                              }

                              if (selectedItem != null) {
                                widget.webRTCManager?.broadcastItemUpdate(
                                  selectedItem!,
                                );
                              }

                              _dragStartGlobalPos = null;
                              _draggedConnection = null;
                              selectedItem = null;
                              dragStartLocalPos = null;
                              _saveBoard();
                            },
                            onPanCancel: () {
                              _dragStartGlobalPos = null;
                              _draggedConnection = null;
                              selectedItem = null;
                              dragStartLocalPos = null;
                              _arrowStartItem = null;
                              _tempArrowStart = null;
                              _tempArrowEnd = null;
                            },
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: BoardPainter(
                                      items: _getVisibleItems(),
                                      offset: offset,
                                      scale: scale,
                                      selectedItem: selectedItem,
                                      connections: _getVisibleConnections(),
                                      folderSelectionItems: _folderSelection,
                                      links: widget.board?.links,
                                      // connections: widget.board?.connections,
                                      highlightedConnections:
                                          _highlightedConnection != null
                                              ? {_highlightedConnection!}
                                              : {},
                                      tempArrowStart: _tempArrowStart,
                                      tempArrowEnd: _tempArrowEnd,
                                      isFPressed: _isFPressed,
                                      tempArrowColor: _currentArrowColor,
                                      tempArrowWidth: _currentArrowWidth,
                                      fileIcons: _loadedIcons,
                                    ),
                                  ),
                                ),
                                if (_dragging)
                                  Positioned.fill(
                                    child: Container(
                                      color: Colors.blue.withAlpha(50),
                                      child: Center(
                                        child: Text(
                                          S.t('drop_files'),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                Positioned(
                  right: 20,
                  bottom: 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Кнопка Файлового Експлорера (замість Files/Folders)
                      _buildSidebarBtn(
                        mode: SidebarMode.explorer,
                        icon:
                            Icons.folder_copy_outlined, // Або Icons.folder_open
                        tooltip: S.t(
                          'explorer',
                        ), // Не забудь додати цей переклад або напиши "Explorer"
                      ),
                      const SizedBox(height: 12),

                      _buildSidebarBtn(
                        mode: SidebarMode.tags,
                        icon: Icons.tag,
                        tooltip: S.t('tags'),
                      ),
                      const SizedBox(height: 12),

                      _buildSidebarBtn(
                        mode: SidebarMode.users,
                        icon: Icons.people_outline,
                        tooltip: S.t('users'),
                      ),

                      const SizedBox(height: 24),

                      // Режим створення стрілок (зв'язків)
                      GestureDetector(
                        onSecondaryTap: _showArrowSettingsDialog,
                        onLongPress: _showArrowSettingsDialog,
                        child: _BoardActionButton(
                          icon:
                              _isArrowCreationMode
                                  ? Icons.timeline
                                  : Icons.arrow_right_alt,
                          isActive: _isArrowCreationMode,
                          activeColor: Colors.green,
                          tooltip: S.t('arrow_mode_hint'),
                          onPressed: () {
                            _safeSetState(() {
                              _isArrowCreationMode = !_isArrowCreationMode;
                              if (_isArrowCreationMode) {
                                selectedItem = null;
                                _folderSelection.clear();
                              }
                            });
                          },
                        ),
                      ),

                      const SizedBox(height: 24),

                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _BoardActionButton(
                            icon: Icons.create_new_folder_outlined,
                            isMini: true,
                            tooltip: S.t('create_file'),
                            onPressed: _createNewFile,
                          ),
                          const SizedBox(width: 12),
                          _BoardActionButton(
                            icon: Icons.upload_file,
                            tooltip: S.t('upload_file'),
                            onPressed: _pickFiles,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: _sidebarMode != SidebarMode.none ? 360 : 0,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(left: BorderSide(color: Colors.grey.shade300)),
              boxShadow: [
                if (_sidebarMode != SidebarMode.none)
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(-2, 0),
                  ),
              ],
            ),
            child:
                _sidebarMode != SidebarMode.none
                    ? ClipRect(
                      child: OverflowBox(
                        minWidth: 360,
                        maxWidth: 360,
                        alignment: Alignment.centerLeft,
                        child: _buildSidebarContent(),
                      ),
                    )
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarContent() {
    String title = "";
    IconData icon = Icons.info;
    // Змінна для вмісту, щоб не дублювати обгортку
    Widget content = const SizedBox.shrink();

    switch (_sidebarMode) {
      case SidebarMode.explorer:
        // Тут ми не ставимо заголовок, бо він вже є всередині _buildExplorer
        // або можемо винести його сюди. Для простоти повернемо віджет повністю.
        return _buildExplorer();

      case SidebarMode.tags:
        title = S.t('tags');
        icon = Icons.tag;
        content =
            _buildFilteredList(); // Цей метод треба трохи підправити (див. нижче)
        break;

      case SidebarMode.users:
        title = S.t('users');
        icon = Icons.people;
        content = _buildFilteredList();
        break;

      default:
        return const SizedBox.shrink();
    }

    // Обгортка для Users та Tags (стандартна шапка)
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Icon(icon, color: Colors.grey[700]),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => _toggleSidebar(SidebarMode.none),
              ),
            ],
          ),
        ),
        // Пошук потрібен для тегів та юзерів
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "${S.t('search_hint')}...",
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.grey[100],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged:
                (val) => setState(() => _searchQuery = val.toLowerCase()),
          ),
        ),
        const SizedBox(height: 10),
        const Divider(height: 1),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildFilteredList() {
    switch (_sidebarMode) {
      // SidebarMode.files та SidebarMode.folders ВИДАЛЕНО, бо вони тепер в explorer

      case SidebarMode.tags:
        final allTags = <String>{};
        for (var i in items) {
          allTags.addAll(i.tags);
        }
        final filteredTags =
            allTags.where((t) {
                return t.toLowerCase().contains(_searchQuery);
              }).toList()
              ..sort();

        if (filteredTags.isEmpty) {
          return Center(child: Text(S.t('tags_not_found')));
        }

        return ListView.builder(
          itemCount: filteredTags.length,
          itemBuilder: (context, index) {
            final tag = filteredTags[index];
            final itemsWithTag =
                items.where((i) => i.tags.contains(tag)).toList();

            return ExpansionTile(
              leading: const Icon(Icons.tag, color: Colors.orange),
              title: Text("#$tag"),
              subtitle: Text("${itemsWithTag.length} файл(ів)"),
              children:
                  itemsWithTag.map((item) {
                    return ListTile(
                      contentPadding: const EdgeInsets.only(
                        left: 32,
                        right: 16,
                      ),
                      title: Text(item.fileName),
                      onTap: () => scrollToItem(item),
                    );
                  }).toList(),
            );
          },
        );

      case SidebarMode.users:
        final filteredEntries =
            _connectedUsers.entries.where((entry) {
              return entry.value['username']!.toLowerCase().contains(
                _searchQuery,
              );
            }).toList();

        return Column(
          children: [
            if (_isHost)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: ElevatedButton.icon(
                  onPressed: _showBlockedUsersDialog,
                  icon: const Icon(Icons.block, size: 18),
                  label: Text(S.t('blacklist')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[50],
                    foregroundColor: Colors.red,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            if (filteredEntries.isEmpty)
              Expanded(child: Center(child: Text(S.t('no_active_members'))))
            else
              Expanded(
                child: ListView.builder(
                  itemCount: filteredEntries.length,
                  itemBuilder: (context, index) {
                    final peerId = filteredEntries[index].key;
                    final info = filteredEntries[index].value;
                    final pubId = info['publicId']!;
                    final isBlocked = widget.board!.blockedPublicIds.contains(
                      pubId,
                    );

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            isBlocked ? Colors.red : const Color(0xFF009688),
                        child: Text(
                          info['username']![0].toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      title: Text(info['username']!),
                      subtitle: Text(
                        pubId.length > 12
                            ? "${pubId.substring(0, 12)}..."
                            : pubId,
                      ),
                      trailing:
                          _isHost
                              ? PopupMenuButton<String>(
                                tooltip: "Керування",
                                onSelected: (value) {
                                  if (value == 'kick') {
                                    widget.webRTCManager?.disconnectPeer(
                                      peerId,
                                    );
                                  } else if (value == 'block') {
                                    setState(() {
                                      if (isBlocked) {
                                        widget.board!.blockedPublicIds.remove(
                                          pubId,
                                        );
                                      } else {
                                        widget.board!.blockedPublicIds.add(
                                          pubId,
                                        );
                                        widget.webRTCManager?.disconnectPeer(
                                          peerId,
                                        );
                                      }
                                    });
                                    _saveBoard();
                                  }
                                },
                                itemBuilder:
                                    (context) => [
                                      const PopupMenuItem(
                                        value: 'kick',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.logout,
                                              color: Colors.orange,
                                              size: 20,
                                            ),
                                            SizedBox(width: 8),
                                            Text("Відключити"),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'block',
                                        child: Row(
                                          children: [
                                            Icon(
                                              isBlocked
                                                  ? Icons.check_circle_outline
                                                  : Icons.block,
                                              color: Colors.red,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              isBlocked
                                                  ? "Розблокувати"
                                                  : "Заблокувати",
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                              )
                              : null,
                    );
                  },
                ),
              ),
          ],
        );

      default:
        return const SizedBox.shrink();
    }
  }

  void _handleFileDrop(List<XFile> files, Offset localPos) async {
    if (files.isEmpty) return;
    if (widget.board?.id == null) return;

    final scenePos = _localToItemSpace(localPos);
    List<BoardItem> newItems = [];

    final currentDir = await _getCurrentFilesDir();

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final originalPath = file.path;

      if (!await io.File(originalPath).exists()) continue;

      final fileName = p.basename(originalPath);

      // Перевірка дублікатів (опціонально, якщо у вас є ця логіка)
      final fileAlreadyAdded = items.any(
        (item) =>
            item.originalPath == originalPath ||
            p.basename(item.originalPath) == fileName,
      );

      if (fileAlreadyAdded) {
        final shouldAdd = await _confirmAddDuplicate(fileName);
        if (!shouldAdd) continue;
      }

      _locallyProcessingFiles.add(fileName.toLowerCase());

      try {
        final dir = io.Directory(currentDir);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        String destinationPath = p.join(currentDir, fileName);

        final nameNoExt = p.basenameWithoutExtension(fileName);
        final ext = p.extension(fileName);
        int counter = 1;

        // Вираховуємо унікальне ім'я
        while (await io.File(destinationPath).exists()) {
          destinationPath = p.join(currentDir, '${nameNoExt}_$counter$ext');
          counter++;
        }

        // 🔥 ЗАХИСТ МОНІТОРА
        // 1. Ігноруємо конкретний повний шлях, куди будемо копіювати
        _fileMonitorService?.ignorePath(destinationPath);
        // 2. Ставимо на паузу перед фізичним записом
        _fileMonitorService?.pause();

        try {
          await io.File(originalPath).copy(destinationPath);
        } finally {
          // 3. Відновлюємо одразу після операції
          _fileMonitorService?.resume();
        }

        final finalFileName = p.basename(destinationPath);

        // Додаємо і фінальне ім'я в список обробки (якщо воно змінилось)
        if (finalFileName != fileName) {
          _locallyProcessingFiles.add(finalFileName.toLowerCase());
        }

        String itemType = 'file';
        final entityType = io.FileSystemEntity.typeSync(originalPath);
        if (entityType == io.FileSystemEntityType.file) {
          itemType =
              p.extension(destinationPath).replaceFirst('.', '').toLowerCase();
        } else if (entityType == io.FileSystemEntityType.directory) {
          itemType = 'folder';
        }

        final positionOffset = Offset(
          (newItems.length + items.length) * 20.0,
          (newItems.length + items.length) * 20.0,
        );

        final newItem = BoardItem(
          id: UniqueKey().toString(),
          path: destinationPath,
          shortcutPath: destinationPath,
          originalPath: destinationPath,
          position: scenePos + positionOffset,
          type: itemType,
          fileName: finalFileName,
          connectionId: _isNestedFolder ? widget.board?.id : null,
        );

        newItems.add(newItem);
        _broadcastItemAdd(item: newItem);

        if (itemType != 'folder') {
          _streamFileToPeers(newItem, destinationPath);
        }
      } catch (e) {
        logger.e("Error adding file via drop: $e");
        _showErrorSnackbar("Помилка додавання файлу: $e");
      } finally {
        // Очищення списку локальної обробки через деякий час
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            _locallyProcessingFiles.remove(fileName.toLowerCase());
          }
        });
      }
    }

    if (newItems.isNotEmpty) {
      _safeSetState(() => items.addAll(newItems));
      _saveBoard();
    }
  }

  @override
  Set<String> get locallyProcessingFiles => _locallyProcessingFiles;

  // Міксин хоче "webRTCManager", у нас він у віджеті
  @override
  WebRTCManager? get webRTCManager => widget.webRTCManager;

  // Міксин хоче "saveBoard", а у нас є "_saveBoard". Робимо місток:
  @override
  Future<void> saveBoard() => _saveBoard();

  // Міксин хоче "safeSetState"
  @override
  void safeSetState(VoidCallback fn) => _safeSetState(fn);

  // Ці дві функції теж треба зробити публічними або перевизначити,
  // але краще їх теж перенести в цей же Mixin, щоб не мучитись!
  @override
  void broadcastItemAdd({required BoardItem item}) =>
      _broadcastItemAdd(item: item);

  @override
  Future<void> streamFileToPeers(BoardItem item, String path) =>
      _streamFileToPeers(item, path);

  @override
  bool get isNestedFolder => _isNestedFolder;

  @override
  void updateItemPath(BoardItem item, String newPath) =>
      _updateItemPath(item, newPath);
}

extension on Object? {
  get id => null;
}

class _BoardActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isActive;
  final bool isMini;
  final Color? activeColor;

  const _BoardActionButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.isActive = false,
    this.isMini = false,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final double size = isMini ? 48 : 64;
    final themeColor = const Color(0xFF009688);
    final effectiveActiveColor = activeColor ?? themeColor;

    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: isActive ? effectiveActiveColor : Colors.grey[100],
        elevation: isActive ? 4 : 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side:
              isActive
                  ? BorderSide.none
                  : BorderSide(color: Colors.grey.shade300, width: 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onPressed,
          child: Tooltip(
            message: tooltip,
            child: Icon(
              icon,
              color: isActive ? Colors.white : themeColor,
              size: isMini ? 24 : 32,
            ),
          ),
        ),
      ),
    );
  }
}

class RainbowColorPicker extends StatefulWidget {
  final Color selectedColor;
  final ValueChanged<Color> onColorChanged;

  const RainbowColorPicker({
    super.key,
    required this.selectedColor,
    required this.onColorChanged,
  });

  @override
  State<RainbowColorPicker> createState() => _RainbowColorPickerState();
}

class _RainbowColorPickerState extends State<RainbowColorPicker> {
  double _currentHue = 0.0;

  @override
  void initState() {
    super.initState();
    _currentHue = HSVColor.fromColor(widget.selectedColor).hue;
  }

  void _updateColor(double dx, double maxWidth) {
    double position = dx.clamp(0.0, maxWidth);
    double hue = (position / maxWidth) * 360.0;

    setState(() {
      _currentHue = hue;
    });

    final newColor = HSVColor.fromAHSV(1.0, hue, 1.0, 0.5).toColor();
    widget.onColorChanged(newColor);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: widget.selectedColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey.shade300, width: 2),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 5),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              onPanUpdate: (details) {
                _updateColor(details.localPosition.dx, constraints.maxWidth);
              },
              onTapDown: (details) {
                _updateColor(details.localPosition.dx, constraints.maxWidth);
              },
              child: Container(
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: (_currentHue / 360.0) * constraints.maxWidth - 15,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: widget.selectedColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
