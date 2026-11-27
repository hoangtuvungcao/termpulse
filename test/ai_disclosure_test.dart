import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_ai_privacy.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/ops/bottom_dock.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _AiBackend extends FakeCoreBackend {
  final requests = <Map<String, String?>>[];

  @override
  Future<AiDraftDto> aiDraftCommand({
    required String endpointUrl,
    String? apiKey,
    required String model,
    required String prompt,
    required String osHint,
    required String shellHint,
  }) async {
    requests.add({
      'endpointUrl': endpointUrl,
      'apiKey': apiKey,
      'model': model,
      'prompt': prompt,
      'osHint': osHint,
      'shellHint': shellHint,
    });
    return const AiDraftDto(
      command: 'pwd',
      explanation: 'Print the working directory.',
      sentContextPreview: '',
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  _AiBackend backend, {
  Size size = const Size(980, 800),
  AppLanguage language = AppLanguage.vi,
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
      child: AppLocalizationScope(
        language: language,
        child: MaterialApp(
          theme: buildTermPulseTheme(AppThemePreset.dark),
          home: const Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: BottomDock()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final tab = find.text(
    translateAppMessage(language, 'AI Draft (BYO-Key/Ollama)'),
  );
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _acknowledge(WidgetTester tester) async {
  final checkbox = find.descendant(
    of: find.byKey(const Key('aiDisclosureAcknowledgement')),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

FilledButton _generateButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('aiGenerateDraft')));

void main() {
  testWidgets('AI requires explicit consent for both button and keyboard', (
    tester,
  ) async {
    final backend = _AiBackend();
    await _mount(tester, backend);
    await _enter(tester, 'aiPromptField', 'Print the working directory');
    expect(_generateButton(tester).onPressed, isNull);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(backend.requests, isEmpty);
    expect(
      find.text('Đọc thông tin dữ liệu và xác nhận trước khi gửi yêu cầu AI.'),
      findsOneWidget,
    );

    await _acknowledge(tester);
    expect(_generateButton(tester).onPressed, isNotNull);
    await tester.ensureVisible(find.byKey(const Key('aiGenerateDraft')));
    await tester.tap(find.byKey(const Key('aiGenerateDraft')));
    await tester.pumpAndSettle();
    expect(backend.requests, hasLength(1));
    expect(backend.requests.single['prompt'], 'Print the working directory');
    expect(backend.requests.single['osHint'], Platform.operatingSystem);
    expect(
      backend.requests.single['shellHint'],
      Platform.isWindows ? 'PowerShell' : 'bash',
    );
    expect(backend.sentInputs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI names the exact recipient without exposing the API key', (
    tester,
  ) async {
    final backend = _AiBackend();
    await _mount(tester, backend);
    const endpoint = 'https://ai.example.test/team/v1/chat/completions';
    const key = 'private-test-key-do-not-render';
    await _enter(tester, 'aiEndpointField', endpoint);
    await _enter(tester, 'aiKeyField', key);
    await _enter(tester, 'aiPromptField', 'List files');
    final recipient = tester.widget<SelectableText>(
      find.byKey(const Key('aiDisclosureRecipient')),
    );
    expect(recipient.data, 'Nơi nhận: $endpoint');
    expect(find.byKey(const Key('aiHttpWarning')), findsNothing);
    final disclosure = find.byKey(const Key('aiDisclosurePanel'));
    final copy = tester
        .widgetList<Text>(
          find.descendant(of: disclosure, matching: find.byType(Text)),
        )
        .map((widget) => widget.data ?? '')
        .join('\n');
    expect(
      copy,
      contains('không tự đính kèm lịch sử terminal hoặc dữ liệu Vault'),
    );
    expect(copy, contains('chỉ được gửi trong phần xác thực tới endpoint đó'));
    expect(copy, isNot(contains(key)));
    expect(recipient.data, isNot(contains(key)));

    await _acknowledge(tester);
    await tester.ensureVisible(find.byKey(const Key('aiGenerateDraft')));
    await tester.tap(find.byKey(const Key('aiGenerateDraft')));
    await tester.pumpAndSettle();
    expect(backend.requests.single['endpointUrl'], endpoint);
    expect(backend.requests.single['apiKey'], key);
    expect(backend.requests.single['prompt'], 'List files');
    expect(backend.requests.single.keys, isNot(contains('terminalHistory')));
    expect(backend.requests.single.keys, isNot(contains('vaultData')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI resets consent when endpoint or model changes', (
    tester,
  ) async {
    final backend = _AiBackend();
    await _mount(tester, backend);
    await _enter(tester, 'aiPromptField', 'Print the working directory');
    expect(find.byKey(const Key('aiHttpWarning')), findsOneWidget);
    await _acknowledge(tester);
    expect(_generateButton(tester).onPressed, isNotNull);

    await _enter(
      tester,
      'aiEndpointField',
      'https://new-ai.example.test/v1/chat/completions',
    );
    expect(_generateButton(tester).onPressed, isNull);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('aiDisclosureAcknowledgement')),
          )
          .value,
      isFalse,
    );
    await _acknowledge(tester);
    await _enter(tester, 'aiModelField', 'another-model');
    expect(_generateButton(tester).onPressed, isNull);
    expect(backend.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI hides invalid recipient credentials and blocks consent', (
    tester,
  ) async {
    final backend = _AiBackend();
    await _mount(tester, backend);
    await _enter(
      tester,
      'aiEndpointField',
      'https://user:embedded-secret@ai.example.test/api/chat',
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('aiDisclosureRecipient')),
          )
          .data,
      'Nhập endpoint HTTP(S) hợp lệ để xem nơi nhận.',
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('aiDisclosureAcknowledgement')),
          )
          .onChanged,
      isNull,
    );
    expect(_generateButton(tester).onPressed, isNull);
    expect(backend.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    testWidgets('AI consent fits compact phone in ${language.code}', (
      tester,
    ) async {
      final backend = _AiBackend();
      await _mount(
        tester,
        backend,
        size: const Size(360, 480),
        language: language,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      final title = language == AppLanguage.vi
          ? 'Dữ liệu gửi cho AI'
          : aiPrivacyTranslations['Dữ liệu gửi cho AI']![language.index - 1];
      expect(find.text(title), findsOneWidget);
      await _acknowledge(tester);
      await tester.ensureVisible(find.byKey(const Key('aiGenerateDraft')));
      expect(_generateButton(tester).onPressed, isNotNull);
      expect(backend.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
