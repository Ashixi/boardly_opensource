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

  // --- 1. Керування кореневою директорією ---

  static Future<String?> getRootPath() async {
    if (_cachedRootPath != null) return _cachedRootPath;

    final prefs = await SharedPreferences.getInstance();
    String? storedPath = prefs.getString(_rootPathKey);

    // Логіка:
    // 1. Якщо шлях є в налаштуваннях І він існує фізично -> повертаємо його.
    // 2. Якщо шляху немає або папку видалили -> створюємо дефолтну в документах додатка.

    if (storedPath != null) {
      if (await Directory(storedPath).exists()) {
        _cachedRootPath = storedPath;
        return storedPath;
      }
    }

    // FALLBACK: Якщо користувач ще не обрав папку, або обрана папка зникла.
    // Використовуємо локальну папку додатка, щоб не крашитись.
    final appDir = await getApplicationSupportDirectory();
    final defaultPath = path.join(appDir.path, 'Boardly_Workspace');

    if (!await Directory(defaultPath).exists()) {
      await Directory(defaultPath).create(recursive: true);
    }

    // Ми НЕ зберігаємо цей шлях у SharedPreferences як "обраний користувачем",
    // щоб при наступному запуску дати шанс обрати знову, або використовувати цей як тимчасовий.
    // Але для поточної сесії використовуємо його.
    _cachedRootPath = defaultPath;

    logger.i('Using default storage path: $defaultPath');
    return defaultPath;
  }

  // Цей метод викликається, коли юзер тицяє кнопку "Обрати папку"
  static Future<void> setRootPath(String newPath) async {
    final prefs = await SharedPreferences.getInstance();

    // Створюємо папку Boardly всередині обраної юзером
    final boardyPath = path.join(newPath, 'Boardly');

    if (!await Directory(boardyPath).exists()) {
      await Directory(boardyPath).create(recursive: true);
    }

    await prefs.setString(_rootPathKey, boardyPath);
    _cachedRootPath = boardyPath;

    // Створюємо структуру папок
    await _createDirectoryStructureIfNeeded();
    logger.i('User selected new root path: $boardyPath');
  }

  static Future<void> _createDirectoryStructureIfNeeded() async {
    final root = await getRootPath();
    if (root == null) return;
    await Directory(path.join(root, 'boards')).create(recursive: true);
  }

  // --- 2. Отримання шляхів ---

  static Future<String> _getBoardsBaseDir() async {
    final root = await getRootPath();
    if (root == null) throw Exception("Root directory not selected");
    final dir = Directory(path.join(root, 'boards'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 🔍 Новий метод: Знаходить шлях до папки дошки за її ID
  /// Сканує папки, щоб знайти ту, де в meta.json лежить потрібний ID.
  static Future<String> getBoardDir(
    String boardId, {
    bool isConnected = false,
  }) async {
    final baseDir = await _getBoardsBaseDir();
    final dir = Directory(baseDir);

    // Перебираємо всі папки в пошуках потрібного ID
    if (await dir.exists()) {
      await for (var entity in dir.list()) {
        if (entity is Directory) {
          final metaFile = File(path.join(entity.path, 'meta.json'));
          if (await metaFile.exists()) {
            try {
              final content = await metaFile.readAsString();
              final json = jsonDecode(content);
              if (json['id'] == boardId) {
                return entity.path; // Знайшли папку!
              }
            } catch (_) {}
          }
        }
      }
    }

    // Якщо не знайшли (наприклад, нова дошка), повертаємо шлях за ID як fallback,
    // але saveBoard це виправить при створенні.
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

  // --- 3. Файлові операції ---

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

      logger.i('Empty file created at: $newPath');
      return newPath;
    } catch (e) {
      logger.e('Error creating empty file: $e');
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
      logger.i('File copied to: $newPath');
      return newPath;
    } catch (e) {
      logger.e('Error copying file: $e');
      rethrow;
    }
  }

  // --- 4. CRUD Дошок ---

  /// Очищає назву від заборонених символів
  static String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }

  static Future<void> saveBoard(
    BoardModel board, {
    bool isConnectedBoard = false,
  }) async {
    if (board.id == null) return;
    try {
      if (isConnectedBoard) {
        return;
      }

      final baseDir = await _getBoardsBaseDir();

      // 1. Формуємо бажану назву папки на основі Title
      String safeTitle = _sanitizeFolderName(board.title ?? "Untitled Board");
      if (safeTitle.isEmpty) safeTitle = "Untitled Board";

      // 2. Шукаємо, чи є вже папка для цього ID
      String currentPath = await getBoardDir(board.id!);
      bool exists = await Directory(currentPath).exists();

      String targetPath;

      if (exists) {
        // Дошка вже існує. Перевіряємо, чи треба перейменовувати.
        final currentDirName = path.basename(currentPath);

        if (currentDirName != safeTitle) {
          String newPathCandidate = path.join(baseDir, safeTitle);
          int counter = 1;
          while (await Directory(newPathCandidate).exists() &&
              newPathCandidate != currentPath) {
            newPathCandidate = path.join(baseDir, '$safeTitle ($counter)');
            counter++;
          }
          try {
            await Directory(currentPath).rename(newPathCandidate);
            targetPath = newPathCandidate;
            logger.i("Renamed board folder to: $targetPath");
          } catch (e) {
            logger.e("Failed to rename folder: $e");
            targetPath = currentPath;
          }
        } else {
          targetPath = currentPath;
        }
      } else {
        // Дошка нова
        String newPathCandidate = path.join(baseDir, safeTitle);
        int counter = 1;
        while (await Directory(newPathCandidate).exists()) {
          newPathCandidate = path.join(baseDir, '$safeTitle ($counter)');
          counter++;
        }
        await Directory(newPathCandidate).create(recursive: true);
        targetPath = newPathCandidate;
      }

      // ▼▼▼ ВИПРАВЛЕННЯ: БЕЗПЕЧНИЙ (АТОМАРНИЙ) ЗАПИС ФАЙЛУ ▼▼▼

      final metaFilePath = path.join(targetPath, 'meta.json');
      final tempFilePath = path.join(
        targetPath,
        'meta.json.tmp',
      ); // Тимчасовий файл
      final tempFile = File(tempFilePath);
      final metaFile = File(metaFilePath);

      final jsonData = jsonEncode(board.toJson());

      // 1. Пишемо в тимчасовий файл з flush: true (гарантує запис на диск)
      await tempFile.writeAsString(jsonData, flush: true);

      // 2. Якщо запис пройшов успішно, замінюємо старий файл новим
      // (На Windows rename іноді падає, якщо файл існує, тому краще видалити старий явно)
      if (await metaFile.exists()) {
        try {
          await metaFile.delete();
        } catch (e) {
          logger.w("Warning deleting old meta.json: $e");
        }
      }

      // Миттєва операція перейменування (атомарна на більшості ОС)
      await tempFile.rename(metaFilePath);

      // ▲▲▲ КІНЕЦЬ ВИПРАВЛЕННЯ ▲▲▲
    } catch (e) {
      logger.e('Error saving board: $e');
      rethrow;
    }
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
      // Використовуємо getBoardDir, щоб знайти правильну папку за ID
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
}
