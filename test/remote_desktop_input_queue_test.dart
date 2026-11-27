import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/src/rust/api/dto.dart';

class _QueueBackend implements RemoteDesktopBackend {
  final streams = <StreamController<RemoteDesktopEventDto>>[];
  final operations = <String>[];
  final closed = <String>[];
  Future<void>? gate;

  @override
  Stream<RemoteDesktopEventDto> connectHost(String hostId) {
    final stream = StreamController<RemoteDesktopEventDto>(sync: true);
    streams.add(stream);
    return stream.stream;
  }

  Future<void> _send(String operation) async {
    final currentGate = gate;
    operations.add(operation);
    await currentGate;
  }

  @override
  Future<void> pointer(String id, int x, int y, int buttons, int scrollY) =>
      _send('$id:pointer:$x:$y:$buttons:$scrollY');

  @override
  Future<void> key(String id, int key, bool down, bool unicode) =>
      _send('$id:key:$key:$down:$unicode');

  @override
  Future<void> typeText(String id, String text) => _send('$id:text:$text');

  @override
  Future<void> close(String sessionId) async => closed.add(sessionId);

  @override
  Future<String> probeCertificate(
    String hostname,
    int port,
    String? name,
  ) async => 'ab' * 32;

  void connected(String id) {
    streams.last.add(
      RemoteDesktopEventDto(
        kind: 'connected',
        sessionId: id,
        width: 1280,
        height: 720,
        rgba: Uint8List(0),
      ),
    );
  }

  Future<void> dispose() async {
    for (final stream in streams) {
      await stream.close();
    }
  }
}

HostDto _host() => const HostDto(
  id: 'desktop',
  label: 'Queue test desktop',
  protocol: 'rdp',
  hostname: 'fixture.invalid',
  port: 3389,
  identityMode: 'direct',
  identityId: 'identity',
  jumpHostMode: 'none',
  proxyMode: 'none',
  envTag: 'test',
  tags: [],
  notes: '',
  env: [],
  isFavorite: false,
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _QueueBackend backend;
  late RemoteDesktopSession session;

  setUp(() async {
    backend = _QueueBackend();
    session = RemoteDesktopSession(
      host: _host(),
      backend: backend,
      onStatusChanged: () {},
    );
    await session.connect();
    backend.connected('old');
  });

  tearDown(() async {
    session.dispose();
    await _flush();
    await backend.dispose();
  });

  test(
    'adjacent unsent motion sends latest position and completes every caller',
    () async {
      final gate = Completer<void>();
      backend.gate = gate.future;
      final inputs = <Future<void>>[session.pointer(1, 1, 0)];
      for (var x = 2; x <= 50; x++) {
        inputs.add(session.pointer(x, x, 0));
      }
      await _flush();
      expect(backend.operations, ['old:pointer:1:1:0:0']);
      backend.gate = null;
      gate.complete();
      await Future.wait(inputs);
      expect(backend.operations, [
        'old:pointer:1:1:0:0',
        'old:pointer:50:50:0:0',
      ]);
    },
  );

  test(
    'button edges wheel keys and text remain ordered motion barriers',
    () async {
      final gate = Completer<void>();
      backend.gate = gate.future;
      final inputs = <Future<void>>[
        session.key(30, true),
        session.pointer(10, 10, 0),
        session.pointer(11, 11, 0),
        session.pointer(12, 12, 1),
        session.pointer(13, 13, 1),
        session.pointer(14, 14, 1),
        session.pointer(15, 15, 0),
        session.pointer(16, 16, 0),
        session.pointer(17, 17, 0),
        session.pointer(18, 18, 0, 120),
        session.pointer(19, 19, 0),
        session.pointer(20, 20, 0),
        session.key(30, false),
        session.pointer(21, 21, 0),
        session.pointer(22, 22, 0),
        session.typeText('reviewed text'),
        session.pointer(23, 23, 0),
        session.pointer(24, 24, 0),
      ];
      backend.gate = null;
      gate.complete();
      await Future.wait(inputs);
      expect(backend.operations, [
        'old:key:30:true:false',
        'old:pointer:11:11:0:0',
        'old:pointer:12:12:1:0',
        'old:pointer:14:14:1:0',
        'old:pointer:15:15:0:0',
        'old:pointer:17:17:0:0',
        'old:pointer:18:18:0:120',
        'old:pointer:20:20:0:0',
        'old:key:30:false:false',
        'old:pointer:22:22:0:0',
        'old:text:reviewed text',
        'old:pointer:24:24:0:0',
      ]);
    },
  );

  for (final oldFails in [false, true]) {
    test(
      'reconnect isolates ${oldFails ? 'failed' : 'completed'} old in-flight input from new drain',
      () async {
        final oldGate = Completer<void>();
        backend.gate = oldGate.future;
        final oldInFlight = session.key(30, true);
        final oldQueued = session.typeText('must never reach new connection');
        var oldQueuedCompleted = false;
        unawaited(oldQueued.then((_) => oldQueuedCompleted = true));
        await session.connect();
        backend.connected('new');
        await _flush();
        expect(oldQueuedCompleted, isTrue);
        expect(backend.closed, ['old']);

        final newGate = Completer<void>();
        backend.gate = newGate.future;
        final newInFlight = session.pointer(1, 1, 0);
        final newMotion = session.pointer(2, 2, 0);
        final newMotionLatest = session.pointer(3, 3, 0);
        var newMotionCompleted = false;
        unawaited(newMotion.then((_) => newMotionCompleted = true));
        if (oldFails) {
          oldGate.completeError(StateError('stale old connection error'));
        } else {
          oldGate.complete();
        }
        await oldInFlight;
        await _flush();
        expect(session.connected, isTrue);
        expect(session.closed, isFalse);
        expect(session.message, isNull);
        expect(newMotionCompleted, isFalse);
        expect(backend.operations, [
          'old:key:30:true:false',
          'new:pointer:1:1:0:0',
        ]);

        final finalMotion = session.pointer(4, 4, 0);
        final key = session.key(30, false);
        backend.gate = null;
        newGate.complete();
        await Future.wait([
          newInFlight,
          newMotion,
          newMotionLatest,
          finalMotion,
          key,
        ]);
        expect(backend.operations, [
          'old:key:30:true:false',
          'new:pointer:1:1:0:0',
          'new:pointer:4:4:0:0',
          'new:key:30:false:false',
        ]);
      },
    );
  }

  for (final streamDone in [false, true]) {
    test(
      '${streamDone ? 'stream completion' : 'closed event'} completes queued input before an in-flight native call returns',
      () async {
        final gate = Completer<void>();
        backend.gate = gate.future;
        final inFlight = session.pointer(1, 1, 0);
        var inFlightCompleted = false;
        unawaited(inFlight.then((_) => inFlightCompleted = true));
        final queued = <Future<void>>[
          session.key(30, true),
          session.typeText('must not reach the ended connection'),
        ];
        var queuedCompleted = 0;
        for (final input in queued) {
          unawaited(input.then((_) => queuedCompleted++));
        }
        await _flush();

        if (streamDone) {
          await backend.streams.single.close();
        } else {
          backend.streams.single.add(
            RemoteDesktopEventDto(
              kind: 'closed',
              sessionId: 'old',
              width: 0,
              height: 0,
              rgba: Uint8List(0),
            ),
          );
        }
        await _flush();
        final completedBeforeNativeReturn = queuedCompleted;
        final inFlightCompletedBeforeNativeReturn = inFlightCompleted;
        backend.gate = null;
        gate.complete();
        await Future.wait([inFlight, ...queued]);

        expect(completedBeforeNativeReturn, queued.length);
        expect(inFlightCompletedBeforeNativeReturn, isFalse);
        expect(backend.operations, ['old:pointer:1:1:0:0']);
        expect(session.closed, isTrue);
        expect(session.connected, isFalse);
      },
    );
  }

  test(
    'close completes queued input without waiting for an old native call',
    () async {
      final gate = Completer<void>();
      backend.gate = gate.future;
      final inFlight = session.pointer(1, 1, 0);
      final queued = session.key(30, true);
      var queuedCompleted = false;
      unawaited(queued.then((_) => queuedCompleted = true));
      await session.close();
      await _flush();
      final completedBeforeNativeReturn = queuedCompleted;
      gate.complete();
      await inFlight;
      expect(completedBeforeNativeReturn, isTrue);
      expect(backend.operations, ['old:pointer:1:1:0:0']);
      expect(session.closed, isTrue);
      expect(backend.closed, ['old']);
    },
  );
}
