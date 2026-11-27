import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/proxy_editor_dialog.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

Future<void> showHostEditorDialog(
  BuildContext context,
  WidgetRef ref, {
  HostDto? existing,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _HostEditorDialog(existing: existing),
  );
}

class _HostEditorDialog extends ConsumerStatefulWidget {
  final HostDto? existing;
  const _HostEditorDialog({this.existing});

  @override
  ConsumerState<_HostEditorDialog> createState() => _HostEditorDialogState();
}

class _HostEditorDialogState extends ConsumerState<_HostEditorDialog> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _secretCtrl;
  late final TextEditingController _passphraseCtrl;
  late final TextEditingController _startupDirCtrl;
  late final TextEditingController _startupCmdCtrl;
  late final TextEditingController _serialBaudCtrl;
  late final TextEditingController _desktopWidthCtrl;
  late final TextEditingController _desktopHeightCtrl;
  late final TextEditingController _desktopDomainCtrl;
  late final TextEditingController _desktopTlsNameCtrl;
  late final TextEditingController _desktopCaCtrl;
  Map<String, dynamic> _desktopOptions = {};
  late int _serialDataBits;
  late int _serialStopBits;
  late String _serialParity;
  late String _serialFlowControl;
  late bool _serialSupported;
  late String _protocol;
  late String _envTag;
  late String _credKind;
  late String? _groupId;
  late String? _jumpHostId;
  late String _jumpMode;
  late String _proxyMode;
  late String? _proxyId;
  ProxyDto? _selectedProxy;
  bool _followSftp = true;
  bool _saving = false;
  bool _showSecret = false;
  bool _showPassphrase = false;
  bool _usernameEdited = false;
  bool _scanningPorts = false;
  String? _error;

  bool get _remoteDesktop => _protocol == 'rdp' || _protocol == 'vnc';
  bool get _needsIdentity => _protocol == 'ssh' || _remoteDesktop;

  Future<void> _scanSerialPorts() async {
    if (_scanningPorts) return;
    setState(() {
      _scanningPorts = true;
      _error = null;
    });
    try {
      final ports = await ref.read(backendProvider).listSerialPorts();
      if (!mounted) return;
      setState(() => _scanningPorts = false);
      if (ports.isEmpty) {
        setState(
          () => _error =
              'Không tìm thấy cổng Serial. Kết nối thiết bị rồi quét lại.',
        );
        return;
      }
      final port = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(context.tr('Chọn cổng phát hiện')),
          children: ports
              .map(
                (port) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(port.portName),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(port.portName),
                      if (port.product != null) Text(port.product!),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );
      if (mounted && port != null) _hostCtrl.text = port;
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _scanningPorts = false);
    }
  }

  List<ProxyDto> _availableProxies(InventoryState inventory) => [
    ...inventory.proxies,
    if (_selectedProxy != null &&
        !inventory.proxies.any((proxy) => proxy.id == _selectedProxy!.id))
      _selectedProxy!,
  ];

  Future<void> _manageProxies() async {
    final selected = await showProxyManagerDialog(
      context,
      ref,
      selectedProxyId: _proxyId,
    );
    if (!mounted) return;
    setState(() {
      _selectedProxy = selected;
      if (selected != null) {
        _proxyId = selected.id;
        _proxyMode = 'direct';
      }
    });
  }

  IdentityDto? _identityFor(InventoryState inventory) {
    final host = widget.existing;
    if (host?.identityMode == 'by_name') {
      return inventory.identities
          .where(
            (identity) =>
                identity.name.toLowerCase() ==
                host?.identityNameRef?.toLowerCase(),
          )
          .firstOrNull;
    }
    String? identityId = host?.identityId;
    if (host == null || host.identityMode == 'inherit') {
      final visited = <String>{};
      String? groupId = _groupId;
      while (groupId != null && visited.add(groupId)) {
        final group = inventory.groups
            .where((group) => group.id == groupId)
            .firstOrNull;
        if (group == null) break;
        if (group.defaultIdentityId != null) {
          identityId = group.defaultIdentityId;
          break;
        }
        groupId = group.parentId;
      }
    }
    return inventory.identities
        .where((identity) => identity.id == identityId)
        .firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    final h = widget.existing;
    _labelCtrl = TextEditingController(text: h?.label ?? '');
    _hostCtrl = TextEditingController(text: h?.hostname ?? '');
    _portCtrl = TextEditingController(text: (h?.port ?? 22).toString());
    _groupId = h?.groupId;
    final identity = _identityFor(ref.read(inventoryProvider));
    _userCtrl = TextEditingController(text: identity?.username ?? 'root');
    _secretCtrl = TextEditingController();
    _passphraseCtrl = TextEditingController();
    _startupDirCtrl = TextEditingController(text: h?.startupDir ?? '');
    _startupCmdCtrl = TextEditingController(text: h?.startupCmd ?? '');
    _serialBaudCtrl = TextEditingController(
      text: (h?.serialBaudrate ?? 115200).toString(),
    );
    _serialDataBits = h?.serialDataBits ?? 8;
    _serialStopBits = h?.serialStopBits ?? 1;
    _serialParity = h?.serialParity ?? 'none';
    _serialFlowControl = h?.serialFlowControl ?? 'none';
    _serialSupported = ref.read(backendProvider).serialSupported();
    _protocol = h?.protocol ?? 'ssh';
    try {
      final options = jsonDecode(h?.remoteDesktopJson ?? '{}');
      if (options is Map<String, dynamic>) _desktopOptions = options;
    } catch (_) {
      // Preserve the host while letting the user replace malformed settings.
    }
    _desktopWidthCtrl = TextEditingController(
      text: '${_desktopOptions['width'] ?? 1280}',
    );
    _desktopHeightCtrl = TextEditingController(
      text: '${_desktopOptions['height'] ?? 800}',
    );
    _desktopDomainCtrl = TextEditingController(
      text: _desktopOptions['domain'] as String? ?? '',
    );
    _desktopTlsNameCtrl = TextEditingController(
      text: _desktopOptions['tls_server_name'] as String? ?? '',
    );
    _desktopCaCtrl = TextEditingController(
      text: _desktopOptions['tls_ca_pem'] as String? ?? '',
    );
    _envTag = h?.envTag ?? 'dev';
    _credKind = 'password';
    _jumpHostId = h?.jumpHostId;
    _jumpMode = h?.jumpHostMode ?? 'inherit';
    _proxyMode = h?.proxyMode ?? 'inherit';
    _proxyId = h?.proxyId;
    _followSftp = h?.followTerminalSftp ?? true;
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _secretCtrl.dispose();
    _passphraseCtrl.dispose();
    _startupDirCtrl.dispose();
    _startupCmdCtrl.dispose();
    _serialBaudCtrl.dispose();
    _desktopWidthCtrl.dispose();
    _desktopHeightCtrl.dispose();
    _desktopDomainCtrl.dispose();
    _desktopTlsNameCtrl.dispose();
    _desktopCaCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final inventory = ref.read(inventoryProvider);
    final port = int.tryParse(_portCtrl.text.trim());
    final serialBaud = int.tryParse(_serialBaudCtrl.text.trim());
    final enteredHostname = _hostCtrl.text.trim();
    final hostname =
        _protocol != 'serial' &&
            enteredHostname.startsWith('[') &&
            enteredHostname.endsWith(']')
        ? enteredHostname.substring(1, enteredHostname.length - 1)
        : enteredHostname;
    String? validationError;
    if (![
      'ssh',
      'telnet',
      'local_shell',
      'serial',
      'rdp',
      'vnc',
    ].contains(_protocol)) {
      validationError = 'Chọn SSH, Telnet, Local Shell, Serial, RDP hoặc VNC.';
    } else if (_protocol == 'serial' && !_serialSupported) {
      validationError =
          'Serial hỗ trợ Linux, Windows, macOS và USB OTG trên Android. iOS chưa hỗ trợ USB Serial.';
    } else if (_labelCtrl.text.trim().isEmpty) {
      validationError = 'Nhập tên hiển thị cho kết nối.';
    } else if (_protocol != 'local_shell' && hostname.isEmpty) {
      validationError = _protocol == 'serial'
          ? 'Nhập tên cổng Serial.'
          : 'Nhập hostname hoặc địa chỉ IP.';
    } else if (_protocol == 'serial' &&
        hostname.runes.any((rune) => rune < 32 || rune == 127)) {
      validationError = 'Tên cổng Serial không hợp lệ.';
    } else if (_protocol == 'serial' &&
        (serialBaud == null ||
            serialBaud < 1 ||
            serialBaud > 4000000 ||
            ![5, 6, 7, 8].contains(_serialDataBits) ||
            ![1, 2].contains(_serialStopBits) ||
            !['none', 'odd', 'even'].contains(_serialParity) ||
            !['none', 'software', 'hardware'].contains(_serialFlowControl))) {
      validationError =
          'Kiểm tra baud rate (1–4000000), data bits, parity, stop bits và flow control.';
    } else if (!['local_shell', 'serial'].contains(_protocol) &&
        (port == null || port < 1 || port > 65535)) {
      validationError = 'Port phải là số từ 1 đến 65535.';
    } else if (_remoteDesktop &&
        (int.tryParse(_desktopWidthCtrl.text) == null ||
            int.tryParse(_desktopHeightCtrl.text) == null ||
            int.parse(_desktopWidthCtrl.text) < 320 ||
            int.parse(_desktopHeightCtrl.text) < 200 ||
            int.parse(_desktopWidthCtrl.text) > 3840 ||
            int.parse(_desktopHeightCtrl.text) > 2160)) {
      validationError = 'Độ phân giải phải từ 320 × 200 đến 3840 × 2160.';
    } else if (_protocol == 'ssh' &&
        _jumpMode == 'direct' &&
        !inventory.hosts.any(
          (host) =>
              host.id == _jumpHostId &&
              host.id != widget.existing?.id &&
              host.protocol == 'ssh',
        )) {
      validationError = 'Chọn SSH Host trung gian hoặc tắt Jump Host.';
    } else if (_protocol == 'ssh' &&
        _proxyMode == 'direct' &&
        !_availableProxies(inventory).any((proxy) => proxy.id == _proxyId)) {
      validationError = 'Chọn Proxy khả dụng hoặc tắt Proxy.';
    } else if (_protocol == 'ssh' &&
        (!['inherit', 'direct', 'none'].contains(_proxyMode) ||
            !['inherit', 'direct', 'none'].contains(_jumpMode))) {
      validationError = 'Chọn chế độ Jump Host và Proxy hợp lệ.';
    } else if (['ssh', 'rdp'].contains(_protocol) &&
        _secretCtrl.text.isNotEmpty &&
        _userCtrl.text.trim().isEmpty) {
      validationError = 'Nhập username tương ứng với thông tin xác thực.';
    } else if (_protocol == 'ssh' &&
        _credKind == 'ssh_key' &&
        _passphraseCtrl.text.isNotEmpty &&
        _secretCtrl.text.isEmpty) {
      validationError = 'Dán Private Key tương ứng với passphrase.';
    }
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final invNotifier = ref.read(inventoryProvider.notifier);

      String? identityId = widget.existing?.identityId;
      String identityMode = widget.existing?.identityMode ?? 'inherit';

      if (_needsIdentity &&
          (_userCtrl.text.trim().isNotEmpty || _protocol == 'vnc') &&
          _secretCtrl.text.isNotEmpty) {
        final ts = DateTime.now().microsecondsSinceEpoch;
        final credId = 'cred_$ts';
        final identId = 'ident_$ts';
        await invNotifier.saveCredentialAndIdentity(
          cred: CredentialDto(
            id: credId,
            name: '${_labelCtrl.text.trim()} Secret',
            kind: _remoteDesktop ? 'password' : _credKind,
            secret: _secretCtrl.text,
            passphrase:
                _credKind == 'ssh_key' && _passphraseCtrl.text.isNotEmpty
                ? _passphraseCtrl.text
                : null,
            storageBackend: 'vault',
          ),
          identity: IdentityDto(
            id: identId,
            name: '${_userCtrl.text.trim()}@${_labelCtrl.text.trim()}',
            username: _userCtrl.text.trim(),
            credentialId: credId,
          ),
        );
        identityId = identId;
        identityMode = 'by_id';
      } else if (_needsIdentity && _userCtrl.text.trim().isNotEmpty) {
        final existingIdentity = _identityFor(inventory);
        if ((widget.existing == null && _groupId == null) ||
            (_usernameEdited &&
                existingIdentity?.username != _userCtrl.text.trim())) {
          final identId = 'ident_${DateTime.now().microsecondsSinceEpoch}';
          await ref
              .read(backendProvider)
              .upsertIdentity(
                IdentityDto(
                  id: identId,
                  name: '${_userCtrl.text.trim()}@${_labelCtrl.text.trim()}',
                  username: _userCtrl.text.trim(),
                  credentialId: existingIdentity?.credentialId,
                ),
              );
          identityId = identId;
          identityMode = 'by_id';
        }
      }

      final host = HostDto(
        id:
            widget.existing?.id ??
            'host_${DateTime.now().microsecondsSinceEpoch}',
        groupId: _groupId,
        label: _labelCtrl.text.trim(),
        protocol: _protocol,
        hostname: _protocol == 'local_shell' ? 'localhost' : hostname,
        port: _protocol == 'local_shell'
            ? 22
            : (_protocol == 'serial' ? 0 : port!),
        identityMode: identityMode,
        identityId: identityId,
        identityNameRef: widget.existing?.identityNameRef,
        jumpHostMode: _protocol == 'ssh' ? _jumpMode : 'none',
        jumpHostId: _protocol == 'ssh' ? _jumpHostId : null,
        proxyMode: _protocol == 'ssh' ? _proxyMode : 'none',
        proxyId: _protocol == 'ssh' ? _proxyId : null,
        colorHex: widget.existing?.colorHex,
        icon: widget.existing?.icon,
        envTag: _envTag,
        tags: widget.existing?.tags ?? const [],
        notes: widget.existing?.notes ?? '',
        startupDir: _startupDirCtrl.text.trim().isEmpty
            ? null
            : _startupDirCtrl.text.trim(),
        startupCmd: _startupCmdCtrl.text.trim().isEmpty
            ? null
            : _startupCmdCtrl.text.trim(),
        env: widget.existing?.env ?? const [],
        followTerminalSftp: _protocol == 'ssh' ? _followSftp : false,
        remoteDesktopJson: _remoteDesktop
            ? jsonEncode({
                ..._desktopOptions,
                'width': int.parse(_desktopWidthCtrl.text),
                'height': int.parse(_desktopHeightCtrl.text),
                'domain': _desktopDomainCtrl.text.trim(),
                'tls_server_name': _desktopTlsNameCtrl.text.trim(),
                'tls_ca_pem': _desktopCaCtrl.text.trim(),
              })
            : widget.existing?.remoteDesktopJson,
        wolMac: widget.existing?.wolMac,
        wolBroadcast: widget.existing?.wolBroadcast,
        serialBaudrate: _protocol == 'serial'
            ? serialBaud
            : widget.existing?.serialBaudrate,
        serialDataBits: _protocol == 'serial'
            ? _serialDataBits
            : widget.existing?.serialDataBits,
        serialParity: _protocol == 'serial'
            ? _serialParity
            : widget.existing?.serialParity,
        serialStopBits: _protocol == 'serial'
            ? _serialStopBits
            : widget.existing?.serialStopBits,
        serialFlowControl: _protocol == 'serial'
            ? _serialFlowControl
            : widget.existing?.serialFlowControl,
        isFavorite: widget.existing?.isFavorite ?? false,
        lastConnectedAt: widget.existing?.lastConnectedAt,
      );

      await invNotifier.saveHost(host);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryProvider);
    final proxies = _availableProxies(inv);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: context.tp.accentContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.dns_rounded,
                color: context.tp.accent,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.existing == null
                    ? context.tr('Thêm kết nối Host mới')
                    : context.tr('Chỉnh sửa Host'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: AbsorbPointer(
            absorbing: _saving,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _formSection(
                    context,
                    Icons.dns_outlined,
                    context.tr('Kết nối'),
                  ),
                  TextField(
                    controller: _labelCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: context.tr('Tên hiển thị (vd: prod-web-01) *'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _hostCtrl,
                          enabled: _protocol != 'local_shell',
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: _protocol == 'serial'
                                ? context.tr('Cổng Serial *')
                                : context.tr('Hostname / IP *'),
                            hintText: _protocol == 'serial'
                                ? context.tr(
                                    Theme.of(context).platform ==
                                            TargetPlatform.android
                                        ? 'Quét và chọn cổng USB Serial'
                                        : '/dev/ttyUSB0 hoặc COM3',
                                  )
                                : null,
                            suffixIcon:
                                _protocol == 'serial' && _serialSupported
                                ? IconButton(
                                    key: const Key('hostSerialScanButton'),
                                    tooltip: context.tr('Quét lại cổng Serial'),
                                    onPressed: _scanningPorts
                                        ? null
                                        : _scanSerialPorts,
                                    icon: _scanningPorts
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.usb_rounded),
                                  )
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _portCtrl,
                          enabled: ![
                            'local_shell',
                            'serial',
                          ].contains(_protocol),
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: context.tr('Port'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _protocol,
                          decoration: InputDecoration(
                            labelText: context.tr('Giao thức'),
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: 'ssh',
                              child: Text('SSHv2'),
                            ),
                            const DropdownMenuItem(
                              value: 'telnet',
                              child: Text('Telnet'),
                            ),
                            DropdownMenuItem(
                              value: 'local_shell',
                              child: Text(context.tr('Local Shell')),
                            ),
                            DropdownMenuItem(
                              value: 'rdp',
                              child: Text(context.tr('RDP · Windows Desktop')),
                            ),
                            DropdownMenuItem(
                              value: 'vnc',
                              child: Text(context.tr('VNC · Remote Desktop')),
                            ),
                            DropdownMenuItem(
                              value: 'serial',
                              enabled: _serialSupported,
                              child: Text(
                                _serialSupported
                                    ? 'Serial'
                                    : context.tr('Serial (không khả dụng)'),
                              ),
                            ),
                            if (![
                              'ssh',
                              'telnet',
                              'local_shell',
                              'serial',
                              'rdp',
                              'vnc',
                            ].contains(_protocol))
                              DropdownMenuItem(
                                value: _protocol,
                                enabled: false,
                                child: Text(
                                  context.tr('$_protocol (chưa hỗ trợ)'),
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            final next = v ?? 'ssh';
                            const ports = {
                              'ssh': 22,
                              'telnet': 23,
                              'rdp': 3389,
                              'vnc': 5900,
                            };
                            if (_portCtrl.text == '${ports[_protocol] ?? 22}') {
                              _portCtrl.text = '${ports[next] ?? 22}';
                            }
                            if (next != 'ssh') _credKind = 'password';
                            _protocol = next;
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _envTag,
                          decoration: InputDecoration(
                            labelText: context.tr('Môi trường'),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'prod',
                              child: Text(context.tr('PROD (Cảnh báo)')),
                            ),
                            DropdownMenuItem(
                              value: 'staging',
                              child: Text(context.tr('Staging')),
                            ),
                            DropdownMenuItem(
                              value: 'dev',
                              child: Text(context.tr('Dev')),
                            ),
                            DropdownMenuItem(
                              value: 'homelab',
                              child: Text(context.tr('Homelab')),
                            ),
                            if (![
                              'prod',
                              'staging',
                              'dev',
                              'homelab',
                            ].contains(_envTag))
                              DropdownMenuItem(
                                value: _envTag,
                                child: Text(_envTag),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _envTag = v ?? 'dev'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (!_remoteDesktop)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        context.tr(switch (_protocol) {
                          'ssh' =>
                            'SSH mã hóa kết nối terminal và hỗ trợ truyền file SFTP.',
                          'telnet' =>
                            'Telnet không mã hóa dữ liệu hoặc mật khẩu. Chỉ dùng với thiết bị và mạng tin cậy.',
                          'local_shell' =>
                            'Mở terminal trên máy này. Local Shell hỗ trợ máy tính và Android; iOS chưa hỗ trợ.',
                          _ =>
                            'Kết nối cổng Serial trực tiếp. Thông số phải trùng với thiết bị.',
                        }),
                        style: TextStyle(fontSize: 12, color: context.tp.muted),
                      ),
                    ),
                  if (_remoteDesktop) ...[
                    _formSection(
                      context,
                      Icons.desktop_windows_outlined,
                      context.tr('Màn hình từ xa'),
                    ),
                    Text(
                      _protocol == 'rdp'
                          ? context.tr(
                              'Điều khiển Windows bằng RDP. Chứng chỉ TLS phải hợp lệ hoặc được bạn xác minh dấu vân tay.',
                            )
                          : context.tr(
                              'Điều khiển màn hình bằng VNC. VNC cổ điển không mã hóa; chỉ dùng mạng tin cậy hoặc SSH/VPN tunnel.',
                            ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('desktopWidthField'),
                            controller: _desktopWidthCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: context.tr('Chiều rộng (px)'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const Key('desktopHeightField'),
                            controller: _desktopHeightCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: context.tr('Chiều cao (px)'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_protocol == 'rdp') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _desktopDomainCtrl,
                        decoration: InputDecoration(
                          labelText: context.tr('Domain (tùy chọn)'),
                        ),
                      ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(context.tr('Chứng chỉ TLS nâng cao')),
                        children: [
                          TextField(
                            controller: _desktopTlsNameCtrl,
                            decoration: InputDecoration(
                              labelText: context.tr(
                                'Tên máy chủ TLS (để trống dùng hostname)',
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _desktopCaCtrl,
                            minLines: 2,
                            maxLines: 4,
                            decoration: InputDecoration(
                              labelText: context.tr('CA PEM riêng (tùy chọn)'),
                            ),
                          ),
                          if ((_desktopOptions['tls_certificate_sha256']
                                      as String? ??
                                  '')
                              .isNotEmpty)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(context.tr('Dấu vân tay đã tin cậy')),
                              subtitle: SelectableText(
                                '${_desktopOptions['tls_certificate_sha256']}',
                              ),
                              trailing: IconButton(
                                tooltip: context.tr('Xóa tin cậy chứng chỉ'),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => setState(
                                  () => _desktopOptions.remove(
                                    'tls_certificate_sha256',
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                  ],
                  if (_protocol == 'serial') ...[
                    _formSection(
                      context,
                      Icons.cable_rounded,
                      context.tr('Thông số Serial'),
                    ),
                    if (!_serialSupported)
                      Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                          context.tr(
                            'Serial hỗ trợ Linux, Windows, macOS và USB OTG trên Android. iOS chưa hỗ trợ USB Serial.',
                          ),
                        ),
                      ),
                    TextField(
                      key: const Key('hostSerialBaudField'),
                      controller: _serialBaudCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: context.tr('Baud rate'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _serialChoice<int>(
                            label: context.tr('Data bits'),
                            key: const Key('hostSerialDataBitsField'),
                            value: _serialDataBits,
                            choices: const {5: '5', 6: '6', 7: '7', 8: '8'},
                            onChanged: (value) =>
                                setState(() => _serialDataBits = value),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _serialChoice<String>(
                            label: context.tr('Parity'),
                            key: const Key('hostSerialParityField'),
                            value: _serialParity,
                            choices: {
                              'none': context.tr('None'),
                              'odd': context.tr('Odd'),
                              'even': context.tr('Even'),
                            },
                            onChanged: (value) =>
                                setState(() => _serialParity = value),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _serialChoice<int>(
                            label: context.tr('Stop bits'),
                            key: const Key('hostSerialStopBitsField'),
                            value: _serialStopBits,
                            choices: const {1: '1', 2: '2'},
                            onChanged: (value) =>
                                setState(() => _serialStopBits = value),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _serialChoice<String>(
                            label: context.tr('Flow control'),
                            key: const Key('hostSerialFlowControlField'),
                            value: _serialFlowControl,
                            choices: {
                              'none': context.tr('None'),
                              'software': 'XON/XOFF',
                              'hardware': 'RTS/CTS',
                            },
                            onChanged: (value) =>
                                setState(() => _serialFlowControl = value),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _groupId,
                    decoration: InputDecoration(
                      labelText: context.tr('Thuộc Group (kế thừa cấu hình)'),
                    ),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(context.tr('-- Không có Group --')),
                      ),
                      ...inv.groups.map(
                        (g) => DropdownMenuItem<String?>(
                          value: g.id,
                          child: Text(g.name),
                        ),
                      ),
                      if (_groupId != null &&
                          !inv.groups.any((group) => group.id == _groupId))
                        DropdownMenuItem<String?>(
                          value: _groupId,
                          enabled: false,
                          child: Text(context.tr('Group không tồn tại')),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _groupId = v;
                      if (!_usernameEdited) {
                        _userCtrl.text = _identityFor(inv)?.username ?? 'root';
                      }
                    }),
                  ),
                  const SizedBox(height: 18),
                  if (_needsIdentity) ...[
                    _formSection(
                      context,
                      Icons.key_rounded,
                      _protocol == 'ssh'
                          ? context.tr('Xác thực SSH')
                          : context.tr('Tài khoản màn hình từ xa'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _userCtrl,
                            enabled: _needsIdentity,
                            autocorrect: false,
                            onChanged: (_) => _usernameEdited = true,
                            decoration: InputDecoration(
                              labelText: context.tr('Username'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _credKind,
                            decoration: InputDecoration(
                              labelText: context.tr('Loại Credential'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'password',
                                child: Text(context.tr('Mật khẩu')),
                              ),
                              if (_protocol == 'ssh')
                                DropdownMenuItem(
                                  value: 'ssh_key',
                                  child: Text(context.tr('SSH Private Key')),
                                ),
                            ],
                            onChanged: _protocol != 'ssh'
                                ? null
                                : (v) => setState(
                                    () => _credKind = v ?? 'password',
                                  ),
                          ),
                        ),
                      ],
                    ),
                    if (_credKind == 'ssh_key') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _passphraseCtrl,
                        enabled: _protocol == 'ssh',
                        autocorrect: false,
                        enableSuggestions: false,
                        obscureText: !_showPassphrase,
                        decoration: InputDecoration(
                          labelText: context.tr('Passphrase của Private Key'),
                          helperText: context.tr(
                            'Để trống nếu khóa không được mã hóa.',
                          ),
                          suffixIcon: IconButton(
                            tooltip: _showPassphrase
                                ? context.tr('Ẩn passphrase')
                                : context.tr('Hiện passphrase'),
                            onPressed: () => setState(
                              () => _showPassphrase = !_showPassphrase,
                            ),
                            icon: Icon(
                              _showPassphrase
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      controller: _secretCtrl,
                      enabled: _needsIdentity,
                      autocorrect: false,
                      enableSuggestions: false,
                      obscureText: _credKind == 'password' && !_showSecret,
                      maxLines: _credKind == 'ssh_key' ? 3 : 1,
                      decoration: InputDecoration(
                        labelText: _credKind == 'password'
                            ? context.tr(
                                'Mật khẩu (để trống nếu giữ cũ/kế thừa)',
                              )
                            : context.tr('Dán nội dung PEM Private Key'),
                        suffixIcon: _credKind == 'password'
                            ? IconButton(
                                tooltip: _showSecret
                                    ? context.tr('Ẩn mật khẩu')
                                    : context.tr('Hiện mật khẩu'),
                                onPressed: () =>
                                    setState(() => _showSecret = !_showSecret),
                                icon: Icon(
                                  _showSecret
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (_protocol == 'ssh') ...[
                    _formSection(
                      context,
                      Icons.route_outlined,
                      context.tr('Đường truyền SSH'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _jumpMode,
                            decoration: InputDecoration(
                              labelText: context.tr('Jump Host Mode'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'inherit',
                                child: Text(context.tr('Kế thừa Group')),
                              ),
                              DropdownMenuItem(
                                value: 'direct',
                                child: Text(context.tr('Chỉ định riêng')),
                              ),
                              DropdownMenuItem(
                                value: 'none',
                                child: Text(context.tr('Tắt Jump Host')),
                              ),
                              if (![
                                'inherit',
                                'direct',
                                'none',
                              ].contains(_jumpMode))
                                DropdownMenuItem(
                                  value: _jumpMode,
                                  enabled: false,
                                  child: Text(
                                    context.tr('$_jumpMode (không hợp lệ)'),
                                  ),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _jumpMode = v ?? 'inherit'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_jumpMode == 'direct')
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              isExpanded: true,
                              initialValue: _jumpHostId,
                              decoration: InputDecoration(
                                labelText: context.tr('Chọn Bastion'),
                              ),
                              items: [
                                ...inv.hosts
                                    .where(
                                      (x) =>
                                          x.id != widget.existing?.id &&
                                          x.protocol == 'ssh',
                                    )
                                    .map(
                                      (x) => DropdownMenuItem<String?>(
                                        value: x.id,
                                        child: Text(x.label),
                                      ),
                                    ),
                                if (_jumpHostId != null &&
                                    !inv.hosts.any(
                                      (host) =>
                                          host.id == _jumpHostId &&
                                          host.id != widget.existing?.id &&
                                          host.protocol == 'ssh',
                                    ))
                                  DropdownMenuItem<String?>(
                                    value: _jumpHostId,
                                    enabled: false,
                                    child: Text(
                                      context.tr('Host không khả dụng'),
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _jumpHostId = v),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('proxyMode_$_proxyMode'),
                            isExpanded: true,
                            initialValue: _proxyMode,
                            decoration: InputDecoration(
                              labelText: context.tr('Kết nối qua Proxy'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'inherit',
                                child: Text(context.tr('Kế thừa Group')),
                              ),
                              DropdownMenuItem(
                                value: 'direct',
                                child: Text(context.tr('Chỉ định Proxy')),
                              ),
                              DropdownMenuItem(
                                value: 'none',
                                child: Text(context.tr('Tắt Proxy')),
                              ),
                              if (![
                                'inherit',
                                'direct',
                                'none',
                              ].contains(_proxyMode))
                                DropdownMenuItem(
                                  value: _proxyMode,
                                  enabled: false,
                                  child: Text(
                                    context.tr('$_proxyMode (không hợp lệ)'),
                                  ),
                                ),
                            ],
                            onChanged: _protocol != 'ssh'
                                ? null
                                : (value) => setState(
                                    () => _proxyMode = value ?? 'inherit',
                                  ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: context.tr('Quản lý Proxy'),
                          onPressed: _protocol != 'ssh' ? null : _manageProxies,
                          icon: const Icon(
                            Icons.settings_ethernet_rounded,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    if (_proxyMode == 'direct') ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String?>(
                        key: ValueKey('proxySelection_$_proxyId'),
                        isExpanded: true,
                        initialValue: _proxyId,
                        decoration: InputDecoration(
                          labelText: context.tr('Proxy SSH'),
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(context.tr('Chọn Proxy…')),
                          ),
                          for (final proxy in proxies)
                            DropdownMenuItem(
                              value: proxy.id,
                              child: Text(
                                '${proxy.name} · ${proxy.host}:${proxy.port}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (_proxyId != null &&
                              !proxies.any((proxy) => proxy.id == _proxyId))
                            DropdownMenuItem(
                              value: _proxyId,
                              enabled: false,
                              child: Text(context.tr('Proxy không tồn tại')),
                            ),
                        ],
                        onChanged: _protocol != 'ssh'
                            ? null
                            : (value) => setState(() => _proxyId = value),
                      ),
                    ],
                    const SizedBox(height: 18),
                  ],
                  if (_protocol == 'ssh' || _protocol == 'local_shell') ...[
                    _formSection(
                      context,
                      Icons.terminal_rounded,
                      context.tr('Khi kết nối'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _startupDirCtrl,
                            enabled: _protocol != 'serial',
                            decoration: InputDecoration(
                              labelText: context.tr('Thư mục khởi động'),
                            ),
                          ),
                        ),
                        if (_protocol == 'ssh') const SizedBox(width: 8),
                        if (_protocol == 'ssh')
                          Expanded(
                            child: TextField(
                              controller: _startupCmdCtrl,
                              enabled: _protocol != 'serial',
                              decoration: InputDecoration(
                                labelText: context.tr('Lệnh chạy sau khi nối'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_protocol == 'ssh')
                    SwitchListTile(
                      value: _followSftp,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.tr('Bật SFTP Follow-Terminal mặc định'),
                      ),
                      onChanged: (v) => setState(() => _followSftp = v),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    InlineNotice(
                      key: const Key('hostEditorError'),
                      message: _error!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(context.tr('Huỷ')),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _saving ? context.tr('Đang lưu...') : context.tr('Lưu Host'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _serialChoice<T>({
    required String label,
    required Key key,
    required T value,
    required Map<T, String> choices,
    required ValueChanged<T> onChanged,
  }) => DropdownButtonFormField<T>(
    isExpanded: true,
    key: key,
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final choice in choices.entries)
        DropdownMenuItem(
          value: choice.key,
          child: Text(choice.value, overflow: TextOverflow.ellipsis),
        ),
      if (!choices.containsKey(value))
        DropdownMenuItem(
          value: value,
          enabled: false,
          child: Text(context.tr('$value (không hợp lệ)')),
        ),
    ],
    onChanged: !_serialSupported
        ? null
        : (next) {
            if (next != null) onChanged(next);
          },
  );
}

Widget _formSection(BuildContext context, IconData icon, String label) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 16, color: context.tp.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: context.tp.muted,
              ),
            ),
          ),
        ],
      ),
    );

Future<void> showCreateTunnelDialog(
  BuildContext context,
  WidgetRef ref, {
  TunnelDto? existing,
}) async {
  final inv = ref.read(inventoryProvider);
  final sshHosts = inv.hosts.where((host) => host.protocol == 'ssh').toList();
  if (sshHosts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr('Hãy tạo một kết nối SSH trước khi thêm Tunnel.'),
        ),
      ),
    );
    return;
  }
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final bindAddrCtrl = TextEditingController(
    text: existing?.bindAddr ?? '127.0.0.1',
  );
  final bindPortCtrl = TextEditingController(
    text: '${existing?.bindPort ?? 5432}',
  );
  final targetHostCtrl = TextEditingController(
    text: existing?.targetHost ?? '127.0.0.1',
  );
  final targetPortCtrl = TextEditingController(
    text: '${existing?.targetPort ?? 5432}',
  );
  String hostId = existing?.hostId ?? sshHosts.first.id;
  String kind = existing?.kind ?? 'local';
  bool saving = false;
  String? error;

  try {
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: Text(
              existing == null
                  ? ctx.tr('Tạo Tunnel SSH (-L / -R / -D)')
                  : ctx.tr('Chỉnh sửa Tunnel SSH'),
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        labelText: ctx.tr('Tên Tunnel (vd: Prod Postgres)'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: hostId,
                      decoration: InputDecoration(
                        labelText: ctx.tr('Qua SSH Host'),
                      ),
                      items: [
                        ...sshHosts.map(
                          (h) => DropdownMenuItem(
                            value: h.id,
                            child: Text(
                              h.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        if (!sshHosts.any((host) => host.id == hostId))
                          DropdownMenuItem(
                            value: hostId,
                            enabled: false,
                            child: Text(ctx.tr('SSH Host không khả dụng')),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => hostId = v ?? hostId),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: kind,
                      decoration: InputDecoration(
                        labelText: ctx.tr('Loại Forward'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'local',
                          child: Text(ctx.tr('Local (-L)')),
                        ),
                        DropdownMenuItem(
                          value: 'remote',
                          child: Text(ctx.tr('Remote (-R)')),
                        ),
                        DropdownMenuItem(
                          value: 'dynamic_socks',
                          child: Text(ctx.tr('Dynamic SOCKS5 (-D)')),
                        ),
                        if (![
                          'local',
                          'remote',
                          'dynamic_socks',
                        ].contains(kind))
                          DropdownMenuItem(
                            value: kind,
                            enabled: false,
                            child: Text(ctx.tr('$kind (chưa hỗ trợ)')),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => kind = v ?? 'local'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: bindAddrCtrl,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: ctx.tr('Địa chỉ Bind'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: bindPortCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: kind == 'remote'
                                  ? ctx.tr('Cổng Bind trên server')
                                  : ctx.tr('Cổng Bind trên máy này'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (kind != 'dynamic_socks') ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: targetHostCtrl,
                              decoration: InputDecoration(
                                labelText: ctx.tr('Target Host'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: targetPortCtrl,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: ctx.tr('Target Port'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      InlineNotice(message: error!),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                child: Text(ctx.tr('Huỷ')),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final bindPort = int.tryParse(bindPortCtrl.text.trim());
                        final enteredBindAddr = bindAddrCtrl.text.trim();
                        final bindAddr =
                            enteredBindAddr.startsWith('[') &&
                                enteredBindAddr.endsWith(']')
                            ? enteredBindAddr.substring(
                                1,
                                enteredBindAddr.length - 1,
                              )
                            : enteredBindAddr;
                        final targetPort = int.tryParse(
                          targetPortCtrl.text.trim(),
                        );
                        if (!sshHosts.any((host) => host.id == hostId) ||
                            ![
                              'local',
                              'remote',
                              'dynamic_socks',
                            ].contains(kind)) {
                          setLocal(
                            () =>
                                error = 'Chọn SSH Host và loại Forward hợp lệ.',
                          );
                          return;
                        }
                        if (bindAddr.isEmpty ||
                            bindAddr.contains(
                              RegExp(r'[\s/\x00-\x1f\x7f@?#]'),
                            ) ||
                            bindPort == null ||
                            bindPort < 1 ||
                            bindPort > 65535 ||
                            (kind != 'dynamic_socks' &&
                                (targetPort == null ||
                                    targetPort < 1 ||
                                    targetPort > 65535 ||
                                    targetHostCtrl.text.trim().isEmpty))) {
                          setLocal(
                            () => error =
                                'Nhập địa chỉ đích và port hợp lệ (1–65535).',
                          );
                          return;
                        }
                        setLocal(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          final t = TunnelDto(
                            id:
                                existing?.id ??
                                'tun_${DateTime.now().microsecondsSinceEpoch}',
                            name: nameCtrl.text.trim().isEmpty
                                ? 'Tunnel'
                                : nameCtrl.text.trim(),
                            hostId: hostId,
                            kind: kind,
                            bindAddr: bindAddr,
                            bindPort: bindPort,
                            targetHost: kind == 'dynamic_socks'
                                ? null
                                : targetHostCtrl.text.trim(),
                            targetPort: kind == 'dynamic_socks'
                                ? null
                                : targetPort,
                            autoStart: existing?.autoStart ?? false,
                          );
                          await ref
                              .read(inventoryProvider.notifier)
                              .saveTunnel(t);
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        } catch (e) {
                          if (ctx.mounted) {
                            setLocal(() => error = e.toString());
                          }
                        } finally {
                          if (ctx.mounted) setLocal(() => saving = false);
                        }
                      },
                child: Text(
                  saving ? ctx.tr('Đang lưu...') : ctx.tr('Lưu Tunnel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
  } finally {
    nameCtrl.dispose();
    bindAddrCtrl.dispose();
    bindPortCtrl.dispose();
    targetHostCtrl.dispose();
    targetPortCtrl.dispose();
  }
}
