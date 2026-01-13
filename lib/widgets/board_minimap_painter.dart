import 'package:flutter/material.dart';
import 'package:boardly/models/board_items.dart';
import 'dart:math';

class BoardMiniMapPainter extends CustomPainter {
  final List<BoardItem> items;
  final Color themeColor;

  BoardMiniMapPainter({
    required this.items,
    // Використовуємо яскравий бірюзовий для світіння
    this.themeColor = const Color(0xFF00E5FF),
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;

    // 1. Знаходимо межі (Bounding Box)
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (var item in items) {
      if (item.position.dx < minX) minX = item.position.dx;
      if (item.position.dx > maxX) maxX = item.position.dx;
      if (item.position.dy < minY) minY = item.position.dy;
      if (item.position.dy > maxY) maxY = item.position.dy;
    }

    maxX += 100; // Враховуємо приблизний розмір файлу
    maxY += 100;

    // 2. Додаємо значні відступи, щоб точки не липли до країв карти
    const double contentPadding = 400.0;
    minX -= contentPadding;
    minY -= contentPadding;
    maxX += contentPadding;
    maxY += contentPadding;

    final double contentWidth = maxX - minX;
    final double contentHeight = maxY - minY;

    if (contentWidth <= 0 || contentHeight <= 0) return;

    // 3. Обчислюємо масштаб
    final double scaleX = size.width / contentWidth;
    final double scaleY = size.height / contentHeight;
    final double scale = min(scaleX, scaleY);

    // Центрування
    final double offsetX = (size.width - contentWidth * scale) / 2;
    final double offsetY = (size.height - contentHeight * scale) / 2;

    canvas.save();
    canvas.translate(offsetX, offsetY);
    canvas.scale(scale);
    canvas.translate(-minX, -minY);

    // === НАЛАШТУВАННЯ СВІТІННЯ ===

    // Розміри в логічних пікселях екрану, які ми хочемо отримати
    const double desiredGlowRadiusOnScreen = 8.0;
    const double desiredCoreRadiusOnScreen = 3.0;

    // Оскільки canvas зараз зменшений (scale), нам треба збільшити радіус малювання,
    // щоб після зменшення він виглядав так, як ми хочемо.
    // Ділимо бажаний розмір на поточний масштаб.
    final double glowRadius = desiredGlowRadiusOnScreen / scale;
    final double coreRadius = desiredCoreRadiusOnScreen / scale;

    // Фарба для світіння (розмита, кольорова)
    final Paint glowPaint =
        Paint()
          ..color = themeColor.withOpacity(0.5)
          // MaskFilter.blur створює ефект розмиття тіні
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    // Фарба для ядра (яскрава точка в центрі, майже біла)
    final Paint corePaint =
        Paint()
          ..color = Colors.white.withOpacity(0.9)
          ..style = PaintingStyle.fill;

    for (var item in items) {
      // Центр файлу
      final center = item.position + const Offset(50, 50);

      // Малюємо спочатку світіння (воно буде позаду)
      canvas.drawCircle(center, glowRadius, glowPaint);

      // Малюємо яскраве ядро зверху
      canvas.drawCircle(center, coreRadius, corePaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BoardMiniMapPainter oldDelegate) {
    return oldDelegate.items != items;
  }
}
