import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/terminal/serial_connect_dialog.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _SerialBackend extends FakeCoreBackend {
  bool supported = true;
  Object? supportError;
  Object? enumerationError;
  List<SerialPortInfoDto> ports = [];
  final configs = <SerialConfigDto>[];
  final serialHostIds = <String?>[];
  final connections = <StreamController<TerminalEventDto>>[];
  int sshConnections = 0;

  @override
  bool serialSupported() {
    if (supportError case final error?) throw error;
    return supported;
  }

  @override
  Future<List<SerialPortInfoDto>> listSerialPorts() async {
    if (enumerationError case final error?) throw error;
    return ports;
  }

  @override
  Stream<TerminalEventDto> connectSerial({
    required SerialConfigDto config,
    String? label,
    String? hostId,
  }) {
    configs.add(config);
    serialHostIds.add(hostId);
    final events = StreamController<TerminalEventDto>();
    connections.add(events);
    scheduleMicrotask(() {
      events.add(
        TerminalEventDto(
          kind: 'session_opened',
          text: 'serial_test_${connections.length}',
        ),
      );
    });
    return events.stream;
  }

  @override
  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows) {
    sshConnections++;
    return super.connectSshHost(hostId, cols, rows);
  }

  @override
  Future<void> upsertHost(HostDto host) async {
    hosts.removeWhere((existing) => existing.id == host.id);
    hosts.add(host);
  }
}

Future<ProviderContainer> _boot(
  WidgetTester tester,
  _SerialBackend backend, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await container.read(vaultProvider.notifier).unlock('test');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const TermPulseApp(),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _choose(WidgetTester tester, Key key, String label) async {
  final field = find.byKey(key);
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

const _saved = HostDto(
  id: 'serial_saved',
  label: 'Router console',
  protocol: 'serial',
  hostname: '/dev/serial-test',
  port: 0,
  identityMode: 'inherit',
  jumpHostMode: 'none',
  proxyMode: 'none',
  envTag: 'prod',
  tags: [],
  notes: '',
  env: [],
  serialBaudrate: 57600,
  serialDataBits: 7,
  serialParity: 'even',
  serialStopBits: 2,
  serialFlowControl: 'hardware',
  isFavorite: false,
);

void main() {
  for (final capabilityFailure in [false, true]) {
    testWidgets(
      'Serial ${capabilityFailure ? 'capability' : 'enumeration'} errors keep diagnostics in Details',
      (tester) async {
        const diagnostic = 'Serial bridge failed internally';
        final backend = _SerialBackend();
        if (capabilityFailure) {
          backend.supportError = StateError(diagnostic);
        } else {
          backend.enumerationError = StateError(diagnostic);
        }
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [backendProvider.overrideWithValue(backend)],
            child: MaterialApp(
              theme: buildTermPulseDarkTheme(),
              home: const Scaffold(body: SerialConnectDialog()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('serialPortsError')), findsOneWidget);
        expect(find.textContaining(diagnostic), findsNothing);
        final details = find.byKey(const Key('noticeDetailsButton'));
        await tester.ensureVisible(details);
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(find.text('Bad state: $diagnostic'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('noticeDetailsDialog')),
            matching: find.widgetWithText(TextButton, 'Đóng'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(diagnostic), findsNothing);
        if (capabilityFailure) {
          expect(
            find.byKey(const Key('serialUnsupportedMessage')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('serialConnectButton')), findsNothing);
        } else {
          backend.enumerationError = null;
          final refresh = find.byKey(const Key('serialRefreshPortsButton'));
          await tester.ensureVisible(refresh);
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('serialPortsError')), findsNothing);
        }
        expect(backend.configs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('desktop Serial dialog sends all selected framing options', (
    tester,
  ) async {
    final backend = _SerialBackend()
      ..ports = [
        const SerialPortInfoDto(
          portName: '/dev/serial-test',
          portType: 'usb',
          product: 'Test fixture',
        ),
      ];
    final container = await _boot(tester, backend);
    await tester.tap(find.byKey(const Key('desktopSerialConnectBtn')));
    await tester.pumpAndSettle();
    await _choose(
      tester,
      const Key('serialDetectedPortField'),
      '/dev/serial-test · Test fixture',
    );
    await tester.enterText(find.byKey(const Key('serialBaudField')), '57600');
    await _choose(tester, const Key('serialDataBitsField'), '7');
    await _choose(tester, const Key('serialParityField'), 'Even');
    await _choose(tester, const Key('serialStopBitsField'), '2');
    await _choose(tester, const Key('serialFlowControlField'), 'RTS/CTS');
    await tester.tap(find.byKey(const Key('serialConnectButton')));
    await tester.pumpAndSettle();
    expect(backend.configs, hasLength(1));
    final config = backend.configs.single;
    expect(config.portName, '/dev/serial-test');
    expect(config.baudRate, 57600);
    expect(config.dataBits, 7);
    expect(config.parity, 'even');
    expect(config.stopBits, 2);
    expect(config.flowControl, 'hardware');
    final tab = container.read(sessionManagerProvider).activeTab!;
    expect(tab.protocol, 'serial');
    expect(tab.sessionId, 'serial_test_1');
    expect(tab.followSftpEnabled, isFalse);
    expect(tab.sftpUnavailableReason, contains('không hỗ trợ SFTP'));
    tab.terminal.textInput('status\r');
    await tester.pump();
    expect(backend.sentInputs, ['status\r']);
    expect(backend.sshConnections, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Serial dialog permits manual path and rejects invalid baud', (
    tester,
  ) async {
    final backend = _SerialBackend();
    await _boot(tester, backend);
    await tester.tap(find.byKey(const Key('desktopSerialConnectBtn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('serialNoPortsMessage')), findsOneWidget);
    expect(find.byKey(const Key('serialDetectedPortField')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('serialPortField')),
      '/dev/manual-serial',
    );
    await tester.enterText(find.byKey(const Key('serialBaudField')), '0');
    await tester.tap(find.byKey(const Key('serialConnectButton')));
    await tester.pumpAndSettle();
    expect(find.text('Baud rate phải từ 1 đến 4000000.'), findsOneWidget);
    expect(backend.configs, isEmpty);
    await tester.enterText(find.byKey(const Key('serialBaudField')), '115200');
    await tester.tap(find.byKey(const Key('serialConnectButton')));
    await tester.pumpAndSettle();
    expect(backend.configs.single.portName, '/dev/manual-serial');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile Serial menu opens terminal only after a connection', (
    tester,
  ) async {
    final backend = _SerialBackend();
    final container = await _boot(tester, backend, size: const Size(412, 915));
    await tester.tap(find.byKey(const Key('mobileMoreMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobileSerialConnectItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('serialConnectDialog')), findsOneWidget);
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobileHostCardsView')), findsOneWidget);
    expect(backend.configs, isEmpty);

    await tester.tap(find.byKey(const Key('mobileMoreMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobileSerialConnectItem')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('serialPortField')),
      '/dev/mobile-serial',
    );
    await tester.tap(find.byKey(const Key('serialConnectButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('serialConnectDialog')), findsNothing);
    expect(find.byKey(const Key('mobileHostCardsView')), findsNothing);
    expect(find.byKey(const Key('mobileAccessoryBar')), findsOneWidget);
    expect(backend.configs.single.portName, '/dev/mobile-serial');
    expect(
      container.read(sessionManagerProvider).activeTab!.protocol,
      'serial',
    );
    expect(backend.sshConnections, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unsupported mobile Serial menu explains USB limitation', (
    tester,
  ) async {
    final backend = _SerialBackend()..supported = false;
    final container = await _boot(tester, backend, size: const Size(412, 915));
    await tester.tap(find.byKey(const Key('mobileMoreMenu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byKey(const Key('mobileSerialConnectItem')),
          )
          .enabled,
      isFalse,
    );
    expect(
      find.text('USB Serial không khả dụng trên thiết bị này.'),
      findsOneWidget,
    );
    await container
        .read(sessionManagerProvider.notifier)
        .openHostSession(_saved);
    expect(container.read(sessionManagerProvider).tabs, isEmpty);
    expect(
      container.read(sessionManagerProvider).lastError,
      contains('không khả dụng'),
    );
    expect(backend.configs, isEmpty);
    expect(backend.sshConnections, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Host editor persists Serial options and cloning preserves them',
    (tester) async {
      final backend = _SerialBackend()
        ..ports = [
          const SerialPortInfoDto(
            portName: '/dev/serial-test',
            portType: 'usb',
            product: 'USB UART',
          ),
        ];
      final container = await _boot(tester, backend);
      await tester.tap(find.byKey(const Key('desktopAddHostBtn')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên hiển thị (vd: prod-web-01) *'),
        'New Serial console',
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Giao thức'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Serial').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hostSerialScanButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/dev/serial-test'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, '/dev/serial-test'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('hostSerialBaudField')),
        '57600',
      );
      await _choose(tester, const Key('hostSerialDataBitsField'), '7');
      await _choose(tester, const Key('hostSerialParityField'), 'Even');
      await _choose(tester, const Key('hostSerialStopBitsField'), '2');
      await _choose(tester, const Key('hostSerialFlowControlField'), 'RTS/CTS');
      await tester.tap(find.widgetWithText(FilledButton, 'Lưu Host'));
      await tester.pumpAndSettle();
      final saved = backend.hosts.firstWhere(
        (host) => host.label == 'New Serial console',
      );
      expect(saved.protocol, 'serial');
      expect(saved.hostname, '/dev/serial-test');
      expect(saved.port, 0);
      expect(saved.serialBaudrate, 57600);
      expect(saved.serialDataBits, 7);
      expect(saved.serialParity, 'even');
      expect(saved.serialStopBits, 2);
      expect(saved.serialFlowControl, 'hardware');
      expect(saved.jumpHostMode, 'none');
      expect(saved.jumpHostId, isNull);
      expect(saved.proxyMode, 'none');
      expect(saved.proxyId, isNull);
      await container.read(inventoryProvider.notifier).cloneHost(saved);
      final clone = backend.hosts.firstWhere(
        (host) => host.label == 'New Serial console (Copy)',
      );
      expect(clone.serialBaudrate, saved.serialBaudrate);
      expect(clone.serialDataBits, saved.serialDataBits);
      expect(clone.serialParity, saved.serialParity);
      expect(clone.serialStopBits, saved.serialStopBits);
      expect(clone.serialFlowControl, saved.serialFlowControl);
      await container
          .read(sessionManagerProvider.notifier)
          .openHostSession(saved);
      await tester.pumpAndSettle();
      expect(backend.serialHostIds.single, saved.id);
      expect(backend.configs.single.dataBits, 7);
      expect(backend.sshConnections, 0);
      expect(
        container.read(sessionManagerProvider).activeTab!.protocol,
        'serial',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'saved Serial disconnect and reconnect reuse configuration and tab',
    () async {
      final backend = _SerialBackend();
      final container = ProviderContainer(
        overrides: [backendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      final manager = container.read(sessionManagerProvider.notifier);
      await manager.openHostSession(_saved);
      await Future<void>.delayed(Duration.zero);
      final before = container.read(sessionManagerProvider).activeTab!;
      backend.connections.single.add(
        const TerminalEventDto(kind: 'closed', text: 'Device unplugged'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(sessionManagerProvider).activeTab!.closed, isTrue);
      expect(await manager.reconnectTab(before.localKey), isTrue);
      await Future<void>.delayed(Duration.zero);
      final after = container.read(sessionManagerProvider).activeTab!;
      expect(after.closed, isFalse);
      expect(after.localKey, before.localKey);
      expect(after.terminal, same(before.terminal));
      expect(after.envTag, 'prod');
      expect(backend.configs, hasLength(2));
      expect(backend.configs[1], backend.configs[0]);
      expect(backend.serialHostIds, [_saved.id, _saved.id]);
      expect(backend.sshConnections, 0);
      await manager.closeTab(after.localKey);
    },
  );
}
