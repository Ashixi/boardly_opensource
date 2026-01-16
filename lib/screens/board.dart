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
import 'package:boardly/screens/payment_dialog.dart';
import 'package:boardly/screens/start_screen.dart';
import 'package:boardly/services/file_monitor_service.dart';
import 'package:boardly/services/localization.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:boardly/widgets/board_minimap_painter.dart';
import 'package:flutter/services.dart';

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

enum SidebarMode { none, files, tags, folders, users }

class CanvasBoard extends StatefulWidget {
  final BoardModel? board;
  final Function(Connection)? onOpenConnectionBoard;
  final Function(BoardModel)? onBoardUpdated;
  final WebRTCManager? webRTCManager;

  const CanvasBoard({
    super.key,
    this.board,
    this.onOpenConnectionBoard,
    this.onBoardUpdated,
    this.webRTCManager,
  });

  @override
  State<CanvasBoard> createState() => CanvasBoardState();
}

class CanvasBoardState extends State<CanvasBoard> {
  List<BoardItem> items = [];
  double scale = 1.0;
  Offset offset = Offset.zero;
  BoardItem? selectedItem;
  Offset? dragStartLocalPos;
  Connection? _draggedConnection;
  bool _dragging = false;
  Connection? _highlightedConnection;

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
      if (widget.onOpenConnectionBoard != null) {
        widget.board!.isConnectionBoard = false;
      }
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

        onFileAdded: (String path) => _handleExternalFileAdded(path),
        onFileRenamed:
            (String old, String newP) => _handleExternalFileRenamed(old, newP),
        onFileDeleted: (String path) => _handleExternalFileDeleted(path),
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

  Future<File?> _findLocalFileForItem(BoardItem item) async {
    File candidate = File(item.originalPath);
    if (await candidate.exists()) return candidate;
    if (widget.board?.id == null) return null;
    try {
      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDirAuto(
        dirName,
      );

      final candidates = [
        p.join(boardFilesDir, item.fileName),
        p.join(boardFilesDir, item.id),
      ];
      for (final path in candidates) {
        candidate = File(path);
        if (await candidate.exists()) {
          if (item.originalPath != path) {
            _updateItemPath(item, path);
          }
          return candidate;
        }
      }
    } catch (e) {
      logger.w("Error searching for local file: $e");
    }
    return null;
  }

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

  Future<String> _calculateFileHash(File file) async {
    if (!await file.exists()) return "";

    int attempts = 0;
    while (attempts < 3) {
      try {
        final stream = file.openRead();
        final digest = await md5.bind(stream).first;
        return digest.toString();
      } catch (e) {
        attempts++;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    logger.w("⚠️ Не вдалося порахувати хеш для ${file.path}");
    return "";
  }

  Future<void> _processPendingUpdates() async {
    if (_pendingUpdates.isEmpty) return;
    final List<String> processedTargets = [];
    for (final entry in _pendingUpdates.entries) {
      final targetPath = entry.key;
      final sourceTempPath = entry.value;
      try {
        final targetFile = File(targetPath);
        final sourceFile = File(sourceTempPath);
        if (!await sourceFile.exists()) {
          processedTargets.add(targetPath);
          continue;
        }
        if (await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (_) {
            continue;
          }
        }
        await sourceFile.rename(targetPath);
        processedTargets.add(targetPath);
        _fileMonitorService?.ignoreNextChange(p.basename(targetPath));
      } catch (e) {}
    }
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

    if (widget.board != null && !_isNestedFolder) {
      if (widget.board != null && !_isNestedFolder) {
        widget.board!.items = List.from(items);
        widget.board!.connections ??= [];

        BoardStorage.saveBoard(widget.board!).catchError((e) {
          logger.w("Warning: Failed to save board on dispose: $e");
        });
      }

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
      final File? fileToRead = await _findLocalFileForItem(item);
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
      _fileMonitorService?.ignoreNextChange(fileName);
      final bool isGuest = !_isHost;

      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnected: isGuest,
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
      await _safeWriteBytes(File(finalFilePath), fileBytes);
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
      final localFile = await _findLocalFileForItem(existingItem);
      if (localFile != null && await localFile.exists()) {
        if (remoteHash != null && remoteHash.isNotEmpty) {
          final String localHash = await _calculateFileHash(localFile);

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

  void _setupWebRTCListener() {
    if (widget.webRTCManager == null) return;

    widget.webRTCManager!.onDataReceived = (String from, dynamic data) {
      if (!_isMounted) return;
      final type = data['type'];

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
      }

      _safeSetState(() {
        switch (type) {
          case 'peer-left':
            _connectedUsers.remove(from);
            logger.i("RTC: Peer $from left, removed from UI list");
            break;

          case 'item-update':
            _handleItemUpdate(data);
            break;

          case 'connection-update':
            _handleConnectionUpdate(data);
            break;

          case 'item-add':
            _handleItemAdd(data);
            break;

          case 'item-delete':
            _handleItemDelete(data);
            break;

          case 'board-description-update':
            _handleBoardDescriptionUpdate(data);
            break;

          case 'request-file-content':
            _handleFileContentRequest(data, from);
            break;

          case 'full-file-content':
            _handleFullFileContent(data);
            break;

          case 'file-available':
            _handleFileAvailable(data, from);
            break;

          case 'request-file':
            _handleFileRequestCommand(data, from);
            break;

          case 'file-transfer-start':
            _handleFileTransferStart(data);
            break;

          case 'file-chunk':
            _handleFileChunk(data);
            break;

          case 'file-transfer-end':
            _handleFileTransferEnd(data, from);
            break;

          case 'full-board':
            if (_isHost) return;
            try {
              final boardModel = BoardModel.fromJson(jsonDecode(data['board']));
              _handleFullBoardReceived(boardModel, from);
            } catch (e) {
              logger.e("Помилка парсингу дошки: $e");
            }
            break;
        }
      });
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
    try {
      final boardJson = jsonEncode(widget.board!.toJson());
      widget.webRTCManager!.sendFullBoardToPeer(peerId, boardJson);
    } catch (e) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 1000));
    for (final item in items) {
      if (item.type == 'folder' || item.type == 'dir') continue;
      if (widget.webRTCManager?.hasOpenConnections != true) break;
      try {
        File? fileToSend = await _findLocalFileForItem(item);
        if (fileToSend != null && await fileToSend.exists()) {
          final String hash = await _calculateFileHash(fileToSend);
          final int size = await fileToSend.length();
          final announcement = {
            'type': 'file-available',
            'fileId': item.id,
            'fileName': item.fileName,
            'fileSize': size,
            'fileHash': hash,
            'originalPath': item.originalPath,
            'ownerPeerId': _myPeerId,
            'isInitial': true,
          };
          widget.webRTCManager!.sendMessageToPeer(peerId, announcement);
          await Future.delayed(const Duration(milliseconds: 50));
        }
      } catch (e) {
        logger.e("Error announcing file ${item.fileName}: $e");
      }
    }
  }

  Future<void> _handleFileTransferStart(Map<String, dynamic> data) async {
    final String fileId = data['fileId'];
    final String fileName = data['fileName'];
    final String originalPath = data['originalPath'];
    final int fileSize = data['fileSize'];
    try {
      if (_incomingFileWriters.containsKey(fileId)) {
        await _incomingFileWriters[fileId]?.close();
        _incomingFileWriters.remove(fileId);
      }

      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnected: !_isHost,
      );

      final uniqueTempName =
          '${fileName}_${DateTime.now().microsecondsSinceEpoch}.part';
      final String tempFilePath = p.join(boardFilesDir, uniqueTempName);
      final dir = Directory(boardFilesDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final IOSink sink = File(tempFilePath).openWrite();
      _incomingFileWriters[fileId] = sink;
      _incomingFilePaths[fileId] = tempFilePath;
      _incomingFileOriginalPaths[fileId] = originalPath;
      _incomingFileExpectedSizes[fileId] = fileSize;
      _downloadLastActiveTime[fileId] = DateTime.now();
    } catch (e) {
      logger.e('Error starting file transfer: $e');
    }
  }

  Future<void> _handleFileTransferEnd(
    Map<String, dynamic> data,
    String from,
  ) async {
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

      await Future.delayed(const Duration(milliseconds: 200));

      final tempFile = File(tempFilePath);
      if (!await tempFile.exists()) return;

      // Перевірка розміру (цілісність)
      final int actualSize = await tempFile.length();
      if (expectedSize != null && actualSize != expectedSize) {
        logger.w("Size mismatch. Deleting corrupted temp file.");
        try {
          await tempFile.delete();
        } catch (_) {}
        return;
      }

      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDir(
        dirName,
        isConnected: !_isHost,
      );

      final existingItem = items.firstWhereOrNull((i) => i.id == fileId);

      String finalFileName =
          existingItem?.fileName ?? p.basename(originalRemotePath ?? 'file');

      String targetFilePath;
      if (existingItem != null) {
        if (!existingItem.originalPath.startsWith(boardFilesDir)) {
          targetFilePath = p.join(boardFilesDir, finalFileName);
        } else {
          targetFilePath = existingItem.originalPath;
        }
      } else {
        targetFilePath = p.join(boardFilesDir, finalFileName);
      }

      final targetFile = File(targetFilePath);
      bool isConflict = false;
      String moveDestination = targetFilePath;

      if (await targetFile.exists()) {
        if (!isInitialSync) {
          isConflict = false;
        } else {
          final String localHash = await _calculateFileHash(targetFile);
          final String incomingHash = await _calculateFileHash(tempFile);

          if (localHash != incomingHash) {
            bool alreadyHasCopy = false;
            for (var item in items) {
              if (item.fileName.contains(
                    p.basenameWithoutExtension(finalFileName),
                  ) &&
                  item.id != fileId) {
                final f = await _findLocalFileForItem(item);
                if (f != null && await f.exists()) {
                  final h = await _calculateFileHash(f);
                  if (h == incomingHash) {
                    alreadyHasCopy = true;
                    break;
                  }
                }
              }
            }

            if (alreadyHasCopy) {
              logger.i("👯 Duplicate conflict ignored.");
              try {
                await tempFile.delete();
              } catch (_) {}
              return;
            }

            isConflict = true;
            final String nameWithoutExt = p.basenameWithoutExtension(
              finalFileName,
            );
            final String ext = p.extension(finalFileName);
            final String timestamp = DateTime.now().millisecondsSinceEpoch
                .toString()
                .substring(8);
            final String conflictFileName =
                '${nameWithoutExt}_conflict_$timestamp$ext';
            final String conflictFilePath = p.join(
              boardFilesDir,
              conflictFileName,
            );

            if (_isHost) {
              moveDestination = conflictFilePath;
              targetFilePath = conflictFilePath;
              finalFileName = conflictFileName;
            } else {
              try {
                await targetFile.rename(conflictFilePath);
                _fileMonitorService?.ignoreNextChange(conflictFileName);
              } catch (e) {
                logger.e("Failed to rename local conflict file: $e");
              }

              moveDestination = targetFilePath;
              targetFilePath = conflictFilePath;
              finalFileName = conflictFileName;
            }
          }
        }
      }

      if (!isConflict &&
          existingItem == null &&
          await File(moveDestination).exists()) {
        int counter = 1;
        final baseName = p.basenameWithoutExtension(finalFileName);
        final ext = p.extension(finalFileName);
        while (await File(moveDestination).exists()) {
          moveDestination = p.join(boardFilesDir, '${baseName}_$counter$ext');
          counter++;
        }
        finalFileName = p.basename(moveDestination);
        targetFilePath = moveDestination;
      }

      bool isLocked = false;
      final fileToSave = File(moveDestination);

      if (await fileToSave.exists() && !isConflict) {
        try {
          await fileToSave.delete();
        } catch (e) {
          isLocked = true;
          logger.w("File locked, cannot delete old version: $e");
        }
      }

      if (!isLocked) {
        try {
          await tempFile.rename(moveDestination);
        } catch (e) {
          await tempFile.copy(moveDestination);
          await tempFile.delete();
        }
        _fileMonitorService?.ignoreNextChange(p.basename(moveDestination));
      } else {
        if (_pendingUpdates.containsKey(moveDestination)) {
          try {
            await File(_pendingUpdates[moveDestination]!).delete();
          } catch (_) {}
        }
        _pendingUpdates[moveDestination] = tempFilePath;
      }

      // --- ОНОВЛЕННЯ ІНТЕРФЕЙСУ (UI) ---

      if (isConflict) {
        final newId = UniqueKey().toString();
        final newItem = BoardItem(
          id: newId,
          path: targetFilePath,
          shortcutPath: targetFilePath,
          originalPath: targetFilePath,
          position:
              (existingItem?.position ?? const Offset(100, 100)) +
              const Offset(40, 40),
          type: p.extension(finalFileName).replaceFirst('.', ''),
          fileName: finalFileName,
          tags: existingItem?.tags ?? [],
        );
        _safeSetState(() => items.add(newItem));

        logger.i("⚠️ Conflict resolved: created new file $finalFileName");
      } else {
        if (existingItem != null) {
          final index = items.indexWhere((i) => i.id == fileId);
          if (index != -1) {
            _safeSetState(() {
              items[index] = items[index].copyWith(
                originalPath: moveDestination,
              );
            });
          }
        } else {
          final newItem = BoardItem(
            id: fileId,
            path: moveDestination,
            shortcutPath: moveDestination,
            originalPath: moveDestination,
            position: Offset(100, 100 + items.length * 50),
            type: p.extension(finalFileName).replaceFirst('.', ''),
            fileName: finalFileName,
          );
          _safeSetState(() => items.add(newItem));
        }
      }

      if (!isLocked) await _saveBoard();
    } catch (e) {
      logger.e('Failed to finalize received file: $e');
    }
  }

  void _handleFullBoardReceived(BoardModel receivedBoard, String from) async {
    if (!mounted) return;
    if (items.isNotEmpty && _isHost) return;

    final dirName = receivedBoard.id!;
    final String boardFilesDir = await BoardStorage.getBoardFilesDir(
      dirName,
      isConnected: true,
    );

    final List<BoardItem> processedItems = [];
    for (var item in receivedBoard.items) {
      final String expectedPath = p.join(boardFilesDir, item.fileName);
      processedItems.add(
        item.copyWith(
          path: expectedPath,
          originalPath: expectedPath,
          shortcutPath: expectedPath,
        ),
      );
    }
    _safeSetState(() {
      final bool wasJoined = widget.board?.isJoined ?? false;
      widget.board?.items = processedItems;
      widget.board?.connections = receivedBoard.connections;
      widget.board?.description = receivedBoard.description;

      if (wasJoined)
        widget.board!.isJoined = true;
      else
        widget.board!.isJoined = receivedBoard.isJoined;
      items = processedItems;
    });
    if (widget.board != null) {
      widget.onBoardUpdated?.call(widget.board!);
      _saveBoard();
    }
  }

  void _handleExternalFileAdded(String path) async {
    if (!mounted) return;

    final fileName = p.basename(path);

    if (_locallyProcessingFiles.contains(fileName.toLowerCase())) {
      logger.i("🛡️ Blocked duplicate from monitor: $fileName");
      return;
    }

    final existing = items.firstWhereOrNull(
      (i) => i.originalPath == path || i.fileName == fileName,
    );
    if (existing != null) return;

    logger.i("📂 External file detected: $path");

    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();

    Offset position = const Offset(100, 100);
    if (items.isNotEmpty) {
      final lastItem = items.last;
      position = lastItem.position + const Offset(20, 20);
    }

    final newItem = BoardItem(
      id: UniqueKey().toString(),
      path: path,
      shortcutPath: path,
      originalPath: path,
      position: position,
      type: ext.isEmpty ? 'file' : ext,
      fileName: fileName,
    );

    _safeSetState(() {
      items.add(newItem);
    });

    _saveBoard();
    _broadcastItemAdd(item: newItem);

    _streamFileToPeers(newItem, path);
  }

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
    } else {
      _handleExternalFileAdded(newPath);
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

  void _handleConnectionUpdate(Map<String, dynamic> data) {
    final List<dynamic> conns = data['connections'];
    final newConnections = conns.map((c) => Connection.fromJson(c)).toList();
    _safeSetState(() {
      widget.board?.connections = newConnections;
      for (final conn in newConnections) {
        for (final itemId in conn.itemIds) {
          final itemIndex = items.indexWhere((i) => i.id == itemId);
          if (itemIndex != -1) {
            if (items[itemIndex].connectionId != conn.id) {
              items[itemIndex].connectionId = conn.id;
            }
          }
        }
      }
      for (final item in items) {
        if (item.connectionId != null) {
          final isInAnyConnection = newConnections.any(
            (c) => c.id == item.connectionId && c.itemIds.contains(item.id),
          );
          if (!isInAnyConnection) {
            item.connectionId = null;
          }
        }
      }
    });
  }

  void _handleItemAdd(Map<String, dynamic> data) {
    final newItem = BoardItem.fromJson(data['item']);
    if (!items.any((i) => i.id == newItem.id)) {
      items.add(newItem);
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
    if (_isMounted) {
      setState(fn);
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
    if (widget.board?.isConnectionBoard == true) {
      _showErrorSnackbar(
        "Вкладені папки всередині вкладених папок наразі обмежені!",
      );
      _safeSetState(() => _folderSelection.clear());
      return;
    }

    Color pickedColor = Colors.blue;
    String folderName = S.t('new_folder');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String tempName = folderName;
        return StatefulBuilder(
          builder: (context, setStateDialog) {
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
                        decoration: InputDecoration(
                          labelText: S.t('folder_name'),
                        ),
                        onChanged: (v) => tempName = v,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        S.t('pick_color'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      RainbowColorPicker(
                        selectedColor: pickedColor,
                        onColorChanged:
                            (newColor) =>
                                setStateDialog(() => pickedColor = newColor),
                      ),
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
                    folderName = tempName;
                    Navigator.pop(ctx, true);
                  },
                  child: Text(S.t('create')),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true) {
      _safeSetState(() => _folderSelection.clear());
      return;
    }

    try {
      final dirName = widget.board!.id!;
      final boardFilesDir = await BoardStorage.getBoardFilesDirAuto(dirName);
      final newFolderPath = p.join(boardFilesDir, folderName);

      final directory = Directory(newFolderPath);
      if (!await directory.exists()) {
        await directory.create();
      }

      final firstItem = _folderSelection.first;
      final folderPos = firstItem.position;

      final newFolder = Connection(
        id: UniqueKey().toString(),
        name: folderName,
        itemIds: _folderSelection.map((i) => i.id).toList(),
        boardId: widget.board!.id,
        isCollapsed: true,
        collapsedPosition: folderPos,
        colorValue: pickedColor.value,
      );

      for (final item in _folderSelection) {
        final oldFile = File(item.originalPath);
        if (await oldFile.exists()) {
          final newPath = p.join(newFolderPath, item.fileName);

          _fileMonitorService?.ignoreNextChange(item.fileName);

          await oldFile.rename(newPath);

          item.originalPath = newPath;
          item.path = newPath;
          item.shortcutPath = newPath;
        }

        if (item.connectionId != null) {
          final old = widget.board?.connections?.firstWhereOrNull(
            (c) => c.id == item.connectionId,
          );
          old?.itemIds.remove(item.id);
        }
        item.connectionId = newFolder.id;
      }

      _safeSetState(() {
        widget.board?.connections ??= [];
        widget.board!.connections!.add(newFolder);
        _folderSelection.clear();
      });

      await _saveBoard();
    } catch (e) {
      logger.e("Помилка створення реальної папки: $e");
      _showErrorSnackbar("Не вдалося створити папку на диску: $e");
    }
  }

  Future<String> _getCurrentFilesDir() async {
    if (items.isNotEmpty) {
      final firstFile = items.first;
      final detectedDir = p.dirname(firstFile.originalPath);

      if (await Directory(detectedDir).exists()) {
        return detectedDir;
      }
    }

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
  //         // 🔥 FIX: Створюємо повноцінну стрілку з поточними налаштуваннями
  //         final link = BoardLink(
  //           id: UniqueKey().toString(),
  //           fromItemId: from.id,
  //           toItemId: to.id,
  //           colorValue:
  //               _currentArrowColor.value, // Використовуємо поточний колір
  //           strokeWidth: _currentArrowWidth, // Використовуємо поточну товщину
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
    _fileMonitorService?.ignoreNextChange(fullFileName);

    try {
      final currentDir = await _getCurrentFilesDir();
      String filePath = p.join(currentDir, fullFileName);

      // Переконуємось, що папка існує
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
        _fileMonitorService?.ignoreNextChange(finalFileName);
      }

      final file = io.File(filePath);
      await file.create();

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
    final bool isRealNestedFolder =
        widget.board?.isConnectionBoard == true &&
        widget.onBoardUpdated != null;

    if (isRealNestedFolder) {
      widget.board!.items = List.from(items);
      widget.board!.connections ??= [];
      widget.onBoardUpdated?.call(widget.board!);

      try {
        if (items.isEmpty) return;

        final allBoards = await BoardStorage.getBoards();
        BoardModel? rootBoard;

        final testPath = items.first.originalPath;

        for (final b in allBoards) {
          if (b.id == null) continue;
          final boardDir = await BoardStorage.getBoardDir(b.id!);

          if (p.isWithin(boardDir, testPath)) {
            rootBoard = b;
            break;
          }
        }

        if (rootBoard == null) {
          logger.w("⚠️ Не вдалося знайти головну дошку для шляху: $testPath");
          return;
        }

        final folderId = widget.board!.id;

        rootBoard.items.removeWhere((i) => i.connectionId == folderId);

        final updatedItems =
            items.map((i) {
              return i.copyWith(connectionId: folderId);
            }).toList();

        rootBoard.items.addAll(updatedItems);

        await BoardStorage.saveBoard(rootBoard);
        logger.i(
          "✅ Вкладена дошка збережена в: ${rootBoard.title} (ID: ${rootBoard.id})",
        );
      } catch (e) {
        logger.e("❌ Помилка збереження вкладеної дошки: $e");
      }
      return;
    }

    _saveDebounceTimer?.cancel();

    _saveDebounceTimer = Timer(const Duration(seconds: 1), () async {
      if (!mounted) return;
      if (widget.board == null) return;

      widget.board!.items = List.from(items);
      widget.board!.connections ??= [];

      widget.onBoardUpdated?.call(widget.board!);

      try {
        logger.i("💾 Triggering delayed save...");
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
        logger.e("Error in delayed save: $e");
      }
    });
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

  void _pickFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );

      if (result != null && result.paths.isNotEmpty) {
        if (widget.board?.id == null) return;
        List<BoardItem> newItems = [];

        // --- ЗМІНА 1: Отримуємо правильну поточну директорію ---
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
            // --- ЗМІНА 2: Використовуємо currentDir для формування шляху ---
            String destinationPath = p.join(currentDir, finalFileName);
            int counter = 1;

            while (await File(destinationPath).exists()) {
              finalFileName = '${nameNoExt}_$counter$ext';
              destinationPath = p.join(currentDir, finalFileName);
              counter++;
            }

            _locallyProcessingFiles.add(finalFileName.toLowerCase());
            _fileMonitorService?.ignoreNextChange(finalFileName);

            try {
              await file.copy(destinationPath);

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
                // --- ЗМІНА 3: Прив'язуємо до ID папки, якщо ми всередині неї ---
                connectionId: _isNestedFolder ? widget.board?.id : null,
              );

              newItems.add(newItem);
              _broadcastItemAdd(item: newItem);
              _streamFileToPeers(newItem, destinationPath);
            } catch (e) {
              logger.e("Помилка копіювання файлу: $e");
            } finally {
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
      if (await file.exists()) await file.delete();
      if (item.originalPath != item.path) {
        final orig = File(item.originalPath);
        if (await orig.exists()) await orig.delete();
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

          if ((isInsideFolderBoard && !isRootHost) ||
              item.connectionId != null ||
              parentConnection != null)
            PopupMenuItem(
              child: Text(S.t('remove_from_folder')),
              onTap: () {
                if (isInsideFolderBoard && !isRootHost) {
                  _safeSetState(() {
                    items.remove(item);
                  });
                  _saveBoard();
                } else {
                  _removeItemFromConnection(item);
                }
              },
            ),

          PopupMenuItem(
            child: Text(S.t('add_tag')),
            onTap: () => _showTagDialog(item),
          ),

          if (!isInsideFolderBoard)
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
                  _cleanUpConnections();
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

  Future<void> _openFile(BoardItem item) async {
    if (_incomingFileWriters.containsKey(item.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏳ Файл ще завантажується, зачекайте...'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    try {
      String targetPath = item.originalPath;
      File? fileToOpen;

      if (await File(targetPath).exists()) {
        fileToOpen = File(targetPath);
      } else if (widget.board?.id != null) {
        final dirName = widget.board!.id!;
        final String boardFilesDir = await BoardStorage.getBoardFilesDirAuto(
          dirName,
        );
        final candidates = [
          p.join(boardFilesDir, item.fileName),
          p.join(boardFilesDir, item.id),
          p.join(boardFilesDir, '${item.id}_${item.fileName}'),
        ];

        for (final path in candidates) {
          if (await File(path).exists()) {
            _updateItemPath(item, path);
            fileToOpen = File(path);
            break;
          }
        }
      }

      if (fileToOpen == null) {
        _showErrorSnackbar('Файл не знайдено: ${item.fileName}');
        return;
      }

      final length = await fileToOpen.length();
      if (length == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⏳ Файл обробляється системою, спробуйте ще раз.'),
            duration: Duration(seconds: 1),
          ),
        );
        return;
      }

      await _launchFile(fileToOpen.path);
    } catch (e) {
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
    return Row(
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
                      final renderBox = context.findRenderObject() as RenderBox;
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
                                event.logicalKey == LogicalKeyboardKey.altRight;
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
                              final item = _hitTest(details.localPosition);
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
                                  worldPos - (dragStartLocalPos ?? Offset.zero);
                              final dx =
                                  newPos.dx -
                                  _draggedConnection!.collapsedPosition!.dx;
                              final dy =
                                  newPos.dy -
                                  _draggedConnection!.collapsedPosition!.dy;
                              final delta = Offset(dx, dy);

                              _safeSetState(() {
                                _draggedConnection!.collapsedPosition = newPos;
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
                                final rect = Rect.fromLTWH(
                                  item.position.dx,
                                  item.position.dy,
                                  100,
                                  100,
                                );
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
                                    items: items,
                                    offset: offset,
                                    scale: scale,
                                    selectedItem: selectedItem,
                                    folderSelectionItems: _folderSelection,
                                    links: widget.board?.links,
                                    connections: widget.board?.connections,
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
                    _buildSidebarBtn(
                      mode: SidebarMode.files,
                      icon: Icons.description_outlined,
                      tooltip: S.t('files_list'),
                    ),
                    const SizedBox(height: 12),
                    _buildSidebarBtn(
                      mode: SidebarMode.tags,
                      icon: Icons.tag,
                      tooltip: S.t('tags'),
                    ),
                    const SizedBox(height: 12),
                    _buildSidebarBtn(
                      mode: SidebarMode.folders,
                      icon: Icons.folder_open,
                      tooltip: S.t('folders'),
                    ),
                    const SizedBox(height: 12),
                    _buildSidebarBtn(
                      mode: SidebarMode.users,
                      icon: Icons.people_outline,
                      tooltip: S.t('users'),
                    ),

                    const SizedBox(height: 24),

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

                    if (!_isNestedFolder || _isHost)
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
    );
  }

  Widget _buildSidebarContent() {
    String title = "";
    IconData icon = Icons.info;

    switch (_sidebarMode) {
      case SidebarMode.files:
        title = S.t('files_list');
        icon = Icons.description;
        break; //
      case SidebarMode.tags:
        title = S.t('tags');
        icon = Icons.tag;
        break; //
      case SidebarMode.folders:
        title = S.t('folders');
        icon = Icons.folder;
        break; //
      case SidebarMode.users:
        title = S.t('users');
        icon = Icons.people;
        break; //
      default:
        break;
    }

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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "${S.t('search_hint')}...", //
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
        Expanded(child: _buildFilteredList()),
      ],
    );
  }

  Widget _buildFilteredList() {
    switch (_sidebarMode) {
      case SidebarMode.files:
        final filteredFiles =
            items.where((i) {
              return i.fileName.toLowerCase().contains(_searchQuery);
            }).toList();

        if (filteredFiles.isEmpty) {
          return Center(child: Text(S.t('files_not_found')));
        }

        return ListView.builder(
          itemCount: filteredFiles.length,
          itemBuilder: (context, index) {
            final item = filteredFiles[index];
            return ListTile(
              leading: Icon(
                Icons.insert_drive_file,
                color: Colors.blue.shade300,
              ),
              title: Text(item.fileName),
              subtitle:
                  item.tags.isNotEmpty
                      ? Text(item.tags.map((t) => "#$t").join(" "))
                      : null,
              onTap: () => scrollToItem(item),
              trailing: IconButton(
                icon: const Icon(Icons.open_in_new, size: 20),
                onPressed: () => _openFile(item),
              ),
            );
          },
        );

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

      case SidebarMode.folders:
        final conns = widget.board?.connections ?? [];
        final filteredFolders =
            conns.where((c) {
              return c.name.toLowerCase().contains(_searchQuery);
            }).toList();

        if (filteredFolders.isEmpty) {
          return Center(child: Text(S.t('folders_not_found')));
        }

        return ListView.builder(
          itemCount: filteredFolders.length,
          itemBuilder: (context, index) {
            final folder = filteredFolders[index];
            return ListTile(
              leading: Icon(
                folder.isCollapsed ? Icons.folder : Icons.folder_open,
                color: Color(folder.colorValue),
              ),
              title: Text(folder.name),
              subtitle: Text("${folder.itemIds.length} об'єктів"),
              onTap: () {
                if (widget.onOpenConnectionBoard != null) {
                  widget.onOpenConnectionBoard!(folder);
                }
              },
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
                                            SizedBox(width: 8),
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

      // Перевірка дублікатів
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
      _fileMonitorService?.ignoreNextChange(fileName);

      try {
        final dir = io.Directory(currentDir);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        String destinationPath = p.join(currentDir, fileName);

        final nameNoExt = p.basenameWithoutExtension(fileName);
        final ext = p.extension(fileName);
        int counter = 1;
        while (await io.File(destinationPath).exists()) {
          destinationPath = p.join(currentDir, '${nameNoExt}_$counter$ext');
          counter++;
        }

        await io.File(originalPath).copy(destinationPath);

        final finalFileName = p.basename(destinationPath);

        if (finalFileName != fileName) {
          _locallyProcessingFiles.add(finalFileName.toLowerCase());
          _fileMonitorService?.ignoreNextChange(finalFileName);
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
