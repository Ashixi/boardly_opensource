import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:boardly/services/localization.dart';

Future<void> showDeleteAccountDialog(BuildContext context, bool isPro) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: Text(
            S.t('delete_account_title'),
            style: const TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isPro) ...[
                  Text(
                    S.t('delete_warning_pro'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(S.t('delete_desc_pro')),
                ] else ...[
                  Text(S.t('delete_account_confirm')),
                  const SizedBox(height: 10),
                  Text(S.t('delete_desc_free')),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                S.t('cancel'),
                style: const TextStyle(color: Colors.black54),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(S.t('delete_btn_confirm')),
            ),
          ],
        ),
  );

  if (confirmed == true && context.mounted) {
    await _deleteAccountAction(context);
  }
}

Future<void> _deleteAccountAction(BuildContext context) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder:
        (ctx) => const Center(
          child: CircularProgressIndicator(color: Colors.redAccent),
        ),
  );

  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');

    if (token != null) {
      final url = Uri.parse('https://boardly.studio/api/user/delete');
      print('--- SENDING DELETE REQUEST TO: $url ---');

      final response = await http.delete(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      print('--- RESPONSE STATUS: ${response.statusCode} ---');
      print('--- RESPONSE BODY: ${response.body} ---');

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to delete account on server: ${response.statusCode}',
        );
      }

      await prefs.remove('auth_token');
      await prefs.remove('user_data');
      await prefs.remove('refresh_token');
      await prefs.remove('device_id');

      if (context.mounted) {
        Navigator.of(context).pop();

        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.t('account_deleted_success')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      throw Exception('No auth token found');
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${S.t('error_prefix')} $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
