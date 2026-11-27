import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/desktop_shell.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _MemorySettings extends SettingsController {
  @override
  AppSettingsState build() => const AppSettingsState();
}

class _LayoutSessions extends SessionManagerController {
  _LayoutSessions(this.initial);

  final WorkspaceState initial;

  @override
  WorkspaceState build() => initial;

  WorkspaceState get snapshot => state;

  @override
  void setActiveTab(int index) {
    state = state.copyWith(activeIndex: index, showOverview: false);
  }

  void replaceTabs(List<TerminalSessionTab> tabs, {int activeIndex = 0}) {
    state = state.copyWith(tabs: tabs, activeIndex: activeIndex);
  }
}

class _UnusedRemoteBackend implements RemoteDesktopBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackedDesktopSession extends RemoteDesktopSession {
  _TrackedDesktopSession(String id)
    : super(
        host: HostDto(
          id: id,
          label: id,
          protocol: 'vnc',
          hostname: 'fixture.invalid',
          port: 5900,
          identityMode: 'inherit',
          jumpHostMode: 'none',
          proxyMode: 'none',
          envTag: 'dev',
          tags: const [],
          notes: '',
          env: const [],
          isFavorite: false,
        ),
        backend: _UnusedRemoteBackend(),
        onStatusChanged: () {},
      );

  final attachedListeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) {
    attachedListeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    attachedListeners.remove(listener);
    super.removeListener(listener);
  }

  void showColor(List<int> rgba, {int sequence = 1}) {
    frame = DesktopFrame(
      2,
      2,
      Uint8List.fromList([for (var i = 0; i < 4; i++) ...rgba]),
      sequence,
    );
    notifyListeners();
  }
}

TerminalSessionTab _tab(String id, {_TrackedDesktopSession? remoteDesktop}) =>
    TerminalSessionTab(
      localKey: id,
      sessionId: 'session_$id',
      title: id,
      envTag: 'dev',
      protocol: remoteDesktop == null ? 'ssh' : 'vnc',
      terminal: Terminal(maxLines: 1000)
        ..write(
          List.generate(180, (index) => '$id alpha line $index').join('\r\n'),
        ),
      controller: TerminalController(),
      followSftpEnabled: false,
      remoteDesktop: remoteDesktop,
    );

Future<_LayoutSessions> _mount(
  WidgetTester tester,
  List<TerminalSessionTab> tabs, {
  SplitMode splitMode = SplitMode.horizontal,
  bool overview = false,
}) async {
  tester.view.physicalSize = const Size(1800, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _LayoutSessions(
    WorkspaceState(
      tabs: tabs,
      splitMode: splitMode,
      showSftpPanel: false,
      showOverview: overview,
    ),
  );
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(FakeCoreBackend()..snippets.clear()),
      settingsProvider.overrideWith(_MemorySettings.new),
      sessionManagerProvider.overrideWith(() => sessions),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        builder: (_, child) =>
            AppLocalizationScope(language: AppLanguage.vi, child: child!),
        home: const DesktopShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sessions;
}

Finder _pane(String id) => find.byWidgetPredicate(
  (widget) => widget is TerminalPane && widget.key == ValueKey(id),
);

Finder _view(String id) =>
    find.descendant(of: _pane(id), matching: find.byType(TerminalView));

Finder _overviewFrame(String id) =>
    find.byKey(ValueKey('desktopOverviewFrame:$id'));

Finder _image(String id) =>
    find.descendant(of: _overviewFrame(id), matching: find.byType(RawImage));

Future<void> _awaitImage(WidgetTester tester, String id) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (tester.widget<RawImage>(_image(id)).image != null) return;
  }
  fail('Overview frame $id did not decode.');
}

Future<List<int>> _pixel(WidgetTester tester, String id) async {
  final image = tester.widget<RawImage>(_image(id)).image!;
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return bytes!.buffer.asUint8List().take(4).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.termpulse.termpulse/foreground');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final splitMode in [
    SplitMode.horizontal,
    SplitMode.vertical,
    SplitMode.quad,
  ]) {
    testWidgets('$splitMode focus preserves pane positions and local state', (
      tester,
    ) async {
      final ids = splitMode == SplitMode.quad
          ? ['pane_a', 'pane_b', 'pane_c', 'pane_d']
          : ['pane_a', 'pane_b'];
      final sessions = await _mount(
        tester,
        ids.map(_tab).toList(),
        splitMode: splitMode,
      );
      final states = {for (final id in ids) id: tester.state(_pane(id))};
      final positions = {
        for (final id in ids) id: tester.getTopLeft(_pane(id)),
      };
      final views = {
        for (final id in ids) id: tester.widget<TerminalView>(_view(id)),
      };
      await tester.tap(
        find.descendant(
          of: _pane(ids.first),
          matching: find.byKey(const Key('terminalFindBtn')),
        ),
      );
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: _pane(ids.first),
        matching: find.byKey(const Key('terminalSearchField')),
      );
      await tester.enterText(search, 'alpha');
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<TerminalView>(_view(ids.first))
          .scrollController!;
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await tester.pump();
      final offset = scroll.offset;

      for (var index = ids.length - 1; index >= 0; index--) {
        await tester.tap(_view(ids[index]));
        await tester.pumpAndSettle();
        expect(sessions.snapshot.activeTab!.localKey, ids[index]);
        expect(
          tester.widget<TerminalView>(_view(ids[index])).focusNode!.hasFocus,
          isTrue,
        );
        for (final id in ids) {
          expect(tester.state(_pane(id)), same(states[id]));
          expect(tester.getTopLeft(_pane(id)), positions[id]);
          expect(
            tester.widget<TerminalView>(_view(id)).focusNode,
            same(views[id]!.focusNode),
          );
          expect(
            tester.widget<TerminalView>(_view(id)).controller,
            same(views[id]!.controller),
          );
        }
        expect(tester.widget<TextField>(search).controller!.text, 'alpha');
        expect(scroll.offset, closeTo(offset, 0.1));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('selecting a hidden session retains other visible split slots', (
    tester,
  ) async {
    final sessions = await _mount(tester, [
      _tab('pane_a'),
      _tab('pane_b'),
      _tab('pane_c'),
    ]);
    final firstState = tester.state(_pane('pane_a'));
    final firstPosition = tester.getTopLeft(_pane('pane_a'));
    sessions.setActiveTab(2);
    await tester.pumpAndSettle();
    expect(_pane('pane_b'), findsNothing);
    expect(_pane('pane_c'), findsOneWidget);
    final thirdState = tester.state(_pane('pane_c'));
    final thirdPosition = tester.getTopLeft(_pane('pane_c'));
    await tester.tap(_view('pane_a'));
    await tester.pumpAndSettle();
    expect(sessions.snapshot.activeTab!.localKey, 'pane_a');
    expect(_pane('pane_b'), findsNothing);
    expect(tester.state(_pane('pane_a')), same(firstState));
    expect(tester.state(_pane('pane_c')), same(thirdState));
    expect(tester.getTopLeft(_pane('pane_a')), firstPosition);
    expect(tester.getTopLeft(_pane('pane_c')), thirdPosition);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('overview removal keeps remaining session image and listener', (
    tester,
  ) async {
    final first = _TrackedDesktopSession('remote_a')
      ..showColor([255, 0, 0, 255]);
    final second = _TrackedDesktopSession('remote_b')
      ..showColor([0, 0, 255, 255]);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final remainingTab = _tab('remote_b', remoteDesktop: second);
    final sessions = await _mount(tester, [
      _tab('remote_a', remoteDesktop: first),
      remainingTab,
    ], overview: true);
    await _awaitImage(tester, 'remote_a');
    await _awaitImage(tester, 'remote_b');
    final secondState = tester.state(_overviewFrame('remote_b'));
    expect(await _pixel(tester, 'remote_a'), [255, 0, 0, 255]);
    expect(await _pixel(tester, 'remote_b'), [0, 0, 255, 255]);
    expect(first.attachedListeners, hasLength(1));
    expect(second.attachedListeners, hasLength(1));

    sessions.replaceTabs([remainingTab]);
    await tester.pumpAndSettle();
    expect(first.attachedListeners, isEmpty);
    expect(second.attachedListeners, hasLength(1));
    expect(tester.state(_overviewFrame('remote_b')), same(secondState));
    expect(await _pixel(tester, 'remote_b'), [0, 0, 255, 255]);
    second.showColor([0, 255, 0, 255], sequence: 2);
    await tester.pump(const Duration(milliseconds: 450));
    await _awaitImage(tester, 'remote_b');
    expect(await _pixel(tester, 'remote_b'), [0, 255, 0, 255]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(second.attachedListeners, isEmpty);
  });

  testWidgets(
    'overview replacement swaps session listener and frame sequence',
    (tester) async {
      final first = _TrackedDesktopSession('old_session')
        ..showColor([255, 0, 0, 255]);
      final replacement = _TrackedDesktopSession('new_session')
        ..showColor([0, 255, 0, 255]);
      addTearDown(first.dispose);
      addTearDown(replacement.dispose);
      final sessions = await _mount(tester, [
        _tab('same_tab', remoteDesktop: first),
      ], overview: true);
      await _awaitImage(tester, 'same_tab');
      final state = tester.state(_overviewFrame('same_tab'));
      first.showColor([0, 0, 255, 255], sequence: 2);
      sessions.replaceTabs([_tab('same_tab', remoteDesktop: replacement)]);
      await tester.pump();
      await _awaitImage(tester, 'same_tab');
      expect(tester.state(_overviewFrame('same_tab')), same(state));
      expect(first.attachedListeners, isEmpty);
      expect(replacement.attachedListeners, hasLength(1));
      expect(await _pixel(tester, 'same_tab'), [0, 255, 0, 255]);
      first.showColor([0, 0, 255, 255], sequence: 3);
      replacement.showColor([255, 255, 0, 255], sequence: 2);
      await tester.pump(const Duration(milliseconds: 450));
      await _awaitImage(tester, 'same_tab');
      expect(await _pixel(tester, 'same_tab'), [255, 255, 0, 255]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(replacement.attachedListeners, isEmpty);
    },
  );
}
