import 'package:boardly/data/board_storage.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:boardly/services/localization.dart';
import 'package:flutter/material.dart';
import 'package:boardly/services/board_api_service.dart'; // <--- Додати це
import 'package:boardly/logger.dart';

class JoinScreen extends StatefulWidget {
  final Future<void> Function(String boardId, String boardTitle) onJoinBoard;
  final Future<String?> Function() onSelectDirectory;
  final bool isPro;

  const JoinScreen({
    super.key,
    required this.onJoinBoard,
    required this.onSelectDirectory,
    required this.isPro,
  });

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  List<BoardModel> _joinedBoards = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    if (_joinedBoards.isEmpty) {
      try {
        var allBoards = await BoardStorage.loadAllBoards();
        if (mounted) {
          setState(() {
            _joinedBoards = allBoards.where((b) => b.isJoined == true).toList();
          });
        }
      } catch (e) {}
    }

    if (_joinedBoards.isEmpty) {
      setState(() => _isLoading = true);
    }

    final api = BoardApiService();
    try {
      final serverBoardsData = await api.getJoinedBoards();
      logger.i("Server returned ${serverBoardsData.length} boards");

      List<BoardModel> freshJoinedBoards = [];

      Set<String> serverIds = {};

      for (var data in serverBoardsData) {
        final String id = data['id'];
        final String title = data['name'];
        serverIds.add(id);

        final newBoard = BoardModel(id: id, title: title, isJoined: true);

        freshJoinedBoards.add(newBoard);

        await BoardStorage.saveBoard(newBoard, isConnectedBoard: true);
      }

      var currentLocal = await BoardStorage.loadAllBoards();
      for (var local in currentLocal) {
        if (local.isJoined &&
            local.id != null &&
            !serverIds.contains(local.id)) {
          await BoardStorage.deleteBoard(local.id!, isConnectedBoard: true);
        }
      }

      if (mounted) {
        setState(() {
          _joinedBoards = freshJoinedBoards;
          _isLoading = false;
        });
      }
    } catch (e) {
      logger.e("Error syncing with server: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Помилка синхронізації: $e")));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showJoinNewBoardDialog(BuildContext context) async {
    final idController = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        bool isDialogLoading = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(S.t('joined')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: idController,
                    decoration: InputDecoration(labelText: S.t('board_id')),
                    autofocus: true,
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
                      isDialogLoading
                          ? null
                          : () async {
                            final id = idController.text.trim();
                            if (id.isEmpty) return;

                            setDialogState(() => isDialogLoading = true);

                            try {
                              final api = BoardApiService();
                              await api.joinBoard(id);

                              if (mounted) Navigator.pop(context);

                              await _loadBoards();
                            } on BoardLimitException {
                              if (mounted) {
                                Navigator.pop(context);
                                showDialog(
                                  context: context,
                                  builder:
                                      (context) => AlertDialog(
                                        title: const Text("Ліміт"),
                                        content: const Text(
                                          "Досягнуто ліміт дошок",
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed:
                                                () => Navigator.pop(context),
                                            child: const Text("OK"),
                                          ),
                                        ],
                                      ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                try {
                                  setDialogState(() => isDialogLoading = false);
                                } catch (_) {}
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("${S.t('error_prefix')} $e"),
                                  ),
                                );
                              }
                            }
                          },
                  child:
                      isDialogLoading
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : Text(S.t('add')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _deleteBoard(BoardModel board) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(S.t('delete_q')),
            content: Text("${S.t('delete_q')} '${board.title}'?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(S.t('no')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: Text(S.t('yes')),
              ),
            ],
          ),
    );

    if (confirm != true || board.id == null) return;

    setState(() => _isLoading = true);

    try {
      try {
        final api = BoardApiService();
        await api.leaveBoard(board.id!);
      } catch (e) {
        logger.w("Could not leave board on server (offline?): $e");
      }

      await BoardStorage.deleteBoard(board.id!);
      await _loadBoards();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${S.t('load_error')}: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                    style: IconButton.styleFrom(backgroundColor: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      S.t('joined'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF009688),
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child:
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                        onRefresh: _loadBoards,
                        child: _buildBody(),
                      ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'join_btn',
        onPressed: () => _showJoinNewBoardDialog(context),
        child: const Icon(Icons.add_link),
      ),
    );
  }

  Widget _buildBody() {
    if (_joinedBoards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.link_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              S.t('no_joined_boards'),
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final int crossAxisCount = constraints.maxWidth < 600 ? 2 : 4;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
          itemCount: _joinedBoards.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.3,
          ),
          itemBuilder: (context, index) {
            final board = _joinedBoards[index];
            return BoardCard(
              board: board,
              isJoinScreen: true,
              onTap: () {
                if (board.id != null) {
                  widget.onJoinBoard(board.id!, board.title ?? "Guest");
                }
              },
              onDelete: () => _deleteBoard(board),
            );
          },
        );
      },
    );
  }
}
