import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_remote.dart';
import 'package:termpulse/core/l10n_catalog_ssh.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

const _rejection =
    'AnyhowException(SSH_AUTHENTICATION_REJECTED: server failure response)';

Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  VoidCallback? retry,
  VoidCallback? dismiss,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTermPulseTheme(AppThemePreset.light),
      builder: (context, child) => AppLocalizationScope(
        language: AppLanguage.vi,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: InlineNotice(
            message: _rejection,
            onRetry: retry,
            onDismiss: dismiss,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('all native SSH and remote codes show guidance before diagnostics', () {
    for (final language in AppLanguage.values) {
      for (final entry in {
        ...sshErrorSources,
        ...remoteDesktopErrorSources,
      }.entries) {
        final source = 'AnyhowException(${entry.key}: native diagnostic)';
        final error = presentAppError(language, source);
        expect(error.summary, translateAppMessage(language, entry.value));
        expect(error.summary, isNot(contains(entry.key)));
        expect(error.summary, isNot(contains('native diagnostic')));
        expect(error.details, source);
      }
    }
  });

  test(
    'unknown technical failures stay in details; plain guidance stays plain',
    () {
      for (final language in AppLanguage.values) {
        for (final raw in [
          'AnyhowException(internal worker stopped)',
          'Bad state: Storage unavailable',
          'StateError(Storage unavailable)',
          'Exception: Storage unavailable',
          'FormatException: Unexpected end of input',
          'Exception(Bad state: Storage unavailable)',
          'SocketException: Connection refused (OS Error: errno = 111)',
          'TimeoutException after 0:00:15.000: Future not completed',
          'UNEXPECTED_NATIVE_FAILURE: missing worker',
        ]) {
          final error = presentAppError(language, raw);
          expect(error.details, raw);
          expect(error.summary, isNot(contains('Exception')));
          expect(error.summary, isNot(contains('errno')));
          expect(error.summary, isNot(contains('UNEXPECTED_NATIVE')));
          expect(error.summary, isNot(contains('Storage unavailable')));
          expect(error.summary, isNot(contains('Unexpected end of input')));
        }
      }
      final friendly = presentAppError(
        AppLanguage.en,
        'Bad state: Kết nối đã bị xóa hoặc đổi giao thức. Hãy mở lại từ danh sách host.',
      );
      expect(friendly.summary, startsWith('The connection was deleted'));
      expect(friendly.details, isNull);
    },
  );

  test('authentication timeout never claims the password is incorrect', () {
    final error = presentAppError(
      AppLanguage.vi,
      'SSH_AUTHENTICATION_TIMEOUT: SSH, 15s',
    );
    expect(error.summary, contains('Chưa thể kết luận sai mật khẩu'));
    expect(error.summary, isNot(contains('15s')));
  });

  testWidgets(
    'notice explains rejection; diagnostics open in a centered dialog',
    (tester) async {
      await _mount(tester, size: const Size(1200, 800));
      expect(find.text(_rejection), findsNothing);
      final summary = tester.widget<Text>(
        find.byKey(const Key('noticeSummary')),
      );
      expect(summary.data, contains('Kiểm tra tên đăng nhập, mật khẩu'));
      expect(summary.data, isNot(contains('SSH_AUTHENTICATION_REJECTED')));
      final bounds = tester.getRect(find.byKey(const Key('noticeSummary')));
      expect(bounds.left, greaterThan(220));
      expect(bounds.right, lessThanOrEqualTo(960));
      await tester.tap(find.byKey(const Key('noticeDetailsButton')));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('noticeDetailsDialog'));
      expect(dialog, findsOneWidget);
      expect(find.text(_rejection), findsOneWidget);
      expect(tester.getCenter(dialog).dx, closeTo(600, 1));
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text(_rejection), findsNothing);
    },
  );

  testWidgets('notice controls fit small landscape and large text', (
    tester,
  ) async {
    var retries = 0;
    var dismissals = 0;
    await _mount(
      tester,
      size: const Size(360, 260),
      textScale: 1.8,
      retry: () => retries++,
      dismiss: () => dismissals++,
    );
    expect(tester.takeException(), isNull);
    final retry = find.text('Thử lại');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    expect(retries, 1);
    final dismiss = find.byTooltip('Đóng / Dismiss');
    await tester.ensureVisible(dismiss);
    await tester.tap(dismiss);
    expect(dismissals, 1);
    await tester.ensureVisible(find.byKey(const Key('noticeDetailsButton')));
    await tester.tap(find.byKey(const Key('noticeDetailsButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('noticeDetailsDialog')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error snackbar is centered and keeps logs behind details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppErrorSnackBar(context, _rejection),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text(_rejection), findsNothing);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.width, 720);
    expect(snack.behavior, SnackBarBehavior.floating);
    expect(snack.action!.label, 'Xem chi tiết');
    await tester.tap(find.text('Xem chi tiết'));
    await tester.pumpAndSettle();
    expect(find.text(_rejection), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('noticeDetailsDialog'))).dx,
      closeTo(600, 1),
    );
    expect(tester.takeException(), isNull);
  });
}
