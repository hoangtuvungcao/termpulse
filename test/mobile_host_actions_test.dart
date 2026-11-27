import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/mobile_shell.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

class _HostActionsBackend extends FakeCoreBackend {
  final savedHosts = <HostDto>[];
  final deletedHostIds = <String>[];
  final sshHostIds = <String>[];
  final quickSshTargets = <String>[];
  bool failSave = false;
  bool failDelete = false;
  bool failListHosts = false;
  Completer<void>? pendingDelete;

  @override
  Future<List<HostDto>> listHosts() async {
    if (failListHosts) throw StateError('Host list unavailable after delete');
    return super.listHosts();
  }

  @override
  Future<void> upsertHost(HostDto host) async {
    savedHosts.add(host);
    if (failSave) throw StateError('Save storage unavailable');
    final index = hosts.indexWhere((existing) => existing.id == host.id);
    if (index < 0) {
      hosts.add(host);
    } else {
      hosts[index] = host;
    }
  }

  @override
  Future<void> deleteHost(String id) async {
    deletedHostIds.add(id);
    await pendingDelete?.future;
    if (failDelete) throw StateError('Delete storage unavailable');
    hosts.removeWhere((host) => host.id == id);
  }

  @override
  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows) {
    sshHostIds.add(hostId);
    return super.connectSshHost(hostId, cols, rows);
  }

  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) {
    quickSshTargets.add(target);
    return super.connectQuickSsh(
      target: target,
      password: password,
      privateKeyPem: privateKeyPem,
      cols: cols,
      rows: rows,
    );
  }
}

class _MemorySettings extends SettingsController {
  _MemorySettings(this.preset);
  final AppThemePreset preset;

  @override
  AppSettingsState build() => AppSettingsState(themePreset: preset);
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _HostActionsBackend backend, {
  Size size = const Size(412, 915),
  AppThemePreset preset = AppThemePreset.dark,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(() => _MemorySettings(preset)),
    ],
  );
  addTearDown(container.dispose);
  expect(
    await container.read(vaultProvider.notifier).unlock('test-master-password'),
    isTrue,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTermPulseTheme(preset),
        builder: (context, child) => AppLocalizationScope(
          language: AppLanguage.vi,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: const MobileShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('mobileShell')), findsOneWidget);
  return container;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
  }
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(Key(key));
Finder _field(String label) => find.widgetWithText(TextField, label);
Finder get _saveHost => find.widgetWithText(FilledButton, 'Lưu Host');
Finder get _cancelHost => find.widgetWithText(TextButton, 'Huỷ');

Future<void> _expectErrorDetails(
  WidgetTester tester,
  String raw, {
  Finder? notice,
}) async {
  expect(find.textContaining(raw), findsNothing);
  final details = notice == null
      ? _key('noticeDetailsButton')
      : find.descendant(of: notice, matching: _key('noticeDetailsButton'));
  await _tap(tester, details);
  expect(find.textContaining(raw), findsOneWidget);
  await _tap(
    tester,
    find.descendant(
      of: _key('noticeDetailsDialog'),
      matching: find.widgetWithText(TextButton, 'Đóng'),
    ),
  );
  expect(find.textContaining(raw), findsNothing);
}

void _expectNoConnections(
  _HostActionsBackend backend,
  ProviderContainer container,
) {
  expect(backend.sshHostIds, isEmpty);
  expect(backend.quickSshTargets, isEmpty);
  expect(container.read(sessionManagerProvider).tabs, isEmpty);
}

void _androidTest(String name, WidgetTesterCallback callback) => testWidgets(
  name,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

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

  _androidTest(
    'mobile edit preloads the selected host and saves real metadata',
    (tester) async {
      final backend = _HostActionsBackend();
      final original = backend.hosts.first;
      final untouched = backend.hosts.last;
      final container = await _mount(tester, backend);
      await _tap(tester, _key('mobileEditHost_h_prod'));
      expect(find.text('Chỉnh sửa Host'), findsOneWidget);
      for (final entry in {
        'Tên hiển thị (vd: prod-web-01) *': original.label,
        'Hostname / IP *': original.hostname,
        'Port': '${original.port}',
      }.entries) {
        expect(
          tester.widget<TextField>(_field(entry.key)).controller!.text,
          entry.value,
        );
      }
      _expectNoConnections(backend, container);
      await tester.enterText(
        _field('Tên hiển thị (vd: prod-web-01) *'),
        'prod-api-renamed',
      );
      await tester.enterText(_field('Hostname / IP *'), '10.0.1.99');
      await tester.enterText(_field('Port'), '2222');
      await _tap(tester, _saveHost);
      expect(find.text('Chỉnh sửa Host'), findsNothing);
      expect(backend.savedHosts, hasLength(1));
      final saved = backend.hosts.singleWhere((host) => host.id == original.id);
      expect(saved.label, 'prod-api-renamed');
      expect(saved.hostname, '10.0.1.99');
      expect(saved.port, 2222);
      expect(saved.protocol, original.protocol);
      expect(saved.tags, original.tags);
      expect(saved.notes, original.notes);
      expect(saved.isFavorite, original.isFavorite);
      expect(saved.identityMode, original.identityMode);
      expect(
        backend.hosts.singleWhere((host) => host.id == untouched.id),
        same(untouched),
      );
      expect(container.read(inventoryProvider).hosts, backend.hosts);
      expect(find.text('prod-api-renamed'), findsOneWidget);
      expect(find.text('10.0.1.99:2222 · SSH'), findsOneWidget);
      expect(find.text(original.label), findsNothing);
      _expectNoConnections(backend, container);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('cancelling mobile edit leaves stored host data unchanged', (
    tester,
  ) async {
    final backend = _HostActionsBackend();
    final originalHosts = List<HostDto>.of(backend.hosts);
    final container = await _mount(tester, backend);
    await _tap(tester, _key('mobileEditHost_h_dev'));
    await tester.enterText(_field('Hostname / IP *'), 'changed.invalid');
    await _tap(tester, _cancelHost);
    expect(backend.savedHosts, isEmpty);
    expect(backend.hosts, originalHosts);
    expect(container.read(inventoryProvider).hosts, originalHosts);
    expect(find.text('Chỉnh sửa Host'), findsNothing);
    _expectNoConnections(backend, container);
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'cancelling delete preserves both hosts without backend mutation',
    (tester) async {
      final backend = _HostActionsBackend();
      final originalHosts = List<HostDto>.of(backend.hosts);
      final container = await _mount(tester, backend);
      await _tap(tester, _key('mobileDeleteHost_h_prod'));
      expect(_key('mobileDeleteHostDialog'), findsOneWidget);
      expect(find.text('Xoá cấu hình đã lưu “prod-api-01”?'), findsOneWidget);
      expect(backend.deletedHostIds, isEmpty);
      await _tap(tester, _key('mobileDeleteHostCancel'));
      expect(_key('mobileDeleteHostDialog'), findsNothing);
      expect(backend.deletedHostIds, isEmpty);
      expect(backend.hosts, originalHosts);
      expect(container.read(inventoryProvider).hosts, originalHosts);
      _expectNoConnections(backend, container);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('confirming mobile delete removes only the chosen host', (
    tester,
  ) async {
    final backend = _HostActionsBackend();
    final untouched = backend.hosts.first;
    final container = await _mount(tester, backend);
    await _tap(tester, _key('mobileDeleteHost_h_dev'));
    expect(find.text('Xoá cấu hình đã lưu “dev-box”?'), findsOneWidget);
    expect(backend.deletedHostIds, isEmpty);
    await _tap(tester, _key('mobileDeleteHostConfirm'));
    expect(backend.deletedHostIds, ['h_dev']);
    expect(backend.hosts, [untouched]);
    expect(container.read(inventoryProvider).hosts, [untouched]);
    expect(_key('mobileHostCard_h_dev'), findsNothing);
    expect(_key('mobileHostCard_h_prod'), findsOneWidget);
    expect(find.text('Đã xoá kết nối “dev-box”.'), findsOneWidget);
    _expectNoConnections(backend, container);
    expect(tester.takeException(), isNull);
  });

  _androidTest('successful delete stays removed when inventory refresh fails', (
    tester,
  ) async {
    final backend = _HostActionsBackend();
    final untouched = backend.hosts.first;
    final container = await _mount(tester, backend);
    await _tap(tester, _key('mobileDeleteHost_h_dev'));
    backend.failListHosts = true;
    await _tap(tester, _key('mobileDeleteHostConfirm'));
    expect(backend.deletedHostIds, ['h_dev']);
    expect(backend.hosts, [untouched]);
    expect(container.read(inventoryProvider).hosts, [untouched]);
    expect(
      container.read(inventoryProvider).error,
      contains('Host list unavailable after delete'),
    );
    expect(_key('mobileHostCard_h_dev'), findsNothing);
    expect(_key('mobileHostCard_h_prod'), findsOneWidget);
    await _expectErrorDetails(tester, 'Host list unavailable after delete');
    expect(_key('mobileHostActionError'), findsNothing);
    _expectNoConnections(backend, container);
    expect(tester.takeException(), isNull);
  });

  _androidTest('delete failure keeps the host and allows an explicit retry', (
    tester,
  ) async {
    final backend = _HostActionsBackend()..failDelete = true;
    final originalHosts = List<HostDto>.of(backend.hosts);
    final container = await _mount(tester, backend);
    await _tap(tester, _key('mobileDeleteHost_h_prod'));
    await _tap(tester, _key('mobileDeleteHostConfirm'));
    expect(_key('mobileHostActionError'), findsOneWidget);
    expect(find.textContaining('Delete storage unavailable'), findsOneWidget);
    expect(backend.hosts, originalHosts);
    expect(container.read(inventoryProvider).hosts, originalHosts);
    expect(
      tester.widget<TextButton>(_key('mobileDeleteHost_h_prod')).onPressed,
      isNotNull,
    );
    backend.failDelete = false;
    await _tap(tester, _key('mobileDeleteHost_h_prod'));
    expect(_key('mobileHostActionError'), findsNothing);
    await _tap(tester, _key('mobileDeleteHostConfirm'));
    expect(backend.deletedHostIds, ['h_prod', 'h_prod']);
    expect(backend.hosts.map((host) => host.id), ['h_dev']);
    expect(_key('mobileHostActionError'), findsNothing);
    _expectNoConnections(backend, container);
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'pending delete disables host actions and prevents a connection',
    (tester) async {
      final pending = Completer<void>();
      final backend = _HostActionsBackend()..pendingDelete = pending;
      final container = await _mount(tester, backend);
      await _tap(tester, _key('mobileDeleteHost_h_prod'));
      await _tap(tester, _key('mobileDeleteHostConfirm'));
      expect(backend.deletedHostIds, ['h_prod']);
      for (final key in ['mobileEditHost_h_prod', 'mobileDeleteHost_h_prod']) {
        expect(tester.widget<TextButton>(_key(key)).onPressed, isNull);
      }
      await _tap(tester, find.text('prod-api-01'));
      expect(backend.deletedHostIds, ['h_prod']);
      _expectNoConnections(backend, container);
      pending.complete();
      await tester.pumpAndSettle();
      expect(backend.hosts.map((host) => host.id), ['h_dev']);
      _expectNoConnections(backend, container);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('failed edit save retains the form and succeeds on retry', (
    tester,
  ) async {
    final backend = _HostActionsBackend()..failSave = true;
    final original = backend.hosts.first;
    final container = await _mount(tester, backend);
    await _tap(tester, _key('mobileEditHost_h_prod'));
    await tester.enterText(_field('Hostname / IP *'), '10.0.1.88');
    await _tap(tester, _saveHost);
    expect(find.text('Chỉnh sửa Host'), findsOneWidget);
    await _expectErrorDetails(
      tester,
      'Save storage unavailable',
      notice: _key('hostEditorError'),
    );
    expect(backend.hosts.first, same(original));
    expect(tester.widget<FilledButton>(_saveHost).onPressed, isNotNull);
    backend.failSave = false;
    await _tap(tester, _saveHost);
    expect(find.text('Chỉnh sửa Host'), findsNothing);
    expect(backend.savedHosts, hasLength(2));
    expect(backend.hosts.first.hostname, '10.0.1.88');
    expect(container.read(inventoryProvider).hosts.first.hostname, '10.0.1.88');
    _expectNoConnections(backend, container);
    expect(tester.takeException(), isNull);
  });

  for (final preset in AppThemePreset.values) {
    _androidTest(
      'host home scrolls with keyboard and rotation in ${preset.name}',
      (tester) async {
        final backend = _HostActionsBackend();
        final container = await _mount(
          tester,
          backend,
          size: const Size(360, 640),
          preset: preset,
          textScale: 1.6,
        );
        const draft = 'ssh -p 2222 ops@server.example';
        final quick = _key('mobileQuickConnectField');
        await tester.enterText(quick, draft);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(740, 360);
        tester.view.viewInsets = const FakeViewPadding(bottom: 120);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.widget<TextField>(quick).controller!.text, draft);
        final homeScrollable = find
            .descendant(
              of: _key('mobileHostCardsView'),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          _key('mobileEditHost_h_dev'),
          180,
          scrollable: homeScrollable,
        );
        await tester.pumpAndSettle();
        expect(_key('mobileEditHost_h_dev').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = const FakeViewPadding();
        tester.view.physicalSize = const Size(360, 640);
        await tester.pumpAndSettle();
        await tester.drag(_key('mobileHostCardsView'), const Offset(0, 1000));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(quick).controller!.text, draft);
        final prodFilter = find
            .ancestor(
              of: find.text('PROD'),
              matching: find.byType(GestureDetector),
            )
            .first;
        expect(tester.getSize(prodFilter).height, greaterThanOrEqualTo(44));
        await tester.tap(prodFilter);
        await tester.pumpAndSettle();
        expect(_key('mobileHostCard_h_dev'), findsNothing);
        expect(_key('mobileHostCard_h_prod'), findsOneWidget);
        _expectNoConnections(backend, container);
        expect(tester.takeException(), isNull);
      },
    );

    _androidTest('host actions fit small phone large text in ${preset.name}', (
      tester,
    ) async {
      final backend = _HostActionsBackend();
      final container = await _mount(
        tester,
        backend,
        size: const Size(360, 640),
        preset: preset,
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, _key('mobileEditHost_h_prod'));
      expect(find.text('Chỉnh sửa Host'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, _cancelHost);
      await _tap(tester, _key('mobileDeleteHost_h_prod'));
      final dialog = _key('mobileDeleteHostDialog');
      final bounds = tester.getRect(dialog);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(360));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(640));
      expect(_key('mobileDeleteHostCancel').hitTestable(), findsOneWidget);
      expect(_key('mobileDeleteHostConfirm').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, _key('mobileDeleteHostCancel'));
      expect(backend.hosts, hasLength(2));
      expect(backend.deletedHostIds, isEmpty);
      _expectNoConnections(backend, container);
      expect(tester.takeException(), isNull);
    });
  }
}
