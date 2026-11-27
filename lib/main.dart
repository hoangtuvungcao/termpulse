import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/automation/automation_dialog.dart';
import 'package:termpulse/features/vault/vault_screen.dart';
import 'package:termpulse/features/vault/vault_welcome_gate.dart';
import 'package:termpulse/features/security/ssh_trust_gate.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/desktop_shell.dart';
import 'package:termpulse/ui/mobile_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final supportPath = await ForegroundBridge.getAppDataDir();
  final dbPath = '$supportPath${Platform.pathSeparator}termpulse_vault.db';

  final container = ProviderContainer();
  await container.read(settingsProvider.notifier).loadFromDisk();
  await container.read(vaultProvider.notifier).initAtPath(dbPath);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const TermPulseApp(),
    ),
  );
}

class TermPulseApp extends ConsumerWidget {
  const TermPulseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultProvider);
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'TermPulse',
      debugShowCheckedModeBanner: false,
      locale: Locale(settings.language.code),
      supportedLocales: [
        for (final language in AppLanguage.values) Locale(language.code),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => AppLocalizationScope(
        language: settings.language,
        child: child ?? const SizedBox.shrink(),
      ),
      theme: buildTermPulseTheme(settings.themePreset),
      themeAnimationDuration:
          WidgetsBinding
              .instance
              .platformDispatcher
              .accessibilityFeatures
              .disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 200),
      home: Builder(
        builder: (context) => VaultWelcomeGate(
          child: SshTrustGate(
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: !vault.unlocked
                  ? const VaultScreen(key: ValueKey('vault_view'))
                  : LayoutBuilder(
                      key: const ValueKey('workspace_view'),
                      builder: (ctx, constraints) {
                        if (constraints.maxWidth >= 900) {
                          return DesktopShell(
                            onOpenTools: () => showAutomationDialog(ctx, ref),
                          );
                        }
                        return const MobileShell();
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
