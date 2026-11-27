import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

class BottomDock extends ConsumerStatefulWidget {
  const BottomDock({super.key});

  @override
  ConsumerState<BottomDock> createState() => _BottomDockState();
}

class _BottomDockState extends ConsumerState<BottomDock> {
  int _tab = 0;
  bool _expanded = true;
  bool _sheetOpen = false;
  StateSetter? _sheetSetState;

  final _aiEndpointCtrl = TextEditingController(
    text: 'http://127.0.0.1:11434/api/chat',
  );
  final _aiModelCtrl = TextEditingController(text: 'qwen2.5-coder:7b');
  final _aiKeyCtrl = TextEditingController();
  final _aiPromptCtrl = TextEditingController();
  String? _aiDraftCmd;
  String? _aiDraftExplain;
  String? _aiError;
  bool _aiLoading = false;
  bool _aiDisclosureAccepted = false;
  late String _aiDisclosureEndpoint;
  late String _aiDisclosureModel;
  final Set<String> _pendingActions = {};

  @override
  void initState() {
    super.initState();
    _aiDisclosureEndpoint = _aiEndpointCtrl.text;
    _aiDisclosureModel = _aiModelCtrl.text;
    _aiEndpointCtrl.addListener(_resetAiDisclosure);
    _aiModelCtrl.addListener(_resetAiDisclosure);
  }

  void _resetAiDisclosure() {
    if (_aiDisclosureEndpoint == _aiEndpointCtrl.text &&
        _aiDisclosureModel == _aiModelCtrl.text) {
      return;
    }
    _update(() {
      _aiDisclosureEndpoint = _aiEndpointCtrl.text;
      _aiDisclosureModel = _aiModelCtrl.text;
      _aiDisclosureAccepted = false;
      _aiError = null;
    });
  }

  Uri? get _validAiEndpoint {
    final endpoint = Uri.tryParse(_aiEndpointCtrl.text.trim());
    if (endpoint == null ||
        !['http', 'https'].contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      return null;
    }
    return endpoint;
  }

  void _update(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _sheetSetState?.call(() {});
  }

  void _selectTab(int tab, bool compactHeight) {
    _update(() {
      _tab = tab;
      _expanded = true;
    });
    if (compactHeight) _openToolSheet();
  }

  Widget _toolBody(
    WorkspaceState workspace,
    InventoryState inventory,
    SessionManagerController manager,
    TermPulsePalette palette,
    AppStrings strings,
  ) {
    return switch (_tab) {
      0 => _buildTransfers(workspace, manager, palette),
      1 => _buildTunnels(inventory, workspace, manager, palette, strings),
      2 => _buildHealth(workspace, manager, palette, strings),
      _ => _buildAiDraft(workspace, manager, palette),
    };
  }

  Future<void> _openToolSheet() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: context.tp.surface,
        constraints: const BoxConstraints(maxWidth: 1100),
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            _sheetSetState = setSheetState;
            return Consumer(
              builder: (sheetContext, sheetRef, _) {
                final workspace = sheetRef.watch(sessionManagerProvider);
                final inventory = sheetRef.watch(inventoryProvider);
                final manager = sheetRef.read(sessionManagerProvider.notifier);
                final palette = sheetContext.tp;
                final strings = sheetRef.s;
                final keyboard = MediaQuery.viewInsetsOf(sheetContext).bottom;
                final visibleHeight =
                    MediaQuery.sizeOf(sheetContext).height -
                    keyboard -
                    MediaQuery.paddingOf(sheetContext).top;
                final title = switch (_tab) {
                  0 => context.tr('Truyền file'),
                  1 => context.tr('SSH tunnels'),
                  2 => strings.healthTabTitle,
                  _ => context.tr('AI Draft'),
                };
                return Padding(
                  padding: EdgeInsets.only(bottom: keyboard),
                  child: SizedBox(
                    height: (visibleHeight * 0.85).clamp(80.0, 520.0),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: context.tr('Đóng công cụ'),
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: palette.border),
                        Expanded(
                          child: _toolBody(
                            workspace,
                            inventory,
                            manager,
                            palette,
                            strings,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    } finally {
      _sheetSetState = null;
      _sheetOpen = false;
    }
  }

  Future<void> _runAction(String key, Future<void> Function() action) async {
    if (_pendingActions.contains(key)) return;
    _update(() => _pendingActions.add(key));
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Không thực hiện được thao tác: {error}', {
                'error': e.toString(),
              }),
            ),
          ),
        );
      }
    } finally {
      if (mounted) _update(() => _pendingActions.remove(key));
    }
  }

  Future<void> _manageTunnel(String action, TunnelDto tunnel) async {
    bool isRunning() => ref
        .read(sessionManagerProvider)
        .tunnelStatuses
        .any((status) => status.tunnelId == tunnel.id && status.running);
    if (_pendingActions.contains(tunnel.id) || isRunning()) return;
    if (action == 'edit') {
      await _runAction(
        tunnel.id,
        () => showCreateTunnelDialog(context, ref, existing: tunnel),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('Xoá Tunnel?')),
        content: Text(
          context.tr('Xoá cấu hình “{name}”? Bạn có thể tạo lại khi cần.', {
            'name': tunnel.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.tr('Huỷ')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.tp.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.tr('Xoá Tunnel')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || isRunning()) return;
    await _runAction(
      tunnel.id,
      () => ref.read(inventoryProvider.notifier).removeTunnel(tunnel.id),
    );
  }

  @override
  void dispose() {
    _aiEndpointCtrl.removeListener(_resetAiDisclosure);
    _aiModelCtrl.removeListener(_resetAiDisclosure);
    _aiEndpointCtrl.dispose();
    _aiModelCtrl.dispose();
    _aiKeyCtrl.dispose();
    _aiPromptCtrl.dispose();
    super.dispose();
  }

  Future<void> _generateAiDraft() async {
    if (_aiLoading) return;
    final endpoint = _validAiEndpoint;
    if (endpoint == null ||
        _aiModelCtrl.text.trim().isEmpty ||
        _aiPromptCtrl.text.trim().isEmpty) {
      _update(
        () => _aiError =
            'Nhập endpoint HTTP(S), tên model và yêu cầu để tạo bản nháp.',
      );
      return;
    }
    if (!_aiDisclosureAccepted) {
      _update(
        () => _aiError =
            'Đọc thông tin dữ liệu và xác nhận trước khi gửi yêu cầu AI.',
      );
      return;
    }
    _update(() {
      _aiLoading = true;
      _aiError = null;
      _aiDraftCmd = null;
      _aiDraftExplain = null;
    });
    try {
      final res = await ref
          .read(backendProvider)
          .aiDraftCommand(
            endpointUrl: _aiEndpointCtrl.text.trim(),
            apiKey: _aiKeyCtrl.text.trim().isEmpty
                ? null
                : _aiKeyCtrl.text.trim(),
            model: _aiModelCtrl.text.trim(),
            prompt: _aiPromptCtrl.text.trim(),
            osHint: Platform.operatingSystem,
            shellHint: Platform.isWindows ? 'PowerShell' : 'bash',
          );
      if (mounted) {
        _update(() {
          _aiLoading = false;
          _aiDraftCmd = res.command.trim();
          _aiDraftExplain = res.explanation;
        });
      }
    } catch (e) {
      if (mounted) {
        _update(() {
          _aiLoading = false;
          _aiError =
              'Không tạo được bản nháp. Kiểm tra endpoint, model, API key và kết nối: $e';
        });
      }
    }
  }

  Future<void> _insertAiDraft(SessionManagerController manager) async {
    final command = _aiDraftCmd?.trim();
    if (command == null || command.isEmpty || _aiLoading) return;
    if (command.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      _update(
        () => _aiError =
            'Bản nháp có nhiều dòng hoặc ký tự điều khiển. Sao chép và kiểm tra từng lệnh trước khi chạy.',
      );
      return;
    }
    await _runAction('ai_insert', () => manager.sendTextToActive(command));
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(sessionManagerProvider);
    final inv = ref.watch(inventoryProvider);
    final mgr = ref.read(sessionManagerProvider.notifier);
    final s = ref.s;
    final tp = context.tp;
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final compactHeight = availableHeight < 520;
    final expanded = !compactHeight && _expanded;
    final body = expanded
        ? SizedBox(height: 152, child: _toolBody(ws, inv, mgr, tp, s))
        : const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: tp.surface,
        border: Border(top: BorderSide(color: tp.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: tp.surface,
              border: Border(bottom: BorderSide(color: tp.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _DockTabBtn(
                          label: context.tr('Transfers ({count})', {
                            'count': '${ws.transfers.length}',
                          }),
                          icon: Icons.swap_vert_rounded,
                          selected: _tab == 0,
                          onTap: () => _selectTab(0, compactHeight),
                        ),
                        const SizedBox(width: 4),
                        _DockTabBtn(
                          label: context.tr('Tunnels ({count})', {
                            'count': '${inv.tunnels.length}',
                          }),
                          icon: Icons.alt_route_rounded,
                          selected: _tab == 1,
                          onTap: () => _selectTab(1, compactHeight),
                        ),
                        const SizedBox(width: 4),
                        _DockTabBtn(
                          label: s.healthTabTitle,
                          icon: Icons.monitor_heart_rounded,
                          selected: _tab == 2,
                          onTap: () => _selectTab(2, compactHeight),
                        ),
                        const SizedBox(width: 4),
                        _DockTabBtn(
                          label: context.tr('AI Draft (BYO-Key/Ollama)'),
                          icon: Icons.auto_awesome_rounded,
                          selected: _tab == 3,
                          onTap: () => _selectTab(3, compactHeight),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: expanded
                      ? context.tr('Thu gọn bảng công cụ')
                      : context.tr('Mở bảng công cụ'),
                  icon: Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    size: 19,
                  ),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: compactHeight
                      ? _openToolSheet
                      : () => _update(() => _expanded = !expanded),
                ),
              ],
            ),
          ),
          if (MediaQuery.disableAnimationsOf(context))
            body
          else
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: body,
            ),
        ],
      ),
    );
  }

  Widget _buildTransfers(
    WorkspaceState ws,
    SessionManagerController mgr,
    TermPulsePalette tp,
  ) {
    if (ws.transfers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            context.tr(
              'Hàng đợi truyền file trống — hoạt động nền không chặn terminal.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: tp.muted, fontSize: 12.5),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: ws.transfers.length,
      itemBuilder: (_, i) {
        final job = ws.transfers[i];
        final ratio = job.bytesTotal > 0
            ? (job.bytesDone / job.bytesTotal).clamp(0.0, 1.0)
            : (job.finished && !job.cancelled && job.error == null ? 1.0 : 0.0);
        final pct = (ratio * 100).round();
        return ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: tp.accentContainer,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              job.isUpload ? Icons.upload_rounded : Icons.download_rounded,
              color: tp.accent,
              size: 17,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  job.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: job.cancelled ? tp.muted : tp.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 5,
                  backgroundColor: tp.bg,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    job.cancelled
                        ? tp.muted
                        : job.error != null
                        ? tp.red
                        : tp.accent,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                job.cancelled
                    ? context.tr('Đã huỷ · {bytes} B', {
                        'bytes': '${job.bytesDone}',
                      })
                    : (job.error == null ? null : context.tr(job.error!)) ??
                          (job.finished
                              ? '${job.bytesDone} B'
                              : '${job.bytesDone}/${job.bytesTotal} B'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: job.error != null ? tp.red : tp.muted,
                ),
              ),
            ],
          ),
          trailing: job.cancelled || job.finished || job.error != null
              ? Tooltip(
                  message: job.cancelled
                      ? context.tr('Đã huỷ')
                      : (job.error == null ? null : context.tr(job.error!)) ??
                            context.tr('Hoàn tất'),
                  child: Icon(
                    job.cancelled
                        ? Icons.cancel_outlined
                        : job.error != null
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_rounded,
                    color: job.cancelled
                        ? tp.muted
                        : job.error != null
                        ? tp.red
                        : tp.green,
                    size: 18,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: job.paused
                          ? context.tr('Tiếp tục truyền')
                          : context.tr('Tạm dừng truyền'),
                      icon: Icon(
                        job.paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        size: 18,
                      ),
                      onPressed: _pendingActions.contains(job.transferId)
                          ? null
                          : () => _runAction(
                              job.transferId,
                              () => mgr.controlTransfer(
                                job.transferId,
                                job.paused ? 'resume' : 'pause',
                              ),
                            ),
                    ),
                    IconButton(
                      tooltip: context.tr('Huỷ truyền file'),
                      icon: Icon(Icons.close_rounded, size: 18, color: tp.red),
                      onPressed: _pendingActions.contains(job.transferId)
                          ? null
                          : () => _runAction(
                              job.transferId,
                              () =>
                                  mgr.controlTransfer(job.transferId, 'cancel'),
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildTunnels(
    InventoryState inv,
    WorkspaceState ws,
    SessionManagerController mgr,
    TermPulsePalette tp,
    AppStrings s,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.tr('SSH port forwarding'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: tp.muted),
                ),
              ),
              TextButton.icon(
                onPressed: () => showCreateTunnelDialog(context, ref),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: Text(s.addTunnelBtn),
              ),
            ],
          ),
        ),
        Expanded(
          child: inv.tunnels.isEmpty
              ? Center(
                  child: Text(
                    context.tr('Chưa có tunnel. Chọn Thêm để cấu hình.'),
                    style: TextStyle(color: tp.muted, fontSize: 12.5),
                  ),
                )
              : ListView.builder(
                  itemCount: inv.tunnels.length,
                  itemBuilder: (_, i) {
                    final t = inv.tunnels[i];
                    final st = ws.tunnelStatuses
                        .where((st) => st.tunnelId == t.id)
                        .firstOrNull;
                    final running = st?.running ?? false;
                    final busy = _pendingActions.contains(t.id);
                    final kindLabel = switch (t.kind) {
                      'local' => context.tr('Local'),
                      'remote' => context.tr('Remote'),
                      'dynamic_socks' => 'SOCKS5',
                      _ => t.kind,
                    };
                    final destination = t.kind == 'dynamic_socks'
                        ? context.tr('SOCKS5 proxy')
                        : '${t.targetHost ?? "—"}:${t.targetPort ?? "—"}';
                    return ListTile(
                      dense: true,
                      leading: StatusDot(
                        color: running ? tp.green : tp.muted,
                        glow: running,
                        size: 9,
                      ),
                      title: Text(
                        '${t.name} · $kindLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${t.bindAddr}:${t.bindPort} → $destination\n${running ? context.tr('Đang chạy') : context.tr('Đã dừng')} · ↓${st?.bytesIn ?? BigInt.zero}B ↑${st?.bytesOut ?? BigInt.zero}B',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: tp.muted,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              backgroundColor: running
                                  ? tp.red.withValues(alpha: 0.16)
                                  : tp.accentContainer,
                              foregroundColor: running ? tp.red : tp.accent,
                              side: BorderSide(
                                color: running
                                    ? tp.red.withValues(alpha: 0.42)
                                    : tp.accent.withValues(alpha: 0.35),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                            ),
                            onPressed: busy
                                ? null
                                : () => _runAction(
                                    t.id,
                                    () => running
                                        ? mgr.stopTunnel(t.id)
                                        : mgr.startTunnel(t.id),
                                  ),
                            child: Text(
                              busy
                                  ? '…'
                                  : running
                                  ? s.stopBtn
                                  : s.startBtn,
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: running
                                ? context.tr('Dừng Tunnel để sửa hoặc xoá')
                                : context.tr('Quản lý Tunnel'),
                            enabled: !busy,
                            onSelected: (action) => _manageTunnel(action, t),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'edit',
                                enabled: !running,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.edit_outlined, size: 18),
                                  title: Text(context.tr('Chỉnh sửa Tunnel')),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                enabled: !running,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: tp.red,
                                  ),
                                  title: Text(
                                    context.tr('Xoá Tunnel'),
                                    style: TextStyle(color: tp.red),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHealth(
    WorkspaceState ws,
    SessionManagerController mgr,
    TermPulsePalette tp,
    AppStrings s,
  ) {
    final tab = ws.activeTab;
    if (tab == null || tab.protocol != 'ssh') {
      return Center(
        child: Text(
          context.tr('SSH Linux /proc monitor'),
          style: TextStyle(color: tp.muted),
        ),
      );
    }
    final m = tab.metrics;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          if (m == null)
            Expanded(
              child: Text(
                context.tr('{action} (SSH /proc không cần agent)', {
                  'action': s.measureProcBtn,
                }),
                style: TextStyle(color: tp.muted, fontSize: 12.5),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    MetricGaugeCard(
                      label: context.tr('CPU LOAD'),
                      value: '${m.cpuPercent.toStringAsFixed(1)}%',
                      ratio: m.cpuPercent / 100.0,
                      icon: Icons.memory_rounded,
                    ),
                    const SizedBox(width: 10),
                    MetricGaugeCard(
                      label: context.tr('MEMORY'),
                      value: '${m.memUsedMb}/${m.memTotalMb} MB',
                      ratio: m.memTotalMb > BigInt.zero
                          ? m.memUsedMb.toDouble() / m.memTotalMb.toDouble()
                          : 0,
                      icon: Icons.developer_board_rounded,
                    ),
                    const SizedBox(width: 10),
                    MetricGaugeCard(
                      label: context.tr('DISK /'),
                      value:
                          '${m.diskUsedGb.toStringAsFixed(1)}/${m.diskTotalGb.toStringAsFixed(1)} GB',
                      ratio: m.diskTotalGb > 0
                          ? m.diskUsedGb / m.diskTotalGb
                          : 0,
                      icon: Icons.storage_rounded,
                    ),
                    const SizedBox(width: 10),
                    MetricGaugeCard(
                      label: context.tr('LOAD AVG'),
                      value: m.loadAvg,
                      icon: Icons.speed_rounded,
                    ),
                    const SizedBox(width: 10),
                    MetricGaugeCard(
                      label: context.tr('UPTIME'),
                      value: '${m.uptimeSecs}s',
                      icon: Icons.timer_outlined,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed:
                tab.sessionId == null ||
                    tab.closed ||
                    _pendingActions.contains('metrics')
                ? null
                : () => _runAction(
                    'metrics',
                    () => mgr.refreshMetrics(tab.localKey),
                  ),
            icon: const Icon(Icons.monitor_heart_rounded, size: 16),
            label: Text(s.measureProcBtn),
          ),
        ],
      ),
    );
  }

  Widget _buildAiDraft(
    WorkspaceState workspace,
    SessionManagerController mgr,
    TermPulsePalette tp,
  ) {
    final active = workspace.activeTab;
    final canInsert = active?.sessionId != null && active?.closed == false;
    final endpoint = _validAiEndpoint;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 640;
              final endpointWidth = compact
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 16) / 2;
              final fieldWidth = compact
                  ? (constraints.maxWidth - 8) / 2
                  : (constraints.maxWidth - 16) / 4;
              return Wrap(
                spacing: 8,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: endpointWidth,
                    child: TextField(
                      key: const Key('aiEndpointField'),
                      controller: _aiEndpointCtrl,
                      enabled: !_aiLoading,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: context.tr('Endpoint API'),
                        hintText: 'http://127.0.0.1:11434/api/chat',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: TextField(
                      key: const Key('aiModelField'),
                      controller: _aiModelCtrl,
                      enabled: !_aiLoading,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: context.tr('Model'),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: TextField(
                      key: const Key('aiKeyField'),
                      controller: _aiKeyCtrl,
                      enabled: !_aiLoading,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: context.tr('API key (tuỳ chọn)'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Container(
            key: const Key('aiDisclosurePanel'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tp.accentContainer.withValues(alpha: 0.45),
              border: Border.all(color: tp.borderStrong),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr('Dữ liệu gửi cho AI'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  endpoint == null
                      ? context.tr(
                          'Nhập endpoint HTTP(S) hợp lệ để xem nơi nhận.',
                        )
                      : context.tr('Nơi nhận: {endpoint}', {
                          'endpoint': _aiEndpointCtrl.text.trim(),
                        }),
                  key: const Key('aiDisclosureRecipient'),
                  style: TextStyle(color: tp.ink, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'Khi nhấn Tạo nháp, yêu cầu bạn nhập, model và gợi ý hệ điều hành/shell được gửi trực tiếp tới endpoint đã chọn. API key, nếu nhập, chỉ được gửi trong phần xác thực tới endpoint đó. Ứng dụng không tự đính kèm lịch sử terminal hoặc dữ liệu Vault.',
                  ),
                  style: TextStyle(color: tp.ink, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'Dịch vụ nhận dữ liệu áp dụng chính sách lưu giữ riêng. Không đưa mật khẩu, private key hoặc dữ liệu nhạy cảm vào yêu cầu.',
                  ),
                  style: TextStyle(color: tp.muted, fontSize: 12, height: 1.4),
                ),
                if (endpoint?.scheme == 'http') ...[
                  const SizedBox(height: 6),
                  Text(
                    context.tr(
                      'Cảnh báo HTTP: yêu cầu và API key được truyền không mã hóa. Chỉ dùng endpoint cục bộ hoặc mạng tin cậy; ưu tiên HTTPS.',
                    ),
                    key: const Key('aiHttpWarning'),
                    style: TextStyle(
                      color: tp.amber,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ],
                CheckboxListTile(
                  key: const Key('aiDisclosureAcknowledgement'),
                  value: _aiDisclosureAccepted,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: Text(
                    context.tr(
                      'Tôi đã đọc và đồng ý gửi dữ liệu nêu trên tới endpoint này khi nhấn Tạo nháp.',
                    ),
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                  onChanged: _aiLoading || endpoint == null
                      ? null
                      : (value) => _update(
                          () => _aiDisclosureAccepted = value == true,
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('aiPromptField'),
                  controller: _aiPromptCtrl,
                  enabled: !_aiLoading,
                  onSubmitted: (_) => _generateAiDraft(),
                  decoration: InputDecoration(
                    hintText: context.tr('Mô tả lệnh bạn cần…'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('aiGenerateDraft'),
                onPressed: _aiLoading || !_aiDisclosureAccepted
                    ? null
                    : _generateAiDraft,
                icon: _aiLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 16),
                label: Text(
                  _aiLoading ? context.tr('Đang tạo…') : context.tr('Tạo nháp'),
                ),
              ),
            ],
          ),
          if (_aiLoading)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                context.tr(
                  'Đang chờ model phản hồi. Ollama có thể mất vài phút để nạp model lần đầu.',
                ),
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (_aiError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  context.tr(_aiError!),
                  style: TextStyle(color: tp.red, fontSize: 12),
                ),
              ),
            ),
          if (_aiDraftCmd != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: tp.bg,
                border: Border.all(color: tp.borderStrong),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                _aiDraftCmd!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: tp.accent,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
            if (_aiDraftExplain?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _aiDraftExplain!,
                  style: TextStyle(color: tp.muted, fontSize: 12, height: 1.4),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              context.tr(
                'Kiểm tra trước khi dùng. Chèn chỉ nhập lệnh; bạn nhấn Enter để chạy.',
              ),
              style: TextStyle(color: tp.muted, fontSize: 11.5),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _runAction(
                    'ai_copy',
                    () => Clipboard.setData(ClipboardData(text: _aiDraftCmd!)),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: Text(context.tr('Sao chép')),
                ),
                OutlinedButton.icon(
                  onPressed:
                      !canInsert ||
                          _aiLoading ||
                          _pendingActions.contains('ai_insert')
                      ? null
                      : () => _insertAiDraft(mgr),
                  icon: const Icon(Icons.terminal_rounded, size: 15),
                  label: Text(context.tr('Chèn vào terminal')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DockTabBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _DockTabBtn({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? tp.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? tp.borderStrong : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? tp.accent : tp.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? tp.ink : tp.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
