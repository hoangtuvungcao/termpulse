// Opt-in native Android RDP diagnostic. Build this target, install with -r,
// and launch the Activity directly; do not use a driver that removes the app.
// Supply ONLY private app-data/qa_remote_desktop.json at runtime:
// {"hostname":"...","port":3389,"username":"...","password":"...",
//  "domain":"...","tlsServerName":"...",
//  "verifiedTlsCertificateSha256":"64 hex characters"}
// Optional pin MUST be verified independently through a trusted channel.
// Without a pin, the normal native root/name verification remains required.
// This target never calls production main(), opens the user's Vault, accepts
// an unverified certificate, tries another password, or captures screenshots.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/core/session_log_store.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:termpulse/state/settings_provider.dart';

const _hostId = 'qa_runtime_rdp_host';
const _hostLabel = 'Runtime RDP diagnostic';

class _DiagnosticFailure implements Exception {
  const _DiagnosticFailure(this.code);
  final String code;

  @override
  String toString() => code;
}

class _RuntimeConfig {
  _RuntimeConfig({
    required this.hostname,
    required this.port,
    required this.username,
    required this.password,
    this.domain,
    this.tlsServerName,
    this.verifiedTlsCertificateSha256,
  });

  final String hostname;
  final int port;
  final String username;
  String password;
  final String? domain;
  final String? tlsServerName;
  final String? verifiedTlsCertificateSha256;
}

String _normalizeFingerprint(String value) =>
    value.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();

Future<_RuntimeConfig> _readConfig(File file) async {
  late final String source;
  try {
    if (await file.length() > 64 * 1024) {
      throw const _DiagnosticFailure('QA_RUNTIME_CONFIG_INVALID');
    }
    source = await file.readAsString();
  } catch (_) {
    throw const _DiagnosticFailure('QA_RUNTIME_CONFIG_INVALID');
  } finally {
    // Delete even malformed input before parsing or starting any native work.
    // Never allow FormatException/FileSystemException to quote private input.
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      throw const _DiagnosticFailure('QA_RUNTIME_CONFIG_CLEANUP');
    }
  }
  try {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) throw const FormatException();
    const fields = {
      'hostname',
      'port',
      'username',
      'password',
      'domain',
      'tlsServerName',
      'verifiedTlsCertificateSha256',
    };
    if (value.keys.any((key) => !fields.contains(key))) {
      throw const FormatException();
    }
    final hostname = value['hostname'];
    final port = value['port'];
    final username = value['username'];
    final password = value['password'];
    final domain = value['domain'];
    final serverName = value['tlsServerName'];
    final pin = value['verifiedTlsCertificateSha256'];
    final invalidAddress = RegExp(r'[\s/@\[\]\\\x00-\x1f\x7f]');
    final invalidAccount = RegExp(r'[\x00-\x1f\x7f]');
    if (hostname is! String ||
        hostname.isEmpty ||
        hostname.length > 253 ||
        invalidAddress.hasMatch(hostname) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        username is! String ||
        username.trim().isEmpty ||
        username.length > 256 ||
        invalidAccount.hasMatch(username) ||
        password is! String ||
        password.isEmpty ||
        password.length > 16384 ||
        (domain != null &&
            (domain is! String ||
                domain.length > 256 ||
                invalidAccount.hasMatch(domain))) ||
        (serverName != null &&
            (serverName is! String ||
                serverName.isEmpty ||
                serverName.length > 253 ||
                invalidAddress.hasMatch(serverName))) ||
        (pin != null &&
            (pin is! String ||
                !RegExp(
                  r'^[0-9a-f]{64}$',
                ).hasMatch(_normalizeFingerprint(pin))))) {
      throw const FormatException();
    }
    return _RuntimeConfig(
      hostname: hostname,
      port: port,
      username: username.trim(),
      password: password,
      domain: domain as String?,
      tlsServerName: serverName as String?,
      verifiedTlsCertificateSha256: pin == null
          ? null
          : _normalizeFingerprint(pin as String),
    );
  } catch (_) {
    throw const _DiagnosticFailure('QA_RUNTIME_CONFIG_INVALID');
  }
}

class _MemorySettings extends SettingsController {
  @override
  void setLanguage(AppLanguage language) =>
      state = state.copyWith(language: language);

  @override
  void setThemePreset(AppThemePreset preset) =>
      state = state.copyWith(themePreset: preset);

  @override
  void setTerminalFontSize(double size) =>
      state = state.copyWith(terminalFontSize: size.clamp(11.0, 20.0));
}

String _nativeCode(Object? error) {
  // Only fixed known codes leave the device. Never report native error text,
  // remote content, host/user names, or a regex match from private input.
  const codes = {
    'RDP_AUTHENTICATION',
    'RDP_CERTIFICATE_CA',
    'RDP_CERTIFICATE_PIN',
    'RDP_CERTIFICATE_UNTRUSTED',
    'RDP_CONNECTION',
    'RDP_DECODE',
    'RDP_NEGOTIATION',
    'RDP_REACTIVATION_TIMEOUT',
    'RDP_SERVER_NAME',
    'RDP_TLS',
    'RDP_WRITE',
    'REMOTE_DESKTOP_ADDRESS',
    'REMOTE_DESKTOP_BUSY',
    'REMOTE_DESKTOP_CLOSED',
    'REMOTE_DESKTOP_CONFIG',
    'REMOTE_DESKTOP_CONNECT',
    'REMOTE_DESKTOP_CREDENTIAL',
    'REMOTE_DESKTOP_FRAME',
    'REMOTE_DESKTOP_HOST',
    'REMOTE_DESKTOP_INVALID_SIZE',
    'REMOTE_DESKTOP_PROTOCOL',
    'REMOTE_DESKTOP_PROXY',
    'REMOTE_DESKTOP_TIMEOUT',
    'REMOTE_DESKTOP_USERNAME',
    'REMOTE_DESKTOP_VAULT_LOCKED',
    'REMOTE_DESKTOP_VIEW_CLOSED',
  };
  final text = error?.toString() ?? '';
  for (final code in codes) {
    if (text.contains('$code:')) return code;
  }
  return 'QA_UNCLASSIFIED_NATIVE_ERROR';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android runtime-only saved-host RDP diagnostic',
    (tester) async {
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      final configFile = File(
        '${appData.path}${Platform.pathSeparator}qa_remote_desktop.json',
      );
      Directory? fixture;
      ProviderContainer? container;
      ProviderSubscription<WorkspaceState>? workspaceObserver;
      RemoteDesktopSession? observedSession;
      _RuntimeConfig? config;
      var cleaned = false;
      var cleanupFailed = false;
      var phase = 'configuration';
      var result = 'QA_NOT_STARTED';
      var probe = 'not_started';
      var trustMode = 'not_started';
      var attempts = 0;
      var nativeConnected = false;
      var connected = false;
      var rendered = false;
      var desktopPixelsReceived = false;
      var frameCount = 0;
      var frameWidth = 0;
      var frameHeight = 0;
      var lastSequence = 0;
      final clock = Stopwatch()..start();
      void observeDesktop() {
        final desktop = observedSession;
        if (desktop == null) return;
        if (desktop.connected) nativeConnected = true;
        final frame = desktop.frame;
        if (frame != null &&
            frame.sequence != lastSequence &&
            frame.width > 0 &&
            frame.height > 0 &&
            frame.rgba.length == frame.width * frame.height * 4) {
          lastSequence = frame.sequence;
          frameCount++;
          frameWidth = frame.width;
          frameHeight = frame.height;
          // Native RDP can emit its initially black buffer before the first
          // GraphicsUpdate. emit_frame always sets alpha=255, so only actual
          // RGB data can distinguish that bootstrap from desktop content.
          if (!desktopPixelsReceived) {
            for (var offset = 0; offset < frame.rgba.length; offset += 4) {
              if (frame.rgba[offset] != 0 ||
                  frame.rgba[offset + 1] != 0 ||
                  frame.rgba[offset + 2] != 0) {
                desktopPixelsReceived = true;
                break;
              }
            }
          }
        }
      }

      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        // Keep attempting every cleanup stage even if an earlier one fails.
        Future<void> attempt(Future<void> Function() action) async {
          try {
            await action();
          } catch (_) {
            cleanupFailed = true;
          }
        }

        await attempt(() async {
          if (await configFile.exists()) await configFile.delete();
        });
        await attempt(() async => workspaceObserver?.close());
        await attempt(
          () async => observedSession?.removeListener(observeDesktop),
        );
        await attempt(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        final current = container;
        if (current != null) {
          await attempt(
            () => current
                .read(sessionManagerProvider.notifier)
                .closeAllSessions(),
          );
          await attempt(() => current.read(backendProvider).vaultLock());
          await attempt(() => current.read(sessionLogStoreProvider).closeAll());
          await attempt(() async => current.dispose());
        }
        // Dart strings are immutable; drop this reference without claiming
        // in-memory zeroization. The only persisted credential was encrypted
        // in the isolated fixture, which is removed below.
        config?.password = '';
        final directory = fixture;
        if (directory != null) {
          await attempt(() async {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          });
        }
      }

      addTearDown(cleanup);
      try {
        final runtime = await _readConfig(configFile);
        config = runtime;
        trustMode = runtime.verifiedTlsCertificateSha256 == null
            ? 'system_roots'
            : 'verified_pin';
        phase = 'native_init';
        await RustLib.init();
        final directory = await appData.createTemp('qa_remote_desktop_vault_');
        fixture = directory;
        final scope = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(_MemorySettings.new),
            sessionLogStoreProvider.overrideWithValue(
              SessionLogStore(
                directory: () async => Directory('${directory.path}/logs'),
              ),
            ),
            automationStorageProvider.overrideWithValue(
              FileAutomationStorage(directory: () async => directory.path),
            ),
          ],
        );
        container = scope;
        if (scope.read(backendProvider) is! RustCoreBackend ||
            scope.read(remoteDesktopBackendProvider)
                is! RustRemoteDesktopBackend) {
          throw const _DiagnosticFailure('QA_NATIVE_BACKEND_REQUIRED');
        }
        phase = 'certificate_probe';
        final observedPin = _normalizeFingerprint(
          await scope
              .read(remoteDesktopBackendProvider)
              .probeCertificate(
                runtime.hostname,
                runtime.port,
                runtime.tlsServerName,
              ),
        );
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(observedPin)) {
          throw const _DiagnosticFailure('QA_CERTIFICATE_PROBE_INVALID');
        }
        if (runtime.verifiedTlsCertificateSha256 != null &&
            observedPin != runtime.verifiedTlsCertificateSha256) {
          probe = 'mismatch';
          throw const _DiagnosticFailure(
            'RDP_CERTIFICATE_FINGERPRINT_MISMATCH',
          );
        }
        // The probe grants no trust. Only an independently supplied pin is
        // saved; absent one, connectHost uses native root/name verification.
        probe = runtime.verifiedTlsCertificateSha256 == null
            ? 'observed_untrusted'
            : 'verified_pin_match';
        phase = 'temporary_vault';
        final vault = scope.read(vaultProvider.notifier);
        await vault.initAtPath('${directory.path}/vault.db');
        if (scope.read(vaultProvider).error != null ||
            scope.read(vaultProvider).initialized ||
            !await vault.unlock('Temporary-RDP-QA-2026!')) {
          throw const _DiagnosticFailure('QA_TEMPORARY_VAULT_FAILED');
        }
        final inventory = scope.read(inventoryProvider.notifier);
        try {
          await inventory.saveCredentialAndIdentity(
            cred: CredentialDto(
              id: 'qa_runtime_rdp_credential',
              name: 'Runtime diagnostic credential',
              kind: 'password',
              secret: runtime.password,
              storageBackend: 'vault',
            ),
            identity: IdentityDto(
              id: 'qa_runtime_rdp_identity',
              name: 'Runtime diagnostic identity',
              username: runtime.username,
              credentialId: 'qa_runtime_rdp_credential',
            ),
          );
        } finally {
          runtime.password = '';
        }
        await inventory.saveHost(
          HostDto(
            id: _hostId,
            label: _hostLabel,
            protocol: 'rdp',
            hostname: runtime.hostname,
            port: runtime.port,
            identityMode: 'by_id',
            identityId: 'qa_runtime_rdp_identity',
            jumpHostMode: 'none',
            proxyMode: 'none',
            envTag: 'dev',
            tags: const ['runtime-diagnostic'],
            notes: '',
            env: const [],
            followTerminalSftp: false,
            isFavorite: false,
            remoteDesktopJson: jsonEncode({
              'width': 1280,
              'height': 720,
              if (runtime.domain != null) 'domain': runtime.domain,
              if (runtime.tlsServerName != null)
                'tls_server_name': runtime.tlsServerName,
              if (runtime.verifiedTlsCertificateSha256 != null)
                'tls_certificate_sha256': runtime.verifiedTlsCertificateSha256,
            }),
          ),
        );
        if (scope.read(inventoryProvider).error != null) {
          throw const _DiagnosticFailure('QA_TEMPORARY_INVENTORY_FAILED');
        }
        phase = 'production_ui';
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: scope,
            child: const TermPulseApp(),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const Key('mobileHostCard_$_hostId'));
        final label = find.descendant(
          of: card,
          matching: find.text(_hostLabel),
        );
        if (card.evaluate().length != 1 || label.evaluate().length != 1) {
          throw const _DiagnosticFailure('QA_SAVED_HOST_UI_UNAVAILABLE');
        }
        // Subscribe before tapping: even an immediate native connected/frame
        // event is observed through the real production session controller.
        workspaceObserver = scope.listen<WorkspaceState>(
          sessionManagerProvider,
          (_, next) {
            final desktop = next.activeTab?.remoteDesktop;
            if (desktop != observedSession) {
              observedSession?.removeListener(observeDesktop);
              observedSession = desktop;
              desktop?.addListener(observeDesktop);
            }
            observeDesktop();
          },
        );
        await tester.ensureVisible(label);
        phase = 'connection';
        attempts = 1;
        await tester.tap(label);
        final observation = Stopwatch()..start();
        result = 'QA_OBSERVATION_TIMEOUT';
        while (observation.elapsed < const Duration(seconds: 75)) {
          await tester.pump(const Duration(milliseconds: 100));
          observeDesktop();
          final desktop = observedSession;
          if (desktop == null) continue;
          if (desktop.closed) {
            result = _nativeCode(desktop.message);
            if (result == 'QA_UNCLASSIFIED_NATIVE_ERROR') {
              result = 'QA_REMOTE_DESKTOP_CLOSED';
            }
            break;
          }
          if (nativeConnected &&
              desktop.connected &&
              frameCount > 0 &&
              desktopPixelsReceived) {
            rendered = find
                .byWidgetPredicate(
                  (widget) => widget is RawImage && widget.image != null,
                )
                .evaluate()
                .isNotEmpty;
            if (rendered) {
              connected = true;
              result = 'connected';
              break;
            }
          }
        }
        observation.stop();
        if (tester.takeException() != null) {
          throw const _DiagnosticFailure('QA_WIDGET_EXCEPTION');
        }
      } catch (error) {
        connected = false;
        result = error is _DiagnosticFailure ? error.code : _nativeCode(error);
        if (phase == 'certificate_probe' && probe == 'not_started') {
          probe = result;
        }
      } finally {
        await cleanup();
        clock.stop();
        if (cleanupFailed) {
          connected = false;
          result = 'QA_REMOTE_DESKTOP_CLEANUP_FAILED';
        }
        binding.reportData = <String, dynamic>{
          ...?binding.reportData,
          'rdp': <String, Object>{
            'result': result,
            'phase': phase,
            'connected': connected,
            'nativeConnected': nativeConnected,
            'rendered': rendered,
            'desktopPixelsReceived': desktopPixelsReceived,
            'certificateProbe': probe,
            'trustMode': trustMode,
            'attempts': attempts,
            'frameCount': frameCount,
            'width': frameWidth,
            'height': frameHeight,
            'elapsedMs': clock.elapsedMilliseconds,
            'cleanupSucceeded': !cleanupFailed,
          },
        };
        debugPrint(
          'TERMPULSE_REMOTE_DESKTOP_COMPLETED result=$result phase=$phase '
          'connected=$connected native_connected=$nativeConnected '
          'rendered=$rendered pixels=$desktopPixelsReceived '
          'probe=$probe trust=$trustMode attempts=$attempts '
          'frames=$frameCount width=$frameWidth height=$frameHeight '
          'elapsed_ms=${clock.elapsedMilliseconds} cleanup=${!cleanupFailed}',
        );
      }
      if (!connected) fail('Remote desktop diagnostic: $result');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
