import 'dart:ui';
import 'package:path/path.dart' as p;

class BoardItem {
  final String id;
  String path; // <--- Прибрали final
  String? shortcutPath; // <--- Прибрали final
  String originalPath; // <--- Прибрали final
  Offset position;
  final String type;
  List<String>
  tags; // Можна також прибрати final, якщо плануєте змінювати список, хоча List сам по собі мутабельний
  String? notes;

  String? connectionId;

  final String fileName;

  BoardItem({
    required this.id,
    required this.path,
    required this.position,
    required this.type,
    List<String>? tags,
    this.notes,

    this.connectionId,

    String? fileName,
    this.shortcutPath,
    required this.originalPath,
  }) : tags = tags ?? [],
       fileName = fileName ?? p.basename(originalPath);

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'position': {'dx': position.dx, 'dy': position.dy},
    'type': type,
    'tags': tags,
    'notes': notes,

    'connectionId': connectionId,

    'fileName': fileName,
    'shortcutPath': shortcutPath,
    'originalPath': originalPath,
  };

  factory BoardItem.fromJson(Map<String, dynamic> json) {
    String? connId;
    if (json['connectionId'] != null) {
      connId = json['connectionId'] as String?;
    } else if (json['connectionIds'] != null &&
        (json['connectionIds'] as List<dynamic>).isNotEmpty) {
      connId = (json['connectionIds'] as List<dynamic>).first.toString();
    }

    return BoardItem(
      id: json['id'] as String,
      path: json['path'] as String,
      position: Offset(
        (json['position']['dx'] as num).toDouble(),
        (json['position']['dy'] as num).toDouble(),
      ),
      type: json['type'] as String,
      tags: (json['tags'] as List<dynamic>).map((e) => e.toString()).toList(),
      notes: json['notes'] as String?,

      connectionId: connId,

      fileName: json['fileName'] as String?,
      shortcutPath: json['shortcutPath'] as String?,
      originalPath: json['originalPath'] as String,
    );
  }

  BoardItem copyWith({
    String? id,
    String? path,
    Offset? position,
    String? type,
    List<String>? tags,
    String? notes,

    String? connectionId,

    String? fileName,
    String? shortcutPath,
    String? originalPath,
  }) {
    return BoardItem(
      id: id ?? this.id,
      path: path ?? this.path,
      position: position ?? this.position,
      type: type ?? this.type,
      tags: tags ?? this.tags,
      notes: notes ?? this.notes,

      connectionId: connectionId ?? this.connectionId,

      fileName: fileName ?? this.fileName,
      shortcutPath: shortcutPath ?? this.shortcutPath,
      originalPath: originalPath ?? this.originalPath,
    );
  }
}
