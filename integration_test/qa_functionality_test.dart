// Native integration coverage against the explicitly controlled QA SSH/SFTP
// fixture (cargo run -p core-transport --example qa_ssh_server).
// No production SSH hosts, shell fixture commands, or user files are modified.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:xterm/xterm.dart';

import 'qa_host_trust.dart';

class _QaApp {
  const _QaApp(this.container, this.directory, this.host, this.captureKey);

  final ProviderContainer container;
  final Directory directory;
  final HostDto? host;
  final GlobalKey captureKey;

  CoreBackend get backend => container.read(backendProvider);
  SessionManagerController get manager =>
      container.read(sessionManagerProvider.notifier);
  WorkspaceState get workspace => container.read(sessionManagerProvider);
  TerminalSessionTab get active => workspace.activeTab!;
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String reason,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await approveControlledQaHostPrompt(tester);
    if (predicate()) return;
  }
  fail(reason);
}

Future<_QaApp> _boot(WidgetTester tester, {bool connectFixture = true}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  tester.testTextInput.register();
  final directory = await Directory.systemTemp.createTemp(
    'termpulse_qa_functionality_',
  );
  final container = ProviderContainer();
  final captureKey = GlobalKey();
  final backend = container.read(backendProvider);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    final manager = container.read(sessionManagerProvider.notifier);
    for (final tab in container.read(sessionManagerProvider).tabs.toList()) {
      await manager.closeTab(tab.localKey);
    }
    container.dispose();
    await backend.vaultLock();
    tester.testTextInput.unregister();
    tester.view.reset();
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  await container
      .read(vaultProvider.notifier)
      .initAtPath('${directory.path}/vault.db');
  expect(
    await container.read(vaultProvider.notifier).unlock('QA-functional-2026!'),
    isTrue,
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: UncontrolledProviderScope(
        container: container,
        child: const TermPulseApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('desktopShell')), findsOneWidget);
  if (!connectFixture) return _QaApp(container, directory, null, captureKey);

  final inventory = container.read(inventoryProvider.notifier);
  await inventory.saveCredentialAndIdentity(
    cred: const CredentialDto(
      id: 'qa_functional_secret',
      name: 'Controlled QA fixture credential',
      kind: 'password',
      secret: 'termpulse2026',
      storageBackend: 'vault',
    ),
    identity: const IdentityDto(
      id: 'qa_functional_identity',
      name: 'Controlled QA fixture identity',
      username: 'ops',
      credentialId: 'qa_functional_secret',
    ),
  );
  const host = HostDto(
    id: 'qa_functional_host',
    label: 'Controlled QA fixture',
    protocol: 'ssh',
    hostname: '127.0.0.1',
    port: 22220,
    identityMode: 'by_id',
    identityId: 'qa_functional_identity',
    jumpHostMode: 'none',
    proxyMode: 'none',
    envTag: 'prod',
    tags: ['controlled-fixture'],
    notes: 'Integration test fixture only',
    env: [],
    isFavorite: false,
  );
  await inventory.saveHost(host);
  final approvalsBeforeConnect = controlledQaHostApprovals;
  await container.read(sessionManagerProvider.notifier).openHostSession(host);
  final app = _QaApp(container, directory, host, captureKey);
  await _waitUntil(
    tester,
    () =>
        app.workspace.activeTab?.sessionId != null &&
        app.active.terminal.buffer.getText().contains('WELCOME_TERMPULSE') &&
        app.active.cwd == '/home/ops/app' &&
        app.active.sftpEntries.any((entry) => entry.name == 'main.rs'),
    reason: 'Controlled QA SSH/SFTP fixture did not connect on127.0.0.1:22220',
  );
  expect(
    controlledQaHostApprovals,
    approvalsBeforeConnect + 1,
    reason: 'The first SSH connection must exercise real first-use approval',
  );
  final capabilities =
      jsonDecode(
            await backend.sftpReadText(
              app.active.sessionId!,
              '/home/ops/app/.termpulse-qa-fixture.json',
            ),
          )
          as Map<String, dynamic>;
  expect(capabilities['fixture'], 'termpulse-controlled-ssh');
  return app;
}

Future<void> _typeTerminal(WidgetTester tester, String command) async {
  await tester.tap(find.byType(TerminalView).first);
  await tester.pump();
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final prefix = tester.testTextInput.editingState?['text'] as String? ?? '';
  final value = '$prefix$command';
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ),
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

Future<void> _entryAction(
  WidgetTester tester,
  String name,
  String menuLabel,
) async {
  final row = find.ancestor(
    of: find.text(name),
    matching: find.byType(ListTile),
  );
  expect(row, findsOneWidget);
  await tester.ensureVisible(row);
  await tester.tap(
    find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(menuLabel).last);
  await tester.pumpAndSettle();
}

TransferJobState _job(_QaApp app, String name) =>
    app.workspace.transfers.firstWhere((job) => job.fileName == name);

Future<void> _captureDesktop(WidgetTester tester, _QaApp app) async {
  await tester.pump(const Duration(milliseconds: 250));
  final boundary =
      app.captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  final screenshot = await boundary.toImage(pixelRatio: 1);
  final bytes = await screenshot.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory(
    Platform.environment['TERMPULSE_QA_SCREENSHOT_DIR'] ??
        'build/qa_screenshots/pc',
  );
  await output.create(recursive: true);
  final file = File('${output.path}/qa_functionality_modern_desktop.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  expect(await file.length(), greaterThan(5000));
  screenshot.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('real SFTP fixture create rename chmod and delete round trip', (
    tester,
  ) async {
    final app = await _boot(tester);
    await tester.tap(find.byKey(const Key('terminalFindBtn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('terminalSearchField')),
      'WELCOME_TERMPULSE',
    );
    await tester.pumpAndSettle();
    final searchCount = tester.widget<Text>(
      find.byKey(const Key('terminalSearchCount')),
    );
    expect(searchCount.data, isNot('0/0'));
    expect(searchCount.data, matches(RegExp(r'^[1-9]\d*/[1-9]\d*')));
    await _captureDesktop(tester, app);
    await tester.tap(find.byTooltip('Đóng tìm kiếm / Close search'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('terminalSearchField')), findsNothing);
    final session = app.active.sessionId!;
    final key = app.active.localKey;
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final initialName = 'qa_functional_$suffix';
    final name = '${initialName}_renamed';
    final path = '/home/ops/app/$name';
    addTearDown(() async {
      // Every cleanup target was generated inside this fixture's temp root.
      for (final dir in ['/home/ops/app/$initialName', path]) {
        for (final file in ['payload.txt', 'renamed.txt']) {
          try {
            await app.backend.sftpDeleteEntry(session, '$dir/$file', false);
          } catch (_) {}
        }
        try {
          await app.backend.sftpDeleteEntry(session, dir, true);
        } catch (_) {}
      }
    });

    await tester.tap(find.byTooltip('Tạo thư mục'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Tên thư mục'),
      initialName,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Tạo'));
    await _waitUntil(
      tester,
      () => app.active.sftpEntries.any((entry) => entry.name == initialName),
      reason: 'Folder creation did not appear in the real SFTP listing',
    );
    await _entryAction(tester, initialName, 'Đổi tên…');
    await tester.enterText(find.widgetWithText(TextField, 'Tên mới'), name);
    await tester.tap(find.widgetWithText(FilledButton, 'Lưu'));
    await _waitUntil(
      tester,
      () => app.active.sftpEntries.any((entry) => entry.name == name),
      reason: 'Folder rename did not update the real SFTP listing',
    );

    // Permissions currently have a backend action, with the actual server mode
    // shown in the visible listing. The fixture applies real Unix permissions.
    await app.backend.sftpSetPermissions(session, path, 0x1c0);
    await app.manager.loadSftpDirectory(key, '/home/ops/app');
    expect(
      app.active.sftpEntries
              .firstWhere((entry) => entry.name == name)
              .permissions &
          0xfff,
      0x1c0,
    );
    await tester.pumpAndSettle();
    expect(find.text('Thư mục · 700'), findsOneWidget);
    await tester.tap(find.text(name));
    await _waitUntil(
      tester,
      () => app.active.cwd == path && !app.active.sftpLoading,
      reason: 'Could not open the new fixture directory',
    );

    const content = 'Tiếng Việt and UTF-8 😺\r\nsecond line\n';
    await app.backend.sftpWriteText(session, '$path/payload.txt', content);
    await app.manager.loadSftpDirectory(key, path);
    await tester.pumpAndSettle();
    await _entryAction(tester, 'payload.txt', 'Đổi tên…');
    await tester.enterText(
      find.widgetWithText(TextField, 'Tên mới'),
      'renamed.txt',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Lưu'));
    await _waitUntil(
      tester,
      () => app.active.sftpEntries.any((entry) => entry.name == 'renamed.txt'),
      reason: 'File rename did not update the real SFTP listing',
    );
    expect(
      await app.backend.sftpReadText(session, '$path/renamed.txt'),
      content,
    );
    await app.backend.sftpSetPermissions(session, '$path/renamed.txt', 0x180);
    expect(
      await app.backend.sftpReadText(session, '$path/renamed.txt'),
      content,
      reason: 'Changing permissions must preserve every byte of file content',
    );
    await app.manager.loadSftpDirectory(key, path);
    expect(app.active.sftpEntries.single.permissions & 0xfff, 0x180);
    await tester.pumpAndSettle();
    expect(find.textContaining('· 600'), findsOneWidget);

    await _entryAction(tester, 'renamed.txt', 'Xoá');
    await tester.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await _waitUntil(
      tester,
      () => app.active.sftpEntries.isEmpty && !app.active.sftpLoading,
      reason: 'Confirmed file deletion did not remove the remote file',
    );
    await app.manager.loadSftpDirectory(key, '/home/ops/app');
    await tester.pumpAndSettle();
    await _entryAction(tester, name, 'Xoá');
    await tester.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await _waitUntil(
      tester,
      () =>
          !app.active.sftpLoading &&
          !app.active.sftpEntries.any((entry) => entry.name == name),
      reason: 'Confirmed folder deletion did not remove the remote directory',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real local PTY accepts keyboard Ctrl+C and reconnect',
    (tester) async {
      final app = await _boot(tester, connectFixture: false);
      await tester.tap(find.byTooltip('Local Shell').first);
      await _waitUntil(
        tester,
        () => app.workspace.activeTab?.sessionId != null,
        reason: 'Native local PTY did not open',
      );
      final key = app.active.localKey;
      await _typeTerminal(tester, "printf '\\nQA_LOCAL_%s\\n' READY");
      await _waitUntil(
        tester,
        () => app.active.terminal.buffer.getText().contains('QA_LOCAL_READY'),
        reason: 'Keyboard text did not reach the real local shell',
      );
      await _typeTerminal(tester, 'sleep 30');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _typeTerminal(tester, "printf '\\nQA_CTRL_C_%s\\n' READY");
      await _waitUntil(
        tester,
        () => app.active.terminal.buffer.getText().contains('QA_CTRL_C_READY'),
        reason: 'Ctrl+C did not interrupt sleep and return the local shell',
        timeout: const Duration(seconds: 10),
      );
      await _typeTerminal(tester, 'exit');
      await _waitUntil(
        tester,
        () => app.active.closed,
        reason: 'Exiting the real shell did not close its terminal state',
      );
      expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('terminalReconnectBtn')));
      await _waitUntil(
        tester,
        () => !app.active.closed && app.active.sessionId != null,
        reason: 'Reconnect did not open a fresh native PTY',
      );
      expect(app.active.localKey, key);
      expect(app.workspace.tabs, hasLength(1));
      await _typeTerminal(tester, "printf '\\nQA_RECONNECT_%s\\n' READY");
      await _waitUntil(
        tester,
        () =>
            app.active.terminal.buffer.getText().contains('QA_RECONNECT_READY'),
        reason: 'Reconnected PTY did not accept real keyboard input',
      );
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isAndroid || Platform.isIOS,
  );

  testWidgets('real loopback Telnet fixture negotiates echoes and closes', (
    tester,
  ) async {
    final app = await _boot(tester, connectFixture: false);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clients = <Socket>[];
    final received = <int>[];
    final accepted = server.listen((socket) {
      clients.add(socket);
      socket.add([255, 251, 1, ...utf8.encode('QA_TELNET_READY\r\n')]);
      socket.listen((bytes) {
        received.addAll(bytes);
        if (bytes.contains(13) || bytes.contains(10)) {
          socket.add(utf8.encode('QA_TELNET_ECHO_CONFIRMED\r\n'));
        }
      }, onError: (Object _) {});
    });
    addTearDown(() async {
      for (final client in clients) {
        client.destroy();
      }
      await accepted.cancel();
      await server.close();
    });
    await app.manager.openTelnet(
      '127.0.0.1',
      server.port,
      label: 'Controlled Telnet fixture',
    );
    await _waitUntil(
      tester,
      () =>
          app.workspace.activeTab?.sessionId != null &&
          app.active.terminal.buffer.getText().contains('QA_TELNET_READY'),
      reason: 'Real Telnet backend did not render the loopback fixture banner',
    );
    await _typeTerminal(tester, 'qa_telnet_input');
    await _waitUntil(
      tester,
      () => app.active.terminal.buffer.getText().contains(
        'QA_TELNET_ECHO_CONFIRMED',
      ),
      reason: 'Real Telnet backend did not transmit keyboard input',
    );
    expect(
      List.generate(
        received.length - 2,
        (index) =>
            received[index] == 255 &&
            received[index + 1] == 253 &&
            received[index + 2] == 1,
      ).any((match) => match),
      isTrue,
      reason: 'Telnet WILL ECHO was not acknowledged',
    );
    expect(
      utf8.decode(received, allowMalformed: true),
      contains('qa_telnet_input'),
    );
    for (final client in clients) {
      await client.close();
    }
    await _waitUntil(
      tester,
      () => app.active.closed,
      reason:
          'Closing the Telnet fixture did not mark the session disconnected',
    );
    expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'paced real SFTP transfer pause resume cancel and download integrity',
    (tester) async {
      final app = await _boot(tester);
      final session = app.active.sessionId!;
      final key = app.active.localKey;
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final uploadName = 'qa_transfer_$suffix.bin';
      final cancelName = 'qa_transfer_cancel_$suffix.bin';
      final payload = Uint8List.fromList(
        List<int>.generate(4 * 1024 * 1024, (i) => i % 251),
      );
      final upload = File('${app.directory.path}/upload.bin');
      await upload.writeAsBytes(payload);
      addTearDown(() async {
        for (final name in [uploadName, cancelName]) {
          try {
            await app.backend.sftpDeleteEntry(
              session,
              '/home/ops/app/$name',
              false,
            );
          } catch (_) {}
        }
      });
      final capabilities =
          jsonDecode(
                await app.backend.sftpReadText(
                  session,
                  '/home/ops/app/.termpulse-qa-fixture.json',
                ),
              )
              as Map<String, dynamic>;
      expect(
        capabilities['writeDelayMs'],
        greaterThanOrEqualTo(10),
        reason:
            'Start the controlled fixture with at least10ms/write for deterministic controls',
      );
      await tester.tap(find.textContaining('Transfers (').first);
      await tester.pumpAndSettle();
      await app.manager.enqueueTransfer(
        localKey: key,
        isUpload: true,
        localPath: upload.path,
        remotePath: '/home/ops/app/$uploadName',
        fileName: uploadName,
      );
      await _waitUntil(
        tester,
        () => app.workspace.transfers.any(
          (job) =>
              job.fileName == uploadName && job.bytesDone > 0 && !job.finished,
        ),
        reason: 'Paced real SFTP upload did not expose in-progress state',
      );
      await tester.tap(find.byTooltip('Tạm dừng truyền').first);
      await _waitUntil(
        tester,
        () => _job(app, uploadName).paused,
        reason: 'Pause control did not acknowledge the real transfer',
      );
      await tester.pump(const Duration(milliseconds: 300));
      final pausedAt = _job(app, uploadName).bytesDone;
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _job(app, uploadName).bytesDone,
        pausedAt,
        reason: 'Actual transfer kept progressing after its pause settled',
      );
      expect(_job(app, uploadName).finished, isFalse);
      await tester.tap(find.byTooltip('Tiếp tục truyền').first);
      await _waitUntil(
        tester,
        () => _job(app, uploadName).finished,
        reason: 'Resumed real SFTP upload did not complete',
        timeout: const Duration(seconds: 45),
      );
      expect(_job(app, uploadName).error, isNull);
      expect(_job(app, uploadName).bytesDone, payload.length);

      final download = File('${app.directory.path}/download.bin');
      await app.manager.enqueueTransfer(
        localKey: key,
        isUpload: false,
        localPath: download.path,
        remotePath: '/home/ops/app/$uploadName',
        fileName: 'download_integrity.bin',
      );
      await _waitUntil(
        tester,
        () => app.workspace.transfers.any(
          (job) => job.fileName == 'download_integrity.bin' && job.finished,
        ),
        reason: 'Real SFTP download did not complete',
      );
      expect(_job(app, 'download_integrity.bin').error, isNull);
      final downloaded = await download.readAsBytes();
      expect(downloaded.length, payload.length);
      expect(
        downloaded.indexed.every((item) => item.$2 == payload[item.$1]),
        isTrue,
        reason: 'Downloaded bytes differ from the uploaded fixture payload',
      );

      await app.manager.enqueueTransfer(
        localKey: key,
        isUpload: true,
        localPath: upload.path,
        remotePath: '/home/ops/app/$cancelName',
        fileName: cancelName,
      );
      await _waitUntil(
        tester,
        () => app.workspace.transfers.any(
          (job) =>
              job.fileName == cancelName && job.bytesDone > 0 && !job.finished,
        ),
        reason: 'Paced cancellation upload did not begin',
      );
      await tester.tap(find.byTooltip('Huỷ truyền file').first);
      await _waitUntil(
        tester,
        () => _job(app, cancelName).finished,
        reason: 'Cancel control did not settle the real transfer',
      );
      expect(_job(app, cancelName).cancelled, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      final partial = (await app.backend.sftpListDirectory(
        session,
        '/home/ops/app',
      )).entries.firstWhere((entry) => entry.name == cancelName).size;
      expect(partial, greaterThan(BigInt.zero));
      expect(partial, lessThan(BigInt.from(payload.length)));
      await tester.pump(const Duration(milliseconds: 400));
      final stopped = (await app.backend.sftpListDirectory(
        session,
        '/home/ops/app',
      )).entries.firstWhere((entry) => entry.name == cancelName).size;
      expect(
        stopped,
        partial,
        reason: 'Cancelled transfer continued writing to the fixture',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real guarded multiline cancel confirm and recipient snapshot', (
    tester,
  ) async {
    final app = await _boot(tester);
    const command = 'echo QA_GUARD_FIRST\necho QA_GUARD_SECOND';
    final field = find.byKey(const Key('composePaneField'));
    final send = find.byKey(const Key('composeSendButton'));
    await tester.enterText(field, command);
    await tester.tap(send);
    await _waitUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
      reason: 'Real command guard did not request multiline confirmation',
    );
    await tester.tap(find.text('Huỷ bỏ'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, command);
    expect(
      app.active.terminal.buffer.getText(),
      isNot(contains('executed: echo QA_GUARD_FIRST')),
    );
    await tester.tap(send);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xác nhận chạy'));
    await _waitUntil(
      tester,
      () => app.active.terminal.buffer.getText().contains(
        'executed: echo QA_GUARD_SECOND',
      ),
      reason:
          'Confirmed multiline commands did not reach the controlled SSH fixture',
    );
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    app.manager.toggleBroadcast();
    const snapshotCommand = 'echo QA_SNAPSHOT_FIRST\necho QA_SNAPSHOT_SECOND';
    await tester.enterText(field, snapshotCommand);
    await tester.tap(send);
    await _waitUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
      reason: 'Broadcast multiline guard did not open',
    );
    await app.manager.openHostSession(app.host!);
    await _waitUntil(
      tester,
      () =>
          app.workspace.tabs.length == 2 &&
          app.workspace.tabs.last.sessionId != null,
      reason: 'Second controlled fixture connection did not become ready',
    );
    app.manager.setActiveTab(0);
    await tester.tap(find.text('Xác nhận chạy'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, snapshotCommand);
    expect(app.workspace.lastError, contains('thay đổi'));
    for (final tab in app.workspace.tabs) {
      expect(
        tab.terminal.buffer.getText(),
        isNot(contains('executed: echo QA_SNAPSHOT')),
        reason: 'A changed recipient set received an unconfirmed command',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
