import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/session_log_store.dart';

final sessionLogStoreProvider = Provider<SessionLogStore>((ref) {
  return SessionLogStore(
    directory: () async => Directory(
      '${await ForegroundBridge.getAppDataDir()}${Platform.pathSeparator}session_logs',
    ),
  );
});

class SessionLogsState {
  const SessionLogsState({
    this.entries = const [],
    this.loading = false,
    this.error,
  });
  final List<SessionLogEntry> entries;
  final bool loading;
  final String? error;
  SessionLogEntry? activeFor(String key) => entries
      .where((entry) => entry.sessionKey == key && entry.active)
      .firstOrNull;
}

class SessionLogsController extends Notifier<SessionLogsState> {
  static const maxLogBytes = 20 * 1024 * 1024;
  late SessionLogStore _store;
  bool _loaded = false;
  Future<void> _operations = Future.value();

  @override
  SessionLogsState build() {
    _store = ref.read(sessionLogStoreProvider);
    _store.onWriteError = (id, error) {
      if (!ref.mounted) return;
      _update(id, endedAt: DateTime.now(), error: 'Lỗi ghi log: $error');
      unawaited(_store.stop(id).catchError((Object _) {}));
    };
    ref.onDispose(() {
      _store.onWriteError = null;
      unawaited(_store.closeAll());
    });
    return const SessionLogsState();
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> load() => _exclusive(_load);

  Future<void> _load() async {
    if (_loaded || !ref.mounted) return;
    state = SessionLogsState(entries: state.entries, loading: true);
    try {
      final entries = await _store.load();
      if (!ref.mounted) return;
      _loaded = true;
      state = SessionLogsState(entries: entries);
    } catch (error) {
      if (ref.mounted) {
        state = SessionLogsState(entries: state.entries, error: '$error');
      }
    }
  }

  Future<bool> start({
    required String sessionKey,
    required String title,
    required String protocol,
  }) => _exclusive(() async {
    await _load();
    if (!ref.mounted || !_loaded) return false;
    if (state.activeFor(sessionKey) != null) return true;
    if (state.entries.length >= 500) {
      state = SessionLogsState(
        entries: state.entries,
        error: 'Đã có 500 log. Xóa log cũ trước khi ghi thêm.',
      );
      return false;
    }
    SessionLogEntry? created;
    try {
      created = await _store.create(
        sessionKey: sessionKey,
        title: title,
        protocol: protocol,
      );
      if (!ref.mounted) {
        await _store.stop(created.id);
        return false;
      }
      state = SessionLogsState(entries: [created, ...state.entries]);
      await _store.saveIndex(state.entries);
      return true;
    } catch (error) {
      if (created != null) {
        try {
          await _store.stop(created.id);
        } catch (_) {}
        if (ref.mounted) {
          _update(created.id, endedAt: DateTime.now(), error: '$error');
        }
      }
      if (ref.mounted) {
        state = SessionLogsState(
          entries: state.entries,
          error: 'Không bắt đầu ghi log: $error',
        );
      }
      return false;
    }
  });

  void append(String sessionKey, List<int> bytes) {
    if (!ref.mounted || bytes.isEmpty) return;
    final entry = state.activeFor(sessionKey);
    if (entry == null) return;
    if (entry.bytes + bytes.length > maxLogBytes) {
      _update(
        entry.id,
        endedAt: DateTime.now(),
        error: 'Đã dừng ở giới hạn 20 MiB mỗi log.',
      );
      unawaited(
        _exclusive(() async {
          try {
            await _store.stop(entry.id);
            await _store.saveIndex(state.entries);
          } catch (error) {
            if (ref.mounted) _update(entry.id, error: '$error');
          }
        }),
      );
      return;
    }
    try {
      _store.append(entry.id, bytes);
      _update(entry.id, bytes: entry.bytes + bytes.length);
    } catch (error) {
      _update(entry.id, endedAt: DateTime.now(), error: 'Lỗi ghi log: $error');
      unawaited(stopSession(sessionKey));
    }
  }

  void _update(String id, {int? bytes, DateTime? endedAt, String? error}) {
    if (!ref.mounted) return;
    state = SessionLogsState(
      entries: [
        for (final entry in state.entries)
          entry.id == id
              ? entry.update(bytes: bytes, endedAt: endedAt, error: error)
              : entry,
      ],
      error: error ?? state.error,
    );
  }

  Future<void> stopSession(String sessionKey) => _exclusive(() async {
    // Find the latest entry even if an I/O failure already marked it stopped.
    final entry = state.entries
        .where((entry) => entry.sessionKey == sessionKey)
        .firstOrNull;
    if (entry == null) return;
    try {
      await _store.stop(entry.id);
    } catch (error) {
      if (ref.mounted) _update(entry.id, error: 'Lỗi đóng log: $error');
    }
    if (!ref.mounted) return;
    _update(entry.id, endedAt: entry.endedAt ?? DateTime.now());
    try {
      await _store.saveIndex(state.entries);
    } catch (error) {
      if (ref.mounted) {
        _update(entry.id, error: 'Không lưu danh mục log: $error');
      }
    }
  });

  Future<void> stopAll() async {
    await _operations;
    for (final entry in state.entries.where((entry) => entry.active).toList()) {
      await stopSession(entry.sessionKey);
    }
  }

  Future<void> delete(String id) => _exclusive(() async {
    final entry = state.entries.where((entry) => entry.id == id).firstOrNull;
    if (entry == null) return;
    if (entry.active) throw StateError('Dừng ghi trước khi xóa log.');
    await _store.delete(id);
    if (!ref.mounted) return;
    state = SessionLogsState(
      entries: state.entries.where((entry) => entry.id != id).toList(),
    );
    await _store.saveIndex(state.entries);
  });
}

final sessionLogsProvider =
    NotifierProvider<SessionLogsController, SessionLogsState>(
      SessionLogsController.new,
    );
