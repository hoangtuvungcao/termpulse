import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

import 'state_regression_test.dart' show ControlledBackend;

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final chromeless in [true, false]) {
    final variant = chromeless ? 'mobile' : 'desktop split';
    testWidgets('$variant status and search scroll at short height', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(740, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = ControlledBackend();
      final container = ProviderContainer(
        overrides: [backendProvider.overrideWithValue(backend)],
      );
      final height = ValueNotifier(260.0);
      final width = ValueNotifier(420.0);
      final search = ValueNotifier(0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        for (final connection in backend.connections) {
          unawaited(connection.close());
        }
        unawaited(backend.transfer.close());
        height.dispose();
        width.dispose();
        search.dispose();
        await tester.pump();
      });
      final manager = container.read(sessionManagerProvider.notifier);
      await manager.openQuickSsh(target: 'ops@first.example:22');
      await manager.openQuickSsh(target: 'ops@second.example:22');
      backend.connections.first.add(
        const TerminalEventDto(kind: 'session_opened', text: 'first'),
      );
      backend.connections.last.add(
        const TerminalEventDto(kind: 'session_opened', text: 'second'),
      );
      backend.connections.last.add(
        TerminalEventDto(
          kind: 'output_bytes',
          bytes: Uint8List.fromList(
            'PERSISTED_OUTPUT\r\nPERSISTED_AGAIN\r\n'.codeUnits,
          ),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTermPulseTheme(AppThemePreset.dark),
            builder: (context, child) => AppLocalizationScope(
              language: AppLanguage.en,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.6)),
                child: child!,
              ),
            ),
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder(
                  valueListenable: height,
                  builder: (_, value, child) =>
                      SizedBox(height: value, child: child),
                  child: ValueListenableBuilder(
                    valueListenable: width,
                    builder: (_, value, child) =>
                        SizedBox(width: value, child: child),
                    child: ValueListenableBuilder(
                      valueListenable: search,
                      builder: (_, request, _) => Consumer(
                        builder: (_, ref, _) {
                          final tab = ref
                              .watch(sessionManagerProvider)
                              .activeTab!;
                          return TerminalPane(
                            key: ValueKey(tab.localKey),
                            tab: tab,
                            isActive: true,
                            showBroadcastBadge: false,
                            chromeless: chromeless,
                            showSplitFocusLine: !chromeless,
                            searchRequest: request,
                            onFocus: () {},
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final terminalFinder = find.byType(TerminalView);
      final originalState = tester.state(terminalFinder);
      final originalView = tester.widget<TerminalView>(terminalFinder);
      final originalTab = container.read(sessionManagerProvider).activeTab!;
      search.value++;
      await tester.pumpAndSettle();
      final searchField = find.byKey(const Key('terminalSearchField'));
      await tester.enterText(searchField, 'PERSISTED');
      backend.connections.last.addError(
        StateError('SSH_AUTHENTICATION_REJECTED: controlled failure'),
      );
      await tester.pumpAndSettle();
      expect(container.read(sessionManagerProvider).tabs, hasLength(2));
      expect(container.read(sessionManagerProvider).activeTab!.closed, isTrue);
      expect(container.read(sessionManagerProvider).lastError, isNotNull);

      height.value = 64;
      tester.view.viewInsets = const FakeViewPadding(bottom: 140);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.state(terminalFinder), same(originalState));
      expect(
        tester.widget<TerminalView>(terminalFinder).controller,
        same(originalView.controller),
      );
      expect(tester.getSize(terminalFinder).height, greaterThan(0));
      expect(
        tester.widget<TextField>(searchField).controller!.text,
        'PERSISTED',
      );
      final reconnect = find.byKey(const Key('terminalReconnectBtn'));
      await Scrollable.ensureVisible(tester.element(reconnect), alignment: .5);
      await tester.pumpAndSettle();
      expect(reconnect.hitTestable(), findsOneWidget);
      await tester.tap(reconnect);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(backend.connections, hasLength(3));
      expect(container.read(sessionManagerProvider).activeTab!.closed, isFalse);
      expect(tester.state(terminalFinder), same(originalState));
      expect(
        container.read(sessionManagerProvider).activeTab!.terminal,
        same(originalTab.terminal),
      );
      expect(
        originalTab.terminal.buffer.getText(),
        contains('PERSISTED_OUTPUT'),
      );

      backend.connections.last.add(
        const TerminalEventDto(kind: 'session_opened', text: 'reconnected'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TerminalView>(terminalFinder).focusNode!.hasFocus,
        isTrue,
      );
      originalTab.terminal.textInput('status\r');
      await tester.pump();
      expect(backend.inputs, ['status\r']);
      expect(tester.takeException(), isNull);

      if (!chromeless) {
        final editable = find.descendant(
          of: searchField,
          matching: find.byType(EditableText),
        );
        final originalSearchState = tester.state(editable);
        height.value = 180;
        width.value = 180;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.state(editable), same(originalSearchState));
        expect(tester.state(terminalFinder), same(originalState));
        expect(
          tester.widget<TextField>(searchField).controller!.text,
          'PERSISTED',
        );
        await Scrollable.ensureVisible(
          tester.element(searchField),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(searchField.hitTestable(), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('terminalSearchCount')))
              .data,
          '1/2',
        );
        final next = find.byKey(const Key('terminalSearchNext'));
        await Scrollable.ensureVisible(tester.element(next), alignment: .5);
        await tester.pumpAndSettle();
        expect(next.hitTestable(), findsOneWidget);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('terminalSearchCount')))
              .data,
          '2/2',
        );
        final previous = find.byKey(const Key('terminalSearchPrevious'));
        await Scrollable.ensureVisible(tester.element(previous), alignment: .5);
        await tester.pumpAndSettle();
        expect(previous.hitTestable(), findsOneWidget);
        await tester.tap(previous);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('terminalSearchCount')))
              .data,
          '1/2',
        );
        final close = find.byKey(const Key('terminalSearchClose'));
        await Scrollable.ensureVisible(tester.element(close), alignment: .5);
        await tester.pumpAndSettle();
        expect(close.hitTestable(), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('terminalSearchBar')), findsNothing);
        expect(tester.state(terminalFinder), same(originalState));
        expect(
          originalTab.terminal.buffer.getText(),
          contains('PERSISTED_OUTPUT'),
        );
        expect(backend.inputs, ['status\r']);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
