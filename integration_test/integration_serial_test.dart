// Exercises the native Serial bridge with Linux OS PTYs. This is deliberately
// not a claim that a physical USB adapter or Android USB driver was tested.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:xterm/xterm.dart';

class _LinuxPtyPair {
  _LinuxPtyPair(this.directory);
  final Directory directory;
  Process? _process;
  RandomAccessFile? _reader;
  RandomAccessFile? _writer;
  StreamSubscription<String>? _errors;
  final _diagnostic = StringBuffer();
  String get appPort => '${directory.path}/app-port';
  String get devicePort => '${directory.path}/device-port';

  Future<void> start() async {
    for (final path in [appPort, devicePort]) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(path).delete();
      }
    }
    _process = await Process.start('socat', [
      '-d',
      '-d',
      'PTY,raw,echo=0,link=$appPort',
      'PTY,raw,echo=0,link=$devicePort',
    ]);
    unawaited(_process!.stdout.drain<void>());
    _errors = _process!.stderr
        .transform(utf8.decoder)
        .listen(_diagnostic.write);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await File(appPort).exists() && await File(devicePort).exists()) {
        _reader = await File(devicePort).open();
        // Append seeks to EOF, which OS PTYs reject with ESPIPE. A character
        // device needs a plain write descriptor without a seek operation.
        _writer = await File(devicePort).open(mode: FileMode.writeOnly);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    throw StateError('Controlled socat PTY pair did not open: $_diagnostic');
  }

  Future<void> send(String text) async {
    await _writer!.writeFrom(utf8.encode(text));
  }

  Future<String> readBytes(int length) async {
    final bytes = <int>[];
    while (bytes.length < length) {
      final chunk = await _reader!.read(length - bytes.length);
      if (chunk.isEmpty) throw StateError('Controlled PTY closed during read');
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<void> stop() async {
    await _writer?.close();
    await _reader?.close();
    _writer = null;
    _reader = null;
    final process = _process;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      _process = null;
    }
    await _errors?.cancel();
    _errors = null;
  }
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 70));
    if (predicate()) return;
  }
  fail(reason);
}

Future<void> _keyboard(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TerminalView).first);
  await tester.pump();
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final prefix = tester.testTextInput.editingState?['text'] as String? ?? '';
  final value = '$prefix$text';
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ),
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets(
    'native connection setup errors reach streams and leave a retryable tab',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      final directory = await Directory.systemTemp.createTemp(
        'termpulse_session_errors_',
      );
      final container = ProviderContainer();
      final backend = container.read(backendProvider);
      var vaultInitialized = false;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final tab
            in container.read(sessionManagerProvider).tabs.toList()) {
          await container
              .read(sessionManagerProvider.notifier)
              .closeTab(tab.localKey);
        }
        if (vaultInitialized) await backend.vaultLock();
        container.dispose();
        tester.view.reset();
        await directory.delete(recursive: true);
      });
      await container
          .read(vaultProvider.notifier)
          .initAtPath('${directory.path}/vault.db');
      expect(container.read(vaultProvider).error, isNull);
      vaultInitialized = true;
      expect(
        await container
            .read(vaultProvider.notifier)
            .unlock('Session-error-QA!'),
        isTrue,
      );

      Future<void> expectSetupError(
        Stream<TerminalEventDto> events,
        String diagnostic,
      ) => expectLater(
        events.timeout(const Duration(seconds: 10)),
        emitsInOrder([
          emitsError(
            predicate<Object>(
              (error) => error.toString().contains(diagnostic),
              'native setup error containing "$diagnostic"',
            ),
          ),
          emitsDone,
        ]),
      );

      final missingSerial = SerialConfigDto(
        portName: '${directory.path}/missing-serial-port',
        baudRate: 9600,
        dataBits: 8,
        parity: 'none',
        stopBits: 1,
        flowControl: 'none',
      );
      await expectSetupError(
        backend.connectSerial(config: missingSerial),
        'Không mở được cổng Serial',
      );
      await expectSetupError(
        backend.connectSshHost('missing-saved-host', 80, 24),
        'Không tìm thấy Host',
      );
      await expectSetupError(
        backend.connectQuickSsh(target: 'user@[invalid', cols: 80, rows: 24),
        'Địa chỉ SSH không hợp lệ',
      );
      await expectSetupError(
        backend.connectLocalShell(
          cols: 80,
          rows: 24,
          startupDir: '${directory.path}/missing-startup-directory',
        ),
        'Thư mục khởi động',
      );
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = unused.port;
      await unused.close();
      await expectSetupError(
        backend.connectTelnetHost(hostname: '127.0.0.1', port: closedPort),
        'Kết nối thất bại: Telnet',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TermPulseApp(),
        ),
      );
      await tester.pumpAndSettle();
      final manager = container.read(sessionManagerProvider.notifier);
      await manager.openSerial(missingSerial);
      await _waitUntil(
        tester,
        () => container.read(sessionManagerProvider).activeTab?.closed == true,
        'A native startup failure did not close its pending terminal tab',
      );
      final tab = container.read(sessionManagerProvider).activeTab!;
      expect(tab.sessionId, isNull);
      expect(tab.closeReason, contains('Không mở được cổng Serial'));
      expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'real Linux Serial PTY keyboard output unplug reconnect and validation',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      tester.testTextInput.register();
      final directory = await Directory.systemTemp.createTemp(
        'termpulse_serial_pty_',
      );
      final pair = _LinuxPtyPair(directory);
      final container = ProviderContainer();
      final backend = container.read(backendProvider);
      var vaultInitialized = false;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final tab
            in container.read(sessionManagerProvider).tabs.toList()) {
          await container
              .read(sessionManagerProvider.notifier)
              .closeTab(tab.localKey);
        }
        await pair.stop();
        container.dispose();
        if (vaultInitialized) await backend.vaultLock();
        tester.testTextInput.unregister();
        tester.view.reset();
        await directory.delete(recursive: true);
      });
      expect(backend.serialSupported(), isTrue);
      // Enumeration reads the machine's actual OS device list, never fake ports.
      final detected = await backend.listSerialPorts();
      expect(
        detected.map((port) => port.portName).toSet().length,
        detected.length,
      );
      await pair.start();
      await expectLater(
        backend.connectSerial(
          config: SerialConfigDto(
            portName: pair.appPort,
            baudRate: 9600,
            dataBits: 9,
            parity: 'none',
            stopBits: 1,
            flowControl: 'none',
          ),
        ),
        emitsError(
          predicate((Object error) => error.toString().contains('data bits')),
        ),
      );
      await container
          .read(vaultProvider.notifier)
          .initAtPath('${directory.path}/vault.db');
      expect(container.read(vaultProvider).error, isNull);
      vaultInitialized = true;
      expect(
        await container
            .read(vaultProvider.notifier)
            .unlock('Serial-PTY-QA-2026!'),
        isTrue,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TermPulseApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktopSerialConnectBtn')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('serialPortField')),
        pair.appPort,
      );
      await tester.enterText(find.byKey(const Key('serialBaudField')), '9600');
      await tester.tap(find.byKey(const Key('serialStopBitsField')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('serialConnectButton')));
      await _waitUntil(
        tester,
        () =>
            container.read(sessionManagerProvider).activeTab?.sessionId != null,
        'Native Serial port did not open through the visible configuration dialog',
      );
      final initial = container.read(sessionManagerProvider).activeTab!;
      expect(initial.protocol, 'serial');
      expect(initial.followSftpEnabled, isFalse);
      expect(initial.sftpUnavailableReason, contains('không hỗ trợ SFTP'));
      await pair.send('QA_SERIAL_NATIVE_OUTPUT\r\n');
      await _waitUntil(
        tester,
        () => container
            .read(sessionManagerProvider)
            .activeTab!
            .terminal
            .buffer
            .getText()
            .contains('QA_SERIAL_NATIVE_OUTPUT'),
        'Real Serial bytes from the PTY peer did not reach the terminal',
      );
      const input = 'QA_SERIAL_KEYBOARD';
      final read = pair.readBytes(input.length + 1);
      await _keyboard(tester, input);
      expect(await read.timeout(const Duration(seconds: 5)), '$input\r');

      await pair.stop();
      await _waitUntil(
        tester,
        () => container.read(sessionManagerProvider).activeTab!.closed,
        'Unplugging the PTY peer did not close the native Serial session',
      );
      expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
      expect(
        container.read(sessionManagerProvider).activeTab!.closeReason,
        isNotEmpty,
      );
      await pair.start();
      await tester.tap(find.byKey(const Key('terminalReconnectBtn')));
      await _waitUntil(tester, () {
        final tab = container.read(sessionManagerProvider).activeTab!;
        return !tab.closed && tab.sessionId != null;
      }, 'Serial reconnect did not acquire the reopened OS PTY');
      final reconnected = container.read(sessionManagerProvider).activeTab!;
      expect(reconnected.localKey, initial.localKey);
      expect(reconnected.terminal, same(initial.terminal));
      expect(container.read(sessionManagerProvider).tabs, hasLength(1));
      await pair.send('QA_SERIAL_RECONNECTED\r\n');
      await _waitUntil(
        tester,
        () => reconnected.terminal.buffer.getText().contains(
          'QA_SERIAL_RECONNECTED',
        ),
        'Reconnected native Serial port did not deliver peer output',
      );
      final secondRead = pair.readBytes('AFTER_RECONNECT\r'.length);
      await _keyboard(tester, 'AFTER_RECONNECT');
      expect(
        await secondRead.timeout(const Duration(seconds: 5)),
        'AFTER_RECONNECT\r',
      );
      await container
          .read(sessionManagerProvider.notifier)
          .closeTab(reconnected.localKey);
      await tester.pump();
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isLinux,
  );
}
