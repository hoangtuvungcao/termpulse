import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

Future<void> _boot(
  WidgetTester tester,
  FakeCoreBackend backend,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await container.read(vaultProvider.notifier).unlock('test');
  await container
      .read(sessionManagerProvider.notifier)
      .openHostSession(backend.hosts.first);
  await tester.pump();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const TermPulseApp(),
    ),
  );
  await tester.pumpAndSettle();
  if (size.width < 900) {
    await tester.tap(find.text('prod-api-01').first);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byType(TerminalView).first);
  await tester.pump();
}

void main() {
  for (final size in [const Size(1280, 820), const Size(412, 915)]) {
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      final layout = size.width >= 900 ? 'desktop' : 'mobile';
      final shortcut = modifier == LogicalKeyboardKey.controlLeft
          ? 'Ctrl+K'
          : 'Meta+K';
      testWidgets('$layout focused terminal opens $shortcut once', (
        tester,
      ) async {
        final backend = FakeCoreBackend();
        await _boot(tester, backend, size);
        backend.sentInputs.clear();

        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('commandPaletteSearch')), findsOneWidget);
        expect(backend.sentInputs, isEmpty);
        Navigator.of(
          tester.element(find.byKey(const Key('commandPaletteSearch'))),
        ).pop();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('commandPaletteSearch')), findsNothing);

        // Closing one palette must leave no duplicate dialog behind.
        await tester.tap(find.byType(TerminalView).first);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(backend.sentInputs.join(), '\x03');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
