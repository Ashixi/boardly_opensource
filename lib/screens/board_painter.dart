// lib/screens/board_painter.dart
import 'dart:math'; 
import 'dart:ui' as ui; 

import 'package:boardly/models/board_items.dart';
import 'package:boardly/models/connection_model.dart';
import 'package:flutter/material.dart';

class BoardPainter extends CustomPainter {
  final List<BoardItem> items;
  final Offset offset;
  final double scale;
  final BoardItem? selectedItem;

 
  final List<BoardItem>? linkItems;
  final List<BoardLink>? links;

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

    _drawGrid(canvas, size);

    _drawVisualLinks(canvas);
    _drawTempLinks(canvas);
    _drawDragArrow(canvas);

    const iconSize = 100.0;

    for (final item in items) {
      if (_isItemInCollapsedFolder(item)) continue;

      final position = item.position;
      final rect = Rect.fromLTWH(position.dx, position.dy, iconSize, iconSize);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

      if (isFPressed && item.connectionId != null && connections != null) {
        final conn = connections!.firstWhereOrNull(
          (c) => c.id == item.connectionId,
        );
        if (conn != null) {
          final color = Color(conn.colorValue);

          canvas.drawRRect(
            rrect,
            Paint()
              ..color = color.withOpacity(0.3)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
          );

          canvas.drawRRect(
            rrect,
            Paint()
              ..color = color.withOpacity(0.5)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
          );

        }
      }


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

      ui.Image? imageToDraw;
      if (fileIcons != null) {
        String typeKey = item.type.toLowerCase();

        if (typeKey == 'doc') typeKey = 'docx';

        imageToDraw = fileIcons![typeKey];
        imageToDraw ??= fileIcons!['default'];
      }

      if (imageToDraw != null) {
        paintImage(
          canvas: canvas,
          rect: rect,
          image: imageToDraw,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      } else {
        final bgPaint = Paint()..color = Colors.blueAccent.withAlpha(180);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(12)),
          bgPaint,
        );

        const icon = TextSpan(text: '📄', style: TextStyle(fontSize: 40));
        final iconPainter = TextPainter(
          text: icon,
          textDirection: TextDirection.ltr,
        );
        iconPainter.layout();
        iconPainter.paint(canvas, rect.topLeft + const Offset(30, 10));
      }

      final int maxChars = 30;
      final displayName =
          item.fileName.length > maxChars
              ? '${item.fileName.substring(0, maxChars - 3)}...'
              : item.fileName;

      final textPainter = TextPainter(
        text: TextSpan(
          text: displayName,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 18,  
            fontWeight: FontWeight.bold,
            backgroundColor:
                Colors.white70, 
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );

      textPainter.layout(maxWidth: iconSize + 60);

      textPainter.paint(
        canvas,
        rect.bottomLeft + Offset((iconSize - textPainter.width) / 2, 10),
      );
    }

    _drawCollapsedFolders(canvas);
    canvas.restore();
  }

  bool _isItemInCollapsedFolder(BoardItem item) {
    if (item.connectionId == null || connections == null) return false;
    final conn = connections!.firstWhereOrNull(
      (c) => c.id == item.connectionId,
    );
    return conn != null && conn.isCollapsed;
  }

  void _drawVisualLinks(Canvas canvas) {
    if (links == null) return;

    for (final link in links!) {
      final fromItem = items.firstWhereOrNull((i) => i.id == link.fromItemId);
      final toItem = items.firstWhereOrNull((i) => i.id == link.toItemId);

      if (fromItem == null || toItem == null) continue;
      if (_isItemInCollapsedFolder(fromItem) ||
          _isItemInCollapsedFolder(toItem))
        continue;

      final center1 = fromItem.position + const Offset(50, 50);
      final center2 = toItem.position + const Offset(50, 50);

      final start = _getRectIntersection(center1, center2, 50.0);
      final end = _getRectIntersection(center2, center1, 50.0);

      final paint =
          Paint()
            ..color = Color(link.colorValue)
            ..strokeWidth = link.strokeWidth
            ..style = PaintingStyle.stroke;

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

  void _drawCollapsedFolders(Canvas canvas) {
    if (connections == null) return;
    for (final connection in connections!) {
      if (connection.isCollapsed && connection.collapsedPosition != null) {
        final position = connection.collapsedPosition!;
        final rect = Rect.fromLTWH(position.dx, position.dy, 100.0, 100.0);
        ui.Image? folderIcon = fileIcons?['folder'];

        if (folderIcon != null) {
          paintImage(
            canvas: canvas,
            rect: rect,
            image: folderIcon,
            fit: BoxFit.contain,
          );
        } else {
          final rrect = RRect.fromRectAndRadius(
            rect,
            const Radius.circular(12),
          );
          final bgPaint =
              Paint()
                ..color = Color(connection.colorValue)
                ..style = PaintingStyle.fill;
          canvas.drawRRect(rrect, bgPaint);
          const icon = TextSpan(text: '📁', style: TextStyle(fontSize: 40));
          final iconPainter = TextPainter(
            text: icon,
            textDirection: TextDirection.ltr,
          );
          iconPainter.layout();
          iconPainter.paint(canvas, rect.topLeft + const Offset(30, 10));
        }

        final int maxFolderChars = 30;
        final displayName =
            connection.name.length > maxFolderChars
                ? '${connection.name.substring(0, maxFolderChars - 3)}...'
                : connection.name;

        final textPainter = TextPainter(
          text: TextSpan(
            text: displayName,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 18, 
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.white70,
            ),
          ),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        );

        textPainter.layout(maxWidth: 160); 
        textPainter.paint(
          canvas,
          rect.bottomLeft + Offset((100 - textPainter.width) / 2, 10),
        );
      }
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint =
        Paint()
          ..color = Colors.grey.withOpacity(0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5;
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
