import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/features/hosts/quick_connect.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

class _QuickBackend extends FakeCoreBackend {
  final ssh = <({String target, String? password})>[];
  final telnet = <({String hostname, int port})>[];
  final streams = <StreamController<TerminalEventDto>>[];

  Stream<TerminalEventDto> _stream() {
    final stream = StreamController<TerminalEventDto>();
    streams.add(stream);
    stream.add(
      TerminalEventDto(kind: 'session_opened', text: 'quick_${streams.length}'),
    );
    return stream.stream;
  }

  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) {
    ssh.add((target: target, password: password));
    return _stream();
  }

  @override
  Stream<TerminalEventDto> connectTelnetHost({
    required String hostname,
    required int port,
    String? label,
  }) {
    telnet.add((hostname: hostname, port: port));
    return _stream();
  }
}

class _MemorySettings extends SettingsController {
  _MemorySettings(this.language);
  final AppLanguage language;

  @override
  AppSettingsState build() => AppSettingsState(language: language);
}

class _Outcome {
  bool? value;
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _QuickBackend backend,
  String input,
  _Outcome outcome, {
  AppLanguage language = AppLanguage.en,
}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(() => _MemorySettings(language)),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await container.read(sessionManagerProvider.notifier).closeAllSessions();
    for (final stream in backend.streams) {
      await stream.close();
    }
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('launchQuickConnect'),
                onPressed: () async {
                  outcome.value = await showQuickConnect(context, ref, input);
                },
                child: const Text('Connect'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launchQuickConnect')));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('terminal SSH syntax normalizes to native target without a shell', () {
    const cases = {
      'ops@example.com': ('ops', 'example.com', 22),
      'ssh ops@192.0.2.10': ('ops', '192.0.2.10', 22),
      'ssh -p 2222 ops@server.example': ('ops', 'server.example', 2222),
      'ssh ops@server.example -p 2200': ('ops', 'server.example', 2200),
      'ssh -p2200 ops@server.example': ('ops', 'server.example', 2200),
      'ssh server.example': ('root', 'server.example', 22),
      'server.example:2222': ('root', 'server.example', 2222),
      'ops@[2001:db8::1]:2200': ('ops', '2001:db8::1', 2200),
      'ssh -p 2222 ops@[2001:db8::1]': ('ops', '2001:db8::1', 2222),
      'ssh ops@2001:db8::1': ('ops', '2001:db8::1', 22),
      '  ssh   ops@localhost  ': ('ops', 'localhost', 22),
    };
    for (final entry in cases.entries) {
      final target = parseQuickConnect(entry.key);
      final (user, host, port) = entry.value;
      expect(target.protocol, QuickConnectProtocol.ssh);
      expect(target.username, user);
      expect(target.hostname, host);
      expect(target.port, port);
      expect(
        target.sshTarget,
        '$user@${host.contains(':') ? '[$host]' : host}:$port',
      );
    }
  });

  test('Telnet supports default explicit and bracketed IPv6 ports', () {
    const cases = {
      'telnet 192.0.2.20': ('192.0.2.20', 23),
      'telnet router.example 2323': ('router.example', 2323),
      'telnet [2001:db8::2] 2323': ('2001:db8::2', 2323),
      'telnet router.example:2323': ('router.example', 2323),
    };
    for (final entry in cases.entries) {
      final target = parseQuickConnect(entry.key);
      expect(target.protocol, QuickConnectProtocol.telnet);
      expect(target.hostname, entry.value.$1);
      expect(target.port, entry.value.$2);
      expect(target.username, isNull);
    }
  });

  test('rejects malformed ports addresses remote commands and credentials', () {
    const invalid = [
      '',
      'ssh',
      'ssh -p',
      'ssh -p 0 ops@host',
      'ssh -p -2 ops@host',
      'ssh -p65536 ops@host',
      'ops@host:',
      'ops@host:22suffix',
      'ssh ops@host echo hello',
      'ssh -i private-key ops@host',
      'ssh ops@host -o StrictHostKeyChecking=no',
      'ops:do-not-echo@host',
      'ops@host@other-host',
      'ops@/etc/passwd',
      'ops@host;echo',
      'ops@[not-ipv6]:22',
      'ops@[2001:db8::1]extra',
      'ops@[2001:db8::1]:65536',
      'ssh -p 2222 ops@host:22',
      'ssh -p22 -p22 ops@host',
      'telnet ops@host',
      'telnet host 0',
      'telnet host:23 23',
      'telnet host 23 command',
      'ssh ops@host\necho secret',
      'ssh://ops:do-not-echo@host',
      'rdp host',
      'vnc host',
      'ops@999.999.999.999',
    ];
    for (final input in invalid) {
      expect(
        () => parseQuickConnect(input),
        throwsA(isA<QuickConnectException>()),
      );
    }
  });

  test('validation copy is localized and never embeds private input', () {
    for (final error in QuickConnectError.values) {
      final messages = {
        for (final language in AppLanguage.values)
          quickConnectValidationMessage(error, language),
      };
      expect(messages, hasLength(AppLanguage.values.length));
      expect(messages.every((message) => message.trim().isNotEmpty), isTrue);
    }
    try {
      parseQuickConnect('ops:do-not-echo@host');
      fail('An address containing a password must be rejected.');
    } on QuickConnectException catch (error) {
      expect(error.error, QuickConnectError.username);
      expect(error.toString(), isNot(contains('do-not-echo')));
    }
  });

  testWidgets('SSH asks separately and dispatches a normalized target', (
    tester,
  ) async {
    final backend = _QuickBackend();
    final outcome = _Outcome();
    final container = await _mount(
      tester,
      backend,
      'ssh -p 2222 ops@server.example',
      outcome,
    );
    final dialog = find.byKey(const Key('quickConnectPasswordDialog'));
    final field = find.byKey(const Key('quickConnectPasswordField'));
    expect(dialog, findsOneWidget);
    expect(tester.widget<AlertDialog>(dialog).alignment, Alignment.center);
    expect(find.text('ops@server.example:2222'), findsOneWidget);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(backend.ssh, isEmpty);
    await tester.enterText(field, '  synthetic QA password  ');
    await tester.tap(find.byKey(const Key('quickConnectSubmit')));
    await tester.pumpAndSettle();
    expect(outcome.value, isTrue);
    expect(backend.ssh, [
      (
        target: 'ops@server.example:2222',
        password: '  synthetic QA password  ',
      ),
    ]);
    expect(backend.telnet, isEmpty);
    expect(
      container.read(sessionManagerProvider).activeTab!.title,
      'ops@server.example:2222',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH empty password stays optional and cancel opens no session', (
    tester,
  ) async {
    final backend = _QuickBackend();
    final outcome = _Outcome();
    await _mount(tester, backend, 'ssh host.example', outcome);
    await tester.tap(find.byKey(const Key('quickConnectCancel')));
    await tester.pumpAndSettle();
    expect(outcome.value, isFalse);
    expect(backend.ssh, isEmpty);
    await tester.tap(find.byKey(const Key('launchQuickConnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickConnectSubmit')));
    await tester.pumpAndSettle();
    expect(outcome.value, isTrue);
    expect(backend.ssh.single, (
      target: 'root@host.example:22',
      password: null,
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Telnet shows transport notice and never asks an SSH password', (
    tester,
  ) async {
    final backend = _QuickBackend();
    final outcome = _Outcome();
    final container = await _mount(
      tester,
      backend,
      'telnet router.example 2323',
      outcome,
    );
    expect(find.byKey(const Key('quickConnectTelnetDialog')), findsOneWidget);
    expect(find.byKey(const Key('quickConnectPasswordField')), findsNothing);
    expect(find.textContaining('does not encrypt'), findsOneWidget);
    expect(backend.telnet, isEmpty);
    await tester.tap(find.byKey(const Key('quickConnectCancel')));
    await tester.pumpAndSettle();
    expect(outcome.value, isFalse);
    expect(backend.telnet, isEmpty);
    await tester.tap(find.byKey(const Key('launchQuickConnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickConnectSubmit')));
    await tester.pumpAndSettle();
    expect(outcome.value, isTrue);
    expect(backend.telnet.single, (hostname: 'router.example', port: 2323));
    expect(backend.ssh, isEmpty);
    expect(
      container.read(sessionManagerProvider).activeTab!.protocol,
      'telnet',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid quick input shows useful notice without echoing secrets',
    (tester) async {
      final backend = _QuickBackend();
      final outcome = _Outcome();
      await _mount(
        tester,
        backend,
        'ssh ops:do-not-echo@server.example',
        outcome,
      );
      expect(outcome.value, isFalse);
      expect(
        find.byKey(const Key('quickConnectValidationNotice')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Do not put passwords in the address'),
        findsOneWidget,
      );
      expect(find.textContaining('do-not-echo'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(backend.ssh, isEmpty);
      expect(backend.telnet, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
