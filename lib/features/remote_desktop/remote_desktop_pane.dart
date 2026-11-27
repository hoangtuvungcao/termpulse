import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_touchpad.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

class RemoteDesktopPane extends ConsumerStatefulWidget {
  final RemoteDesktopSession session;
  final VoidCallback onFocus;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  const RemoteDesktopPane({
    super.key,
    required this.session,
    required this.onFocus,
    this.fullscreen = false,
    this.onToggleFullscreen,
  });

  @override
  ConsumerState<RemoteDesktopPane> createState() => _RemoteDesktopPaneState();
}

class _RemoteDesktopPaneState extends ConsumerState<RemoteDesktopPane> {
  final _focus = FocusNode(debugLabel: 'remote desktop keyboard');
  final _transform = TransformationController();
  final _renderedImage = ValueNotifier<ui.Image?>(null);
  final _cursor = ValueNotifier<Offset>(Offset.zero);
  late final RemoteDesktopTouchpad _touchpad;
  final Map<PhysicalKeyboardKey, (int, bool)> _pressed = {};
  ui.Image? _image;
  bool _decoding = false;
  int _decodedSequence = -1;
  int _decodeGeneration = 0;
  bool _fit = true;
  bool _needsInitialView = true;
  bool _pan = false;
  bool _viewOnly = false;
  bool _checkingCertificate = false;
  Size? _viewport;
  int _buttons = 0;
  String? _inputSessionId;
  Offset _lastPosition = Offset.zero;
  Timer? _pointerTimer;
  Object? _presentation;

  RemoteDesktopSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _touchpad = RemoteDesktopTouchpad(
      onMove: _moveCursor,
      onButton: _touchButton,
      onTransform: _touchTransform,
    );
    _session.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(covariant RemoteDesktopPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != _session) {
      _releaseKeys(oldWidget.session);
      oldWidget.session.removeListener(_changed);
      ++_decodeGeneration;
      _decodedSequence = -1;
      _needsInitialView = true;
      final previous = _image;
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
      _image = null;
      _renderedImage.value = null;
      _session.addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_inputSessionId != _session.sessionId || !_session.connected) {
      // A reconnect must not release keys that belonged to the old connection
      // into the new one, or deliver a delayed pointer movement to it.
      _touchpad.cancel(release: false);
      _pressed.clear();
      _buttons = 0;
      _pointerTimer?.cancel();
      _inputSessionId = _session.sessionId;
    }
    final frame = _session.frame;
    if (frame == null && (_image != null || _decoding)) {
      final previous = _image;
      _image = null;
      _renderedImage.value = null;
      _decodedSequence = -1;
      ++_decodeGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    }
    if (!_decoding && frame != null && frame.sequence != _decodedSequence) {
      _decoding = true;
      final generation = _decodeGeneration;
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (image) {
          _decoding = false;
          if (!mounted || generation != _decodeGeneration) {
            image.dispose();
            if (mounted) _changed();
            return;
          }
          final previous = _image;
          final resized =
              previous?.width != image.width ||
              previous?.height != image.height;
          _image = image;
          _decodedSequence = frame.sequence;
          if (resized) {
            _cursor.value = Offset(image.width / 2, image.height / 2);
            _lastPosition = _cursor.value;
          }
          _renderedImage.value = image;
          if (resized) {
            setState(() {});
            _updateView();
          }
          // The preceding frame may still be used by the render tree this frame.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => previous?.dispose(),
          );
          if (_session.frame?.sequence != _decodedSequence) _changed();
        },
      );
    }
    final presentation = (
      _session.sessionId,
      _session.connected,
      _session.closed,
      _session.message,
      _session.host.label,
    );
    if (_presentation != presentation) {
      _presentation = presentation;
      setState(() {});
    }
  }

  void _updateView() {
    if (_image == null || _viewport == null) return;
    if (_needsInitialView) {
      _needsInitialView = false;
      // On a phone, fitting the entire Windows desktop makes text microscopic.
      // Start at readable pixel size; the touchpad follows the cursor as needed.
      final platform = Theme.of(context).platform;
      final phone =
          (platform == TargetPlatform.android ||
              platform == TargetPlatform.iOS) &&
          MediaQuery.sizeOf(context).shortestSide < 600;
      _fit = !phone || _image!.width <= _viewport!.width;
      if (!_fit) {
        _setScale(1, center: true);
        return;
      }
    }
    if (_fit) {
      _fitImage();
    } else {
      _revealCursor();
    }
  }

  // This is an axis-aligned 2D transform. Its unchanged Z axis is always 1,
  // so getMaxScaleOnAxis would incorrectly report 100% whenever we zoom out.
  double get _scale => _transform.value.storage[0].abs();

  double get _minimumScale {
    final image = _image;
    final viewport = _viewport;
    if (image == null || viewport == null) return .05;
    return math
        .min(viewport.width / image.width, viewport.height / image.height)
        .clamp(.05, 1.0);
  }

  void _setScale(double value, {bool center = false}) {
    final viewport = _viewport;
    if (viewport == null || _image == null) return;
    _fit = false;
    final scale = value.clamp(_minimumScale, 4.0);
    final anchor = center
        ? viewport.center(Offset.zero)
        : MatrixUtils.transformPoint(_transform.value, _cursor.value);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        anchor.dx - _cursor.value.dx * scale,
        anchor.dy - _cursor.value.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
    _clampView();
  }

  void _clampView() {
    final viewport = _viewport;
    final image = _image;
    if (viewport == null || image == null) return;
    final scale = _scale;
    final translation = _transform.value.getTranslation();
    double clampAxis(double offset, double extent, double available) =>
        extent <= available
        ? (available - extent) / 2
        : offset.clamp(available - extent, 0).toDouble();
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        clampAxis(translation.x, image.width * scale, viewport.width),
        clampAxis(translation.y, image.height * scale, viewport.height),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _revealCursor() {
    final viewport = _viewport;
    if (viewport == null) return;
    final point = MatrixUtils.transformPoint(_transform.value, _cursor.value);
    final margin = math.min(48.0, viewport.shortestSide / 4);
    final dx = point.dx < margin
        ? margin - point.dx
        : point.dx > viewport.width - margin
        ? viewport.width - margin - point.dx
        : 0.0;
    final dy = point.dy < margin
        ? margin - point.dy
        : point.dy > viewport.height - margin
        ? viewport.height - margin - point.dy
        : 0.0;
    if (dx != 0 || dy != 0) {
      final matrix = _transform.value.clone();
      matrix.setTranslationRaw(
        matrix.storage[12] + dx,
        matrix.storage[13] + dy,
        0,
      );
      _transform.value = matrix;
    }
    _clampView();
  }

  void _moveCursor(Offset delta) {
    _cursor.value = _position(_cursor.value + delta / _scale);
    _lastPosition = _cursor.value;
    _revealCursor();
    if (_pointerTimer?.isActive != true) {
      _pointerTimer = Timer(const Duration(milliseconds: 12), _sendPointer);
    }
  }

  void _touchButton(int button, bool down) {
    _pointerTimer?.cancel();
    _lastPosition = _cursor.value;
    _buttons = down ? button : 0;
    _sendPointer();
  }

  void _touchTransform(Offset previousFocal, Offset focal, double factor) {
    final viewportContext = _viewportKey.currentContext;
    final box = viewportContext?.findRenderObject();
    if (box is! RenderBox) return;
    _fit = false;
    final previous = box.globalToLocal(previousFocal);
    final next = box.globalToLocal(focal);
    final scene = _transform.toScene(previous);
    final scale = (_scale * factor).clamp(_minimumScale, 4.0);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        next.dx - scene.dx * scale,
        next.dy - scene.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
    _clampView();
  }

  final _viewportKey = GlobalKey();

  void _fitImage() {
    final image = _image;
    final viewport = _viewport;
    if (image == null || viewport == null) return;
    final scale = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (viewport.width - image.width * scale) / 2,
        (viewport.height - image.height * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _releaseKeys([RemoteDesktopSession? session]) {
    _touchpad.cancel(release: false);
    _pointerTimer?.cancel();
    final target = session ?? _session;
    for (final entry in _pressed.values) {
      unawaited(target.key(entry.$1, false, unicode: entry.$2));
    }
    _pressed.clear();
    if (_buttons != 0) {
      _buttons = 0;
      unawaited(
        target.pointer(_lastPosition.dx.round(), _lastPosition.dy.round(), 0),
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_viewOnly || _pan || !_session.connected) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed) {
      _releaseKeys();
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      final pressed = _pressed.remove(event.physicalKey);
      if (pressed != null) {
        unawaited(_session.key(pressed.$1, false, unicode: pressed.$2));
      }
      return KeyEventResult.handled;
    }
    final character = event.character;
    final modified =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!modified &&
        character != null &&
        character.runes.length == 1 &&
        character.runes.first >= 32 &&
        character.runes.first != 127) {
      final rune = character.runes.first;
      // Unicode events preserve the user's actual keyboard language/layout.
      final previous = _pressed[event.physicalKey];
      if (previous != null && previous != (rune, true)) {
        unawaited(_session.key(previous.$1, false, unicode: previous.$2));
      }
      _pressed[event.physicalKey] = (rune, true);
      unawaited(_session.key(rune, true, unicode: true));
      return KeyEventResult.handled;
    }
    final key = _session.host.protocol == 'rdp'
        ? desktopScanCodes[event.physicalKey.usbHidUsage]
        : desktopKeysyms[event.logicalKey.keyId];
    if (key != null) {
      final previous = _pressed[event.physicalKey];
      if (previous != null && previous != (key, false)) {
        unawaited(_session.key(previous.$1, false, unicode: previous.$2));
      }
      _pressed[event.physicalKey] = (key, false);
      unawaited(_session.key(key, true));
    } else if (character != null && character.isNotEmpty && !modified) {
      unawaited(_session.typeText(character));
    }
    return KeyEventResult.handled;
  }

  Offset _position(Offset local) => Offset(
    local.dx.clamp(0, math.max(0, (_image?.width ?? 1) - 1)).toDouble(),
    local.dy.clamp(0, math.max(0, (_image?.height ?? 1) - 1)).toDouble(),
  );

  void _pointer(PointerEvent event) {
    if (_viewOnly || _pan || !_session.connected) return;
    if (event is PointerDownEvent) {
      widget.onFocus();
      _focus.requestFocus();
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touchpad.add(event);
      return;
    }
    _lastPosition = _position(_transform.toScene(event.localPosition));
    _cursor.value = _lastPosition;
    final buttons =
        ((event.buttons & kPrimaryMouseButton != 0 ? 1 : 0) |
        (event.buttons & kMiddleMouseButton != 0 ? 2 : 0) |
        (event.buttons & kSecondaryMouseButton != 0 ? 4 : 0));
    final changed = buttons != _buttons;
    _buttons = buttons;
    if (event is PointerMoveEvent || event is PointerHoverEvent) {
      if (!changed && _pointerTimer?.isActive == true) return;
      _pointerTimer?.cancel();
      _pointerTimer = Timer(const Duration(milliseconds: 12), _sendPointer);
    } else {
      _pointerTimer?.cancel();
      _sendPointer();
    }
  }

  void _sendPointer() => unawaited(
    _session.pointer(
      _lastPosition.dx.round(),
      _lastPosition.dy.round(),
      _buttons,
    ),
  );

  Future<void> _secureAttention() async {
    _releaseKeys();
    final session = _session;
    final sessionId = session.sessionId;
    final keys = session.host.protocol == 'rdp'
        ? [0x1d, 0x38, 0x153]
        : [0xffe3, 0xffe9, 0xffff];
    for (final key in keys) {
      if (!mounted || session != _session || session.sessionId != sessionId) {
        return;
      }
      await session.key(key, true);
    }
    for (final key in keys.reversed) {
      if (!mounted || session != _session || session.sessionId != sessionId) {
        return;
      }
      await session.key(key, false);
    }
    if (mounted) _focus.requestFocus();
  }

  Future<void> _typeText() async {
    _releaseKeys();
    final session = _session;
    final sessionId = session.sessionId;
    final controller = TextEditingController();
    final route = DialogRoute<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        alignment: Alignment.center,
        scrollable: true,
        title: Text(dialogContext.tr('Gõ văn bản vào máy từ xa')),
        content: SizedBox(
          width: 460,
          child: TextField(
            key: const Key('remoteDesktopTextInput'),
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: dialogContext.tr(
                'Nhập hoặc dán văn bản. Chỉ gửi khi bấm Gửi.',
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.tr('Huỷ')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(dialogContext.tr('Gửi')),
          ),
        ],
      ),
    );
    final text = await Navigator.of(context).push(route);
    unawaited(route.completed.then((_) => controller.dispose()));
    if (text != null &&
        mounted &&
        session == _session &&
        session.sessionId == sessionId) {
      await session.typeText(text);
    }
  }

  Future<void> _verifyCertificate() async {
    if (_checkingCertificate) return;
    setState(() => _checkingCertificate = true);
    try {
      final host = (await ref.read(backendProvider).listHosts())
          .where((h) => h.id == _session.host.id)
          .firstOrNull;
      if (!mounted) return;
      if (host == null || host.protocol != 'rdp') {
        throw StateError(
          'Kết nối đã bị xóa hoặc đổi giao thức. Hãy mở lại từ danh sách host.',
        );
      }
      final options = _desktopOptions(host);
      final name = options['tls_server_name'] as String?;
      final fingerprint = await _session.backend.probeCertificate(
        host.hostname,
        host.port,
        name?.isEmpty == true ? null : name,
      );
      if (!mounted) return;
      final controller = TextEditingController();
      final route = DialogRoute<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            final matches =
                controller.text.trim().toLowerCase() ==
                fingerprint.toLowerCase();
            return AlertDialog(
              title: Text(context.tr('Xác minh chứng chỉ RDP')),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${host.hostname}:${host.port}'),
                      const SizedBox(height: 12),
                      Text(
                        context.tr(
                          'Đối chiếu dấu vân tay SHA256 với quản trị viên qua kênh tin cậy. Không tiếp tục nếu không khớp.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(fingerprint),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('rdpCertificateConfirmation'),
                        controller: controller,
                        onChanged: (_) => update(() {}),
                        decoration: InputDecoration(
                          labelText: context.tr('Nhập dấu vân tay đã xác minh'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.tr('Huỷ')),
                ),
                FilledButton(
                  onPressed: matches
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: Text(context.tr('Tin cậy và kết nối lại')),
                ),
              ],
            );
          },
        ),
      );
      final approved = await Navigator.of(context).push(route);
      unawaited(route.completed.then((_) => controller.dispose()));
      if (approved != true || !mounted) return;
      final latest = (await ref.read(backendProvider).listHosts())
          .where((h) => h.id == host.id)
          .firstOrNull;
      if (!mounted) return;
      if (latest == null ||
          latest.protocol != host.protocol ||
          latest.hostname != host.hostname ||
          latest.port != host.port ||
          _desktopOptions(latest)['tls_server_name'] !=
              options['tls_server_name']) {
        throw StateError(
          'Kết nối đã thay đổi trong lúc xác minh. Hãy xác minh lại chứng chỉ.',
        );
      }
      final settings = _desktopOptions(latest)
        ..['tls_certificate_sha256'] = fingerprint;
      await ref
          .read(inventoryProvider.notifier)
          .saveHost(hostWithDesktopOptions(latest, jsonEncode(settings)));
      if (mounted) unawaited(_session.connect());
    } catch (error) {
      if (mounted) {
        showAppErrorSnackBar(context, 'Không xác minh được chứng chỉ: $error');
      }
    } finally {
      if (mounted) setState(() => _checkingCertificate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final session = _session;
    final error = presentAppError(
      AppLocalizationScope.of(context),
      session.message ?? 'Đang kết nối màn hình từ xa…',
    );
    final certificateError = (session.message ?? '').contains(
      'RDP_CERTIFICATE_UNTRUSTED:',
    );
    return ColoredBox(
      color: context.tp.terminalTheme.background,
      child: Column(
        children: [
          Material(
            color: context.tp.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    if (constraints.maxWidth >= 600) ...[
                      Icon(
                        session.host.protocol == 'rdp'
                            ? Icons.desktop_windows_outlined
                            : Icons.desktop_mac_outlined,
                        size: 19,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${session.host.protocol.toUpperCase()} · ${session.host.label}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    IconButton(
                      key: const Key('remoteDesktopFit'),
                      tooltip: context.tr('Vừa cửa sổ'),
                      onPressed: image == null
                          ? null
                          : () {
                              setState(() {
                                _fit = true;
                                _pan = false;
                              });
                              _fitImage();
                            },
                      icon: const Icon(Icons.fit_screen),
                    ),
                    IconButton(
                      key: const Key('remoteDesktopZoomOut'),
                      tooltip: context.tr('Thu nhỏ'),
                      onPressed: image == null
                          ? null
                          : () => _setScale(_scale / 1.3),
                      icon: const Icon(Icons.remove),
                    ),
                    SizedBox(
                      width: 42,
                      child: ValueListenableBuilder<Matrix4>(
                        valueListenable: _transform,
                        builder: (context, value, _) => Text(
                          '${(value.storage[0].abs() * 100).round()}%',
                          key: const Key('remoteDesktopScale'),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('remoteDesktopZoomIn'),
                      tooltip: context.tr('Phóng to'),
                      onPressed: image == null
                          ? null
                          : () => _setScale(_scale * 1.3),
                      icon: const Icon(Icons.add),
                    ),
                    if (constraints.maxWidth < 600) const Spacer(),
                    if (widget.onToggleFullscreen != null)
                      IconButton(
                        key: const Key('remoteDesktopFullscreen'),
                        tooltip: context.tr(
                          widget.fullscreen
                              ? 'Thoát toàn màn hình'
                              : 'Toàn màn hình',
                        ),
                        onPressed: widget.onToggleFullscreen,
                        icon: Icon(
                          widget.fullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: context.tr('Thao tác màn hình từ xa'),
                      onSelected: (action) {
                        switch (action) {
                          case 'actual':
                            _releaseKeys();
                            setState(() => _pan = false);
                            _setScale(1, center: true);
                          case 'pan':
                            _releaseKeys();
                            setState(() {
                              _pan = !_pan;
                              _fit = false;
                            });
                          case 'view':
                            _releaseKeys();
                            setState(() => _viewOnly = !_viewOnly);
                          case 'type':
                            unawaited(_typeText());
                          case 'sas':
                            unawaited(_secureAttention());
                          case 'reconnect':
                            unawaited(session.connect());
                          case 'disconnect':
                            unawaited(session.close());
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'actual',
                          enabled: image != null,
                          child: Text(context.tr('Kích thước thật (100%)')),
                        ),
                        CheckedPopupMenuItem(
                          value: 'pan',
                          checked: _pan,
                          enabled: image != null,
                          child: Text(context.tr('Thu phóng và kéo màn hình')),
                        ),
                        CheckedPopupMenuItem(
                          value: 'view',
                          checked: _viewOnly,
                          child: Text(context.tr('Chỉ xem')),
                        ),
                        PopupMenuItem(
                          value: 'type',
                          enabled: session.connected && !_viewOnly,
                          child: Text(context.tr('Gõ văn bản')),
                        ),
                        PopupMenuItem(
                          value: 'sas',
                          enabled: session.connected && !_viewOnly,
                          child: const Text('Ctrl+Alt+Del'),
                        ),
                        PopupMenuItem(
                          value: 'reconnect',
                          enabled: session.closed,
                          child: Text(context.tr('Kết nối lại')),
                        ),
                        PopupMenuItem(
                          value: 'disconnect',
                          enabled: !session.closed,
                          child: Text(context.tr('Ngắt kết nối')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (session.host.protocol == 'vnc')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                context.tr(
                  'VNC không mã hóa. Hãy dùng mạng tin cậy hoặc SSH/VPN tunnel.',
                ),
                style: TextStyle(color: context.tp.amber, fontSize: 11),
              ),
            ),
          Expanded(
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: _renderedImage,
              builder: (context, image, _) => image == null || session.closed
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!session.closed)
                              const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            SelectableText(
                              error.summary,
                              textAlign: TextAlign.center,
                            ),
                            if (error.details != null)
                              ErrorDetailsButton(details: error.details!),
                            if (session.closed) ...[
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  if (certificateError)
                                    FilledButton.icon(
                                      onPressed: _checkingCertificate
                                          ? null
                                          : _verifyCertificate,
                                      icon: const Icon(
                                        Icons.verified_user_outlined,
                                      ),
                                      label: Text(
                                        context.tr('Xác minh chứng chỉ'),
                                      ),
                                    ),
                                  OutlinedButton.icon(
                                    onPressed: () => session.connect(),
                                    icon: const Icon(Icons.refresh),
                                    label: Text(context.tr('Kết nối lại')),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.biggest;
                        if (_viewport != size) {
                          _viewport = size;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _updateView();
                          });
                        }
                        return Focus(
                          focusNode: _focus,
                          onKeyEvent: _onKey,
                          onFocusChange: (focused) {
                            if (!focused) _releaseKeys();
                          },
                          child: Listener(
                            key: const Key('remoteDesktopViewport'),
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _pointer,
                            onPointerMove: _pointer,
                            onPointerHover: _pointer,
                            onPointerUp: _pointer,
                            onPointerCancel: _pointer,
                            onPointerSignal: (event) {
                              if (event is PointerScrollEvent &&
                                  !_pan &&
                                  !_viewOnly) {
                                _lastPosition = _position(
                                  _transform.toScene(event.localPosition),
                                );
                                GestureBinding.instance.pointerSignalResolver
                                    .register(
                                      event,
                                      (_) => unawaited(
                                        session.pointer(
                                          _lastPosition.dx.round(),
                                          _lastPosition.dy.round(),
                                          _buttons,
                                          event.scrollDelta.dy.sign.toInt() *
                                              -120,
                                        ),
                                      ),
                                    );
                              }
                            },
                            child: ClipRect(
                              key: _viewportKey,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RepaintBoundary(
                                    child: InteractiveViewer(
                                      transformationController: _transform,
                                      constrained: false,
                                      minScale: 0.05,
                                      maxScale: 4,
                                      panEnabled: _pan,
                                      scaleEnabled: _pan,
                                      onInteractionStart: (_) {
                                        if (_pan) _fit = false;
                                      },
                                      child: Semantics(
                                        label: context.tr('Màn hình máy từ xa'),
                                        child: RawImage(
                                          image: image,
                                          width: image.width.toDouble(),
                                          height: image.height.toDouble(),
                                          filterQuality: FilterQuality.low,
                                        ),
                                      ),
                                    ),
                                  ),
                                  IgnorePointer(
                                    child: AnimatedBuilder(
                                      animation: Listenable.merge([
                                        _transform,
                                        _cursor,
                                      ]),
                                      builder: (context, _) => CustomPaint(
                                        key: const Key('remoteDesktopCursor'),
                                        painter: _RemoteCursorPainter(
                                          MatrixUtils.transformPoint(
                                            _transform.value,
                                            _cursor.value,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              context.tr(
                _viewOnly
                    ? 'Chế độ chỉ xem'
                    : _pan
                    ? 'Thu phóng và kéo màn hình'
                    : 'Vuốt để rê chuột · Chạm 1 ngón: trái · 2 ngón: phải',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: context.tp.muted),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _releaseKeys();
    _session.removeListener(_changed);
    _pointerTimer?.cancel();
    _touchpad.dispose();
    ++_decodeGeneration;
    _image?.dispose();
    _focus.dispose();
    _transform.dispose();
    _renderedImage.dispose();
    _cursor.dispose();
    super.dispose();
  }
}

class _RemoteCursorPainter extends CustomPainter {
  const _RemoteCursorPainter(this.position);
  final Offset position;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(position.dx, position.dy)
      ..relativeLineTo(0, 21)
      ..relativeLineTo(5, -5)
      ..relativeLineTo(4, 9)
      ..relativeLineTo(4, -2)
      ..relativeLineTo(-4, -9)
      ..relativeLineTo(8, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF101827)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_RemoteCursorPainter oldDelegate) =>
      position != oldDelegate.position;
}

Map<String, dynamic> _desktopOptions(HostDto host) {
  try {
    final value = jsonDecode(host.remoteDesktopJson ?? '{}');
    if (value is Map<String, dynamic>) return value;
  } catch (_) {}
  return {};
}

HostDto hostWithDesktopOptions(HostDto h, String json) => HostDto(
  id: h.id,
  groupId: h.groupId,
  label: h.label,
  protocol: h.protocol,
  hostname: h.hostname,
  port: h.port,
  identityMode: h.identityMode,
  identityId: h.identityId,
  identityNameRef: h.identityNameRef,
  jumpHostMode: h.jumpHostMode,
  jumpHostId: h.jumpHostId,
  proxyMode: h.proxyMode,
  proxyId: h.proxyId,
  colorHex: h.colorHex,
  icon: h.icon,
  envTag: h.envTag,
  tags: h.tags,
  notes: h.notes,
  startupDir: h.startupDir,
  startupCmd: h.startupCmd,
  env: h.env,
  followTerminalSftp: h.followTerminalSftp,
  wolMac: h.wolMac,
  wolBroadcast: h.wolBroadcast,
  serialBaudrate: h.serialBaudrate,
  serialDataBits: h.serialDataBits,
  serialParity: h.serialParity,
  serialStopBits: h.serialStopBits,
  serialFlowControl: h.serialFlowControl,
  isFavorite: h.isFavorite,
  lastConnectedAt: h.lastConnectedAt,
  remoteDesktopJson: json,
);

/// USB HID usages to RDP set-1 scancodes. Bit 8 marks an extended E0 key.
const desktopScanCodes = <int, int>{
  0x70004: 0x1e,
  0x70005: 0x30,
  0x70006: 0x2e,
  0x70007: 0x20,
  0x70008: 0x12,
  0x70009: 0x21,
  0x7000a: 0x22,
  0x7000b: 0x23,
  0x7000c: 0x17,
  0x7000d: 0x24,
  0x7000e: 0x25,
  0x7000f: 0x26,
  0x70010: 0x32,
  0x70011: 0x31,
  0x70012: 0x18,
  0x70013: 0x19,
  0x70014: 0x10,
  0x70015: 0x13,
  0x70016: 0x1f,
  0x70017: 0x14,
  0x70018: 0x16,
  0x70019: 0x2f,
  0x7001a: 0x11,
  0x7001b: 0x2d,
  0x7001c: 0x15,
  0x7001d: 0x2c,
  0x7001e: 0x02,
  0x7001f: 0x03,
  0x70020: 0x04,
  0x70021: 0x05,
  0x70022: 0x06,
  0x70023: 0x07,
  0x70024: 0x08,
  0x70025: 0x09,
  0x70026: 0x0a,
  0x70027: 0x0b,
  0x70028: 0x1c,
  0x70029: 0x01,
  0x7002a: 0x0e,
  0x7002b: 0x0f,
  0x7002c: 0x39,
  0x7002d: 0x0c,
  0x7002e: 0x0d,
  0x7002f: 0x1a,
  0x70030: 0x1b,
  0x70031: 0x2b,
  0x70033: 0x27,
  0x70034: 0x28,
  0x70035: 0x29,
  0x70036: 0x33,
  0x70037: 0x34,
  0x70038: 0x35,
  0x70039: 0x3a,
  0x7003a: 0x3b,
  0x7003b: 0x3c,
  0x7003c: 0x3d,
  0x7003d: 0x3e,
  0x7003e: 0x3f,
  0x7003f: 0x40,
  0x70040: 0x41,
  0x70041: 0x42,
  0x70042: 0x43,
  0x70043: 0x44,
  0x70044: 0x57,
  0x70045: 0x58,
  0x70046: 0x137,
  0x70047: 0x46,
  0x70049: 0x152,
  0x7004a: 0x147,
  0x7004b: 0x149,
  0x7004c: 0x153,
  0x7004d: 0x14f,
  0x7004e: 0x151,
  0x7004f: 0x14d,
  0x70050: 0x14b,
  0x70051: 0x150,
  0x70052: 0x148,
  0x70053: 0x45,
  0x70054: 0x135,
  0x70055: 0x37,
  0x70056: 0x4a,
  0x70057: 0x4e,
  0x70058: 0x11c,
  0x70059: 0x4f,
  0x7005a: 0x50,
  0x7005b: 0x51,
  0x7005c: 0x4b,
  0x7005d: 0x4c,
  0x7005e: 0x4d,
  0x7005f: 0x47,
  0x70060: 0x48,
  0x70061: 0x49,
  0x70062: 0x52,
  0x70063: 0x53,
  0x70065: 0x15d,
  0x700e0: 0x1d,
  0x700e1: 0x2a,
  0x700e2: 0x38,
  0x700e3: 0x15b,
  0x700e4: 0x11d,
  0x700e5: 0x36,
  0x700e6: 0x138,
  0x700e7: 0x15c,
};

final desktopKeysyms = <int, int>{
  LogicalKeyboardKey.enter.keyId: 0xff0d,
  LogicalKeyboardKey.numpadEnter.keyId: 0xff8d,
  LogicalKeyboardKey.escape.keyId: 0xff1b,
  LogicalKeyboardKey.backspace.keyId: 0xff08,
  LogicalKeyboardKey.tab.keyId: 0xff09, LogicalKeyboardKey.delete.keyId: 0xffff,
  LogicalKeyboardKey.insert.keyId: 0xff63,
  LogicalKeyboardKey.home.keyId: 0xff50,
  LogicalKeyboardKey.end.keyId: 0xff57, LogicalKeyboardKey.pageUp.keyId: 0xff55,
  LogicalKeyboardKey.pageDown.keyId: 0xff56,
  LogicalKeyboardKey.arrowLeft.keyId: 0xff51,
  LogicalKeyboardKey.arrowUp.keyId: 0xff52,
  LogicalKeyboardKey.arrowRight.keyId: 0xff53,
  LogicalKeyboardKey.arrowDown.keyId: 0xff54,
  LogicalKeyboardKey.shiftLeft.keyId: 0xffe1,
  LogicalKeyboardKey.shiftRight.keyId: 0xffe2,
  LogicalKeyboardKey.controlLeft.keyId: 0xffe3,
  LogicalKeyboardKey.controlRight.keyId: 0xffe4,
  LogicalKeyboardKey.altLeft.keyId: 0xffe9,
  LogicalKeyboardKey.altRight.keyId: 0xffea,
  LogicalKeyboardKey.metaLeft.keyId: 0xffeb,
  LogicalKeyboardKey.metaRight.keyId: 0xffec,
  LogicalKeyboardKey.capsLock.keyId: 0xffe5,
  LogicalKeyboardKey.numLock.keyId: 0xff7f,
  LogicalKeyboardKey.scrollLock.keyId: 0xff14,
  LogicalKeyboardKey.f1.keyId: 0xffbe, LogicalKeyboardKey.f2.keyId: 0xffbf,
  LogicalKeyboardKey.f3.keyId: 0xffc0, LogicalKeyboardKey.f4.keyId: 0xffc1,
  LogicalKeyboardKey.f5.keyId: 0xffc2, LogicalKeyboardKey.f6.keyId: 0xffc3,
  LogicalKeyboardKey.f7.keyId: 0xffc4, LogicalKeyboardKey.f8.keyId: 0xffc5,
  LogicalKeyboardKey.f9.keyId: 0xffc6, LogicalKeyboardKey.f10.keyId: 0xffc7,
  LogicalKeyboardKey.f11.keyId: 0xffc8, LogicalKeyboardKey.f12.keyId: 0xffc9,
  // Shortcut letters use their base keysym while Control/Alt is held.
  for (var char = 0x20; char <= 0x7e; char++) char: char,
};
