import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/sftp/remote_editor_dialog.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _Backend extends FakeCoreBackend {
  final deletes = <String>[];
  final failedDeletes = <String>{};
  final downloads = <({String session, String remote, String local})>[];
  final permissions = <({String path, int mode})>[];
  String remoteText = 'original';
  final writes = <String>[];
  int reads = 0;
  bool failRead = false;

  @override
  Future<void> sftpDeleteEntry(
    String sessionId,
    String path,
    bool isDir,
  ) async {
    deletes.add(path);
    if (failedDeletes.contains(path)) throw StateError('Permission denied');
  }

  @override
  Future<void> sftpSetPermissions(
    String sessionId,
    String path,
    int mode,
  ) async {
    permissions.add((path: path, mode: mode));
  }

  @override
  Stream<TransferProgressDto> sftpStartTransfer({
    required String sessionId,
    required bool isUpload,
    required String localPath,
    required String remotePath,
  }) async* {
    downloads.add((session: sessionId, remote: remotePath, local: localPath));
    yield TransferProgressDto(
      transferId: 'download_${downloads.length}',
      bytesDone: BigInt.one,
      bytesTotal: BigInt.one,
      finished: true,
    );
  }

  @override
  Future<String> sftpReadText(String sessionId, String path) async {
    reads++;
    if (failRead) throw StateError('Connection lost');
    return remoteText;
  }

  @override
  Future<void> sftpWriteText(
    String sessionId,
    String path,
    String content,
  ) async {
    writes.add(content);
    remoteText = content;
  }
}

class _LocalPathAccess implements SftpLocalPathAccess {
  final entries = <String>{};
  final directories = <String>{'/safe/downloads'};
  final checkedDirectories = <String>[];
  final checkedEntries = <String>[];

  @override
  Future<bool> directoryExists(String path) async {
    checkedDirectories.add(path);
    return directories.contains(path);
  }

  @override
  Future<bool> entryExists(String path) async {
    checkedEntries.add(path);
    return entries.contains(path);
  }
}

class _Sessions extends SessionManagerController {
  final TerminalSessionTab initial;
  int reloads = 0;
  _Sessions(this.initial);

  @override
  WorkspaceState build() => WorkspaceState(tabs: [initial]);

  void show(TerminalSessionTab tab) => state = state.copyWith(tabs: [tab]);

  @override
  Future<void> loadSftpDirectory(
    String localKey,
    String path, {
    bool syncTerminal = false,
  }) async {
    reloads++;
  }
}

SftpEntryDto _entry(
  String name, {
  bool directory = false,
  int size = 1,
  int modified = 1,
  int permissions = 0x1a4,
}) => SftpEntryDto(
  name: name,
  path: '/work/$name',
  isDir: directory,
  isSymlink: false,
  size: BigInt.from(size),
  permissions: permissions,
  modified: BigInt.from(modified),
);

TerminalSessionTab _tab(List<SftpEntryDto> entries, {String cwd = '/work'}) =>
    TerminalSessionTab(
      localKey: 'sftp',
      sessionId: 'session',
      title: 'SSH',
      envTag: 'dev',
      protocol: 'ssh',
      terminal: Terminal(),
      controller: TerminalController(),
      cwd: cwd,
      sftpEntries: entries,
    );

Future<_Sessions> _mount(
  WidgetTester tester,
  _Backend backend,
  List<SftpEntryDto> entries, {
  bool editor = false,
  Size size = const Size(700, 800),
  SftpLocalPathAccess? localPathAccess,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(_tab(entries));
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(backend),
      sessionManagerProvider.overrideWith(() => sessions),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => editor
                ? TextButton(
                    onPressed: () => showRemoteFileEditor(
                      context,
                      ref,
                      sessionId: 'session',
                      remotePath: '/work/file.txt',
                    ),
                    child: const Text('Open editor'),
                  )
                : SftpPanel(
                    tab: ref.watch(sessionManagerProvider).tabs.single,
                    localPathAccess: localPathAccess,
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sessions;
}

Future<void> _selectAll(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sftpSelectionMode')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('sftpSelectAll')));
  await tester.pumpAndSettle();
}

List<String> _names(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title! as Text).data!)
    .toList();

// Batch dialogs intentionally hold the action lock; use a bounded pump while
// its indeterminate activity indicator is active behind the modal route.
Future<void> _dialogFrame(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 350));

void main() {
  testWidgets('Remote files filter, sort and reveal hidden entries', (
    tester,
  ) async {
    await _mount(tester, _Backend(), [
      _entry('z.txt', size: 99, modified: 2),
      _entry('.env'),
      _entry('A.txt', size: 3, modified: 5),
      _entry('folder', directory: true),
    ]);
    expect(_names(tester), ['folder', 'A.txt', 'z.txt']);
    await tester.tap(find.byKey(const Key('sftpSortMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dung lượng lớn trước'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_names(tester), ['folder', 'z.txt', 'A.txt']);
    await tester.tap(find.byKey(const Key('sftpSortMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mới sửa trước'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_names(tester), ['folder', 'A.txt', 'z.txt']);
    await tester.tap(find.byKey(const Key('sftpShowHidden')));
    await tester.pumpAndSettle();
    expect(_names(tester), contains('.env'));
    await tester.enterText(find.byKey(const Key('sftpFilterField')), 'A.TXT');
    await tester.pumpAndSettle();
    expect(_names(tester), ['A.txt']);
    await tester.enterText(find.byKey(const Key('sftpFilterField')), 'absent');
    await tester.pumpAndSettle();
    expect(find.text('Không có mục phù hợp'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Selections cannot retain filtered items or another directory', (
    tester,
  ) async {
    final entries = [_entry('a.txt'), _entry('b.txt')];
    final sessions = await _mount(tester, _Backend(), entries);
    await _selectAll(tester);
    expect(find.text('2/2 mục đã chọn'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sftpFilterField')), 'a.txt');
    await tester.pumpAndSettle();
    expect(find.text('1/1 mục đã chọn'), findsOneWidget);
    await tester.tap(find.byTooltip('Xoá bộ lọc'));
    await tester.pumpAndSettle();
    expect(find.text('1/2 mục đã chọn'), findsOneWidget);
    sessions.show(_tab(entries, cwd: '/other'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sftpDeleteSelected')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bulk deletion confirms once and reports every failure', (
    tester,
  ) async {
    final backend = _Backend()..failedDeletes.add('/work/b.txt');
    final sessions = await _mount(tester, backend, [
      _entry('a.txt'),
      _entry('b.txt'),
      _entry('empty', directory: true),
    ]);
    await _selectAll(tester);
    await tester.tap(find.byKey(const Key('sftpDeleteSelected')));
    await _dialogFrame(tester);
    expect(find.text('Xoá 3 mục đã chọn?'), findsOneWidget);
    expect(find.textContaining('2 file, 1 thư mục'), findsOneWidget);
    expect(find.textContaining('không xoá đệ quy'), findsOneWidget);
    expect(backend.deletes, isEmpty);
    await tester.tap(find.text('Xoá 3 mục'));
    await _dialogFrame(tester);
    expect(backend.deletes.toSet(), {
      '/work/a.txt',
      '/work/b.txt',
      '/work/empty',
    });
    expect(find.textContaining('Đã xoá 2/3 mục.'), findsOneWidget);
    expect(
      find.textContaining('b.txt: Bad state: Permission denied'),
      findsOneWidget,
    );
    expect(sessions.reloads, 1);
    await tester.tap(find.text('Đóng'));
    await tester.pumpAndSettle();
    expect(find.text('1/3 mục đã chọn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancelling a batch and changing location never deletes files', (
    tester,
  ) async {
    final backend = _Backend();
    final entries = [_entry('a.txt')];
    final sessions = await _mount(tester, backend, entries);
    await _selectAll(tester);
    await tester.tap(find.byKey(const Key('sftpDeleteSelected')));
    await _dialogFrame(tester);
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();
    expect(backend.deletes, isEmpty);
    await tester.tap(find.byKey(const Key('sftpDeleteSelected')));
    await _dialogFrame(tester);
    sessions.show(_tab(entries, cwd: '/other'));
    await tester.pump();
    await tester.tap(find.text('Xoá 1 mục'));
    await _dialogFrame(tester);
    expect(backend.deletes, isEmpty);
    expect(
      find.textContaining('phiên hoặc thư mục đã thay đổi'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Batch download skips unsafe names, folders and existing targets',
    (tester) async {
      const destination = '/safe/downloads';
      final localPaths = _LocalPathAccess()
        ..entries.addAll(['$destination/exists.txt', '$destination/link.txt']);
      final backend = _Backend();
      await _mount(tester, backend, [
        _entry('good.txt'),
        _entry('exists.txt'),
        _entry('link.txt'),
        _entry('unsafe\\name.txt'),
        _entry('folder', directory: true),
      ], localPathAccess: localPaths);
      await _selectAll(tester);
      await tester.tap(find.byKey(const Key('sftpDownloadSelected')));
      await _dialogFrame(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Thư mục lưu trên máy'),
        destination,
      );
      await tester.tap(find.text('Tiếp tục'));
      await _dialogFrame(tester);
      await _dialogFrame(tester);
      expect(find.text('Tải 1 file về máy?'), findsOneWidget);
      expect(find.textContaining('Bỏ qua: 4 mục.'), findsOneWidget);
      expect(backend.downloads, isEmpty);
      await tester.tap(find.text('Tải 1 file'));
      await _dialogFrame(tester);
      await _dialogFrame(tester);
      expect(backend.downloads, [
        (
          session: 'session',
          remote: '/work/good.txt',
          local: '$destination/good.txt',
        ),
      ]);
      expect(find.textContaining('Đã gửi 1 yêu cầu tải file.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Permission editor validates octal and preserves special bits', (
    tester,
  ) async {
    final backend = _Backend();
    await _mount(tester, backend, [_entry('app.sh', permissions: 0x9a4)]);
    await tester.tap(find.byTooltip('Thao tác file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quyền truy cập…'));
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('sftpPermissionMode'));
    expect(tester.widget<TextField>(mode).controller!.text, '4644');
    await tester.tap(find.byKey(const ValueKey('sftpPermission:6:1')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(mode).controller!.text, '4744');
    await tester.enterText(mode, '888');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Áp dụng quyền'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(mode, '4750');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Áp dụng quyền'));
    await tester.pumpAndSettle();
    expect(backend.permissions, [(path: '/work/app.sh', mode: 0x9e8)]);
    expect(backend.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Narrow SFTP tools and permission dialog fit a phone viewport', (
    tester,
  ) async {
    await _mount(tester, _Backend(), [
      _entry('file.txt'),
    ], size: const Size(320, 640));
    await _selectAll(tester);
    await tester.tap(find.byTooltip('Thao tác file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quyền truy cập…'));
    await tester.pumpAndSettle();
    expect(find.text('Áp dụng quyền'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Editor preserves local changes when the remote file conflicts', (
    tester,
  ) async {
    final backend = _Backend();
    await _mount(tester, backend, [], editor: true);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my edits');
    await tester.pump();
    expect(find.text('Có thay đổi chưa lưu'), findsOneWidget);
    backend.remoteText = 'someone else';
    await tester.tap(find.text('Lưu lên Server'));
    await tester.pumpAndSettle();
    expect(backend.reads, 2);
    expect(backend.writes, isEmpty);
    expect(find.text('File trên server đã thay đổi'), findsOneWidget);
    expect(backend.writes, isEmpty);
    await tester.tap(find.text('Giữ bản đang sửa'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'my edits',
    );
    expect(find.text('Có thay đổi chưa lưu'), findsOneWidget);
    expect(backend.remoteText, 'someone else');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Editor checks again after explicit overwrite consent', (
    tester,
  ) async {
    final backend = _Backend();
    await _mount(tester, backend, [], editor: true);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my edits');
    await tester.pump();
    backend.remoteText = 'other version 1';
    await tester.tap(find.text('Lưu lên Server'));
    await tester.pumpAndSettle();
    backend.remoteText = 'other version 2';
    await tester.tap(find.text('Ghi đè bản server'));
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    expect(find.text('File trên server đã thay đổi'), findsOneWidget);
    await tester.tap(find.text('Ghi đè bản server'));
    await tester.pumpAndSettle();
    expect(backend.writes, ['my edits']);
    expect(find.text('Đã lưu lên server.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Editor can reload a conflict and refuses writes if preflight fails',
    (tester) async {
      final backend = _Backend();
      await _mount(tester, backend, [], editor: true);
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'my edits');
      await tester.pump();
      backend.remoteText = 'latest';
      await tester.tap(find.text('Lưu lên Server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tải bản server'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'latest',
      );
      expect(find.text('Nội dung đã đồng bộ'), findsOneWidget);
      expect(backend.writes, isEmpty);
      await tester.enterText(find.byType(TextField), 'new local edits');
      await tester.pump();
      backend.failRead = true;
      await tester.tap(find.text('Lưu lên Server'));
      await tester.pumpAndSettle();
      expect(backend.writes, isEmpty);
      expect(
        find.textContaining('Không kiểm tra hoặc lưu được file:'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'new local edits',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
