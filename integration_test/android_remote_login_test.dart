// Opt-in native Android diagnostic. Build this target, install with -r, and
// launch the Activity directly. Do not use an integration driver that removes
// the installed app. Supply ONLY a private runtime app-data/qa_remote_login.json:
// {"hostname":"...","port":22,"username":"...","passwords":["..."],
//  "expectedFingerprint":"SHA256:..."}
// Never pass credentials through source, dart-defines, screenshots or logs.
// This entrypoint never calls production main() or opens the user's Vault.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/host_keys_api.dart' as host_keys;
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

class _RuntimeConfig {
  const _RuntimeConfig({
    required this.hostname,
    required this.port,
    required this.username,
    required this.passwords,
    required this.expectedFingerprint,
  });

  final String hostname;
  final int port;
  final String username;
  final List<String> passwords;
  final String expectedFingerprint;

  String get target {
    final address = hostname.contains(':') ? '[$hostname]' : hostname;
    return '$username@$address:$port';
  }
}

Future<_RuntimeConfig> _readConfig(File file) async {
  // Catch parse errors here: FormatException can otherwise quote its source,
  // which contains the private runtime candidates.
  try {
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) throw const FormatException();
    final hostname = value['hostname'];
    final port = value['port'];
    final username = value['username'];
    final passwords = value['passwords'];
    final fingerprint = value['expectedFingerprint'];
    if (hostname is! String ||
        hostname.isEmpty ||
        hostname.contains(RegExp(r'[\s/@\[\]]')) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        username is! String ||
        username.isEmpty ||
        username.contains(RegExp(r'[\s/@:]')) ||
        passwords is! List ||
        passwords.isEmpty ||
        passwords.length > 2 ||
        passwords.any((item) => item is! String || item.isEmpty) ||
        fingerprint is! String ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint)) {
      throw const FormatException();
    }
    return _RuntimeConfig(
      hostname: hostname,
      port: port,
      username: username,
      passwords: List<String>.from(passwords),
      expectedFingerprint: fingerprint,
    );
  } catch (_) {
    throw StateError(
      'Private remote-login configuration is missing or invalid.',
    );
  }
}

class _MemorySettings extends SettingsController {
  @override
  void setLanguage(AppLanguage language) {
    state = state.copyWith(language: language);
  }

  @override
  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
  }

  @override
  void setTerminalFontSize(double size) {
    state = state.copyWith(terminalFontSize: size.clamp(11.0, 20.0));
  }
}

Future<String?> _verifyExpectedHost(
  WidgetTester tester,
  _RuntimeConfig config,
  Set<String> approved,
) async {
  final dialog = find.byKey(const Key('sshTrustDialog'));
  if (dialog.evaluate().isEmpty) return null;
  final prompts = await host_keys.listHostKeyPrompts();
  String? blocked;
  if (prompts.length != 1) {
    blocked = 'SSH_HOST_KEY_UNEXPECTED_PROMPT';
  } else {
    final prompt = prompts.single;
    if (prompt.hostname != config.hostname || prompt.port != config.port) {
      blocked = 'SSH_HOST_KEY_UNEXPECTED_ENDPOINT';
    } else if (prompt.changed) {
      blocked = 'SSH_HOST_KEY_CHANGED';
    } else if (prompt.certificateAuthority ||
        prompt.algorithm != 'ssh-ed25519' ||
        prompt.fingerprint != config.expectedFingerprint ||
        prompt.serverKeyFingerprint != config.expectedFingerprint) {
      blocked = 'SSH_HOST_KEY_FINGERPRINT_MISMATCH';
    } else if (!approved.contains(prompt.requestId)) {
      final checkbox = find.byKey(const Key('sshTrustVerifiedCheckbox'));
      if (checkbox.evaluate().length != 1) {
        throw StateError('Expected host verification control is unavailable.');
      }
      await tester.ensureVisible(checkbox);
      await tester.pump();
      if (tester.widget<CheckboxListTile>(checkbox).value != true) {
        await tester.tap(checkbox);
        await tester.pump();
      }
      final approve = find.byKey(const Key('sshTrustApproveButton'));
      if (approve.evaluate().length != 1) {
        throw StateError('Expected host approval control is unavailable.');
      }
      await tester.ensureVisible(approve);
      await tester.pump();
      approved.add(prompt.requestId);
      await tester.tap(approve);
      await tester.pump();
    }
  }
  if (blocked != null) {
    final reject = find.byKey(const Key('sshTrustRejectButton'));
    if (reject.evaluate().length == 1) {
      await tester.ensureVisible(reject);
      await tester.pump();
      await tester.tap(reject);
      await tester.pump();
    }
  }
  return blocked;
}

String _phaseCode(String? error) =>
    RegExp(r'\bSSH_[A-Z_]+\b').firstMatch(error ?? '')?.group(0) ??
    'QA_UNCLASSIFIED_NATIVE_ERROR';

Future<bool> _captureResult(
  WidgetTester tester,
  GlobalKey key,
  Directory directory,
  String name,
  ProviderContainer container,
  _RuntimeConfig config,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
  if (find.byType(AlertDialog).evaluate().isNotEmpty) return false;
  final workspace = container.read(sessionManagerProvider);
  final visible =
      '${workspace.lastError ?? ''}\n'
      '${workspace.activeTab?.terminal.buffer.getText() ?? ''}';
  if (config.passwords.any(visible.contains)) return false;
  final context = key.currentContext;
  if (context == null || !context.mounted) {
    throw StateError('Remote-login result screenshot boundary is unavailable.');
  }
  final boundary = context.findRenderObject()! as RenderRepaintBoundary;
  expect(boundary.debugNeedsPaint, isFalse);
  final screenshot = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Could not encode remote-login result.');
    await File(
      '${directory.path}${Platform.pathSeparator}$name.png',
    ).writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      flush: true,
    );
  } finally {
    screenshot.dispose();
  }
  return true;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android runtime-only remote SSH login diagnostic',
    (tester) async {
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      final configFile = File(
        '${appData.path}${Platform.pathSeparator}qa_remote_login.json',
      );
      Directory? fixture;
      ProviderContainer? container;
      _RuntimeConfig? config;
      var cleaned = false;
      tester.testTextInput.register();
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        try {
          if (await configFile.exists()) await configFile.delete();
        } finally {
          try {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            final current = container;
            if (current != null) {
              try {
                await current
                    .read(sessionManagerProvider.notifier)
                    .closeAllSessions();
              } finally {
                await current.read(backendProvider).vaultLock();
              }
            }
          } finally {
            container?.dispose();
            tester.testTextInput.unregister();
            config?.passwords.fillRange(0, config.passwords.length, '');
            final directory = fixture;
            if (directory != null && await directory.exists()) {
              await directory.delete(recursive: true);
            }
          }
        }
      }

      addTearDown(cleanup);
      late final _RuntimeConfig runtime;
      try {
        runtime = await _readConfig(configFile);
      } finally {
        if (await configFile.exists()) await configFile.delete();
      }
      config = runtime;
      await RustLib.init();
      fixture = await appData.createTemp('qa_remote_login_vault_');
      final shots = await appData.createTemp('qa_remote_login_shots_');
      final scope = ProviderContainer(
        overrides: [settingsProvider.overrideWith(_MemorySettings.new)],
      );
      container = scope;
      expect(scope.read(backendProvider), isA<RustCoreBackend>());
      final vault = scope.read(vaultProvider.notifier);
      await vault.initAtPath(
        '${fixture.path}${Platform.pathSeparator}vault.db',
      );
      expect(scope.read(vaultProvider).error, isNull);
      expect(scope.read(vaultProvider).initialized, isFalse);
      expect(await vault.unlock('Temporary-Remote-QA-2026!'), isTrue);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: UncontrolledProviderScope(
            container: scope,
            child: const TermPulseApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobileShell')), findsOneWidget);
      final manager = scope.read(sessionManagerProvider.notifier);
      final approved = <String>{};
      final results = <Map<String, Object>>[];
      var connected = false;
      for (var i = 0; i < runtime.passwords.length; i++) {
        await manager.closeAllSessions();
        await tester.pumpAndSettle();
        var opened = false;
        final observer = scope.listen<WorkspaceState>(sessionManagerProvider, (
          _,
          next,
        ) {
          if (next.activeTab?.sessionId?.isNotEmpty == true) opened = true;
        });
        final clock = Stopwatch()..start();
        var result = 'QA_OBSERVATION_TIMEOUT';
        try {
          await manager.openQuickSsh(
            target: runtime.target,
            password: runtime.passwords[i],
          );
          await tester.pump();
          // Enter the new terminal through the app's normal session chip;
          // runtime credentials never enter a TextField or the widget tree.
          final chip = find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(InkWell),
          );
          if (chip.evaluate().length == 1) {
            await tester.tap(chip);
            await tester.pump();
          }
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            final hostBlocked = await _verifyExpectedHost(
              tester,
              runtime,
              approved,
            );
            if (hostBlocked != null) {
              result = hostBlocked;
              break;
            }
            final workspace = scope.read(sessionManagerProvider);
            if (opened) {
              result = 'connected';
              connected = true;
              break;
            }
            if (workspace.activeTab?.closed == true) {
              result = _phaseCode(
                workspace.lastError ?? workspace.activeTab?.closeReason,
              );
              break;
            }
          }
        } finally {
          clock.stop();
          observer.close();
        }
        final ordinal = i + 1;
        // A successful remote shell may display private account content.
        // The native session_opened observation is sufficient proof of login.
        final screenshot =
            !connected &&
            await _captureResult(
              tester,
              captureKey,
              shots,
              'attempt-$ordinal-$result',
              scope,
              runtime,
            );
        results.add(<String, Object>{
          'index': ordinal,
          'result': result,
          'elapsedMs': clock.elapsedMilliseconds,
          'screenshotSaved': screenshot,
        });
        debugPrint(
          'TERMPULSE_REMOTE_LOGIN_ATTEMPT index=$ordinal result=$result elapsed_ms=${clock.elapsedMilliseconds}',
        );
        if (connected ||
            result.startsWith('SSH_HOST_KEY_') ||
            result == 'QA_OBSERVATION_TIMEOUT') {
          break;
        }
      }
      expect(tester.takeException(), isNull);
      await cleanup();
      binding.reportData = <String, dynamic>{
        ...?binding.reportData,
        'attempts': results,
        'connected': connected,
        'screenshotDirectory': shots.path,
      };
      debugPrint('TERMPULSE_REMOTE_LOGIN_SCREENSHOT_DIR=${shots.path}');
      debugPrint(
        'TERMPULSE_REMOTE_LOGIN_COMPLETED connected=$connected attempts=${results.length}',
      );
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
