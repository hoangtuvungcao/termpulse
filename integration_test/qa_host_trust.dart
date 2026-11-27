// Native QA only: approve the independently identified loopback fixture through
// the actual first-use UI. Never silently trust a production endpoint or a
// changed host key. Pass the fixture's startup SHA256 value using
// --dart-define=QA_SSH_FINGERPRINT=SHA256:...
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/src/rust/api/host_keys_api.dart' as host_keys;

int controlledQaHostApprovals = 0;
final Set<String> _approvedRequests = {};

Future<void> approveControlledQaHostPrompt(WidgetTester tester) async {
  if (find.byKey(const Key('sshTrustDialog')).evaluate().isEmpty) return;
  const expected = String.fromEnvironment('QA_SSH_FINGERPRINT');
  expect(
    RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(expected),
    isTrue,
    reason:
        'Native QA requires the fixture startup fingerprint via '
        '--dart-define=QA_SSH_FINGERPRINT=SHA256:...',
  );
  final prompts = await host_keys.listHostKeyPrompts();
  expect(
    prompts,
    hasLength(1),
    reason: 'Only one controlled QA trust request is allowed',
  );
  final prompt = prompts.single;
  expect(
    prompt.hostname,
    '127.0.0.1',
    reason: 'Never approve an arbitrary endpoint',
  );
  expect(prompt.port, 22220);
  expect(
    prompt.changed,
    isFalse,
    reason: 'QA must not auto-replace an existing host key',
  );
  expect(
    prompt.certificateAuthority,
    isFalse,
    reason: 'The controlled QA fixture uses a raw key',
  );
  expect(prompt.algorithm, 'ssh-ed25519');
  expect(prompt.publicKey, startsWith('ssh-ed25519 '));
  expect(
    prompt.fingerprint,
    expected,
    reason: 'The SSH key must match the independently started fixture',
  );
  expect(prompt.serverKeyFingerprint, expected);
  expect(find.text(expected), findsOneWidget);
  if (_approvedRequests.contains(prompt.requestId)) return;
  final checkbox = find.byKey(const Key('sshTrustVerifiedCheckbox'));
  expect(checkbox, findsOneWidget);
  await tester.ensureVisible(checkbox);
  if (tester.widget<CheckboxListTile>(checkbox).value != true) {
    await tester.tap(checkbox);
    await tester.pump();
  }
  final approve = find.byKey(const Key('sshTrustApproveButton'));
  expect(approve, findsOneWidget);
  expect(tester.widget<FilledButton>(approve).onPressed, isNotNull);
  _approvedRequests.add(prompt.requestId);
  await tester.tap(approve);
  controlledQaHostApprovals++;
  await tester.pump();
}
