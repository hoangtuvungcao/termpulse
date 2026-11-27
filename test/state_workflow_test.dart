import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';

import 'state_regression_test.dart'
    show ControlledBackend, exampleHost, flushEvents;

class _WorkflowBackend extends ControlledBackend {
  final transferActions = <String>[];
  final broadcastPayloads = <({List<String> sessions, String text})>[];
  Future<void> Function(String action)? transferControl;

  @override
  Future<void> sftpControlTransfer(String transferId, String action) async {
    transferActions.add('$transferId:$action');
    await transferControl?.call(action);
  }

  @override
  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows) =>
      connectQuickSsh(target: hostId, cols: cols, rows: rows);

  @override
  Future<int> broadcastSessionInput(
    List<String> sessionIds,
    List<int> data,
  ) async {
    broadcastPayloads.add((
      sessions: List.of(sessionIds),
      text: utf8.decode(data),
    ));
    return super.broadcastSessionInput(sessionIds, data);
  }
}

void main() {
  late _WorkflowBackend backend;
  late ProviderContainer container;
  late SessionManagerController manager;

  setUp(() {
    backend = _WorkflowBackend();
    container = ProviderContainer(
      overrides: [backendProvider.overrideWithValue(backend)],
    );
    manager = container.read(sessionManagerProvider.notifier);
  });

  tearDown(() => container.dispose());

  Future<TerminalSessionTab> connect() async {
    await manager.openQuickSsh(target: 'server.example');
    backend.connections.last.add(
      TerminalEventDto(
        kind: 'session_opened',
        text: 'session_${backend.connections.length}',
      ),
    );
    await flushEvents();
    return container.read(sessionManagerProvider).activeTab!;
  }

  Future<void> startTransfer(TerminalSessionTab tab) async {
    await manager.enqueueTransfer(
      localKey: tab.localKey,
      isUpload: true,
      localPath: '/tmp/local',
      remotePath: '/remote',
      fileName: 'local',
    );
    backend.transfer.add(
      TransferProgressDto(
        transferId: 'transfer',
        bytesDone: BigInt.one,
        bytesTotal: BigInt.from(100),
        finished: false,
      ),
    );
    await flushEvents();
  }

  test(
    'disabled Follow keeps browser directory independent of shell cwd',
    () async {
      final tab = await connect();
      manager.toggleFollowSftp(tab.localKey);
      await manager.loadSftpDirectory(tab.localKey, '/browsing');
      backend.directoryCalls.clear();
      backend.connections.single.add(
        const TerminalEventDto(kind: 'cwd_changed', text: '/shell'),
      );
      await flushEvents();
      final current = container.read(sessionManagerProvider).activeTab!;
      expect(current.cwd, '/browsing');
      expect(current.terminalCwd, '/shell');
      expect(backend.directoryCalls, isEmpty);

      manager.toggleFollowSftp(tab.localKey);
      await flushEvents();
      expect(backend.directoryCalls, ['session_1:/shell']);
      expect(container.read(sessionManagerProvider).activeTab!.cwd, '/shell');
    },
  );

  test('turning Follow off invalidates pending navigation and cd', () async {
    final tab = await connect();
    final response = Completer<SftpListingDto>();
    backend.directoryRequest = (_, _) => response.future;
    final navigation = manager.loadSftpDirectory(
      tab.localKey,
      '/pending',
      syncTerminal: true,
    );
    manager.toggleFollowSftp(tab.localKey);
    response.complete(const SftpListingDto(cwd: '/pending', entries: []));
    await navigation;
    final current = container.read(sessionManagerProvider).activeTab!;
    expect(current.cwd, '~');
    expect(current.sftpLoading, isFalse);
    expect(current.followSftpEnabled, isFalse);
    expect(backend.inputs, isEmpty);
  });

  test('guard snapshot rejects changed broadcast recipients', () async {
    final first = await connect();
    manager.toggleBroadcast();
    final snapshot = container.read(sessionManagerProvider);
    final expected = snapshot.broadcastTargets
        .map((t) => t.sessionId!)
        .toList();
    await connect();
    manager.setActiveTab(0);
    expect(
      await manager.sendTextToActive(
        'dangerous command\n',
        broadcastIfEnabled: true,
        expectedActiveKey: first.localKey,
        expectedSessionIds: expected,
        expectedBroadcastMode: snapshot.broadcastMode,
      ),
      isFalse,
    );
    expect(backend.inputs, isEmpty);
    expect(backend.broadcasts, isEmpty);
    expect(
      container.read(sessionManagerProvider).lastError,
      contains('thay đổi'),
    );
  });

  test('guard snapshot rejects mode and active-session changes', () async {
    final first = await connect();
    manager.toggleBroadcast();
    expect(
      await manager.sendTextToActive(
        'command',
        broadcastIfEnabled: true,
        expectedActiveKey: first.localKey,
        expectedSessionIds: [first.sessionId!],
        expectedBroadcastMode: false,
      ),
      isFalse,
    );
    manager.toggleBroadcast();
    await connect();
    expect(
      await manager.sendTextToActive(
        'command',
        expectedActiveKey: first.localKey,
        expectedSessionIds: [first.sessionId!],
        expectedBroadcastMode: false,
      ),
      isFalse,
    );
    expect(backend.inputs, isEmpty);
    expect(backend.broadcasts, isEmpty);
  });

  test(
    'unchanged guard snapshot sends once to the confirmed recipients',
    () async {
      await connect();
      await connect();
      manager.toggleBroadcast();
      final snapshot = container.read(sessionManagerProvider);
      final targets = snapshot.broadcastTargets
          .map((t) => t.sessionId!)
          .toList();
      expect(
        await manager.sendTextToActive(
          'confirmed command',
          broadcastIfEnabled: true,
          expectedActiveKey: snapshot.activeTab!.localKey,
          expectedSessionIds: targets.reversed.toList(),
          expectedBroadcastMode: true,
        ),
        isTrue,
      );
      expect(backend.broadcasts, [targets]);
    },
  );

  for (final change in [
    'broadcast recipients',
    'closed recipient',
    'broadcast mode',
    'active session',
  ]) {
    test('queued guard rechecks $change before sending', () async {
      final first = await connect();
      final second = await connect();
      manager.setActiveTab(0);
      final gate = Completer<void>();
      backend.inputGate = gate.future;
      final preceding = manager.sendTextToActive('preceding input');
      await flushEvents();
      manager.toggleBroadcast();
      final snapshot = container.read(sessionManagerProvider);
      final guarded = manager.sendTextToActive(
        'confirmed command\n',
        broadcastIfEnabled: true,
        bracketedPaste: change == 'broadcast recipients',
        expectedActiveKey: first.localKey,
        expectedSessionIds: snapshot.broadcastTargets
            .map((tab) => tab.sessionId!)
            .toList(),
        expectedBroadcastMode: true,
      );
      await flushEvents();
      expect(backend.inputs, ['preceding input']);
      expect(backend.broadcasts, isEmpty);

      switch (change) {
        case 'broadcast recipients':
          manager.toggleTabBroadcast(second.localKey);
        case 'closed recipient':
          backend.connections[1].add(const TerminalEventDto(kind: 'closed'));
          await flushEvents();
        case 'broadcast mode':
          manager.toggleBroadcast();
        case 'active session':
          manager.setActiveTab(1);
      }
      gate.complete();
      expect(await preceding, isTrue);
      expect(await guarded, isFalse);
      expect(backend.inputs, ['preceding input']);
      expect(backend.broadcasts, isEmpty);
      expect(
        container.read(sessionManagerProvider).lastError,
        contains('thay đổi'),
      );
    });
  }

  test('queued unchanged guard sends to all confirmed recipients', () async {
    final first = await connect();
    await connect();
    manager.setActiveTab(0);
    final gate = Completer<void>();
    backend.inputGate = gate.future;
    final preceding = manager.sendTextToActive('preceding input');
    await flushEvents();
    manager.toggleBroadcast();
    final snapshot = container.read(sessionManagerProvider);
    final targets = snapshot.broadcastTargets
        .map((tab) => tab.sessionId!)
        .toList();
    final guarded = manager.sendTextToActive(
      'confirmed command\n',
      broadcastIfEnabled: true,
      expectedActiveKey: first.localKey,
      expectedSessionIds: targets,
      expectedBroadcastMode: true,
    );
    await flushEvents();
    expect(backend.broadcasts, isEmpty);
    gate.complete();
    expect(await preceding, isTrue);
    expect(await guarded, isTrue);
    expect(backend.broadcasts, [targets]);
  });

  test('late pause response cannot mark a completed transfer paused', () async {
    final tab = await connect();
    await startTransfer(tab);
    final response = Completer<void>();
    backend.transferControl = (_) => response.future;
    final pause = manager.controlTransfer('transfer', 'pause');
    await flushEvents();
    backend.transfer.add(
      TransferProgressDto(
        transferId: 'transfer',
        bytesDone: BigInt.from(100),
        bytesTotal: BigInt.from(100),
        finished: true,
      ),
    );
    await flushEvents();
    response.complete();
    await pause;
    final job = container.read(sessionManagerProvider).transfers.single;
    expect(job.finished, isTrue);
    expect(job.paused, isFalse);
  });

  test(
    'transfer controls execute in user order despite pending responses',
    () async {
      final tab = await connect();
      await startTransfer(tab);
      final response = Completer<void>();
      backend.transferControl = (action) async {
        if (action == 'pause') await response.future;
      };
      final pause = manager.controlTransfer('transfer', 'pause');
      final resume = manager.controlTransfer('transfer', 'resume');
      await flushEvents();
      expect(backend.transferActions, ['transfer:pause']);
      response.complete();
      await Future.wait([pause, resume]);
      expect(backend.transferActions, ['transfer:pause', 'transfer:resume']);
      expect(
        container.read(sessionManagerProvider).transfers.single.paused,
        isFalse,
      );
    },
  );

  test('paste honors bracketed mode for each broadcast recipient', () async {
    final first = await connect();
    final second = await connect();
    first.terminal.write('\x1b[?2004h');
    expect(first.terminal.bracketedPasteMode, isTrue);
    expect(second.terminal.bracketedPasteMode, isFalse);
    manager.toggleBroadcast();
    expect(
      await manager.sendTextToActive(
        'echo first\necho second',
        broadcastIfEnabled: true,
        bracketedPaste: true,
      ),
      isTrue,
    );
    expect(backend.broadcastPayloads, hasLength(2));
    expect(backend.broadcastPayloads[0].sessions, [first.sessionId!]);
    expect(
      backend.broadcastPayloads[0].text,
      '\x1b[200~echo first\necho second\x1b[201~',
    );
    expect(backend.broadcastPayloads[1].sessions, [second.sessionId!]);
    expect(backend.broadcastPayloads[1].text, 'echo first\necho second');
  });

  test(
    'mixed-mode paste waits for every recipient before rechecking its snapshot',
    () async {
      final first = await connect();
      final second = await connect();
      first.terminal.setBracketedPasteMode(true);
      manager.setActiveTab(0);
      final gate = Completer<void>();
      backend.inputGate = gate.future;
      final preceding = manager.sendTextToActive('preceding input');
      await flushEvents();
      manager.toggleBroadcast();
      final snapshot = container.read(sessionManagerProvider);
      final paste = manager.sendTextToActive(
        'echo first\necho second',
        broadcastIfEnabled: true,
        bracketedPaste: true,
        expectedActiveKey: first.localKey,
        expectedSessionIds: snapshot.broadcastTargets
            .map((tab) => tab.sessionId!)
            .toList(),
        expectedBroadcastMode: true,
      );
      await flushEvents();
      manager.toggleTabBroadcast(second.localKey);
      gate.complete();
      expect(await preceding, isTrue);
      expect(await paste, isFalse);
      expect(backend.inputs, ['preceding input']);
      expect(backend.broadcastPayloads, isEmpty);
      expect(
        container.read(sessionManagerProvider).lastError,
        contains('thay đổi'),
      );
    },
  );

  test(
    'mixed-mode paste sends all groups after the shared queue is ready',
    () async {
      final first = await connect();
      final second = await connect();
      first.terminal.setBracketedPasteMode(true);
      manager.setActiveTab(0);
      final gate = Completer<void>();
      backend.inputGate = gate.future;
      final preceding = manager.sendTextToActive('preceding input');
      await flushEvents();
      manager.toggleBroadcast();
      final paste = manager.sendTextToActive(
        'echo first\necho second',
        broadcastIfEnabled: true,
        bracketedPaste: true,
        expectedActiveKey: first.localKey,
        expectedSessionIds: [first.sessionId!, second.sessionId!],
        expectedBroadcastMode: true,
      );
      await flushEvents();
      final groupsBeforeReady = List.of(backend.broadcastPayloads);
      gate.complete();
      expect(await preceding, isTrue);
      expect(await paste, isTrue);
      expect(groupsBeforeReady, isEmpty);
      expect(backend.broadcastPayloads.map((group) => group.sessions), [
        [first.sessionId!],
        [second.sessionId!],
      ]);
      expect(backend.broadcastPayloads.map((group) => group.text), [
        '\x1b[200~echo first\necho second\x1b[201~',
        'echo first\necho second',
      ]);
    },
  );

  test(
    'cancelled transfer stays distinct from a completed successful job',
    () async {
      final tab = await connect();
      await startTransfer(tab);
      await manager.controlTransfer('transfer', 'cancel');
      backend.transfer.add(
        TransferProgressDto(
          transferId: 'transfer',
          bytesDone: BigInt.from(100),
          bytesTotal: BigInt.from(100),
          finished: true,
        ),
      );
      await flushEvents();
      final job = container.read(sessionManagerProvider).transfers.single;
      expect(job.finished, isTrue);
      expect(job.cancelled, isTrue);
      expect(job.paused, isFalse);
      expect(job.bytesDone, 1);
      expect(job.error, isNull);
      expect(job.copyWith(paused: false).cancelled, isTrue);
      expect(
        const TransferJobState(
          transferId: 'complete',
          fileName: 'done',
          isUpload: true,
          finished: true,
        ).cancelled,
        isFalse,
      );
    },
  );

  test('reconnect keeps tab, scrollback and safety preferences', () async {
    final tab = await connect();
    tab.terminal.write('keep this output');
    manager.toggleTabBroadcast(tab.localKey);
    manager.toggleFollowSftp(tab.localKey);
    manager.setInputModifiers(ctrl: true, alt: true);
    tab.terminal.setBracketedPasteMode(true);
    tab.terminal.setCursorKeysMode(true);
    backend.connections.first.add(
      const TerminalEventDto(kind: 'closed', text: 'connection lost'),
    );
    await flushEvents();
    expect(await manager.reconnectTab(tab.localKey), isTrue);
    final reconnecting = container.read(sessionManagerProvider).activeTab!;
    expect(reconnecting.localKey, tab.localKey);
    expect(reconnecting.terminal, same(tab.terminal));
    expect(
      reconnecting.terminal.buffer.getText(),
      contains('keep this output'),
    );
    expect(reconnecting.sessionId, isNull);
    expect(reconnecting.closed, isFalse);
    expect(reconnecting.closeReason, isNull);
    expect(reconnecting.broadcastIncluded, isFalse);
    expect(reconnecting.followSftpEnabled, isFalse);
    expect(reconnecting.inputCtrl, isFalse);
    expect(reconnecting.inputAlt, isFalse);
    expect(reconnecting.terminal.bracketedPasteMode, isFalse);
    expect(reconnecting.terminal.cursorKeysMode, isFalse);
    expect(backend.closedSessions, ['session_1']);
    expect(backend.connections, hasLength(2));
    backend.connections.last.add(
      const TerminalEventDto(kind: 'session_opened', text: 'reconnected'),
    );
    await flushEvents();
    expect(container.read(sessionManagerProvider).tabs, hasLength(1));
    expect(await manager.sendTextToActive('ready'), isTrue);
    expect(backend.inputs, ['ready']);
  });

  test(
    'saved hosts and non-SSH sources reconnect without duplicate tabs',
    () async {
      for (final protocol in ['ssh', 'telnet', 'local_shell']) {
        if (protocol == 'ssh') {
          await manager.openHostSession(exampleHost);
        } else if (protocol == 'telnet') {
          await manager.openTelnet('server.example', 23);
        } else {
          await manager.openLocalShell();
        }
        final tab = container.read(sessionManagerProvider).activeTab!;
        backend.connections.last.add(
          const TerminalEventDto(kind: 'session_opened', text: 'original'),
        );
        backend.connections.last.add(const TerminalEventDto(kind: 'closed'));
        await flushEvents();
        final first = manager.reconnectTab(tab.localKey);
        final duplicate = manager.reconnectTab(tab.localKey);
        expect(await first, isTrue);
        expect(await duplicate, isFalse);
        expect(
          container.read(sessionManagerProvider).tabs.last.protocol,
          protocol,
        );
        expect(
          container.read(sessionManagerProvider).tabs.last.localKey,
          tab.localKey,
        );
        await manager.closeTab(tab.localKey);
        expect(await manager.reconnectTab(tab.localKey), isFalse);
      }
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
    },
  );
}
