import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/core/l10n.dart';

class PanelResizeHandle extends StatefulWidget {
  final String label;
  final ValueChanged<double> onDelta;
  final VoidCallback onReset;
  final ValueChanged<bool>? onDragStateChanged;
  final ValueChanged<double>? onSizeDelta;

  const PanelResizeHandle({
    super.key,
    required this.label,
    required this.onDelta,
    required this.onReset,
    this.onDragStateChanged,
    this.onSizeDelta,
  });

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      onIncrease: () => (widget.onSizeDelta ?? widget.onDelta)(16),
      onDecrease: () => (widget.onSizeDelta ?? widget.onDelta)(-16),
      child: Focus(
        onFocusChange: (focused) => setState(() => _highlighted = focused),
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            widget.onDelta(
              event.logicalKey == LogicalKeyboardKey.arrowLeft ? -16 : 16,
            );
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onReset();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _highlighted = true),
          onExit: (_) => setState(() => _highlighted = false),
          child: Tooltip(
            message: context.tr(
              '{label} · Kéo để đổi rộng · Nhấp đôi để đặt lại',
              {'label': widget.label},
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) =>
                  widget.onDragStateChanged?.call(true),
              onHorizontalDragUpdate: (details) =>
                  widget.onDelta(details.delta.dx),
              onHorizontalDragEnd: (_) =>
                  widget.onDragStateChanged?.call(false),
              onHorizontalDragCancel: () =>
                  widget.onDragStateChanged?.call(false),
              onDoubleTap: widget.onReset,
              child: SizedBox(
                width: 8,
                child: Center(
                  child: Container(
                    width: 2,
                    color: _highlighted ? context.tp.accent : context.tp.border,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InlineNotice extends StatelessWidget {
  final String message;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetry;

  const InlineNotice({
    super.key,
    required this.message,
    this.onDismiss,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final error = presentAppError(AppLocalizationScope.of(context), message);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tp.red.withValues(alpha: 0.08),
          border: Border(
            bottom: BorderSide(color: tp.red.withValues(alpha: 0.25)),
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 20,
                        color: tp.red,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        error.summary,
                        key: const Key('noticeSummary'),
                        style: TextStyle(
                          color: tp.ink,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                if (error.details != null ||
                    onRetry != null ||
                    onDismiss != null)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    children: [
                      if (error.details != null)
                        ErrorDetailsButton(details: error.details!),
                      if (onRetry != null)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(44, 44),
                          ),
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(context.tr('Thử lại')),
                        ),
                      if (onDismiss != null)
                        IconButton(
                          tooltip: context.tr('Đóng / Dismiss'),
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          onPressed: onDismiss,
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorDetailsButton extends StatelessWidget {
  final String details;

  const ErrorDetailsButton({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const Key('noticeDetailsButton'),
      style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
      onPressed: () => showAppErrorDetails(context, details),
      icon: const Icon(Icons.info_outline_rounded, size: 17),
      label: Text(context.tr('Xem chi tiết')),
    );
  }
}

Future<void> showAppErrorDetails(BuildContext context, String details) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('noticeDetailsDialog'),
        alignment: Alignment.center,
        scrollable: true,
        constraints: const BoxConstraints(maxWidth: 560),
        title: Text(dialogContext.tr('Chi tiết kỹ thuật')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              dialogContext.tr(
                'Thông tin này giúp kiểm tra lỗi khi cần hỗ trợ.',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              details,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.tr('Đóng')),
          ),
        ],
      ),
    );

void showAppErrorSnackBar(BuildContext context, String message) {
  final error = presentAppError(AppLocalizationScope.of(context), message);
  final width = (MediaQuery.sizeOf(context).width - 32).clamp(1.0, 720.0);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      width: width,
      content: Text(error.summary),
      action: error.details == null
          ? null
          : SnackBarAction(
              label: context.tr('Xem chi tiết'),
              onPressed: () {
                if (context.mounted) {
                  showAppErrorDetails(context, error.details!);
                }
              },
            ),
    ),
  );
}

class StatusDot extends StatelessWidget {
  final Color color;
  final bool glow;
  final double size;

  const StatusDot({
    super.key,
    required this.color,
    this.glow = true,
    this.size = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: size * 0.95,
                  spreadRadius: 0.4,
                ),
              ]
            : null,
      ),
    );
  }
}

class EnvBadge extends StatelessWidget {
  final String envTag;
  final bool compact;

  const EnvBadge({super.key, required this.envTag, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final lower = envTag.toLowerCase();
    final (Color fg, Color bg) = switch (lower) {
      'prod' => (tp.red, tp.red.withValues(alpha: 0.12)),
      'staging' => (tp.cyan, tp.cyan.withValues(alpha: 0.12)),
      _ => (tp.green, tp.green.withValues(alpha: 0.12)),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 4.5 : 5.5,
            height: compact ? 4.5 : 5.5,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fg),
          ),
          SizedBox(width: compact ? 4 : 5),
          Text(
            envTag.toUpperCase(),
            style: TextStyle(
              fontSize: compact ? 9 : 10,
              fontWeight: FontWeight.w800,
              color: fg,
              letterSpacing: 0.45,
            ),
          ),
        ],
      ),
    );
  }
}

class ProtocolAvatar extends StatelessWidget {
  final String envTag;
  final String protocol;
  final double size;
  final bool active;

  const ProtocolAvatar({
    super.key,
    required this.envTag,
    required this.protocol,
    this.size = 38,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final lower = envTag.toLowerCase();
    final Color tint = switch (lower) {
      'prod' => tp.red,
      'staging' => tp.cyan,
      _ => tp.green,
    };
    final IconData icon = switch (protocol.toLowerCase()) {
      'local_shell' => Icons.terminal_rounded,
      'telnet' => Icons.router_rounded,
      _ => Icons.dns_rounded,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.29),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withValues(alpha: 0.22),
                tint.withValues(alpha: 0.08),
              ],
            ),
            border: Border.all(color: tint.withValues(alpha: 0.34)),
          ),
          child: Icon(icon, size: size * 0.48, color: tint),
        ),
        if (active)
          Positioned(
            right: -1.5,
            top: -1.5,
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                color: tp.surface,
                shape: BoxShape.circle,
              ),
              child: StatusDot(color: tp.green, glow: true, size: size * 0.22),
            ),
          ),
      ],
    );
  }
}

class HoverSurface extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final Color? color;
  final Color? hoverColor;
  final Border? border;
  final Border? hoverBorder;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const HoverSurface({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(11)),
    this.color,
    this.hoverColor,
    this.border,
    this.hoverBorder,
    this.padding,
    this.margin,
  });

  @override
  State<HoverSurface> createState() => _HoverSurfaceState();
}

class _HoverSurfaceState extends State<HoverSurface> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final highlighted = _hover || _focused;
    final bg = highlighted
        ? (widget.hoverColor ?? tp.surface3.withValues(alpha: 0.72))
        : (widget.color ?? tp.surface);
    final br = highlighted
        ? (widget.hoverBorder ?? Border.all(color: tp.borderStrong))
        : (widget.border ?? Border.all(color: tp.border));

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        margin: widget.margin,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: widget.borderRadius,
          border: br,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: widget.borderRadius,
            onTap: widget.onTap,
            onFocusChange: (value) => setState(() => _focused = value),
            child: Padding(
              padding: widget.padding ?? EdgeInsets.zero,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class MetricGaugeCard extends StatelessWidget {
  final String label;
  final String value;
  final double? ratio;
  final IconData icon;

  const MetricGaugeCard({
    super.key,
    required this.label,
    required this.value,
    this.ratio,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final isDark = tp.brightness == Brightness.dark;
    final clamped = ratio != null && ratio!.isFinite
        ? ratio!.clamp(0.0, 1.0)
        : null;
    final barColor = clamped == null
        ? tp.cyan
        : (clamped >= 0.85 ? tp.red : (clamped >= 0.65 ? tp.amber : tp.green));

    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? tp.surface2 : tp.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tp.border),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: barColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 12, color: barColor),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: tp.muted,
                  letterSpacing: 0.35,
                ),
              ),
              if (clamped != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${(clamped * 100).round()}%',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                    color: barColor,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
              fontFeatures: const [FontFeature.tabularFigures()],
              color: tp.ink,
            ),
          ),
          if (clamped != null) ...[
            const SizedBox(height: 7),
            Container(
              width: 126,
              height: 5,
              decoration: BoxDecoration(
                color: tp.bg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: clamped.clamp(0.03, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(
                      colors: [barColor.withValues(alpha: 0.8), barColor],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: barColor.withValues(alpha: 0.35),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AmbientBackdrop extends StatelessWidget {
  final Widget child;
  const AmbientBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final isDark = tp.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tp.bg,
        gradient: RadialGradient(
          center: const Alignment(-0.45, -0.75),
          radius: 1.25,
          colors: [
            tp.accent.withValues(alpha: isDark ? 0.14 : 0.08),
            tp.cyan.withValues(alpha: isDark ? 0.05 : 0.03),
            tp.bg,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: CustomPaint(
        painter: _DotGridPainter(
          color: tp.ink.withValues(alpha: isDark ? 0.045 : 0.04),
        ),
        child: child,
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color color;
  const _DotGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 28.0;
    for (double x = 14; x < size.width; x += step) {
      for (double y = 14; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}
