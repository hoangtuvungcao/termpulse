import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_workspace.dart';
import 'package:termpulse/core/l10n_catalog_terminal.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/automation/automation_dialog.dart';
import 'package:termpulse/features/settings/settings_dialog.dart';
import 'package:termpulse/features/sftp/remote_editor_dialog.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/command_guard_dialog.dart';
import 'package:termpulse/features/terminal/command_palette.dart';
import 'package:termpulse/features/terminal/session_log_dialog.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _MemorySettings extends SettingsController {
  final AppLanguage language;
  _MemorySettings(this.language);

  @override
  AppSettingsState build() => AppSettingsState(language: language);
}

class _MemoryAutomationStorage implements AutomationStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String json) async => value = json;
}

class _EditorBackend extends FakeCoreBackend {
  @override
  Future<String> sftpReadText(String sessionId, String path) async =>
      'Không có mục phù hợp';
}

class _FailingEditorBackend extends FakeCoreBackend {
  @override
  Future<String> sftpReadText(String sessionId, String path) async =>
      throw StateError('server denied 日本語.txt');
}

class _Sessions extends SessionManagerController {
  final TerminalSessionTab tab;
  _Sessions(this.tab);

  @override
  WorkspaceState build() => WorkspaceState(tabs: [tab]);
}

class _MemoryLogs extends SessionLogsController {
  @override
  SessionLogsState build() => const SessionLogsState();

  @override
  Future<void> load() async {}
}

Future<void> _mount(
  WidgetTester tester,
  AppLanguage language,
  Widget Function(BuildContext, WidgetRef) builder, {
  TerminalSessionTab? tab,
  FakeCoreBackend? backend,
  ValueNotifier<AppLanguage>? languageChanges,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => _MemorySettings(language)),
      backendProvider.overrideWithValue(backend ?? _EditorBackend()),
      automationStorageProvider.overrideWithValue(_MemoryAutomationStorage()),
      sessionLogsProvider.overrideWith(_MemoryLogs.new),
      if (tab != null)
        sessionManagerProvider.overrideWith(() => _Sessions(tab)),
    ],
  );
  addTearDown(container.dispose);
  final app = MaterialApp(
    theme: buildTermPulseTheme(AppThemePreset.dark),
    home: Scaffold(
      body: Consumer(builder: (context, ref, _) => builder(context, ref)),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: languageChanges == null
          ? AppLocalizationScope(language: language, child: app)
          : ValueListenableBuilder<AppLanguage>(
              valueListenable: languageChanges,
              builder: (_, current, child) =>
                  AppLocalizationScope(language: current, child: child!),
              child: app,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

String _expected(AppLanguage language, String key) => language == AppLanguage.vi
    ? key
    : (workspaceTranslations[key] ??
          terminalTranslations[key])![language.index - 1];

void main() {
  test(
    'workspace catalog covers every language and preserves placeholders',
    () {
      final placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');
      Set<String> parameters(String text) =>
          placeholder.allMatches(text).map((match) => match.group(1)!).toSet();
      for (final entry in {
        ...workspaceTranslations,
        ...terminalTranslations,
      }.entries) {
        expect(entry.value, hasLength(4), reason: entry.key);
        for (final translation in entry.value) {
          expect(translation.trim(), isNotEmpty, reason: entry.key);
          expect(
            parameters(translation),
            parameters(entry.key),
            reason: entry.key,
          );
        }
      }
    },
  );

  test('workspace interpolation leaves user filenames and paths unchanged', () {
    const name = 'Không có mục phù hợp_日本語.txt';
    for (final language in AppLanguage.values) {
      final message = translateAppMessage(
        language,
        'Đã thêm {name} vào hàng đợi tải về.',
        {'name': name},
      );
      expect(message, contains(name));
      expect(message, isNot(contains('{name}')));
    }
  });

  testWidgets('open editor errors follow live language changes', (
    tester,
  ) async {
    final language = ValueNotifier(AppLanguage.vi);
    addTearDown(language.dispose);
    await _mount(
      tester,
      AppLanguage.vi,
      (context, ref) => TextButton(
        onPressed: () => showRemoteFileEditor(
          context,
          ref,
          sessionId: 'session',
          remotePath: '/work/日本語.txt',
        ),
        child: const Text('Open'),
      ),
      backend: _FailingEditorBackend(),
      languageChanges: language,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      find.text('Không đọc được file: Bad state: server denied 日本語.txt'),
      findsOneWidget,
    );
    for (final next in AppLanguage.values.skip(1)) {
      language.value = next;
      await tester.pumpAndSettle();
      expect(
        find.text(
          _expected(
            next,
            'Không đọc được file: {error}',
          ).replaceAll('{error}', 'server denied 日本語.txt'),
        ),
        findsOneWidget,
      );
      expect(find.text('/work/日本語.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  for (final language in AppLanguage.values) {
    testWidgets('settings security and theme labels: ${language.name}', (
      tester,
    ) async {
      await _mount(
        tester,
        language,
        (context, ref) => TextButton(
          onPressed: () => showSettingsDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.text(_expected(language, 'Khóa máy chủ SSH và CA')),
        findsOneWidget,
      );
      expect(find.text(_expected(language, 'Dark')), findsOneWidget);
      expect(find.text(_expected(language, 'Light')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('macro editor labels and validation: ${language.name}', (
      tester,
    ) async {
      await _mount(
        tester,
        language,
        (context, ref) => TextButton(
          onPressed: () => showAutomationDialog(context, ref),
          child: const Text('Open'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('automationCreate')));
      await tester.pumpAndSettle();
      expect(find.text(_expected(language, 'Tên macro')), findsOneWidget);
      await tester.ensureVisible(find.text(_expected(language, 'Lưu macro')));
      await tester.tap(find.text(_expected(language, 'Lưu macro')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          _expected(
            language,
            'Tên macro cần 1–100 ký tự, không chứa ký tự điều khiển.',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'remote editor localizes controls but preserves content: ${language.name}',
      (tester) async {
        await _mount(
          tester,
          language,
          (context, ref) => TextButton(
            onPressed: () => showRemoteFileEditor(
              context,
              ref,
              sessionId: 'session',
              remotePath: '/work/日本語.txt',
            ),
            child: const Text('Open'),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.text(_expected(language, 'Lưu lên Server')),
          findsOneWidget,
        );
        expect(
          find.text(_expected(language, 'Nội dung đã đồng bộ')),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Không có mục phù hợp',
        );
        expect(find.text('/work/日本語.txt'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('SFTP sort and permissions labels: ${language.name}', (
      tester,
    ) async {
      final tab = TerminalSessionTab(
        localKey: 'sftp',
        sessionId: 'session',
        title: 'SSH',
        envTag: 'dev',
        protocol: 'ssh',
        terminal: Terminal(),
        controller: TerminalController(),
        cwd: '/work',
        sftpEntries: [
          SftpEntryDto(
            name: 'Không có mục phù hợp',
            path: '/work/Không có mục phù hợp',
            isDir: false,
            isSymlink: false,
            size: BigInt.one,
            permissions: 0x1a4,
            modified: BigInt.one,
          ),
        ],
      );
      await _mount(tester, language, (_, _) => SftpPanel(tab: tab), tab: tab);
      expect(find.text('Không có mục phù hợp'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sftpSortMenu')));
      await tester.pumpAndSettle();
      expect(find.text(_expected(language, 'Mới sửa trước')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const Key('sftpSortMenu')))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(_expected(language, 'Thao tác file')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_expected(language, 'Quyền truy cập…')));
      await tester.pumpAndSettle();
      expect(find.text(_expected(language, 'Quyền truy cập')), findsOneWidget);
      expect(
        find.text(_expected(language, 'Mã bát phân (000–7777)')),
        findsOneWidget,
      );
      expect(find.text(_expected(language, 'Chủ sở hữu')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('terminal search and logging labels: ${language.name}', (
      tester,
    ) async {
      final tab = TerminalSessionTab(
        localKey: 'terminal',
        sessionId: 'session',
        title: 'Nhật ký phiên',
        envTag: 'dev',
        protocol: 'ssh',
        terminal: Terminal(),
        controller: TerminalController(),
      );
      await _mount(
        tester,
        language,
        (_, _) => TerminalPane(
          tab: tab,
          isActive: true,
          showBroadcastBadge: false,
          onFocus: () {},
        ),
        tab: tab,
      );
      expect(
        find.textContaining('Nhật ký phiên', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('terminalFindBtn')));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, _expected(language, 'Tìm / Find')),
        findsOneWidget,
      );
      expect(
        find.byTooltip(
          _expected(language, 'Phân biệt hoa thường / Match case'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('terminalSessionTools')));
      await tester.pumpAndSettle();
      expect(
        find.text(_expected(language, 'Bắt đầu ghi đầu ra')),
        findsOneWidget,
      );
      expect(
        find.text(_expected(language, 'Xem và quản lý log…')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('command palette and guard labels: ${language.name}', (
      tester,
    ) async {
      await _mount(
        tester,
        language,
        (context, ref) => Column(
          children: [
            TextButton(
              onPressed: () => showCommandPaletteDialog(context, ref),
              child: const Text('Palette'),
            ),
            TextButton(
              onPressed: () => showCommandGuardDialog(
                context,
                command: 'rm -rf /\nwhoami',
                targetLabel: 'Nhật ký phiên',
                result: GuardResultDto(
                  severity: 'confirm',
                  reason: 'Xoá đệ quy thư mục gốc hoặc toàn bộ dữ liệu',
                  isMultiline: true,
                  lineCount: BigInt.two,
                ),
              ),
              child: const Text('Guard'),
            ),
          ],
        ),
      );
      await tester.tap(find.text('Palette'));
      await tester.pumpAndSettle();
      expect(
        find.text(_expected(language, 'Mở Local Shell mới')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('commandPaletteSearch')),
        'no_match_9284',
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          _expected(
            language,
            'Không tìm thấy kết quả. Thử tên host, lệnh hoặc tunnel khác.',
          ),
        ),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.byKey(const Key('commandPaletteSearch'))),
      ).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guard'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          _expected(language, 'Xoá đệ quy thư mục gốc hoặc toàn bộ dữ liệu'),
        ),
        findsOneWidget,
      );
      expect(find.text('Nhật ký phiên'), findsOneWidget);
      expect(find.text('rm -rf /\nwhoami'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('session log empty state: ${language.name}', (tester) async {
      await _mount(
        tester,
        language,
        (context, ref) => TextButton(
          onPressed: () => showSessionLogsDialog(context, ref),
          child: const Text('Logs'),
        ),
      );
      await tester.tap(find.text('Logs'));
      await tester.pumpAndSettle();
      expect(find.text(_expected(language, 'Nhật ký phiên')), findsOneWidget);
      expect(
        find.text(
          _expected(
            language,
            'Chưa có log. Mở một phiên và chọn Ghi phiên hiện tại.',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
