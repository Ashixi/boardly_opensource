// lib/models/board_model.dart
import 'board_items.dart';
import 'connection_model.dart';

class BoardModel {
  final String? id;
  String? title;
  final String? ownerId;

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
      items:
          (json['items'] as List?)
              ?.map((e) => BoardItem.fromJson(e))
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
