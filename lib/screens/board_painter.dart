// lib/screens/board_painter.dart
import 'dart:math';
import 'dart:ui' as ui;

import 'package:boardly/models/board_items.dart';
import 'package:boardly/models/connection_model.dart';
import 'package:flutter/material.dart';
// Для firstWhereOrNull

class BoardPainter extends CustomPainter {
  final List<BoardItem> items;
  final Offset offset;
  final double scale;
  final BoardItem? selectedItem;
  final BoardItem? linkTargetItem; // <--- ДОДАТИ ЦЕ
  final List<BoardItem>? linkItems;
  final List<BoardLink>? links;
  // Це список постійних стрілок

  // Для Папок (F)
  final List<BoardItem>? folderSelectionItems;
  final List<Connection>? connections;
  final bool isFPressed;

  final Offset? tempArrowStart;
  final Offset? tempArrowEnd;
  final Color tempArrowColor;
  final double tempArrowWidth;

  final Map<String, ui.Image>? fileIcons;

  BoardPainter({
    this.linkTargetItem, // <--- ДОДАТИ В КОНСТРУКТОР
    required this.items,
    required this.offset,
    required this.scale,
    this.selectedItem,
    this.linkItems,
    this.links,
    this.folderSelectionItems,
    this.connections,
    required Object highlightedConnections,
    this.tempArrowStart,
    this.tempArrowEnd,
    required this.isFPressed,
    this.tempArrowColor = Colors.black,
    this.tempArrowWidth = 2.0,
    this.fileIcons,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    // 1. Сітка
    _drawGrid(canvas, size);

    // 2. --- ДОДАНО --- Малюємо постійні стрілки (links)
    _drawLinks(canvas);

    if (linkTargetItem != null) {
      final position = linkTargetItem!.position;
      final rect = Rect.fromLTWH(position.dx, position.dy, 100.0, 100.0);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(20));

      final paint =
          Paint()
            ..color = Colors.greenAccent.withOpacity(0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.0
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

      canvas.drawRRect(rrect, paint);
    }

    // 3. Тимчасові стрілки (Drag & Drop створення)
    _drawTempLinks(canvas);
    _drawDragArrow(canvas);

    const iconSize = 100.0;

    // 4. Малюємо файли
    for (final item in items) {
      final position = item.position;
      final rect = Rect.fromLTWH(position.dx, position.dy, iconSize, iconSize);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

      // Ефекти виділення
      bool isSelected = false;
      Color glowColor = Colors.white;

      if (folderSelectionItems != null &&
          folderSelectionItems!.contains(item)) {
        isSelected = true;
        glowColor = Colors.blueAccent;
      } else if (linkItems != null && linkItems!.contains(item)) {
        isSelected = true;
        glowColor = Colors.orangeAccent;
      } else if (selectedItem == item) {
        isSelected = true;
        glowColor = Colors.blueAccent;
      }

      if (isSelected) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = glowColor.withOpacity(0.3)
            ..style = PaintingStyle.fill
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = glowColor.withOpacity(0.4)
            ..style = PaintingStyle.fill
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
        );
      }

      // Іконки
      ui.Image? imageToDraw;
      if (fileIcons != null) {
        String typeKey = item.type.toLowerCase();
        if (typeKey == 'doc') typeKey = 'docx';
        imageToDraw = fileIcons![typeKey];
        imageToDraw ??= fileIcons!['default'];
      }

      if (imageToDraw != null) {
        // ... код малювання картинки ...
        paintImage(
          canvas: canvas,
          rect: rect,
          image: imageToDraw,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      } else {
        // ... заглушка ...
        final bgPaint = Paint()..color = Colors.blueAccent.withAlpha(180);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(12)),
          bgPaint,
        );
      }

      // Текст
      const int maxChars = 30;
      final displayName =
          item.fileName.length > maxChars
              ? '${item.fileName.substring(0, maxChars - 3)}...'
              : item.fileName;

      final textPainter = TextPainter(
        text: TextSpan(
          text: displayName,
          style: TextStyle(
            color: Colors.black, // Чорний колір тексту
            fontSize: 23, // Збільшено з 14 до 20
            fontWeight: FontWeight.bold, // Робимо жирним
            shadows: [
              Shadow(
                offset: const Offset(1, 1),
                blurRadius: 2,
                color: Colors.white.withOpacity(
                  0.8,
                ), // Біла тінь для контрасту на фоні сітки
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );

      // Дозволяємо тексту бути трохи ширшим за іконку (iconSize + 60)
      textPainter.layout(maxWidth: iconSize + 60);

      textPainter.paint(
        canvas,
        Offset(
          position.dx + (iconSize - textPainter.width) / 2,
          position.dy + iconSize + 8, // Трохи збільшив відступ від іконки
        ),
      );
    }

    canvas.restore();
  }

  // --- НОВИЙ МЕТОД: Малює збережені стрілки ---
  void _drawLinks(Canvas canvas) {
    if (links == null || links!.isEmpty) return;

    for (final link in links!) {
      // Знаходимо об'єкти за ID
      final fromItem = items.firstWhereOrNull((i) => i.id == link.fromItemId);
      final toItem = items.firstWhereOrNull((i) => i.id == link.toItemId);

      // Якщо одного з файлів немає (наприклад, видалений) — не малюємо
      if (fromItem == null || toItem == null) continue;

      final paint =
          Paint()
            ..color = Color(link.colorValue) // Колір з моделі
            ..strokeWidth =
                link
                    .strokeWidth // Товщина з моделі
            ..style = PaintingStyle.stroke;

      // Центри іконок (іконка 100x100 -> центр +50)
      final startCenter = fromItem.position + const Offset(50, 50);
      final endCenter = toItem.position + const Offset(50, 50);

      // Рахуємо перетин з краями іконок, щоб стрілка не заходила всередину
      final start = _getRectIntersection(startCenter, endCenter, 50.0);
      final end = _getRectIntersection(endCenter, startCenter, 50.0);

      _drawArrow(canvas, start, end, paint);
    }
  }

  void _drawDragArrow(Canvas canvas) {
    if (tempArrowStart != null && tempArrowEnd != null) {
      final paint =
          Paint()
            ..color = tempArrowColor
            ..strokeWidth = tempArrowWidth
            ..style = PaintingStyle.stroke;

      // Рахуємо початок від краю іконки, з якої тягнемо
      final start = _getRectIntersection(tempArrowStart!, tempArrowEnd!, 50.0);

      _drawArrow(canvas, start, tempArrowEnd!, paint);
    }
  }

  Offset _getRectIntersection(Offset from, Offset to, double halfSize) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;

    if (dx == 0 && dy == 0) return from;

    double scaleX =
        (dx != 0) ? (dx > 0 ? halfSize : -halfSize) / dx : double.infinity;
    double scaleY =
        (dy != 0) ? (dy > 0 ? halfSize : -halfSize) / dy : double.infinity;

    double scale = (scaleX.abs() < scaleY.abs()) ? scaleX : scaleY;

    return from + Offset(dx * scale, dy * scale);
  }

  void _drawArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
    canvas.drawLine(start, end, paint);

    final double angle = atan2(end.dy - start.dy, end.dx - start.dx);
    final double arrowSize = 10.0 + paint.strokeWidth;

    final path = Path();
    path.moveTo(
      end.dx - arrowSize * cos(angle - pi / 6),
      end.dy - arrowSize * sin(angle - pi / 6),
    );
    path.lineTo(end.dx, end.dy);
    path.lineTo(
      end.dx - arrowSize * cos(angle + pi / 6),
      end.dy - arrowSize * sin(angle + pi / 6),
    );

    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    // Повертаємо стиль назад, бо drawPath може змінити його на fill за замовчуванням
    paint.style = PaintingStyle.stroke;
  }

  void _drawTempLinks(Canvas canvas) {
    if (linkItems == null || linkItems!.length < 2) return;
    final paint =
        Paint()
          ..color = Colors.grey
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

    for (int i = 0; i < linkItems!.length - 1; i++) {
      final start = linkItems![i].position + const Offset(50, 50);
      final end = linkItems![i + 1].position + const Offset(50, 50);
      canvas.drawLine(start, end, paint);
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint =
        Paint()
          ..color = Colors.grey.withOpacity(0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5;

    // Щоб сітка була "нескінченною" і рухалась, треба врахувати offset
    // Але твоя реалізація просто малює лінії по розміру екрану.
    // Це ок, якщо background статичний, але зазвичай сітка має рухатись разом з контентом.
    // Для простоти залишаємо як є, але краще робити infinite grid.

    for (double x = -size.width; x < size.width; x += 20) {
      canvas.drawLine(
        Offset(x, -size.height),
        Offset(x, size.height),
        gridPaint,
      );
    }
    for (double y = -size.height; y < size.height; y += 20) {
      canvas.drawLine(Offset(-size.width, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) => true;
}

extension on Object? {
  get id => null;
}

extension FirstWhereOrNullExtension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (E element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
