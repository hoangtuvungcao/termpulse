import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/android_serial.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';

const _methods = MethodChannel('termpulse/android_serial');
const _eventMethods = MethodChannel('termpulse/android_serial/events');
const _events = EventChannel('termpulse/android_serial/events');
const _config = SerialConfigDto(
  portName: 'usb:/dev/bus/usb/001/002:1',
  baudRate: 57600,
  dataBits: 7,
  parity: 'even',
  stopBits: 2,
  flowControl: 'hardware',
);

class _UsbPlatform {
  final calls = <MethodCall>[];
  final eventCalls = <String>[];
  final ports = <Map<String, dynamic>>[];
  List<int>? initialBytes;
  Completer<void>? openGate;
  PlatformException? openError;

  TestDefaultBinaryMessenger get messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    messenger.setMockMethodCallHandler(_eventMethods, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listPorts':
          return ports;
        case 'open':
          if (openGate case final gate?) await gate.future;
          if (openError case final error?) throw error;
        case 'start':
          if (initialBytes case final bytes?) {
            await emit(
              (call.arguments as Map)['sessionId'] as String,
              'output_bytes',
              bytes: bytes,
            );
          }
      }
      return null;
    });
  }

  Future<void> emit(
    String id,
    String kind, {
    List<int>? bytes,
    String? text,
  }) async {
    await messenger.handlePlatformMessage(
      _events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'sessionId': id,
        'kind': kind,
        if (bytes != null) 'bytes': Uint8List.fromList(bytes),
        'text': ?text,
      }),
      null,
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_eventMethods, null);
  }
}

class _Session {
  _Session(Stream<TerminalEventDto> stream) {
    subscription = stream.listen(
      (event) {
        events.add(event);
        if (event.kind == 'session_opened') opened.complete(event.text!);
        if (event.kind == 'output_bytes' && !output.isCompleted) {
          output.complete();
        }
      },
      onError: (Object error) => errors.add(error),
      onDone: () => done.complete(),
    );
  }

  final events = <TerminalEventDto>[];
  final errors = <Object>[];
  final opened = Completer<String>();
  final output = Completer<void>();
  final done = Completer<void>();
  late StreamSubscription<TerminalEventDto> subscription;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AndroidSerial serial;
  late _UsbPlatform platform;

  setUp(() {
    platform = _UsbPlatform()..install();
    serial = AndroidSerial(methods: _methods, events: _events);
  });
  tearDown(() async {
    await serial.closeAll();
    platform.uninstall();
  });

  test(
    'USB discovery preserves device metadata and usable port names',
    () async {
      platform.ports.add({
        'portName': _config.portName,
        'manufacturer': 'Acme',
        'product': 'USB UART · 2',
        'serialNumber': 'ABC-123',
      });
      final ports = await serial.listPorts();
      expect(ports, hasLength(1));
      expect(ports.single.portName, _config.portName);
      expect(ports.single.portType, 'usb');
      expect(ports.single.manufacturer, 'Acme');
      expect(ports.single.product, 'USB UART · 2');
      expect(ports.single.serialNumber, 'ABC-123');
    },
  );

  test(
    'USB session applies framing and delivers open before binary data',
    () async {
      platform.initialBytes = [0, 255, 13, 10];
      final session = _Session(
        serial.connect(_config, label: 'Router console'),
      );
      final id = await session.opened.future;
      await session.output.future;
      expect(serial.owns(id), isTrue);
      expect(
        platform.calls.firstWhere((call) => call.method == 'open').arguments,
        {
          'sessionId': id,
          'portName': _config.portName,
          'baudRate': 57600,
          'dataBits': 7,
          'parity': 'even',
          'stopBits': 2,
          'flowControl': 'hardware',
        },
      );
      expect(session.events.map((event) => event.kind), [
        'session_opened',
        'title_changed',
        'output_bytes',
      ]);
      expect(session.events[1].text, 'Router console');
      expect(session.events.last.bytes, [0, 255, 13, 10]);

      await serial.write(id, [255, 0, 3]);
      final write = platform.calls.lastWhere((call) => call.method == 'write');
      expect((write.arguments as Map)['bytes'], isA<Uint8List>());
      expect((write.arguments as Map)['bytes'], [255, 0, 3]);
      await serial.close(id);
      await session.done.future;
      expect(session.events.last.kind, 'closed');
      expect(session.errors, isEmpty);
    },
  );

  test(
    'denied Android permission fails cleanly before reading starts',
    () async {
      platform.openError = PlatformException(
        code: 'permission_denied',
        message: 'Quyền truy cập USB Serial bị từ chối.',
      );
      final session = _Session(serial.connect(_config));
      await session.done.future;
      expect(session.events, isEmpty);
      expect(session.errors.single, isA<StateError>());
      expect(session.errors.single.toString(), contains('Quyền truy cập'));
      expect(platform.calls.any((call) => call.method == 'start'), isFalse);
      expect(platform.calls.any((call) => call.method == 'close'), isTrue);
    },
  );

  test(
    'unplug closes its session without affecting another USB session',
    () async {
      final first = _Session(serial.connect(_config));
      final second = _Session(serial.connect(_config));
      final firstId = await first.opened.future;
      final secondId = await second.opened.future;
      expect(firstId, isNot(secondId));
      await platform.emit(
        firstId,
        'error',
        text: 'Thiết bị USB Serial đã ngắt kết nối.',
      );
      await first.done.future;
      await platform.emit(secondId, 'output_bytes', bytes: [42]);
      await second.output.future;
      expect(first.errors.single.toString(), contains('ngắt kết nối'));
      expect(second.events.last.bytes, [42]);
      expect(second.errors, isEmpty);
      await serial.close(secondId);
      await second.done.future;
    },
  );

  test(
    'cancelling while permission is pending prevents a late session',
    () async {
      platform.openGate = Completer<void>();
      final session = _Session(serial.connect(_config));
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls.any((call) => call.method == 'open'), isTrue);
      await session.subscription.cancel();
      platform.openGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.events, isEmpty);
      expect(platform.calls.any((call) => call.method == 'close'), isTrue);
      expect(platform.calls.any((call) => call.method == 'start'), isFalse);
    },
  );

  test(
    'vault cleanup closes sessions and permits a fresh event listener',
    () async {
      final first = _Session(serial.connect(_config));
      final second = _Session(serial.connect(_config));
      await first.opened.future;
      await second.opened.future;
      await serial.closeAll();
      await Future.wait([first.done.future, second.done.future]);
      expect(first.events.last.kind, 'closed');
      expect(second.events.last.kind, 'closed');
      expect(platform.eventCalls, ['listen', 'cancel']);

      platform.initialBytes = [65];
      final reopened = _Session(serial.connect(_config));
      final id = await reopened.opened.future;
      await reopened.output.future;
      expect(platform.eventCalls, ['listen', 'cancel', 'listen']);
      expect(reopened.events.last.bytes, [65]);
      await serial.close(id);
      await reopened.done.future;
    },
  );
}
