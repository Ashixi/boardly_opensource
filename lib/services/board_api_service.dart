import 'dart:convert';
import 'package:boardly/screens/start_screen.dart';
import 'package:boardly/logger.dart';

class BoardLimitException implements Exception {
  final String message;
  BoardLimitException(this.message);
}

class BoardApiService {
  final AuthHttpClient client = AuthHttpClient();
  final String baseUrl = "https://boardly.studio/api";

  Future<Map<String, dynamic>> createBoard(String name) async {
    try {
      final response = await client.request(
        Uri.parse('$baseUrl/boards/'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return jsonDecode(response.body);
      } else if (response.statusCode == 403) {
        throw BoardLimitException("Limit reached");
      } else {
        throw Exception("Failed to create board: ${response.body}");
      }
    } catch (e) {
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> deleteBoard(String boardId) async {
    try {
      final response = await client.request(
        Uri.parse('$baseUrl/boards/$boardId'),
        method: 'DELETE',
      );

      if (response.statusCode != 200) {
        throw Exception("Failed to delete board on server: ${response.body}");
      }
    } catch (e) {
      logger.e("API Delete Error: $e");
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> joinBoard(String boardId) async {
    try {
      final response = await client.request(
        Uri.parse('$baseUrl/boards/join'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'board_id': boardId}),
      );

      if (response.statusCode == 200) {
        return;
      } else if (response.statusCode == 403) {
        throw BoardLimitException("Limit reached");
      } else if (response.statusCode == 404) {
        throw Exception("Board not found");
      } else {
        throw Exception("Failed to join: ${response.body}");
      }
    } catch (e) {
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> getJoinedBoards() async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('$baseUrl/boards/joined'),
        method: 'GET',
      );

      if (response.statusCode == 200) {
        logger.i("API Raw Response: ${response.body}");

        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        throw Exception(
          'Failed to load joined boards: ${response.statusCode} ${response.body}',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> leaveBoard(String boardId) async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://boardly.studio/api/boards/leave/$boardId'),
        method: 'DELETE',
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to leave board: ${response.body}');
      }
    } catch (e) {
      logger.e("API Leave Error: $e");
      rethrow;
    } finally {
      client.close();
    }
  }
}
