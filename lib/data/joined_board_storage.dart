import 'package:boardly/models/joined_board_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

class JoinedBoardStorage {
  static const String _joinedBoardsKey = 'joined_boards_list';

  /// Завантажує список збережених дошок
  static Future<List<JoinedBoardInfo>> loadJoinedBoards() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> boardsJsonList =
        prefs.getStringList(_joinedBoardsKey) ?? [];

    return boardsJsonList
        .map((str) => JoinedBoardInfo.fromJsonString(str))
        .toList();
  }

  /// Зберігає повний список дошок
  static Future<void> _saveBoardsList(List<JoinedBoardInfo> boards) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> boardsJsonList =
        boards.map((b) => b.toJsonString()).toList();
    await prefs.setStringList(_joinedBoardsKey, boardsJsonList);
  }

  /// Додає нову дошку до списку
  static Future<void> addJoinedBoard(JoinedBoardInfo board) async {
    final boards = await loadJoinedBoards();
    boards.removeWhere((b) => b.id == board.id);
    boards.add(board);
    await _saveBoardsList(boards);
  }

  /// Видаляє дошку зі списку
  static Future<void> removeJoinedBoard(String boardId) async {
    final boards = await loadJoinedBoards();
    boards.removeWhere((b) => b.id == boardId);
    await _saveBoardsList(boards);
  }
}
