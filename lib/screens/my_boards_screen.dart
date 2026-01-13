import 'package:boardly/data/board_storage.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/screens/tab.dart';
import 'package:flutter/material.dart';
import 'package:boardly/widgets/board_card.dart';
import 'package:uuid/uuid.dart';
import '../services/localization.dart';

class MyBoardsScreen extends StatefulWidget {
  const MyBoardsScreen({super.key});

  @override
  State<MyBoardsScreen> createState() => _MyBoardsScreenState();
}

class _MyBoardsScreenState extends State<MyBoardsScreen> {
  List<BoardModel> localBoards = [];

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

      setState(() {
        localBoards =
            allBoards.where((b) {
              return !b.isJoined && !b.isConnectionBoard && b.ownerId == null;
            }).toList();

        isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = "${S.t('load_error')}: $e";
          isLoading = false;
        });
      }
    }
  }

  Future<void> _addLocalBoard() async {
    String? customName = await showDialog<String>(
      context: context,
      builder: (context) {
        String tempName = "";
        return AlertDialog(
          title: Text(S.t('create_new_board')),
          content: TextField(
            autofocus: true,
            decoration: InputDecoration(
              labelText: S.t('username'),
              hintText: S.t('board_name_hint'),
            ),
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
    customName = customName.trim();

    final uniqueId = const Uuid().v4();
    final newBoard = BoardModel(
      id: uniqueId,
      title: customName,
      isJoined: false,
      isConnectionBoard: false,
    );

    try {
      await BoardStorage.saveBoard(newBoard, isConnectedBoard: false);
      if (!mounted) return;
      await _loadBoards();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CanvasTabbedBoard(initialBoard: newBoard),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("${S.t('delete_error')}: $e")));
    }
  }

  Future<void> _deleteBoard(BoardModel board) async {
    try {
      await BoardStorage.deleteBoard(
        board.id!,
        isConnectedBoard: board.isJoined,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${S.t('board_deleted_success')} '${board.title}'"),
        ),
      );
      await _loadBoards();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("${S.t('delete_error')}: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
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
                      S.t('my_boards'),
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
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_local_board',
        icon: const Icon(Icons.add),
        label: Text(S.t('create')),
        onPressed: _addLocalBoard,
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

    if (localBoards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 64,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 16),
            Text(
              S.t('no_local_boards'),
              style: TextStyle(color: Colors.grey[600]),
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
          itemCount: localBoards.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.3,
          ),
          itemBuilder: (context, index) {
            final board = localBoards[index];
            return BoardCard(
              board: board,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => CanvasTabbedBoard(initialBoard: board),
                  ),
                );
              },
              onDelete: () => _deleteBoard(board),
            );
          },
        );
      },
    );
  }
}
