import 'dart:convert';

class JoinedBoardInfo {
  final String id;
  final String title;
  final String directory;

  JoinedBoardInfo({
    required this.id,
    required this.title,
    required this.directory,
  });

  Map<String, dynamic> toJson() {
    return {'id': id, 'title': title, 'directory': directory};
  }

  factory JoinedBoardInfo.fromJson(Map<String, dynamic> json) {
    return JoinedBoardInfo(
      id: json['id'],
      title: json['title'],
      directory: json['directory'],
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory JoinedBoardInfo.fromJsonString(String str) =>
      JoinedBoardInfo.fromJson(jsonDecode(str));
}
