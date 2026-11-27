import 'package:flutter/material.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';

class AppPermissionsScreen extends StatefulWidget {
  const AppPermissionsScreen({super.key});

  @override
  State<AppPermissionsScreen> createState() => _AppPermissionsScreenState();
}

class _AppPermissionsScreenState extends State<AppPermissionsScreen>
    with WidgetsBindingObserver {
  NotificationPermissionStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await ForegroundBridge.getNotificationPermissionStatus();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _error = 'Không đọc được trạng thái quyền.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return AlertDialog(
          key: const Key('notificationPermissionRationale'),
          scrollable: true,
          constraints: const BoxConstraints(maxWidth: 420),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 20, 20),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.primary.withValues(alpha: 0.20),
                      colors.primary.withValues(alpha: 0.08),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: 0.24),
                  ),
                ),
                child: Icon(
                  Icons.notifications_active_outlined,
                  color: colors.primary,
                  size: 25,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TermPulse',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.tr('Cho phép thông báo?'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('Thông báo phiên kết nối'),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr(
                  'TermPulse dùng thông báo để hiển thị số phiên và nút tắt hỗ trợ chạy nền. Bạn có thể từ chối và tiếp tục dùng ứng dụng. Android vẫn có thể giới hạn phiên chạy nền.',
                ),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const Key('cancelNotificationPermission'),
              style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Để sau')),
            ),
            FilledButton.icon(
              key: const Key('confirmNotificationPermission'),
              style: FilledButton.styleFrom(minimumSize: const Size(112, 44)),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              iconAlignment: IconAlignment.end,
              label: Text(context.tr('Tiếp tục')),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await ForegroundBridge.requestNotificationPermission();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Không thể yêu cầu quyền thông báo.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    setState(() => _error = null);
    try {
      await ForegroundBridge.openNotificationSettings();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Không mở được cài đặt thông báo.');
      }
    }
  }

  String _statusLabel(NotificationPermissionStatus status) {
    if (!ForegroundBridge.isAndroid) return 'Không áp dụng trên nền tảng này';
    if (status.visible) return 'Thông báo đã bật';
    if (!status.granted) return 'Chưa cấp quyền thông báo';
    if (!status.notificationsEnabled) return 'Thông báo ứng dụng đang tắt';
    return 'Kênh thông báo phiên đang tắt';
  }

  Widget _section(String title, String text) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr(title), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(context.tr(text), style: const TextStyle(height: 1.5)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      key: const Key('permissionsScreen'),
      appBar: AppBar(title: Text(context.tr('Quyền và thông báo'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                context.tr(
                  'Chỉ cấp quyền khi bạn cần tính năng tương ứng. Không cần quyền thông báo để tạo hoặc mở Vault.',
                ),
              ),
              _section(
                'Thông báo phiên kết nối',
                'Thông báo hiển thị số phiên và nút tắt hỗ trợ chạy nền; không hiển thị mật khẩu hay nội dung terminal. Quyền này là tùy chọn.',
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              if (status != null) ...[
                const SizedBox(height: 12),
                Text(
                  context.tr(_statusLabel(status)),
                  key: const Key('notificationPermissionStatus'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (ForegroundBridge.isAndroid && status.canRequest)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const Key('requestNotificationPermission'),
                      onPressed: _busy ? null : _request,
                      icon: const Icon(Icons.notifications_outlined),
                      label: Text(context.tr('Cho phép thông báo')),
                    ),
                  ),
                if (ForegroundBridge.isAndroid && !status.visible)
                  Text(
                    context.tr(
                      'Nếu đã từ chối hoặc tắt kênh thông báo, bạn có thể bật lại trong cài đặt Android.',
                    ),
                  ),
                if (ForegroundBridge.isAndroid)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('openNotificationSettings'),
                      onPressed: _busy ? null : _openSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: Text(context.tr('Mở cài đặt thông báo')),
                    ),
                  ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    context.tr(_error!),
                    key: const Key('permissionsError'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('refreshNotificationPermission'),
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.tr('Kiểm tra lại')),
                ),
              ),
              _section(
                'Hỗ trợ chạy nền',
                'Dịch vụ hỗ trợ các phiên đang mở khi bạn chuyển ứng dụng. Android có thể giới hạn thời gian hoặc dừng dịch vụ; kết nối không được bảo đảm duy trì vô hạn. Tắt dịch vụ không đóng phiên SSH: hãy ngắt kết nối trong terminal nếu muốn kết thúc phiên.',
              ),
              if (ForegroundBridge.isAndroid)
                ValueListenableBuilder<BackgroundServiceStatus>(
                  valueListenable: ForegroundBridge.backgroundStatus,
                  builder: (context, state, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      Text(
                        context.tr(
                          state.error == 'foreground_stop_failed'
                              ? 'Không tắt được hỗ trợ chạy nền'
                              : state.running
                              ? 'Hỗ trợ chạy nền đang hoạt động'
                              : state.stoppedReason == 'timeout'
                              ? 'Android đã giới hạn thời gian chạy nền'
                              : state.error != null ||
                                    state.stoppedReason == 'start_failed'
                              ? 'Không khởi động được hỗ trợ chạy nền'
                              : state.stoppedReason == 'user'
                              ? 'Bạn đã tắt hỗ trợ chạy nền'
                              : 'Hỗ trợ chạy nền chưa hoạt động',
                        ),
                      ),
                      if (state.running)
                        TextButton(
                          key: const Key('pauseBackgroundSupport'),
                          onPressed: ForegroundBridge.pauseBackgroundSupport,
                          child: Text(
                            context.tr('Tắt dịch vụ hỗ trợ chạy nền'),
                          ),
                        ),
                      if (!state.running && state.activeSessions > 0)
                        TextButton(
                          key: const Key('resumeBackgroundSupport'),
                          onPressed: ForegroundBridge.resumeBackgroundSupport,
                          child: Text(context.tr('Thử bật hỗ trợ chạy nền')),
                        ),
                    ],
                  ),
                ),
              _section(
                'Mạng và thiết bị USB',
                'Truy cập mạng dùng cho máy chủ, proxy, truyền tệp và API AI do bạn chọn. USB Serial chỉ truy cập thiết bị bạn chọn sau hộp thoại cho phép của Android. Một số giao thức và endpoint HTTP không mã hóa dữ liệu khi truyền.',
              ),
              _section(
                'Quyền không sử dụng',
                'Ứng dụng không yêu cầu camera, micro, vị trí, danh bạ hay quyền truy cập toàn bộ bộ nhớ. Tệp trong vùng riêng của ứng dụng vẫn được lưu mà không cần quyền bộ nhớ rộng.',
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
