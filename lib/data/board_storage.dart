import 'dart:io';
import 'package:boardly/models/board_model.dart';
import 'package:path/path.dart' as path;
import 'dart:convert';
import 'package:boardly/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class BoardStorage {
  static const String _rootPathKey = 'boardy_root_path';
  static String? _cachedRootPath;

  static Future<String?> getRootPath() async {
    if (_cachedRootPath != null) return _cachedRootPath;

    final prefs = await SharedPreferences.getInstance();
    String? storedPath = prefs.getString(_rootPathKey);

    if (storedPath != null) {
      if (await Directory(storedPath).exists()) {
        _cachedRootPath = storedPath;
        return storedPath;
      }
    }

    final appDir = await getApplicationSupportDirectory();
    final defaultPath = path.join(appDir.path, 'Boardly_Workspace');

    if (!await Directory(defaultPath).exists()) {
      await Directory(defaultPath).create(recursive: true);
    }

    _cachedRootPath = defaultPath;
    return defaultPath;
  }

  static Future<void> setRootPath(String newPath) async {
    final prefs = await SharedPreferences.getInstance();
    final boardyPath = path.join(newPath, 'Boardly');

    if (!await Directory(boardyPath).exists()) {
      await Directory(boardyPath).create(recursive: true);
    }

    await prefs.setString(_rootPathKey, boardyPath);
    _cachedRootPath = boardyPath;
    await _createDirectoryStructureIfNeeded();
    logger.i('User selected new root path: $boardyPath');
  }

  static Future<void> _createDirectoryStructureIfNeeded() async {
    final root = await getRootPath();
    if (root == null) return;
    await Directory(path.join(root, 'boards')).create(recursive: true);
  }

  static Future<String> _getBoardsBaseDir() async {
    final root = await getRootPath();
    if (root == null) throw Exception("Root directory not selected");
    final dir = Directory(path.join(root, 'boards'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  static Future<String?> _findExistingBoardPath(String boardId) async {
    final baseDir = await _getBoardsBaseDir();
    final dir = Directory(baseDir);

    if (await dir.exists()) {
      await for (var entity in dir.list()) {
        if (entity is Directory) {
          final folderName = path.basename(entity.path);

          if (folderName.endsWith(boardId)) {
            return entity.path;
          }
          final metaFile = File(path.join(entity.path, 'meta.json'));
          if (await metaFile.exists()) {
            try {
              final content = await metaFile.readAsString();
              final json = jsonDecode(content);
              if (json['id'] == boardId) {
                return entity.path;
              }
            } catch (_) {}
          }
        }
      }
    }
    return null;
  }

  static Future<String> getBoardDir(
    String boardId, {
    bool isConnected = false,
  }) async {
    String? existingPath = await _findExistingBoardPath(boardId);
    if (existingPath != null) return existingPath;

    final baseDir = await _getBoardsBaseDir();
    return path.join(baseDir, boardId);
  }

  static Future<String> getBoardFilesDir(
    String boardId, {
    bool isConnected = false,
  }) async {
    final boardPath = await getBoardDir(boardId);
    final filesDir = Directory(path.join(boardPath, 'files'));
    if (!await filesDir.exists()) await filesDir.create(recursive: true);
    return filesDir.path;
  }

  static Future<String> getBoardFilesDirAuto(String boardId) async {
    return getBoardFilesDir(boardId);
  }

  static Future<void> saveBoard(
    BoardModel board, {
    bool isConnectedBoard = false,
  }) async {
    if (board.id == null) return;

    if (isConnectedBoard ||
        board.isConnectionBoard ||
        board.id!.startsWith('[#') ||
        (board.title == null && board.id!.startsWith('['))) {
      return;
    }

    try {
      final baseDir = await _getBoardsBaseDir();

      String? currentPath = await _findExistingBoardPath(board.id!);
      String targetPath;

      if (currentPath != null) {
        targetPath = currentPath;
      } else {
        String safeTitle = _sanitizeFolderName(board.title ?? "Board");
        if (safeTitle.isEmpty) safeTitle = "Board";

        String folderName = "${safeTitle}_${board.id}";

        targetPath = path.join(baseDir, folderName);

        await Directory(targetPath).create(recursive: true);
        logger.i("Створено нову папку: $targetPath");
      }

      final metaFilePath = path.join(targetPath, 'meta.json');
      final tempFilePath = path.join(targetPath, 'meta.json.tmp');
      final tempFile = File(tempFilePath);
      final metaFile = File(metaFilePath);

      final jsonData = jsonEncode(board.toJson());

      await tempFile.writeAsString(jsonData, flush: true);

      int attempts = 0;
      while (attempts < 5) {
        try {
          if (await metaFile.exists()) {
            await metaFile.delete();
          }
          await tempFile.rename(metaFilePath);
          break;
        } catch (e) {
          attempts++;
          await Future.delayed(Duration(milliseconds: 200 * attempts));
        }
      }

      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    } catch (e) {
      logger.e('Error saving board: $e');
    }
  }

  static String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '').trim();
  }

  static Future<List<BoardModel>> loadAllBoards() async {
    try {
      final boardsDir = await _getBoardsBaseDir();
      return _scanDirForBoards(boardsDir);
    } catch (e) {
      logger.e('Error loading boards: $e');
      return [];
    }
  }

  static Future<List<BoardModel>> _scanDirForBoards(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    List<BoardModel> boards = [];
    await for (var entity in dir.list()) {
      if (entity is Directory) {
        final folderName = path.basename(entity.path);

        if (folderName.startsWith('[') && folderName.endsWith(']')) {
          continue;
        }

        final metaFile = File(path.join(entity.path, 'meta.json'));
        if (await metaFile.exists()) {
          try {
            final content = await metaFile.readAsString();
            final board = BoardModel.fromJson(jsonDecode(content));
            boards.add(board);
          } catch (_) {}
        }
      }
    }
    return boards;
  }

  static Future<void> deleteBoard(
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    try {
      final boardPath = await getBoardDir(boardId);
      final dir = Directory(boardPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      logger.e('Error deleting board: $e');
      rethrow;
    }
  }

  static Future<String> createEmptyFile(
    String fileNameWithExtension,
    String boardId, {
    bool isConnectedBoard = false,
    String initialContent = '',
  }) async {
    try {
      final filesDir = await getBoardFilesDir(boardId);
      final fileName = path.basename(fileNameWithExtension);
      String newPath = path.join(filesDir, fileName);
      int counter = 1;
      while (await File(newPath).exists()) {
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final ext = path.extension(fileName);
        newPath = path.join(filesDir, '${nameWithoutExt}_$counter$ext');
        counter++;
      }
      final newFile = File(newPath);
      await newFile.writeAsString(initialContent);
      return newPath;
    } catch (e) {
      rethrow;
    }
  }

  static Future<String> addFileToBoard(
    String originalFilePath,
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    try {
      final filesDir = await getBoardFilesDir(boardId);
      final fileName = path.basename(originalFilePath);
      String newPath = path.join(filesDir, fileName);
      int counter = 1;
      while (await File(newPath).exists()) {
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final ext = path.extension(fileName);
        newPath = path.join(filesDir, '${nameWithoutExt}_$counter$ext');
        counter++;
      }
      await File(originalFilePath).copy(newPath);
      return newPath;
    } catch (e) {
      rethrow;
    }
  }
}
