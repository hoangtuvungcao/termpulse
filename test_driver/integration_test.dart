import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data != null) {
      final outDir = Directory('build/qa_screenshots/mobile');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      for (final entry in data.entries) {
        if (entry.key.startsWith('shot:') && entry.value is String) {
          final name = entry.key.substring(5);
          File(
            '${outDir.path}/$name.png',
          ).writeAsBytesSync(base64Decode(entry.value as String));
        }
      }
    }
    await writeResponseData(data);
  },
);
