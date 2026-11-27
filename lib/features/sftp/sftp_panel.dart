import 'dart:io';
import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/sftp/remote_editor_dialog.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

String _readableSize(BigInt bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 || value >= 10 ? 0 : 1)} ${units[unit]}';
}

enum _RemoteSort {
  name('Tên A → Z'),
  nameDescending('Tên Z → A'),
  newest('Mới sửa trước'),
  largest('Dung lượng lớn trước');

  final String label;
  const _RemoteSort(this.label);
}

typedef _RemoteLocation = ({String key, String session, String cwd});

abstract interface class SftpLocalPathAccess {
  Future<bool> directoryExists(String path);

  /// Includes symbolic links, including links whose target does not exist.
  Future<bool> entryExists(String path);
}

class _IoSftpLocalPathAccess implements SftpLocalPathAccess {
  const _IoSftpLocalPathAccess();

  @override
  Future<bool> directoryExists(String path) => Directory(path).exists();

  @override
  Future<bool> entryExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;
}

class SftpPanel extends ConsumerStatefulWidget {
  final TerminalSessionTab tab;
  final bool compact;
  final bool? commanderMode;
  final ValueChanged<bool>? onCommanderChanged;
  final SftpLocalPathAccess? localPathAccess;

  const SftpPanel({
    super.key,
    required this.tab,
    this.compact = false,
    this.commanderMode,
    this.onCommanderChanged,
    this.localPathAccess,
  });

  @override
  ConsumerState<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends ConsumerState<SftpPanel> {
  AppLanguage _language = AppLanguage.vi;

  // Async file operations can complete after their dialog closes. Retain the
  // current language rather than consulting an unmounted BuildContext.
  String _tr(String source, [Map<String, String> parameters = const {}]) =>
      translateAppMessage(_language, source, parameters);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _language = AppLocalizationScope.of(context);
  }

  bool _localCommander = false;
  late String _localDir;
  List<FileSystemEntity> _localEntries = [];
  bool _localLoading = false;
  String? _localError;
  int _localRequest = 0;
  bool _busy = false;
  final _filterController = TextEditingController();
  String _filter = '';
  bool _showHidden = false;
  _RemoteSort _sort = _RemoteSort.name;
  bool _selecting = false;
  final Set<String> _selectedPaths = {};

  bool get _commanderMode => widget.commanderMode ?? _localCommander;
  SftpLocalPathAccess get _localPathAccess =>
      widget.localPathAccess ?? const _IoSftpLocalPathAccess();
  bool get _canUseSftp =>
      widget.tab.sessionId != null &&
      !widget.tab.closed &&
      widget.tab.protocol == 'ssh' &&
      widget.tab.sftpUnavailableReason == null;

  void _toggleCommander() {
    final next = !_commanderMode;
    if (widget.onCommanderChanged != null) {
      widget.onCommanderChanged!(next);
    } else {
      setState(() => _localCommander = next);
    }
    if (next) _loadLocalDirectory(_localDir);
  }

  @override
  void initState() {
    super.initState();
    _localDir = Platform.environment['HOME'] ?? '/';
    if (_commanderMode) _loadLocalDirectory(_localDir);
  }

  @override
  void didUpdateWidget(covariant SftpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab.localKey != widget.tab.localKey ||
        oldWidget.tab.sessionId != widget.tab.sessionId ||
        oldWidget.tab.cwd != widget.tab.cwd ||
        !_canUseSftp) {
      _selectedPaths.clear();
      _selecting = false;
    } else {
      final available = widget.tab.sftpEntries.map((e) => e.path).toSet();
      _selectedPaths.removeWhere((path) => !available.contains(path));
    }
    if (widget.commanderMode == true && oldWidget.commanderMode != true) {
      _loadLocalDirectory(_localDir);
    }
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  _RemoteLocation get _location => (
    key: widget.tab.localKey,
    session: widget.tab.sessionId!,
    cwd: widget.tab.cwd,
  );

  bool _atLocation(_RemoteLocation location) =>
      mounted &&
      _canUseSftp &&
      widget.tab.localKey == location.key &&
      widget.tab.sessionId == location.session &&
      widget.tab.cwd == location.cwd;

  List<SftpEntryDto> get _visibleEntries {
    final query = _filter.trim().toLowerCase();
    final entries = widget.tab.sftpEntries.where((entry) {
      return (_showHidden || !entry.name.startsWith('.')) &&
          (query.isEmpty || entry.name.toLowerCase().contains(query));
    }).toList();
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final comparison = switch (_sort) {
        _RemoteSort.name => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
        _RemoteSort.nameDescending => b.name.toLowerCase().compareTo(
          a.name.toLowerCase(),
        ),
        _RemoteSort.newest => b.modified.compareTo(a.modified),
        _RemoteSort.largest => b.size.compareTo(a.size),
      };
      return comparison != 0 ? comparison : a.path.compareTo(b.path);
    });
    return entries;
  }

  List<SftpEntryDto> get _selectedEntries => _visibleEntries
      .where((entry) => _selectedPaths.contains(entry.path))
      .toList();

  void _pruneFilteredSelection() {
    final visible = _visibleEntries.map((entry) => entry.path).toSet();
    _selectedPaths.removeWhere((path) => !visible.contains(path));
  }

  void _toggleSelection(SftpEntryDto entry) {
    if (_busy || !_canUseSftp) return;
    setState(() {
      _selecting = true;
      if (!_selectedPaths.add(entry.path)) _selectedPaths.remove(entry.path);
    });
  }

  Future<void> _loadLocalDirectory(String path) async {
    final request = ++_localRequest;
    setState(() {
      _localLoading = true;
      _localError = null;
      _localDir = path;
    });
    try {
      final entries = await Directory(path).list(followLinks: false).toList();
      entries.sort((a, b) {
        if ((a is Directory) != (b is Directory)) {
          return a is Directory ? -1 : 1;
        }
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (mounted && request == _localRequest) {
        setState(() {
          _localEntries = entries;
          _localLoading = false;
        });
      }
    } catch (e) {
      if (mounted && request == _localRequest) {
        setState(() {
          _localEntries = [];
          _localLoading = false;
          _localError = 'Không đọc được thư mục: $e';
        });
      }
    }
  }

  void _showMessage(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? context.tp.red : null,
      ),
    );
  }

  Future<void> _runFileAction(Future<void> Function() action) async {
    if (_busy || !_canUseSftp) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _showMessage(
        _tr('Không thực hiện được thao tác: {error}', {'error': e.toString()}),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\u0000');

  Widget _directoryState({
    required IconData icon,
    required String title,
    required String detail,
    String? actionLabel,
    VoidCallback? onAction,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: context.tp.muted),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.tp.muted,
                height: 1.45,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    ),
  );

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
              ),
              child: SingleChildScrollView(child: Text(message)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(ref.s.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _promptMkdir() async {
    final s = ref.s;
    final name = await _promptText(
      title: s.mkdirTooltip,
      label: _tr('Tên thư mục'),
      action: s.create,
    );
    if (!mounted || name == null || !_canUseSftp) return;
    if (!_validName(name)) {
      _showMessage(_tr('Tên thư mục không hợp lệ.'), error: true);
      return;
    }
    final target = widget.tab.cwd == '/' ? '/$name' : '${widget.tab.cwd}/$name';
    await _runFileAction(() async {
      final backend = ref.read(backendProvider);
      final manager = ref.read(sessionManagerProvider.notifier);
      await backend.sftpCreateDir(widget.tab.sessionId!, target);
      await manager.loadSftpDirectory(widget.tab.localKey, widget.tab.cwd);
    });
  }

  Future<void> _promptRename(SftpEntryDto entry) async {
    final s = ref.s;
    final nextName = await _promptText(
      title: _tr('Đổi tên'),
      label: _tr('Tên mới'),
      action: s.save,
      initialValue: entry.name,
    );
    if (!mounted ||
        nextName == null ||
        nextName == entry.name ||
        !_canUseSftp) {
      return;
    }
    if (!_validName(nextName)) {
      _showMessage(_tr('Tên file không hợp lệ.'), error: true);
      return;
    }
    if (widget.tab.sftpEntries.any((e) => e.name == nextName)) {
      _showMessage(_tr('Tên này đã tồn tại. Chọn một tên khác.'), error: true);
      return;
    }
    final parent = entry.path.substring(0, entry.path.lastIndexOf('/'));
    final nextPath = '${parent.isEmpty ? "" : parent}/$nextName';
    await _runFileAction(() async {
      final backend = ref.read(backendProvider);
      final manager = ref.read(sessionManagerProvider.notifier);
      await backend.sftpRenameEntry(
        widget.tab.sessionId!,
        entry.path,
        nextPath,
      );
      await manager.loadSftpDirectory(widget.tab.localKey, widget.tab.cwd);
    });
  }

  Future<void> _downloadEntry(SftpEntryDto entry) async {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final path = await _promptText(
      title: _tr('Tải file về máy'),
      label: _tr('Đường dẫn lưu đầy đủ'),
      action: _tr('Tải về'),
      initialValue: '$home/${entry.name}',
    );
    if (!mounted || path == null || path.isEmpty) return;
    await _runFileAction(() async {
      final manager = ref.read(sessionManagerProvider.notifier);
      if (await File(path).exists()) {
        if (!mounted ||
            !await _confirm(
              title: _tr('Ghi đè file trên máy?'),
              message: path,
              action: _tr('Ghi đè'),
            )) {
          return;
        }
      }
      if (!mounted) return;
      await manager.enqueueTransfer(
        localKey: widget.tab.localKey,
        isUpload: false,
        localPath: path,
        remotePath: entry.path,
        fileName: entry.name,
      );
      _showMessage(
        _tr('Đã thêm {name} vào hàng đợi tải về.', {'name': entry.name}),
      );
    });
  }

  Future<String?> _promptText({
    required String title,
    required String label,
    required String action,
    String initialValue = '',
  }) async {
    final ctrl = TextEditingController(text: initialValue);
    final cancelLabel = ref.s.cancel;
    final route = DialogRoute<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          autocorrect: false,
          onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    );
    try {
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      return result;
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _deleteEntry(SftpEntryDto entry) async {
    if (!await _confirm(
      title: entry.isDir ? _tr('Xoá thư mục?') : _tr('Xoá file?'),
      message: _tr('Thao tác này không thể hoàn tác.\n{path}', {
        'path': entry.path,
      }),
      action: _tr('Xoá'),
    )) {
      return;
    }
    if (!mounted) return;
    await _runFileAction(() async {
      final backend = ref.read(backendProvider);
      final manager = ref.read(sessionManagerProvider.notifier);
      await backend.sftpDeleteEntry(
        widget.tab.sessionId!,
        entry.path,
        entry.isDir,
      );
      await manager.loadSftpDirectory(widget.tab.localKey, widget.tab.cwd);
    });
  }

  String _entrySummary(List<SftpEntryDto> entries) {
    final directories = entries.where((entry) => entry.isDir).length;
    return _tr('{files} file, {folders} thư mục', {
      'files': '${entries.length - directories}',
      'folders': '$directories',
    });
  }

  String _entryNames(Iterable<SftpEntryDto> entries) =>
      entries.map((entry) => entry.name).join('\n');

  Future<void> _batchResult(String title, String summary, List<String> errors) {
    if (!mounted) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              '$summary${errors.isEmpty ? '' : '\n\n${_tr('Bỏ qua / lỗi ({count}):\n{errors}', {'count': '${errors.length}', 'errors': errors.join('\n')})}'}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(_tr('Đóng')),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_busy ||
        !_canUseSftp ||
        widget.tab.sftpLoading ||
        widget.tab.sftpError != null) {
      return;
    }
    final location = _location;
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    await _runFileAction(() async {
      final confirmed = await _confirm(
        title: _tr('Xoá {count} mục đã chọn?', {'count': '${entries.length}'}),
        message: _tr(
          '{summary} trong {path}\nThao tác này không thể hoàn tác. Thư mục phải trống; không xoá đệ quy.\n\n{names}',
          {
            'summary': _entrySummary(entries),
            'path': location.cwd,
            'names': _entryNames(entries),
          },
        ),
        action: _tr('Xoá {count} mục', {'count': '${entries.length}'}),
      );
      if (!confirmed || !mounted) return;
      final backend = ref.read(backendProvider);
      final manager = ref.read(sessionManagerProvider.notifier);
      final errors = <String>[];
      var deleted = 0;
      for (final entry in entries) {
        if (!_atLocation(location) || widget.tab.sftpLoading) {
          errors.add(
            _tr('{name}: phiên hoặc thư mục đã thay đổi.', {
              'name': entry.name,
            }),
          );
          continue;
        }
        try {
          await backend.sftpDeleteEntry(
            location.session,
            entry.path,
            entry.isDir,
          );
          deleted++;
          if (mounted) setState(() => _selectedPaths.remove(entry.path));
        } catch (error) {
          errors.add('${entry.name}: $error');
        }
      }
      if (_atLocation(location)) {
        await manager.loadSftpDirectory(location.key, location.cwd);
      }
      await _batchResult(
        _tr('Kết quả xoá'),
        _tr('Đã xoá {deleted}/{total} mục.', {
          'deleted': '$deleted',
          'total': '${entries.length}',
        }),
        errors,
      );
    });
  }

  // A remote filename is untrusted when mapped onto the local filesystem.
  bool _safeLocalName(String name) =>
      _validName(name) &&
      !name.contains('\\') &&
      (!Platform.isWindows ||
          (!RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name) &&
              !name.endsWith('.') &&
              !name.endsWith(' ') &&
              !RegExp(
                r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
                caseSensitive: false,
              ).hasMatch(name)));

  Future<void> _downloadSelected() async {
    if (_busy ||
        !_canUseSftp ||
        widget.tab.sftpLoading ||
        widget.tab.sftpError != null) {
      return;
    }
    final location = _location;
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    await _runFileAction(() async {
      final destination = await _promptText(
        title: _tr('Tải các file đã chọn'),
        label: _tr('Thư mục lưu trên máy'),
        action: _tr('Tiếp tục'),
        initialValue: _commanderMode
            ? _localDir
            : Platform.environment['HOME'] ?? Directory.systemTemp.path,
      );
      if (destination == null || destination.isEmpty || !mounted) return;
      if (!_atLocation(location) || widget.tab.sftpLoading) {
        _showMessage(_tr('Phiên hoặc thư mục đã thay đổi. Hãy chọn lại file.'));
        return;
      }
      final directory = Directory(destination);
      if (!await _localPathAccess.directoryExists(directory.path)) {
        _showMessage(_tr('Thư mục lưu không tồn tại.'), error: true);
        return;
      }
      final errors = <String>[];
      final targets = <({SftpEntryDto entry, String localPath})>[];
      final names = <String>{};
      for (final entry in entries) {
        if (entry.isDir) {
          errors.add(
            _tr('{name}: chưa hỗ trợ tải cả thư mục.', {'name': entry.name}),
          );
          continue;
        }
        if (!_safeLocalName(entry.name)) {
          errors.add(
            _tr('{name}: tên không an toàn trên máy này.', {
              'name': entry.name,
            }),
          );
          continue;
        }
        final nameKey = Platform.isWindows || Platform.isMacOS
            ? entry.name.toLowerCase()
            : entry.name;
        final path = '${directory.path}${Platform.pathSeparator}${entry.name}';
        if (!names.add(nameKey) || await _localPathAccess.entryExists(path)) {
          errors.add(
            _tr('{name}: đích đã tồn tại hoặc trùng tên.', {
              'name': entry.name,
            }),
          );
          continue;
        }
        targets.add((entry: entry, localPath: path));
      }
      if (!mounted) return;
      if (targets.isEmpty) {
        await _batchResult(
          _tr('Chưa có file để tải'),
          _tr('Đã gửi 0 yêu cầu.'),
          errors,
        );
        return;
      }
      final confirmed = await _confirm(
        title: _tr('Tải {count} file về máy?', {'count': '${targets.length}'}),
        message:
            _tr(
              '{summary} đã chọn.\nSẵn sàng: {ready} file. Bỏ qua: {skipped} mục.\nThư mục lưu: {path}\nMục đã tồn tại khi kiểm tra sẽ được bỏ qua.\n\n{names}',
              {
                'summary': _entrySummary(entries),
                'ready': '${targets.length}',
                'skipped': '${errors.length}',
                'path': directory.absolute.path,
                'names': _entryNames(
                  targets.map((target) => target.entry).toList(),
                ),
              },
            ) +
            (errors.isEmpty
                ? ''
                : '\n\n${_tr('Bỏ qua:\n{errors}', {'errors': errors.join('\n')})}'),
        action: _tr('Tải {count} file', {'count': '${targets.length}'}),
      );
      if (!confirmed || !mounted) return;
      final manager = ref.read(sessionManagerProvider.notifier);
      var submitted = 0;
      for (final target in targets) {
        if (!_atLocation(location) || widget.tab.sftpLoading) {
          errors.add(
            _tr('{name}: phiên hoặc thư mục đã thay đổi.', {
              'name': target.entry.name,
            }),
          );
          continue;
        }
        try {
          // Check again after confirmation, including dangling symlinks.
          if (await _localPathAccess.entryExists(target.localPath)) {
            errors.add(
              _tr('{name}: đích vừa xuất hiện; đã bỏ qua.', {
                'name': target.entry.name,
              }),
            );
            continue;
          }
          if (!_atLocation(location) || widget.tab.sftpLoading) {
            errors.add(
              _tr('{name}: phiên hoặc thư mục đã thay đổi.', {
                'name': target.entry.name,
              }),
            );
            continue;
          }
          await manager.enqueueTransfer(
            localKey: location.key,
            isUpload: false,
            localPath: target.localPath,
            remotePath: target.entry.path,
            fileName: target.entry.name,
          );
          submitted++;
        } catch (error) {
          errors.add('${target.entry.name}: $error');
        }
      }
      await _batchResult(
        _tr('Yêu cầu tải về'),
        _tr(
          'Đã gửi {count} yêu cầu tải file. Xem tiến độ và lỗi truyền trong Transfers.',
          {'count': '$submitted'},
        ),
        errors,
      );
    });
  }

  Future<void> _editPermissions(SftpEntryDto entry) async {
    if (_busy || !_canUseSftp) return;
    final location = _location;
    final mode = await showDialog<int>(
      context: context,
      builder: (_) => _PermissionsDialog(entry: entry),
    );
    if (mode == null || !_atLocation(location) || widget.tab.sftpLoading) {
      return;
    }
    if (mode == (entry.permissions & 0xfff)) return;
    await _runFileAction(() async {
      await ref
          .read(backendProvider)
          .sftpSetPermissions(location.session, entry.path, mode);
      if (_atLocation(location)) {
        await ref
            .read(sessionManagerProvider.notifier)
            .loadSftpDirectory(location.key, location.cwd);
      }
    });
  }

  Future<void> _uploadFile(FileSystemEntity file, String name) async {
    final remotePath = widget.tab.cwd == '/'
        ? '/$name'
        : '${widget.tab.cwd}/$name';
    await _runFileAction(() async {
      final manager = ref.read(sessionManagerProvider.notifier);
      final confirmed = await _confirm(
        title: _tr('Tải file lên server?'),
        message: _tr(
          '{local}\n→ {remote}\nFile cùng tên trên server sẽ được ghi đè.',
          {'local': file.path, 'remote': remotePath},
        ),
        action: _tr('Tải lên'),
      );
      if (!mounted || !confirmed) return;
      await manager.enqueueTransfer(
        localKey: widget.tab.localKey,
        isUpload: true,
        localPath: file.path,
        remotePath: remotePath,
        fileName: name,
      );
      _showMessage(_tr('Đã thêm {name} vào hàng đợi tải lên.', {'name': name}));
    });
  }

  (IconData, Color) _iconForEntry(
    String name,
    bool isDir,
    TermPulsePalette tp,
  ) {
    if (isDir) return (Icons.folder_rounded, tp.cyan);
    final lower = name.toLowerCase();
    if (lower.endsWith('.conf') ||
        lower.endsWith('.toml') ||
        lower.endsWith('.env') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml')) {
      return (Icons.tune_rounded, tp.accent);
    }
    if (lower.endsWith('.rs') ||
        lower.endsWith('.dart') ||
        lower.endsWith('.py') ||
        lower.endsWith('.sh') ||
        lower.endsWith('.js')) {
      return (Icons.code_rounded, tp.green);
    }
    if (lower.endsWith('.log') || lower.endsWith('.txt')) {
      return (Icons.article_outlined, tp.amber);
    }
    return (Icons.description_outlined, tp.muted);
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final mgr = ref.read(sessionManagerProvider.notifier);
    final s = ref.s;
    final tp = context.tp;
    final showCommander = _commanderMode && !widget.compact;

    return Container(
      decoration: BoxDecoration(
        color: tp.surface,
        border: widget.compact
            ? null
            : Border(left: BorderSide(color: tp.border)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: widget.compact ? tp.surface : tp.surface2,
              border: Border(bottom: BorderSide(color: tp.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_shared_rounded, size: 17, color: tp.accent),
                const SizedBox(width: 6),
                const Text(
                  'SFTP',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _canUseSftp
                          ? () => mgr.toggleFollowSftp(tab.localKey)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: tab.followSftpEnabled
                              ? tp.accentContainer
                              : tp.bg,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: tab.followSftpEnabled
                                ? tp.accent.withValues(alpha: 0.45)
                                : tp.border,
                          ),
                        ),
                        child: Text(
                          tab.followSftpEnabled ? s.sftpFollow : s.sftpManual,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: tab.followSftpEnabled ? tp.accent : tp.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!widget.compact)
                  IconButton(
                    tooltip: _commanderMode
                        ? s.sftpOnePaneTooltip
                        : s.sftpCommanderTooltip,
                    icon: Icon(
                      _commanderMode
                          ? Icons.view_sidebar_rounded
                          : Icons.view_column_rounded,
                      size: 17,
                      color: _commanderMode ? tp.accent : tp.muted,
                    ),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: _toggleCommander,
                  ),
                IconButton(
                  tooltip: s.mkdirTooltip,
                  icon: const Icon(Icons.create_new_folder_rounded, size: 17),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: !_canUseSftp || _busy || tab.sftpLoading
                      ? null
                      : _promptMkdir,
                ),
                IconButton(
                  tooltip: s.refreshTooltip,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: !_canUseSftp || _busy || tab.sftpLoading
                      ? null
                      : () => mgr.loadSftpDirectory(tab.localKey, tab.cwd),
                ),
              ],
            ),
          ),

          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (!showCommander)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: tp.bg,
                border: Border(bottom: BorderSide(color: tp.border)),
              ),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap:
                        !_canUseSftp ||
                            _busy ||
                            tab.sftpLoading ||
                            tab.cwd == '/'
                        ? null
                        : () {
                            final idx = tab.cwd.lastIndexOf('/');
                            final parent = idx <= 0
                                ? '/'
                                : tab.cwd.substring(0, idx);
                            mgr.loadSftpDirectory(
                              tab.localKey,
                              parent,
                              syncTerminal: true,
                            );
                          },
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: tp.surface2,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: 14,
                        color: tp.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tab.cwd,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: tp.cyan,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (tab.sftpUnavailableReason != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: tp.amber.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tp.amber.withValues(alpha: 0.4)),
              ),
              child: Text(
                _tr('SFTP không khả dụng: {error}', {
                  'error': _tr(tab.sftpUnavailableReason!),
                }),
                style: TextStyle(fontSize: 12, color: tp.amber),
              ),
            ),

          if (tab.sftpError != null && tab.sftpEntries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 17, color: tp.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: _tr(tab.sftpError!),
                      child: Text(
                        _tr(tab.sftpError!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tp.red, fontSize: 12),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _tr('Thử tải lại thư mục'),
                    onPressed: tab.sftpLoading || _busy
                        ? null
                        : () => mgr.loadSftpDirectory(tab.localKey, tab.cwd),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                  ),
                ],
              ),
            ),

          Expanded(
            child: Row(
              children: [
                if (showCommander) ...[
                  Expanded(child: _buildLocalCommanderPane(tab, tp)),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: Column(
                    children: [
                      if (showCommander)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: tp.bg,
                            border: Border(
                              bottom: BorderSide(color: tp.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              InkWell(
                                onTap:
                                    !_canUseSftp ||
                                        _busy ||
                                        tab.sftpLoading ||
                                        tab.cwd == '/'
                                    ? null
                                    : () {
                                        final idx = tab.cwd.lastIndexOf('/');
                                        final parent = idx <= 0
                                            ? '/'
                                            : tab.cwd.substring(0, idx);
                                        mgr.loadSftpDirectory(
                                          tab.localKey,
                                          parent,
                                          syncTerminal: true,
                                        );
                                      },
                                child: Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 14,
                                  color: tp.cyan,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'REMOTE: ${tab.cwd}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: tp.cyan,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      _buildRemoteTools(tp),
                      Expanded(child: _buildRemoteList(tab, mgr, tp)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteTools(TermPulsePalette tp) {
    final enabled =
        _canUseSftp &&
        !_busy &&
        !widget.tab.sftpLoading &&
        widget.tab.sftpError == null;
    final entries = _visibleEntries;
    final selected = _selectedEntries;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tp.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('sftpFilterField'),
                  controller: _filterController,
                  enabled: _canUseSftp && !_busy,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: _tr('Lọc tên file…'),
                    prefixIcon: const Icon(Icons.search_rounded, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: _tr('Xoá bộ lọc'),
                            icon: const Icon(Icons.close_rounded, size: 15),
                            onPressed: () => setState(() {
                              _filterController.clear();
                              _filter = '';
                            }),
                          ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                  onChanged: (value) => setState(() {
                    _filter = value;
                    _pruneFilteredSelection();
                  }),
                ),
              ),
              PopupMenuButton<_RemoteSort>(
                key: const Key('sftpSortMenu'),
                tooltip: _tr('Sắp xếp: {sort}', {'sort': _tr(_sort.label)}),
                enabled: _canUseSftp && !_busy,
                initialValue: _sort,
                onSelected: (value) => setState(() => _sort = value),
                icon: const Icon(Icons.sort_rounded, size: 18),
                itemBuilder: (_) => [
                  for (final sort in _RemoteSort.values)
                    CheckedPopupMenuItem(
                      value: sort,
                      checked: sort == _sort,
                      child: Text(_tr(sort.label)),
                    ),
                ],
              ),
              IconButton(
                key: const Key('sftpShowHidden'),
                tooltip: _showHidden ? _tr('Ẩn file ẩn') : _tr('Hiện file ẩn'),
                isSelected: _showHidden,
                onPressed: !_canUseSftp || _busy
                    ? null
                    : () => setState(() {
                        _showHidden = !_showHidden;
                        _pruneFilteredSelection();
                      }),
                icon: const Icon(Icons.visibility_off_outlined, size: 18),
                selectedIcon: const Icon(Icons.visibility_outlined, size: 18),
              ),
              IconButton(
                key: const Key('sftpSelectionMode'),
                tooltip: _selecting
                    ? _tr('Thoát chọn nhiều')
                    : _tr('Chọn nhiều mục'),
                isSelected: _selecting,
                onPressed: !enabled
                    ? null
                    : () => setState(() {
                        _selecting = !_selecting;
                        _selectedPaths.clear();
                      }),
                icon: const Icon(Icons.checklist_rounded, size: 18),
              ),
            ],
          ),
          if (_selecting)
            Row(
              children: [
                Checkbox(
                  key: const Key('sftpSelectAll'),
                  value: selected.isEmpty
                      ? false
                      : selected.length == entries.length
                      ? true
                      : null,
                  tristate: true,
                  onChanged: !enabled || entries.isEmpty
                      ? null
                      : (_) => setState(() {
                          if (selected.length == entries.length) {
                            _selectedPaths.clear();
                          } else {
                            _selectedPaths.addAll(entries.map((e) => e.path));
                          }
                        }),
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(
                    _tr('{selected}/{total} mục đã chọn', {
                      'selected': '${selected.length}',
                      'total': '${entries.length}',
                    }),
                    style: TextStyle(fontSize: 11, color: tp.muted),
                  ),
                ),
                IconButton(
                  key: const Key('sftpDownloadSelected'),
                  tooltip: _tr('Tải các file đã chọn'),
                  onPressed: enabled && selected.isNotEmpty
                      ? _downloadSelected
                      : null,
                  icon: const Icon(Icons.download_rounded, size: 19),
                ),
                IconButton(
                  key: const Key('sftpDeleteSelected'),
                  tooltip: _tr('Xoá các mục đã chọn'),
                  onPressed: enabled && selected.isNotEmpty
                      ? _deleteSelected
                      : null,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: tp.red,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRemoteList(
    TerminalSessionTab tab,
    SessionManagerController mgr,
    TermPulsePalette tp,
  ) {
    if (!_canUseSftp) {
      return _directoryState(
        icon: Icons.folder_off_outlined,
        title: _tr('Chưa thể duyệt file'),
        detail: tab.protocol == 'ssh'
            ? tab.sftpUnavailableReason != null
                  ? _tr('Server cần bật SFTP subsystem để xem và truyền file.')
                  : _tr('Kết nối SSH để xem và truyền file.')
            : _tr('SFTP chỉ khả dụng trong phiên SSH.'),
      );
    }
    if (tab.sftpLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.sftpEntries.isEmpty) {
      return _directoryState(
        icon: tab.sftpError == null
            ? Icons.folder_open_rounded
            : Icons.cloud_off_rounded,
        title: tab.sftpError == null
            ? _tr('Thư mục trống')
            : _tr('Không tải được nội dung thư mục'),
        detail:
            (tab.sftpError == null ? null : _tr(tab.sftpError!)) ??
            _tr('Tạo thư mục mới hoặc bật chế độ 2 ngăn để tải file lên.'),
        actionLabel: tab.sftpError == null
            ? _tr('Tạo thư mục')
            : _tr('Thử lại'),
        onAction: _busy
            ? null
            : tab.sftpError == null
            ? _promptMkdir
            : () => mgr.loadSftpDirectory(tab.localKey, tab.cwd),
      );
    }
    final entries = _visibleEntries;
    if (entries.isEmpty) {
      return _directoryState(
        icon: Icons.filter_alt_off_outlined,
        title: _tr('Không có mục phù hợp'),
        detail: _tr('Đổi bộ lọc tên hoặc bật hiển thị file ẩn.'),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final e = entries[i];
        final (iconData, tint) = _iconForEntry(e.name, e.isDir, tp);
        return ListTile(
          key: ValueKey('sftpEntry:${e.path}'),
          selected: _selectedPaths.contains(e.path),
          dense: true,
          contentPadding: const EdgeInsets.only(left: 10, right: 2),
          visualDensity: VisualDensity.compact,
          leading: _selecting
              ? Checkbox(
                  key: ValueKey('sftpSelect:${e.path}'),
                  value: _selectedPaths.contains(e.path),
                  onChanged: _busy ? null : (_) => _toggleSelection(e),
                  visualDensity: VisualDensity.compact,
                )
              : Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tint.withValues(alpha: 0.25)),
                  ),
                  child: Icon(iconData, size: 16, color: tint),
                ),
          title: Text(
            e.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              fontWeight: e.isDir ? FontWeight.w700 : FontWeight.w600,
              color: e.isDir ? tp.cyan : tp.ink,
            ),
          ),
          subtitle: Text(
            e.isDir
                ? _tr('Thư mục · {mode}', {
                    'mode': (e.permissions & 0xfff)
                        .toRadixString(8)
                        .padLeft(3, '0'),
                  })
                : '${_readableSize(e.size)} · ${(e.permissions & 0xfff).toRadixString(8).padLeft(3, '0')}${e.isSymlink ? ' · ${_tr('Liên kết')}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: tp.muted),
          ),
          onTap: _busy
              ? null
              : _selecting
              ? () => _toggleSelection(e)
              : () {
                  if (e.isDir) {
                    mgr.loadSftpDirectory(
                      tab.localKey,
                      e.path,
                      syncTerminal: true,
                    );
                  } else if (tab.sessionId != null) {
                    showRemoteFileEditor(
                      context,
                      ref,
                      sessionId: tab.sessionId!,
                      remotePath: e.path,
                    );
                  }
                },
          onLongPress: _busy ? null : () => _toggleSelection(e),
          trailing: PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: _tr('Thao tác file'),
            iconSize: 16,
            padding: EdgeInsets.zero,
            onSelected: (act) async {
              if (!_canUseSftp || _busy) return;
              if (act == 'edit') {
                await showRemoteFileEditor(
                  context,
                  ref,
                  sessionId: tab.sessionId!,
                  remotePath: e.path,
                );
              } else if (act == 'download') {
                await _downloadEntry(e);
              } else if (act == 'rename') {
                await _promptRename(e);
              } else if (act == 'delete') {
                await _deleteEntry(e);
              } else if (act == 'permissions') {
                await _editPermissions(e);
              }
            },
            itemBuilder: (_) => [
              if (!e.isDir)
                PopupMenuItem(
                  value: 'edit',
                  child: Text(_tr('Mở trình sửa file')),
                ),
              if (!e.isDir)
                PopupMenuItem(
                  value: 'download',
                  child: Text(_tr('Tải về máy…')),
                ),
              PopupMenuItem(value: 'rename', child: Text(_tr('Đổi tên…'))),
              if (!e.isSymlink)
                PopupMenuItem(
                  value: 'permissions',
                  child: Text(_tr('Quyền truy cập…')),
                ),
              PopupMenuItem(
                value: 'delete',
                child: Text(ref.s.delete, style: TextStyle(color: tp.red)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocalCommanderPane(TerminalSessionTab tab, TermPulsePalette tp) {
    final dir = Directory(_localDir);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: tp.bg,
            border: Border(bottom: BorderSide(color: tp.border)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: _tr('Thư mục cha trên máy này'),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: _localLoading || dir.parent.path == _localDir
                    ? null
                    : () => _loadLocalDirectory(dir.parent.path),
                icon: Icon(
                  Icons.arrow_upward_rounded,
                  size: 14,
                  color: tp.amber,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _tr('LOCAL: {path}', {'path': _localDir}),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: tp.amber,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _localLoading
              ? const Center(child: CircularProgressIndicator())
              : _localError != null
              ? _directoryState(
                  icon: Icons.folder_off_outlined,
                  title: _tr('Không đọc được thư mục trên máy'),
                  detail: _tr(_localError!),
                  actionLabel: _tr('Thử lại'),
                  onAction: () => _loadLocalDirectory(_localDir),
                )
              : _localEntries.isEmpty
              ? _directoryState(
                  icon: Icons.folder_open_rounded,
                  title: _tr('Thư mục trống'),
                  detail: _tr(
                    'Chọn thư mục khác hoặc làm mới sau khi thêm file.',
                  ),
                  actionLabel: _tr('Làm mới'),
                  onAction: () => _loadLocalDirectory(_localDir),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _localEntries.length,
                  itemBuilder: (_, i) {
                    final ent = _localEntries[i];
                    final isDir = ent is Directory;
                    final name =
                        ent.uri.pathSegments
                            .where((s) => s.isNotEmpty)
                            .lastOrNull ??
                        ent.path;
                    final (iconData, tint) = isDir
                        ? (Icons.folder_rounded, tp.amber)
                        : _iconForEntry(name, false, tp);
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      visualDensity: VisualDensity.compact,
                      leading: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(iconData, size: 14, color: tint),
                      ),
                      title: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      trailing: isDir
                          ? const Icon(Icons.chevron_right_rounded, size: 18)
                          : Tooltip(
                              message: _tr('Tải file lên server'),
                              child: Icon(
                                Icons.upload_rounded,
                                size: 16,
                                color: _canUseSftp ? tp.accent : tp.muted,
                              ),
                            ),
                      onTap: !isDir && (!_canUseSftp || _busy)
                          ? null
                          : () {
                              if (isDir) {
                                _loadLocalDirectory(ent.path);
                              } else {
                                _uploadFile(ent, name);
                              }
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _PermissionsDialog extends StatefulWidget {
  final SftpEntryDto entry;
  const _PermissionsDialog({required this.entry});

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late int _mode;
  late final TextEditingController _controller;
  bool _valid = true;

  @override
  void initState() {
    super.initState();
    _mode = widget.entry.permissions & 0xfff;
    _controller = TextEditingController(text: _octal);
  }

  String get _octal => _mode.toRadixString(8).padLeft(3, '0');

  void _setBit(int bit, bool value) => setState(() {
    _mode = value ? _mode | bit : _mode & ~bit;
    _controller.text = _octal;
    _valid = true;
  });

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('Quyền truy cập')),
      content: SizedBox(
        width: 370,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.entry.path,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('sftpPermissionMode'),
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.tr('Mã bát phân (000–7777)'),
                  hintText: context.tr('Ví dụ: 644 hoặc 755'),
                  errorText: _valid
                      ? null
                      : context.tr('Nhập 3 hoặc 4 chữ số từ 0 đến 7.'),
                ),
                onChanged: (text) => setState(() {
                  _valid = RegExp(r'^[0-7]{3,4}$').hasMatch(text);
                  if (_valid) _mode = int.parse(text, radix: 8);
                }),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(flex: 2, child: SizedBox()),
                  for (final label in [
                    context.tr('Đọc'),
                    context.tr('Ghi'),
                    context.tr('Chạy'),
                  ])
                    Expanded(
                      child: Center(
                        child: Text(
                          label,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
              for (final row in [
                (context.tr('Chủ sở hữu'), 6),
                (context.tr('Nhóm'), 3),
                (context.tr('Người khác'), 0),
              ])
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(row.$1, style: const TextStyle(fontSize: 12)),
                    ),
                    for (final permission in [
                      (context.tr('Đọc'), 4),
                      (context.tr('Ghi'), 2),
                      (context.tr('Chạy'), 1),
                    ])
                      Expanded(
                        child: Tooltip(
                          message: '${row.$1}: ${permission.$1}',
                          child: Checkbox(
                            key: ValueKey(
                              'sftpPermission:${row.$2}:${permission.$2}',
                            ),
                            value: (_mode & (permission.$2 << row.$2)) != 0,
                            onChanged: (value) =>
                                _setBit(permission.$2 << row.$2, value!),
                          ),
                        ),
                      ),
                  ],
                ),
              Text(
                widget.entry.isDir
                    ? context.tr(
                        'Với thư mục, quyền Chạy cho phép truy cập nội dung bên trong.',
                      )
                    : context.tr(
                        'Quyền Chạy cho phép thực thi file trên server.',
                      ),
                style: TextStyle(fontSize: 11, color: context.tp.muted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final special in [
                    ('Setuid', 0x800),
                    ('Setgid', 0x400),
                    ('Sticky', 0x200),
                  ])
                    FilterChip(
                      label: Text(special.$1),
                      selected: (_mode & special.$2) != 0,
                      onSelected: (value) => _setBit(special.$2, value),
                    ),
                ],
              ),
              Text(
                context.tr(
                  'Chỉ áp dụng cho mục này; không thay đổi chủ sở hữu hoặc các mục con.',
                ),
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Huỷ')),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.of(context).pop(_mode) : null,
          child: Text(context.tr('Áp dụng quyền')),
        ),
      ],
    );
  }
}
