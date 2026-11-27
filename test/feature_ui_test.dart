import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/features/hosts/import_dialog.dart';
import 'package:termpulse/features/hosts/proxy_editor_dialog.dart';
import 'package:termpulse/features/ops/bottom_dock.dart';
import 'package:termpulse/features/settings/settings_dialog.dart';
import 'package:termpulse/features/sftp/remote_editor_dialog.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _FeatureBackend extends FakeCoreBackend {
  bool failSave = false;
  bool failCredential = false;
  bool failRead = false;
  int hostSaves = 0;
  int fileSaves = 0;
  int fileDeletes = 0;
  int directoryCreates = 0;
  int tunnelDeletes = 0;
  int proxyDeletes = 0;
  bool failTunnelSave = false;
  bool failProxySave = false;
  bool failProxyList = false;
  bool failProxyDelete = false;
  CredentialDto? savedCredential;
  IdentityDto? savedIdentity;
  HostDto? savedHost;
  ProxyDto? savedProxy;
  TunnelDto? savedTunnel;
  final List<TunnelStatusDto> tunnelStatuses = [];
  final List<ProxyDto> proxies = [];

  @override
  Future<void> upsertHost(HostDto host) async {
    hostSaves++;
    if (failSave) throw StateError('Storage unavailable');
    savedHost = host;
  }

  @override
  Future<void> upsertIdentity(IdentityDto identity) async {
    savedIdentity = identity;
  }

  @override
  Future<void> upsertCredential(CredentialDto credential) async {
    if (failCredential) throw StateError('Credential storage unavailable');
    savedCredential = credential;
  }

  @override
  Future<List<ProxyDto>> listProxies() async {
    if (failProxyList) throw StateError('Proxy list unavailable');
    return List.of(proxies);
  }

  @override
  Future<void> upsertProxy(ProxyDto proxy) async {
    if (failProxySave) throw StateError('Proxy storage unavailable');
    savedProxy = proxy;
    final index = proxies.indexWhere((item) => item.id == proxy.id);
    if (index < 0) {
      proxies.add(proxy);
    } else {
      proxies[index] = proxy;
    }
  }

  @override
  Future<void> deleteProxy(String id) async {
    proxyDeletes++;
    if (failProxyDelete) {
      throw StateError(
        'Host "Production server" (host-ref); Group "Production" (group-ref)',
      );
    }
    if (hosts.any((host) => host.proxyId == id)) {
      throw StateError('Proxy đang được Host tham chiếu.');
    }
    proxies.removeWhere((proxy) => proxy.id == id);
  }

  @override
  Future<void> upsertTunnel(TunnelDto tunnel) async {
    if (failTunnelSave) throw StateError('Tunnel storage unavailable');
    savedTunnel = tunnel;
    final index = tunnels.indexWhere((item) => item.id == tunnel.id);
    if (index < 0) {
      tunnels.add(tunnel);
    } else {
      tunnels[index] = tunnel;
    }
  }

  @override
  Future<void> deleteTunnel(String id) async {
    tunnelDeletes++;
    tunnels.removeWhere((tunnel) => tunnel.id == id);
  }

  @override
  Future<List<TunnelStatusDto>> listTunnelStatuses() async =>
      List.of(tunnelStatuses);

  @override
  Future<TunnelStatusDto> startTunnelById(String tunnelId) async {
    final status = TunnelStatusDto(
      tunnelId: tunnelId,
      running: true,
      bytesIn: BigInt.zero,
      bytesOut: BigInt.zero,
      activeConns: BigInt.zero,
    );
    tunnelStatuses.removeWhere((item) => item.tunnelId == tunnelId);
    tunnelStatuses.add(status);
    return status;
  }

  @override
  Future<void> stopTunnelById(String tunnelId) async {
    tunnelStatuses.removeWhere((status) => status.tunnelId == tunnelId);
  }

  @override
  Future<String> sftpReadText(String sessionId, String path) async {
    if (failRead) throw StateError('Permission denied');
    return 'original content';
  }

  @override
  Future<void> sftpWriteText(
    String sessionId,
    String path,
    String content,
  ) async {
    fileSaves++;
  }

  @override
  Future<void> sftpDeleteEntry(
    String sessionId,
    String path,
    bool isDir,
  ) async {
    fileDeletes++;
  }

  @override
  Future<void> sftpCreateDir(String sessionId, String path) async {
    directoryCreates++;
  }
}

class _MemorySettingsController extends SettingsController {
  @override
  void setTerminalFontSize(double size) {
    state = state.copyWith(terminalFontSize: size.clamp(11.0, 20.0));
  }

  @override
  void setLanguage(AppLanguage lang) {
    state = state.copyWith(language: lang);
  }

  @override
  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
  }
}

class _SeededSessionController extends SessionManagerController {
  final WorkspaceState initialState;
  _SeededSessionController(this.initialState);

  @override
  WorkspaceState build() => initialState;
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _FeatureBackend backend, {
  required Widget Function(BuildContext, WidgetRef) builder,
  Size size = const Size(980, 800),
  WorkspaceState? workspace,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      settingsProvider.overrideWith(_MemorySettingsController.new),
      if (workspace != null)
        sessionManagerProvider.overrideWith(
          () => _SeededSessionController(workspace),
        ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(inventoryProvider.notifier).refreshAll();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) => builder(context, ref)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _closeErrorDetails(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('noticeDetailsDialog')),
      matching: find.widgetWithText(TextButton, 'Đóng'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Host editor rejects invalid ports and recovers after save errors',
    (tester) async {
      final backend = _FeatureBackend();
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () =>
              showHostEditorDialog(context, ref, existing: backend.hosts.first),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final portField = find.widgetWithText(TextField, 'Port');
      await tester.enterText(portField, '70000');
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(backend.hostSaves, 0);
      expect(find.text('Port phải là số từ 1 đến 65535.'), findsOneWidget);

      await tester.enterText(portField, '22');
      backend.failSave = true;
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Storage unavailable'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('Bad state: Storage unavailable'), findsOneWidget);
      await _closeErrorDetails(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Lưu Host'))
            .onPressed,
        isNotNull,
      );

      backend.failSave = false;
      backend.failCredential = true;
      final secret = find.widgetWithText(
        TextField,
        'Mật khẩu (để trống nếu giữ cũ/kế thừa)',
      );
      await tester.ensureVisible(secret);
      await tester.enterText(secret, 'password');
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Credential storage unavailable'),
        findsNothing,
      );
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.text('Bad state: Credential storage unavailable'),
        findsOneWidget,
      );
      await _closeErrorDetails(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Lưu Host'))
            .onPressed,
        isNotNull,
      );

      backend.failCredential = false;
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(backend.hostSaves, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('RDP requires a username before saving an entered password', (
    tester,
  ) async {
    final backend = _FeatureBackend();
    await _mount(
      tester,
      backend,
      builder: (context, ref) => TextButton(
        onPressed: () =>
            showHostEditorDialog(context, ref, existing: backend.hosts.first),
        child: const Text('Open'),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final protocol = find.widgetWithText(
      DropdownButtonFormField<String>,
      'Giao thức',
    );
    await tester.ensureVisible(protocol);
    await tester.tap(protocol);
    await tester.pumpAndSettle();
    await tester.tap(find.text('RDP · Windows Desktop').last);
    await tester.pumpAndSettle();
    final username = find.widgetWithText(TextField, 'Username');
    final password = find.widgetWithText(
      TextField,
      'Mật khẩu (để trống nếu giữ cũ/kế thừa)',
    );
    await tester.ensureVisible(username);
    await tester.enterText(username, '   ');
    await tester.ensureVisible(password);
    await tester.enterText(password, 'rdp-fixture-password');
    await tester.tap(find.text('Lưu Host'));
    await tester.pumpAndSettle();
    expect(
      find.text('Nhập username tương ứng với thông tin xác thực.'),
      findsOneWidget,
    );
    expect(backend.hostSaves, 0);
    expect(backend.savedCredential, isNull);
    expect(backend.savedIdentity, isNull);
    expect(find.byKey(const Key('noticeDetailsButton')), findsNothing);
    await tester.ensureVisible(username);
    await tester.enterText(username, 'rdp-fixture-user');
    await tester.tap(find.text('Lưu Host'));
    await tester.pumpAndSettle();
    expect(backend.savedHost?.protocol, 'rdp');
    expect(backend.savedHost?.port, 3389);
    expect(backend.savedHost?.identityMode, 'by_id');
    expect(backend.savedHost?.identityId, backend.savedIdentity?.id);
    expect(backend.savedIdentity?.username, 'rdp-fixture-user');
    expect(backend.savedIdentity?.credentialId, backend.savedCredential?.id);
    expect(backend.savedCredential?.secret, 'rdp-fixture-password');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('VNC still saves password-only authentication', (tester) async {
    final backend = _FeatureBackend();
    await _mount(
      tester,
      backend,
      builder: (context, ref) => TextButton(
        onPressed: () =>
            showHostEditorDialog(context, ref, existing: backend.hosts.first),
        child: const Text('Open'),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final protocol = find.widgetWithText(
      DropdownButtonFormField<String>,
      'Giao thức',
    );
    await tester.ensureVisible(protocol);
    await tester.tap(protocol);
    await tester.pumpAndSettle();
    await tester.tap(find.text('VNC · Remote Desktop').last);
    await tester.pumpAndSettle();
    final username = find.widgetWithText(TextField, 'Username');
    await tester.ensureVisible(username);
    await tester.enterText(username, '');
    final password = find.widgetWithText(
      TextField,
      'Mật khẩu (để trống nếu giữ cũ/kế thừa)',
    );
    await tester.ensureVisible(password);
    await tester.enterText(password, 'vnc-fixture-password');
    await tester.tap(find.text('Lưu Host'));
    await tester.pumpAndSettle();
    expect(backend.savedHost?.protocol, 'vnc');
    expect(backend.savedHost?.port, 5900);
    expect(backend.savedHost?.identityMode, 'by_id');
    expect(backend.savedIdentity?.username, isEmpty);
    expect(backend.savedIdentity?.credentialId, backend.savedCredential?.id);
    expect(backend.savedCredential?.secret, 'vnc-fixture-password');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SSH private keys keep their encrypted-key passphrase in the vault credential',
    (tester) async {
      final backend = _FeatureBackend();
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () =>
              showHostEditorDialog(context, ref, existing: backend.hosts.first),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final credentialType = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Loại Credential',
      );
      await tester.ensureVisible(credentialType);
      await tester.tap(credentialType);
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH Private Key').last);
      await tester.pumpAndSettle();
      final passphrase = find.widgetWithText(
        TextField,
        'Passphrase của Private Key',
      );
      await tester.ensureVisible(passphrase);
      await tester.enterText(passphrase, 'key passphrase');
      expect(tester.widget<TextField>(passphrase).obscureText, isTrue);
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(
        find.text('Dán Private Key tương ứng với passphrase.'),
        findsOneWidget,
      );
      expect(backend.savedCredential, isNull);
      final privateKey = find.widgetWithText(
        TextField,
        'Dán nội dung PEM Private Key',
      );
      await tester.ensureVisible(privateKey);
      await tester.enterText(privateKey, 'PRIVATE KEY CONTENT\n');
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(backend.savedCredential?.kind, 'ssh_key');
      expect(backend.savedCredential?.secret, 'PRIVATE KEY CONTENT\n');
      expect(backend.savedCredential?.passphrase, 'key passphrase');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Host proxy manager validates, saves vault credentials, edits and selects a proxy',
    (tester) async {
      final backend = _FeatureBackend();
      await _mount(
        tester,
        backend,
        size: const Size(360, 640),
        builder: (context, ref) => TextButton(
          onPressed: () =>
              showHostEditorDialog(context, ref, existing: backend.hosts.first),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Quản lý Proxy'));
      await tester.tap(find.byTooltip('Quản lý Proxy'));
      await tester.pumpAndSettle();
      expect(find.text('Chưa có Proxy'), findsOneWidget);
      await tester.tap(find.text('Thêm Proxy'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên Proxy *'),
        'Office Proxy',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Hostname / IP Proxy *'),
        '127.0.0.1',
      );
      final port = find.widgetWithText(TextField, 'Port Proxy');
      await tester.enterText(port, '70000');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(
        find.text('Port Proxy phải là số từ 1 đến 65535.'),
        findsOneWidget,
      );
      await tester.enterText(port, '1080');
      final auth = find.widgetWithText(
        SwitchListTile,
        'Proxy yêu cầu xác thực',
      );
      await tester.ensureVisible(auth);
      await tester.tap(auth);
      await tester.pumpAndSettle();
      final username = find.widgetWithText(TextField, 'Username Proxy *');
      final password = find.widgetWithText(TextField, 'Mật khẩu Proxy');
      await tester.ensureVisible(username);
      await tester.enterText(username, 'proxy-user');
      await tester.ensureVisible(password);
      await tester.enterText(password, 'proxy-private-password');
      expect(tester.widget<TextField>(password).obscureText, isTrue);
      backend.failProxySave = true;
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Proxy storage unavailable'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('Bad state: Proxy storage unavailable'), findsOneWidget);
      await _closeErrorDetails(tester);
      final credentialId = backend.savedCredential?.id;
      backend.failProxySave = false;
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.proxies, hasLength(1));
      expect(backend.savedCredential?.secret, 'proxy-private-password');
      expect(backend.savedCredential?.storageBackend, 'vault');
      expect(backend.savedCredential?.id, credentialId);
      expect(backend.savedProxy?.credentialId, credentialId);
      expect(backend.savedProxy?.username, 'proxy-user');
      expect(backend.savedProxy?.host, '127.0.0.1');
      expect(backend.savedProxy?.credentialId, isNot('proxy-private-password'));
      await tester.tap(find.byTooltip('Chỉnh sửa Proxy'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên Proxy *'),
        'Office Proxy Updated',
      );
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.proxies, hasLength(1));
      expect(backend.savedProxy?.credentialId, credentialId);
      await tester.tap(find.text('Office Proxy Updated'));
      await tester.pumpAndSettle();
      final hostAddress = find.widgetWithText(TextField, 'Hostname / IP *');
      await tester.ensureVisible(hostAddress);
      await tester.enterText(hostAddress, '[::1]');
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(backend.savedHost?.proxyMode, 'direct');
      expect(backend.savedHost?.proxyId, backend.savedProxy?.id);
      expect(backend.savedHost?.hostname, '::1');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Proxy manager retries list errors and SOCKS4 clears password credentials',
    (tester) async {
      final backend = _FeatureBackend()..failProxyList = true;
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () => showProxyManagerDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Proxy list unavailable'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('Bad state: Proxy list unavailable'), findsOneWidget);
      await _closeErrorDetails(tester);
      backend.failProxyList = false;
      backend.proxies.add(
        const ProxyDto(
          id: 'p1',
          name: 'Existing Proxy',
          kind: 'socks5',
          host: '127.0.0.1',
          port: 1080,
          username: 'operator',
          credentialId: 'old-vault-credential',
        ),
      );
      await tester.tap(find.text('Thử tải lại'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chỉnh sửa Proxy'));
      await tester.pumpAndSettle();
      final kind = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Loại Proxy',
      );
      await tester.tap(kind);
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS4').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Mật khẩu Proxy'), findsNothing);
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.savedProxy?.id, 'p1');
      expect(backend.savedProxy?.kind, 'socks4');
      expect(backend.savedProxy?.username, 'operator');
      expect(backend.savedProxy?.credentialId, isNull);
      expect(backend.savedCredential, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Proxy credentials validate protocol constraints and normalize IPv6',
    (tester) async {
      final backend = _FeatureBackend();
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () => showProxyEditorDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên Proxy *'),
        'IPv6 Proxy',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Hostname / IP Proxy *'),
        '[::1]',
      );
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Proxy yêu cầu xác thực'),
      );
      await tester.pumpAndSettle();
      final username = find.widgetWithText(TextField, 'Username Proxy *');
      await tester.enterText(username, List.filled(128, 'é').join());
      await tester.enterText(
        find.widgetWithText(TextField, 'Mật khẩu Proxy'),
        'password',
      );
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Username và mật khẩu SOCKS5 không được vượt quá 255 byte UTF-8.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Loại Proxy'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP CONNECT').last);
      await tester.pumpAndSettle();
      await tester.enterText(username, 'user:name');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(
        find.text('Username HTTP CONNECT không được chứa dấu hai chấm (:).'),
        findsOneWidget,
      );
      await tester.enterText(username, 'operator');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.savedProxy?.host, '::1');
      expect(backend.savedProxy?.port, 8080);
      expect(backend.savedProxy?.username, 'operator');
      expect(backend.savedProxy?.kind, 'http_connect');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Proxy deletion confirms intent and keeps referenced configuration visible on failure',
    (tester) async {
      final backend = _FeatureBackend();
      backend.proxies.add(
        const ProxyDto(
          id: 'p-delete',
          name: 'Office Proxy',
          kind: 'http_connect',
          host: 'proxy.example',
          port: 443,
          username: 'operator',
          credentialId: 'shared-password',
          tls: true,
        ),
      );
      await _mount(
        tester,
        backend,
        size: const Size(360, 640),
        builder: (context, ref) => TextButton(
          onPressed: () => showProxyManagerDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      Future<void> askDelete() async {
        await tester.tap(find.byTooltip('Xoá Proxy'));
        await tester.pumpAndSettle();
      }

      await askDelete();
      expect(find.text('Xoá Proxy?'), findsOneWidget);
      expect(
        find.textContaining('Mật khẩu trong Vault sẽ được giữ lại.'),
        findsOneWidget,
      );
      expect(backend.proxyDeletes, 0);
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
      expect(backend.proxyDeletes, 0);
      backend.failProxyDelete = true;
      await askDelete();
      await tester.tap(find.widgetWithText(FilledButton, 'Xoá Proxy'));
      await tester.pumpAndSettle();
      expect(backend.proxyDeletes, 1);
      expect(find.textContaining('Production server'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.textContaining('Production server'), findsOneWidget);
      await _closeErrorDetails(tester);
      expect(find.text('Office Proxy'), findsOneWidget);
      expect(backend.proxies.single.credentialId, 'shared-password');
      backend.failProxyDelete = false;
      await askDelete();
      await tester.tap(find.widgetWithText(FilledButton, 'Xoá Proxy'));
      await tester.pumpAndSettle();
      expect(backend.proxyDeletes, 2);
      expect(backend.proxies, isEmpty);
      expect(find.text('Chưa có Proxy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Deleting an unsaved Host proxy selection cannot resurrect the cached proxy',
    (tester) async {
      final backend = _FeatureBackend();
      backend.proxies.add(
        const ProxyDto(
          id: 'temporary',
          name: 'Temporary Proxy',
          kind: 'socks5',
          host: '127.0.0.1',
          port: 1080,
        ),
      );
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () =>
              showHostEditorDialog(context, ref, existing: backend.hosts.first),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Quản lý Proxy'));
      await tester.tap(find.byTooltip('Quản lý Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Temporary Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Quản lý Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Xoá Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Xoá Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text('Proxy không tồn tại'), findsOneWidget);
      await tester.tap(find.text('Lưu Host'));
      await tester.pumpAndSettle();
      expect(backend.hostSaves, 0);
      expect(find.text('Chọn Proxy khả dụng hoặc tắt Proxy.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TLS and enterprise HTTP proxy settings validate and preserve vault passwords',
    (tester) async {
      final backend = _FeatureBackend();
      const existing = ProxyDto(
        id: 'enterprise',
        name: 'Enterprise Proxy',
        kind: 'http_connect',
        host: 'proxy.example',
        port: 443,
        username: 'operator',
        credentialId: 'existing-password',
      );
      await _mount(
        tester,
        backend,
        size: const Size(360, 640),
        builder: (context, ref) => TextButton(
          onPressed: () => showProxyEditorDialog(
            context,
            ref,
            existing: backend.savedProxy ?? existing,
          ),
          child: const Text('Open'),
        ),
      );
      Future<void> enter(String label, String text) async {
        final field = find.widgetWithText(TextField, label);
        await tester.ensureVisible(field);
        await tester.enterText(field, text);
      }

      Future<void> selectAuth(String label) async {
        final field = find.widgetWithText(
          DropdownButtonFormField<String>,
          'Xác thực HTTP CONNECT',
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final tls = find.widgetWithText(SwitchListTile, 'TLS tới Proxy');
      await tester.ensureVisible(tls);
      await tester.tap(tls);
      await tester.pumpAndSettle();
      await enter('Tên máy chủ TLS (tuỳ chọn)', 'secure.proxy.example');
      await enter(
        'CA PEM riêng (tuỳ chọn)',
        '-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----',
      );
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('CA TLS phải là chứng chỉ PEM hợp lệ'),
        findsOneWidget,
      );
      expect(backend.savedProxy, isNull);
      await enter('CA PEM riêng (tuỳ chọn)', '');
      await selectAuth('NTLMv2');
      await enter('Domain / Realm (tuỳ chọn)', 'CORP');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.savedProxy?.tls, isTrue);
      expect(backend.savedProxy?.tlsServerName, 'secure.proxy.example');
      expect(backend.savedProxy?.tlsCaPem, isNull);
      expect(backend.savedProxy?.authMethod, 'ntlm');
      expect(backend.savedProxy?.authDomain, 'CORP');
      expect(backend.savedProxy?.credentialId, 'existing-password');
      expect(backend.savedCredential, isNull);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await selectAuth('Kerberos / Negotiate');
      await enter('Domain / Realm (tuỳ chọn)', 'EXAMPLE.COM');
      await enter('SPN Kerberos (tuỳ chọn)', 'ssh/proxy.example');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(
        find.text('SPN Kerberos phải có dạng HTTP/proxy.example.com.'),
        findsOneWidget,
      );
      await enter('SPN Kerberos (tuỳ chọn)', 'HTTP/secure.proxy.example');
      for (final invalid in [
        'http://kdc.example',
        'tcp://user:password@kdc.example:88',
        'https://kdc.example/KdcProxy#fragment',
      ]) {
        await enter('KDC URL *', invalid);
        await tester.tap(find.text('Lưu Proxy'));
        await tester.pumpAndSettle();
        expect(find.textContaining('KDC URL phải dùng tcp://'), findsOneWidget);
        expect(backend.savedProxy?.authMethod, 'ntlm');
      }
      await enter('KDC URL *', 'https://kdc.example/KdcProxy');
      await tester.tap(find.text('Lưu Proxy'));
      await tester.pumpAndSettle();
      expect(backend.savedProxy?.authMethod, 'kerberos');
      expect(backend.savedProxy?.authDomain, 'EXAMPLE.COM');
      expect(backend.savedProxy?.authSpn, 'HTTP/secure.proxy.example');
      expect(backend.savedProxy?.authKdcUrl, 'https://kdc.example/KdcProxy');
      expect(backend.savedProxy?.credentialId, 'existing-password');
      expect(backend.savedCredential, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Remote editor clears dirty state after reverting and saves with keyboard shortcut',
    (tester) async {
      final backend = _FeatureBackend();
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () => showRemoteFileEditor(
            context,
            ref,
            sessionId: 'session',
            remotePath: '/etc/app.conf',
          ),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final editor = find.byType(TextField);
      await tester.enterText(editor, 'changed');
      await tester.pump();
      expect(find.text('Có thay đổi chưa lưu'), findsOneWidget);
      await tester.enterText(editor, 'original content');
      await tester.pump();
      expect(find.text('Nội dung đã đồng bộ'), findsOneWidget);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: find.text('Lưu lên Server'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ButtonStyleButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text('Bỏ thay đổi chưa lưu?'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(editor, 'saved by keyboard');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(backend.fileSaves, 1);
      expect(find.text('Đã lưu lên server.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Failed remote file loads cannot overwrite the file and can retry',
    (tester) async {
      final backend = _FeatureBackend()..failRead = true;
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () => showRemoteFileEditor(
            context,
            ref,
            sessionId: 'session',
            remotePath: '/etc/app.conf',
          ),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Không đọc được file:'), findsOneWidget);
      final saveButton = find.ancestor(
        of: find.text('Lưu lên Server'),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      );
      expect(
        tester.widget<ButtonStyleButton>(saveButton.first).onPressed,
        isNull,
      );
      expect(find.byType(TextField), findsNothing);
      expect(backend.fileSaves, 0);

      backend.failRead = false;
      await tester.tap(find.text('Thử tải lại'));
      await tester.pumpAndSettle();
      expect(find.text('original content'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'edited content');
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text('Bỏ thay đổi chưa lưu?'), findsOneWidget);
      await tester.tap(find.text('Tiếp tục sửa'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu lên Server'));
      await tester.pumpAndSettle();
      expect(backend.fileSaves, 1);
      expect(find.text('Đã lưu lên server.'), findsOneWidget);
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Saved remote editor closes cleanly with desktop focus behavior',
    (tester) async {
      final backend = _FeatureBackend();
      bool completed = false;
      await _mount(
        tester,
        backend,
        builder: (context, ref) => TextButton(
          onPressed: () async {
            await showRemoteFileEditor(
              context,
              ref,
              sessionId: 'session',
              remotePath: '/etc/app.conf',
            );
            completed = true;
          },
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'saved content\n');
      await tester.pump();
      await tester.tap(find.text('Lưu lên Server'));
      await tester.pumpAndSettle();
      expect(backend.fileSaves, 1);
      expect(find.text('Đã lưu lên server.'), findsOneWidget);
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(completed, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('Feature dialogs fit a compact phone viewport', (tester) async {
    final backend = _FeatureBackend();
    final actions = <String, Future<void> Function(BuildContext, WidgetRef)>{
      'Settings': showSettingsDialog,
      'Import': showImportExportDialog,
      'Host': (context, ref) => showHostEditorDialog(context, ref),
      'Tunnel': showCreateTunnelDialog,
    };
    await _mount(
      tester,
      backend,
      size: const Size(360, 640),
      builder: (context, ref) => Wrap(
        children: [
          for (final action in actions.entries)
            TextButton(
              onPressed: () => action.value(context, ref),
              child: Text(action.key),
            ),
        ],
      ),
    );
    for (final action in actions.keys) {
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: '$action dialog should fit at 360px',
      );
      final dialogContext = tester.element(find.byType(AlertDialog));
      Navigator.of(dialogContext).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('AI tools scroll on phones and validate endpoint configuration', (
    tester,
  ) async {
    await _mount(
      tester,
      _FeatureBackend(),
      size: const Size(360, 640),
      builder: (context, ref) =>
          const Align(alignment: Alignment.bottomCenter, child: BottomDock()),
    );
    await tester.ensureVisible(find.text('AI Draft (BYO-Key/Ollama)'));
    await tester.tap(find.text('AI Draft (BYO-Key/Ollama)'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final acknowledgement = find.descendant(
      of: find.byKey(const Key('aiDisclosureAcknowledgement')),
      matching: find.byType(Checkbox),
    );
    await tester.ensureVisible(acknowledgement);
    await tester.tap(acknowledgement);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tạo nháp'));
    await tester.tap(find.text('Tạo nháp'));
    await tester.pumpAndSettle();
    expect(
      find.text('Nhập endpoint HTTP(S), tên model và yêu cầu để tạo bản nháp.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Font size controls step, reset, and respect the supported bounds',
    (tester) async {
      final container = await _mount(
        tester,
        _FeatureBackend(),
        size: const Size(360, 640),
        builder: (context, ref) => TextButton(
          onPressed: () => showSettingsDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final increase = find.byKey(const Key('terminalFontIncrease'));
      final decrease = find.byKey(const Key('terminalFontDecrease'));
      final reset = find.byKey(const Key('terminalFontReset'));
      await tester.ensureVisible(increase);
      await tester.tap(increase);
      await tester.pump();
      expect(container.read(settingsProvider).terminalFontSize, 14);
      await tester.tap(reset);
      await tester.pump();
      expect(container.read(settingsProvider).terminalFontSize, 13.5);
      expect(tester.widget<IconButton>(reset).onPressed, isNull);
      container.read(settingsProvider.notifier).setTerminalFontSize(20);
      await tester.pump();
      expect(tester.widget<IconButton>(increase).onPressed, isNull);
      container.read(settingsProvider.notifier).setTerminalFontSize(11);
      await tester.pump();
      expect(tester.widget<IconButton>(decrease).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Tunnel manager edits existing configuration, guards running tunnels, and confirms delete',
    (tester) async {
      final backend = _FeatureBackend();
      backend.tunnels[0] = const TunnelDto(
        id: 't1',
        name: 'Prod DB',
        hostId: 'h_prod',
        kind: 'local',
        bindAddr: '0.0.0.0',
        bindPort: 5432,
        targetHost: '127.0.0.1',
        targetPort: 5432,
        autoStart: true,
      );
      await _mount(
        tester,
        backend,
        size: const Size(360, 640),
        builder: (context, ref) =>
            const Align(alignment: Alignment.bottomCenter, child: BottomDock()),
      );
      await tester.tap(find.text('Tunnels (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Quản lý Tunnel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chỉnh sửa Tunnel'));
      await tester.pumpAndSettle();
      expect(find.text('Chỉnh sửa Tunnel SSH'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên Tunnel (vd: Prod Postgres)'),
        'Updated DB',
      );
      backend.failTunnelSave = true;
      await tester.tap(find.text('Lưu Tunnel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tunnel storage unavailable'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.text('Bad state: Tunnel storage unavailable'),
        findsOneWidget,
      );
      await _closeErrorDetails(tester);
      backend.failTunnelSave = false;
      await tester.tap(find.text('Lưu Tunnel'));
      await tester.pumpAndSettle();
      expect(backend.tunnels, hasLength(1));
      expect(backend.savedTunnel?.id, 't1');
      expect(backend.savedTunnel?.name, 'Updated DB');
      expect(backend.savedTunnel?.bindAddr, '0.0.0.0');
      expect(backend.savedTunnel?.autoStart, isTrue);
      await tester.tap(find.text(const AppStrings(AppLanguage.vi).startBtn));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Dừng Tunnel để sửa hoặc xoá'));
      await tester.pumpAndSettle();
      final editItem = find.ancestor(
        of: find.text('Chỉnh sửa Tunnel'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(tester.widget<PopupMenuItem<String>>(editItem).enabled, isFalse);
      Navigator.of(tester.element(editItem)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text(const AppStrings(AppLanguage.vi).stopBtn));
      await tester.pumpAndSettle();
      Future<void> askDelete() async {
        await tester.tap(find.byTooltip('Quản lý Tunnel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xoá Tunnel'));
        await tester.pumpAndSettle();
      }

      await askDelete();
      expect(find.text('Xoá Tunnel?'), findsOneWidget);
      expect(backend.tunnelDeletes, 0);
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
      expect(backend.tunnelDeletes, 0);
      await askDelete();
      await tester.tap(find.text('Xoá Tunnel'));
      await tester.pumpAndSettle();
      expect(backend.tunnelDeletes, 1);
      expect(backend.tunnels, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Cancelled transfers show a neutral cancelled status and retain partial progress',
    (tester) async {
      await _mount(
        tester,
        _FeatureBackend(),
        workspace: const WorkspaceState(
          transfers: [
            TransferJobState(
              transferId: 'cancelled-partial',
              fileName: 'cancelled.txt',
              isUpload: true,
              bytesDone: 40,
              bytesTotal: 100,
              finished: true,
              cancelled: true,
            ),
            TransferJobState(
              transferId: 'cancelled-unknown',
              fileName: 'unknown-size.txt',
              isUpload: false,
              finished: true,
              cancelled: true,
            ),
          ],
        ),
        builder: (context, ref) =>
            const Align(alignment: Alignment.bottomCenter, child: BottomDock()),
      );
      expect(find.byTooltip('Đã huỷ'), findsNWidgets(2));
      expect(find.byTooltip('Hoàn tất'), findsNothing);
      expect(find.text('Đã huỷ · 40 B'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(find.byIcon(Icons.cancel_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dock collapses on short windows and all tool tabs remain accessible',
    (tester) async {
      await _mount(
        tester,
        _FeatureBackend(),
        size: const Size(1280, 820),
        builder: (context, ref) => const Column(
          children: [
            SizedBox(
              height: 110,
              child: Center(child: Text('Broadcast warning / operation error')),
            ),
            Expanded(child: SizedBox(key: Key('terminalArea'))),
            BottomDock(),
          ],
        ),
      );
      expect(tester.getSize(find.byType(BottomDock)).height, 193);
      tester.view.physicalSize = const Size(1280, 360);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BottomDock)).height, 41);
      for (final tab in [
        'Transfers (0)',
        'Tunnels (1)',
        const AppStrings(AppLanguage.vi).healthTabTitle,
        'AI Draft (BYO-Key/Ollama)',
      ]) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(BottomDock)).height, 41);
        expect(
          tester.getSize(find.byKey(const Key('terminalArea'))).height,
          greaterThan(200),
        );
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '$tab should fit a short window',
        );
        if (tab.startsWith('AI Draft')) {
          final acknowledgement = find.descendant(
            of: find.byKey(const Key('aiDisclosureAcknowledgement')),
            matching: find.byType(Checkbox),
          );
          await tester.ensureVisible(acknowledgement);
          await tester.tap(acknowledgement);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Tạo nháp'));
          await tester.tap(find.text('Tạo nháp'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Nhập endpoint HTTP(S), tên model và yêu cầu để tạo bản nháp.',
            ),
            findsOneWidget,
          );
        }
        await tester.tap(find.byTooltip('Đóng công cụ'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Mở bảng công cụ'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Đóng công cụ'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BottomDock)).height, 41);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Reduced motion dock toggles and resizes without AnimatedSize', (
    tester,
  ) async {
    await _mount(
      tester,
      _FeatureBackend(),
      size: const Size(1280, 820),
      builder: (context, ref) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: const Align(
          alignment: Alignment.bottomCenter,
          child: BottomDock(),
        ),
      ),
    );
    final dock = find.byType(BottomDock);
    expect(
      find.descendant(of: dock, matching: find.byType(AnimatedSize)),
      findsNothing,
    );
    for (var index = 0; index < 3; index++) {
      await tester.tap(find.byTooltip('Thu gọn bảng công cụ'));
      await tester.pump();
      expect(tester.getSize(dock).height, 41);
      await tester.tap(find.byTooltip('Mở bảng công cụ'));
      await tester.pump();
      expect(tester.getSize(dock).height, 193);
    }
    tester.view.physicalSize = const Size(1280, 360);
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).height, 41);
    await tester.tap(find.text('Tunnels (1)'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.byTooltip('Đóng công cụ'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1280, 820);
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).height, 193);
    expect(
      find.descendant(of: dock, matching: find.byType(AnimatedSize)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SFTP destructive actions require confirmation and directory dialogs close cleanly',
    (tester) async {
      final backend = _FeatureBackend();
      final entry = SftpEntryDto(
        name: 'app.conf',
        path: '/app.conf',
        isDir: false,
        isSymlink: false,
        size: BigInt.from(1572864),
        permissions: 0x81a4,
        modified: BigInt.zero,
      );
      final tab = TerminalSessionTab(
        localKey: 'sftp',
        sessionId: 'session',
        title: 'SSH',
        envTag: 'dev',
        protocol: 'ssh',
        terminal: Terminal(),
        controller: TerminalController(),
        cwd: '/',
        sftpEntries: [entry],
      );
      await _mount(
        tester,
        backend,
        builder: (context, ref) => SftpPanel(tab: tab),
      );
      expect(find.text('1.5 MiB · 644'), findsOneWidget);
      await tester.tap(find.byTooltip('Thao tác file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xoá'));
      await tester.pumpAndSettle();
      expect(find.text('Xoá file?'), findsOneWidget);
      expect(backend.fileDeletes, 0);
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
      expect(backend.fileDeletes, 0);

      await tester.tap(find.byTooltip('Tạo thư mục'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Tên thư mục'),
        'config',
      );
      await tester.tap(find.text('Tạo'));
      await tester.pumpAndSettle();
      expect(backend.directoryCreates, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
