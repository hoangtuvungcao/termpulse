import 'dart:async';
import 'package:flutter/gestures.dart';

/// Touchpad gestures never press a remote button just because a finger lands.
/// A second finger can therefore become a right tap or pinch without dragging
/// a remote window or leaving the left button held down.
class RemoteDesktopTouchpad {
  RemoteDesktopTouchpad({
    required this.onMove,
    required this.onButton,
    required this.onTransform,
  });

  final void Function(Offset delta) onMove;
  final void Function(int button, bool down) onButton;
  final void Function(Offset previousFocal, Offset focal, double scale)
  onTransform;
  final _contacts = <int, _Contact>{};
  Timer? _hold;
  Duration _started = Duration.zero;
  int _maximumPointers = 0;
  bool _moved = false;
  bool _dragging = false;
  Offset? _focal;
  double? _span;

  static const _slop = 8.0;

  void add(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (_contacts.isEmpty) {
        _started = event.timeStamp;
        _maximumPointers = 0;
        _moved = false;
      }
      _contacts[event.pointer] = _Contact(event.position);
      _maximumPointers = _contacts.length > _maximumPointers
          ? _contacts.length
          : _maximumPointers;
      _hold?.cancel();
      if (_contacts.length == 1) {
        _hold = Timer(const Duration(milliseconds: 500), () {
          if (_contacts.length == 1 && _maximumPointers == 1 && !_moved) {
            _dragging = true;
            onButton(1, true);
          }
        });
      } else {
        if (_dragging) {
          _dragging = false;
          onButton(1, false);
        }
        _rememberTransform();
      }
      return;
    }
    final contact = _contacts[event.pointer];
    if (contact == null) return;
    if (event is PointerMoveEvent) {
      final previous = contact.position;
      contact.position = event.position;
      final wasMoved = _moved;
      if ((event.position - contact.start).distance > _slop) {
        _moved = true;
        _hold?.cancel();
      }
      if (_maximumPointers == 1 && (_moved || _dragging)) {
        onMove(
          event.position - (wasMoved || _dragging ? previous : contact.start),
        );
      } else if (_contacts.length == 2 && _maximumPointers == 2 && _moved) {
        final positions = _contacts.values.map((c) => c.position).toList();
        final focal = (positions[0] + positions[1]) / 2;
        final span = (positions[0] - positions[1]).distance;
        if (_focal != null && _span != null && _span! > 1 && span > 1) {
          onTransform(_focal!, focal, span / _span!);
        }
        _focal = focal;
        _span = span;
      }
      return;
    }
    if (event is PointerCancelEvent) {
      cancel();
      return;
    }
    if (event is PointerUpEvent) {
      _contacts.remove(event.pointer);
      _hold?.cancel();
      if (_contacts.isNotEmpty) return;
      if (_dragging) {
        _dragging = false;
        onButton(1, false);
      } else if (!_moved &&
          event.timeStamp - _started <= const Duration(milliseconds: 500) &&
          _maximumPointers <= 2) {
        final button = _maximumPointers == 2 ? 4 : 1;
        onButton(button, true);
        onButton(button, false);
      }
      _focal = null;
      _span = null;
    }
  }

  void _rememberTransform() {
    if (_contacts.length != 2) return;
    final positions = _contacts.values.map((c) => c.position).toList();
    _focal = (positions[0] + positions[1]) / 2;
    _span = (positions[0] - positions[1]).distance;
  }

  void cancel({bool release = true}) {
    _hold?.cancel();
    _contacts.clear();
    if (_dragging && release) onButton(1, false);
    _dragging = false;
    _focal = null;
    _span = null;
  }

  void dispose() => cancel();
}

class _Contact {
  _Contact(this.start) : position = start;
  final Offset start;
  Offset position;
}
