import 'package:boardly/data/board_storage.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:boardly/services/localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
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
    setState(() => _isLoading = true);
    try {
      final allBoards = await BoardStorage.loadAllBoards();
      final joined = allBoards.where((b) => b.isJoined == true).toList();

      if (mounted) {
        setState(() {
          _joinedBoards = joined;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showJoinNewBoardDialog(BuildContext context) async {
    // Видаляємо локальну перевірку лімітів на початку.
    // Тепер перевірка відбувається на сервері при спробі приєднання.

    final idController = TextEditingController();
    final titleController = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        bool isDialogLoading = false; // Локальний стан завантаження для діалогу

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(S.t('joined')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: InputDecoration(
                      labelText: S.t('title_for_self'),
                    ),
                    autofocus: true,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: idController,
                    decoration: InputDecoration(labelText: S.t('board_id')),
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
                            final title = titleController.text.trim();
                            if (id.isEmpty || title.isEmpty) return;

                            setDialogState(() => isDialogLoading = true);

                            try {
                              // 1. Спроба приєднатися на сервері (Тут перевіряються ліміти)
                              final api = BoardApiService();
                              await api.joinBoard(id);

                              // 2. Якщо успішно — зберігаємо локально
                              final newBoard = BoardModel(
                                id: id,
                                title: title,
                                isJoined: true,
                              );

                              await BoardStorage.saveBoard(
                                newBoard,
                                isConnectedBoard: true,
                              );

                              if (mounted)
                                Navigator.pop(
                                  context,
                                ); // Закриваємо діалог вводу
                              await _loadBoards(); // Оновлюємо список
                            } on BoardLimitException {
                              // ЛІМІТ ВИЧЕРПАНО (403 від сервера)
                              if (mounted) {
                                Navigator.pop(
                                  context,
                                ); // Закриваємо діалог вводу

                                // Відкриваємо діалог про Pro версію
                                showDialog(
                                  context: context,
                                  builder:
                                      (context) => AlertDialog(
                                        title: Text(S.t('limit_reached')),
                                        content: Text(S.t('limit_join_desc')),
                                        actions: [
                                          TextButton(
                                            onPressed:
                                                () => Navigator.pop(context),
                                            child: Text(S.t('cancel')),
                                          ),
                                          ElevatedButton(
                                            onPressed: () async {
                                              Navigator.pop(context);
                                              String urlString =
                                                  (appLocale
                                                              .value
                                                              .languageCode ==
                                                          'uk')
                                                      ? "https://boardly.studio/ua/profile.html"
                                                      : "https://boardly.studio/en/login.html";

                                              final Uri url = Uri.parse(
                                                urlString,
                                              );
                                              if (await canLaunchUrl(url)) {
                                                await launchUrl(
                                                  url,
                                                  mode:
                                                      LaunchMode
                                                          .externalApplication,
                                                );
                                              }
                                            },
                                            child: Text(
                                              S.t('manage_subscription'),
                                            ),
                                          ),
                                        ],
                                      ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("${S.t('error_prefix')} $e"),
                                  ),
                                );
                              }
                            } finally {
                              if (mounted && isDialogLoading) {
                                setDialogState(() => isDialogLoading = false);
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
