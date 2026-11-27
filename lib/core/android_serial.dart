import 'dart:async';

import 'package:flutter/services.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';

/// Android USB Host serial sessions. Desktop sessions continue using Rust.
class AndroidSerial {
  AndroidSerial({
    MethodChannel methods = const MethodChannel('termpulse/android_serial'),
    EventChannel events = const EventChannel('termpulse/android_serial/events'),
  }) : _methods = methods,
       _events = events;

  final MethodChannel _methods;
  final EventChannel _events;
  final _sessions = <String, StreamController<TerminalEventDto>>{};
  StreamSubscription<dynamic>? _subscription;
  int _sequence = 0;

  bool owns(String sessionId) => sessionId.startsWith('android_serial_');

  Future<T?> _call<T>(String method, [Map<String, dynamic>? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw StateError(error.message ?? error.code);
    }
  }

  Future<List<SerialPortInfoDto>> listPorts() async {
    final ports = await _call<List<dynamic>>('listPorts') ?? [];
    return ports.map((raw) {
      final value = Map<String, dynamic>.from(raw as Map);
      return SerialPortInfoDto(
        portName: value['portName'] as String,
        portType: 'usb',
        manufacturer: value['manufacturer'] as String?,
        product: value['product'] as String?,
        serialNumber: value['serialNumber'] as String?,
      );
    }).toList();
  }

  void _listen() {
    _subscription ??= _events.receiveBroadcastStream().listen(
      (dynamic raw) {
        final event = Map<String, dynamic>.from(raw as Map);
        final id = event['sessionId'] as String?;
        final stream = _sessions[id];
        if (stream == null || stream.isClosed) return;
        final kind = event['kind'] as String;
        if (kind == 'output_bytes') {
          final bytes = event['bytes'];
          stream.add(
            TerminalEventDto(
              kind: kind,
              bytes: bytes is Uint8List
                  ? bytes
                  : Uint8List.fromList((bytes as List).cast<int>()),
            ),
          );
        } else if (kind == 'error') {
          stream.addError(StateError(event['text'] as String));
          _finish(id!);
        } else if (kind == 'closed') {
          stream.add(
            TerminalEventDto(kind: kind, text: event['text'] as String?),
          );
          _finish(id!);
        }
      },
      onError: (Object error, StackTrace stack) {
        for (final stream in _sessions.values.toList()) {
          stream.addError(error, stack);
          unawaited(stream.close());
        }
        _sessions.clear();
      },
    );
  }

  void _finish(String id) {
    final stream = _sessions.remove(id);
    if (stream != null) unawaited(stream.close());
  }

  Stream<TerminalEventDto> connect(SerialConfigDto config, {String? label}) {
    final id =
        'android_serial_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    late final StreamController<TerminalEventDto> controller;
    controller = StreamController<TerminalEventDto>(
      onListen: () async {
        _sessions[id] = controller;
        _listen();
        try {
          await _call<void>('open', {
            'sessionId': id,
            'portName': config.portName,
            'baudRate': config.baudRate,
            'dataBits': config.dataBits,
            'parity': config.parity,
            'stopBits': config.stopBits,
            'flowControl': config.flowControl,
          });
          if (_sessions[id] != controller || controller.isClosed) return;
          controller.add(TerminalEventDto(kind: 'session_opened', text: id));
          controller.add(
            TerminalEventDto(
              kind: 'title_changed',
              text:
                  label ??
                  'Serial ${config.portName} · ${config.baudRate} baud',
            ),
          );
          // Read only after the Dart subscriber has received session_opened.
          await _call<void>('start', {'sessionId': id});
        } catch (error, stack) {
          if (!controller.isClosed) {
            controller.addError(error, stack);
          }
          _finish(id);
        }
      },
      onCancel: () async {
        _sessions.remove(id);
        await _call<void>('close', {'sessionId': id});
      },
    );
    return controller.stream;
  }

  Future<void> write(String id, List<int> bytes) => _call<void>('write', {
    'sessionId': id,
    'bytes': Uint8List.fromList(bytes),
  });

  Future<void> close(String id) async {
    await _call<void>('close', {'sessionId': id});
    final stream = _sessions[id];
    if (stream != null && !stream.isClosed) {
      stream.add(
        const TerminalEventDto(kind: 'closed', text: 'USB Serial đã đóng.'),
      );
    }
    _finish(id);
  }

  Future<void> closeAll() async {
    await _call<void>('closeAll');
    for (final id in _sessions.keys.toList()) {
      final stream = _sessions[id]!;
      if (!stream.isClosed) {
        stream.add(
          const TerminalEventDto(kind: 'closed', text: 'USB Serial đã đóng.'),
        );
      }
      _finish(id);
    }
    await _subscription?.cancel();
    _subscription = null;
  }
}
