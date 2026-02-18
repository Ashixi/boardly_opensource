import 'package:boardly/logger.dart'; // Додано для логування помилок
import 'board_items.dart';
import 'connection_model.dart';

class BoardModel {
  String? id;
  String? title;
  String? ownerId;

  List<BoardItem> items;
  List<Connection>? connections;
  List<BoardLink>? links;
  List<ConnectionBoard>? connectionBoards;

  bool isConnectionBoard;
  String? connectionId;
  String? description;
  bool isJoined;

  List<String> blockedPublicIds;

  BoardModel({
    this.id,
    this.title,
    this.ownerId,
    List<BoardItem>? items,
    this.connections,
    this.links,
    this.connectionBoards,
    this.isConnectionBoard = false,
    this.connectionId,
    this.description,
    this.isJoined = false,
    List<String>? blockedPublicIds,
  }) : items = items ?? [],
       blockedPublicIds = blockedPublicIds ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'ownerId': ownerId,
    'items': items.map((e) => e.toJson()).toList(),
    'connections': connections?.map((c) => c.toJson()).toList(),
    'links': links?.map((l) => l.toJson()).toList(),
    'connectionBoards': connectionBoards?.map((cb) => cb.toJson()).toList(),
    'isConnectionBoard': isConnectionBoard,
    'connectionId': connectionId,
    'description': description,
    'isJoined': isJoined,
    'blockedPublicIds': blockedPublicIds,
  };

  factory BoardModel.fromJson(Map<String, dynamic> json) {
    return BoardModel(
      id: json['id']?.toString(),
      title: json['title']?.toString(),
      ownerId: json['ownerId']?.toString(),
      // ЗАХИЩЕНЕ ЗАВАНТАЖЕННЯ ЕЛЕМЕНТІВ
      items:
          (json['items'] as List?)
              ?.map((e) {
                try {
                  return BoardItem.fromJson(e);
                } catch (err, stack) {
                  // Якщо елемент битий, ми його пропускаємо, але не крашимо всю дошку
                  logger.e(
                    '⚠️ Skipping corrupted item in board ${json['id']}: $err',
                    error: err,
                    stackTrace: stack,
                  );
                  return null;
                }
              })
              .where(
                (element) => element != null,
              ) // Відкидаємо null (биті елементи)
              .cast<BoardItem>() // Приводимо до правильного типу
              .toList() ??
          [],
      connections:
          (json['connections'] as List?)
              ?.map((e) => Connection.fromJson(e))
              .toList(),
      links:
          (json['links'] as List?)?.map((e) => BoardLink.fromJson(e)).toList(),
      connectionBoards:
          (json['connectionBoards'] as List?)
              ?.map((e) => ConnectionBoard.fromJson(e))
              .toList(),
      isConnectionBoard: json['isConnectionBoard'] ?? false,
      connectionId: json['connectionId']?.toString(),
      description: json['description']?.toString(),
      isJoined: json['isJoined'] ?? false,
      blockedPublicIds:
          (json['blockedPublicIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}
