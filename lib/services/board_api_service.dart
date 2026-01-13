import 'dart:convert';
import 'package:boardly/screens/start_screen.dart';
import 'package:http/http.dart' as http;
import 'package:boardly/logger.dart';

class BoardLimitException implements Exception {
  final String message;
  BoardLimitException(this.message);
}

class BoardApiService {
  final AuthHttpClient _client = AuthHttpClient();
  final String _baseUrl =
      "https://boardly.studio/api";

  Future<Map<String, dynamic>> createBoard(String name) async {
    try {
      final response = await _client.request(
        Uri.parse('$_baseUrl/boards/'),
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
      _client.close();
    }
  }
}
