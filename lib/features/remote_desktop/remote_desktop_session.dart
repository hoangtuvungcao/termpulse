import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/src/rust/api/dto.dart';

class DesktopFrame {
  final int width;
  final int height;
  final Uint8List rgba;
  final int sequence;
  const DesktopFrame(this.width, this.height, this.rgba, this.sequence);
}

/// Owns a native desktop connection even when its tab is not visible.
class RemoteDesktopSession extends ChangeNotifier {
  HostDto _host;
  HostDto get host => _host;
  final RemoteDesktopBackend backend;
  final Future<HostDto> Function()? refreshHost;
  final VoidCallback onStatusChanged;
  StreamSubscription<RemoteDesktopEventDto>? _subscription;
  String? sessionId;
  String? message;
  String? remoteClipboard;
  DesktopFrame? frame;
  bool connected = false;
  bool closed = false;
  bool _disposed = false;
  int _generation = 0;
  int _frameSequence = 0;
  final _inputs = Queue<_DesktopInput>();
  bool _drainingInputs = false;
  int _queuedButtons = 0;

  RemoteDesktopSession({
    required HostDto host,
    required this.backend,
    required this.onStatusChanged,
    this.refreshHost,
  }) : _host = host;

  Future<void> connect() async {
    final generation = ++_generation;
    await _closeNative();
    if (_disposed || generation != _generation) return;
    closed = false;
    connected = false;
    message = null;
    frame = null;
    remoteClipboard = null;
    _discardQueuedInputs();
    _drainingInputs = false;
    _queuedButtons = 0;
    _emit(status: true);
    try {
      if (refreshHost != null) {
        final latest = await refreshHost!();
        if (_disposed || generation != _generation) return;
        if (latest.id != host.id ||
            !const {'rdp', 'vnc'}.contains(latest.protocol)) {
          _fail(
            'Kết nối đã bị xóa hoặc đổi giao thức. Hãy mở lại từ danh sách host.',
          );
          return;
        }
        _host = latest;
        _emit(status: true);
      }
      _subscription = backend
          .connectHost(host.id)
          .listen(
            (event) {
              if (_disposed || generation != _generation || closed) return;
              if (event.sessionId.isNotEmpty) sessionId = event.sessionId;
              switch (event.kind) {
                case 'connecting':
                  _emit(status: true);
                case 'connected':
                  connected = true;
                  _emit(status: true);
                case 'frame':
                  final expected = event.width * event.height * 4;
                  if (event.width < 1 ||
                      event.height < 1 ||
                      expected > 3840 * 2160 * 4 ||
                      event.rgba.length != expected) {
                    _fail('Dữ liệu màn hình từ xa không hợp lệ.');
                    return;
                  }
                  frame = DesktopFrame(
                    event.width,
                    event.height,
                    // The bridge already transfers an owned Uint8List. Keep it
                    // instead of copying several MB again for every frame.
                    event.rgba,
                    ++_frameSequence,
                  );
                  _emit();
                case 'clipboard':
                  remoteClipboard = event.message;
                  _emit();
                case 'notice':
                  message = event.message;
                  _emit();
                case 'error':
                  _fail(event.message ?? 'Không kết nối được màn hình từ xa.');
                case 'closed':
                  _discardQueuedInputs();
                  closed = true;
                  connected = false;
                  frame = null;
                  remoteClipboard = null;
                  message = event.message ?? message ?? 'Phiên đã kết thúc';
                  _emit(status: true);
              }
            },
            onError: (Object error) {
              if (generation == _generation) _fail(error.toString());
            },
            onDone: () {
              if (!_disposed && generation == _generation && !closed) {
                _discardQueuedInputs();
                closed = true;
                connected = false;
                frame = null;
                remoteClipboard = null;
                message ??= 'Luồng kết nối đã kết thúc.';
                _emit(status: true);
              }
            },
          );
    } catch (error) {
      if (generation == _generation) _fail(error.toString());
    }
  }

  void _fail(String error) {
    if (_disposed || closed) return;
    closed = true;
    connected = false;
    frame = null;
    remoteClipboard = null;
    message = error;
    _discardQueuedInputs();
    _emit(status: true);
    unawaited(_closeNative());
  }

  void _emit({bool status = false}) {
    if (_disposed) return;
    if (status) onStatusChanged();
    notifyListeners();
  }

  Future<void> _closeNative() async {
    final subscription = _subscription;
    _subscription = null;
    final id = sessionId;
    sessionId = null;
    // Stop the socket before waiting on stream cancellation.
    if (id != null) {
      try {
        await backend.close(id);
      } catch (_) {}
    }
    await subscription?.cancel();
  }

  Future<void> close() async {
    ++_generation;
    _discardQueuedInputs();
    closed = true;
    connected = false;
    frame = null;
    remoteClipboard = null;
    message = 'Đã ngắt kết nối theo yêu cầu.';
    _emit(status: true);
    await _closeNative();
  }

  Future<void> pointer(int x, int y, int buttons, [int scrollY = 0]) async {
    final id = sessionId;
    if (!connected || id == null || closed) return;
    final motionOnly = buttons == _queuedButtons && scrollY == 0;
    _queuedButtons = buttons;
    await _queueInput(
      id,
      () => backend.pointer(id, x, y, buttons, scrollY),
      motionOnly: motionOnly,
    );
  }

  Future<void> key(int key, bool down, {bool unicode = false}) async {
    final id = sessionId;
    if (!connected || id == null || closed) return;
    await _queueInput(id, () => backend.key(id, key, down, unicode));
  }

  Future<void> typeText(String text) async {
    final id = sessionId;
    if (!connected || id == null || closed || text.isEmpty) return;
    await _queueInput(id, () => backend.typeText(id, text));
  }

  Future<void> _queueInput(
    String id,
    Future<void> Function() send, {
    bool motionOnly = false,
  }) {
    final generation = _generation;
    if (motionOnly && _inputs.isNotEmpty) {
      final pending = _inputs.last;
      if (pending.motionOnly &&
          pending.id == id &&
          pending.generation == generation) {
        // Replace only adjacent unsent movement. Button transitions, wheel,
        // keyboard and text remain ordering barriers and are never discarded.
        pending.send = send;
        return pending.done.future;
      }
    }
    final input = _DesktopInput(id, generation, send, motionOnly);
    _inputs.add(input);
    if (!_drainingInputs) unawaited(_drainInputs(generation));
    return input.done.future;
  }

  Future<void> _drainInputs(int generation) async {
    _drainingInputs = true;
    while (_inputs.isNotEmpty && generation == _generation && !_disposed) {
      final input = _inputs.removeFirst();
      try {
        if (!closed &&
            input.generation == _generation &&
            sessionId == input.id) {
          await input.send();
        }
      } catch (error) {
        if (generation == _generation) _fail(error.toString());
      } finally {
        if (!input.done.isCompleted) input.done.complete();
      }
    }
    if (generation == _generation) _drainingInputs = false;
  }

  void _discardQueuedInputs() {
    while (_inputs.isNotEmpty) {
      _inputs.removeFirst().done.complete();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    frame = null;
    remoteClipboard = null;
    ++_generation;
    _discardQueuedInputs();
    unawaited(_closeNative());
    super.dispose();
  }
}

class _DesktopInput {
  _DesktopInput(this.id, this.generation, this.send, this.motionOnly);
  final String id;
  final int generation;
  Future<void> Function() send;
  final bool motionOnly;
  final done = Completer<void>();
}
