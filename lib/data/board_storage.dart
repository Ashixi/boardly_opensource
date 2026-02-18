import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:boardly/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:boardly/models/board_model.dart';
import 'package:synchronized/synchronized.dart';

class BoardStorage {
  static const String _rootPathKey = 'boardy_root_path';
  static String? _cachedRootPath;

  static final _saveLock = Lock();

  static Future<String?> getRootPath() async {
    if (_cachedRootPath != null) return _cachedRootPath;
    final prefs = await SharedPreferences.getInstance();
    String? storedPath = prefs.getString(_rootPathKey);
    if (storedPath != null && await Directory(storedPath).exists()) {
      _cachedRootPath = storedPath;
      return storedPath;
    }
    final appDir = await getApplicationSupportDirectory();
    final defaultPath = path.join(appDir.path, 'Boardly_Workspace');
    if (!await Directory(defaultPath).exists()) {
      await Directory(defaultPath).create(recursive: true);
    }
    _cachedRootPath = defaultPath;
    return defaultPath;
  }

  static Future<void> setRootPath(
    String newUserPath, {
    bool moveData = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final oldRootPath = _cachedRootPath ?? prefs.getString(_rootPathKey);
    final newBoardlyPath = path.join(newUserPath, 'Boardly');
    if (oldRootPath == newBoardlyPath) return;
    final newBoardsDir = Directory(path.join(newBoardlyPath, 'boards'));
    if (!await newBoardsDir.exists())
      await newBoardsDir.create(recursive: true);
    if (moveData && oldRootPath != null) {
      final oldBoardsDir = Directory(path.join(oldRootPath, 'boards'));
      if (await oldBoardsDir.exists()) {
        try {
          if (await newBoardsDir.list().isEmpty) await newBoardsDir.delete();
          await oldBoardsDir.rename(newBoardsDir.path);
          logger.i("✅ Boards moved via rename");
        } catch (e) {
          logger.w("⚠️ Rename failed (different drives?), copying...");
          await _copyDirectory(oldBoardsDir, newBoardsDir);
          await oldBoardsDir.delete(recursive: true);
        }
      }
    }
    await prefs.setString(_rootPathKey, newBoardlyPath);
    _cachedRootPath = newBoardlyPath;
    logger.i('New root path set: $newBoardlyPath');
  }

  static Future<void> saveBoard(
    BoardModel board, {
    bool isConnectedBoard = false,
  }) async {
    await _saveLock.synchronized(() async {
      if (board.id == null) return;

      if (board.id!.startsWith('[')) {
        logger.i("🚫 Save skipped for internal component: ${board.id}");
        return;
      }

      try {
        final baseDir = await _getBoardsBaseDir();

        String? existingPath = await _findExistingBoardPath(board.id!);
        String targetPath =
            existingPath ??
            path.join(
              baseDir,
              "${_sanitizeFolderName(board.title ?? 'Board')}_${board.id}",
            );

        final targetDir = Directory(targetPath);

        if (!await targetDir.exists()) {
          await targetDir.create(recursive: true);
        }

        final metaFile = File(path.join(targetPath, 'meta.json'));
        final tmpFile = File(path.join(targetPath, 'meta.json.tmp'));

        await tmpFile.writeAsString(jsonEncode(board.toJson()), flush: true);

        bool saved = false;
        int attempts = 0;
        const maxAttempts = 10;

        while (attempts < maxAttempts && !saved) {
          try {
            await tmpFile.rename(metaFile.path);
            saved = true;
          } catch (renameError) {
            try {
              if (await metaFile.exists()) await metaFile.delete();
              await tmpFile.rename(metaFile.path);
              saved = true;
            } catch (deleteRenameError) {
              attempts++;
              if (attempts < maxAttempts) {
                await Future.delayed(Duration(milliseconds: 100 * attempts));
              } else {
                try {
                  await tmpFile.copy(metaFile.path);
                  await tmpFile.delete();
                  saved = true;
                } catch (_) {}
              }
            }
          }
        }
      } catch (e, stack) {
        logger.e('Error saving board: $e');
      }
    });
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

  static Future<void> deleteBoard(
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    try {
      final boardPath = await getBoardDir(
        boardId,
        isConnectedBoard: isConnectedBoard,
      );
      if (path.basename(boardPath).startsWith('[')) return;

      final dir = Directory(boardPath);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      logger.e('Error deleting board: $e');
      rethrow;
    }
  }

  static Future<String> createEmptyFile(
    String fileName,
    String boardId, {
    bool isConnectedBoard = false,
    String initialContent = '',
  }) async {
    final filesDir = await getBoardFilesDir(
      boardId,
      isConnectedBoard: isConnectedBoard,
    );
    final filePath = await _getUniqueFilePath(filesDir, fileName);

    if (!await Directory(filesDir).exists()) {
      logger.w(
        "⚠️ Cannot create file for internal ID: $boardId (Folder missing)",
      );
      return filePath;
    }

    await File(filePath).writeAsString(initialContent);
    return filePath;
  }

  static Future<String> addFileToBoard(
    String originalPath,
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    final filesDir = await getBoardFilesDir(
      boardId,
      isConnectedBoard: isConnectedBoard,
    );

    if (!await Directory(filesDir).exists()) {
      return path.join(filesDir, path.basename(originalPath));
    }

    final fileName = path.basename(originalPath);
    final newPath = await _getUniqueFilePath(filesDir, fileName);
    await File(originalPath).copy(newPath);
    return newPath;
  }

  static Future<String> _getUniqueFilePath(
    String dirPath,
    String fileName,
  ) async {
    String newPath = path.join(dirPath, fileName);
    if (!await File(newPath).exists()) return newPath;

    final name = path.basenameWithoutExtension(fileName);
    final ext = path.extension(fileName);
    int counter = 1;
    while (await File(newPath).exists()) {
      newPath = path.join(dirPath, '${name}_$counter$ext');
      counter++;
    }
    return newPath;
  }

  static Future<List<BoardModel>> _scanDirForBoards(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    List<BoardModel> boards = [];
    await for (var entity in dir.list()) {
      if (entity is Directory) {
        final folderName = path.basename(entity.path);
        if (folderName.startsWith('[') && folderName.endsWith(']')) continue;
        final metaFile = File(path.join(entity.path, 'meta.json'));
        if (!await metaFile.exists()) continue;
        try {
          final content = await metaFile.readAsString();
          boards.add(BoardModel.fromJson(jsonDecode(content)));
        } catch (e) {
          logger.e('❌ Corrupted board meta at ${entity.path}: $e');
        }
      }
    }
    return boards;
  }

  static Future<String?> _findExistingBoardPath(String boardId) async {
    if (boardId.startsWith('[')) return null;

    final baseDir = await _getBoardsBaseDir();
    final dir = Directory(baseDir);
    if (!await dir.exists()) return null;
    try {
      await for (var entity in dir.list()) {
        if (entity is Directory) {
          if (path.basename(entity.path).endsWith(boardId)) return entity.path;
          final metaFile = File(path.join(entity.path, 'meta.json'));
          if (await metaFile.exists()) {
            try {
              final content = await metaFile.readAsString();
              if (content.contains('"$boardId"')) {
                final json = jsonDecode(content);
                if (json['id'] == boardId) return entity.path;
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<String> _getBoardsBaseDir() async {
    final root = await getRootPath();
    if (root == null) throw Exception("Root not selected");
    final dir = Directory(path.join(root, 'boards'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  static Future<String> getBoardDir(
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    final foundPath = await _findExistingBoardPath(boardId);
    if (foundPath != null) return foundPath;

    final baseDir = await _getBoardsBaseDir();
    final defaultPath = path.join(baseDir, boardId);

    if (boardId.startsWith('[')) {
      return defaultPath;
    }

    return defaultPath;
  }

  static Future<String> getBoardFilesDir(
    String boardId, {
    bool isConnectedBoard = false,
  }) async {
    final boardPath = await getBoardDir(
      boardId,
      isConnectedBoard: isConnectedBoard,
    );
    final filesDir = Directory(path.join(boardPath, 'files'));

    if (!boardId.startsWith('[')) {
      if (!await filesDir.exists()) await filesDir.create(recursive: true);
    }

    return filesDir.path;
  }

  static Future<String> getBoardFilesDirAuto(String boardId) async {
    return getBoardFilesDir(boardId);
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final newPath = path.join(destination.path, path.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  static String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '').trim();
  }
}
