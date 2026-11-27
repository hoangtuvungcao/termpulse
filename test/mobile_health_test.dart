import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _HealthBackend extends FakeCoreBackend {
  _HealthBackend({this.closed = false, this.connecting = false});

  final bool closed;
  final bool connecting;
  final metricsCalls = <String>[];

  @override
  Stream<TerminalEventDto> connectSshHost(
    String hostId,
    int cols,
    int rows,
  ) async* {
    if (!connecting) {
      yield TerminalEventDto(kind: 'session_opened', text: 'sess_$hostId');
    }
    if (closed) {
      yield const TerminalEventDto(kind: 'closed');
    } else {
      yield* StreamController<TerminalEventDto>().stream;
    }
  }

  @override
  Future<HostMetricsDto> pollSessionMetrics(String sessionId) {
    metricsCalls.add(sessionId);
    return super.pollSessionMetrics(sessionId);
  }
}

Future<ProviderContainer> _showMobileHealth(
  WidgetTester tester,
  _HealthBackend backend, {
  String protocol = 'ssh',
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await container.read(vaultProvider.notifier).unlock('test');
  final manager = container.read(sessionManagerProvider.notifier);
  switch (protocol) {
    case 'local_shell':
      await manager.openLocalShell();
    case 'telnet':
      await manager.openTelnet('localhost', 23);
    default:
      await manager.openHostSession(backend.hosts.first);
  }
  await tester.pump();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const TermPulseApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(of: find.text('1'), matching: find.byType(InkWell)).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('mobileBottomSheetBtn')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Health & Tunnels'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  for (final protocol in ['local_shell', 'telnet']) {
    testWidgets('mobile health explains unavailable $protocol metrics', (
      tester,
    ) async {
      final backend = _HealthBackend();
      await _showMobileHealth(tester, backend, protocol: protocol);
      final button = find.byKey(const Key('mobileMeasureHealthBtn'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.byKey(const Key('mobileHealthUnavailable')), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(backend.metricsCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('mobile health disables measurement for closed SSH', (
    tester,
  ) async {
    final backend = _HealthBackend(closed: true);
    final container = await _showMobileHealth(tester, backend);
    expect(container.read(sessionManagerProvider).activeTab!.closed, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('mobileMeasureHealthBtn')))
          .onPressed,
      isNull,
    );
    final reason = tester.widget<Text>(
      find.byKey(const Key('mobileHealthUnavailable')),
    );
    expect(reason.data, contains('đã đóng'));
    expect(backend.metricsCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile health waits until SSH connection is ready', (
    tester,
  ) async {
    final backend = _HealthBackend(connecting: true);
    final container = await _showMobileHealth(tester, backend);
    expect(container.read(sessionManagerProvider).activeTab!.sessionId, isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('mobileMeasureHealthBtn')))
          .onPressed,
      isNull,
    );
    final reason = tester.widget<Text>(
      find.byKey(const Key('mobileHealthUnavailable')),
    );
    expect(reason.data, contains('chờ kết nối'));
    expect(backend.metricsCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile health measures a connected SSH session', (tester) async {
    final backend = _HealthBackend();
    final container = await _showMobileHealth(tester, backend);
    final button = find.byKey(const Key('mobileMeasureHealthBtn'));
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(find.byKey(const Key('mobileHealthUnavailable')), findsNothing);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(backend.metricsCalls, ['sess_h_prod']);
    expect(
      container.read(sessionManagerProvider).activeTab!.metrics!.cpuPercent,
      24.5,
    );
    expect(find.text('24.5%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
