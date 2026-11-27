import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';

import 'qa_host_trust.dart';

Future<void> _capture(
  GlobalKey key,
  String outDir,
  String name,
  WidgetTester tester,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 350));
  final ctx = key.currentContext;
  if (ctx == null || !ctx.mounted) {
    throw StateError('Capture boundary context missing for $name');
  }
  final boundary = ctx.findRenderObject()! as RenderRepaintBoundary;
  final img = await boundary.toImage(pixelRatio: 2.0);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  expect(bd, isNotNull, reason: 'PNG encode failed for $name');
  final bytes = bd!.buffer.asUint8List();
  final file = File('$outDir/$name.png');
  file.writeAsBytesSync(bytes);
  expect(
    file.lengthSync(),
    greaterThan(5000),
    reason: 'Screenshot $name too small',
  );
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  (binding.reportData ??= <String, dynamic>{})['shot:$name'] = base64Encode(
    bytes,
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
    await tester.pump(const Duration(milliseconds: 150));
    await approveControlledQaHostPrompt(tester);
    if (pred()) return;
  }
  fail(reason ?? 'Timed out waiting for condition');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TermPulse mobile layout functional and visual QA', (
    tester,
  ) async {
    await RustLib.init();
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final appDir = await ForegroundBridge.getAppDataDir();
    final outDir = Platform.isAndroid
        ? '$appDir/qa_shots'
        : 'build/qa_screenshots/mobile';
    final outDirObj = Directory(outDir);
    outDirObj.createSync(recursive: true);

    final dbPath =
        '$appDir/qa_mobile_${DateTime.now().microsecondsSinceEpoch}.db';
    final f = File(dbPath);
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

    // 1. Mobile Vault Setup screen
    expect(find.byKey(const Key('vaultPasswordField')), findsOneWidget);
    await _capture(shotKey, outDir, 'mobile_01_vault_setup', tester);

    await tester.enterText(
      find.byKey(const Key('vaultPasswordField')),
      'MobilePass!2026',
    );
    await tester.enterText(
      find.byKey(const Key('vaultConfirmPasswordField')),
      'MobilePass!2026',
    );
    await tester.tap(find.byKey(const Key('vaultSubmitButton')));
    await _waitUntil(
      tester,
      () => find.byKey(const Key('mobileShell')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 45),
      reason: 'MobileShell did not appear after vault unlock',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('vaultWelcomeContinue')));
    await tester.pumpAndSettle();

    // Seed PROD & Staging hosts pointing at host loopback 10.0.2.2:22220 + snippet + tunnel
    final inv = container.read(inventoryProvider.notifier);
    await inv.saveCredentialAndIdentity(
      cred: const CredentialDto(
        id: 'cred_qa_mobile',
        name: 'QA Ops Secret',
        kind: 'password',
        secret: 'termpulse2026',
        storageBackend: 'vault',
      ),
      identity: const IdentityDto(
        id: 'ident_qa_mobile',
        name: 'ops@qa',
        username: 'ops',
        credentialId: 'cred_qa_mobile',
      ),
    );
    final qaHost = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
    await inv.saveHost(
      HostDto(
        id: 'host_mob_prod',
        label: 'prod-web-01',
        protocol: 'ssh',
        hostname: qaHost,
        port: 22220,
        identityMode: 'by_id',
        identityId: 'ident_qa_mobile',
        jumpHostMode: 'none',
        proxyMode: 'none',
        envTag: 'prod',
        tags: ['nginx', 'prod'],
        notes: 'QA mobile prod',
        env: [],
        followTerminalSftp: true,
        isFavorite: true,
      ),
    );
    await inv.saveHost(
      HostDto(
        id: 'host_mob_stg',
        label: 'staging-api',
        protocol: 'ssh',
        hostname: qaHost,
        port: 22220,
        identityMode: 'by_id',
        identityId: 'ident_qa_mobile',
        jumpHostMode: 'none',
        proxyMode: 'none',
        envTag: 'staging',
        tags: ['api'],
        notes: 'QA mobile staging',
        env: [],
        followTerminalSftp: true,
        isFavorite: false,
      ),
    );
    await inv.saveSnippet(
      const SnippetDto(
        id: 'snip_mob_1',
        scope: 'global',
        title: 'Check Kernel',
        commandTpl: 'uname -a',
        pinButtonBar: true,
      ),
    );
    await inv.saveSnippet(
      const SnippetDto(
        id: 'snip_mob_2',
        scope: 'global',
        title: 'List Directory',
        commandTpl: 'ls',
        pinButtonBar: false,
      ),
    );
    await inv.saveTunnel(
      const TunnelDto(
        id: 'tun_mob_1',
        name: 'Mobile Web Forward',
        hostId: 'host_mob_prod',
        kind: 'local',
        bindAddr: '127.0.0.1',
        bindPort: 19081,
        targetHost: '127.0.0.1',
        targetPort: 18080,
        autoStart: false,
      ),
    );
    await tester.pumpAndSettle();

    // 2. Host Cards Home
    expect(find.byKey(const Key('mobileHostCardsView')), findsOneWidget);
    await _capture(shotKey, outDir, 'mobile_02_hosts_home', tester);

    // 3. Connect SSH to prod-web-01 (triggers Android SshForegroundService)
    final approvalsBeforeConnect = controlledQaHostApprovals;
    await tester.tap(find.text('prod-web-01'));
    await _waitUntil(
      tester,
      () {
        final tab = container.read(sessionManagerProvider).activeTab;
        return tab != null &&
            tab.sessionId != null &&
            tab.sftpEntries.any((e) => e.name == 'main.rs');
      },
      reason:
          'Mobile SSH or SFTP /home/ops/app failed to connect to 10.0.2.2:22220',
    );
    expect(
      controlledQaHostApprovals,
      approvalsBeforeConnect + 1,
      reason: 'The first SSH connection must exercise real first-use approval',
    );
    await container
        .read(sessionManagerProvider.notifier)
        .sendTextToActive('ls\n');
    await tester.pump(const Duration(milliseconds: 500));
    await _capture(shotKey, outDir, 'mobile_03_ssh_terminal', tester);

    // 4. Open Bottom-Sheet SFTP & follow terminal cd /etc/nginx
    await container
        .read(sessionManagerProvider.notifier)
        .sendTextToActive('cd /etc/nginx\n');
    await _waitUntil(tester, () {
      final tab = container.read(sessionManagerProvider).activeTab;
      return tab != null &&
          tab.cwd == '/etc/nginx' &&
          tab.sftpEntries.any((e) => e.name == 'nginx.conf');
    }, reason: 'Mobile SFTP did not follow cd /etc/nginx');
    await tester.tap(find.byKey(const Key('mobileBottomSheetBtn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobileBottomSheet')), findsOneWidget);
    await _capture(shotKey, outDir, 'mobile_04_bottom_sheet_sftp', tester);

    // 5. Snippets & ComposeBar tab
    await tester.tap(find.text('Snippets'));
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'mobile_05_mobile_snippets', tester);

    // 6. Health & Tunnels tab -> measure /proc & start tunnel
    await tester.tap(find.text('Health & Tunnels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đo ngay').first);
    await _waitUntil(
      tester,
      () => find.textContaining('2410/8192 MB').evaluate().isNotEmpty,
      reason: 'Mobile /proc health metrics did not populate',
    );
    final tunnelSwitch = find.byType(Switch).first;
    await tester.ensureVisible(tunnelSwitch);
    await tester.pumpAndSettle();
    await tester.tap(tunnelSwitch);
    await _waitUntil(
      tester,
      () => container
          .read(sessionManagerProvider)
          .tunnelStatuses
          .any((s) => s.running),
      reason: 'Mobile tunnel failed to start',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'mobile_06_mobile_health_tunnels', tester);
    await container
        .read(sessionManagerProvider.notifier)
        .stopTunnel('tun_mob_1');

    // 7. PROD Dangerous Command Guard via ComposeBar on Snippets tab
    await tester.tap(find.text('Snippets'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composePaneField')),
      'rm -rf /var/www',
    );
    await tester.tap(find.byKey(const Key('composeSendButton')));
    await _waitUntil(
      tester,
      () => find.text('Cảnh báo lệnh nguy hiểm (PROD)').evaluate().isNotEmpty,
      reason: 'Mobile PROD guard did not trigger',
    );
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'mobile_07_prod_guard', tester);
    await tester.tap(find.text('Huỷ bỏ'));
    await tester.pumpAndSettle();

    // Close bottom sheet
    await tester.tap(find.byKey(const Key('mobileBottomSheetBtn')));
    await tester.pumpAndSettle();

    // 8. Sticky Ctrl + Space Trackpad swipe
    await tester.tap(find.byKey(const Key('stickyCtrlBtn')));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('mobileSpaceTrackpad')),
      const Offset(60, 0),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await _capture(
      shotKey,
      outDir,
      'mobile_08_sticky_ctrl_space_trackpad',
      tester,
    );

    // 9. Navigate back to Mobile Home -> open Settings -> switch to English + Light
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsBtn')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('lang_en')));
    await tester.tap(find.byKey(const Key('lang_en')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('theme_light')));
    await tester.tap(find.byKey(const Key('theme_light')));
    await tester.pumpAndSettle();
    expect(find.text('Settings & Personalization'), findsOneWidget);
    await _capture(shotKey, outDir, 'mobile_09_settings_i18n_theme', tester);

    // 10. Close Settings -> verify Mobile Home in Light Mode + English
    await tester.ensureVisible(find.text('Close'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _capture(shotKey, outDir, 'mobile_10_light_home', tester);
  });
}
