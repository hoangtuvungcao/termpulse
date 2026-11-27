import 'package:termpulse/src/rust/api/dto.dart';

enum ConnectionLibrarySort { name, recent }

/// A safe presentation tree: broken imports never hide a connection or loop.
class ConnectionLibraryTree {
  final List<GroupDto> groups;
  final List<HostDto> hosts;
  late final Map<String, GroupDto> groupsById = {
    for (final group in groups) group.id: group,
  };
  late final Map<String, String?> parents = {
    for (final group in groups) group.id: _safeParent(group),
  };

  ConnectionLibraryTree({required this.groups, required this.hosts});

  String? _safeParent(GroupDto group) {
    final visited = <String>{group.id};
    var parent = group.parentId;
    while (parent != null) {
      if (!visited.add(parent) || !groupsById.containsKey(parent)) return null;
      parent = groupsById[parent]!.parentId;
    }
    return group.parentId;
  }

  List<GroupDto> childrenOf(String? parentId) {
    final children = groups.where((g) => parents[g.id] == parentId).toList();
    children.sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      return byOrder != 0 ? byOrder : _compareNames(a.name, b.name, a.id, b.id);
    });
    return children;
  }

  List<HostDto> hostsIn(String? groupId, List<HostDto> source) => source
      .where(
        (host) =>
            (groupsById.containsKey(host.groupId) ? host.groupId : null) ==
            groupId,
      )
      .toList();

  bool isDescendant(String candidateId, String ancestorId) {
    final visited = <String>{};
    String? current = candidateId;
    while (current != null && visited.add(current)) {
      if (current == ancestorId) return true;
      current = groupsById[current]?.parentId;
    }
    return false;
  }

  String groupPath(String? id) {
    final parts = <String>[];
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      final group = groupsById[id];
      if (group == null) break;
      parts.insert(0, group.name);
      id = parents[id];
    }
    return parts.join(' / ');
  }

  int descendantHostCount(String groupId, List<HostDto> source) => source
      .where(
        (host) => host.groupId != null && isDescendant(host.groupId!, groupId),
      )
      .length;

  List<HostDto> filter({
    String query = '',
    String? protocol,
    String? environment,
    bool favoritesOnly = false,
    ConnectionLibrarySort sort = ConnectionLibrarySort.name,
  }) {
    final q = query.trim().toLowerCase();
    final result = hosts.where((host) {
      if (protocol != null && host.protocol != protocol) return false;
      if (environment != null && host.envTag != environment) return false;
      if (favoritesOnly && !host.isFavorite) return false;
      if (q.isEmpty) return true;
      return [
        host.label,
        host.hostname,
        host.envTag,
        ...host.tags,
        groupPath(host.groupId),
      ].any((text) => text.toLowerCase().contains(q));
    }).toList();
    result.sort((a, b) {
      if (sort == ConnectionLibrarySort.recent) {
        final recent = (b.lastConnectedAt?.toInt() ?? 0).compareTo(
          a.lastConnectedAt?.toInt() ?? 0,
        );
        if (recent != 0) return recent;
      }
      return _compareNames(a.label, b.label, a.id, b.id);
    });
    return result;
  }
}

int _compareNames(String a, String b, String aId, String bId) {
  final compared = a.toLowerCase().compareTo(b.toLowerCase());
  return compared != 0 ? compared : aId.compareTo(bId);
}

HostDto connectionHostWithFavorite(HostDto host, bool isFavorite) => HostDto(
  id: host.id,
  groupId: host.groupId,
  label: host.label,
  protocol: host.protocol,
  hostname: host.hostname,
  port: host.port,
  identityMode: host.identityMode,
  identityId: host.identityId,
  identityNameRef: host.identityNameRef,
  jumpHostMode: host.jumpHostMode,
  jumpHostId: host.jumpHostId,
  proxyMode: host.proxyMode,
  proxyId: host.proxyId,
  colorHex: host.colorHex,
  icon: host.icon,
  envTag: host.envTag,
  tags: List.of(host.tags),
  notes: host.notes,
  startupDir: host.startupDir,
  startupCmd: host.startupCmd,
  env: List.of(host.env),
  followTerminalSftp: host.followTerminalSftp,
  remoteDesktopJson: host.remoteDesktopJson,
  wolMac: host.wolMac,
  wolBroadcast: host.wolBroadcast,
  serialBaudrate: host.serialBaudrate,
  serialDataBits: host.serialDataBits,
  serialParity: host.serialParity,
  serialStopBits: host.serialStopBits,
  serialFlowControl: host.serialFlowControl,
  isFavorite: isFavorite,
  lastConnectedAt: host.lastConnectedAt,
);
