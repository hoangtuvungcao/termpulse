import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/settings_provider.dart';

Future<bool> showCommandGuardDialog(
  BuildContext context, {
  required String command,
  required GuardResultDto result,
  required String targetLabel,
}) async {
  final isConfirm = result.severity == 'confirm';
  final approved = await showDialog<bool>(
    context: context,
    builder: (ctx) => _CommandGuardContent(
      command: command,
      result: result,
      targetLabel: targetLabel,
      isConfirm: isConfirm,
    ),
  );
  return approved ?? false;
}

class _CommandGuardContent extends StatelessWidget {
  final String command;
  final GuardResultDto result;
  final String targetLabel;
  final bool isConfirm;

  const _CommandGuardContent({
    required this.command,
    required this.result,
    required this.targetLabel,
    required this.isConfirm,
  });

  @override
  Widget build(BuildContext context) {
    AppLanguage lang = AppLanguage.vi;
    try {
      lang = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(settingsProvider).language;
    } catch (_) {}
    final s = AppStrings(lang);
    final pal =
        Theme.of(context).extension<TermPulsePalette>() ??
        paletteFor(AppThemePreset.dark);

    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: (isConfirm ? pal.red : pal.amber).withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              isConfirm
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: isConfirm ? pal.red : pal.amber,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isConfirm ? s.guardDangerTitle : s.guardConfirmTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            targetLabel,
            style: TextStyle(fontWeight: FontWeight.w700, color: pal.accent),
          ),
          if (result.reason != null) ...[
            const SizedBox(height: 6),
            Text(
              context.tr(result.reason!),
              style: TextStyle(color: pal.amber),
            ),
          ],
          if (result.isMultiline) ...[
            const SizedBox(height: 6),
            Text(
              context.tr('({count} lines)', {'count': '${result.lineCount}'}),
              style: TextStyle(fontSize: 12.5, color: pal.muted),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: pal.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: pal.border),
            ),
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(s.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: isConfirm ? pal.red : pal.amber,
            foregroundColor:
                ThemeData.estimateBrightnessForColor(
                      isConfirm ? pal.red : pal.amber,
                    ) ==
                    Brightness.dark
                ? Colors.white
                : const Color(0xFF10172A),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(s.guardConfirmRun),
        ),
      ],
    );
  }
}
