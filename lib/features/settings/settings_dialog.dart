import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/security/host_keys_dialog.dart';
import 'app_permissions_screen.dart';
import 'privacy_policy_screen.dart';
import 'package:termpulse/state/settings_provider.dart';

Future<void> showSettingsDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final s = AppStrings(st.language);
    final tp = context.tp;

    return AlertDialog(
      key: const Key('settingsDialog'),
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tp.accentContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tp.accent.withValues(alpha: 0.3)),
            ),
            child: Icon(Icons.tune_rounded, color: tp.accent, size: 19),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              s.settingsTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                key: const Key('settingsPrivacyButton'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.privacy_tip_outlined),
                title: Text(context.tr('Chính sách quyền riêng tư')),
                subtitle: Text(
                  context.tr('Xem cách dữ liệu được lưu và chia sẻ'),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                ),
              ),
              ListTile(
                key: const Key('settingsPermissionsButton'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_outlined),
                title: Text(context.tr('Quyền và thông báo')),
                subtitle: Text(
                  context.tr('Kiểm tra quyền thông báo và hỗ trợ chạy nền'),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AppPermissionsScreen(),
                  ),
                ),
              ),
              ListTile(
                key: const Key('settingsSshHostKeysButton'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_user_outlined),
                title: Text(context.tr('Khóa máy chủ SSH và CA')),
                subtitle: Text(
                  context.tr(
                    'Xem fingerprint, nhập khóa đã xác minh hoặc đặt lại tin cậy',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showSshHostKeysDialog(context),
              ),
              const Divider(),
              Text(
                s.settingsLanguageLabel,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: tp.muted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final lang in AppLanguage.values)
                    ChoiceChip(
                      key: Key('lang_${lang.name}'),
                      showCheckmark: false,
                      selected: st.language == lang,
                      selectedColor: tp.accentContainer,
                      side: BorderSide(
                        color: st.language == lang
                            ? tp.accent
                            : tp.borderStrong,
                      ),
                      label: Text(
                        lang.nativeName,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: st.language == lang ? tp.accent : tp.ink,
                        ),
                      ),
                      onSelected: (_) => ctrl.setLanguage(lang),
                    ),
                ],
              ),
              const SizedBox(height: 18),

              Text(
                s.settingsThemeLabel,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: tp.muted,
                ),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = [
                    for (final preset in AppThemePreset.values)
                      _ThemeModeCard(
                        key: Key('theme_${preset.name}'),
                        preset: preset,
                        selected: st.themePreset == preset,
                        onTap: () => ctrl.setThemePreset(preset),
                      ),
                  ];
                  if (constraints.maxWidth < 340) {
                    return Column(
                      children: [
                        cards.first,
                        const SizedBox(height: 10),
                        cards.last,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: cards.first),
                      const SizedBox(width: 10),
                      Expanded(child: cards.last),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),

              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.settingsFontSizeLabel,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: tp.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: tp.surface2,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: tp.border),
                    ),
                    child: Text(
                      '${st.terminalFontSize.toStringAsFixed(1)} px',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: tp.accent,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    key: const Key('terminalFontDecrease'),
                    tooltip: '${s.settingsFontSizeLabel} −',
                    onPressed: st.terminalFontSize <= 11
                        ? null
                        : () => ctrl.setTerminalFontSize(
                            st.terminalFontSize - 0.5,
                          ),
                    icon: const Icon(Icons.text_decrease_rounded, size: 20),
                  ),
                  Expanded(
                    child: Slider(
                      key: const Key('terminalFontSlider'),
                      value: st.terminalFontSize.clamp(11.0, 20.0),
                      min: 11.0,
                      max: 20.0,
                      divisions: 18,
                      onChanged: ctrl.setTerminalFontSize,
                    ),
                  ),
                  IconButton(
                    key: const Key('terminalFontIncrease'),
                    tooltip: '${s.settingsFontSizeLabel} +',
                    onPressed: st.terminalFontSize >= 20
                        ? null
                        : () => ctrl.setTerminalFontSize(
                            st.terminalFontSize + 0.5,
                          ),
                    icon: const Icon(Icons.text_increase_rounded, size: 20),
                  ),
                  IconButton(
                    key: const Key('terminalFontReset'),
                    tooltip: '${s.settingsFontSizeLabel}: 13.5 px',
                    onPressed: st.terminalFontSize == 13.5
                        ? null
                        : () => ctrl.setTerminalFontSize(13.5),
                    icon: const Icon(Icons.restart_alt_rounded, size: 20),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: tp.terminalTheme.background,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: tp.borderStrong),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    'ops@prod-web-01:/etc/nginx\$ systemctl status nginx',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: st.terminalFontSize,
                      color: tp.terminalTheme.green,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.close),
        ),
      ],
    );
  }
}

class _ThemeModeCard extends StatelessWidget {
  final AppThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeModeCard({
    super.key,
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = paletteFor(preset);
    final activeTp = context.tp;
    final isDark = preset == AppThemePreset.dark;

    return Semantics(
      button: true,
      selected: selected,
      label: context.tr(preset.displayName),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? activeTp.accent : activeTp.borderStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: pal.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: pal.borderStrong),
                    ),
                    child: Icon(
                      isDark
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                      size: 16,
                      color: pal.accent,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      context.tr(preset.displayName),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: pal.ink,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 17,
                      color: activeTp.accent,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Mini Terminal Visual Preview
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: pal.terminalTheme.background,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: pal.border),
                ),
                child: Text(
                  '~\$ ssh prod-web-01',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: pal.terminalTheme.green,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
