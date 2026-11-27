import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _FailingInputBackend extends FakeCoreBackend {
  @override
  Future<void> sendSessionInput(String sessionId, List<int> data) async {
    throw StateError('temporary write failure');
  }
}

class _DelayedCloseBackend extends FakeCoreBackend {
  final closeGate = Completer<void>();

  @override
  Future<void> closeSession(String sessionId) => closeGate.future;
}

Future<ProviderContainer> _boot(
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
  return container;
}

void main() {
  testWidgets(
    'composer waits calmly for guard confirmation and keeps cancel draft',
    (tester) async {
      final backend = FakeCoreBackend();
      await _boot(tester, backend, const Size(1280, 820));
      final field = find.byKey(const Key('composePaneField'));
      await tester.enterText(field, 'rm -rf /tmp/old_cache');
      await tester.tap(find.byKey(const Key('composeSendButton')));
      await tester.pumpAndSettle();
      expect(find.text('Cảnh báo lệnh nguy hiểm (PROD)'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(backend.sentInputs, isEmpty);
      await tester.tap(find.text('Huỷ bỏ'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'rm -rf /tmp/old_cache',
      );
      expect(backend.sentInputs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('composer keeps draft and displays failed transport reason', (
    tester,
  ) async {
    await _boot(tester, _FailingInputBackend(), const Size(1280, 820));
    final field = find.byKey(const Key('composePaneField'));
    await tester.enterText(field, 'echo ready');
    await tester.tap(find.byKey(const Key('composeSendButton')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'echo ready');
    expect(find.textContaining('temporary write failure'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('composer clears draft after successful transport', (
    tester,
  ) async {
    final backend = FakeCoreBackend();
    await _boot(tester, backend, const Size(1280, 820));
    final field = find.byKey(const Key('composePaneField'));
    await tester.enterText(field, 'echo ready');
    await tester.tap(find.byKey(const Key('composeSendButton')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(backend.sentInputs, contains('echo ready\n'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile close callback tolerates widget disposal during close', (
    tester,
  ) async {
    final backend = _DelayedCloseBackend();
    await _boot(tester, backend, const Size(412, 740));
    await tester.tap(find.text('prod-api-01').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    backend.closeGate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
