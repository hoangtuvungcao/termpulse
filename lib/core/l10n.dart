import 'package:flutter/widgets.dart';

import 'l10n_catalog_ai_privacy.dart';
import 'l10n_catalog_connections.dart';
import 'l10n_catalog_errors.dart';
import 'l10n_catalog_onboarding.dart';
import 'l10n_catalog_privacy.dart';
import 'l10n_catalog_remote.dart';
import 'l10n_catalog_shell.dart';
import 'l10n_catalog_ssh.dart';
import 'l10n_catalog_terminal.dart';
import 'l10n_catalog_workspace.dart';

enum AppLanguage {
  vi('vi', 'Tiếng Việt', 'VI'),
  en('en', 'English', 'EN'),
  zh('zh', '简体中文', '中文'),
  ja('ja', '日本語', 'JP'),
  ko('ko', '한국어', 'KO');

  final String code;
  final String nativeName;
  final String shortBadge;
  const AppLanguage(this.code, this.nativeName, this.shortBadge);
}

/// Kept above the Navigator so dialogs and menus follow language changes too.
class AppLocalizationScope extends InheritedWidget {
  final AppLanguage language;

  const AppLocalizationScope({
    super.key,
    required this.language,
    required super.child,
  });

  static AppLanguage of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppLocalizationScope>()
          ?.language ??
      AppLanguage.vi;

  @override
  bool updateShouldNotify(AppLocalizationScope oldWidget) =>
      oldWidget.language != language;
}

final Map<String, List<String>> appTranslationCatalog = Map.unmodifiable({
  ...aiPrivacyTranslations,
  ...privacyTranslations,
  ...onboardingTranslations,
  ...connectionTranslations,
  ...workspaceTranslations,
  ...shellTranslations,
  ...sshTranslations,
  ...terminalTranslations,
  ...remoteTranslations,
  ...errorTranslations,
});

class AppErrorPresentation {
  final String summary;
  final String? details;

  const AppErrorPresentation(this.summary, {this.details});
}

/// App-generated failures must make sense without reading native logs. This
/// deliberately does not process remote terminal output or user content.
AppErrorPresentation presentAppError(AppLanguage language, String source) {
  var message = source.trim();
  var hadExceptionWrapper = false;
  for (var i = 0; i < 5; i++) {
    final wrapper = RegExp(
      r'^(?:AnyhowException|Exception|StateError|FormatException|TimeoutException)\(',
    ).firstMatch(message);
    if (wrapper != null && message.endsWith(')')) {
      hadExceptionWrapper = true;
      message = message.substring(wrapper.end, message.length - 1).trim();
      continue;
    }
    final prefix = RegExp(
      r'^(?:Bad state|Exception|StateError|FormatException|TimeoutException):\s*',
    ).firstMatch(message);
    if (prefix == null) break;
    hadExceptionWrapper = true;
    message = message.substring(prefix.end).trim();
  }
  final code = RegExp(
    r'\b((?:REMOTE_DESKTOP|RDP|VNC|SSH)_[A-Z_]+):',
  ).firstMatch(message)?.group(1);
  final explanation = sshErrorSources[code] ?? remoteDesktopErrorSources[code];
  if (explanation != null) {
    return AppErrorPresentation(
      translateAppMessage(language, explanation),
      details: source.trim(),
    );
  }

  final lower = message.toLowerCase();
  String? fallback;
  if (lower.contains('timed out') ||
      lower.contains('timeoutexception') ||
      source.startsWith('TimeoutException')) {
    fallback =
        'Máy chủ chưa phản hồi kịp. Kiểm tra mạng và địa chỉ kết nối, rồi thử lại.';
  } else if (RegExp(
    r'connection refused|connection reset|network is unreachable|no route to host|failed host lookup|socketexception|kết nối thất bại:',
    caseSensitive: false,
  ).hasMatch(message)) {
    fallback =
        'Không kết nối được máy chủ. Kiểm tra địa chỉ, cổng và mạng, rồi thử lại.';
  } else if (RegExp(
        r'\b\w*(?:Exception|Error)\b|\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b|\bstack trace\b|\bat \S+\.dart:\d+|\bos error \d+',
      ).hasMatch(message) ||
      (hadExceptionWrapper && !_isKnownErrorGuidance(message))) {
    fallback =
        'Không thể hoàn tất thao tác. Hãy thử lại; nếu vẫn lỗi, mở chi tiết để được hỗ trợ.';
  }
  if (fallback != null) {
    return AppErrorPresentation(
      translateAppMessage(language, fallback),
      details: source.trim(),
    );
  }
  return AppErrorPresentation(translateAppMessage(language, message));
}

bool _isKnownErrorGuidance(String message) {
  if (appTranslationCatalog.containsKey(message)) return true;
  // Allow app-authored guidance with values such as host names, but never
  // treat a generic "Error: {error}" translation as a friendly explanation.
  return _translationTemplates.any(
    (template) =>
        !template.parameters.any(
          const {'error', 'message', 'reason'}.contains,
        ) &&
        template.pattern.hasMatch(message),
  );
}

class _TranslationTemplate {
  final String source;
  final RegExp pattern;
  final List<String> parameters;
  const _TranslationTemplate(this.source, this.pattern, this.parameters);
}

final _translationTemplates = () {
  final placeholder = RegExp(r'\{([a-zA-Z][a-zA-Z0-9_]*)\}');
  final result = <_TranslationTemplate>[];
  for (final key in appTranslationCatalog.keys) {
    final matches = placeholder.allMatches(key).toList();
    if (matches.isEmpty || key.replaceAll(placeholder, '').trim().length < 4) {
      continue;
    }
    final pattern = StringBuffer('^');
    final parameters = <String>[];
    var offset = 0;
    for (final match in matches) {
      pattern.write(RegExp.escape(key.substring(offset, match.start)));
      pattern.write('([\\s\\S]*?)');
      parameters.add(match.group(1)!);
      offset = match.end;
    }
    pattern.write(RegExp.escape(key.substring(offset)));
    pattern.write(r'$');
    result.add(
      _TranslationTemplate(key, RegExp(pattern.toString()), parameters),
    );
  }
  // Prefer a specific message over a generic "Error: {error}" wrapper.
  result.sort((a, b) => b.source.length.compareTo(a.source.length));
  return result;
}();

String translateAppMessage(
  AppLanguage language,
  String source, [
  Map<String, String> parameters = const {},
  int depth = 0,
]) {
  String interpolate(String text, Map<String, String> values) =>
      text.replaceAllMapped(
        RegExp(r'\{([a-zA-Z][a-zA-Z0-9_]*)\}'),
        (match) => values[match.group(1)] ?? match.group(0)!,
      );

  final translations = appTranslationCatalog[source];
  if (translations != null) {
    final text = language == AppLanguage.vi
        ? source
        : translations[language.index - 1];
    return interpolate(text, parameters);
  }
  if (depth < 5) {
    final nativeError = RegExp(
      r'^(?:AnyhowException\()?((?:REMOTE_DESKTOP|RDP|VNC|SSH)_[A-Z_]+):\s*',
    ).firstMatch(source);
    final code = nativeError?.group(1);
    final explanation =
        sshErrorSources[code] ?? remoteDesktopErrorSources[code];
    if (nativeError != null && explanation != null) {
      final headline = translateAppMessage(
        language,
        explanation,
        const {},
        depth + 1,
      );
      var detail = source.substring(nativeError.end);
      if (source.startsWith('AnyhowException(') && detail.endsWith(')')) {
        detail = detail.substring(0, detail.length - 1);
      }
      return '$headline\n[$code] $detail';
    }
  }
  if (depth >= 5 || language == AppLanguage.vi) {
    return interpolate(source, parameters);
  }
  for (final prefix in ['Bad state: ', 'Exception: ', 'FormatException: ']) {
    if (source.startsWith(prefix)) {
      return translateAppMessage(
        language,
        source.substring(prefix.length),
        parameters,
        depth + 1,
      );
    }
  }
  for (final template in _translationTemplates) {
    final match = template.pattern.firstMatch(source);
    if (match == null) continue;
    final values = <String, String>{...parameters};
    for (var i = 0; i < template.parameters.length; i++) {
      final value = match.group(i + 1)!;
      // Only translate known messages. Arbitrary filenames, hostnames, command
      // output and other user/server content must remain untouched.
      values[template.parameters[i]] =
          const {'error', 'message', 'reason'}.contains(template.parameters[i])
          ? translateAppMessage(language, value, const {}, depth + 1)
          : value;
    }
    return translateAppMessage(language, template.source, values, depth + 1);
  }
  return interpolate(source, parameters);
}

extension TermPulseLocalizedContext on BuildContext {
  String tr(String source, [Map<String, String> parameters = const {}]) =>
      translateAppMessage(AppLocalizationScope.of(this), source, parameters);

  String trError(String source) =>
      presentAppError(AppLocalizationScope.of(this), source).summary;
}

class AppStrings {
  final AppLanguage lang;
  const AppStrings(this.lang);

  String _pick({
    required String vi,
    required String en,
    required String zh,
    required String ja,
    required String ko,
  }) => switch (lang) {
    AppLanguage.vi => vi,
    AppLanguage.en => en,
    AppLanguage.zh => zh,
    AppLanguage.ja => ja,
    AppLanguage.ko => ko,
  };

  // --- Vault Screen ---
  String get vaultSubtitle => _pick(
    vi: 'Rust Core · Local-First SSH & SFTP',
    en: 'Rust Core · Local-First SSH & SFTP',
    zh: 'Rust 内核 · 本地优先 SSH 与 SFTP',
    ja: 'Rust コア · ローカルファースト SSH & SFTP',
    ko: 'Rust 코어 · 로컬 우선 SSH & SFTP',
  );
  String get vaultSecurityBanner => _pick(
    vi: 'Bí mật đăng nhập được mã hóa bằng Argon2id + ChaCha20-Poly1305. Metadata và lịch sử lệnh không mã hóa. Không cần tài khoản.',
    en: 'Credential secrets use Argon2id + ChaCha20-Poly1305 encryption. Metadata and command history are not encrypted. No account required.',
    zh: '凭据机密使用 Argon2id + ChaCha20-Poly1305 加密。元数据和命令历史不加密。无需账号。',
    ja: '認証情報の秘密は Argon2id + ChaCha20-Poly1305 で暗号化します。メタデータとコマンド履歴は暗号化されません。アカウントは不要です。',
    ko: '인증 비밀 정보는 Argon2id + ChaCha20-Poly1305으로 암호화됩니다. 메타데이터와 명령 기록은 암호화되지 않습니다. 계정은 필요하지 않습니다.',
  );
  String get vaultNewTitle => _pick(
    vi: 'Khởi tạo Vault mã hoá mới',
    en: 'Create Encrypted Vault',
    zh: '创建新加密保险库',
    ja: '新しい暗号化 Vault を作成',
    ko: '새 암호화 Vault 생성',
  );
  String get vaultUnlockTitle => _pick(
    vi: 'Mở khoá Vault của bạn',
    en: 'Unlock Your Vault',
    zh: '解锁您的保险库',
    ja: 'Vault のロックを解除',
    ko: 'Vault 잠금 해제',
  );
  String get masterPasswordLabel => _pick(
    vi: 'Mật khẩu chính (Master Password)',
    en: 'Master Password',
    zh: '主密码 (Master Password)',
    ja: 'マスターパスワード',
    ko: '마스터 비밀번호',
  );
  String get confirmPasswordLabel => _pick(
    vi: 'Xác nhận mật khẩu chính',
    en: 'Confirm Master Password',
    zh: '确认主密码',
    ja: 'マスターパスワード確認',
    ko: '마스터 비밀번호 확인',
  );
  String get createVaultCta => _pick(
    vi: 'Tạo Vault & Bắt đầu',
    en: 'Create Vault & Start',
    zh: '创建并开始使用',
    ja: 'Vault を作成して開始',
    ko: 'Vault 생성 및 시작',
  );
  String get unlockVaultCta => _pick(
    vi: 'Mở khoá Vault',
    en: 'Unlock Vault',
    zh: '解锁保险库',
    ja: 'Vault を開く',
    ko: 'Vault 잠금 해제',
  );
  String get errEmptyPassword => _pick(
    vi: 'Vui lòng nhập mật khẩu chính.',
    en: 'Please enter your master password.',
    zh: '请输入主密码。',
    ja: 'マスターパスワードを入力してください。',
    ko: '마스터 비밀번호를 입력하세요.',
  );
  String get errMismatchPassword => _pick(
    vi: 'Mật khẩu xác nhận không khớp.',
    en: 'Confirmation password does not match.',
    zh: '两次输入的密码不一致。',
    ja: '確認用パスワードが一致しません。',
    ko: '확인 비밀번호가 일치하지 않습니다.',
  );

  // --- Common Actions ---
  String get cancel =>
      _pick(vi: 'Huỷ', en: 'Cancel', zh: '取消', ja: 'キャンセル', ko: '취소');
  String get cancelAction =>
      _pick(vi: 'Huỷ bỏ', en: 'Cancel', zh: '取消', ja: 'キャンセル', ko: '취소');
  String get close =>
      _pick(vi: 'Đóng', en: 'Close', zh: '关闭', ja: '閉じる', ko: '닫기');
  String get save => _pick(vi: 'Lưu', en: 'Save', zh: '保存', ja: '保存', ko: '저장');
  String get connect =>
      _pick(vi: 'Kết nối', en: 'Connect', zh: '连接', ja: '接続', ko: '연결');
  String get edit => _pick(vi: 'Sửa', en: 'Edit', zh: '编辑', ja: '編集', ko: '편집');
  String get clone =>
      _pick(vi: 'Nhân bản', en: 'Duplicate', zh: '复制', ja: '複製', ko: '복제');
  String get delete =>
      _pick(vi: 'Xoá', en: 'Delete', zh: '删除', ja: '削除', ko: '삭제');
  String get create =>
      _pick(vi: 'Tạo', en: 'Create', zh: '新建', ja: '作成', ko: '만들기');

  // --- Desktop Shell & Toolbar ---
  String get toggleSidebarTooltip => _pick(
    vi: 'Thu/Mở cây Host',
    en: 'Toggle Host Sidebar',
    zh: '切换主机侧边栏',
    ja: 'ホストサイドバー切替',
    ko: '호스트 사이드바 전환',
  );
  String get quickConnectHint => _pick(
    vi: 'Quick: user@host:22',
    en: 'Quick: user@host:22',
    zh: '快速连接: user@host:22',
    ja: 'クイック接続: user@host:22',
    ko: '빠른 연결: user@host:22',
  );
  String get searchHostsHint => _pick(
    vi: 'Tìm host, tag, env...',
    en: 'Search hosts, tags, env...',
    zh: '搜索主机、标签、环境...',
    ja: 'ホスト・タグ・環境を検索...',
    ko: '호스트, 태그, 환경 검색...',
  );
  String get hostBtnLabel =>
      _pick(vi: 'Host', en: 'Host', zh: '主机', ja: 'ホスト', ko: '호스트');
  String get localShellTooltip => _pick(
    vi: 'Terminal cục bộ',
    en: 'Local Shell',
    zh: '本地终端',
    ja: 'ローカルシェル',
    ko: '로컬 셸',
  );
  String get importExportTooltip => _pick(
    vi: 'Nhập / Xuất',
    en: 'Import / Export',
    zh: '导入 / 导出',
    ja: 'インポート / エクスポート',
    ko: '가져오기 / 내보내기',
  );
  String get overviewTooltip => _pick(
    vi: 'Tổng quan các phiên',
    en: 'Session Overview',
    zh: '会话概览',
    ja: 'セッション一覧',
    ko: '세션 개요',
  );
  String get toggleSftpTooltip => _pick(
    vi: 'Bật/Tắt Panel SFTP',
    en: 'Toggle SFTP Panel',
    zh: '切换 SFTP 面板',
    ja: 'SFTP パネル切替',
    ko: 'SFTP 패널 전환',
  );
  String get settingsTooltip => _pick(
    vi: 'Cài đặt · Ngôn ngữ · Giao diện',
    en: 'Settings · Language · Theme',
    zh: '设置 · 语言 · 主题',
    ja: '設定 · 言語 · テーマ',
    ko: '설정 · 언어 · 테마',
  );
  String get lockVaultTooltip => _pick(
    vi: 'Khoá Vault',
    en: 'Lock Vault',
    zh: '锁定保险库',
    ja: 'Vault をロック',
    ko: 'Vault 잠금',
  );
  String get broadcastChip => _pick(
    vi: 'Broadcast',
    en: 'Broadcast',
    zh: '广播输入',
    ja: '一斉送信',
    ko: '브로드캐스트',
  );
  String broadcastBanner(int count, bool hasProd) => switch (lang) {
    AppLanguage.vi =>
      'BROADCAST ĐANG BẬT — Gõ đồng loạt tới $count phiên${hasProd ? " (CÓ HOST PROD — Hãy cẩn trọng!)" : ""}',
    AppLanguage.en =>
      'BROADCAST ACTIVE — Typing across $count sessions${hasProd ? " (INCLUDES PROD — Caution!)" : ""}',
    AppLanguage.zh =>
      '同步广播已开启 — 将同时发送到 $count 个会话${hasProd ? "（包含 PROD 主机 — 请谨慎！）" : ""}',
    AppLanguage.ja =>
      'ブロードキャスト有効 — $count セッションへ一斉入力中${hasProd ? " (PROD環境を含む — 要注意!)" : ""}',
    AppLanguage.ko =>
      '브로드캐스트 활성 — $count개 세션에 동시 입력 중${hasProd ? " (PROD 포함 — 주의!)" : ""}',
  };
  String get turnOffFast => _pick(
    vi: 'Tắt nhanh',
    en: 'Turn Off',
    zh: '立即关闭',
    ja: 'すぐ停止',
    ko: '즉시 끄기',
  );
  String get emptyHostsSidebar => _pick(
    vi: 'Chưa có Host nào.\nBấm + Host hoặc Import ~/.ssh/config.',
    en: 'No hosts yet.\nClick + Host or import ~/.ssh/config.',
    zh: '暂无主机。\n点击 + 主机或导入 ~/.ssh/config。',
    ja: 'ホストがありません。\n+ ホスト追加または ~/.ssh/config をインポート。',
    ko: '호스트가 없습니다.\n+ 호스트 또는 ~/.ssh/config 가져오기를 누르세요.',
  );
  String get readyTitle => _pick(
    vi: 'Sẵn sàng kết nối',
    en: 'Ready to Connect',
    zh: '准备就绪',
    ja: '接続準備完了',
    ko: '연결 준비 완료',
  );
  String get readyDesc => _pick(
    vi: 'Chọn Host ở thanh bên trái, gõ user@host:port trên Quick-Connect, hoặc mở nhanh Local Shell.',
    en: 'Select a host from the sidebar, type user@host:port in Quick-Connect, or launch Local Shell.',
    zh: '从左侧选择主机、使用快速连接输入 user@host:port，或直接打开本地终端。',
    ja: '左のサイドバーからホストを選択するか、Quick-Connect またはローカルシェルを開いてください。',
    ko: '사이드바에서 호스트를 선택하거나 Quick-Connect 또는 로컬 셸을 열어보세요.',
  );
  String get openLocalShell => _pick(
    vi: 'Mở Local Shell',
    en: 'Open Local Shell',
    zh: '打开本地终端',
    ja: 'ローカルシェルを開く',
    ko: '로컬 셸 열기',
  );
  String get addHost => _pick(
    vi: 'Thêm Host',
    en: 'Add Host',
    zh: '添加主机',
    ja: 'ホスト追加',
    ko: '호스트 추가',
  );
  String get importSshConfigBtn => _pick(
    vi: 'Import ssh_config',
    en: 'Import ssh_config',
    zh: '导入 ssh_config',
    ja: 'ssh_config インポート',
    ko: 'ssh_config 가져오기',
  );
  String get overviewEmpty => _pick(
    vi: 'Chưa có phiên nào đang mở.',
    en: 'No active sessions.',
    zh: '当前没有活动会话。',
    ja: '開いているセッションはありません。',
    ko: '열린 세션이 없습니다.',
  );
  String get sessionRunningHint => _pick(
    vi: 'Đang hoạt động · nhấn để phóng to',
    en: 'Active · click to focus',
    zh: '运行中 · 点击聚焦',
    ja: '稼働中 · クリックで拡大',
    ko: '활성 · 클릭하여 포커스',
  );
  String get sessionClosed => _pick(
    vi: 'Đã ngắt kết nối',
    en: 'Disconnected',
    zh: '已断开',
    ja: '切断済み',
    ko: '연결 끊김',
  );

  // --- Compose Bar & Guard ---
  String composeHint(int targetCount, bool broadcast) => broadcast
      ? _pick(
          vi: 'Compose Pane → Broadcast tới $targetCount host...',
          en: 'Compose Pane → Broadcast to $targetCount hosts...',
          zh: '安全输入栏 → 广播到 $targetCount 台主机...',
          ja: 'コマンド作成 → $targetCount ホストへ一斉送信...',
          ko: '명령 작성창 → $targetCount개 호스트로 브로드캐스트...',
        )
      : _pick(
          vi: 'Compose Pane (soạn lệnh nhiều dòng an toàn trước khi gửi)...',
          en: 'Compose Pane (stage multi-line commands safely before sending)...',
          zh: '安全输入栏（发送前预览多行命令与危险拦截）...',
          ja: 'コマンド作成ペイン（複数行コマンドを安全に確認して送信）...',
          ko: '명령 작성창 (전송 전 여러 줄 명령을 안전하게 확인)...',
        );
  String get sendBtn =>
      _pick(vi: 'Gửi', en: 'Send', zh: '发送', ja: '送信', ko: '전송');
  String get sendBroadcastBtn => _pick(
    vi: 'Gửi đồng loạt',
    en: 'Broadcast',
    zh: '广播发送',
    ja: '一斉送信',
    ko: '동시 전송',
  );
  String get guardDangerTitle => _pick(
    vi: 'Cảnh báo lệnh nguy hiểm (PROD)',
    en: 'Dangerous Command Warning (PROD)',
    zh: '高危命令警告 (PROD)',
    ja: '危険コマンド警告 (PROD)',
    ko: '위험 명령 경고 (PROD)',
  );
  String get guardConfirmTitle => _pick(
    vi: 'Xác nhận gửi lệnh',
    en: 'Confirm Command Execution',
    zh: '确认发送命令',
    ja: 'コマンド実行の確認',
    ko: '명령 실행 확인',
  );
  String get guardConfirmRun => _pick(
    vi: 'Xác nhận chạy',
    en: 'Run Anyway',
    zh: '确认执行',
    ja: '実行を確定',
    ko: '실행 확인',
  );

  // --- SFTP & Remote Editor ---
  String get sftpFollow => _pick(
    vi: '● Follow',
    en: '● Follow',
    zh: '● 跟随终端',
    ja: '● 追従',
    ko: '● 자동 추적',
  );
  String get sftpManual => _pick(
    vi: '○ Manual',
    en: '○ Manual',
    zh: '○ 手动模式',
    ja: '○ 手動',
    ko: '○ 수동',
  );
  String get sftpOnePaneTooltip => _pick(
    vi: 'Chế độ 1 ngăn',
    en: 'Single Pane Mode',
    zh: '单栏模式',
    ja: '単一ペインモード',
    ko: '단일 창 모드',
  );
  String get sftpCommanderTooltip => _pick(
    vi: 'Chế độ 2 ngăn Commander',
    en: 'Dual-Pane Commander Mode',
    zh: '双栏 Commander 模式',
    ja: '2ペイン Commander モード',
    ko: '2분할 Commander 모드',
  );
  String get mkdirTooltip => _pick(
    vi: 'Tạo thư mục',
    en: 'New Folder',
    zh: '新建文件夹',
    ja: '新規フォルダ',
    ko: '새 폴더',
  );
  String get refreshTooltip =>
      _pick(vi: 'Làm mới', en: 'Refresh', zh: '刷新', ja: '更新', ko: '새로고침');
  String get saveToServer => _pick(
    vi: 'Lưu lên Server',
    en: 'Save & Upload',
    zh: '保存并上传',
    ja: 'サーバーへ保存',
    ko: '서버에 저장',
  );

  // --- Bottom Dock & Mobile ---
  String get healthTabTitle => _pick(
    vi: 'Server Health (/proc)',
    en: 'Server Health (/proc)',
    zh: '服务器负载 (/proc)',
    ja: 'サーバー監視 (/proc)',
    ko: '서버 상태 (/proc)',
  );
  String get measureProcBtn => _pick(
    vi: 'Đo /proc',
    en: 'Probe /proc',
    zh: '采集 /proc',
    ja: '/proc 計測',
    ko: '/proc 측정',
  );
  String get measureNowBtn => _pick(
    vi: 'Đo ngay',
    en: 'Probe Now',
    zh: '立即检测',
    ja: '今すぐ計測',
    ko: '지금 측정',
  );
  String get startBtn =>
      _pick(vi: 'Chạy', en: 'Start', zh: '启动', ja: '開始', ko: '시작');
  String get stopBtn =>
      _pick(vi: 'Dừng', en: 'Stop', zh: '停止', ja: '停止', ko: '중지');
  String get addTunnelBtn => _pick(
    vi: 'Thêm Tunnel',
    en: 'Add Tunnel',
    zh: '新建隧道',
    ja: 'トンネル追加',
    ko: '터널 추가',
  );
  String get saveHostBtn => _pick(
    vi: 'Lưu Host',
    en: 'Save Host',
    zh: '保存主机',
    ja: 'ホスト保存',
    ko: '호스트 저장',
  );
  String get exportSshConfigBtn => _pick(
    vi: 'Xuất ssh_config',
    en: 'Export ssh_config',
    zh: '导出 ssh_config',
    ja: 'ssh_config 出力',
    ko: 'ssh_config 내보내기',
  );
  String get exportJsonBtn => _pick(
    vi: 'Xuất JSON',
    en: 'Export JSON',
    zh: '导出 JSON',
    ja: 'JSON 出力',
    ko: 'JSON 내보내기',
  );
  String get importIntoVaultBtn => _pick(
    vi: 'Nhập vào Vault',
    en: 'Import to Vault',
    zh: '导入保险库',
    ja: 'Vault に取込',
    ko: 'Vault로 가져오기',
  );

  // --- Settings Dialog ---
  String get settingsTitle => _pick(
    vi: 'Cài đặt & Cá nhân hoá',
    en: 'Settings & Personalization',
    zh: '设置与个性化',
    ja: '設定とカスタマイズ',
    ko: '설정 및 개인화',
  );
  String get settingsLanguageLabel => _pick(
    vi: 'Ngôn ngữ hiển thị (Multi-Language)',
    en: 'Display Language',
    zh: '显示语言',
    ja: '表示言語',
    ko: '표시 언어',
  );
  String get settingsThemeLabel => _pick(
    vi: 'Bảng màu & Giao diện (App + Terminal)',
    en: 'Theme Preset (Chrome + Terminal)',
    zh: '主题与终端配色',
    ja: 'カラーテーマ (UI + ターミナル)',
    ko: '테마 프리셋 (UI + 터미널)',
  );
  String get settingsFontSizeLabel => _pick(
    vi: 'Cỡ chữ Terminal',
    en: 'Terminal Font Size',
    zh: '终端字体大小',
    ja: 'ターミナル文字サイズ',
    ko: '터미널 글꼴 크기',
  );
}
