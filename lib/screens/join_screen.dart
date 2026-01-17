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
    // 1. Спочатку показуємо те, що є локально (кеш)
    if (_joinedBoards.isEmpty) {
      try {
        var allBoards = await BoardStorage.loadAllBoards();
        if (mounted) {
          setState(() {
            _joinedBoards = allBoards.where((b) => b.isJoined == true).toList();
          });
        }
      } catch (e) {
        // ігноруємо помилки локального завантаження на старті
      }
    }

    // Не блокуємо UI лоадером, якщо дані вже є (Pull-to-refresh ефект)
    if (_joinedBoards.isEmpty) {
      setState(() => _isLoading = true);
    }

    final api = BoardApiService();
    try {
      // 2. Отримуємо свіжі дані з сервера
      final serverBoardsData = await api.getJoinedBoards();
      logger.i(
        "Server returned ${serverBoardsData.length} boards",
      ); // Лог для перевірки

      // 3. Формуємо новий список об'єктів BoardModel прямо з відповіді сервера
      List<BoardModel> freshJoinedBoards = [];

      // Список ID для перевірки видалення
      Set<String> serverIds = {};

      for (var data in serverBoardsData) {
        final String id = data['id'];
        final String title =
            data['name']; // ВАЖЛИВО: Бекенд віддає 'name', а не 'title'
        serverIds.add(id);

        final newBoard = BoardModel(
          id: id,
          title: title,
          isJoined: true,
          // Зберігаємо інші поля, якщо вони є локально (наприклад, шляхи до файлів)
          // Але оскільки це join screen, шляхи підтягнуться пізніше
        );

        freshJoinedBoards.add(newBoard);

        // 4. Асинхронно оновлюємо кеш (зберігаємо на диск)
        // Не чекаємо await, щоб не гальмувати UI, або чекаємо, якщо критично
        await BoardStorage.saveBoard(newBoard, isConnectedBoard: true);
      }

      // 5. Видаляємо локально ті, яких немає на сервері (синхронізація видалення)
      var currentLocal = await BoardStorage.loadAllBoards();
      for (var local in currentLocal) {
        if (local.isJoined &&
            local.id != null &&
            !serverIds.contains(local.id)) {
          await BoardStorage.deleteBoard(local.id!, isConnectedBoard: true);
        }
      }

      // 6. ОНОВЛЮЄМО UI ДАНИМИ З СЕРВЕРА (Джерело правди)
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
    final titleController = TextEditingController();

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

                            // 1. Запускаємо лоадер
                            setDialogState(() => isDialogLoading = true);

                            try {
                              final api = BoardApiService();
                              await api.joinBoard(id);

                              final newBoard = BoardModel(
                                id: id,
                                title: title,
                                isJoined: true,
                              );

                              await BoardStorage.saveBoard(
                                newBoard,
                                isConnectedBoard: true,
                              );

                              // 2. УСПІХ: Просто закриваємо діалог.
                              // Не треба робити setDialogState(false), бо діалогу вже не буде.
                              if (mounted) Navigator.pop(context);

                              await _loadBoards();
                            } on BoardLimitException {
                              // 3. ПОМИЛКА ЛІМІТУ: Діалог залишається відкритим?
                              // Тут ви закриваєте діалог вручну, тому теж не треба оновлювати стан.
                              if (mounted) {
                                Navigator.pop(context);
                                // ... ваш код показу діалогу про ліміт ...
                                showDialog(
                                  context: context,
                                  builder:
                                      (context) => AlertDialog(
                                        // ... ваш код діалогу ...
                                      ),
                                );
                              }
                            } catch (e) {
                              // 4. ІНША ПОМИЛКА: Діалог залишається, треба вимкнути спінер
                              if (mounted) {
                                // Обгортаємо в try-catch на випадок, якщо юзер сам закрив діалог під час запиту
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
                            // 5. БЛОК FINALLY ВИДАЛЕНО
                            // Ми керуємо станом спінера явно в блоках try/catch
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
