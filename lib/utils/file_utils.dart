import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'; // для compute

Future<String> calculateMd5InIsolate(String filePath) async {
  final file = File(filePath);
  if (!file.existsSync()) return "";

  try {
    final stream = file.openRead();
    final digest = await md5.bind(stream).first;
    return digest.toString();
  } catch (e) {
    return "";
  }
}
