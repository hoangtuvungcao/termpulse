import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/terminal/command_palette.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _FailingSessionManager extends SessionManagerController {
  int attempts = 0;

  @override
  WorkspaceState build() => const WorkspaceState();

  @override
  Future<void> openLocalShell({
    String? startupDir,
    String title = 'Local Shell',
    String envTag = 'dev',
    String? hostId,
  }) async {
    attempts++;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    throw StateError('Local shell bridge failed internally');
  }
}

void main() {
  testWidgets('palette errors retain working Details after palette closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = _FailingSessionManager();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWithValue(FakeCoreBackend()),
        sessionManagerProvider.overrideWith(() => manager),
      ],
    );
    addTearDown(container.dispose);
    await container.read(inventoryProvider.notifier).refreshAll();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTermPulseDarkTheme(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showCommandPaletteDialog(context, ref),
                child: const Text('Open palette'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open palette'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mở Local Shell mới'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(manager.attempts, 1);
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.textContaining('Local shell bridge failed internally'),
      findsNothing,
    );
    expect(find.text('Xem chi tiết'), findsOneWidget);
    await tester.tap(find.text('Xem chi tiết'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('noticeDetailsDialog')), findsOneWidget);
    expect(
      find.text('Bad state: Local shell bridge failed internally'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
