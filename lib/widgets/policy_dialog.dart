import 'package:boardly/services/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PolicyService {
  static const String _policyKey = 'policy_accepted';

  /// Перевіряє, чи користувач уже приймав умови
  static Future<void> checkPolicy(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final bool? accepted = prefs.getBool(_policyKey);

    if (accepted == null || !accepted) {
      // Якщо не прийнято, показуємо вікно примусово
      // ignore: use_build_context_synchronously
      showPolicy(context, canDecline: true);
    }
  }

  /// Відображає текст політики
  static Future<void> showPolicy(
    BuildContext context, {
    bool canDecline = false,
  }) async {
    // Завантажуємо текст із вашого файлу
    String policyText = "Завантаження...";
    try {
      policyText = await rootBundle.loadString(
        'assets/policy/privacy_policy.txt',
      );
    } catch (e) {
      print(
        "Деталі помилки ассетів: $e",
      ); // Це покаже в консолі, що саме не так
      policyText =
          "Помилка завантаження тексту політики. Зверніться в підтримку.";
    }

    showDialog(
      context: context,
      barrierDismissible:
          !canDecline, // Не можна закрити просто натиснувши поруч, якщо треба прийняти
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(Icons.gavel_rounded, color: Color(0xFF009688)),
              SizedBox(width: 10),
              Text(S.t('terms_and_policy')),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Text(policyText, style: const TextStyle(fontSize: 14)),
            ),
          ),
          actions: [
            if (canDecline)
              TextButton(
                onPressed:
                    () =>
                        SystemNavigator.pop(), // Закриває додаток, якщо не згодні
                child: Text(
                  S.t('decline'),
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF009688),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_policyKey, true);
                // ignore: use_build_context_synchronously
                Navigator.of(context).pop();
              },
              child: Text(S.t('agree'), style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }
}
