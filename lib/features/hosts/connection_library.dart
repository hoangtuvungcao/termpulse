import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/connection_library_actions.dart';
import 'package:termpulse/features/hosts/connection_library_model.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/features/hosts/import_dialog.dart';
import 'package:termpulse/features/terminal/serial_connect_dialog.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

const _supportedProtocols = [
  'ssh',
  'telnet',
  'local_shell',
  'serial',
  'rdp',
  'vnc',
];

String _protocolLabel(BuildContext context, String protocol) =>
    switch (protocol) {
      'ssh' => 'SSH',
      'telnet' => 'Telnet',
      'local_shell' => context.tr('Local Shell'),
      'serial' => 'Serial',
      'rdp' => 'RDP',
      'vnc' => 'VNC',
      _ => protocol.toUpperCase(),
    };

class ConnectionLibrary extends ConsumerStatefulWidget {
  const ConnectionLibrary({super.key});

  @override
  ConsumerState<ConnectionLibrary> createState() => _ConnectionLibraryState();
}

class _ConnectionLibraryState extends ConsumerState<ConnectionLibrary> {
  late final TextEditingController _searchController;
  String? _protocol;
  String? _environment;
  bool _favoritesOnly = false;
  ConnectionLibrarySort _sort = ConnectionLibrarySort.name;
  final _collapsed = <String>{};
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(inventoryProvider).searchQuery,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _run(String id, Future<void> Function() operation) async {
    if (!_busy.add(id)) return;
    setState(() {});
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        showAppErrorSnackBar(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _resetFilters() {
    _searchController.clear();
    ref.read(inventoryProvider.notifier).setSearch('');
    setState(() {
      _protocol = null;
      _environment = null;
      _favoritesOnly = false;
      _collapsed.clear();
    });
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(ref.s.cancel),
            ),
            FilledButton(
              key: const Key('connectionDeleteConfirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(ref.s.delete),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _hostAction(HostDto host, String action) async {
    if (_busy.contains(host.id)) return;
    final inventory = ref.read(inventoryProvider.notifier);
    switch (action) {
      case 'connect':
        await _run(
          host.id,
          () => ref.read(sessionManagerProvider.notifier).openHostSession(host),
        );
      case 'edit':
        await showHostEditorDialog(context, ref, existing: host);
      case 'duplicate':
        await _run(host.id, () => inventory.cloneHost(host));
      case 'favorite':
        await _run(
          host.id,
          () => ref
              .read(connectionLibraryActionsProvider)
              .setFavorite(host.id, !host.isFavorite),
        );
      case 'delete':
        final confirmed = await _confirm(
          context.tr('Xoá kết nối?'),
          context.tr('Xoá cấu hình đã lưu “${host.label}”?'),
        );
        if (mounted && confirmed) {
          await _run(host.id, () => inventory.removeHost(host.id));
        }
    }
  }

  List<PopupMenuEntry<String>> _hostMenu(HostDto host) => [
    PopupMenuItem(
      value: 'connect',
      enabled:
          _supportedProtocols.contains(host.protocol) &&
          (host.protocol != 'serial' ||
              ref.read(backendProvider).serialSupported()),
      child: Text(ref.s.connect),
    ),
    PopupMenuItem(value: 'edit', child: Text(ref.s.edit)),
    PopupMenuItem(value: 'duplicate', child: Text(ref.s.clone)),
    PopupMenuItem(
      value: 'favorite',
      child: Text(
        host.isFavorite
            ? context.tr('Bỏ yêu thích')
            : context.tr('Thêm yêu thích'),
      ),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(value: 'delete', child: Text(ref.s.delete)),
  ];

  Future<void> _showHostContext(HostDto host, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: _hostMenu(host),
    );
    if (mounted && action != null) await _hostAction(host, action);
  }

  Future<void> _groupAction(GroupDto group, String action) async {
    if (action == 'edit' || action == 'child') {
      await showDialog<void>(
        context: context,
        builder: (_) => _ConnectionGroupDialog(
          existing: action == 'edit' ? group : null,
          initialParentId: action == 'child' ? group.id : null,
        ),
      );
    } else if (action == 'delete') {
      final confirmed = await _confirm(
        context.tr('Xoá nhóm trống?'),
        context.tr(
          'Xoá nhóm “${group.name}”? Chỉ nhóm không còn kết nối và nhóm con mới có thể xoá.',
        ),
      );
      if (mounted && confirmed) {
        await _run(
          'group:${group.id}',
          () => ref
              .read(connectionLibraryActionsProvider)
              .deleteEmptyGroup(group.id),
        );
      }
    }
  }

  Widget _smallButton({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: selected ? context.tp.accentContainer : null,
      foregroundColor: selected ? context.tp.accent : context.tp.muted,
    ),
    icon: Icon(icon, size: 17),
  );

  Widget _filterMenu({
    required String name,
    required String label,
    required IconData icon,
    required String? selected,
    required Map<String, String> options,
    required ValueChanged<String?> onChanged,
  }) => PopupMenuButton<String>(
    key: Key('connection${name}Filter'),
    tooltip: label,
    initialValue: selected ?? '\u0000all',
    onSelected: (value) {
      setState(() {
        onChanged(value == '\u0000all' ? null : value);
        _collapsed.clear();
      });
    },
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: '\u0000all',
        checked: selected == null,
        child: Text(context.tr('Tất cả $label')),
      ),
      for (final option in options.entries)
        CheckedPopupMenuItem(
          value: option.key,
          checked: selected == option.key,
          child: Text(option.value),
        ),
    ],
    child: Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: context.tp.surface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: selected == null ? context.tp.border : context.tp.accent,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 13, color: context.tp.muted),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              selected == null ? label : options[selected] ?? selected,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5),
            ),
          ),
          const Icon(Icons.expand_more_rounded, size: 13),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider);
    final workspace = ref.watch(sessionManagerProvider);
    final s = ref.s;
    final tp = context.tp;
    final tree = ConnectionLibraryTree(
      groups: inventory.groups,
      hosts: inventory.hosts,
    );
    final filtered = tree.filter(
      query: inventory.searchQuery,
      protocol: _protocol,
      environment: _environment,
      favoritesOnly: _favoritesOnly,
      sort: _sort,
    );
    final filtering =
        inventory.searchQuery.trim().isNotEmpty ||
        _protocol != null ||
        _environment != null ||
        _favoritesOnly;
    final environments =
        inventory.hosts.map((host) => host.envTag).toSet().toList()..sort();
    final protocols = {
      ..._supportedProtocols,
      ...inventory.hosts.map((h) => h.protocol),
    };
    final serialSupported = ref.read(backendProvider).serialSupported();
    final entries = <({GroupDto? group, HostDto? host, int depth})>[];
    void appendGroup(String? parent, int depth) {
      for (final group in tree.childrenOf(parent)) {
        if (filtering && tree.descendantHostCount(group.id, filtered) == 0) {
          continue;
        }
        entries.add((group: group, host: null, depth: depth));
        if (!_collapsed.contains(group.id)) appendGroup(group.id, depth + 1);
      }
      for (final host in tree.hostsIn(parent, filtered)) {
        entries.add((group: null, host: host, depth: depth));
      }
    }

    appendGroup(null, 0);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tp.surface,
        border: Border(right: BorderSide(color: tp.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      context.tr('KẾT NỐI'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .5,
                        color: tp.muted,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${filtered.length} / ${inventory.hosts.length}',
                        key: const Key('connectionLibraryCount'),
                        style: TextStyle(fontSize: 10, color: tp.muted),
                      ),
                    ),
                    _smallButton(
                      key: const Key('connectionFavoritesFilter'),
                      tooltip: context.tr('Chỉ hiện yêu thích'),
                      icon: _favoritesOnly
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      selected: _favoritesOnly,
                      onPressed: () => setState(() {
                        _favoritesOnly = !_favoritesOnly;
                        _collapsed.clear();
                      }),
                    ),
                    PopupMenuButton<ConnectionLibrarySort>(
                      key: const Key('connectionSortMenu'),
                      tooltip: context.tr('Sắp xếp kết nối'),
                      initialValue: _sort,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 170),
                      icon: const Icon(Icons.sort_rounded, size: 17),
                      iconSize: 17,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(30, 30),
                        maximumSize: const Size(30, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelected: (sort) => setState(() => _sort = sort),
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                          value: ConnectionLibrarySort.name,
                          checked: _sort == ConnectionLibrarySort.name,
                          child: Text(context.tr('Tên A–Z')),
                        ),
                        CheckedPopupMenuItem(
                          value: ConnectionLibrarySort.recent,
                          checked: _sort == ConnectionLibrarySort.recent,
                          child: Text(context.tr('Kết nối gần đây')),
                        ),
                      ],
                    ),
                    PopupMenuButton<String>(
                      key: const Key('connectionLibraryMenu'),
                      tooltip: context.tr('Quản lý thư viện'),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_horiz_rounded, size: 17),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(28, 30),
                        maximumSize: const Size(28, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelected: (action) async {
                        switch (action) {
                          case 'group':
                            await showDialog<void>(
                              context: context,
                              builder: (_) => const _ConnectionGroupDialog(),
                            );
                          case 'refresh':
                            await ref
                                .read(inventoryProvider.notifier)
                                .refreshAll();
                          case 'expand':
                            setState(() => _collapsed.clear());
                          case 'collapse':
                            setState(
                              () => _collapsed.addAll(tree.groupsById.keys),
                            );
                          case 'reset':
                            _resetFilters();
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'group',
                          child: Text(context.tr('Tạo nhóm mới')),
                        ),
                        PopupMenuItem(
                          value: 'expand',
                          child: Text(context.tr('Mở tất cả nhóm')),
                        ),
                        PopupMenuItem(
                          value: 'collapse',
                          child: Text(context.tr('Thu gọn nhóm')),
                        ),
                        PopupMenuItem(
                          value: 'refresh',
                          child: Text(context.tr('Làm mới thư viện')),
                        ),
                        PopupMenuItem(
                          value: 'reset',
                          child: Text(context.tr('Xoá bộ lọc')),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(
                  height: 35,
                  child: TextField(
                    key: const Key('connectionSearchField'),
                    controller: _searchController,
                    onChanged: (query) {
                      ref.read(inventoryProvider.notifier).setSearch(query);
                      setState(() => _collapsed.clear());
                    },
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: s.searchHostsHint,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 9,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 16),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const Key('desktopAddHostBtn'),
                          onPressed: () => showHostEditorDialog(context, ref),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: Text(
                            s.hostBtnLabel,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _smallButton(
                        tooltip: context.tr(s.localShellTooltip),
                        icon: Icons.terminal_rounded,
                        onPressed: () => ref
                            .read(sessionManagerProvider.notifier)
                            .openLocalShell(),
                      ),
                      const SizedBox(width: 3),
                      _smallButton(
                        tooltip: context.tr(s.importExportTooltip),
                        icon: Icons.file_upload_outlined,
                        onPressed: () => showImportExportDialog(context, ref),
                      ),
                      const SizedBox(width: 3),
                      _smallButton(
                        key: const Key('desktopSerialConnectBtn'),
                        tooltip: serialSupported
                            ? context.tr('Kết nối Serial')
                            : context.tr(
                                'Serial hỗ trợ Linux, Windows, macOS và USB OTG trên Android. iOS chưa hỗ trợ USB Serial.',
                              ),
                        icon: Icons.cable_rounded,
                        onPressed: serialSupported
                            ? () => showSerialConnectDialog(context, ref)
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _filterMenu(
                        name: 'Protocol',
                        label: context.tr('Giao thức'),
                        icon: Icons.lan_outlined,
                        selected: _protocol,
                        options: {
                          for (final p in protocols)
                            p: _protocolLabel(context, p),
                        },
                        onChanged: (value) => _protocol = value,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: _filterMenu(
                        name: 'Environment',
                        label: context.tr('Môi trường'),
                        icon: Icons.label_outline_rounded,
                        selected: _environment,
                        options: {
                          for (final e in environments)
                            e: e.isEmpty ? context.tr('Không gắn nhãn') : e,
                        },
                        onChanged: (value) => _environment = value,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (inventory.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: filtered.isEmpty && (inventory.groups.isEmpty || filtering)
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                inventory.loading
                                    ? context.tr('Đang tải thư viện…')
                                    : filtering
                                    ? context.tr('Không có kết nối phù hợp.')
                                    : s.emptyHostsSidebar,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: tp.muted),
                              ),
                              if (filtering)
                                TextButton(
                                  key: const Key('connectionResetFilters'),
                                  onPressed: _resetFilters,
                                  child: Text(context.tr('Xoá bộ lọc')),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('connectionLibraryList'),
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final indent = math.min(entry.depth, 4) * 9.0;
                      final group = entry.group;
                      if (group != null) {
                        return Padding(
                          padding: EdgeInsets.only(left: indent),
                          child: SizedBox(
                            height: 34,
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    key: Key('connectionGroup:${group.id}'),
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () => setState(() {
                                      if (!_collapsed.remove(group.id)) {
                                        _collapsed.add(group.id);
                                      }
                                    }),
                                    child: SizedBox(
                                      height: 34,
                                      child: Row(
                                        children: [
                                          Icon(
                                            _collapsed.contains(group.id)
                                                ? Icons.chevron_right_rounded
                                                : Icons.expand_more_rounded,
                                            size: 17,
                                            color: tp.muted,
                                          ),
                                          Icon(
                                            Icons.folder_outlined,
                                            size: 15,
                                            color: tp.accent,
                                          ),
                                          const SizedBox(width: 5),
                                          Expanded(
                                            child: Text(
                                              group.name,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${tree.descendantHostCount(group.id, filtered)}',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: tp.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  key: Key('connectionGroupMenu:${group.id}'),
                                  tooltip: context.tr(
                                    'Thao tác nhóm ${group.name}',
                                  ),
                                  enabled: !_busy.contains('group:${group.id}'),
                                  icon: const Icon(
                                    Icons.more_horiz_rounded,
                                    size: 16,
                                  ),
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(27, 30),
                                    maximumSize: const Size(27, 30),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onSelected: (action) =>
                                      _groupAction(group, action),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text(
                                        context.tr('Sửa tên / nhóm cha'),
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'child',
                                      child: Text(context.tr('Tạo nhóm con')),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text(context.tr('Xoá nhóm trống')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      final host = entry.host!;
                      final connected = workspace.tabs.any(
                        (tab) => tab.hostId == host.id && !tab.closed,
                      );
                      final supported =
                          _supportedProtocols.contains(host.protocol) &&
                          (host.protocol != 'serial' || serialSupported);
                      return Padding(
                        padding: EdgeInsets.only(left: indent),
                        child: GestureDetector(
                          onSecondaryTapDown: (details) =>
                              _showHostContext(host, details.globalPosition),
                          child: HoverSurface(
                            key: Key('connectionHost:${host.id}'),
                            margin: const EdgeInsets.only(bottom: 3),
                            padding: const EdgeInsets.fromLTRB(6, 7, 0, 7),
                            color: connected ? tp.surface2 : Colors.transparent,
                            hoverColor: tp.surface2,
                            border: Border.all(
                              color: connected
                                  ? tp.accent.withValues(alpha: .38)
                                  : Colors.transparent,
                            ),
                            hoverBorder: Border.all(color: tp.border),
                            onTap: supported && !_busy.contains(host.id)
                                ? () => _hostAction(host, 'connect')
                                : null,
                            child: Row(
                              children: [
                                ProtocolAvatar(
                                  envTag: host.envTag,
                                  protocol: host.protocol,
                                  size: 28,
                                  active: connected,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              host.label,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          if (host.isFavorite)
                                            Icon(
                                              Icons.star_rounded,
                                              size: 12,
                                              color: tp.amber,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        !supported
                                            ? context.tr(
                                                '${_protocolLabel(context, host.protocol)} · Chưa hỗ trợ',
                                              )
                                            : host.protocol == 'local_shell'
                                            ? context.tr('Local Shell')
                                            : host.protocol == 'serial'
                                            ? '${host.hostname} · Serial'
                                            : '${host.hostname}:${host.port} · ${host.envTag}',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontFamily: 'monospace',
                                          color: tp.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  key: Key('connectionHostMenu:${host.id}'),
                                  tooltip: context.tr('Thao tác ${host.label}'),
                                  enabled: !_busy.contains(host.id),
                                  icon: const Icon(
                                    Icons.more_vert_rounded,
                                    size: 16,
                                  ),
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(28, 32),
                                    maximumSize: const Size(28, 32),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onSelected: (action) =>
                                      _hostAction(host, action),
                                  itemBuilder: (_) => _hostMenu(host),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionGroupDialog extends ConsumerStatefulWidget {
  final GroupDto? existing;
  final String? initialParentId;
  const _ConnectionGroupDialog({this.existing, this.initialParentId});

  @override
  ConsumerState<_ConnectionGroupDialog> createState() =>
      _ConnectionGroupDialogState();
}

class _ConnectionGroupDialogState
    extends ConsumerState<_ConnectionGroupDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name,
  );
  late String? _parentId = widget.existing?.parentId ?? widget.initialParentId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Nhập tên nhóm.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(connectionLibraryActionsProvider)
          .saveGroup(
            id: widget.existing?.id,
            name: _name.text,
            parentId: _parentId,
          );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(inventoryProvider).groups;
    final tree = ConnectionLibraryTree(groups: groups, hosts: const []);
    final options =
        groups
            .where(
              (group) =>
                  widget.existing == null ||
                  !tree.isDescendant(group.id, widget.existing!.id),
            )
            .toList()
          ..sort(
            (a, b) => tree.groupPath(a.id).compareTo(tree.groupPath(b.id)),
          );
    final validParent = options.any((group) => group.id == _parentId)
        ? _parentId
        : null;
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? context.tr('Tạo nhóm kết nối')
            : context.tr('Sửa nhóm kết nối'),
      ),
      content: SizedBox(
        width: 390,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('connectionGroupName'),
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                decoration: InputDecoration(labelText: context.tr('Tên nhóm')),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: const Key('connectionGroupParent'),
                initialValue: validParent ?? '',
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Nhóm cha')),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(context.tr('Thư mục gốc')),
                  ),
                  for (final group in options)
                    DropdownMenuItem(
                      value: group.id,
                      child: Text(
                        tree.groupPath(group.id),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _parentId = value == '' ? null : value,
                      ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InlineNotice(message: _error!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(ref.s.cancel),
        ),
        FilledButton(
          key: const Key('connectionGroupSave'),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? context.tr('Đang lưu…') : context.tr('Lưu nhóm'),
          ),
        ),
      ],
    );
  }
}
