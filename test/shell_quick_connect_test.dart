import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/quick_connect.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/desktop_shell.dart';
import 'package:termpulse/ui/mobile_shell.dart';

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
      TerminalEventDto(kind: 'session_opened', text: 'shell_${streams.length}'),
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
  @override
  AppSettingsState build() => const AppSettingsState(language: AppLanguage.en);
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _QuickBackend backend, {
  required bool mobile,
  double textScale = 1,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(360, 640)
      : const Size(1280, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(_MemorySettings.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (final stream in backend.streams) {
      unawaited(stream.close());
    }
    await tester.pump();
  });
  expect(
    await container.read(vaultProvider.notifier).unlock('test-only-password'),
    isTrue,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        builder: (context, child) => AppLocalizationScope(
          language: AppLanguage.en,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: mobile ? const MobileShell() : const DesktopShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _key(String key) => find.byKey(Key(key));

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

  testWidgets(
    'mobile terminal keeps error details reachable with two tabs and keyboard',
    (tester) async {
      final backend = _QuickBackend();
      final container = await _mount(
        tester,
        backend,
        mobile: true,
        textScale: 1.6,
      );
      final manager = container.read(sessionManagerProvider.notifier);
      await manager.openQuickSsh(target: 'ops@first.example:22');
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(of: find.text('1'), matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      await manager.openQuickSsh(target: 'ops@second.example:22');
      await tester.pumpAndSettle();
      backend.streams.first.addError(
        StateError(
          'SSH_AUTHENTICATION_REJECTED: native authentication fixture',
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(sessionManagerProvider).tabs, hasLength(2));
      tester.view.physicalSize = const Size(740, 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 140);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_key('mobileSessionTabsStrip'), findsOneWidget);
      expect(_key('mobileAccessoryBar').hitTestable(), findsOneWidget);
      expect(
        tester.widget<Text>(_key('noticeSummary').first).data,
        contains('Check the username'),
      );
      final details = _key('noticeDetailsButton').first;
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(_key('noticeDetailsDialog'), findsOneWidget);
      expect(
        find.textContaining('native authentication fixture'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    final shell = mobile ? 'mobile' : 'desktop';
    testWidgets('$shell quick SSH keeps draft on cancel and dispatches once', (
      tester,
    ) async {
      final backend = _QuickBackend();
      await _mount(tester, backend, mobile: mobile);
      final field = _key('${shell}QuickConnectField');
      const draft = 'ssh -p 2222 ops@server.example';
      expect(
        tester.widget<TextField>(field).decoration!.hintText,
        quickConnectHint,
      );
      await tester.enterText(field, draft);
      final submit = tester.widget<TextField>(field).onSubmitted!;
      submit(draft);
      submit(draft);
      await tester.pumpAndSettle();
      expect(_key('quickConnectPasswordDialog'), findsOneWidget);
      expect(find.text('ops@server.example:2222'), findsOneWidget);
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(backend.ssh, isEmpty);
      await tester.tap(_key('quickConnectCancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).enabled, isTrue);
      expect(tester.widget<TextField>(field).controller!.text, draft);

      await tester.tap(_key('${shell}QuickConnectSubmit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        _key('quickConnectPasswordField'),
        '  test passphrase  ',
      );
      await tester.tap(_key('quickConnectSubmit'));
      await tester.pumpAndSettle();
      expect(backend.ssh, [
        (target: 'ops@server.example:2222', password: '  test passphrase  '),
      ]);
      expect(backend.telnet, isEmpty);
      if (!mobile) {
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('$shell quick Telnet requires plaintext confirmation', (
      tester,
    ) async {
      final backend = _QuickBackend();
      await _mount(tester, backend, mobile: mobile);
      await tester.enterText(
        _key('${shell}QuickConnectField'),
        'telnet router.example 2323',
      );
      await tester.tap(_key('${shell}QuickConnectSubmit'));
      await tester.pumpAndSettle();
      expect(_key('quickConnectTelnetDialog'), findsOneWidget);
      expect(find.text('router.example:2323'), findsOneWidget);
      expect(
        tester.widget<Text>(_key('quickConnectTelnetNotice')).data,
        contains('does not encrypt'),
      );
      expect(backend.telnet, isEmpty);
      expect(backend.ssh, isEmpty);
      await tester.tap(_key('quickConnectSubmit'));
      await tester.pumpAndSettle();
      expect(backend.telnet, [(hostname: 'router.example', port: 2323)]);
      expect(backend.ssh, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$shell invalid quick address never echoes credentials', (
      tester,
    ) async {
      final backend = _QuickBackend();
      final container = await _mount(tester, backend, mobile: mobile);
      await tester.enterText(
        _key('${shell}QuickConnectField'),
        'ops:private-input@server.example',
      );
      await tester.tap(_key('${shell}QuickConnectSubmit'));
      await tester.pumpAndSettle();
      final notice = tester.widget<Text>(_key('quickConnectValidationNotice'));
      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackBar.behavior, SnackBarBehavior.floating);
      expect(snackBar.width, mobile ? 328 : 720);
      expect(notice.data, isNot(contains('private-input')));
      expect(notice.data, isNot(contains('server.example')));
      expect(notice.data, contains('ssh [-p port] user@host'));
      expect(backend.ssh, isEmpty);
      expect(backend.telnet, isEmpty);
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
