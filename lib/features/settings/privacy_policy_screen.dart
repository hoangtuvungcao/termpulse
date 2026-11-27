import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/legal_config.dart';

/// An offline copy of the privacy notice. Reading it does not grant consent or
/// request a permission; optional data sharing has its own feature-level flow.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  bool? _vietnamese;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vietnamese ??= AppLocalizationScope.of(context) == AppLanguage.vi;
  }

  @override
  Widget build(BuildContext context) {
    final vi = _vietnamese ?? true;
    final theme = Theme.of(context);
    final sections = vi ? _vietnamesePolicy : _englishPolicy;

    return Scaffold(
      key: const Key('privacyPolicyScreen'),
      appBar: AppBar(title: Text(context.tr('Chính sách quyền riêng tư'))),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    key: const Key('privacyPolicyLanguageToggle'),
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Tiếng Việt'),
                        selected: vi,
                        onSelected: (_) => setState(() => _vietnamese = true),
                      ),
                      ChoiceChip(
                        label: const Text('English'),
                        selected: !vi,
                        onSelected: (_) => setState(() => _vietnamese = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    vi ? 'Chính sách quyền riêng tư' : 'Privacy policy',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${vi ? 'Phiên bản' : 'Version'}: ${AppLegalConfig.policyVersion}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  if (!AppLegalConfig.isConfigured)
                    Container(
                      key: const Key('privacyConfigurationNotice'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        vi
                            ? 'BẢN THỬ NGHIỆM — Cấu hình phát hành chưa hoàn tất. Chưa có đầy đủ danh tính đơn vị phát hành, email liên hệ và địa chỉ HTTPS công khai của chính sách. Nội dung dưới đây là bản dự thảo trong ứng dụng; chưa thể dùng để xác nhận sẵn sàng phát hành trên Google Play.'
                            : 'TEST BUILD — Release configuration is incomplete. The publisher identity, contact email and public HTTPS privacy-policy address have not all been supplied. This in-app notice is a draft and does not establish readiness for Google Play release.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    )
                  else
                    SelectionArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${vi ? 'Đơn vị phát hành' : 'Publisher'}: ${AppLegalConfig.publisherName}',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${vi ? 'Liên hệ về quyền riêng tư' : 'Privacy contact'}: ${AppLegalConfig.contactEmail}',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${vi ? 'Chính sách công khai' : 'Public policy'}: ${AppLegalConfig.privacyPolicyUrl}',
                          ),
                        ],
                      ),
                    ),
                  for (final section in sections) ...[
                    const SizedBox(height: 24),
                    Text(section.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SelectableText(
                      section.body,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PolicySection {
  final String title;
  final String body;
  const _PolicySection(this.title, this.body);
}

const _vietnamesePolicy = [
  _PolicySection(
    '1. Phạm vi và lựa chọn của bạn',
    'TermPulse là công cụ terminal, quản lý kết nối và truy cập từ xa. Ứng dụng không yêu cầu tài khoản TermPulse. Bản ứng dụng này không tích hợp quảng cáo, SDK phân tích hành vi hoặc cơ chế tự động gửi dữ liệu sử dụng về đơn vị phát hành. Bạn chọn máy chủ, proxy và dịch vụ AI để kết nối. Việc đọc chính sách không cấp quyền Android và không đồng ý thay bạn cho việc gửi dữ liệu tùy chọn.',
  ),
  _PolicySection(
    '2. Dữ liệu được lưu trên thiết bị',
    'Ứng dụng lưu hồ sơ kết nối như tên máy chủ, địa chỉ IP, cổng, tên đăng nhập, nhóm, cấu hình proxy, thiết lập giao thức, macro/lệnh đã lưu, tùy chọn giao diện và các bản ghi tin cậy SSH. Lịch sử lệnh có thể được ghi khi bạn gửi một dòng lệnh để hỗ trợ gợi ý và sử dụng lại. Các dữ liệu này có thể tiết lộ hạ tầng hoặc nội dung công việc của bạn.\n\nMật khẩu, khóa riêng và các bí mật trong kho thông tin đăng nhập được mã hóa bằng ChaCha20-Poly1305; khóa được dẫn xuất từ mật khẩu Vault bằng Argon2id. Đây không phải mã hóa toàn bộ cơ sở dữ liệu: metadata kết nối và lịch sử lệnh trong SQLite, bản ghi host key và thiết lập cục bộ được lưu dạng văn bản rõ. Khóa Vault không tự mã hóa hay xóa các metadata, lịch sử, log hoặc tệp đã xuất.',
  ),
  _PolicySection(
    '3. Kết nối mạng và bên nhận dữ liệu',
    'Khi bạn kết nối, máy chủ hoặc proxy bạn chọn nhận địa chỉ mạng, thông tin xác thực cần thiết và dữ liệu của tính năng đang dùng, chẳng hạn lệnh, đầu ra terminal, thao tác bàn phím/chuột remote desktop hoặc nội dung tệp truyền bằng SFTP. Dữ liệu được gửi trực tiếp tới các bên nhận đó; họ có thể ghi lại hoặc lưu giữ theo chính sách riêng.\n\nSSH/SFTP mã hóa đường truyền và kiểm tra host key. RDP kiểm tra TLS/chứng thư theo cấu hình. Telnet và VNC TCP cổ điển không mã hóa dữ liệu; chỉ dùng qua mạng tin cậy hoặc đường hầm/VPN phù hợp. Không có cam kết rằng mọi giao thức, proxy hoặc máy chủ do bạn cấu hình đều an toàn.',
  ),
  _PolicySection(
    '4. AI là tính năng tùy chọn',
    'Chỉ khi bạn xác nhận thông báo dữ liệu rồi nhấn Tạo nháp, ứng dụng mới gửi prompt bạn nhập, tên model và gợi ý hệ điều hành/shell tới endpoint AI bạn chọn. API key nếu nhập được gửi để xác thực với endpoint đó. Ứng dụng không tự đính kèm lịch sử terminal, mật khẩu hoặc dữ liệu Vault vào yêu cầu AI. Nội dung bạn tự nhập có thể vẫn chứa thông tin nhạy cảm; hãy kiểm tra trước khi gửi.\n\nEndpoint có thể là máy cục bộ hoặc nhà cung cấp bên ngoài. Việc lưu giữ, sử dụng và xóa yêu cầu/phản hồi phía dịch vụ do bên nhận kiểm soát. HTTP không mã hóa prompt và API key; ưu tiên HTTPS. Bản nháp AI cần được bạn xem xét trước khi đưa vào terminal.',
  ),
  _PolicySection(
    '5. Log, clipboard và tệp xuất',
    'Ghi log phiên mặc định tắt và chỉ bật sau xác nhận riêng của bạn. Log ghi đầu ra terminal nhận được từ lúc bật, không ghi trực tiếp phím gõ; máy chủ vẫn có thể in mật khẩu hoặc bí mật vào đầu ra. Log là tệp văn bản rõ ngoài phần bí mật được mã hóa của Vault, tối đa 20 MiB mỗi lượt. Ghi dừng khi ngắt phiên, khóa Vault hoặc thoát ứng dụng; kết nối lại không tự bật ghi.\n\nBạn có thể chủ động xuất log, lịch sử đang có trong terminal, macro hoặc cấu hình. Các tệp này không tự được mã hóa; bản xuất cấu hình qua giao diện bỏ thông tin bí mật, nhưng metadata và đầu ra vẫn có thể nhạy cảm. Sao chép/dán hoặc tính năng clipboard từ xa do bạn sử dụng có thể đưa nội dung vào clipboard thiết bị hoặc máy chủ. Bạn chịu trách nhiệm bảo vệ và xóa bản sao đã xuất hoặc đã chia sẻ.',
  ),
  _PolicySection(
    '6. Quyền Android và hoạt động nền',
    'Quyền Internet dùng cho các kết nối do bạn chọn. Quyền thông báo là tùy chọn, được giải thích trước khi bạn chủ động yêu cầu; từ chối không tạo đồng ý chia sẻ dữ liệu. Thông báo dịch vụ nền có thể hiển thị trạng thái và số phiên. Truy cập USB Serial chỉ được yêu cầu cho thiết bị USB bạn chọn. Bản ứng dụng này không yêu cầu quyền vị trí, danh bạ, camera, microphone hoặc quyền đọc toàn bộ bộ nhớ dùng chung.\n\nDịch vụ nền giúp duy trì các phiên đang dùng nhưng chịu giới hạn Android, loại dịch vụ và chính sách tiết kiệm pin. Không bảo đảm giữ kết nối vô hạn. Bạn có thể xem/tắt quyền thông báo hoặc dừng ứng dụng trong Cài đặt Android.',
  ),
  _PolicySection(
    '7. Lưu giữ, xóa dữ liệu và sao lưu',
    'Dữ liệu cục bộ được giữ để bạn sử dụng lại cho tới khi bạn xóa dữ liệu tương ứng hoặc xóa dữ liệu ứng dụng. Bạn có thể xóa hồ sơ/khóa tin cậy/log bằng các công cụ quản lý có sẵn. Để xóa toàn bộ dữ liệu riêng của ứng dụng, dùng Cài đặt Android → Ứng dụng → TermPulse → Bộ nhớ → Xóa dữ liệu, hoặc gỡ cài đặt. Tên mục có thể khác theo thiết bị. Không có tài khoản TermPulse trên máy chủ để yêu cầu xóa.\n\nCấu hình Android tắt sao lưu tự động và loại dữ liệu riêng của ứng dụng khỏi sao lưu đám mây/chuyển thiết bị. Các tệp bạn tự xuất hoặc sao chép ra ngoài dữ liệu riêng có thể vẫn tồn tại sau khi gỡ ứng dụng. Xóa dữ liệu cục bộ không xóa bản sao trên máy chủ, proxy, dịch vụ AI hoặc nơi bạn đã chia sẻ; hãy liên hệ bên nhận tương ứng. Ứng dụng không cam kết xóa an toàn ở cấp bộ nhớ vật lý.',
  ),
  _PolicySection(
    '8. Liên hệ và thay đổi chính sách',
    'Khi bản phát hành đã được cấu hình đầy đủ, danh tính đơn vị phát hành, địa chỉ liên hệ về quyền riêng tư và chính sách HTTPS công khai xuất hiện ở đầu trang. Dùng địa chỉ đó để hỏi về quyền riêng tư hoặc báo vấn đề dữ liệu. Khi cách xử lý dữ liệu thay đổi, chính sách và ngày phiên bản sẽ được cập nhật; lựa chọn hoặc quyền cần thiết vẫn được yêu cầu tại tính năng liên quan.',
  ),
];

const _englishPolicy = [
  _PolicySection(
    '1. Scope and your choices',
    'TermPulse is a terminal, connection-management and remote-access tool. It does not require a TermPulse account. This app version does not include advertising, behavioral analytics SDKs or an automatic mechanism for sending usage data to the publisher. You choose the servers, proxies and AI services to connect to. Reading this policy neither grants Android permissions nor consents to optional data sharing.',
  ),
  _PolicySection(
    '2. Data stored on your device',
    'The app stores connection profiles such as hostnames, IP addresses, ports, usernames, groups, proxy/protocol settings, saved macros/commands, interface preferences and SSH trust records. Command history may be recorded when you submit a line of input to support suggestions and reuse. This information may reveal your infrastructure or work content.\n\nPasswords, private keys and other secrets in the credential store are encrypted with ChaCha20-Poly1305 using a key derived from your Vault password with Argon2id. This is not full-database encryption: connection metadata and command history in SQLite, host-key records and local preferences are stored in plaintext. Locking the Vault does not encrypt or delete metadata, history, logs or exported files.',
  ),
  _PolicySection(
    '3. Network connections and recipients',
    'When you connect, your selected server or proxy receives network addressing, the authentication required for the connection and data used by that feature, such as commands, terminal output, remote-desktop keyboard/mouse input or SFTP file contents. Data goes directly to those recipients, which may record or retain it under their own policies.\n\nSSH/SFTP encrypt transport and check host keys. RDP validates TLS/certificates according to its configuration. Telnet and classic TCP VNC do not encrypt data; use a trusted network or suitable tunnel/VPN. The app does not guarantee that every protocol, proxy or server you configure is secure.',
  ),
  _PolicySection(
    '4. AI is optional',
    'Only after you confirm the data notice and select Generate draft does the app send your entered prompt, model name and OS/shell hints to your chosen AI endpoint. An API key, if supplied, is sent to authenticate with that endpoint. The app does not automatically attach terminal history, passwords or Vault data to AI requests. Your own prompt may still contain sensitive information; review it before sending.\n\nThe endpoint may be local or operated by an external provider. The recipient controls service-side use, retention and deletion of requests and responses. HTTP does not encrypt prompts or API keys; prefer HTTPS. Review AI drafts before putting them into the terminal.',
  ),
  _PolicySection(
    '5. Logs, clipboard and exports',
    'Session logging is off by default and starts only after your separate confirmation. It records terminal output received after enabling it, not keystrokes directly; a server may nevertheless print passwords or secrets. Logs are plaintext files outside the encrypted secret portion of the Vault, limited to 20 MiB per recording. Logging stops on disconnect, Vault lock or app exit and does not restart automatically on reconnect.\n\nYou may choose to export logs, the current terminal scrollback, macros or configuration. These files are not automatically encrypted. Configuration exports from the interface omit credential secrets, but metadata and terminal output may remain sensitive. Copy/paste or remote-clipboard features you use may place content in the device or server clipboard. You control protection and deletion of exported or shared copies.',
  ),
  _PolicySection(
    '6. Android permissions and background operation',
    'Internet access supports the connections you choose. Notification permission is optional and explained before you choose to request it; refusal does not grant data-sharing consent. A foreground-service notification may show status and session counts. USB Serial access is requested only for a USB device you select. This app version does not request location, contacts, camera, microphone or broad shared-storage access.\n\nA foreground service supports ongoing sessions but remains subject to Android limits, its service type and battery policies. Connections are not guaranteed to persist indefinitely. You can manage notification permission or stop the app in Android Settings.',
  ),
  _PolicySection(
    '7. Retention, deletion and backups',
    'Local data is retained for reuse until you delete the relevant data or clear the app. Available management tools let you delete profiles, trust records and logs. To remove all private app data, use Android Settings → Apps → TermPulse → Storage → Clear storage/data, or uninstall. Menu names vary by device. There is no server-side TermPulse account to delete.\n\nAndroid configuration disables automatic backups and excludes private app data from cloud backup and device transfer. Files you export or copy outside private app storage may remain after uninstalling. Local deletion does not delete copies on servers, proxies, AI services or destinations you shared with; contact the respective recipient. The app does not promise physical-storage secure erasure.',
  ),
  _PolicySection(
    '8. Contact and policy changes',
    'When release configuration is complete, the publisher identity, privacy contact and public HTTPS policy appear at the top of this page. Use that contact for privacy questions or data concerns. Changes to data handling will be reflected in this policy and its version date; required choices or permissions are still requested within the relevant feature.',
  ),
];
