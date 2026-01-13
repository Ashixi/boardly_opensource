import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../logger.dart';

class LogViewerScreen extends StatelessWidget {
  const LogViewerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "System Logs",
          style: TextStyle(color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: "Copy All",
            onPressed: () {
              final text = LogHistory.logsNotifier.value.join(
                '\n\n----------------\n\n',
              );
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('All logs copied!')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: "Clear",
            onPressed: () => LogHistory.clear(),
          ),
        ],
      ),
      backgroundColor: Colors.white,
      body: ValueListenableBuilder<List<String>>(
        valueListenable: LogHistory.logsNotifier,
        builder: (context, logs, child) {
          if (logs.isEmpty) {
            return const Center(
              child: Text(
                "No logs yet...",
                style: TextStyle(color: Colors.grey),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: logs.length,
            separatorBuilder:
                (_, __) => Divider(color: Colors.grey.shade200, height: 24),
            itemBuilder: (context, index) {
              return SelectableText(
                logs[index],
                style: const TextStyle(
                  color: Colors.black87, 
                  fontFamily:
                      'monospace', 
                  fontSize: 13,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
