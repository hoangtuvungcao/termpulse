import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

const quickConnectHint = 'ssh user@host · telnet host 23';
const quickConnectSyntaxHelp =
    'user@host:port\nssh [-p port] user@host\ntelnet host [port]\n'
    'ssh user@[IPv6]:port';

enum QuickConnectProtocol { ssh, telnet }

enum QuickConnectError {
  syntax,
  hostname,
  username,
  port,
  duplicatePort,
  unsupportedProtocol,
}

class QuickConnectException implements Exception {
  const QuickConnectException(this.error);
  final QuickConnectError error;

  @override
  String toString() => 'QuickConnectException(${error.name})';
}

class QuickConnectTarget {
  const QuickConnectTarget({
    required this.protocol,
    required this.hostname,
    required this.port,
    this.username,
  });

  final QuickConnectProtocol protocol;
  final String hostname;
  final int port;
  final String? username;

  String get endpoint =>
      '${hostname.contains(':') ? '[$hostname]' : hostname}:$port';

  /// Canonical native SSH syntax. Never contains a password or shell command.
  String get sshTarget => '${username ?? 'root'}@$endpoint';

  String get displayName =>
      protocol == QuickConnectProtocol.ssh ? sshTarget : endpoint;
}

Never _invalid(QuickConnectError error) => throw QuickConnectException(error);

int _port(String text) {
  if (!RegExp(r'^[0-9]{1,5}$').hasMatch(text)) {
    _invalid(QuickConnectError.port);
  }
  final port = int.tryParse(text);
  if (port == null || port < 1 || port > 65535) {
    _invalid(QuickConnectError.port);
  }
  return port;
}

({String hostname, int? port}) _endpoint(String value) {
  String host;
  int? port;
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end < 0) _invalid(QuickConnectError.hostname);
    host = value.substring(1, end);
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
      _invalid(QuickConnectError.hostname);
    }
    final rest = value.substring(end + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) _invalid(QuickConnectError.hostname);
      port = _port(rest.substring(1));
    }
  } else if (':'.allMatches(value).length > 1) {
    host = value;
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
      _invalid(QuickConnectError.hostname);
    }
  } else {
    final colon = value.indexOf(':');
    host = colon < 0 ? value : value.substring(0, colon);
    if (colon >= 0) port = _port(value.substring(colon + 1));
    if (host.isEmpty ||
        host.length > 253 ||
        !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(host) ||
        host.contains('..') ||
        host.split('.').any((label) => label.length > 63) ||
        (RegExp(r'^[0-9]+(?:\.[0-9]+){3}$').hasMatch(host) &&
            InternetAddress.tryParse(host) == null)) {
      _invalid(QuickConnectError.hostname);
    }
  }
  return (hostname: host, port: port);
}

/// Parses a small, explicit terminal-like grammar; never invokes a shell.
/// Remote commands, passwords in addresses, URIs, and unrelated SSH options
/// are rejected rather than silently discarded or sent to the wrong host.
QuickConnectTarget parseQuickConnect(String input) {
  final text = input.trim();
  if (text.isEmpty ||
      text.length > 2048 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
    _invalid(QuickConnectError.syntax);
  }
  final tokens = text.split(RegExp(r'\s+'));
  final command = tokens.first.toLowerCase();
  if (text.contains('://') ||
      const {'rdp', 'vnc', 'sftp', 'ftp', 'http', 'https'}.contains(command)) {
    _invalid(QuickConnectError.unsupportedProtocol);
  }
  if (command == 'telnet') {
    if (tokens.length < 2 || tokens.length > 3) {
      _invalid(QuickConnectError.syntax);
    }
    if (tokens[1].contains('@')) _invalid(QuickConnectError.username);
    final address = _endpoint(tokens[1]);
    final explicitPort = tokens.length == 3 ? _port(tokens[2]) : null;
    if (address.port != null && explicitPort != null) {
      _invalid(QuickConnectError.duplicatePort);
    }
    return QuickConnectTarget(
      protocol: QuickConnectProtocol.telnet,
      hostname: address.hostname,
      port: explicitPort ?? address.port ?? 23,
    );
  }
  String? destination;
  int? optionPort;
  if (command == 'ssh') {
    for (var index = 1; index < tokens.length; index++) {
      final token = tokens[index];
      if (token == '-p' || token.startsWith('-p')) {
        if (optionPort != null) _invalid(QuickConnectError.duplicatePort);
        String value;
        if (token == '-p') {
          if (++index >= tokens.length) _invalid(QuickConnectError.port);
          value = tokens[index];
        } else {
          value = token.substring(2);
        }
        optionPort = _port(value);
      } else if (token.startsWith('-') || destination != null) {
        _invalid(QuickConnectError.syntax);
      } else {
        destination = token;
      }
    }
  } else {
    if (tokens.length != 1) _invalid(QuickConnectError.syntax);
    destination = tokens.single;
  }
  if (destination == null || destination.isEmpty) {
    _invalid(QuickConnectError.syntax);
  }
  final at = destination.indexOf('@');
  final username = at < 0 ? 'root' : destination.substring(0, at);
  if (username.isEmpty ||
      username.length > 256 ||
      username.startsWith('-') ||
      RegExp(r'''[\s@:/\[\]?#;"'`$|&<>]''').hasMatch(username)) {
    _invalid(QuickConnectError.username);
  }
  final address = _endpoint(
    at < 0 ? destination : destination.substring(at + 1),
  );
  if (address.port != null && optionPort != null) {
    _invalid(QuickConnectError.duplicatePort);
  }
  return QuickConnectTarget(
    protocol: QuickConnectProtocol.ssh,
    hostname: address.hostname,
    port: optionPort ?? address.port ?? 22,
    username: username,
  );
}

// Local copy belongs to this helper so both shells get identical notices
// without introducing a dependency from the central catalog back to widgets.
const _validation = <QuickConnectError, List<String>>{
  QuickConnectError.syntax: [
    'Dùng cú pháp SSH hoặc Telnet bên dưới. Không thêm lệnh từ xa hay tuỳ chọn khác.',
    'Use the SSH or Telnet syntax below. Do not add remote commands or other options.',
    '请使用下方 SSH 或 Telnet 语法，不要附加远程命令或其他选项。',
    '以下の SSH または Telnet の書式を使ってください。リモートコマンドや他のオプションは追加できません。',
    '아래 SSH 또는 Telnet 형식을 사용하세요. 원격 명령이나 다른 옵션은 추가할 수 없습니다.',
  ],
  QuickConnectError.hostname: [
    'Tên máy chủ hoặc địa chỉ IP chưa hợp lệ. Với IPv6 và cổng riêng, dùng [IPv6]:port.',
    'Enter a valid hostname or IP address. Use [IPv6]:port to specify an IPv6 port.',
    '请输入有效的主机名或 IP 地址。为 IPv6 指定端口时请使用 [IPv6]:port。',
    '有効なホスト名または IP アドレスを入力してください。IPv6 のポート指定は [IPv6]:port です。',
    '올바른 호스트 이름이나 IP 주소를 입력하세요. IPv6 포트는 [IPv6]:port로 지정하세요.',
  ],
  QuickConnectError.username: [
    'Kiểm tra tên đăng nhập. Không ghi mật khẩu trong ô địa chỉ; SSH sẽ hỏi mật khẩu riêng.',
    'Check the username. Do not put passwords in the address; SSH asks for a password separately.',
    '请检查用户名。不要在地址中填写密码，SSH 将单独询问密码。',
    'ユーザー名を確認してください。アドレスにパスワードを含めないでください。SSH のパスワードは別に入力します。',
    '사용자 이름을 확인하세요. 주소에 비밀번호를 넣지 마세요. SSH 비밀번호는 별도로 입력합니다.',
  ],
  QuickConnectError.port: [
    'Cổng phải là số từ 1 đến 65535.',
    'The port must be a number from 1 to 65535.',
    '端口必须是 1 到 65535 之间的数字。',
    'ポートには 1～65535 の数値を指定してください。',
    '포트는 1~65535 사이의 숫자여야 합니다.',
  ],
  QuickConnectError.duplicatePort: [
    'Chỉ nhập cổng một lần: trong địa chỉ hoặc bằng -p.',
    'Specify the port once: in the address or with -p.',
    '请只指定一次端口：在地址中或使用 -p。',
    'ポートはアドレス内または -p のいずれか一度だけ指定してください。',
    '포트는 주소 또는 -p 중 한 곳에만 지정하세요.',
  ],
  QuickConnectError.unsupportedProtocol: [
    'Ô kết nối nhanh hỗ trợ SSH và Telnet. Hãy thêm Host để cấu hình RDP, VNC hoặc giao thức khác được ứng dụng hỗ trợ.',
    'Quick Connect supports SSH and Telnet. Add a Host to configure RDP, VNC, or another supported connection type.',
    '快速连接支持 SSH 和 Telnet。请添加主机以配置 RDP、VNC 或应用支持的其他连接类型。',
    'クイック接続は SSH と Telnet に対応しています。RDP、VNC など対応する接続はホストを追加して設定してください。',
    '빠른 연결은 SSH와 Telnet을 지원합니다. RDP, VNC 등 지원되는 연결은 호스트를 추가하여 설정하세요.',
  ],
};

String quickConnectValidationMessage(
  QuickConnectError error,
  AppLanguage language,
) => _validation[error]![language.index];

enum _Copy {
  sshTitle,
  password,
  optionalPassword,
  telnetTitle,
  telnetNotice,
  failed,
}

const _copy = <_Copy, List<String>>{
  _Copy.sshTitle: [
    'Kết nối SSH',
    'Connect with SSH',
    'SSH 连接',
    'SSH 接続',
    'SSH 연결',
  ],
  _Copy.password: [
    'Mật khẩu SSH',
    'SSH password',
    'SSH 密码',
    'SSH パスワード',
    'SSH 비밀번호',
  ],
  _Copy.optionalPassword: [
    'Để trống nếu tài khoản không yêu cầu mật khẩu.',
    'Leave empty if the account does not require a password.',
    '如果账户不需要密码，请留空。',
    'パスワードが不要なアカウントは空欄にしてください。',
    '계정에 비밀번호가 필요하지 않으면 비워 두세요.',
  ],
  _Copy.telnetTitle: [
    'Kết nối Telnet',
    'Connect with Telnet',
    'Telnet 连接',
    'Telnet 接続',
    'Telnet 연결',
  ],
  _Copy.telnetNotice: [
    'Telnet không mã hóa nội dung và thông tin đăng nhập. Chỉ tiếp tục trên mạng bạn tin cậy; nên dùng SSH khi có thể.',
    'Telnet does not encrypt content or sign-in details. Continue only on a trusted network; use SSH when available.',
    'Telnet 不会加密内容或登录信息。请仅在可信网络上继续，建议尽可能使用 SSH。',
    'Telnet は通信内容やログイン情報を暗号化しません。信頼できるネットワークでのみ続行し、可能なら SSH を使ってください。',
    'Telnet은 내용과 로그인 정보를 암호화하지 않습니다. 신뢰할 수 있는 네트워크에서만 계속하고 가능하면 SSH를 사용하세요.',
  ],
  _Copy.failed: [
    'Chưa thể bắt đầu kết nối. Hãy mở lại Vault rồi thử lại.',
    'Could not start the connection. Reopen the Vault and try again.',
    '无法开始连接。请重新打开保险库后重试。',
    '接続を開始できませんでした。Vault を開き直して再試行してください。',
    '연결을 시작하지 못했습니다. Vault를 다시 열고 시도하세요.',
  ],
};

String _text(_Copy copy, AppLanguage language) => _copy[copy]![language.index];

void _notice(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      width: (MediaQuery.sizeOf(context).width - 32).clamp(1.0, 720.0),
      content: Text(text, key: const Key('quickConnectValidationNotice')),
      duration: const Duration(seconds: 8),
    ),
  );
}

/// Opens only supported transports through the existing session controller.
/// True means dispatched, not authenticated. False means cancelled or invalid.
Future<bool> showQuickConnect(
  BuildContext context,
  WidgetRef ref,
  String input,
) async {
  if (input.trim().isEmpty || !context.mounted) return false;
  final language = ref.read(settingsProvider).language;
  final strings = AppStrings(language);
  late final QuickConnectTarget target;
  try {
    target = parseQuickConnect(input);
  } on QuickConnectException catch (error) {
    _notice(
      context,
      '${quickConnectValidationMessage(error.error, language)}\n\n'
      '$quickConnectSyntaxHelp',
    );
    return false;
  }
  final manager = ref.read(sessionManagerProvider.notifier);
  try {
    if (target.protocol == QuickConnectProtocol.telnet) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('quickConnectTelnetDialog'),
          alignment: Alignment.center,
          scrollable: true,
          title: Text(_text(_Copy.telnetTitle, language)),
          content: SizedBox(
            width: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(target.endpoint),
                const SizedBox(height: 12),
                Text(
                  _text(_Copy.telnetNotice, language),
                  key: const Key('quickConnectTelnetNotice'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('quickConnectCancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('quickConnectSubmit'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.connect),
            ),
          ],
        ),
      );
      if (approved != true || !context.mounted) return false;
      await manager.openTelnet(
        target.hostname,
        target.port,
        label: 'Telnet ${target.endpoint}',
      );
      return true;
    }
    final controller = TextEditingController();
    String? password;
    final route = DialogRoute<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('quickConnectPasswordDialog'),
        alignment: Alignment.center,
        scrollable: true,
        title: Text(_text(_Copy.sshTitle, language)),
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(target.sshTarget),
              const SizedBox(height: 12),
              TextField(
                key: const Key('quickConnectPasswordField'),
                controller: controller,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _text(_Copy.password, language),
                ),
                onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
              ),
              const SizedBox(height: 8),
              Text(_text(_Copy.optionalPassword, language)),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('quickConnectCancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('quickConnectSubmit'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.connect),
          ),
        ],
      ),
    );
    try {
      password = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      controller.clear();
      controller.dispose();
    }
    if (!context.mounted || password == null) return false;
    await manager.openQuickSsh(
      target: target.sshTarget,
      password: password.isEmpty ? null : password,
    );
    return true;
  } catch (_) {
    if (context.mounted) _notice(context, _text(_Copy.failed, language));
    return false;
  }
}
