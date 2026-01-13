import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class LogHistory {
  static final ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);
  static const int maxLogs = 500; // Тримаємо останні 500 логів

  static void addLog(List<String> lines) {
    final textBlock = lines.join('\n');

    final currentLogs = List<String>.from(logsNotifier.value);
    currentLogs.insert(0, textBlock);

    if (currentLogs.length > maxLogs) {
      currentLogs.removeRange(maxLogs, currentLogs.length);
    }

    logsNotifier.value = currentLogs;
  }

  static void clear() {
    logsNotifier.value = [];
  }
}

class MemoryOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    LogHistory.addLog(event.lines);
  }
}

final logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 80,
    colors: false,
    printEmojis: true,
    printTime: true,
  ),
  output: MultiOutput([ConsoleOutput(), MemoryOutput()]),
);
