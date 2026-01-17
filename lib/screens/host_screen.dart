import 'package:boardly/screens/start_screen.dart';
import 'package:flutter/material.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/logger.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:boardly/services/localization.dart';
import 'package:url_launcher/url_launcher.dart';

class HostScreen extends StatefulWidget {
  final Future<void> Function(BoardModel board) onOpenAndHostBoard;
  final Future<BoardModel> Function(String boardName) onAddNewAndHostBoard;
  final Future<void> Function(BoardModel board) onDeleteBoard;
  final bool isPro;

  const HostScreen({
    super.key,
    required this.onOpenAndHostBoard,
    required this.onAddNewAndHostBoard,
    required this.onDeleteBoard,
    required this.isPro,
  });

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  List<BoardModel> hostingBoards = [];
  bool isLoading = true;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final allBoards = await BoardStorage.loadAllBoards();
      final List<BoardModel> filtered = [];

      for (var b in allBoards) {
        if (b.isJoined) continue;

        if (b.isConnectionBoard) {
          logger.i("Fixing corrupted host board: ${b.title}");
          b.isConnectionBoard = false;
          await BoardStorage.saveBoard(b);
        }

        if (b.ownerId == null) continue;

        filtered.add(b);
      }

      if (!mounted) return;
      setState(() {
        hostingBoards = filtered;
        isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        errorMessage = "${S.t('load_error')}: $e";
        isLoading = false;
      });
    }
  }

  Future<void> _handleDelete(BoardModel board) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(S.t('delete_q')),
            content: Text("${S.t('delete_board_q')} '${board.title}'?"),
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

    if (confirm != true) return;

    setState(() => hostingBoards.remove(board));

    try {
      await widget.onDeleteBoard(board);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.t('board_deleted_success'))));
      }
    } catch (e) {
      await _loadBoards();
    }
  }

  Future<void> _handleCreateNewBoard() async {
    final userData = await AuthStorage.getUserData();
    if (userData == null) {
      if (!mounted) return;
      return;
    }

    if (!widget.isPro && hostingBoards.length >= 4) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(S.t('limit_reached')),
              content: Text(S.t('limit_host_desc')),
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

    if (!mounted) return;
    String? customName = await showDialog<String>(
      context: context,
      builder: (context) {
        String tempName = "";
        return AlertDialog(
          title: Text(S.t('create_new_board')),
          content: TextField(
            autofocus: true,
            decoration: InputDecoration(hintText: S.t('board_name_hint')),
            onChanged: (v) => tempName = v,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(S.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, tempName),
              child: Text(S.t('create')),
            ),
          ],
        );
      },
    );

    if (customName == null || customName.trim().isEmpty) return;

    try {
      final newBoard = await widget.onAddNewAndHostBoard(customName.trim());
      if (!mounted) return;

      await _loadBoards();
      await widget.onOpenAndHostBoard(newBoard);
    } catch (e) {
      logger.e("Error creating host board: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
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
                      S.t('hosting'),
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
              child: RefreshIndicator(
                onRefresh: _loadBoards,
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'host_btn',
        onPressed: _handleCreateNewBoard,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
    if (isLoading) return const Center(child: CircularProgressIndicator());
    if (errorMessage != null) {
      return Center(
        child: Text(errorMessage!, style: const TextStyle(color: Colors.red)),
      );
    }
    if (hostingBoards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_upload_outlined,
              size: 64,
              color: Colors.grey[300],
            ),
            SizedBox(height: 16),
            Text(
              S.t('no_boards_for_hosting'),
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
          itemCount: hostingBoards.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.3,
          ),
          itemBuilder: (context, index) {
            final board = hostingBoards[index];
            return BoardCard(
              board: board,
              isHostScreen: true,
              onTap: () async => await widget.onOpenAndHostBoard(board),
              onDelete: () => _handleDelete(board),
            );
          },
        );
      },
    );
  }
}
