import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_connections.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/features/hosts/proxy_editor_dialog.dart';
import 'package:termpulse/features/terminal/serial_connect_dialog.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _Backend extends FakeCoreBackend {
  @override
  bool serialSupported() => true;

  @override
  Future<List<SerialPortInfoDto>> listSerialPorts() async => [];
}

class _Launchers extends ConsumerWidget {
  const _Launchers();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Wrap(
      children: [
        TextButton(
          key: const Key('host'),
          onPressed: () => showHostEditorDialog(context, ref),
          child: const Text('host'),
        ),
        TextButton(
          key: const Key('serial'),
          onPressed: () => showSerialConnectDialog(context, ref),
          child: const Text('serial'),
        ),
        TextButton(
          key: const Key('proxy'),
          onPressed: () => showProxyEditorDialog(context, ref),
          child: const Text('proxy'),
        ),
      ],
    ),
  );
}

Future<ValueNotifier<AppLanguage>> _boot(
  WidgetTester tester,
  AppLanguage initial,
) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final language = ValueNotifier(initial);
  addTearDown(language.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [backendProvider.overrideWithValue(_Backend())],
      child: ValueListenableBuilder<AppLanguage>(
        valueListenable: language,
        builder: (_, value, child) => AppLocalizationScope(
          language: value,
          child: MaterialApp(theme: buildTermPulseDarkTheme(), home: child),
        ),
        child: const _Launchers(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return language;
}

String _tr(AppLanguage language, String source) =>
    translateAppMessage(language, source);

Future<void> _protocol(
  WidgetTester tester,
  AppLanguage language,
  String label,
) async {
  final field = find.widgetWithText(
    DropdownButtonFormField<String>,
    _tr(language, 'Giao thức'),
  );
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'connection catalog covers every language and preserves placeholders',
    () {
      final placeholder = RegExp(r'\{[a-zA-Z][a-zA-Z0-9_]*\}');
      for (final entry in connectionTranslations.entries) {
        expect(entry.value, hasLength(4), reason: entry.key);
        final expected = placeholder
            .allMatches(entry.key)
            .map((m) => m[0])
            .toSet();
        for (final value in entry.value) {
          expect(value.trim(), isNotEmpty, reason: entry.key);
          expect(
            placeholder.allMatches(value).map((m) => m[0]).toSet(),
            expected,
            reason: entry.key,
          );
        }
      }
      expect(
        _tr(AppLanguage.en, 'Không thể hoàn tất: Bad state: Nhập tên nhóm.'),
        'Could not complete: Enter a group name.',
      );
      expect(
        _tr(AppLanguage.zh, 'Xoá cấu hình đã lưu “server-01.example”?'),
        '删除已保存的连接“server-01.example”？',
      );
    },
  );

  for (final language in [
    AppLanguage.en,
    AppLanguage.zh,
    AppLanguage.ja,
    AppLanguage.ko,
  ]) {
    testWidgets('${language.code} forms show only relevant protocol controls', (
      tester,
    ) async {
      await _boot(tester, language);
      await tester.tap(find.byKey(const Key('host')));
      await tester.pumpAndSettle();
      expect(find.text(_tr(language, 'Thêm kết nối Host mới')), findsOneWidget);
      expect(find.text(_tr(language, 'Xác thực SSH')), findsOneWidget);
      await _protocol(tester, language, 'Telnet');
      expect(find.text(_tr(language, 'Xác thực SSH')), findsNothing);
      expect(find.text(_tr(language, 'Đường truyền SSH')), findsNothing);
      expect(
        find.text(_tr(language, 'Bật SFTP Follow-Terminal mặc định')),
        findsNothing,
      );
      expect(
        find.text(
          _tr(
            language,
            'Telnet không mã hóa dữ liệu hoặc mật khẩu. Chỉ dùng với thiết bị và mạng tin cậy.',
          ),
        ),
        findsOneWidget,
      );
      await _protocol(tester, language, _tr(language, 'Local Shell'));
      expect(find.text(_tr(language, 'Thư mục khởi động')), findsOneWidget);
      expect(find.text(_tr(language, 'Lệnh chạy sau khi nối')), findsNothing);
      await _protocol(tester, language, _tr(language, 'RDP · Windows Desktop'));
      expect(find.byKey(const Key('desktopWidthField')), findsOneWidget);
      expect(find.byKey(const Key('desktopHeightField')), findsOneWidget);
      expect(
        find.text(_tr(language, 'Tài khoản màn hình từ xa')),
        findsOneWidget,
      );
      expect(find.text(_tr(language, 'Khi kết nối')), findsNothing);
      expect(find.text(_tr(language, 'Đường truyền SSH')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('open Serial dialog and validation follow a language change', (
    tester,
  ) async {
    final language = await _boot(tester, AppLanguage.en);
    await tester.tap(find.byKey(const Key('serial')));
    await tester.pumpAndSettle();
    expect(find.text('Connect Serial'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('serialPortField')),
      '/dev/localized-test',
    );
    await tester.enterText(find.byKey(const Key('serialBaudField')), '0');
    await tester.tap(find.byKey(const Key('serialConnectButton')));
    await tester.pumpAndSettle();
    expect(
      find.text('Baud rate must be between 1 and 4000000.'),
      findsOneWidget,
    );
    language.value = AppLanguage.zh;
    await tester.pumpAndSettle();
    expect(find.text('连接串口'), findsOneWidget);
    expect(find.text('波特率必须介于 1 到 4000000 之间。'), findsOneWidget);
    expect(find.text('Connect Serial'), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('serialPortField')))
          .controller!
          .text,
      '/dev/localized-test',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('proxy validation and labels are localized at phone width', (
    tester,
  ) async {
    final language = await _boot(tester, AppLanguage.ja);
    await tester.tap(find.byKey(const Key('proxy')));
    await tester.pumpAndSettle();
    expect(find.text('SSH プロキシを追加'), findsOneWidget);
    await tester.tap(find.text('プロキシを保存'));
    await tester.pumpAndSettle();
    expect(find.text('プロキシの表示名を入力してください。'), findsOneWidget);
    language.value = AppLanguage.ko;
    await tester.pumpAndSettle();
    expect(find.text('프록시 표시 이름을 입력하세요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
