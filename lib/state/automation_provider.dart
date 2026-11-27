import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/features/automation/command_macro.dart';
import 'package:termpulse/state/app_providers.dart';

abstract class AutomationStorage {
  Future<String?> read();
  Future<void> write(String json);
}

/// Plaintext local library. Never put passwords/private keys in command macros.
class FileAutomationStorage implements AutomationStorage {
  final Future<String> Function() directory;
  FileAutomationStorage({Future<String> Function()? directory})
    : directory = directory ?? ForegroundBridge.getAppDataDir;

  Future<File> _file() async => File(
    '${await directory()}${Platform.pathSeparator}termpulse_command_macros.json',
  );

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > CommandMacro.maxJsonBytes) {
      throw const FormatException('Tệp macro vượt giới hạn 2 MiB.');
    }
    return file.readAsString();
  }

  @override
  Future<void> write(String json) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.pending');
    await pending.writeAsString(json, flush: true);
    // Rename the sibling file only after a complete, flushed write.
    await pending.rename(file.path);
  }
}

final automationStorageProvider = Provider<AutomationStorage>(
  (ref) => FileAutomationStorage(),
);

class AutomationLibraryController extends AsyncNotifier<List<CommandMacro>> {
  Future<void> _writes = Future<void>.value();

  @override
  Future<List<CommandMacro>> build() async {
    final raw = await ref.watch(automationStorageProvider).read();
    return raw == null ? const [] : CommandMacro.decodeLibrary(raw);
  }

  Future<void> _update(List<CommandMacro> Function(List<CommandMacro>) update) {
    final operation = _writes.then((_) async {
      final current = await future;
      if (!ref.mounted) return;
      final next = List<CommandMacro>.unmodifiable(update(current));
      final json = CommandMacro.encodeLibrary(next);
      await ref.read(automationStorageProvider).write(json);
      if (ref.mounted) state = AsyncData(next);
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> save(CommandMacro macro) {
    macro.validate();
    return _update(
      (current) => [
        for (final existing in current)
          if (existing.id == macro.id) macro else existing,
        if (!current.any((existing) => existing.id == macro.id)) macro,
      ],
    );
  }

  Future<void> duplicate(CommandMacro macro) => save(
    macro.copyWith(
      id: CommandMacro.newId(),
      name:
          '${macro.name.length > 90 ? macro.name.substring(0, 90) : macro.name} (bản sao)',
    ),
  );

  Future<void> delete(String id) =>
      _update((current) => current.where((macro) => macro.id != id).toList());

  /// Imported recipes get fresh IDs so they never overwrite existing recipes.
  Future<int> importJson(String raw) async {
    final incoming = CommandMacro.decodeLibrary(raw);
    await _update(
      (current) => [
        ...current,
        for (final macro in incoming) macro.copyWith(id: CommandMacro.newId()),
      ],
    );
    return incoming.length;
  }

  Future<String> exportJson() async => CommandMacro.encodeLibrary(await future);
}

final automationLibraryProvider =
    AsyncNotifierProvider<AutomationLibraryController, List<CommandMacro>>(
      AutomationLibraryController.new,
    );

class MacroTargetSnapshot {
  final String activeKey;
  final bool broadcast;
  final Set<String> sessionIds;
  final String label;

  MacroTargetSnapshot._(
    this.activeKey,
    this.broadcast,
    this.sessionIds,
    this.label,
  );

  static MacroTargetSnapshot? capture(WorkspaceState workspace) {
    final active = workspace.activeTab;
    if (active == null ||
        active.isRemoteDesktop ||
        active.closed ||
        active.sessionId == null) {
      return null;
    }
    final targets = workspace.broadcastMode
        ? workspace.broadcastTargets.map((tab) => tab.sessionId!).toSet()
        : {active.sessionId!};
    if (targets.isEmpty) return null;
    return MacroTargetSnapshot._(
      active.localKey,
      workspace.broadcastMode,
      Set.unmodifiable(targets),
      workspace.broadcastMode
          ? 'Broadcast (${targets.length} phiên)'
          : active.title,
    );
  }

  bool matches(WorkspaceState workspace) {
    final next = capture(workspace);
    return next != null &&
        next.activeKey == activeKey &&
        next.broadcast == broadcast &&
        next.sessionIds.length == sessionIds.length &&
        sessionIds.containsAll(next.sessionIds);
  }
}

class MacroRunState {
  final bool running;
  final bool cancelRequested;
  final String? macroId;
  final int completedSteps;
  final int totalSteps;
  final String message;

  const MacroRunState({
    this.running = false,
    this.cancelRequested = false,
    this.macroId,
    this.completedSteps = 0,
    this.totalSteps = 0,
    this.message = 'Chọn macro và phiên đang kết nối để chạy.',
  });
}

class AutomationRunnerController extends Notifier<MacroRunState> {
  Object? _token;
  MacroTargetSnapshot? _target;
  String? _vaultPath;
  Completer<void>? _delay;
  Timer? _timer;

  @override
  MacroRunState build() {
    ref.listen(vaultProvider, (_, vault) {
      if (state.running &&
          (!vault.unlocked || vault.loading || vault.dbPath != _vaultPath)) {
        cancel('Đã dừng: Vault bị khóa hoặc thay đổi.');
      }
    });
    ref.listen(sessionManagerProvider, (_, workspace) {
      if (state.running && _target?.matches(workspace) != true) {
        cancel('Đã dừng: phiên hoặc danh sách broadcast đã thay đổi.');
      }
    });
    ref.listen(backendProvider, (_, _) {
      if (state.running) cancel('Đã dừng: backend đã thay đổi.');
    });
    ref.onDispose(() {
      _token = null;
      _timer?.cancel();
      if (_delay case final delay? when !delay.isCompleted) delay.complete();
    });
    return const MacroRunState();
  }

  void cancel([
    String reason = 'Đã dừng macro; các lệnh đã gửi không được hoàn tác.',
  ]) {
    if (!ref.mounted || !state.running) return;
    state = MacroRunState(
      running: true,
      cancelRequested: true,
      macroId: state.macroId,
      completedSteps: state.completedSteps,
      totalSteps: state.totalSteps,
      message: reason,
    );
    _timer?.cancel();
    if (_delay case final delay? when !delay.isCompleted) delay.complete();
  }

  Future<bool> run(
    CommandMacro macro, {
    required Future<bool> Function(String command) sendGuarded,
  }) async {
    if (state.running) return false;
    macro.validate();
    final vault = ref.read(vaultProvider);
    final target = MacroTargetSnapshot.capture(
      ref.read(sessionManagerProvider),
    );
    if (!vault.unlocked || vault.loading || target == null) {
      state = const MacroRunState(
        message: 'Mở khóa Vault và kết nối một phiên trước khi chạy.',
      );
      return false;
    }
    final token = Object();
    _token = token;
    _target = target;
    _vaultPath = vault.dbPath;
    var completed = 0;
    var message = 'Đã gửi xong ${macro.steps.length} bước tới ${target.label}.';
    var success = false;
    bool live() => ref.mounted && identical(_token, token);
    bool allowed() =>
        live() &&
        !state.cancelRequested &&
        target.matches(ref.read(sessionManagerProvider)) &&
        ref.read(vaultProvider).unlocked &&
        !ref.read(vaultProvider).loading;

    state = MacroRunState(
      running: true,
      macroId: macro.id,
      totalSteps: macro.steps.length,
      message: 'Chuẩn bị gửi tới ${target.label}.',
    );
    try {
      for (var index = 0; index < macro.steps.length; index++) {
        if (!allowed()) return false;
        final step = macro.steps[index];
        state = MacroRunState(
          running: true,
          macroId: macro.id,
          completedSteps: completed,
          totalSteps: macro.steps.length,
          message:
              'Bước ${index + 1}/${macro.steps.length}: xác minh và gửi lệnh.',
        );
        final sent = await sendGuarded(step.command);
        if (!live()) return false;
        if (sent) completed++;
        if (state.cancelRequested) return false;
        if (!sent) {
          message =
              'Đã dừng ở bước ${index + 1}: hủy xác nhận hoặc không gửi được lệnh.';
          return false;
        }
        if (!allowed()) {
          message = 'Đã dừng: phiên nhận lệnh đã thay đổi.';
          return false;
        }
        if (step.delayAfterMs > 0) {
          state = MacroRunState(
            running: true,
            macroId: macro.id,
            completedSteps: completed,
            totalSteps: macro.steps.length,
            message: 'Đã gửi bước ${index + 1}; chờ ${step.delayAfterMs} ms.',
          );
          final delay = Completer<void>();
          _delay = delay;
          _timer = Timer(
            Duration(milliseconds: step.delayAfterMs),
            delay.complete,
          );
          await delay.future;
          _delay = null;
          _timer = null;
          if (!allowed()) return false;
        }
      }
      success = true;
      return true;
    } catch (error) {
      message = 'Macro dừng do lỗi: $error';
      return false;
    } finally {
      if (live()) {
        final cancelled = state.cancelRequested;
        state = MacroRunState(
          macroId: macro.id,
          completedSteps: completed,
          totalSteps: macro.steps.length,
          message: cancelled ? state.message : message,
        );
        _token = null;
        _target = null;
        _vaultPath = null;
      }
      if (!success) _timer?.cancel();
    }
  }
}

final automationRunnerProvider =
    NotifierProvider<AutomationRunnerController, MacroRunState>(
      AutomationRunnerController.new,
    );
