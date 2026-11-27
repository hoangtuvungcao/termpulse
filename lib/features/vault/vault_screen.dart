import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/settings/settings_dialog.dart';
import 'package:termpulse/features/settings/privacy_policy_screen.dart';
import 'package:termpulse/features/settings/app_permissions_screen.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/brand_logo.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;
  String? _localErr;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(VaultUiState st) async {
    if (st.loading || _submitting) return;
    final pw = _passCtrl.text;
    if (pw.isEmpty) {
      setState(() => _localErr = 'Vui lòng nhập mật khẩu chính.');
      return;
    }
    if (!st.initialized && pw != _confirmCtrl.text) {
      setState(() => _localErr = 'Mật khẩu xác nhận không khớp.');
      return;
    }
    setState(() {
      _localErr = null;
      _submitting = true;
    });
    try {
      await ref.read(vaultProvider.notifier).unlock(pw);
    } catch (e) {
      if (mounted) setState(() => _localErr = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(vaultProvider);
    final settings = ref.watch(settingsProvider);
    final s = AppStrings(settings.language);
    final tp = context.tp;
    final isDark = tp.brightness == Brightness.dark;
    final isNew = !st.initialized;
    final err = _localErr ?? st.error;
    final busy = st.loading || _submitting;

    return Scaffold(
      body: AmbientBackdrop(
        child: SafeArea(
          child: Stack(
            children: [
              // Translucent floating top-right quick bar
              Positioned(
                top: 14,
                right: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<AppLanguage>(
                      key: const Key('vaultLangBtn'),
                      tooltip: s.settingsLanguageLabel,
                      onSelected: (lang) =>
                          ref.read(settingsProvider.notifier).setLanguage(lang),
                      itemBuilder: (_) => [
                        for (final lang in AppLanguage.values)
                          PopupMenuItem(
                            value: lang,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    lang.shortBadge,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                      color: tp.accent,
                                    ),
                                  ),
                                ),
                                Text(lang.nativeName),
                              ],
                            ),
                          ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: tp.surface.withValues(
                            alpha: isDark ? 0.86 : 0.94,
                          ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: tp.borderStrong),
                          boxShadow: isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.translate_rounded,
                              size: 15,
                              color: tp.accent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              settings.language.nativeName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: tp.ink,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              Icons.arrow_drop_down_rounded,
                              size: 16,
                              color: tp.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: tp.surface.withValues(
                          alpha: isDark ? 0.86 : 0.94,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: tp.borderStrong),
                        boxShadow: isDark
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                      child: IconButton(
                        key: const Key('quickThemeToggleBtn'),
                        tooltip: s.settingsThemeLabel,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          settings.themePreset == AppThemePreset.dark
                              ? Icons.light_mode_rounded
                              : Icons.dark_mode_rounded,
                          size: 18,
                          color: tp.accent,
                        ),
                        onPressed: () =>
                            ref.read(settingsProvider.notifier).toggleTheme(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      decoration: BoxDecoration(
                        color: tp.surface.withValues(
                          alpha: isDark ? 0.86 : 0.94,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: tp.borderStrong),
                        boxShadow: isDark
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                      child: IconButton(
                        key: const Key('vaultSettingsBtn'),
                        tooltip: s.settingsTooltip,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.tune_rounded, size: 18, color: tp.ink),
                        onPressed: () => showSettingsDialog(context, ref),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                top: 74,
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 452),
                      child: Container(
                        decoration: BoxDecoration(
                          color: tp.surface.withValues(
                            alpha: isDark ? 0.94 : 0.98,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: tp.borderStrong),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: isDark ? 0.58 : 0.08,
                              ),
                              blurRadius: 42,
                              offset: const Offset(0, 20),
                            ),
                            if (isDark)
                              BoxShadow(
                                color: tp.accent.withValues(alpha: 0.10),
                                blurRadius: 36,
                                spreadRadius: -8,
                              ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const TermPulseLogo(size: 56, showGlow: true),
                                  const SizedBox(width: 15),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            RichText(
                                              text: TextSpan(
                                                style: const TextStyle(
                                                  fontSize: 22,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: -0.5,
                                                ),
                                                children: [
                                                  TextSpan(
                                                    text: 'Term',
                                                    style: TextStyle(
                                                      color: tp.ink,
                                                    ),
                                                  ),
                                                  TextSpan(
                                                    text: 'Pulse',
                                                    style: TextStyle(
                                                      color: tp.accent,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 2.5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: tp.cyanContainer,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                border: Border.all(
                                                  color: tp.cyan.withValues(
                                                    alpha: 0.32,
                                                  ),
                                                ),
                                              ),
                                              child: Text(
                                                'v1.0',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                  color: tp.cyan,
                                                  fontFamily: 'monospace',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          s.vaultSubtitle,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: tp.muted,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Container(
                                padding: const EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      tp.accentContainer,
                                      tp.cyanContainer.withValues(
                                        alpha: isDark ? 0.5 : 0.6,
                                      ),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: tp.accent.withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: tp.accent.withValues(
                                          alpha: 0.16,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        Icons.verified_user_rounded,
                                        size: 18,
                                        color: tp.accent,
                                      ),
                                    ),
                                    const SizedBox(width: 11),
                                    Expanded(
                                      child: Text(
                                        s.vaultSecurityBanner,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          color: tp.ink,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 22),
                              Text(
                                isNew ? s.vaultNewTitle : s.vaultUnlockTitle,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                key: const Key('vaultPasswordField'),
                                controller: _passCtrl,
                                enabled: !busy,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: [
                                  isNew
                                      ? AutofillHints.newPassword
                                      : AutofillHints.password,
                                ],
                                textInputAction: isNew
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                obscureText: _obscure,
                                onSubmitted: (_) {
                                  if (!isNew) _submit(st);
                                },
                                decoration: InputDecoration(
                                  labelText: s.masterPasswordLabel,
                                  prefixIcon: const Icon(
                                    Icons.lock_outline_rounded,
                                    size: 18,
                                  ),
                                  suffixIcon: IconButton(
                                    tooltip: _obscure
                                        ? context.tr('Hiện mật khẩu')
                                        : context.tr('Ẩn mật khẩu'),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_off_rounded
                                          : Icons.visibility_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ),
                              if (isNew) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  key: const Key('vaultConfirmPasswordField'),
                                  controller: _confirmCtrl,
                                  enabled: !busy,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [
                                    AutofillHints.newPassword,
                                  ],
                                  textInputAction: TextInputAction.done,
                                  obscureText: _obscure,
                                  onSubmitted: (_) => _submit(st),
                                  decoration: InputDecoration(
                                    labelText: s.confirmPasswordLabel,
                                    prefixIcon: const Icon(
                                      Icons.lock_reset_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                              if (err != null) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 9,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tp.red.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: tp.red.withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline_rounded,
                                        size: 16,
                                        color: tp.red,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          context.tr(err),
                                          style: TextStyle(
                                            color: tp.red,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  gradient: LinearGradient(
                                    colors: [
                                      tp.accent,
                                      Color.lerp(tp.accent, tp.cyan, 0.25)!,
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: tp.accent.withValues(
                                        alpha: isDark ? 0.38 : 0.24,
                                      ),
                                      blurRadius: 16,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: SizedBox(
                                  height: 48,
                                  child: FilledButton.icon(
                                    key: const Key('vaultSubmitButton'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.transparent,
                                      shadowColor: Colors.transparent,
                                      foregroundColor: tp.accentInk,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: busy ? null : () => _submit(st),
                                    icon: busy
                                        ? SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: tp.accentInk,
                                            ),
                                          )
                                        : Icon(
                                            isNew
                                                ? Icons.shield_rounded
                                                : Icons.lock_open_rounded,
                                            size: 18,
                                          ),
                                    label: Text(
                                      isNew
                                          ? s.createVaultCta
                                          : s.unlockVaultCta,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                children: [
                                  TextButton(
                                    key: const Key('privacyButton'),
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const PrivacyPolicyScreen(),
                                      ),
                                    ),
                                    child: Text(
                                      context.tr('Chính sách quyền riêng tư'),
                                    ),
                                  ),
                                  TextButton(
                                    key: const Key('permissionsButton'),
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const AppPermissionsScreen(),
                                      ),
                                    ),
                                    child: Text(
                                      context.tr('Quyền và thông báo'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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
