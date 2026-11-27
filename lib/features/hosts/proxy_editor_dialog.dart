import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

const _proxyKinds = {
  'socks5': 'SOCKS5',
  'socks4': 'SOCKS4',
  'http_connect': 'HTTP CONNECT',
};

const _httpAuthMethods = {
  'basic': 'Basic',
  'ntlm': 'NTLMv2',
  'kerberos': 'Kerberos / Negotiate',
};

Future<ProxyDto?> showProxyManagerDialog(
  BuildContext context,
  WidgetRef ref, {
  String? selectedProxyId,
}) => showDialog<ProxyDto>(
  context: context,
  builder: (_) => _ProxyManagerDialog(selectedProxyId: selectedProxyId),
);

Future<ProxyDto?> showProxyEditorDialog(
  BuildContext context,
  WidgetRef ref, {
  ProxyDto? existing,
}) => showDialog<ProxyDto>(
  context: context,
  builder: (_) => _ProxyEditorDialog(existing: existing),
);

class _ProxyManagerDialog extends ConsumerStatefulWidget {
  final String? selectedProxyId;
  const _ProxyManagerDialog({this.selectedProxyId});

  @override
  ConsumerState<_ProxyManagerDialog> createState() =>
      _ProxyManagerDialogState();
}

class _ProxyManagerDialogState extends ConsumerState<_ProxyManagerDialog> {
  List<ProxyDto> _proxies = [];
  bool _loading = true;
  bool _openingEditor = false;
  bool _deleting = false;
  String? _error;
  String? _actionError;
  int _loadVersion = 0;

  bool get _busy => _openingEditor || _deleting;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final proxies = List<ProxyDto>.of(
        await ref.read(backendProvider).listProxies(),
      );
      proxies.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (mounted && version == _loadVersion) {
        setState(() => _proxies = proxies);
      }
    } catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _edit([ProxyDto? proxy]) async {
    if (_busy) return;
    setState(() => _openingEditor = true);
    try {
      final saved = await showProxyEditorDialog(context, ref, existing: proxy);
      if (!mounted) return;
      if (saved != null) await _load();
    } finally {
      if (mounted) setState(() => _openingEditor = false);
    }
  }

  Future<void> _delete(ProxyDto proxy) async {
    if (_busy) return;
    setState(() {
      _deleting = true;
      _actionError = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.tr('Xoá Proxy?')),
          content: Text(
            context.tr(
              'Xoá cấu hình “${proxy.name}”? Mật khẩu trong Vault sẽ được giữ lại. Proxy còn được Host hoặc Group tham chiếu sẽ không bị xoá; hãy đổi cấu hình của các mục đó trước.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.tr('Huỷ')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: context.tp.red),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.tr('Xoá Proxy')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await ref.read(inventoryProvider.notifier).deleteProxy(proxy.id);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        setState(() => _actionError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_deleting,
    child: AlertDialog(
      key: const Key('proxyManagerDialog'),
      title: Text(context.tr('Quản lý Proxy SSH')),
      content: SizedBox(
        width: 480,
        height: (MediaQuery.sizeOf(context).height * 0.48).clamp(180.0, 380.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(
                'Chọn Proxy để áp dụng cho Host. Hỗ trợ SOCKS5, SOCKS4 và HTTP CONNECT.',
              ),
              style: TextStyle(
                fontSize: 12.5,
                color: context.tp.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            if (_actionError != null) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 88),
                child: SingleChildScrollView(
                  child: InlineNotice(message: _actionError!),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? SingleChildScrollView(
                      child: Column(
                        children: [
                          Icon(
                            Icons.cloud_off_rounded,
                            color: context.tp.muted,
                            size: 32,
                          ),
                          const SizedBox(height: 10),
                          InlineNotice(message: _error!),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded, size: 17),
                            label: Text(context.tr('Thử tải lại')),
                          ),
                        ],
                      ),
                    )
                  : _proxies.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.router_outlined,
                            size: 36,
                            color: context.tp.muted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            context.tr('Chưa có Proxy'),
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            context.tr(
                              'Thêm cấu hình để kết nối SSH qua Proxy.',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: context.tp.muted,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _proxies.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (_, index) {
                        final proxy = _proxies[index];
                        final selected = proxy.id == widget.selectedProxyId;
                        return Material(
                          color: selected
                              ? context.tp.accentContainer
                              : context.tp.surface2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: selected
                                  ? context.tp.accent
                                  : context.tp.border,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(
                              left: 12,
                              right: 4,
                            ),
                            leading: Icon(
                              selected
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.router_outlined,
                              color: context.tp.accent,
                              size: 21,
                            ),
                            title: Text(
                              proxy.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${_proxyKinds[proxy.kind] ?? proxy.kind}${proxy.tls == true ? ' · TLS' : ''} · ${proxy.host}:${proxy.port}${proxy.username == null ? '' : '\n${proxy.username}${proxy.credentialId == null ? '' : ' · Vault'}'}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: context.tp.muted,
                              ),
                            ),
                            onTap: _busy
                                ? null
                                : () => Navigator.of(context).pop(proxy),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: context.tr('Chỉnh sửa Proxy'),
                                  onPressed: _busy ? null : () => _edit(proxy),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  tooltip: context.tr('Xoá Proxy'),
                                  onPressed: _busy
                                      ? null
                                      : () => _delete(proxy),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.tr('Đóng')),
        ),
        FilledButton.icon(
          key: const Key('addProxyButton'),
          onPressed: _busy ? null : _edit,
          icon: const Icon(Icons.add_rounded, size: 17),
          label: Text(context.tr('Thêm Proxy')),
        ),
      ],
    ),
  );
}

class _ProxyEditorDialog extends ConsumerStatefulWidget {
  final ProxyDto? existing;
  const _ProxyEditorDialog({this.existing});

  @override
  ConsumerState<_ProxyEditorDialog> createState() => _ProxyEditorDialogState();
}

class _ProxyEditorDialogState extends ConsumerState<_ProxyEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _tlsServerNameCtrl;
  late final TextEditingController _tlsCaCtrl;
  late final TextEditingController _authDomainCtrl;
  late final TextEditingController _authSpnCtrl;
  late final TextEditingController _authKdcCtrl;
  final _passwordCtrl = TextEditingController();
  late final String _proxyId;
  late String _kind;
  late bool _authenticate;
  late bool _tls;
  late String _authMethod;
  String? _newCredentialId;
  String? _error;
  bool _saving = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    final proxy = widget.existing;
    _proxyId = proxy?.id ?? 'proxy_${DateTime.now().microsecondsSinceEpoch}';
    _nameCtrl = TextEditingController(text: proxy?.name ?? '');
    _hostCtrl = TextEditingController(text: proxy?.host ?? '');
    _portCtrl = TextEditingController(text: '${proxy?.port ?? 1080}');
    _usernameCtrl = TextEditingController(text: proxy?.username ?? '');
    _tlsServerNameCtrl = TextEditingController(
      text: proxy?.tlsServerName ?? '',
    );
    _tlsCaCtrl = TextEditingController(text: proxy?.tlsCaPem ?? '');
    _authDomainCtrl = TextEditingController(text: proxy?.authDomain ?? '');
    _authSpnCtrl = TextEditingController(text: proxy?.authSpn ?? '');
    _authKdcCtrl = TextEditingController(text: proxy?.authKdcUrl ?? '');
    _kind = proxy?.kind ?? 'socks5';
    _tls = proxy?.tls ?? false;
    _authMethod = proxy?.authMethod == 'none'
        ? 'basic'
        : proxy?.authMethod ?? 'basic';
    _authenticate =
        _kind != 'socks4' &&
        (proxy?.authMethod != null
            ? proxy!.authMethod != 'none'
            : proxy?.credentialId != null || _usernameCtrl.text.isNotEmpty);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _tlsServerNameCtrl.dispose();
    _tlsCaCtrl.dispose();
    _authDomainCtrl.dispose();
    _authSpnCtrl.dispose();
    _authKdcCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    final enteredHost = _hostCtrl.text.trim();
    final host = enteredHost.startsWith('[') && enteredHost.endsWith(']')
        ? enteredHost.substring(1, enteredHost.length - 1)
        : enteredHost;
    final port = int.tryParse(_portCtrl.text.trim());
    final username = _usernameCtrl.text.trim();
    final tlsServerName = _tlsServerNameCtrl.text.trim();
    final tlsCa = _tlsCaCtrl.text.trim();
    final authDomain = _authDomainCtrl.text.trim();
    final authSpn = _authSpnCtrl.text.trim();
    final authKdc = _authKdcCtrl.text.trim();
    final http = _kind == 'http_connect';
    final needsPassword = _kind != 'socks4' && _authenticate;
    final integratedAuth =
        http && needsPassword && ['ntlm', 'kerberos'].contains(_authMethod);
    final kerberos = http && needsPassword && _authMethod == 'kerberos';
    String? error;
    if (name.isEmpty) {
      error = 'Nhập tên hiển thị cho Proxy.';
    } else if (!_proxyKinds.containsKey(_kind)) {
      error = 'Chọn loại Proxy được hỗ trợ.';
    } else if (host.isEmpty ||
        host.contains(RegExp(r'[\s/\x00-\x1f\x7f@?#]'))) {
      error =
          'Nhập hostname hoặc IP của Proxy, không kèm giao thức hay đường dẫn.';
    } else if (port == null || port < 1 || port > 65535) {
      error = 'Port Proxy phải là số từ 1 đến 65535.';
    } else if (username.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      error = 'Username Proxy không được chứa ký tự điều khiển.';
    } else if (http &&
        _authenticate &&
        !_httpAuthMethods.containsKey(_authMethod)) {
      error = 'Chọn phương thức xác thực HTTP CONNECT được hỗ trợ.';
    } else if (http &&
        _tls &&
        tlsServerName.isNotEmpty &&
        tlsServerName.contains(RegExp(r'[\s/\x00-\x1f\x7f@?#]'))) {
      error = 'Tên máy chủ TLS phải là hostname hoặc IP, không kèm đường dẫn.';
    } else if (http && _tls && tlsCa.isNotEmpty && !_validCaPem(tlsCa)) {
      error =
          'CA TLS phải là chứng chỉ PEM hợp lệ, tối đa 256 KiB; không dán Private Key.';
    } else if (needsPassword &&
        (username.isEmpty ||
            (_passwordCtrl.text.isEmpty &&
                widget.existing?.credentialId == null))) {
      error = 'Nhập username và mật khẩu cho Proxy yêu cầu xác thực.';
    } else if (needsPassword &&
        http &&
        _authMethod == 'basic' &&
        username.contains(':')) {
      error = 'Username HTTP CONNECT không được chứa dấu hai chấm (:).';
    } else if (needsPassword &&
        _kind == 'socks5' &&
        (utf8.encode(username).length > 255 ||
            utf8.encode(_passwordCtrl.text).length > 255)) {
      error = 'Username và mật khẩu SOCKS5 không được vượt quá 255 byte UTF-8.';
    } else if (integratedAuth &&
        (authDomain.length > 255 ||
            authDomain.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
      error =
          'Domain / Realm không được chứa ký tự điều khiển hoặc dài quá 255 ký tự.';
    } else if (kerberos &&
        authSpn.isNotEmpty &&
        (authSpn.length > 1024 ||
            !RegExp(r'^HTTP/[^\s/\x00-\x1f\x7f@?#]+$').hasMatch(authSpn))) {
      error = 'SPN Kerberos phải có dạng HTTP/proxy.example.com.';
    } else if (kerberos && !_validKdcUrl(authKdc)) {
      error =
          'KDC URL phải dùng tcp://, udp:// hoặc https://, có hostname và không chứa userinfo hay fragment.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final backend = ref.read(backendProvider);
      String? credentialId = needsPassword
          ? widget.existing?.credentialId
          : null;
      if (needsPassword && _passwordCtrl.text.isNotEmpty) {
        credentialId = _newCredentialId ??=
            'proxy_cred_${DateTime.now().microsecondsSinceEpoch}';
        await backend.upsertCredential(
          CredentialDto(
            id: credentialId,
            name: '$name Proxy Password',
            kind: 'password',
            secret: _passwordCtrl.text,
            storageBackend: 'vault',
          ),
        );
      }
      final proxy = ProxyDto(
        id: _proxyId,
        name: name,
        kind: _kind,
        host: host,
        port: port!,
        username: (_kind == 'socks4' || needsPassword) && username.isNotEmpty
            ? username
            : null,
        credentialId: credentialId,
        tls: http ? _tls : null,
        tlsServerName: http && _tls && tlsServerName.isNotEmpty
            ? tlsServerName
            : null,
        tlsCaPem: http && _tls && tlsCa.isNotEmpty ? tlsCa : null,
        authMethod: http ? (_authenticate ? _authMethod : 'none') : null,
        authDomain: integratedAuth && authDomain.isNotEmpty ? authDomain : null,
        authSpn: kerberos && authSpn.isNotEmpty ? authSpn : null,
        authKdcUrl: kerberos && authKdc.isNotEmpty ? authKdc : null,
      );
      await backend.upsertProxy(proxy);
      await ref.read(inventoryProvider.notifier).refreshAll();
      if (mounted) Navigator.of(context).pop(proxy);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _validCaPem(String value) {
    if (utf8.encode(value).length > 256 * 1024 ||
        value.contains('PRIVATE KEY')) {
      return false;
    }
    final pattern = RegExp(
      r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
    );
    final matches = pattern.allMatches(value).toList();
    if (matches.isEmpty || value.replaceAll(pattern, '').trim().isNotEmpty) {
      return false;
    }
    try {
      return matches.every(
        (match) => base64
            .decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''))
            .isNotEmpty,
      );
    } on FormatException {
      return false;
    }
  }

  bool _validKdcUrl(String value) {
    if (value.length > 2048 || value.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['tcp', 'udp', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return false;
    }
    return uri.scheme == 'https' ||
        ((uri.path.isEmpty || uri.path == '/') && !uri.hasQuery);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      key: const Key('proxyEditorDialog'),
      scrollable: true,
      title: Text(
        widget.existing == null
            ? context.tr('Thêm Proxy SSH')
            : context.tr('Chỉnh sửa Proxy SSH'),
      ),
      content: SizedBox(
        width: 440,
        child: AbsorbPointer(
          absorbing: _saving,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: context.tr('Tên Proxy *'),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.tr('Loại Proxy'),
                ),
                items: [
                  for (final kind in _proxyKinds.entries)
                    DropdownMenuItem(value: kind.key, child: Text(kind.value)),
                  if (!_proxyKinds.containsKey(_kind))
                    DropdownMenuItem(
                      value: _kind,
                      enabled: false,
                      child: Text(context.tr('$_kind (chưa hỗ trợ)')),
                    ),
                ],
                onChanged: (value) => setState(() {
                  final next = value ?? 'socks5';
                  if (next == 'http_connect' && _portCtrl.text == '1080') {
                    _portCtrl.text = '8080';
                  }
                  if (next != 'http_connect' && _portCtrl.text == '8080') {
                    _portCtrl.text = '1080';
                  }
                  _kind = next;
                }),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _hostCtrl,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: context.tr('Hostname / IP Proxy *'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: context.tr('Port Proxy'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_kind == 'http_connect') ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    context.tr('TLS tới Proxy'),
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    context.tr('Luôn kiểm tra chuỗi chứng chỉ và tên máy chủ.'),
                  ),
                  value: _tls,
                  onChanged: (value) => setState(() => _tls = value),
                ),
                if (_tls) ...[
                  TextField(
                    controller: _tlsServerNameCtrl,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: context.tr('Tên máy chủ TLS (tuỳ chọn)'),
                      helperText: context.tr(
                        'Để trống để xác minh bằng hostname / IP Proxy.',
                      ),
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tlsCaCtrl,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 3,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: context.tr('CA PEM riêng (tuỳ chọn)'),
                      helperText: context.tr(
                        'Chỉ dán chứng chỉ CA công khai. Để trống để dùng CA tin cậy của ứng dụng.',
                      ),
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
              if (_kind != 'socks4')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    context.tr('Proxy yêu cầu xác thực'),
                    style: TextStyle(fontSize: 13),
                  ),
                  value: _authenticate,
                  onChanged: (value) => setState(() => _authenticate = value),
                ),
              if (_kind == 'http_connect' && _authenticate) ...[
                DropdownButtonFormField<String>(
                  initialValue: _authMethod,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.tr('Xác thực HTTP CONNECT'),
                  ),
                  items: [
                    for (final method in _httpAuthMethods.entries)
                      DropdownMenuItem(
                        value: method.key,
                        child: Text(method.value),
                      ),
                    if (!_httpAuthMethods.containsKey(_authMethod))
                      DropdownMenuItem(
                        value: _authMethod,
                        enabled: false,
                        child: Text(context.tr('$_authMethod (chưa hỗ trợ)')),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _authMethod = value ?? 'basic'),
                ),
                const SizedBox(height: 12),
              ],
              if (_kind == 'socks4' || _authenticate) ...[
                TextField(
                  controller: _usernameCtrl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _kind == 'socks4'
                        ? context.tr('SOCKS4 User ID (tuỳ chọn)')
                        : 'Username Proxy *',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_kind != 'socks4' && _authenticate)
                TextField(
                  controller: _passwordCtrl,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.tr('Mật khẩu Proxy'),
                    helperText: widget.existing?.credentialId == null
                        ? context.tr('Mật khẩu được lưu trong Vault.')
                        : context.tr('Để trống để giữ mật khẩu đã lưu.'),
                    helperMaxLines: 2,
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? context.tr('Ẩn mật khẩu Proxy')
                          : context.tr('Hiện mật khẩu Proxy'),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
              if (_kind == 'http_connect' &&
                  _authenticate &&
                  ['ntlm', 'kerberos'].contains(_authMethod)) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _authDomainCtrl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.tr('Domain / Realm (tuỳ chọn)'),
                    helperText: context.tr(
                      'Có thể dùng username dạng DOMAIN\\user hoặc user@REALM.',
                    ),
                    helperMaxLines: 2,
                  ),
                ),
              ],
              if (_kind == 'http_connect' &&
                  _authenticate &&
                  _authMethod == 'kerberos') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _authSpnCtrl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.tr('SPN Kerberos (tuỳ chọn)'),
                    hintText: 'HTTP/proxy.example.com',
                    helperText: context.tr(
                      'Để trống để dùng HTTP/<tên máy chủ TLS hoặc hostname Proxy>.',
                    ),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _authKdcCtrl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.tr('KDC URL *'),
                    hintText: 'tcp://kdc.example.com:88',
                    helperText: context.tr(
                      'Bắt buộc cho Kerberos. Dùng tcp://kdc.example:88, udp://kdc.example:88 hoặc HTTPS KDC Proxy.',
                    ),
                    helperMaxLines: 3,
                  ),
                ),
              ],
              if (_kind == 'socks4')
                Text(
                  context.tr('SOCKS4 dùng User ID và không hỗ trợ mật khẩu.'),
                  style: TextStyle(
                    color: context.tp.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                InlineNotice(message: _error!),
              ],
            ],
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
            _saving ? context.tr('Đang lưu…') : context.tr('Lưu Proxy'),
          ),
        ),
      ],
    ),
  );
}
