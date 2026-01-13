import 'dart:io';
import 'package:flutter/material.dart';
import 'package:boardly/models/board_model.dart';
import 'package:boardly/data/board_storage.dart';
import 'package:boardly/widgets/board_minimap_painter.dart';
import 'package:boardly/services/localization.dart';

class BoardCard extends StatelessWidget {
  final BoardModel board;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool isHostScreen;
  final bool isJoinScreen;

  const BoardCard({
    super.key,
    required this.board,
    required this.onTap,
    required this.onDelete,
    this.isHostScreen = false,
    this.isJoinScreen = false,
  });

  Future<String> _calculateSize() async {
    try {
      if (board.id == null) return "";
      final path = await BoardStorage.getBoardFilesDirAuto(board.id!);
      final dir = Directory(path);
      if (!await dir.exists()) return "";

      int totalSize = 0;
      await for (var file in dir.list(recursive: true, followLinks: false)) {
        if (file is File) {
          totalSize += await file.length();
        }
      }

      if (totalSize < 1024) return "$totalSize B";
      if (totalSize < 1024 * 1024)
        return "${(totalSize / 1024).toStringAsFixed(1)} KB";
      return "${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB";
    } catch (e) {
      return "";
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Card(
      elevation:
          0, // Прибираємо тінь, оскільки у нас тепер є чітка обводка (flat style)
      color: Colors.white,
      surfaceTintColor: Colors.white,
      // 🔥 ДОДАНО: Обводка (border)
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Colors.grey.shade300, // Колір обводки
          width: 1.5, // Товщина лінії
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // === МІНІ-КАРТА ===
            Expanded(
              child: Container(
                // Трохи змінюємо фон всередині, щоб він не зливався з білим низом
                color: const Color(0xFFF7F9FA),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: CustomPaint(
                          painter: BoardMiniMapPainter(
                            items: board.items,
                            themeColor: primaryColor,
                          ),
                        ),
                      ),
                    ),
                    // Кнопка видалення
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: onDelete,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color:
                                  Colors
                                      .white, // Білий фон для контрасту на карті
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.grey.shade200,
                              ), // Тонка рамка навколо хрестика
                            ),
                            child: Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // === ІНФО (Збільшений текст) ===
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 10.0,
              ),
              // Верхня лінія вже не обов'язкова, бо є загальна рамка,
              // але можна залишити для розділення карти і тексту
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Назва
                  Text(
                    board.title ?? "Без назви",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700, // Жирніший шрифт
                      color: Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),

                  // Статистика
                  Row(
                    children: [
                      Icon(
                        Icons.insert_drive_file_outlined,
                        size: 14,
                        color: primaryColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "${board.items.length} ${S.t('files')}",
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[700],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      FutureBuilder<String>(
                        future: _calculateSize(),
                        builder: (context, snapshot) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              snapshot.data ?? "...",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
