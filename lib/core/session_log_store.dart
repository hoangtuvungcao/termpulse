import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SessionLogEntry {
  const SessionLogEntry({
    required this.id,
    required this.sessionKey,
    required this.title,
    required this.protocol,
    required this.startedAt,
    this.endedAt,
    this.bytes = 0,
    this.error,
  });

  final String id;
  final String sessionKey;
  final String title;
  final String protocol;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int bytes;
  final String? error;
  bool get active => endedAt == null;

  SessionLogEntry update({int? bytes, DateTime? endedAt, String? error}) =>
      SessionLogEntry(
        id: id,
        sessionKey: sessionKey,
        title: title,
        protocol: protocol,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        bytes: bytes ?? this.bytes,
        error: error ?? this.error,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionKey': sessionKey,
    'title': title,
    'protocol': protocol,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'bytes': bytes,
    'error': error,
  };

  factory SessionLogEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || !RegExp(r'^log_[0-9]+_[0-9]+$').hasMatch(id)) {
      throw const FormatException('Mã tệp log không hợp lệ.');
    }
    final bytes = json['bytes'];
    if (bytes is! int || bytes < 0) {
      throw const FormatException('Kích thước log không hợp lệ.');
    }
    return SessionLogEntry(
      id: id,
      sessionKey: json['sessionKey'] as String,
      title: json['title'] as String,
      protocol: json['protocol'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.parse(json['endedAt'] as String),
      bytes: bytes,
      error: json['error'] as String?,
    );
  }
}

/// Opt-in, received terminal bytes only. Logs are plaintext, outside the Vault.
class SessionLogStore {
  SessionLogStore({required this.directory});
  final Future<Directory> Function() directory;
  final Map<String, IOSink> _writers = {};
  Future<void> _indexWrites = Future.value();
  void Function(String id, Object error)? onWriteError;
  int _sequence = 0;

  Future<File> fileFor(String id) async {
    if (!RegExp(r'^log_[0-9]+_[0-9]+$').hasMatch(id)) {
      throw const FormatException('Mã tệp log không hợp lệ.');
    }
    final root = await directory();
    return File('${root.path}${Platform.pathSeparator}$id.log');
  }

  Future<List<SessionLogEntry>> load() async {
    final root = await directory();
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    if (!await index.exists()) return [];
    if (await index.length() > 2 * 1024 * 1024) {
      throw const FormatException('Danh mục log vượt giới hạn 2 MiB.');
    }
    final data = jsonDecode(await index.readAsString());
    if (data is! Map || data['version'] != 1 || data['logs'] is! List) {
      throw const FormatException('Danh mục log không đúng định dạng.');
    }
    final values = data['logs'] as List;
    if (values.length > 500) {
      throw const FormatException('Danh mục log vượt giới hạn 500 phiên.');
    }
    return values.map((value) {
      final entry = SessionLogEntry.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      return entry.active
          ? entry.update(
              endedAt: DateTime.now(),
              error: 'Lượt ghi trước đã kết thúc khi ứng dụng đóng.',
            )
          : entry;
    }).toList();
  }

  Future<void> saveIndex(List<SessionLogEntry> entries) {
    final content = jsonEncode({
      'version': 1,
      'logs': entries.map((entry) => entry.toJson()).toList(),
    });
    final next = _indexWrites.then((_) async {
      final root = await directory();
      await root.create(recursive: true);
      final target = File('${root.path}${Platform.pathSeparator}index.json');
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(target.path);
    });
    _indexWrites = next.catchError((Object _) {});
    return next;
  }

  Future<SessionLogEntry> create({
    required String sessionKey,
    required String title,
    required String protocol,
  }) async {
    final now = DateTime.now();
    final id = 'log_${now.microsecondsSinceEpoch}_${_sequence++}';
    final file = await fileFor(id);
    await file.parent.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    unawaited(
      sink.done.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) =>
            onWriteError?.call(id, error),
      ),
    );
    try {
      sink.writeln(
        '# TermPulse · $protocol · ${now.toUtc().toIso8601String()}',
      );
      sink.writeln('# ${title.replaceAll(RegExp(r'[\r\n\x1b]'), ' ')}');
      await sink.flush();
      _writers[id] = sink;
      return SessionLogEntry(
        id: id,
        sessionKey: sessionKey,
        title: title,
        protocol: protocol,
        startedAt: now,
      );
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  void append(String id, List<int> bytes) => _writers[id]?.add(bytes);

  Future<void> stop(String id) async {
    final sink = _writers.remove(id);
    if (sink == null) return;
    try {
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<void> closeAll() async {
    for (final id in _writers.keys.toList()) {
      try {
        await stop(id);
      } catch (_) {}
    }
    await _indexWrites;
  }

  Future<String> preview(String id, {int limit = 512 * 1024}) async {
    await _writers[id]?.flush();
    final file = await fileFor(id);
    final input = await file.open();
    try {
      final data = await input.read(limit);
      var text = utf8.decode(data, allowMalformed: true);
      // Render text, never terminal escape sequences or OSC hyperlinks.
      text = text
          .replaceAll(RegExp(r'\x1b\][^\x07]*(?:\x07|\x1b\\)'), '')
          .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
          .replaceAll(RegExp(r'[\x00-\x08\x0b-\x0d\x0e-\x1f\x7f]'), '');
      if (await file.length() > limit) {
        text += '\n\n[Chỉ xem trước 512 KiB đầu. Xuất log để đọc toàn bộ.]';
      }
      return text;
    } finally {
      await input.close();
    }
  }

  Future<void> export(String id, String destination) async {
    final target = File(destination);
    if (!target.isAbsolute) throw ArgumentError('Cần đường dẫn tuyệt đối.');
    final source = await fileFor(id);
    if (source.absolute.path == target.absolute.path) return;
    await _writers[id]?.flush();
    await source.copy(target.path);
  }

  Future<void> delete(String id) async {
    if (_writers.containsKey(id)) throw StateError('Dừng ghi trước khi xóa.');
    final file = await fileFor(id);
    if (await file.exists()) await file.delete();
  }
}
