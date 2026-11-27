import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/security/host_keys_dialog.dart';
import 'package:termpulse/features/security/host_trust_service.dart';
import 'package:termpulse/features/security/ssh_trust_gate.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _oldFingerprint = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

HostKeyPromptDto _prompt({bool changed = false, bool ca = false}) =>
    HostKeyPromptDto(
      requestId: 'controlled-request-${changed ? 'changed' : 'new'}',
      hostname: 'controlled.example',
      port: 2222,
      algorithm: 'ssh-ed25519',
      fingerprint: _fingerprint,
      publicKey: 'ssh-ed25519 controlled-public-key',
      previousFingerprints: changed ? ['key:$_oldFingerprint'] : [],
      changed: changed,
      certificateAuthority: ca,
      serverKeyFingerprint: ca ? _oldFingerprint : _fingerprint,
      certificatePrincipals: ca ? ['controlled.example'] : [],
      certificateValidUntil: ca ? '18446744073709551615' : null,
    );

const _record = HostKeyRecordDto(
  recordId: 'controlled.example|key|$_fingerprint',
  hostname: 'controlled.example',
  port: 2222,
  algorithm: 'ssh-ed25519',
  fingerprint: _fingerprint,
  publicKey: 'ssh-ed25519 controlled-public-key',
  certificateAuthority: false,
  revoked: false,
);

class _TrustService implements HostTrustService {
  final prompts = <HostKeyPromptDto>[];
  final keys = <HostKeyRecordDto>[];
  final decisions =
      <({String requestId, String decision, String fingerprint})>[];
  final removals = <({String recordId, String fingerprint})>[];
  final imports = <Map<String, Object>>[];
  bool failDecision = false;
  bool failImport = false;
  int polls = 0;
  Future<List<HostKeyPromptDto>>? nextPoll;

  @override
  Future<List<HostKeyPromptDto>> pending() async {
    polls++;
    final delayed = nextPoll;
    if (delayed != null) {
      nextPoll = null;
      return delayed;
    }
    return List.of(prompts);
  }

  @override
  Future<void> decide(HostKeyPromptDto prompt, String decision) async {
    if (failDecision) throw StateError('Controlled decision failure');
    decisions.add((
      requestId: prompt.requestId,
      decision: decision,
      fingerprint: prompt.fingerprint,
    ));
    prompts.removeWhere((request) => request.requestId == prompt.requestId);
  }

  @override
  Future<List<HostKeyRecordDto>> records() async => List.of(keys);

  @override
  Future<void> remove(
    HostKeyRecordDto record,
    String expectedFingerprint,
  ) async {
    if (expectedFingerprint != record.fingerprint) {
      throw StateError('Fingerprint mismatch');
    }
    removals.add((recordId: record.recordId, fingerprint: expectedFingerprint));
    keys.removeWhere((key) => key.recordId == record.recordId);
  }

  @override
  Future<void> importKey({
    required String hostname,
    required int port,
    required String publicKey,
    required bool certificateAuthority,
    required bool replaceExisting,
    required String expectedFingerprint,
  }) async {
    if (failImport) throw StateError('Controlled import failure');
    imports.add({
      'hostname': hostname,
      'port': port,
      'publicKey': publicKey,
      'certificateAuthority': certificateAuthority,
      'replaceExisting': replaceExisting,
      'expectedFingerprint': expectedFingerprint,
    });
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  _TrustService? service,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(FakeCoreBackend()),
      if (service != null) hostTrustServiceProvider.overrideWithValue(service),
    ],
  );
  await container.read(vaultProvider.notifier).unlock('controlled-test');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Builder(
          builder: (context) => SshTrustGate(
            child: Scaffold(
              body: Center(
                child: FilledButton(
                  key: const Key('openHostKeys'),
                  onPressed: () => showSshHostKeysDialog(context),
                  child: const Text('Manage trusted keys'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openManagement(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('openHostKeys')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('sshHostKeysDialog')), findsOneWidget);
}

void main() {
  testWidgets('fake backend never initializes the native trust bridge', (
    tester,
  ) async {
    final container = await _mount(tester);
    expect(container.read(hostTrustServiceProvider), isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown key needs explicit verification then sends bound approval',
    (tester) async {
      final service = _TrustService()..prompts.add(_prompt());
      await _mount(tester, service: service);
      expect(find.text('controlled.example:2222'), findsOneWidget);
      final approve = find.byKey(const Key('sshTrustApproveButton'));
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      expect(service.decisions, isEmpty);
      await tester.tap(find.byKey(const Key('sshTrustVerifiedCheckbox')));
      await tester.pump();
      expect(tester.widget<FilledButton>(approve).onPressed, isNotNull);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(service.decisions.single, (
        requestId: 'controlled-request-new',
        decision: 'trust',
        fingerprint: _fingerprint,
      ));
      expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
    },
  );

  testWidgets('reject is available without accepting or persisting trust', (
    tester,
  ) async {
    final service = _TrustService()..prompts.add(_prompt());
    await _mount(tester, service: service);
    await tester.tap(find.byKey(const Key('sshTrustRejectButton')));
    await tester.pumpAndSettle();
    expect(service.decisions.single.decision, 'reject');
    expect(service.decisions.single.fingerprint, _fingerprint);
    expect(service.keys, isEmpty);
    expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
  });

  testWidgets(
    'changed key requires the exact new fingerprint for replacement',
    (tester) async {
      final service = _TrustService()..prompts.add(_prompt(changed: true));
      await _mount(tester, service: service);
      expect(find.byKey(const Key('sshTrustApproveButton')), findsNothing);
      expect(find.text('key:$_oldFingerprint'), findsOneWidget);
      final replace = find.byKey(const Key('sshTrustReplaceButton'));
      final field = find.byKey(const Key('sshTrustFingerprintField'));
      expect(tester.widget<FilledButton>(replace).onPressed, isNull);
      await tester.enterText(field, _oldFingerprint);
      await tester.pump();
      expect(tester.widget<FilledButton>(replace).onPressed, isNull);
      expect(service.decisions, isEmpty);
      await tester.enterText(field, _fingerprint);
      await tester.pump();
      expect(tester.widget<FilledButton>(replace).onPressed, isNotNull);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      expect(service.decisions.single.decision, 'replace_verified');
      expect(service.decisions.single.fingerprint, _fingerprint);
    },
  );

  testWidgets(
    'certificate prompt distinguishes scoped CA trust from leaf fingerprint',
    (tester) async {
      final service = _TrustService()..prompts.add(_prompt(ca: true));
      await _mount(tester, service: service);
      expect(
        find.textContaining('Dấu vân tay CA ký chứng chỉ'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Khóa máy chủ: $_oldFingerprint'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Principal: controlled.example'),
        findsOneWidget,
      );
      expect(find.textContaining('Hết hạn: Không giới hạn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expired prompt closes without approval and polling stops on disposal',
    (tester) async {
      final service = _TrustService()..prompts.add(_prompt());
      await _mount(tester, service: service);
      expect(find.byKey(const Key('sshTrustDialog')), findsOneWidget);
      service.prompts.clear();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
      expect(service.decisions, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final polls = service.polls;
      await tester.pump(const Duration(seconds: 2));
      expect(service.polls, polls);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Vault lock removes stale trust dialog without allowing approval',
    (tester) async {
      final service = _TrustService()..prompts.add(_prompt());
      final container = await _mount(tester, service: service);
      await container.read(vaultProvider.notifier).lock();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
      expect(service.decisions, isEmpty);
      final polls = service.polls;
      await tester.pump(const Duration(seconds: 1));
      expect(service.polls, polls);
    },
  );

  testWidgets('decision error stays visible and can be retried or rejected', (
    tester,
  ) async {
    final service = _TrustService()
      ..prompts.add(_prompt())
      ..failDecision = true;
    await _mount(tester, service: service);
    await tester.tap(find.byKey(const Key('sshTrustVerifiedCheckbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sshTrustApproveButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Controlled decision failure'), findsOneWidget);
    expect(find.byKey(const Key('sshTrustDialog')), findsOneWidget);
    expect(service.decisions, isEmpty);
    service.failDecision = false;
    await tester.tap(find.byKey(const Key('sshTrustRejectButton')));
    await tester.pumpAndSettle();
    expect(service.decisions.single.decision, 'reject');
  });

  testWidgets('a late poll cannot reopen an already approved request', (
    tester,
  ) async {
    final prompt = _prompt();
    final service = _TrustService()..prompts.add(prompt);
    await _mount(tester, service: service);
    final delayed = Completer<List<HostKeyPromptDto>>();
    service.nextPoll = delayed.future;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('sshTrustVerifiedCheckbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sshTrustApproveButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
    delayed.complete([prompt]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
    expect(service.decisions.single.decision, 'trust');
  });

  testWidgets('switching Vault paths removes a stale pending dialog', (
    tester,
  ) async {
    final service = _TrustService()..prompts.add(_prompt());
    final container = await _mount(tester, service: service);
    expect(find.byKey(const Key('sshTrustDialog')), findsOneWidget);
    service.prompts.clear(); // Production cancellation clears the old scope.
    await container
        .read(vaultProvider.notifier)
        .initAtPath('/tmp/another-test-vault.db');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sshTrustDialog')), findsNothing);
    expect(service.decisions, isEmpty);
  });

  testWidgets('management removal requires typed matching fingerprint', (
    tester,
  ) async {
    final service = _TrustService()..keys.add(_record);
    await _mount(tester, service: service);
    await _openManagement(tester);
    await tester.tap(
      find.byKey(ValueKey('sshHostKeyRemove:${_record.recordId}')),
    );
    await tester.pumpAndSettle();
    final remove = find.byKey(const Key('sshHostKeyRemoveConfirmButton'));
    expect(tester.widget<FilledButton>(remove).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('sshHostKeyRemoveFingerprintField')),
      _oldFingerprint,
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(remove).onPressed, isNull);
    expect(service.removals, isEmpty);
    await tester.enterText(
      find.byKey(const Key('sshHostKeyRemoveFingerprintField')),
      _fingerprint,
    );
    await tester.pump();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(service.removals.single, (
      recordId: _record.recordId,
      fingerprint: _fingerprint,
    ));
    expect(service.keys, isEmpty);
    expect(
      find.textContaining('Chưa có máy chủ nào được tin cậy'),
      findsOneWidget,
    );
  });

  testWidgets(
    'management imports verified CA with explicit replacement and surfaces failure',
    (tester) async {
      final service = _TrustService()..failImport = true;
      await _mount(tester, service: service);
      await _openManagement(tester);
      await tester.tap(find.byKey(const Key('sshHostKeysImportButton')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sshHostKeyHostnameField')),
        'ca.example',
      );
      await tester.enterText(
        find.byKey(const Key('sshHostKeyPortField')),
        '2222',
      );
      await tester.enterText(
        find.byKey(const Key('sshHostKeyPublicKeyField')),
        _record.publicKey,
      );
      await tester.enterText(
        find.byKey(const Key('sshHostKeyExpectedFingerprintField')),
        _fingerprint,
      );
      final ca = find.byKey(const Key('sshHostKeyCaCheckbox'));
      await tester.ensureVisible(ca);
      await tester.tap(ca);
      final replace = find.byKey(const Key('sshHostKeyReplaceCheckbox'));
      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.tap(find.byKey(const Key('sshHostKeyImportSaveButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Controlled import failure'), findsOneWidget);
      expect(service.imports, isEmpty);
      service.failImport = false;
      await tester.tap(find.byKey(const Key('sshHostKeyImportSaveButton')));
      await tester.pumpAndSettle();
      expect(service.imports.single, {
        'hostname': 'ca.example',
        'port': 2222,
        'publicKey': _record.publicKey,
        'certificateAuthority': true,
        'replaceExisting': true,
        'expectedFingerprint': _fingerprint,
      });
      expect(find.byKey(const Key('sshHostKeyImportDialog')), findsNothing);
    },
  );
}
