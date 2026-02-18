import 'dart:async';
import 'dart:io';

import 'package:boardly/data/board_storage.dart';
import 'package:boardly/models/board_items.dart';
import 'package:boardly/models/connection_model.dart';
import 'package:boardly/screens/board.dart';
import 'package:boardly/logger.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:boardly/web_rtc/rtc.dart';
import 'package:collection/collection.dart';

mixin FileLogicMixin on State<CanvasBoard> {
  List<BoardItem> get items;
  set items(List<BoardItem> value);

  WebRTCManager? get webRTCManager;

  Future<void> saveBoard();

  void safeSetState(VoidCallback fn);
  void updateItemPath(BoardItem item, String newPath);
  Future<void> streamFileToPeers(BoardItem item, String path);
  void broadcastItemAdd({required BoardItem item});

  Set<String> get locallyProcessingFiles;
  bool get isNestedFolder;

  Timer? _saveDebounceTimer;

  void triggerSaveBoard() {
    if (_saveDebounceTimer?.isActive ?? false) {
      _saveDebounceTimer!.cancel();
    }

    _saveDebounceTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (!mounted) return;
      try {
        await saveBoard();
        logger.i("💾 Auto-saved board after file operations (Debounced)");
      } catch (e) {
        logger.e("❌ Error during debounced save: $e");
      }
    });
  }

  void handleExternalFileAdded(String path) async {
    if (!mounted) return;

    final fileName = p.basename(path);

    if (fileName == 'meta.json' ||
        fileName.endsWith('.tmp') ||
        fileName.endsWith('.part') ||
        fileName.startsWith('.')) {
      return;
    }

    if (locallyProcessingFiles.contains(fileName.toLowerCase())) return;

    final existing = items.firstWhereOrNull(
      (i) => i.originalPath == path || i.fileName == fileName,
    );
    if (existing != null) return;

    logger.i("🔎 Analyzing path for: $path");

    String? targetConnectionId;

    try {
      final boardId = widget.board!.id!;
      final rootFilesDir = await BoardStorage.getBoardFilesDirAuto(boardId);

      final normalizedRoot = p.canonicalize(rootFilesDir);
      final normalizedPath = p.canonicalize(path);

      final relativePath = p.relative(normalizedPath, from: normalizedRoot);
      final pathParts = p.split(relativePath);

      if (pathParts.length > 1 && pathParts[0] != '..') {
        final parentFolderName = pathParts[0];

        var connection = widget.board?.connections?.firstWhereOrNull(
          (c) => c.name.toLowerCase() == parentFolderName.toLowerCase(),
        );

        if (connection != null) {
          targetConnectionId = connection.id;
          logger.i("📂 Found child connection: ${connection.name}");
        } else {
          if (widget.board?.isConnectionBoard == true) {
            targetConnectionId = widget.board?.id;
            logger.i(
              "📂 File is inside current nested folder (Self). Assigned to current board.",
            );
          } else {
            logger.w(
              "⚠️ Creating NEW connection for folder: $parentFolderName",
            );
            connection = _createConnectionSync(parentFolderName);
            targetConnectionId = connection.id;
          }
        }
      } else {
        if (widget.board?.isConnectionBoard == true) {
          targetConnectionId = widget.board?.connectionId ?? widget.board?.id;
        } else {
          targetConnectionId = null;
        }
      }
    } catch (e) {
      logger.e("❌ Error calculating path context: $e");
    }

    logger.i(
      "✅ Adding file: $fileName -> Connection: ${targetConnectionId ?? 'ROOT'}",
    );

    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();

    Offset position = const Offset(100, 100);

    if (targetConnectionId != null && widget.board?.connections != null) {
      final conn = widget.board!.connections!.firstWhereOrNull(
        (c) => c.id == targetConnectionId,
      );
      if (conn != null && conn.collapsedPosition != null) {
        position = conn.collapsedPosition! + const Offset(50, 50);
      } else if (widget.board?.isConnectionBoard == true &&
          widget.board?.id == targetConnectionId) {
        if (items.isNotEmpty) {
          position = items.last.position + const Offset(20, 20);
        }
      }
    } else if (items.isNotEmpty) {
      final lastItem = items.last;
      position = lastItem.position + const Offset(20, 20);
    }

    final newItem = BoardItem(
      id: UniqueKey().toString(),
      path: path,
      shortcutPath: path,
      originalPath: path,
      position: position,
      type: ext.isEmpty ? 'file' : ext,
      fileName: fileName,
      connectionId: targetConnectionId,
    );

    safeSetState(() {
      items.add(newItem);

      if (targetConnectionId != null && widget.board?.connections != null) {
        final conn = widget.board!.connections!.firstWhereOrNull(
          (c) => c.id == targetConnectionId,
        );
        if (conn != null && !conn.itemIds.contains(newItem.id)) {
          conn.itemIds.add(newItem.id);
        }
      }
    });

    triggerSaveBoard();
    broadcastItemAdd(item: newItem);

    if (newItem.type != 'folder') {
      streamFileToPeers(newItem, path);
    }
  }

  Connection _createConnectionSync(String folderName) {
    Offset position = const Offset(200, 200);
    if ((widget.board?.connections?.isNotEmpty ?? false)) {
      final lastPos = widget.board!.connections!.last.collapsedPosition;
      if (lastPos != null) position = lastPos + const Offset(20, 20);
    }

    final newFolder = Connection(
      id: UniqueKey().toString(),
      name: folderName,
      itemIds: [],
      boardId: widget.board!.id,
      isCollapsed: true,
      collapsedPosition: position,
      colorValue: Colors.blue.value,
    );

    safeSetState(() {
      widget.board?.connections ??= [];
      widget.board!.connections!.add(newFolder);
    });

    return newFolder;
  }

  void handleExternalFileDeleted(String path) async {
    if (!mounted) return;

    final potentialFolderName = p.basename(path);
    final isKnownFolder =
        widget.board?.connections?.any(
          (c) => c.name.toLowerCase() == potentialFolderName.toLowerCase(),
        ) ??
        false;

    if (isKnownFolder) {
      handleExternalFolderDeleted(path);
      return;
    }

    bool exists = await File(path).exists();
    if (exists) return;

    if (await Directory(path).exists()) return;

    safeSetState(() {
      items.removeWhere((item) {
        final itemPath = p.canonicalize(item.originalPath);
        final deletedPath = p.canonicalize(path);
        final isNameMatch =
            p.basename(item.originalPath).toLowerCase() ==
            p.basename(path).toLowerCase();

        return itemPath == deletedPath ||
            (isNameMatch &&
                item.originalPath.toLowerCase().contains(path.toLowerCase()));
      });
    });

    triggerSaveBoard();
  }

  void handleExternalFolderAdded(String path) async {
    if (!mounted) return;
    if (widget.board?.isConnectionBoard == true) return;

    final folderName = p.basename(path);
    if (folderName == 'files' || folderName.startsWith('.')) return;

    final exists =
        widget.board?.connections?.any(
          (c) => c.name.toLowerCase() == folderName.toLowerCase(),
        ) ??
        false;

    if (exists) return;

    logger.i("📂 External Folder Detected: $folderName");
    _createConnectionSync(folderName);

    triggerSaveBoard();

    if (widget.webRTCManager != null) {
      final conn = widget.board!.connections!.last;
      widget.webRTCManager!.broadcastFolderCreate(conn);
      widget.webRTCManager!.broadcastConnectionUpdate(
        widget.board!.connections!,
      );
    }
  }

  void handleExternalFolderRenamed(String oldPath, String newPath) {
    if (!mounted) return;
    final oldName = p.basename(oldPath);
    final newName = p.basename(newPath);

    final conn = widget.board?.connections?.firstWhereOrNull(
      (c) => c.name.toLowerCase() == oldName.toLowerCase(),
    );

    if (conn != null) {
      safeSetState(() {
        conn.name = newName;
      });
      triggerSaveBoard();

      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastConnectionUpdate(
          widget.board!.connections!,
        );
        widget.webRTCManager!.broadcastFolderRename(conn.id, oldName, newName);
      }
    }
  }

  void handleExternalFolderDeleted(String path) {
    if (!mounted) return;
    final folderName = p.basename(path);

    final conn = widget.board?.connections?.firstWhereOrNull(
      (c) => c.name.toLowerCase() == folderName.toLowerCase(),
    );

    if (conn != null) {
      final connId = conn.id;
      safeSetState(() {
        widget.board!.connections!.remove(conn);
        items.removeWhere((item) => item.connectionId == connId);
      });
      triggerSaveBoard();

      if (widget.webRTCManager != null) {
        widget.webRTCManager!.broadcastFolderDelete(connId, folderName);
        widget.webRTCManager!.broadcastConnectionUpdate(
          widget.board!.connections!,
        );
      }
    }
  }

  Future<void> syncOrphanFiles() async {
    if (widget.board?.id == null) return;
    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;

    try {
      final String filesDir = await BoardStorage.getBoardFilesDirAuto(
        widget.board!.id!,
      );
      final dir = Directory(filesDir);
      if (!await dir.exists()) return;

      final bool isNested = widget.board?.isConnectionBoard == true;
      final recursive = !isNested;

      final List<FileSystemEntity> entities =
          await dir.list(recursive: recursive).toList();

      if (!isNested) {
        for (var entity in entities) {
          if (entity is Directory) {
            final folderName = p.basename(entity.path);
            if (folderName == 'files' || folderName.startsWith('.')) continue;

            final exists =
                widget.board?.connections?.any(
                  (c) => c.name.toLowerCase() == folderName.toLowerCase(),
                ) ??
                false;

            if (!exists) {
              _createConnectionSync(folderName);
            }
          }
        }
      }

      List<BoardItem> restoredItems = [];

      for (var entity in entities) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          if (fileName.startsWith('.') ||
              fileName == 'meta.json' ||
              fileName.endsWith('.part'))
            continue;

          final exists = items.any(
            (i) =>
                i.fileName.toLowerCase() == fileName.toLowerCase() ||
                p.basename(i.originalPath).toLowerCase() ==
                    fileName.toLowerCase(),
          );

          if (!exists) {
            if (isNested) {
              final fileDir = p.dirname(entity.path);
              if (p.canonicalize(fileDir) != p.canonicalize(filesDir)) continue;
            }

            final ext = p.extension(fileName).replaceAll('.', '').toLowerCase();
            String? connectionId;

            if (isNested) {
              connectionId = widget.board?.id;
            } else {
              final parentDirName = p.basename(p.dirname(entity.path));
              final rootName = p.basename(filesDir);

              if (parentDirName != rootName &&
                  parentDirName != widget.board!.id) {
                final conn = widget.board?.connections?.firstWhereOrNull(
                  (c) => c.name.toLowerCase() == parentDirName.toLowerCase(),
                );
                connectionId = conn?.id;
              }
            }

            restoredItems.add(
              BoardItem(
                id: UniqueKey().toString(),
                path: entity.path,
                shortcutPath: entity.path,
                originalPath: entity.path,
                position: Offset(
                  150.0 + (restoredItems.length * 30),
                  150.0 + (restoredItems.length * 30),
                ),
                type: ext.isEmpty ? 'file' : ext,
                fileName: fileName,
                connectionId: connectionId,
              ),
            );
          }
        }
      }

      if (restoredItems.isNotEmpty) {
        safeSetState(() {
          items.addAll(restoredItems);
        });
        triggerSaveBoard();
      }
    } catch (e) {
      logger.e("Error syncing orphan files: $e");
    }
  }

  Future<File?> findLocalFileForItem(BoardItem item) async {
    File candidate = File(item.originalPath);
    if (await candidate.exists()) return candidate;

    if (widget.board?.id == null) return null;

    try {
      final dirName = widget.board!.id!;
      final String boardFilesDir = await BoardStorage.getBoardFilesDirAuto(
        dirName,
      );

      final candidates = [
        p.join(boardFilesDir, item.fileName),
        p.join(boardFilesDir, item.id),
      ];

      if (item.connectionId != null && widget.board?.connections != null) {
        final conn = widget.board!.connections!.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        if (conn != null) {
          candidates.insert(0, p.join(boardFilesDir, conn.name, item.fileName));
        }
      }

      for (final path in candidates) {
        candidate = File(path);
        if (await candidate.exists()) {
          if (item.originalPath != path) {
            updateItemPath(item, path);
          }
          return candidate;
        }
      }
    } catch (e) {
      logger.w("Error searching for local file: $e");
    }
    return null;
  }
}
