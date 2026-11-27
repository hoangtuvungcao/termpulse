import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';

class ControlledBackend implements CoreBackend {
  final connections = <StreamController<TerminalEventDto>>[];
  final inputs = <String>[];
  final broadcasts = <List<String>>[];
  final closedSessions = <String>[];
  final directoryCalls = <String>[];
  final transfer = StreamController<TransferProgressDto>();
  Future<void>? inputGate;
  Object? inputError;
  Object? resizeError;
  Object? closeError;
  Future<List<HostDto>> Function()? hostsRequest;
  Future<SftpListingDto> Function(String, String)? directoryRequest;

  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) {
    final stream = StreamController<TerminalEventDto>();
    connections.add(stream);
    return stream.stream;
  }

  @override
  Future<void> sendSessionInput(String sessionId, List<int> data) async {
    if (inputError case final error?) throw error;
    inputs.add(utf8.decode(data));
    await inputGate;
  }

  @override
  Stream<TerminalEventDto> connectLocalShell({
    required int cols,
    required int rows,
    String? startupDir,
  }) => connectQuickSsh(target: 'local', cols: cols, rows: rows);

  @override
  Stream<TerminalEventDto> connectTelnetHost({
    required String hostname,
    required int port,
    String? label,
  }) => connectQuickSsh(target: hostname, cols: 80, rows: 24);

  @override
  Future<int> broadcastSessionInput(
    List<String> sessionIds,
    List<int> data,
  ) async {
    broadcasts.add(sessionIds);
    return sessionIds.length;
  }

  @override
  Future<void> resizeTerminal(String sessionId, int cols, int rows) async {
    if (resizeError case final error?) throw error;
  }

  @override
  Future<void> closeSession(String sessionId) async {
    closedSessions.add(sessionId);
    if (closeError case final error?) throw error;
  }

  @override
  Future<SftpListingDto> sftpListDirectory(
    String sessionId,
    String path,
  ) async {
    directoryCalls.add('$sessionId:$path');
    return directoryRequest == null
        ? SftpListingDto(cwd: path, entries: const [])
        : await directoryRequest!(sessionId, path);
  }

  @override
  Stream<TransferProgressDto> sftpStartTransfer({
    required String sessionId,
    required bool isUpload,
    required String localPath,
    required String remotePath,
  }) => transfer.stream;

  @override
  Future<void> sftpControlTransfer(String transferId, String action) async {}

  @override
  Future<List<GroupDto>> listGroups() async => [];
  @override
  Future<List<HostDto>> listHosts() async => await hostsRequest?.call() ?? [];
  @override
  Future<List<CredentialDto>> listCredentials() async => [];
  @override
  Future<List<IdentityDto>> listIdentities() async => [];
  @override
  Future<List<ProxyDto>> listProxies() async => [];
  @override
  Future<List<TunnelDto>> listTunnels() async => [];
  @override
  Future<List<SnippetDto>> listSnippets() async => [];
  @override
  Future<void> vaultLock() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const exampleHost = HostDto(
  id: 'host',
  label: 'Server',
  protocol: 'ssh',
  hostname: 'server.example',
  port: 22,
  identityMode: 'inherit',
  jumpHostMode: 'inherit',
  proxyMode: 'inherit',
  envTag: 'dev',
  tags: [],
  notes: '',
  env: [],
  isFavorite: false,
);

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  late ControlledBackend backend;
  late ProviderContainer container;
  late SessionManagerController manager;

  setUp(() {
    backend = ControlledBackend();
    container = ProviderContainer(
      overrides: [backendProvider.overrideWithValue(backend)],
    );
    manager = container.read(sessionManagerProvider.notifier);
  });

  tearDown(() {
    container.dispose();
  });

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

  test(
    'saved Telnet and Local Shell preserve production host metadata',
    () async {
      for (final protocol in ['telnet', 'local_shell']) {
        final host = HostDto(
          id: 'prod_$protocol',
          label: 'Production $protocol',
          protocol: protocol,
          hostname: 'production.example',
          port: 23,
          identityMode: 'inherit',
          jumpHostMode: 'inherit',
          proxyMode: 'inherit',
          envTag: 'prod',
          tags: const [],
          notes: '',
          env: const [],
          isFavorite: false,
        );
        await manager.openHostSession(host);
        final tab = container.read(sessionManagerProvider).activeTab!;
        expect(tab.hostId, host.id);
        expect(tab.title, host.label);
        expect(tab.envTag, 'prod');
      }
    },
  );

  test('terminal preserves Unicode split across transport packets', () async {
    final tab = await connect();
    final bytes = utf8.encode('Tiếng Việt 😺');
    for (final byte in bytes) {
      backend.connections.last.add(
        TerminalEventDto(
          kind: 'output_bytes',
          bytes: Uint8List.fromList([byte]),
        ),
      );
    }
    await flushEvents();
    expect(tab.terminal.buffer.getText(), contains('Tiếng Việt 😺'));
    expect(tab.terminal.buffer.getText(), isNot(contains('\uFFFD')));
  });

  test(
    'terminal writes remain ordered while an earlier write is pending',
    () async {
      final tab = await connect();
      final gate = Completer<void>();
      backend.inputGate = gate.future;
      tab.terminal.textInput('a');
      tab.terminal.textInput('b');
      await flushEvents();
      expect(backend.inputs, ['a']);
      gate.complete();
      await flushEvents();
      expect(backend.inputs, ['a', 'b']);
    },
  );

  test('typing and resize failures become visible state errors', () async {
    final tab = await connect();
    backend.inputError = StateError('write failed');
    tab.terminal.textInput('x');
    await flushEvents();
    expect(
      container.read(sessionManagerProvider).lastError,
      contains('write failed'),
    );
    backend.resizeError = StateError('resize failed');
    tab.terminal.resize(100, 40);
    await flushEvents();
    expect(
      container.read(sessionManagerProvider).lastError,
      contains('resize failed'),
    );
  });

  test('unchanged keyboard modifiers do not rebuild workspace state', () async {
    await connect();
    final before = container.read(sessionManagerProvider);
    manager.setInputModifiers(ctrl: false, alt: false);
    expect(container.read(sessionManagerProvider), same(before));

    manager.setInputModifiers(ctrl: true, alt: false);
    final modified = container.read(sessionManagerProvider);
    expect(modified.activeTab!.inputCtrl, isTrue);
    manager.setInputModifiers(ctrl: true, alt: false);
    expect(container.read(sessionManagerProvider), same(modified));
    manager.setInputModifiers(ctrl: false, alt: false);
    expect(
      container.read(sessionManagerProvider).activeTab!.inputCtrl,
      isFalse,
    );
  });

  test('explicit sends report delivery success and failure', () async {
    await connect();
    expect(await manager.sendTextToActive('success'), isTrue);
    backend.inputError = StateError('write failed');
    expect(await manager.sendTextToActive('failure'), isFalse);
    expect(
      container.read(sessionManagerProvider).lastError,
      contains('write failed'),
    );
  });

  test('soft keyboard consumes Ctrl and Alt exactly once', () async {
    final tab = await connect();
    manager.setInputModifiers(ctrl: true, alt: false);
    tab.terminal.textInput('c');
    tab.terminal.textInput('c');
    manager.setInputModifiers(ctrl: false, alt: true);
    tab.terminal.textInput('x');
    await flushEvents();
    expect(backend.inputs, ['\x03', 'c', '\x1bx']);
    final current = container.read(sessionManagerProvider).activeTab!;
    expect(current.inputCtrl, isFalse);
    expect(current.inputAlt, isFalse);
  });

  test(
    'each session independently follows terminal directory changes',
    () async {
      await connect();
      await connect();
      backend.directoryCalls.clear();
      backend.connections[0].add(
        const TerminalEventDto(kind: 'cwd_changed', text: '/first'),
      );
      backend.connections[1].add(
        const TerminalEventDto(kind: 'cwd_changed', text: '/second'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        backend.directoryCalls,
        containsAll(['session_1:/first', 'session_2:/second']),
      );
      expect(
        container.read(sessionManagerProvider).tabs.map((tab) => tab.cwd),
        ['/first', '/second'],
      );
    },
  );

  test(
    'a stale SFTP response cannot override newer navigation or run cd',
    () async {
      final tab = await connect();
      final oldListing = Completer<SftpListingDto>();
      final newListing = Completer<SftpListingDto>();
      backend.directoryRequest = (_, path) =>
          path == '/old' ? oldListing.future : newListing.future;
      final oldLoad = manager.loadSftpDirectory(
        tab.localKey,
        '/old',
        syncTerminal: true,
      );
      final newLoad = manager.loadSftpDirectory(
        tab.localKey,
        '/new',
        syncTerminal: true,
      );
      newListing.complete(const SftpListingDto(cwd: '/new', entries: []));
      await newLoad;
      oldListing.complete(const SftpListingDto(cwd: '/old', entries: []));
      await oldLoad;
      expect(container.read(sessionManagerProvider).activeTab!.cwd, '/new');
      expect(backend.inputs, ["cd '/new'\n"]);
    },
  );

  test('SFTP failures survive unrelated tab state changes', () async {
    final tab = await connect();
    backend.directoryRequest = (_, _) =>
        Future.error(StateError('SFTP denied'));
    await manager.loadSftpDirectory(tab.localKey, '/restricted');
    manager.clearTabAlert(tab.localKey);
    expect(
      container.read(sessionManagerProvider).activeTab!.sftpError,
      contains('SFTP denied'),
    );
  });

  test(
    'closing a preceding tab preserves selection and cleans up despite backend errors',
    () async {
      final first = await connect();
      final second = await connect();
      final third = await connect();
      await manager.closeTab(first.localKey);
      expect(
        container.read(sessionManagerProvider).activeTab!.localKey,
        third.localKey,
      );
      backend.closeError = StateError('already gone');
      await manager.closeTab(second.localKey);
      expect(
        container.read(sessionManagerProvider).tabs.map((tab) => tab.localKey),
        [third.localKey],
      );
      expect(
        container.read(sessionManagerProvider).lastError,
        contains('already gone'),
      );
    },
  );

  test(
    'a completed terminal stream is closed and rejects further input',
    () async {
      final tab = await connect();
      await backend.connections.last.close();
      expect(container.read(sessionManagerProvider).activeTab!.closed, isTrue);
      tab.terminal.textInput('ignored');
      await manager.sendTextToActive('ignored');
      await flushEvents();
      expect(backend.inputs, isEmpty);
    },
  );

  for (final code in [
    'SSH_AUTHENTICATION_REJECTED',
    'SSH_AUTHENTICATION_TIMEOUT',
    'SSH_AUTHENTICATION_INTERRUPTED',
    'SSH_CONNECTION',
    'SSH_HANDSHAKE',
  ]) {
    test(
      'terminal setup preserves $code after stream completion and retries',
      () async {
        await manager.openQuickSsh(target: 'server.example');
        final localKey = container
            .read(sessionManagerProvider)
            .activeTab!
            .localKey;
        final reason = 'AnyhowException($code: controlled diagnostic)';
        backend.connections.last.addError(reason);
        await flushEvents();
        await backend.connections.last.close();
        final failed = container.read(sessionManagerProvider);
        expect(failed.activeTab!.closed, isTrue);
        expect(failed.activeTab!.sessionId, isNull);
        expect(failed.activeTab!.closeReason, reason);
        expect(failed.lastError, reason);

        expect(await manager.reconnectTab(localKey), isTrue);
        backend.connections.last.add(
          const TerminalEventDto(kind: 'session_opened', text: 'retry_session'),
        );
        await flushEvents();
        final retried = container.read(sessionManagerProvider);
        expect(retried.activeTab!.closed, isFalse);
        expect(retried.activeTab!.sessionId, 'retry_session');
        expect(retried.activeTab!.closeReason, isNull);
        expect(retried.lastError, isNull);
      },
    );
  }

  test(
    'broadcast with no selected recipients does not send to a muted session',
    () async {
      final tab = await connect();
      manager.toggleTabBroadcast(tab.localKey);
      manager.toggleBroadcast();
      await manager.sendTextToActive('command\n', broadcastIfEnabled: true);
      expect(backend.inputs, isEmpty);
      expect(backend.broadcasts, isEmpty);
      expect(container.read(sessionManagerProvider).lastError, isNotNull);
    },
  );

  test(
    'transfer errors before the first progress event become failed jobs',
    () async {
      final tab = await connect();
      await manager.enqueueTransfer(
        localKey: tab.localKey,
        isUpload: true,
        localPath: '/tmp/local',
        remotePath: '/remote',
        fileName: 'local',
      );
      backend.transfer.addError(StateError('transfer failed'));
      await flushEvents();
      final job = container.read(sessionManagerProvider).transfers.single;
      expect(job.finished, isTrue);
      expect(job.error, contains('transfer failed'));
    },
  );

  test('cancelled transfer ignores late progress events', () async {
    final tab = await connect();
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
    await manager.controlTransfer('transfer', 'cancel');
    backend.transfer.add(
      TransferProgressDto(
        transferId: 'transfer',
        bytesDone: BigInt.two,
        bytesTotal: BigInt.from(100),
        finished: false,
      ),
    );
    await backend.transfer.close();
    final job = container.read(sessionManagerProvider).transfers.single;
    expect(job.finished, isTrue);
    expect(job.paused, isFalse);
    expect(job.error, isNull);
  });

  test('disposing workspace cancels transfers and closes sessions', () async {
    final tab = await connect();
    var cancelled = false;
    backend.transfer.onCancel = () {
      cancelled = true;
    };
    await manager.enqueueTransfer(
      localKey: tab.localKey,
      isUpload: true,
      localPath: '/tmp/local',
      remotePath: '/remote',
      fileName: 'local',
    );
    container.invalidate(sessionManagerProvider);
    container.read(sessionManagerProvider);
    await flushEvents();
    expect(cancelled, isTrue);
    expect(backend.closedSessions, contains('session_1'));
  });

  test(
    'newer inventory refresh wins and failed refresh preserves cached items',
    () async {
      final oldHosts = Completer<List<HostDto>>();
      final newHosts = Completer<List<HostDto>>();
      var count = 0;
      backend.hostsRequest = () =>
          count++ == 0 ? oldHosts.future : newHosts.future;
      final inventory = container.read(inventoryProvider.notifier);
      final first = inventory.refreshAll();
      final second = inventory.refreshAll();
      newHosts.complete([exampleHost]);
      await second;
      oldHosts.complete([]);
      await first;
      expect(container.read(inventoryProvider).hosts, [exampleHost]);
      backend.hostsRequest = () =>
          Future.error(StateError('vault unavailable'));
      await inventory.refreshAll();
      expect(container.read(inventoryProvider).hosts, [exampleHost]);
      expect(container.read(inventoryProvider).loading, isFalse);
      expect(
        container.read(inventoryProvider).error,
        contains('vault unavailable'),
      );
    },
  );

  test(
    'locking clears inventory and ignores an older refresh in flight',
    () async {
      final hosts = Completer<List<HostDto>>();
      backend.hostsRequest = () => hosts.future;
      final refresh = container.read(inventoryProvider.notifier).refreshAll();
      await container.read(vaultProvider.notifier).lock();
      hosts.complete([exampleHost]);
      await refresh;
      expect(container.read(inventoryProvider).hosts, isEmpty);
    },
  );
}
