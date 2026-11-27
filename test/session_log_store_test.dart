import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/session_log_store.dart';

void main() {
  late Directory root;
  late SessionLogStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('termpulse-session-logs-');
    store = SessionLogStore(directory: () async => root);
  });

  tearDown(() async {
    await store.closeAll();
    await root.delete(recursive: true);
  });

  test('persists opt-in output and exports a complete log', () async {
    final entry = await store.create(
      sessionKey: 'session-a',
      title: 'edge-prod',
      protocol: 'ssh',
    );
    store.append(entry.id, 'hello\r\n'.codeUnits);
    await store.stop(entry.id);

    final stopped = entry.update(bytes: 7, endedAt: DateTime.now());
    await store.saveIndex([stopped]);
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.active, isFalse);
    expect(loaded.single.title, 'edge-prod');

    final preview = await store.preview(entry.id);
    expect(preview, contains('hello'));
    expect(preview, isNot(contains('\r')));

    final destination = File(
      '${root.path}${Platform.pathSeparator}exported.log',
    );
    await store.export(entry.id, destination.path);
    expect(await destination.readAsString(), contains('hello'));
  });

  test(
    'recovery marks unfinished recording stopped and previews strip escapes',
    () async {
      final entry = await store.create(
        sessionKey: 'session-b',
        title: 'host',
        protocol: 'ssh',
      );
      store.append(
        entry.id,
        'safe\x1b[31mred\x1b[0m\x1b]0;title\x07'.codeUnits,
      );
      await store.saveIndex([entry]);
      await store.closeAll();

      final recovered = await store.load();
      expect(recovered.single.active, isFalse);
      expect(recovered.single.error, contains('ứng dụng đóng'));
      final preview = await store.preview(entry.id);
      expect(preview, contains('safered'));
      expect(preview, isNot(contains('\x1b')));
      expect(preview, isNot(contains('title')));
    },
  );

  test('rejects unsafe log identifiers before reading files', () async {
    await expectLater(store.fileFor('../secret'), throwsFormatException);
  });
}
