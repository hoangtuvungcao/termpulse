import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/features/hosts/connection_library_model.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';

final connectionLibraryActionsProvider = Provider(ConnectionLibraryActions.new);

/// Re-read mutable records before changing one field to preserve newer edits.
class ConnectionLibraryActions {
  final Ref _ref;
  ConnectionLibraryActions(this._ref);

  Future<void> setFavorite(String hostId, bool favorite) async {
    final backend = _ref.read(backendProvider);
    final hosts = await backend.listHosts();
    final current = hosts.where((host) => host.id == hostId).firstOrNull;
    if (current == null) throw StateError('Kết nối này không còn tồn tại.');
    if (current.isFavorite == favorite) return;
    await backend.upsertHost(connectionHostWithFavorite(current, favorite));
    if (_ref.mounted) {
      await _ref.read(inventoryProvider.notifier).refreshAll();
    }
  }

  Future<void> saveGroup({
    String? id,
    required String name,
    String? parentId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Nhập tên nhóm.');
    final backend = _ref.read(backendProvider);
    final groups = await backend.listGroups();
    final current = groups.where((group) => group.id == id).firstOrNull;
    if (id != null && current == null) {
      throw StateError('Nhóm này không còn tồn tại.');
    }
    final tree = ConnectionLibraryTree(groups: groups, hosts: const []);
    if (parentId != null &&
        (!tree.groupsById.containsKey(parentId) ||
            (id != null && tree.isDescendant(parentId, id)))) {
      throw StateError('Nhóm cha không hợp lệ hoặc tạo vòng lặp.');
    }
    // Refuse attaching to an already broken imported hierarchy as well.
    final seen = <String>{};
    var ancestor = parentId;
    while (ancestor != null) {
      if (!seen.add(ancestor) || !tree.groupsById.containsKey(ancestor)) {
        throw StateError('Sửa cấu trúc nhóm cha trước khi thêm nhóm con.');
      }
      ancestor = tree.groupsById[ancestor]!.parentId;
    }
    await backend.upsertGroup(
      GroupDto(
        id: id ?? 'group_${DateTime.now().microsecondsSinceEpoch}',
        parentId: parentId,
        name: trimmed,
        colorHex: current?.colorHex,
        icon: current?.icon,
        defaultIdentityId: current?.defaultIdentityId,
        defaultJumpHostId: current?.defaultJumpHostId,
        defaultProxyId: current?.defaultProxyId,
        defaultTheme: current?.defaultTheme,
        env: current?.env ?? const [],
        sortOrder: current?.sortOrder ?? groups.length,
      ),
    );
    if (_ref.mounted) {
      await _ref.read(inventoryProvider.notifier).refreshAll();
    }
  }

  Future<void> deleteEmptyGroup(String id) async {
    final backend = _ref.read(backendProvider);
    final groups = await backend.listGroups();
    final hosts = await backend.listHosts();
    if (groups.any((group) => group.parentId == id) ||
        hosts.any((host) => host.groupId == id)) {
      throw StateError(
        'Chỉ xoá nhóm trống. Hãy chuyển kết nối và nhóm con trước.',
      );
    }
    await backend.deleteGroup(id);
    if (_ref.mounted) {
      await _ref.read(inventoryProvider.notifier).refreshAll();
    }
  }
}
