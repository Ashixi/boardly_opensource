import 'package:boardly/data/board_storage.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:boardly/services/localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
    if (!widget.isPro && _joinedBoards.isNotEmpty) {
      showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(S.t('limit_reached')),
              content: Text(S.t('limit_join_desc')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(S.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(context);

                    String urlString;
                    if (appLocale.value.languageCode == 'uk') {
                      urlString = "https://boardly.studio/ua/profile.html";
                    } else {
                      urlString = "https://boardly.studio/en/login.html";
                    }

                    final Uri url = Uri.parse(urlString);
                    if (await canLaunchUrl(url)) {
                      await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  child: Text(S.t('manage_subscription')),
                ),
              ],
            ),
      );
      return;
    }

    final idController = TextEditingController();
    final titleController = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(S.t('joined')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: S.t('title_for_self')),
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
              onPressed: () async {
                final id = idController.text.trim();
                final title = titleController.text.trim();
                if (id.isEmpty || title.isEmpty) return;

                final newBoard = BoardModel(
                  id: id,
                  title: title,
                  isJoined: true,
                );
                try {
                  await BoardStorage.saveBoard(
                    newBoard,
                    isConnectedBoard: true,
                  );
                  if (context.mounted) Navigator.pop(context);
                  await _loadBoards();
                } catch (e) {}
              },
              child: Text(S.t('add')),
            ),
          ],
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
                child: Text(S.t('yes')),
              ),
            ],
          ),
    );

    if (confirm != true || board.id == null) return;

    try {
      await BoardStorage.deleteBoard(board.id!);
      await _loadBoards();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${S.t('load_error')}: $e")));
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
