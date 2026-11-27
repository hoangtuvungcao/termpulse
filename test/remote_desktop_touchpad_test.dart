import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_touchpad.dart';

PointerDownEvent _down(int pointer, Offset position, int milliseconds) =>
    PointerDownEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
      timeStamp: Duration(milliseconds: milliseconds),
    );

PointerMoveEvent _move(int pointer, Offset position, int milliseconds) =>
    PointerMoveEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
      timeStamp: Duration(milliseconds: milliseconds),
    );

PointerUpEvent _up(int pointer, Offset position, int milliseconds) =>
    PointerUpEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
      timeStamp: Duration(milliseconds: milliseconds),
    );

void main() {
  late List<Offset> moves;
  late List<(int, bool)> buttons;
  late List<(Offset, Offset, double)> transforms;
  late RemoteDesktopTouchpad touchpad;

  setUp(() {
    moves = [];
    buttons = [];
    transforms = [];
    touchpad = RemoteDesktopTouchpad(
      onMove: moves.add,
      onButton: (button, down) => buttons.add((button, down)),
      onTransform: (previous, current, scale) =>
          transforms.add((previous, current, scale)),
    );
  });

  tearDown(() => touchpad.dispose());

  testWidgets('stationary single tap clicks left only after finger lifts', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(buttons, isEmpty);
    expect(moves, isEmpty);
    touchpad.add(_move(1, const Offset(23, 32), 110));
    expect(buttons, isEmpty);
    expect(moves, isEmpty);
    touchpad.add(_up(1, const Offset(23, 32), 150));
    expect(buttons, [(1, true), (1, false)]);
    expect(transforms, isEmpty);
  });

  testWidgets('two finger tap emits right click without left press', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    touchpad.add(_down(2, const Offset(70, 30), 20));
    await tester.pump(const Duration(milliseconds: 100));
    expect(buttons, isEmpty);
    touchpad.add(_up(1, const Offset(20, 30), 120));
    expect(buttons, isEmpty);
    touchpad.add(_up(2, const Offset(70, 30), 140));
    expect(buttons, [(4, true), (4, false)]);
    expect(moves, isEmpty);
    expect(transforms, isEmpty);
  });

  testWidgets('swipes move relatively without pressing remote buttons', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    touchpad.add(_move(1, const Offset(40, 30), 30));
    touchpad.add(_move(1, const Offset(45, 40), 60));
    await tester.pump(const Duration(milliseconds: 600));
    touchpad.add(_up(1, const Offset(45, 40), 650));
    expect(moves, [const Offset(20, 0), const Offset(5, 10)]);
    expect(buttons, isEmpty);
    expect(transforms, isEmpty);
  });

  testWidgets('pinch reports focal transform and never clicks or drags', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(100, 100), 0));
    touchpad.add(_down(2, const Offset(200, 100), 10));
    touchpad.add(_move(2, const Offset(240, 100), 40));
    touchpad.add(_move(1, const Offset(80, 100), 70));
    touchpad.add(_up(2, const Offset(240, 100), 100));
    touchpad.add(_up(1, const Offset(80, 100), 120));
    await tester.pump(const Duration(milliseconds: 600));
    expect(transforms, hasLength(2));
    expect(transforms.first.$1, const Offset(150, 100));
    expect(transforms.first.$2, const Offset(170, 100));
    expect(transforms.first.$3, closeTo(1.4, 0.0001));
    expect(transforms.last.$1, const Offset(170, 100));
    expect(transforms.last.$2, const Offset(160, 100));
    expect(transforms.last.$3, closeTo(160 / 140, 0.0001));
    expect(moves, isEmpty);
    expect(buttons, isEmpty);
  });

  testWidgets('long hold enables left drag and releases once on lift', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    await tester.pump(const Duration(milliseconds: 499));
    expect(buttons, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(buttons, [(1, true)]);
    touchpad.add(_move(1, const Offset(24, 34), 520));
    touchpad.add(_move(1, const Offset(40, 44), 560));
    expect(moves, [const Offset(4, 4), const Offset(16, 10)]);
    touchpad.add(_up(1, const Offset(40, 44), 600));
    expect(buttons, [(1, true), (1, false)]);
    expect(transforms, isEmpty);
  });

  testWidgets('pointer cancellation releases drag and ignores stale lift', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    await tester.pump(const Duration(milliseconds: 500));
    touchpad.add(
      const PointerCancelEvent(
        pointer: 1,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration(milliseconds: 550),
      ),
    );
    touchpad.add(_up(1, const Offset(20, 30), 570));
    expect(buttons, [(1, true), (1, false)]);
    expect(moves, isEmpty);
    touchpad.add(_down(2, const Offset(40, 50), 600));
    touchpad.add(_up(2, const Offset(40, 50), 650));
    expect(buttons, [(1, true), (1, false), (1, true), (1, false)]);
  });

  testWidgets('cancelling a pending tap cannot turn into a delayed press', (
    tester,
  ) async {
    touchpad.add(_down(1, const Offset(20, 30), 0));
    await tester.pump(const Duration(milliseconds: 100));
    touchpad.cancel();
    await tester.pump(const Duration(milliseconds: 600));
    touchpad.add(_up(1, const Offset(20, 30), 750));
    expect(buttons, isEmpty);
    expect(moves, isEmpty);
    expect(transforms, isEmpty);
  });
}
