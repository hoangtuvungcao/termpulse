import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/desktop_shell.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _MemorySettings extends SettingsController {
  @override
  AppSettingsState build() => const AppSettingsState();
}

Future<void> _mount(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = FakeCoreBackend();
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(_MemorySettings.new),
    ],
  );
  addTearDown(container.dispose);
  await container.read(vaultProvider.notifier).unlock('fixture-only');
  await container
      .read(sessionManagerProvider.notifier)
      .openHostSession(backend.hosts.first);
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
  // Let the fixture's initial CWD/SFTP debounce finish before short drag cases.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
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

  for (final handle in ['sidebarResizeHandle', 'sftpResizeHandle']) {
    testWidgets('$handle follows drag without delayed width animation', (
      tester,
    ) async {
      await _mount(tester, const Size(1280, 820));
      final sidebar = handle == 'sidebarResizeHandle';
      final panel = find.byKey(
        Key(sidebar ? 'desktopSidebarPanel' : 'desktopSftpPanel'),
      );
      final initialWidth = tester.getSize(panel).width;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(Key(handle))),
      );
      await gesture.moveBy(Offset(sidebar ? 30 : -30, 0));
      await tester.pump();
      await gesture.moveBy(Offset(sidebar ? 35 : -35, 0));
      await tester.pump();
      expect(tester.widget<AnimatedContainer>(panel).duration, Duration.zero);
      expect(tester.getSize(panel).width, greaterThan(initialWidth));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedContainer>(panel).duration,
        greaterThan(Duration.zero),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow desktop keeps usable terminal beside resized panels', (
    tester,
  ) async {
    await _mount(tester, const Size(900, 820));
    await tester.drag(
      find.byKey(const Key('sidebarResizeHandle')),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('sftpResizeHandle')),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('desktopTerminalWorkspace'))).width,
      greaterThanOrEqualTo(360),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SFTP accessibility increase enlarges the panel', (tester) async {
    await _mount(tester, const Size(1280, 820));
    final panel = find.byKey(const Key('desktopSftpPanel'));
    final initialWidth = tester.getSize(panel).width;
    Semantics panelSemantics() => tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(const Key('sftpResizeHandle')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    panelSemantics().properties.onIncrease!();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, greaterThan(initialWidth));
    panelSemantics().properties.onDecrease!();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(initialWidth, 0.1));
  });
}
