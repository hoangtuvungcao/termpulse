import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/automation/automation_dialog.dart';
import 'package:termpulse/features/automation/command_macro.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

import 'widget_test.dart' show FakeCoreBackend;

class _MemoryStorage implements AutomationStorage {
  String? json;
  bool failWrite = false;
  int writes = 0;
  _MemoryStorage([this.json]);
  @override
  Future<String?> read() async => json;
  @override
  Future<void> write(String json) async {
    if (failWrite) throw const FileSystemException('Controlled disk failure');
    writes++;
    this.json = json;
  }
}

class _Vault extends VaultController {
  @override
  VaultUiState build() =>
      const VaultUiState(initialized: true, unlocked: true, dbPath: '/test');
  void setLocked() => state = state.copyWith(unlocked: false);
}

class _Workspace extends SessionManagerController {
  @override
  WorkspaceState build() => WorkspaceState(tabs: [_tab('one')]);
  void replace(WorkspaceState workspace) => state = workspace;
}

class _Backend extends FakeCoreBackend {
  final checkedEnvironments = <String>[];
  @override
  GuardResultDto checkCommandGuard(String input, String envTag) {
    checkedEnvironments.add(envTag);
    return super.checkCommandGuard(input, envTag);
  }
}

TerminalSessionTab _tab(String id, {String environment = 'dev'}) =>
    TerminalSessionTab(
      localKey: 'tab_$id',
      sessionId: 'session_$id',
      title: 'Host $id',
      envTag: environment,
      protocol: 'ssh',
      terminal: Terminal(),
      controller: TerminalController(),
    );

CommandMacro _macro({String id = 'macro_one', List<MacroStep>? steps}) =>
    CommandMacro(
      id: id,
      name: 'Kiểm tra máy chủ',
      steps:
          steps ??
          const [MacroStep(command: 'pwd'), MacroStep(command: 'whoami')],
    );

ProviderContainer _container({AutomationStorage? storage, _Backend? backend}) =>
    ProviderContainer(
      overrides: [
        automationStorageProvider.overrideWithValue(
          storage ?? _MemoryStorage(),
        ),
        backendProvider.overrideWithValue(backend ?? _Backend()),
        vaultProvider.overrideWith(_Vault.new),
        sessionManagerProvider.overrideWith(_Workspace.new),
      ],
    );

Future<void> _tick() => Future<void>.delayed(Duration.zero);

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: FilledButton(
                onPressed: () => showAutomationDialog(context, ref),
                child: const Text('Open automation'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open automation'));
  await tester.pumpAndSettle();
}

void main() {
  test('macro JSON roundtrips Unicode, ordered steps, and delay', () {
    final macro = _macro(
      steps: const [
        MacroStep(command: 'printf "Tiếng Việt\\n"', delayAfterMs: 1200),
        MacroStep(command: 'pwd\nwhoami'),
      ],
    );
    final result = CommandMacro.decodeLibrary(
      CommandMacro.encodeLibrary([macro]),
    ).single;
    expect(result.name, macro.name);
    expect(
      result.steps.map((step) => step.command),
      macro.steps.map((step) => step.command),
    );
    expect(result.steps.first.delayAfterMs, 1200);
    expect(
      () => result.steps.add(const MacroStep(command: 'date')),
      throwsUnsupportedError,
    );
  });

  test(
    'macro validation rejects schema, duplicate IDs, controls, and caps',
    () {
      expect(
        () => CommandMacro.decodeLibrary('{"version":1}'),
        throwsFormatException,
      );
      expect(
        () => CommandMacro.decodeLibrary('not JSON'),
        throwsFormatException,
      );
      expect(
        () => CommandMacro.encodeLibrary([_macro(), _macro()]),
        throwsFormatException,
      );
      for (final step in [
        const MacroStep(command: ' '),
        const MacroStep(command: 'echo\x1b[31m'),
        const MacroStep(command: 'date', delayAfterMs: -1),
        const MacroStep(command: 'date', delayAfterMs: 600001),
        MacroStep(command: 'x' * 8193),
      ]) {
        expect(() => step.validate(), throwsFormatException);
      }
      expect(
        () => _macro(
          steps: List.filled(65, const MacroStep(command: 'pwd')),
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => CommandMacro.encodeLibrary(
          List.generate(129, (index) => _macro(id: 'macro_$index')),
        ),
        throwsFormatException,
      );
      expect(
        () => CommandMacro.decodeLibrary('x' * (CommandMacro.maxJsonBytes + 1)),
        throwsFormatException,
      );
      final invalidDelay =
          jsonDecode(CommandMacro.encodeLibrary([_macro()]))
              as Map<String, dynamic>;
      invalidDelay['macros'][0]['steps'][0]['delayAfterMs'] = 1.5;
      expect(
        () => CommandMacro.decodeLibrary(jsonEncode(invalidDelay)),
        throwsFormatException,
      );
    },
  );

  test(
    'library persists create edit duplicate delete and import without overwrite',
    () async {
      final storage = _MemoryStorage();
      final container = _container(storage: storage);
      addTearDown(container.dispose);
      expect(await container.read(automationLibraryProvider.future), isEmpty);
      final library = container.read(automationLibraryProvider.notifier);
      await library.save(_macro());
      await library.save(_macro().copyWith(name: 'Đã chỉnh sửa'));
      await library.duplicate(_macro());
      expect(
        await library.importJson(CommandMacro.encodeLibrary([_macro()])),
        1,
      );
      var macros = await container.read(automationLibraryProvider.future);
      expect(macros, hasLength(3));
      expect(macros.map((macro) => macro.id).toSet(), hasLength(3));
      expect(macros.first.name, 'Đã chỉnh sửa');
      await library.delete(macros[1].id);
      macros = CommandMacro.decodeLibrary(storage.json!);
      expect(macros, hasLength(2));
      final reopened = _container(storage: storage);
      addTearDown(reopened.dispose);
      expect(
        (await reopened.read(automationLibraryProvider.future)).first.name,
        'Đã chỉnh sửa',
      );
      expect(
        CommandMacro.decodeLibrary(await library.exportJson()),
        hasLength(2),
      );
    },
  );

  test(
    'library serializes concurrent saves and keeps data after a disk error',
    () async {
      final storage = _MemoryStorage();
      final container = _container(storage: storage);
      addTearDown(container.dispose);
      await container.read(automationLibraryProvider.future);
      final library = container.read(automationLibraryProvider.notifier);
      await Future.wait([
        library.save(_macro(id: 'first')),
        library.save(_macro(id: 'second')),
      ]);
      expect(
        await container.read(automationLibraryProvider.future),
        hasLength(2),
      );
      storage.failWrite = true;
      await expectLater(
        library.delete('first'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await container.read(automationLibraryProvider.future),
        hasLength(2),
      );
      storage.failWrite = false;
      await library.delete('first');
      expect(
        (await container.read(automationLibraryProvider.future)).single.id,
        'second',
      );
    },
  );

  test(
    'file storage writes and reopens the actual local JSON library',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'termpulse_macro_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = FileAutomationStorage(
        directory: () async => directory.path,
      );
      expect(await storage.read(), isNull);
      await storage.write(CommandMacro.encodeLibrary([_macro()]));
      await storage.write(CommandMacro.encodeLibrary([_macro(id: 'updated')]));
      expect(
        CommandMacro.decodeLibrary((await storage.read())!).single.id,
        'updated',
      );
      expect(
        await File(
          '${directory.path}/termpulse_command_macros.json.pending',
        ).exists(),
        isFalse,
      );
    },
  );

  test('runner sends in order and refuses a concurrent run', () async {
    final container = _container();
    addTearDown(container.dispose);
    final runner = container.read(automationRunnerProvider.notifier);
    final gate = Completer<bool>();
    final commands = <String>[];
    final running = runner.run(
      _macro(),
      sendGuarded: (command) async {
        commands.add(command);
        return commands.length == 1 ? gate.future : true;
      },
    );
    expect(commands, ['pwd']);
    expect(await runner.run(_macro(), sendGuarded: (_) async => true), isFalse);
    gate.complete(true);
    expect(await running, isTrue);
    expect(commands, ['pwd', 'whoami']);
    expect(container.read(automationRunnerProvider).completedSteps, 2);
    expect(container.read(automationRunnerProvider).running, isFalse);
  });

  test(
    'runner stops after rejected guard and never sends later commands',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      final commands = <String>[];
      expect(
        await container
            .read(automationRunnerProvider.notifier)
            .run(
              _macro(),
              sendGuarded: (command) async {
                commands.add(command);
                return false;
              },
            ),
        isFalse,
      );
      expect(commands, ['pwd']);
      expect(container.read(automationRunnerProvider).completedSteps, 0);
    },
  );

  for (final change in ['cancel', 'vault', 'target', 'broadcast']) {
    test(
      'runner interrupts delay on $change and preserves already-sent progress',
      () async {
        final container = _container();
        addTearDown(container.dispose);
        final runner = container.read(automationRunnerProvider.notifier);
        final commands = <String>[];
        final running = runner.run(
          _macro(
            steps: const [
              MacroStep(command: 'pwd', delayAfterMs: 600000),
              MacroStep(command: 'whoami'),
            ],
          ),
          sendGuarded: (command) async {
            commands.add(command);
            return true;
          },
        );
        await _tick();
        expect(container.read(automationRunnerProvider).completedSteps, 1);
        switch (change) {
          case 'cancel':
            runner.cancel();
          case 'vault':
            (container.read(vaultProvider.notifier) as _Vault).setLocked();
          case 'target':
            (container.read(sessionManagerProvider.notifier) as _Workspace)
                .replace(WorkspaceState(tabs: [_tab('changed')]));
          case 'broadcast':
            container.read(sessionManagerProvider.notifier).toggleBroadcast();
        }
        expect(await running.timeout(const Duration(seconds: 1)), isFalse);
        expect(commands, ['pwd']);
        expect(container.read(automationRunnerProvider).completedSteps, 1);
        expect(container.read(automationRunnerProvider).running, isFalse);
      },
    );
  }

  test(
    'runner refuses locked and disconnected targets and stops on disposal',
    () async {
      final container = _container();
      final runner = container.read(automationRunnerProvider.notifier);
      final vault = container.read(vaultProvider.notifier) as _Vault;
      vault.setLocked();
      expect(
        await runner.run(_macro(), sendGuarded: (_) async => true),
        isFalse,
      );
      container.dispose();
      final next = _container();
      final running = next
          .read(automationRunnerProvider.notifier)
          .run(
            _macro(
              steps: const [
                MacroStep(command: 'pwd', delayAfterMs: 600000),
                MacroStep(command: 'date'),
              ],
            ),
            sendGuarded: (_) async => true,
          );
      await _tick();
      next.dispose();
      expect(await running.timeout(const Duration(seconds: 1)), isFalse);
    },
  );

  for (final size in [
    const Size(360, 640),
    const Size(360, 360),
    const Size(1000, 700),
  ]) {
    testWidgets('macro library fits $size and disables run without a session', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = _container(
        storage: _MemoryStorage(CommandMacro.encodeLibrary([_macro()])),
      );
      addTearDown(container.dispose);
      (container.read(sessionManagerProvider.notifier) as _Workspace).replace(
        const WorkspaceState(),
      );
      await _open(tester, container);
      await tester.scrollUntilVisible(
        find.byKey(const Key('automationRun_macro_one')),
        140,
        scrollable: find.byType(Scrollable).first,
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('automationRun_macro_one')),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('macro editor saves actual ordered commands and delays', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final container = _container(storage: storage);
    addTearDown(container.dispose);
    await _open(tester, container);
    await tester.tap(find.byKey(const Key('automationCreate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('macroName')), 'Daily checks');
    await tester.enterText(find.byKey(const Key('macroCommand_0')), 'pwd');
    await tester.enterText(find.byKey(const Key('macroDelay_0')), '250');
    await tester.ensureVisible(find.byKey(const Key('macroAddStep')));
    await tester.tap(find.byKey(const Key('macroAddStep')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('macroCommand_1')));
    await tester.enterText(find.byKey(const Key('macroCommand_1')), 'whoami');
    await tester.tap(find.byKey(const Key('macroSave')));
    await tester.pumpAndSettle();
    final macro = CommandMacro.decodeLibrary(storage.json!).single;
    expect(macro.name, 'Daily checks');
    expect(macro.steps.map((step) => step.command), ['pwd', 'whoami']);
    expect(macro.steps.first.delayAfterMs, 250);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'macro uses real PROD broadcast guard and rejects changed recipients',
    (tester) async {
      final backend = _Backend();
      final container = _container(
        backend: backend,
        storage: _MemoryStorage(
          CommandMacro.encodeLibrary([
            _macro(
              steps: const [MacroStep(command: 'rm -rf /tmp/controlled-only')],
            ),
          ]),
        ),
      );
      addTearDown(container.dispose);
      final manager =
          container.read(sessionManagerProvider.notifier) as _Workspace;
      manager.replace(
        WorkspaceState(
          tabs: [
            _tab('one'),
            _tab('prod', environment: 'prod'),
          ],
          broadcastMode: true,
        ),
      );
      await _open(tester, container);
      await tester.ensureVisible(
        find.byKey(const Key('automationRun_macro_one')),
      );
      await tester.tap(find.byKey(const Key('automationRun_macro_one')));
      await tester.pumpAndSettle();
      expect(backend.checkedEnvironments, ['prod']);
      expect(find.text('Broadcast (2 host)'), findsOneWidget);
      expect(backend.sentInputs, isEmpty);
      expect(backend.broadcastCalls, isEmpty);
      manager.replace(WorkspaceState(tabs: [_tab('one')], broadcastMode: true));
      // Approving an already displayed guard cannot send to a different target set.
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(backend.broadcastCalls, isEmpty);
      expect(container.read(automationRunnerProvider).running, isFalse);
      expect(
        container.read(automationRunnerProvider).message,
        contains('thay đổi'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Vault lock while a guard is open disables stale approval', (
    tester,
  ) async {
    final backend = _Backend();
    final container = _container(
      backend: backend,
      storage: _MemoryStorage(
        CommandMacro.encodeLibrary([
          _macro(
            steps: const [MacroStep(command: 'rm -rf /tmp/controlled-only')],
          ),
        ]),
      ),
    );
    addTearDown(container.dispose);
    await _open(tester, container);
    await tester.tap(find.byKey(const Key('automationRun_macro_one')));
    await tester.pumpAndSettle();
    expect(find.text('rm -rf /tmp/controlled-only'), findsNWidgets(2));
    (container.read(vaultProvider.notifier) as _Vault).setLocked();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(backend.sentInputs, isEmpty);
    expect(backend.broadcastCalls, isEmpty);
    expect(container.read(automationRunnerProvider).running, isFalse);
    expect(
      container.read(automationRunnerProvider).message,
      contains('Vault bị khóa'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
