import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:xterm/xterm.dart';

import 'qa_host_trust.dart';

Future<void> _capture(
  GlobalKey key,
  String outDir,
  String name,
  WidgetTester tester,
) async {
  await tester.pump(const Duration(milliseconds: 250));
  final ctx = key.currentContext;
  if (ctx == null || !ctx.mounted) {
    throw StateError('Capture boundary context missing for $name');
  }
  final boundary = ctx.findRenderObject()! as RenderRepaintBoundary;
  final img = await boundary.toImage(pixelRatio: 1.0);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  expect(bd, isNotNull, reason: 'PNG encode failed for $name');
  final bytes = bd!.buffer.asUint8List();
  final file = File('$outDir/$name.png');
  file.writeAsBytesSync(bytes);
  debugPrint('QA screenshot: $name');
  expect(
    file.lengthSync(),
    greaterThan(5000),
    reason: 'Screenshot $name too small',
  );
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() pred, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    await approveControlledQaHostPrompt(tester);
    if (pred()) return;
  }
  fail(reason ?? 'Timed out waiting for condition');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TermPulse PC Full Functional & UI/UX QA + 14 Screenshots', (
    tester,
  ) async {
    await RustLib.init();
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    tester.view.physicalSize = const Size(1400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const outDir = 'build/qa_screenshots/pc';
    Directory(outDir).createSync(recursive: true);

    final dbPath =
        '/tmp/termpulse_qa_pc_vault_${DateTime.now().millisecondsSinceEpoch}.db';
    final f = File(dbPath);
    if (f.existsSync()) f.deleteSync();
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(vaultProvider.notifier).initAtPath(dbPath);

    final shotKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const TermPulseApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Vault Setup screen
    expect(find.byKey(const Key('vaultPasswordField')), findsOneWidget);
    await _capture(shotKey, outDir, 'pc_01_vault_setup', tester);

    // Unlock & create master vault
    await tester.enterText(
      find.byKey(const Key('vaultPasswordField')),
      'MasterPass!2026',
    );
    await tester.enterText(
      find.byKey(const Key('vaultConfirmPasswordField')),
      'MasterPass!2026',
    );
    await tester.tap(find.byKey(const Key('vaultSubmitButton')));
    await _waitUntil(
      tester,
      () => find.byKey(const Key('desktopShell')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 45),
      reason: 'DesktopShell did not open after vault unlock',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('vaultWelcomeContinue')));
    await tester.pumpAndSettle();

    // 2. Host Editor Dialog
    await tester.tap(find.byKey(const Key('desktopAddHostBtn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Tên hiển thị (vd: prod-web-01) *'),
      'prod-web-01',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Hostname / IP *'),
      '127.0.0.1',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Port'), '22220');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'ops');
    await tester.enterText(
      find.widgetWithText(TextField, 'Mật khẩu (để trống nếu giữ cũ/kế thừa)'),
      'termpulse2026',
    );
    // Select PROD environment
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Môi trường'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROD (Cảnh báo)').last);
    await tester.pumpAndSettle();

    await _capture(shotKey, outDir, 'pc_02_host_dialog', tester);
    await tester.tap(find.text('Lưu Host'));
    await _waitUntil(
      tester,
      () => container
          .read(inventoryProvider)
          .hosts
          .any((h) => h.label == 'prod-web-01'),
      reason: 'prod-web-01 not saved',
    );
    await tester.pumpAndSettle();

    // Seed 2nd SSH host (staging-api), pinned snippet, and a local tunnel rule for QA scenarios
    final inv = container.read(inventoryProvider.notifier);
    final prodHost = container
        .read(inventoryProvider)
        .hosts
        .firstWhere((h) => h.label == 'prod-web-01');
    await inv.saveHost(
      HostDto(
        id: 'host_staging_api',
        label: 'staging-api',
        protocol: 'ssh',
        hostname: '127.0.0.1',
        port: 22220,
        identityMode: 'by_id',
        identityId: prodHost.identityId,
        jumpHostMode: 'none',
        proxyMode: 'none',
        envTag: 'staging',
        tags: const ['api', 'rust'],
        notes: 'QA staging host',
        env: const [],
        followTerminalSftp: true,
        isFavorite: true,
      ),
    );
    await inv.saveSnippet(
      const SnippetDto(
        id: 'snip_check_uname',
        scope: 'global',
        title: 'Kernel & Uptime',
        commandTpl: 'uname -a',
        pinButtonBar: true,
      ),
    );
    await inv.saveTunnel(
      TunnelDto(
        id: 'tun_web_18080',
        name: 'QA Web Forward',
        hostId: prodHost.id,
        kind: 'local',
        bindAddr: '127.0.0.1',
        bindPort: 19080,
        targetHost: '127.0.0.1',
        targetPort: 18080,
        autoStart: false,
      ),
    );
    await tester.pumpAndSettle();

    // 3. Connect SSH to prod-web-01 + Follow SFTP panel
    final approvalsBeforeConnect = controlledQaHostApprovals;
    await tester.tap(find.text('prod-web-01').first);
    await _waitUntil(tester, () {
      final ws = container.read(sessionManagerProvider);
      final tab = ws.activeTab;
      if (tab == null || tab.sessionId == null) return false;
      return tab.sftpEntries.any((e) => e.name == 'main.rs');
    }, reason: 'SSH or initial SFTP /home/ops/app listing did not populate');
    expect(
      controlledQaHostApprovals,
      approvalsBeforeConnect + 1,
      reason: 'The first SSH connection must exercise real first-use approval',
    );
    await tester.tap(find.byType(TerminalView).first);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final editingText =
        tester.testTextInput.editingState?['text'] as String? ?? '';
    final typedCommand = '${editingText}pwd';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: typedCommand,
        selection: TextSelection.collapsed(offset: typedCommand.length),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _waitUntil(
      tester,
      () => RegExp(r'\$ pwd\s*\n/home/ops/app').hasMatch(
        container
            .read(sessionManagerProvider)
            .activeTab!
            .terminal
            .buffer
            .getText(),
      ),
      reason:
          'Direct terminal keyboard input did not reach the live SSH session',
    );
    await container
        .read(sessionManagerProvider.notifier)
        .sendTextToActive('ls\n');
    await tester.pump(const Duration(milliseconds: 500));
    await _capture(shotKey, outDir, 'pc_03_workspace_ssh_sftp', tester);

    // 4. Bidirectional SFTP follow (cd /etc/nginx) + 2-pane Commander mode
    await container
        .read(sessionManagerProvider.notifier)
        .sendTextToActive('cd /etc/nginx\n');
    await _waitUntil(tester, () {
      final tab = container.read(sessionManagerProvider).activeTab;
      return tab != null &&
          tab.cwd == '/etc/nginx' &&
          tab.sftpEntries.any((e) => e.name == 'nginx.conf');
    }, reason: 'SFTP did not follow OSC-7 cd /etc/nginx');
    await tester.tap(find.byTooltip('Chế độ 2 ngăn Commander'));
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_04_sftp_commander', tester);

    // Turn off Commander mode so remote list is spacious, then tap nginx.conf for Remote Editor
    await tester.tap(find.byTooltip('Chế độ 1 ngăn'));
    await tester.pumpAndSettle();

    // 5. Remote File Editor (open nginx.conf -> edit -> save to server)
    await tester.tap(find.text('nginx.conf'));
    await _waitUntil(
      tester,
      () =>
          find.text('Lưu lên Server').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
      reason: 'Remote editor did not load nginx.conf',
    );
    await tester.pumpAndSettle();
    final editedConfig =
        'worker_processes auto;\n# TermPulse QA ${DateTime.now().microsecondsSinceEpoch}\nhttp {\n  server { listen 80; }\n}\n';
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      editedConfig,
    );
    await tester.pump();
    await tester.tap(find.text('Lưu lên Server'));
    await _waitUntil(
      tester,
      () => find.text('Đã lưu lên server.').evaluate().isNotEmpty,
      reason: 'Remote save status did not appear',
    );
    expect(
      await container
          .read(backendProvider)
          .sftpReadText(
            container.read(sessionManagerProvider).activeTab!.sessionId!,
            '/etc/nginx/nginx.conf',
          ),
      editedConfig,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _capture(shotKey, outDir, 'pc_05_remote_editor', tester);
    await tester.tap(find.text('Đóng'));
    debugPrint('QA remote editor Close tapped');
    await tester.pumpAndSettle();
    debugPrint('QA remote editor closed');

    // 6. Compose Pane + PROD Dangerous Command Guard
    await tester.enterText(
      find.byKey(const Key('composePaneField')),
      'rm -rf /tmp/old_cache',
    );
    await tester.tap(find.byKey(const Key('composeSendButton')));
    debugPrint('QA dangerous command send tapped');
    await _waitUntil(
      tester,
      () => find.text('Cảnh báo lệnh nguy hiểm (PROD)').evaluate().isNotEmpty,
      reason: 'PROD Command Guard modal did not trigger',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_06_compose_prod_guard', tester);
    await tester.tap(find.text('Huỷ bỏ'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composePaneField')),
      'systemctl status nginx',
    );
    await tester.pump();

    // 7. Split 1x2 + Broadcast Safety Banner + OSC-777 agent notification
    await tester.tap(find.text('staging-api').first);
    await _waitUntil(
      tester,
      () => container.read(sessionManagerProvider).tabs.length >= 2,
      reason: 'staging-api tab did not open',
    );
    await tester.tap(find.byTooltip('Local Shell'));
    await _waitUntil(
      tester,
      () => container.read(sessionManagerProvider).tabs.length >= 3,
      reason: 'Local Shell tab did not open',
    );
    // Switch active tab back to prod-web-01 (index 0) cleanly so split shows prod-web-01 + staging-api
    container.read(sessionManagerProvider.notifier).setActiveTab(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1x2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktopBroadcastChip')));
    await _waitUntil(
      tester,
      () =>
          find.byKey(const Key('broadcastSafetyBanner')).evaluate().isNotEmpty,
      reason: 'Broadcast banner missing',
    );
    // Trigger OSC-777 agent-done notification
    await container
        .read(sessionManagerProvider.notifier)
        .sendTextToActive('agent-done\n');
    await tester.pump(const Duration(milliseconds: 500));
    await _capture(shotKey, outDir, 'pc_07_split_broadcast_alert', tester);

    // Turn off broadcast and return to 1x1 cleanly
    await tester.tap(find.text('Tắt nhanh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1x1'));
    await tester.pumpAndSettle();

    // 8. Command Palette (Ctrl+K)
    await tester.tap(find.byType(TerminalView).first);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('commandPaletteSearch')),
      'prod',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_08_command_palette', tester);
    // Close dialog via back/pop
    Navigator.of(
      tester.element(find.byKey(const Key('commandPaletteSearch'))),
    ).pop();
    await tester.pumpAndSettle();

    // 9. BottomDock -> Server Health (/proc)
    await tester.tap(find.text('Server Health (/proc)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đo /proc'));
    await _waitUntil(
      tester,
      () => find.textContaining('2410/8192 MB').evaluate().isNotEmpty,
      reason: '/proc health metrics did not arrive',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_09_health_proc', tester);

    // 10. Real SFTP upload + Tunnel Manager (-L 19080 -> 18080)
    final uploadSrc = File('/tmp/termpulse_qa_upload.txt');
    uploadSrc.writeAsStringSync(
      'Uploaded via TermPulse PC QA integration test\n' * 16,
    );
    addTearDown(() {
      if (uploadSrc.existsSync()) uploadSrc.deleteSync();
    });
    final mgr = container.read(sessionManagerProvider.notifier);
    final activeKey = container
        .read(sessionManagerProvider)
        .activeTab!
        .localKey;
    await mgr.enqueueTransfer(
      localKey: activeKey,
      isUpload: true,
      localPath: uploadSrc.path,
      remotePath: '/etc/nginx/qa_upload.txt',
      fileName: 'qa_upload.txt',
    );
    await _waitUntil(
      tester,
      () => container
          .read(sessionManagerProvider)
          .transfers
          .any((j) => j.finished && j.error == null),
      reason: 'SFTP upload did not complete cleanly',
    );

    await tester.tap(find.textContaining('Tunnels ('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chạy').first);
    await _waitUntil(
      tester,
      () => container
          .read(sessionManagerProvider)
          .tunnelStatuses
          .any((s) => s.running),
      reason: 'Tunnel did not start',
    );
    // Verify real TCP forwarding through SSH direct-tcpip tunnel!
    final sock = await Socket.connect('127.0.0.1', 19080);
    await sock.first.timeout(const Duration(seconds: 4));
    await sock.close();
    await mgr.refreshTunnelStatuses();
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_10_tunnels_transfers', tester);
    // Stop tunnel cleanly
    await mgr.stopTunnel('tun_web_18080');

    // 11. Import / Export Dialog
    await tester.tap(find.byTooltip('Import / Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xuất ssh_config'));
    await _waitUntil(
      tester,
      () => find.textContaining('Đã xuất ssh_config').evaluate().isNotEmpty,
      reason: 'SSH config export failed',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_11_import_export', tester);
    await tester.tap(find.text('Đóng'));
    await tester.pumpAndSettle();

    // 12. Overview Mission Control Grid
    await tester.tap(find.byTooltip('Overview Mission Control'));
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'pc_12_overview_mission_control', tester);

    // Exit Overview back to terminal workspace
    await tester.tap(find.byTooltip('Overview Mission Control'));
    await tester.pumpAndSettle();

    // 13. Settings Dialog -> Switch to English (Dark mode)
    await tester.tap(find.byKey(const Key('settingsBtn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lang_en')));
    await tester.pumpAndSettle();
    expect(find.text('Settings & Personalization'), findsOneWidget);
    await _capture(shotKey, outDir, 'pc_13_settings_i18n_en', tester);

    // 14. Switch to Light Mode & inspect English workspace
    await tester.tap(find.byKey(const Key('theme_light')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Broadcast'), findsOneWidget);
    await _capture(shotKey, outDir, 'pc_14_daylight_light_mode', tester);
  });
}
