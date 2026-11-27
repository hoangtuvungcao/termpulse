import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/features/terminal/terminal_search.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _ToolBackend extends FakeCoreBackend {
  final connections = <StreamController<TerminalEventDto>>[];

  @override
  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows) {
    final stream = StreamController<TerminalEventDto>();
    connections.add(stream);
    scheduleMicrotask(() {
      stream.add(
        TerminalEventDto(
          kind: 'session_opened',
          text: 'tools_${connections.length}',
        ),
      );
      stream.add(
        TerminalEventDto(
          kind: 'output_bytes',
          bytes: utf8.encode('Alpha alpha\r\nbeta\r\n'),
        ),
      );
    });
    return stream.stream;
  }
}

Future<ProviderContainer> _boot(
  WidgetTester tester,
  _ToolBackend backend, {
  Size size = const Size(1280, 820),
}) async {
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
  if (size.width < 900) {
    await tester.tap(find.text('prod-api-01').first);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byType(TerminalView).first);
  await tester.pump();
  backend.sentInputs.clear();
  return container;
}

Future<void> _shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    var clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
            case 'Clipboard.getData':
              return {'text': clipboard};
            case 'Clipboard.hasStrings':
              return {'value': clipboard.isNotEmpty};
          }
          return null;
        });
  });
  test('terminal search handles case, literal regex characters and limits', () {
    final terminal = Terminal()..resize(80, 4);
    terminal.write('Alpha alpha a.b a[b]\r\nALPHA');
    expect(searchTerminalBuffer(terminal.buffer, 'alpha').length, 3);
    expect(
      searchTerminalBuffer(
        terminal.buffer,
        'Alpha',
        caseSensitive: true,
      ).length,
      1,
    );
    expect(searchTerminalBuffer(terminal.buffer, 'a.b').length, 1);
    expect(searchTerminalBuffer(terminal.buffer, 'a[b]').length, 1);
    expect(searchTerminalBuffer(terminal.buffer, 'alpha', limit: 2).length, 2);
    expect(searchTerminalBuffer(terminal.buffer, ''), isEmpty);
    expect(searchTerminalBuffer(terminal.buffer, 'Alpha', limit: 0), isEmpty);
  });

  test('terminal search crosses soft wraps but not hard newlines', () {
    final terminal = Terminal()..resize(6, 4);
    terminal.write('abcdefghi\r\njkl');
    final match = searchTerminalBuffer(terminal.buffer, 'defgh').single;
    expect(match.begin, const CellOffset(3, 0));
    expect(match.end, const CellOffset(2, 1));
    expect(searchTerminalBuffer(terminal.buffer, 'ghijkl'), isEmpty);
  });

  test('terminal search retains wide glyph and surrogate cell coordinates', () {
    final terminal = Terminal()..resize(30, 4);
    terminal.write('你🙂 hello 你🙂');
    final match = searchTerminalBuffer(terminal.buffer, 'hello').single;
    expect(match.begin, const CellOffset(5, 0));
    expect(match.end, const CellOffset(10, 0));
    for (final match in searchTerminalBuffer(terminal.buffer, '你🙂')) {
      expect(
        terminal.buffer.getText(BufferRangeLine(match.begin, match.end)),
        '你🙂',
      );
    }
  });

  for (final size in [const Size(1280, 820), const Size(360, 740)]) {
    testWidgets(
      'terminal find is navigable and leaves PTY intact at ${size.width}px',
      (tester) async {
        final backend = _ToolBackend();
        final container = await _boot(tester, backend, size: size);
        if (size.width < 900) {
          await tester.tap(find.byKey(const Key('mobileTerminalFindBtn')));
        } else {
          await _shortcut(tester, LogicalKeyboardKey.keyF, shift: true);
        }
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('terminalSearchField')),
          'alpha',
        );
        await tester.pumpAndSettle();
        expect(find.text('1/2'), findsOneWidget);
        expect(
          container
              .read(sessionManagerProvider)
              .activeTab!
              .controller
              .highlights
              .length,
          1,
        );
        await tester.tap(find.byTooltip('Kết quả tiếp / Next'));
        await tester.pump();
        expect(find.text('2/2'), findsOneWidget);
        await tester.tap(find.byTooltip('Kết quả tiếp / Next'));
        await tester.pump();
        expect(find.text('1/2'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('terminalSearchField')),
          'missing',
        );
        await tester.pumpAndSettle();
        expect(find.text('0/0'), findsOneWidget);
        await tester.tap(find.byTooltip('Đóng tìm kiếm / Close search'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('terminalSearchField')), findsNothing);
        expect(
          container
              .read(sessionManagerProvider)
              .activeTab!
              .controller
              .highlights,
          isEmpty,
        );
        expect(backend.sentInputs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Ctrl+A and Ctrl+C reach shell; paste is bracketed and strips controls',
    (tester) async {
      final backend = _ToolBackend();
      final container = await _boot(tester, backend);
      await _shortcut(tester, LogicalKeyboardKey.keyA);
      await _shortcut(tester, LogicalKeyboardKey.keyC);
      expect(backend.sentInputs.join(), '\x01\x03');
      backend.sentInputs.clear();
      container
          .read(sessionManagerProvider)
          .activeTab!
          .terminal
          .write('\x1b[?2004h');
      await tester.runAsync(
        () =>
            Clipboard.setData(const ClipboardData(text: 'echo \x1bready\x00')),
      );
      await _shortcut(tester, LogicalKeyboardKey.keyV, shift: true);
      expect(backend.sentInputs.single, '\x1b[200~echo ready\x1b[201~');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'multiline clipboard waits for approval and cancel sends nothing',
    (tester) async {
      final backend = _ToolBackend();
      await _boot(tester, backend);
      await tester.runAsync(
        () => Clipboard.setData(
          const ClipboardData(text: 'echo one\necho two\n'),
        ),
      );
      await _shortcut(tester, LogicalKeyboardKey.keyV);
      expect(find.textContaining('echo one'), findsWidgets);
      expect(backend.sentInputs, isEmpty);
      await tester.tap(find.text('Huỷ bỏ'));
      await tester.pumpAndSettle();
      expect(backend.sentInputs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disconnected terminal reconnects same tab from visible action', (
    tester,
  ) async {
    final backend = _ToolBackend();
    final container = await _boot(tester, backend);
    final before = container.read(sessionManagerProvider).activeTab!;
    backend.connections.first.add(
      const TerminalEventDto(kind: 'closed', text: 'test disconnect'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
    await tester.tap(find.byKey(const Key('terminalReconnectBtn')));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    final after = container.read(sessionManagerProvider).activeTab!;
    expect(after.localKey, before.localKey);
    expect(after.terminal, same(before.terminal));
    expect(
      after.closed,
      isFalse,
      reason: container.read(sessionManagerProvider).lastError,
    );
    expect(after.sessionId, 'tools_2');
    expect(container.read(sessionManagerProvider).tabs.length, 1);
    expect(find.byKey(const Key('terminalReconnectBtn')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('palette arrow navigation executes selected result', (
    tester,
  ) async {
    final backend = _ToolBackend();
    final container = await _boot(tester, backend);
    await _shortcut(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(
      find.byKey(const Key('commandPaletteSearch')),
      'Kết nối:',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(sessionManagerProvider).activeTab!.title, 'dev-box');
    expect(find.byKey(const Key('commandPaletteSearch')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('session log actions are discoverable in the terminal menu', (
    tester,
  ) async {
    final backend = _ToolBackend();
    final container = await _boot(tester, backend);
    final tab = container.read(sessionManagerProvider).activeTab!;
    expect(tab.sessionId, isNotNull);

    await tester.tap(find.byKey(const Key('terminalSessionTools')));
    await tester.pumpAndSettle();
    expect(find.text('Bắt đầu ghi đầu ra'), findsOneWidget);
    expect(find.text('Xem và quản lý log…'), findsOneWidget);
    expect(find.text('Xuất scrollback hiện có…'), findsOneWidget);
    expect(container.read(sessionLogsProvider).activeFor(tab.localKey), isNull);
  });

  testWidgets('dangerous pinned snippet uses confirmation before execution', (
    tester,
  ) async {
    final backend = _ToolBackend();
    backend.snippets.add(
      const SnippetDto(
        id: 'danger',
        scope: 'global',
        title: 'Danger test',
        commandTpl: 'rm -rf /tmp/old_cache',
        pinButtonBar: true,
      ),
    );
    await _boot(tester, backend);
    await tester.tap(find.text('Danger test'));
    await tester.pumpAndSettle();
    expect(find.text('Cảnh báo lệnh nguy hiểm (PROD)'), findsOneWidget);
    expect(backend.sentInputs, isEmpty);
    await tester.tap(find.text('Huỷ bỏ'));
    await tester.pumpAndSettle();
    expect(backend.sentInputs, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop panels resize and reset without blocking terminal', (
    tester,
  ) async {
    final backend = _ToolBackend();
    await _boot(tester, backend);
    final sidebar = find.byKey(const Key('sidebarResizeHandle'));
    final originalX = tester.getCenter(sidebar).dx;
    await tester.drag(sidebar, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(sidebar).dx - originalX, inInclusiveRange(35, 60));
    await tester.tap(sidebar);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(sidebar);
    await tester.pumpAndSettle();
    expect(tester.getCenter(sidebar).dx, closeTo(originalX, 1));
    final sftp = find.byKey(const Key('sftpResizeHandle'));
    final sftpX = tester.getCenter(sftp).dx;
    await tester.drag(sftp, const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(sftpX - tester.getCenter(sftp).dx, inInclusiveRange(25, 50));
    await tester.tap(find.byType(TerminalView).first);
    await tester.pump(const Duration(milliseconds: 350));
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(backend.sentInputs, contains('\x03'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile terminal tools fit larger accessible text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _boot(tester, _ToolBackend(), size: const Size(360, 740));
    await tester.tap(find.byKey(const Key('mobileTerminalFindBtn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('terminalSearchField')),
      'alpha',
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
