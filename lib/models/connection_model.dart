import 'dart:ui';

class Connection {
  final String id;
  String name;
  List<String> itemIds;
  final String? boardId;
  int colorValue;

  bool isCollapsed;
  Offset? collapsedPosition;

  List<BoardLink>? links;

  Connection({
    required this.id,
    required this.name,
    required this.itemIds,
    required this.boardId,
    this.isCollapsed = false,
    this.collapsedPosition,
    this.colorValue = 0xFF2196F3,
    this.links,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'itemIds': itemIds,
    'boardId': boardId,
    'isCollapsed': isCollapsed,
    'collapsedPosition':
        collapsedPosition != null
            ? {'dx': collapsedPosition!.dx, 'dy': collapsedPosition!.dy}
            : null,
    'colorValue': colorValue,
    'links': links?.map((l) => l.toJson()).toList(),
  };

  factory Connection.fromJson(Map<String, dynamic> json) {
    return Connection(
      id: json['id'] as String,
      name: json['name'] as String,
      itemIds:
          (json['itemIds'] as List<dynamic>).map((e) => e.toString()).toList(),
      boardId: json['boardId'] as String,
      isCollapsed: json['isCollapsed'] as bool? ?? false,
      collapsedPosition:
          json['collapsedPosition'] != null
              ? Offset(
                (json['collapsedPosition']['dx'] as num).toDouble(),
                (json['collapsedPosition']['dy'] as num).toDouble(),
              )
              : null,
      colorValue: json['colorValue'] ?? 0xFF2196F3,

      links:
          (json['links'] as List?)?.map((e) => BoardLink.fromJson(e)).toList(),
    );
  }
}

class BoardLink {
  final String id;
  final String fromItemId;
  final String toItemId;
  final int colorValue;
  final double strokeWidth;

  BoardLink({
    required this.id,
    required this.fromItemId,
    required this.toItemId,
    this.colorValue = 0xFF000000,
    this.strokeWidth = 2.0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromItemId': fromItemId,
    'toItemId': toItemId,
    'colorValue': colorValue,
    'strokeWidth': strokeWidth,
  };

  factory BoardLink.fromJson(Map<String, dynamic> json) {
    return BoardLink(
      id: json['id'],
      fromItemId: json['fromItemId'],
      toItemId: json['toItemId'],
      colorValue: json['colorValue'] ?? 0xFF000000,
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.0,
    );
  }
}

class ConnectionBoard {
  final String id;
  final String connectionId;
  String description;
  final List<String> itemIds;

  ConnectionBoard({
    required this.id,
    required this.connectionId,
    this.description = "",
    required this.itemIds,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'connectionId': connectionId,
    'description': description,
    'itemIds': itemIds,
  };

  factory ConnectionBoard.fromJson(Map<String, dynamic> json) {
    return ConnectionBoard(
      id: json['id'] as String,
      connectionId: json['connectionId'] as String,
      description: json['description'] as String? ?? "",
      itemIds:
          (json['itemIds'] as List<dynamic>).map((e) => e.toString()).toList(),
    );
  }
}
