import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/connection_library.dart';
import 'package:termpulse/features/hosts/connection_library_actions.dart';
import 'package:termpulse/features/hosts/connection_library_model.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';

import 'widget_test.dart' show FakeCoreBackend;

HostDto _host(
  String id, {
  String? groupId,
  String? label,
  String protocol = 'ssh',
  String environment = 'dev',
  bool favorite = false,
  int? recent,
}) => HostDto(
  id: id,
  groupId: groupId,
  label: label ?? id,
  protocol: protocol,
  hostname: '$id.example.test',
  port: 22,
  identityMode: 'inherit',
  jumpHostMode: 'inherit',
  proxyMode: 'inherit',
  envTag: environment,
  tags: const ['team-platform'],
  notes: '',
  env: const [],
  isFavorite: favorite,
  lastConnectedAt: recent,
);

GroupDto _group(String id, {String? parentId, String? name}) => GroupDto(
  id: id,
  parentId: parentId,
  name: name ?? id,
  env: const [],
  sortOrder: 0,
);

class _LibraryBackend extends FakeCoreBackend {
  final groups = <GroupDto>[];
  final deletedHosts = <String>[];
  final deletedGroups = <String>[];
  int groupWrites = 0;
  Object? groupError;
  Object? hostError;

  _LibraryBackend() {
    hosts.clear();
  }

  @override
  Future<List<GroupDto>> listGroups() async => List.of(groups);

  @override
  Future<void> upsertGroup(GroupDto group) async {
    if (groupError case final error?) throw error;
    groupWrites++;
    groups.removeWhere((existing) => existing.id == group.id);
    groups.add(group);
  }

  @override
  Future<void> deleteGroup(String id) async {
    deletedGroups.add(id);
    groups.removeWhere((group) => group.id == id);
  }

  @override
  Future<void> upsertHost(HostDto host) async {
    if (hostError case final error?) throw error;
    hosts.removeWhere((existing) => existing.id == host.id);
    hosts.add(host);
  }

  @override
  Future<void> deleteHost(String id) async {
    deletedHosts.add(id);
    hosts.removeWhere((host) => host.id == id);
  }
}

ProviderContainer _container(_LibraryBackend backend) {
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpLibrary(
  WidgetTester tester,
  _LibraryBackend backend, {
  Size size = const Size(244, 640),
}) async {
  tester.view.physicalSize = Size(900, size.height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = _container(backend);
  await container.read(inventoryProvider.notifier).refreshAll();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseDarkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: const ConnectionLibrary(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _menu(WidgetTester tester, Key key, String text) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'filters compose and search group paths, tags and connection fields',
    () {
      final tree = ConnectionLibraryTree(
        groups: [
          _group('platform', name: 'Platform'),
          _group('edge', parentId: 'platform'),
        ],
        hosts: [
          _host('alpha', groupId: 'edge', favorite: true, environment: 'prod'),
          _host('beta', protocol: 'telnet', environment: 'prod'),
          _host('gamma'),
        ],
      );
      expect(tree.filter(query: 'platform').map((h) => h.id), [
        'alpha',
        'beta',
        'gamma',
      ]);
      expect(tree.filter(query: 'Platform / edge').map((h) => h.id), ['alpha']);
      expect(
        tree
            .filter(protocol: 'ssh', environment: 'prod', favoritesOnly: true)
            .map((h) => h.id),
        ['alpha'],
      );
      expect(tree.filter(query: 'no match'), isEmpty);
    },
  );

  test(
    'name and recent ordering are deterministic with never-connected hosts',
    () {
      final tree = ConnectionLibraryTree(
        groups: const [],
        hosts: [
          _host('z', label: 'Zulu', recent: 30),
          _host('a2', label: 'alpha'),
          _host('b', label: 'Beta', recent: 50),
          _host('a1', label: 'Alpha'),
        ],
      );
      expect(tree.filter().map((h) => h.id), ['a1', 'a2', 'b', 'z']);
      expect(tree.filter(sort: ConnectionLibrarySort.recent).map((h) => h.id), [
        'b',
        'z',
        'a1',
        'a2',
      ]);
    },
  );

  test(
    'cycles and missing parent groups remain reachable without recursion',
    () {
      final tree = ConnectionLibraryTree(
        groups: [
          _group('a', parentId: 'b'),
          _group('b', parentId: 'a'),
          _group('orphan', parentId: 'missing'),
        ],
        hosts: [
          _host('unassigned', groupId: 'missing'),
          _host('saved', groupId: 'a'),
        ],
      );
      expect(tree.childrenOf(null).map((g) => g.id), ['a', 'b', 'orphan']);
      expect(tree.hostsIn(null, tree.hosts).single.id, 'unassigned');
      expect(tree.hostsIn('a', tree.hosts).single.id, 'saved');
      expect(tree.groupPath('a'), 'a');
    },
  );

  test(
    'favorite persistence reads latest record and preserves optional settings',
    () async {
      final backend = _LibraryBackend()..hosts.add(_host('saved'));
      final container = _container(backend);
      await container.read(inventoryProvider.notifier).refreshAll();
      final latest = HostDto(
        id: 'saved',
        groupId: 'g',
        label: 'Changed elsewhere',
        protocol: 'serial',
        hostname: '/dev/ttyUSB0',
        port: 0,
        identityMode: 'by_name',
        identityId: 'identity',
        identityNameRef: 'ops',
        jumpHostMode: 'none',
        jumpHostId: 'jump',
        proxyMode: 'direct',
        proxyId: 'proxy',
        colorHex: '#123456',
        icon: 'terminal',
        envTag: 'prod',
        tags: const ['console'],
        notes: 'keep',
        startupDir: '/work',
        startupCmd: 'pwd',
        env: const [KeyValueDto(key: 'SAFE', value: '1')],
        followTerminalSftp: false,
        remoteDesktopJson: '{"width":1600,"height":900,"domain":"LAB"}',
        wolMac: '00:11:22:33:44:55',
        wolBroadcast: '10.0.0.255',
        serialBaudrate: 9600,
        serialDataBits: 7,
        serialParity: 'even',
        serialStopBits: 2,
        serialFlowControl: 'hardware',
        isFavorite: false,
        lastConnectedAt: 1234,
      );
      backend.hosts[0] = latest;
      await container
          .read(connectionLibraryActionsProvider)
          .setFavorite('saved', true);
      final saved = backend.hosts.single;
      expect(saved.isFavorite, isTrue);
      expect(saved.label, 'Changed elsewhere');
      expect(saved.groupId, latest.groupId);
      expect(saved.identityNameRef, latest.identityNameRef);
      expect(saved.identityId, latest.identityId);
      expect(saved.proxyId, latest.proxyId);
      expect(saved.jumpHostId, latest.jumpHostId);
      expect(saved.startupCmd, latest.startupCmd);
      expect(saved.env, latest.env);
      expect(saved.followTerminalSftp, isFalse);
      expect(saved.remoteDesktopJson, latest.remoteDesktopJson);
      expect(saved.wolMac, latest.wolMac);
      expect(saved.serialBaudrate, latest.serialBaudrate);
      expect(saved.serialDataBits, latest.serialDataBits);
      expect(saved.serialParity, latest.serialParity);
      expect(saved.serialStopBits, latest.serialStopBits);
      expect(saved.serialFlowControl, latest.serialFlowControl);
      expect(saved.lastConnectedAt, latest.lastConnectedAt);
      expect(container.read(inventoryProvider).hosts.single.isFavorite, isTrue);
    },
  );

  test(
    'group edits preserve inherited defaults and refuse hierarchy cycles',
    () async {
      const original = GroupDto(
        id: 'parent',
        name: 'Parent',
        env: [KeyValueDto(key: 'TERM', value: 'xterm')],
        sortOrder: 7,
        colorHex: '#123456',
        icon: 'folder',
        defaultIdentityId: 'id',
        defaultJumpHostId: 'jump',
        defaultProxyId: 'proxy',
        defaultTheme: 'dark',
      );
      final backend = _LibraryBackend()
        ..groups.addAll([original, _group('child', parentId: 'parent')]);
      final actions = _container(
        backend,
      ).read(connectionLibraryActionsProvider);
      await actions.saveGroup(id: 'parent', name: ' Renamed ');
      final saved = backend.groups.firstWhere((g) => g.id == 'parent');
      expect(saved.name, 'Renamed');
      expect(saved.defaultIdentityId, original.defaultIdentityId);
      expect(saved.defaultProxyId, original.defaultProxyId);
      expect(saved.defaultJumpHostId, original.defaultJumpHostId);
      expect(saved.defaultTheme, original.defaultTheme);
      expect(saved.sortOrder, 7);
      expect(saved.env, original.env);
      await expectLater(
        actions.saveGroup(id: 'parent', name: 'Bad', parentId: 'child'),
        throwsStateError,
      );
      await expectLater(
        actions.saveGroup(id: 'parent', name: 'Bad', parentId: 'parent'),
        throwsStateError,
      );
      await expectLater(
        actions.saveGroup(name: 'Bad', parentId: 'missing'),
        throwsStateError,
      );
      expect(backend.groupWrites, 1);
    },
  );

  test(
    'empty group delete rechecks latest hosts and children before backend mutation',
    () async {
      final backend = _LibraryBackend()..groups.add(_group('group'));
      final container = _container(backend);
      await container.read(inventoryProvider.notifier).refreshAll();
      final actions = container.read(connectionLibraryActionsProvider);
      backend.groups.add(_group('child', parentId: 'group'));
      await expectLater(actions.deleteEmptyGroup('group'), throwsStateError);
      backend.groups.removeLast();
      backend.hosts.add(_host('host', groupId: 'group'));
      await expectLater(actions.deleteEmptyGroup('group'), throwsStateError);
      expect(backend.deletedGroups, isEmpty);
      backend.hosts.clear();
      await actions.deleteEmptyGroup('group');
      expect(backend.deletedGroups, ['group']);
      expect(container.read(inventoryProvider).groups, isEmpty);
    },
  );

  testWidgets(
    'library composes protocol/environment/favorite filters and resets empty results',
    (tester) async {
      final backend = _LibraryBackend()
        ..hosts.addAll([
          _host('SSH prod', environment: 'prod', favorite: true),
          _host('Telnet dev', protocol: 'telnet'),
          _host('SSH dev'),
        ]);
      await _pumpLibrary(tester, backend);
      expect(find.text('3 / 3'), findsOneWidget);
      await _menu(tester, const Key('connectionProtocolFilter'), 'SSH');
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('Telnet dev'), findsNothing);
      await _menu(tester, const Key('connectionEnvironmentFilter'), 'prod');
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('connectionFavoritesFilter')));
      await tester.pumpAndSettle();
      expect(find.text('SSH prod'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('connectionSearchField')),
        'missing',
      );
      await tester.pumpAndSettle();
      expect(find.text('Không có kết nối phù hợp.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('connectionResetFilters')));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('Telnet dev'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nested groups collapse and host favorite/duplicate/delete actions persist',
    (tester) async {
      final backend = _LibraryBackend()
        ..groups.addAll([_group('parent'), _group('child', parentId: 'parent')])
        ..hosts.add(_host('saved', groupId: 'child'));
      await _pumpLibrary(tester, backend);
      await tester.tap(find.byKey(const Key('connectionGroup:parent')));
      await tester.pumpAndSettle();
      expect(find.text('saved'), findsNothing);
      await tester.tap(find.byKey(const Key('connectionGroup:parent')));
      await tester.pumpAndSettle();
      await _menu(
        tester,
        const Key('connectionHostMenu:saved'),
        'Thêm yêu thích',
      );
      expect(backend.hosts.single.isFavorite, isTrue);
      await _menu(tester, const Key('connectionHostMenu:saved'), 'Nhân bản');
      expect(backend.hosts.map((h) => h.label), contains('saved (Copy)'));
      await _menu(tester, const Key('connectionHostMenu:saved'), 'Xoá');
      expect(backend.deletedHosts, isEmpty);
      await tester.tap(find.text('Huỷ').last);
      await tester.pumpAndSettle();
      expect(backend.deletedHosts, isEmpty);
      await _menu(tester, const Key('connectionHostMenu:saved'), 'Xoá');
      await tester.tap(find.byKey(const Key('connectionDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(backend.deletedHosts, ['saved']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'group create, rename, validation retry and delete use real inventory mutations',
    (tester) async {
      final backend = _LibraryBackend();
      await _pumpLibrary(tester, backend);
      await _menu(tester, const Key('connectionLibraryMenu'), 'Tạo nhóm mới');
      await tester.tap(find.byKey(const Key('connectionGroupSave')));
      await tester.pumpAndSettle();
      expect(find.text('Nhập tên nhóm.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('connectionGroupName')),
        'Operations',
      );
      backend.groupError = StateError('temporary error');
      await tester.tap(find.byKey(const Key('connectionGroupSave')));
      await tester.pumpAndSettle();
      expect(find.textContaining('temporary error'), findsNothing);
      final details = find.byKey(const Key('noticeDetailsButton'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('Bad state: temporary error'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Đóng'));
      await tester.pumpAndSettle();
      backend.groupError = null;
      await tester.tap(find.byKey(const Key('connectionGroupSave')));
      await tester.pumpAndSettle();
      expect(backend.groups.single.name, 'Operations');
      final id = backend.groups.single.id;
      await _menu(tester, Key('connectionGroupMenu:$id'), 'Sửa tên / nhóm cha');
      await tester.enterText(
        find.byKey(const Key('connectionGroupName')),
        'Production',
      );
      await tester.tap(find.byKey(const Key('connectionGroupSave')));
      await tester.pumpAndSettle();
      expect(backend.groups.single.name, 'Production');
      await _menu(tester, Key('connectionGroupMenu:$id'), 'Xoá nhóm trống');
      expect(backend.deletedGroups, isEmpty);
      await tester.tap(find.byKey(const Key('connectionDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(backend.deletedGroups, [id]);
      expect(find.text('Production'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library action errors keep diagnostics behind Details', (
    tester,
  ) async {
    final backend = _LibraryBackend()
      ..hosts.add(_host('saved'))
      ..hostError = StateError('Connection storage failed internally');
    await _pumpLibrary(tester, backend);
    await _menu(
      tester,
      const Key('connectionHostMenu:saved'),
      'Thêm yêu thích',
    );
    expect(
      find.textContaining('Connection storage failed internally'),
      findsNothing,
    );
    expect(find.text('Xem chi tiết'), findsOneWidget);
    await tester.tap(find.text('Xem chi tiết'));
    await tester.pumpAndSettle();
    expect(
      find.text('Bad state: Connection storage failed internally'),
      findsOneWidget,
    );
    expect(backend.hosts.single.isFavorite, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library fits minimum sidebar width and short windows', (
    tester,
  ) async {
    final backend = _LibraryBackend()..hosts.add(_host('saved'));
    await _pumpLibrary(tester, backend, size: const Size(220, 225));
    expect(
      find.byKey(const Key('desktopAddHostBtn')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktopSerialConnectBtn')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('connectionHost:saved')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
