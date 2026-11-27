import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/mobile_shell.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

class _PanelBackend extends FakeCoreBackend {
  _PanelBackend() {
    snippets
      ..clear()
      ..addAll(
        List.generate(
          25,
          (index) => SnippetDto(
            id: 'snippet_$index',
            scope: 'global',
            title: 'Snippet ${index.toString().padLeft(2, '0')}',
            commandTpl: 'echo $index',
            pinButtonBar: false,
          ),
        ),
      );
    tunnels
      ..clear()
      ..addAll(
        List.generate(
          25,
          (index) => TunnelDto(
            id: 'tunnel_$index',
            name: 'Tunnel ${index.toString().padLeft(2, '0')}',
            hostId: hosts.first.id,
            kind: 'local',
            bindAddr: '127.0.0.1',
            bindPort: 6000 + index,
            targetHost: '127.0.0.1',
            targetPort: 22,
            autoStart: false,
          ),
        ),
      );
  }

  @override
  Future<SftpListingDto> sftpListDirectory(
    String sessionId,
    String path,
  ) async => SftpListingDto(
    cwd: '/var/log',
    entries: List.generate(
      25,
      (index) => SftpEntryDto(
        name: 'file_${index.toString().padLeft(2, '0')}.txt',
        path: '/var/log/file_${index.toString().padLeft(2, '0')}.txt',
        isDir: false,
        isSymlink: false,
        size: BigInt.from(256),
        permissions: 0x1a4,
        modified: BigInt.zero,
      ),
    ),
  );
}

class _MemorySettings extends SettingsController {
  _MemorySettings(this.preset);
  final AppThemePreset preset;

  @override
  AppSettingsState build() => AppSettingsState(themePreset: preset);
}

Finder _key(String value) => find.byKey(Key(value));

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _PanelBackend backend, {
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
  await container.read(vaultProvider.notifier).unlock('test-password');
  await container
      .read(sessionManagerProvider.notifier)
      .openHostSession(backend.hosts.first);
  await tester.pump();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
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
  await tester.tap(
    find.ancestor(of: find.text('1'), matching: find.byType(InkWell)).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(_key('mobileBottomSheetBtn'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _selectTab(WidgetTester tester, String tab) async {
  final target = _key('mobileSheetTab$tab');
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _scrollPanelUntilVisible(
  WidgetTester tester,
  Finder target, {
  required Finder scrollable,
}) async {
  for (var drag = 0; drag < 45; drag++) {
    final viewport = tester.getRect(_key('mobileSheetContentViewport'));
    if (target.hitTestable().evaluate().isNotEmpty) {
      final bounds = tester.getRect(target);
      if (bounds.top >= viewport.top - 1 &&
          bounds.bottom <= viewport.bottom + 1) {
        return;
      }
    }
    final visible = tester.getRect(scrollable).intersect(viewport);
    // On a short landscape screen the list starts beneath the panel's clip.
    // Reveal it by dragging visible controls, then drag its visible portion.
    final area = visible.height >= 24 ? visible : viewport;
    await tester.dragFrom(
      Offset(area.center.dx, area.bottom - 8),
      Offset(0, -(viewport.height * .7).clamp(80.0, 140.0)),
    );
    await tester.pumpAndSettle();
  }
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: 'The panel content must be reachable using visible drag gestures.',
  );
  final viewport = tester.getRect(_key('mobileSheetContentViewport'));
  final bounds = tester.getRect(target);
  expect(bounds.top, greaterThanOrEqualTo(viewport.top - 1));
  expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom + 1));
}

void _expectPanelAboveKeys(WidgetTester tester) {
  expect(_key('mobileBottomSheet'), findsOneWidget);
  final panel = tester.getRect(_key('mobileBottomSheet'));
  final keys = tester.getRect(_key('mobileAccessoryBar'));
  expect(panel.height, greaterThanOrEqualTo(44));
  expect(panel.bottom, closeTo(keys.top, .1));
  expect(panel.top, greaterThanOrEqualTo(0));
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

  _androidTest('mobile tools drag grows and shrinks without terminal input', (
    tester,
  ) async {
    final backend = _PanelBackend();
    final container = await _mount(tester, backend);
    final terminalState = tester.state(find.byType(TerminalPane));
    final sessionKey = container
        .read(sessionManagerProvider)
        .activeTab!
        .localKey;
    final original = tester.getSize(_key('mobileBottomSheet')).height;
    await tester.dragFrom(
      tester.getTopLeft(_key('mobileSheetResizeHandle')) + const Offset(28, 22),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    final larger = tester.getSize(_key('mobileBottomSheet')).height;
    expect(larger, greaterThan(original + 90));
    await tester.dragFrom(
      tester.getTopLeft(_key('mobileSheetResizeHandle')) + const Offset(28, 22),
      const Offset(0, 90),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(_key('mobileBottomSheet')).height,
      lessThan(larger - 60),
    );
    await tester.dragFrom(
      tester.getTopLeft(_key('mobileSheetResizeHandle')) + const Offset(28, 22),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(_key('mobileBottomSheet')).height, 44);
    await tester.tap(_key('mobileSheetCollapseBtn'));
    await tester.pumpAndSettle();
    expect(tester.getSize(_key('mobileBottomSheet')).height, greaterThan(200));
    expect(tester.state(find.byType(TerminalPane)), same(terminalState));
    expect(
      container.read(sessionManagerProvider).activeTab!.localKey,
      sessionKey,
    );
    expect(backend.sentInputs, isEmpty);
    _expectPanelAboveKeys(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _androidTest(
    'mobile tools collapse and restore retains tab and compose draft',
    (tester) async {
      final backend = _PanelBackend();
      await _mount(tester, backend);
      await _selectTab(tester, 'Snippets');
      await tester.enterText(_key('composePaneField'), 'echo unsent draft');
      await tester.pumpAndSettle();
      final composeFocus = tester
          .widget<EditableText>(
            find.descendant(
              of: _key('composePaneField'),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode;
      expect(composeFocus.hasFocus, isTrue);
      await tester.tap(_key('mobileSheetCollapseBtn'));
      await tester.pumpAndSettle();
      expect(tester.getSize(_key('mobileBottomSheet')).height, 44);
      expect(composeFocus.hasFocus, isFalse);
      expect(_key('composePaneField'), findsNothing);
      await tester.tap(_key('mobileSheetCollapseBtn'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(_key('mobileBottomSheet')).height,
        greaterThan(200),
      );
      expect(
        tester.widget<TextField>(_key('composePaneField')).controller!.text,
        'echo unsent draft',
      );
      await tester.tap(_key('mobileSheetExpandBtn'));
      await tester.pumpAndSettle();
      final maximized = tester.getSize(_key('mobileBottomSheet')).height;
      await tester.tap(_key('mobileSheetExpandBtn'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(_key('mobileBottomSheet')).height,
        lessThan(maximized),
      );
      await tester.tap(_key('mobileBottomSheetBtn'));
      await tester.pumpAndSettle();
      await tester.tap(_key('mobileBottomSheetBtn'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_key('composePaneField')).controller!.text,
        'echo unsent draft',
      );
      expect(backend.sentInputs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _androidTest(
    'mobile tools stays reachable with keyboard and short landscape',
    (tester) async {
      final backend = _PanelBackend();
      await _mount(tester, backend, size: const Size(412, 740));
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      await tester.pumpAndSettle();
      _expectPanelAboveKeys(tester);
      expect(_key('mobileSheetResizeHandle').hitTestable(), findsOneWidget);
      expect(_key('mobileSheetContentViewport'), findsOneWidget);
      tester.view.physicalSize = const Size(740, 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await tester.pumpAndSettle();
      _expectPanelAboveKeys(tester);
      await tester.tap(_key('mobileSheetExpandBtn'));
      await tester.pumpAndSettle();
      _expectPanelAboveKeys(tester);
      await tester.tap(_key('mobileSheetCollapseBtn'));
      await tester.pumpAndSettle();
      expect(tester.getSize(_key('mobileBottomSheet')).height, 44);
      await tester.tap(_key('mobileSheetCollapseBtn'));
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.physicalSize = const Size(412, 740);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(_key('mobileBottomSheet')).height,
        greaterThan(250),
      );
      expect(backend.sentInputs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _androidTest(
    'mobile tools resets tabs after layout and scrolls at real device landscape',
    (tester) async {
      final backend = _PanelBackend();
      await _mount(tester, backend, size: const Size(392.7, 872.7));
      await tester.tap(_key('mobileSheetExpandBtn'));
      await tester.pumpAndSettle();
      await _selectTab(tester, 'Snippets');
      await tester.enterText(_key('composePaneField'), 'echo landscape draft');
      FocusManager.instance.primaryFocus?.unfocus();
      tester.view.physicalSize = const Size(872.7, 392.7);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      await tester.pumpAndSettle();
      _expectPanelAboveKeys(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(_key('composePaneField')).controller!.text,
        'echo landscape draft',
      );

      for (var repeat = 0; repeat < 2; repeat++) {
        await _selectTab(tester, 'Files');
        expect(tester.takeException(), isNull);
        final lastFile = _key('sftpEntry:/var/log/file_24.txt');
        await _scrollPanelUntilVisible(
          tester,
          lastFile,
          scrollable: find
              .descendant(
                of: find.byType(SftpPanel),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        expect(lastFile.hitTestable(), findsOneWidget);
        final outer = tester.state<ScrollableState>(
          find
              .descendant(
                of: _key('mobileSheetContentScroll'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(outer.position.pixels, greaterThan(0));

        // Keep the header partly visible while its viewport is still scrolled.
        // Resetting synchronously during this tab build notifies AppBar early.
        outer.position.jumpTo(12);
        await tester.pumpAndSettle();
        expect(_key('mobileSheetTabSnippets').hitTestable(), findsOneWidget);
        await tester.tap(_key('mobileSheetTabSnippets'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _scrollPanelUntilVisible(
          tester,
          find.text('Snippet 24'),
          scrollable: find.descendant(
            of: _key('mobileSnippetList'),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.ensureVisible(_key('composeSendButton'));
        await tester.pumpAndSettle();
        expect(_key('composeSendButton').hitTestable(), findsOneWidget);
        await _selectTab(tester, 'Health');
        expect(tester.takeException(), isNull);
        await _scrollPanelUntilVisible(
          tester,
          find.text('Tunnel 24'),
          scrollable: find.descendant(
            of: _key('mobileHealthScroll'),
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text('Tunnel 24').hitTestable(), findsOneWidget);
        _expectPanelAboveKeys(tester);
        expect(tester.takeException(), isNull);
      }
      expect(backend.sentInputs, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final preset in [AppThemePreset.dark, AppThemePreset.light]) {
    _androidTest(
      'mobile tools scrolls all contents at 360px and 1.6x $preset',
      (tester) async {
        final backend = _PanelBackend();
        await _mount(
          tester,
          backend,
          size: const Size(360, 640),
          preset: preset,
          textScale: 1.6,
        );
        await tester.tap(_key('mobileSheetExpandBtn'));
        await tester.pumpAndSettle();
        final finalFile = _key('sftpEntry:/var/log/file_24.txt');
        await tester.scrollUntilVisible(
          finalFile,
          160,
          scrollable: find
              .descendant(
                of: find.byType(SftpPanel),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(finalFile.hitTestable(), findsOneWidget);
        _expectPanelAboveKeys(tester);

        await _selectTab(tester, 'Snippets');
        await tester.scrollUntilVisible(
          find.text('Snippet 24'),
          150,
          scrollable: find.descendant(
            of: _key('mobileSnippetList'),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Snippet 24').hitTestable(), findsOneWidget);
        await tester.ensureVisible(_key('composeSendButton'));
        await tester.pumpAndSettle();
        expect(_key('composeSendButton').hitTestable(), findsOneWidget);

        await _selectTab(tester, 'Health');
        await tester.ensureVisible(find.text('Tunnel 24'));
        await tester.pumpAndSettle();
        expect(find.text('Tunnel 24').hitTestable(), findsOneWidget);
        expect(
          tester.getRect(find.text('Tunnel 24')).bottom,
          lessThanOrEqualTo(tester.getRect(_key('mobileAccessoryBar')).top),
        );
        _expectPanelAboveKeys(tester);
        expect(backend.sentInputs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
