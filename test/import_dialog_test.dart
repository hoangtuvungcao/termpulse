import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/import_dialog.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _ImportBackend extends FakeCoreBackend {
  List<String> warnings = [
    'Bỏ qua wildcard block `Host *`',
    'Host `production` tham chiếu ProxyJump `bastion` chưa có trong file.',
  ];
  bool failImport = false;
  final importedFormats = <String>[];

  Future<ImportResultDto> _import(String format) async {
    importedFormats.add(format);
    if (failImport) throw StateError('Import storage unavailable');
    return ImportResultDto(
      hostsImported: BigInt.one,
      identitiesImported: BigInt.zero,
      warnings: List.of(warnings),
    );
  }

  @override
  Future<ImportResultDto> importSshConfig(String content) => _import('ssh');

  @override
  Future<ImportResultDto> importCsv(String content) => _import('csv');

  @override
  Future<ImportResultDto> importPuttyReg(String content) => _import('putty');

  @override
  Future<String> vaultExportJson({required bool includeSecrets}) async => '{}';
}

Future<void> _openDialog(
  WidgetTester tester,
  _ImportBackend backend, {
  Size size = const Size(980, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showImportExportDialog(context, ref),
              child: const Text('Open import'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open import'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'controlled config');
}

Future<void> _import(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Nhập vào Vault'));
  await tester.tap(find.text('Nhập vào Vault'));
  await tester.pumpAndSettle();
}

void main() {
  for (final format in ['ssh', 'csv', 'putty']) {
    testWidgets('$format import shows every backend warning', (tester) async {
      final backend = _ImportBackend();
      await _openDialog(tester, backend);
      if (format != 'ssh') {
        await tester.tap(find.text(format == 'csv' ? 'CSV' : 'PuTTY .reg'));
        await tester.pumpAndSettle();
      }
      await _import(tester);
      expect(backend.importedFormats, [format]);
      expect(find.textContaining('Đã nhập 1 Host'), findsOneWidget);
      expect(find.textContaining('Cần kiểm tra 2 cảnh báo'), findsOneWidget);
      for (final warning in backend.warnings) {
        expect(find.text(warning), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'warnings survive copy and reset on next clean import or export',
    (tester) async {
      final backend = _ImportBackend();
      await _openDialog(tester, backend);
      await _import(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Sao chép'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('importWarnings')), findsOneWidget);

      backend.warnings = const [];
      await _import(tester);
      expect(find.byKey(const Key('importWarnings')), findsNothing);
      expect(find.textContaining('Cần kiểm tra'), findsNothing);

      backend.warnings = ['Review skipped directive'];
      await _import(tester);
      await tester.tap(find.text('Xuất JSON'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('importWarnings')), findsNothing);
      expect(find.textContaining('Đã xuất json'), findsOneWidget);
    },
  );

  testWidgets('failed import clears warnings from the previous result', (
    tester,
  ) async {
    final backend = _ImportBackend();
    await _openDialog(tester, backend);
    await _import(tester);
    backend.failImport = true;
    await _import(tester);
    expect(find.byKey(const Key('importWarnings')), findsNothing);
    expect(find.textContaining('Import storage unavailable'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Nhập vào Vault'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('many import warnings scroll on a compact phone', (tester) async {
    final backend = _ImportBackend()
      ..warnings = List.generate(
        30,
        (index) => 'Cảnh báo cấu hình ${index + 1}',
      );
    await _openDialog(tester, backend, size: const Size(360, 640));
    await _import(tester);
    final warnings = find.byKey(const Key('importWarnings'));
    await tester.ensureVisible(warnings);
    await tester.drag(warnings, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('Cảnh báo cấu hình 30').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Đóng'));
    await tester.tap(find.text('Đóng'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
