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
  final Future<void> Function(BoardModel board) onHostExistingBoard;
  final Future<void> Function(BoardModel board) onDeleteBoard;
  final bool isPro;

  const HostScreen({
    super.key,
    required this.onOpenAndHostBoard,
    required this.onAddNewAndHostBoard,
    required this.onHostExistingBoard,
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

  Future<BoardModel?> _showLocalBoardPicker() async {
    final allBoards = await BoardStorage.loadAllBoards();

    final localCandidates =
        allBoards
            .where(
              (b) => !b.isJoined && !b.isConnectionBoard && b.ownerId == null,
            )
            .toList();

    if (!mounted) return null;

    if (localCandidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.t('no_local_boards_available'))));
      return null;
    }

    return await showDialog<BoardModel>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(S.t('select_board_to_host')),
            content: SizedBox(
              width: double.maxFinite,
              height: 300,
              child: ListView.separated(
                itemCount: localCandidates.length,
                separatorBuilder: (ctx, i) => const Divider(),
                itemBuilder: (ctx, i) {
                  final board = localCandidates[i];
                  return ListTile(
                    leading: const Icon(
                      Icons.dashboard_customize,
                      color: Colors.grey,
                    ),
                    title: Text(board.title ?? "Untitled"),
                    subtitle: Text("ID: ...${board.id?.substring(0, 4) ?? ''}"),
                    onTap: () {
                      Navigator.pop(ctx, board);
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text(S.t('cancel')),
              ),
            ],
          ),
    );
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

  Future<void> _handleCreateOrHostBoard() async {
    final userData = await AuthStorage.getUserData();
    if (userData == null) return;

    if (!widget.isPro && hostingBoards.length >= 4) {
      if (!mounted) return;
      _showLimitDialog();
      return;
    }

    if (!mounted) return;

    final String? action = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (ctx) => _buildSelectionDialog(ctx),
    );

    if (action == null) return;

    if (action == 'create_new') {
      await _createNewBoardFlow();
    } else if (action == 'host_existing') {
      await _hostExistingBoardFlow();
    }
  }

  Widget _buildSelectionDialog(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.zero,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SizedBox.expand(
          child: Center(
            child: SingleChildScrollView(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 32,
                runSpacing: 32,
                children: [
                  _SquareButton(
                    title: S.t('create_new'),
                    icon: Icons.add_circle_outline,
                    color: const Color(0xFF009688),
                    size: 320,
                    onTap: () => Navigator.pop(context, 'create_new'),
                  ),
                  _SquareButton(
                    title: S.t('from_device'),
                    icon: Icons.upload_file,
                    color: Colors.blueAccent,
                    size: 320,
                    onTap: () => Navigator.pop(context, 'host_existing'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showLimitDialog() {
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
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
                child: Text(S.t('manage_subscription')),
              ),
            ],
          ),
    );
  }

  Future<void> _hostExistingBoardFlow() async {
    final selectedBoard = await _showLocalBoardPicker();
    if (selectedBoard != null) {
      try {
        setState(() => isLoading = true);
        await widget.onHostExistingBoard(selectedBoard);
        await _loadBoards();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Error hosting board: $e")));
        }
      } finally {
        if (mounted) setState(() => isLoading = false);
      }
    }
  }

  Future<void> _createNewBoardFlow() async {
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
        onPressed: _handleCreateOrHostBoard,
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

class _SquareButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  const _SquareButton({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 130,
  });

  @override
  Widget build(BuildContext context) {
    final double iconSize = size * 0.25;
    final double fontSize = size * 0.06;

    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.15),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size * 0.15),
        splashColor: color.withOpacity(0.1),
        highlightColor: color.withOpacity(0.05),
        child: Container(
          width: size,
          height: size,
          padding: EdgeInsets.symmetric(
            horizontal: size * 0.08,
            vertical: size * 0.05,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.all(size * 0.08),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: iconSize, color: color),
              ),
              SizedBox(height: size * 0.04),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
