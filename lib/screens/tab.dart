import 'package:boardly/services/localization.dart';
import 'package:flutter/material.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/models/connection_model.dart';
import 'package:boardly/web_rtc/rtc.dart';
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/services/file_monitor_service.dart';
import 'board.dart';
import 'package:flutter/services.dart';
import 'package:boardly/screens/start_screen.dart';

class CanvasTabbedBoard extends StatefulWidget {
  final BoardModel initialBoard;
  final WebRTCManager? webRTCManager;

  const CanvasTabbedBoard({
    super.key,
    required this.initialBoard,
    this.webRTCManager,
  });

  @override
  State<CanvasTabbedBoard> createState() => _CanvasTabbedBoardState();
}

class _CanvasTabbedBoardState extends State<CanvasTabbedBoard> {
  late List<BoardModel> _boards;
  late int _currentTabIndex;
  FileMonitorService? _fileMonitorService;

  final Map<String, int> _nestingLevels = {};

  final GlobalKey<CanvasBoardState> _canvasKey = GlobalKey<CanvasBoardState>();

  bool _isConnected = false;
  bool _isJoining = false;

  @override
  void initState() {
    super.initState();
    _boards = [widget.initialBoard];
    _currentTabIndex = 0;

    if (widget.initialBoard.id != null) {
      _nestingLevels[widget.initialBoard.id!] = 0;
    }

    if (widget.webRTCManager != null) {
      _isConnected = widget.webRTCManager!.isConnected;
      widget.webRTCManager!.addConnectedListener(_onRtcConnected);
      widget.webRTCManager!.addDisconnectedListener(_onRtcDisconnected);
    }
  }

  @override
  void dispose() {
    if (widget.webRTCManager != null) {
      widget.webRTCManager!.removeConnectedListener(_onRtcConnected);
      widget.webRTCManager!.removeDisconnectedListener(_onRtcDisconnected);
    }
    _fileMonitorService?.stop();
    super.dispose();
  }

  void _onRtcConnected(String id) {
    if (mounted) {
      setState(() {
        _isConnected = true;
        _isJoining = false;
      });
    }
  }

  void _onRtcDisconnected() {
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isJoining = false;
      });
    }
  }

  void _addConnectionBoard(Connection connection) {
    // 1. Розрахунок рівня
    final currentBoard = _boards[_currentTabIndex];
    final currentLevel =
        (currentBoard.id != null) ? (_nestingLevels[currentBoard.id] ?? 0) : 0;
    final newLevel = currentLevel + 1;
    _nestingLevels[connection.id] = newLevel;

    final mainBoard = _boards[0];

    final updatedItems =
        mainBoard.items
            .where((item) => connection.itemIds.contains(item.id))
            .map((item) => item.copyWith())
            .toList();

    final childConnections =
        mainBoard.connections
            ?.where((conn) {
              if (conn.id == connection.id) return false;

              if (conn.itemIds.isEmpty) return false;

              final isSubset = conn.itemIds.every(
                (id) => connection.itemIds.contains(id),
              );
              return isSubset;
            })
            .map((c) => c.copyWith())
            .toList();

    setState(() {
      final existingTabIndex = _boards.indexWhere(
        (b) => b.isConnectionBoard && b.connectionId == connection.id,
      );

      final newBoardModel = BoardModel(
        id: connection.id,
        title: connection.name,
        items: updatedItems,
        connections: childConnections,
        isConnectionBoard: true,
        connectionId: connection.id,
        links: connection.links ?? [],
      );

      if (existingTabIndex != -1) {
        _boards[existingTabIndex] = newBoardModel;
        _currentTabIndex = existingTabIndex;
      } else {
        _boards.add(newBoardModel);
        _currentTabIndex = _boards.length - 1;
      }
    });
  }

  void _onTabBoardUpdated(BoardModel updatedBoard) {
    setState(() {
      final index = _boards.indexWhere((b) => b.id == updatedBoard.id);
      if (index != -1) {
        _boards[index] = updatedBoard;
      }
    });

    final mainBoard = _boards[0];

    if (updatedBoard.isConnectionBoard && updatedBoard.connectionId != null) {
      final connIndex = mainBoard.connections?.indexWhere(
        (c) => c.id == updatedBoard.connectionId,
      );

      if (connIndex != null && connIndex != -1) {
        final connection = mainBoard.connections![connIndex];
        connection.links = updatedBoard.links ?? [];
        connection.itemIds = updatedBoard.items.map((e) => e.id).toList();

        final activeItemIds = updatedBoard.items.map((i) => i.id).toSet();

        mainBoard.items.removeWhere((item) {
          return item.connectionId == updatedBoard.connectionId &&
              !activeItemIds.contains(item.id);
        });

        for (final updatedItem in updatedBoard.items) {
          final mainItemIndex = mainBoard.items.indexWhere(
            (i) => i.id == updatedItem.id,
          );

          if (mainItemIndex != -1) {
            mainBoard.items[mainItemIndex] = updatedItem;
          } else {
            mainBoard.items.add(updatedItem);
          }
        }
      }
    } else {
      _saveBoard(updatedBoard);
    }

    if (updatedBoard.connections != null) {
      mainBoard.connections ??= [];
      for (final childConn in updatedBoard.connections!) {
        final mainConnIndex = mainBoard.connections!.indexWhere(
          (c) => c.id == childConn.id,
        );
        if (mainConnIndex != -1) {
          mainBoard.connections![mainConnIndex] = childConn;
        } else {
          mainBoard.connections!.add(childConn);
        }
      }
    }

    if (updatedBoard.isConnectionBoard) {
      _saveBoard(mainBoard);
    }
  }

  void _closeTab(int index) {
    if (index == 0) return;

    setState(() {
      _boards.removeAt(index);
      if (_currentTabIndex >= index) {
        _currentTabIndex = (_currentTabIndex > 0) ? _currentTabIndex - 1 : 0;
      }
    });
  }

  Future<void> _saveBoard(BoardModel board) async {
    if (!board.isConnectionBoard) {
      try {
        await BoardStorage.saveBoard(board);
      } catch (e) {}
    }
  }

  void _toggleConnection() {
    if (widget.webRTCManager == null) return;
    if (_isConnected) {
      widget.webRTCManager!.disconnect();
    } else {
      setState(() => _isJoining = true);
      widget.webRTCManager!.connect();

      Future.delayed(const Duration(seconds: 10), () {
        if (mounted && _isJoining && !_isConnected) {
          setState(() => _isJoining = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Час очікування вичерпано")),
          );
        }
      });
    }
  }

  void _showBoardIdDialog() {
    final boardId = widget.initialBoard.id;
    if (boardId == null) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(S.t('board_id')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                S.t('share_instruction'),
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: SelectableText(
                        boardId,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, color: Color(0xFF009688)),
                    tooltip: S.t('copy_id'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: boardId));
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("ID скопійовано в буфер обміну"),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(S.t('close'), style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentBoard = _boards[_currentTabIndex];

    final int level =
        (currentBoard.id != null) ? (_nestingLevels[currentBoard.id] ?? 0) : 0;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leadingWidth: 50,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () {
            if (widget.webRTCManager != null) {
              widget.webRTCManager!.disconnect();
            }

            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const Addboard()),
              (route) => false,
            );
          },
        ),
        title: Text(
          currentBoard.title ?? 'Boardly',
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (widget.webRTCManager != null)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: IconButton(
                style: IconButton.styleFrom(
                  backgroundColor:
                      _isConnected
                          ? const Color(0xFF009688).withOpacity(0.1)
                          : (_isJoining
                              ? Colors.orange.withOpacity(0.1)
                              : Colors.grey[100]),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon:
                    _isJoining
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Icon(
                          _isConnected ? Icons.cloud_done : Icons.cloud_off,
                          color:
                              _isConnected
                                  ? const Color(0xFF009688)
                                  : Colors.grey,
                        ),
                tooltip: _isConnected ? S.t('disconnect') : S.t('connect'),
                onPressed: _toggleConnection,
              ),
            ),
          if (widget.webRTCManager != null)
            IconButton(
              icon: const Icon(Icons.share, color: Colors.black87),
              tooltip: S.t('share_id'),
              onPressed: _showBoardIdDialog,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Container(
            height: 60,
            padding: const EdgeInsets.only(bottom: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (int i = 0; i < _boards.length; i++)
                    _TabLabel(
                      board: _boards[i],
                      isActive: i == _currentTabIndex,
                      onTap: () => setState(() => _currentTabIndex = i),
                      onClose: () => _closeTab(i),
                      showCloseButton: i != 0,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: CanvasBoard(
        key: _canvasKey,
        board: _boards[_currentTabIndex],
        onOpenConnectionBoard: _addConnectionBoard,
        onBoardUpdated: _onTabBoardUpdated,
        webRTCManager: widget.webRTCManager,
        nestingLevel: level,
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  final BoardModel board;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final bool showCloseButton;

  const _TabLabel({
    required this.board,
    required this.isActive,
    required this.onTap,
    required this.onClose,
    required this.showCloseButton,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: Material(
        color: isActive ? const Color(0xFF009688) : Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  board.title ?? 'Дошка',
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.grey[700],
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                if (showCloseButton) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(2.0),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: isActive ? Colors.white70 : Colors.grey[500],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
