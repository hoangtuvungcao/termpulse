import 'dart:io';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/foreground_bridge.dart';

Future<String?> requestOutputPath(
  BuildContext context, {
  required String title,
  required String fileName,
}) async {
  final directory = await ForegroundBridge.getAppDataDir();
  if (!context.mounted) return null;
  final controller = TextEditingController(
    text:
        '$directory${Platform.pathSeparator}exports${Platform.pathSeparator}$fileName',
  );
  final route = DialogRoute<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final valid =
            controller.text.trim().isNotEmpty &&
            File(controller.text.trim()).isAbsolute;
        return AlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(
            width: 580,
            child: TextField(
              key: const Key('outputFilePathField'),
              controller: controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: context.tr('Đường dẫn tệp trên máy này'),
                helperText: context.tr(
                  'Nhập đường dẫn tuyệt đối. Thư mục cha sẽ được tạo nếu cần.',
                ),
                helperMaxLines: 3,
                errorText: valid
                    ? null
                    : context.tr('Cần đường dẫn tuyệt đối.'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.tr('Hủy')),
            ),
            FilledButton(
              onPressed: valid
                  ? () => Navigator.pop(ctx, controller.text.trim())
                  : null,
              child: Text(context.tr('Lưu tệp')),
            ),
          ],
        );
      },
    ),
  );
  String? selected;
  try {
    selected = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
  } finally {
    controller.dispose();
  }
  if (selected == null || !context.mounted) return null;
  if (await File(selected).exists()) {
    if (!context.mounted) return null;
    final overwrite = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('Ghi đè tệp đã có?')),
        content: SelectableText(selected!),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr('Hủy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr('Ghi đè')),
          ),
        ],
      ),
    );
    if (overwrite != true) return null;
  }
  return selected;
}
