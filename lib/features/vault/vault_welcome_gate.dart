import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/settings/app_permissions_screen.dart';
import 'package:termpulse/features/settings/privacy_policy_screen.dart';
import 'package:termpulse/state/app_providers.dart';

enum _WelcomeAction { permissions }

/// Lives below the Navigator and survives the Vault-to-workspace transition.
/// Existing Vaults and ordinary unlocks never trigger first-creation onboarding.
class VaultWelcomeGate extends ConsumerStatefulWidget {
  const VaultWelcomeGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VaultWelcomeGate> createState() => _VaultWelcomeGateState();
}

class _VaultWelcomeGateState extends ConsumerState<VaultWelcomeGate> {
  DialogRoute<_WelcomeAction>? _route;

  void _closeWelcome() {
    final route = _route;
    _route = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _showWelcome(String vaultPath) async {
    if (!mounted || _route != null) return;
    final vault = ref.read(vaultProvider);
    if (!vault.unlocked || vault.dbPath != vaultPath) return;
    final route = DialogRoute<_WelcomeAction>(
      context: context,
      builder: (_) => const _VaultWelcomeDialog(),
    );
    _route = route;
    final action = await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_route, route)) _route = null;
    if (!mounted || action != _WelcomeAction.permissions) return;
    final current = ref.read(vaultProvider);
    if (!current.unlocked || current.dbPath != vaultPath) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const AppPermissionsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(vaultProvider, (previous, next) {
      if (_route != null &&
          (!next.unlocked || previous?.dbPath != next.dbPath)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _closeWelcome();
        });
      }
      if (previous != null &&
          !previous.initialized &&
          next.initialized &&
          next.unlocked) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showWelcome(next.dbPath));
        });
      }
    });
    return widget.child;
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive && route.navigator?.mounted == true) {
          route.navigator?.removeRoute(route);
        }
      });
    }
    super.dispose();
  }
}

class _VaultWelcomeDialog extends StatelessWidget {
  const _VaultWelcomeDialog();

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return Dialog(
      key: const Key('vaultCreatedDialog'),
      backgroundColor: tp.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: tp.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [tp.accentContainer, tp.cyanContainer],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: tp.green.withValues(alpha: 0.35)),
                  ),
                  child: Icon(
                    Icons.verified_user_rounded,
                    color: tp.green,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Semantics(
                namesRoute: true,
                header: true,
                child: Text(
                  context.tr('Vault đã sẵn sàng'),
                  key: const Key('vaultWelcomeTitle'),
                  style: TextStyle(
                    color: tp.ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                context.tr(
                  'Chào mừng đến với TermPulse. Thêm máy chủ đầu tiên để bắt đầu kết nối.',
                ),
                style: TextStyle(color: tp.muted, height: 1.5),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tp.surface2,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tp.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _WelcomeDetail(
                      icon: Icons.phonelink_lock_rounded,
                      title: 'Lưu cục bộ trên thiết bị',
                      message:
                          'Mật khẩu kết nối và khóa bí mật được mã hóa trong Vault. Thông tin máy chủ và lịch sử lệnh không được mã hóa.',
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Divider(height: 1, color: tp.border),
                    ),
                    const _WelcomeDetail(
                      icon: Icons.key_rounded,
                      title: 'Giữ an toàn mật khẩu chính',
                      message: 'Bạn cần mật khẩu này để mở lại Vault.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                key: const Key('vaultWelcomeContinue'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                label: Text(context.tr('Bắt đầu sử dụng')),
              ),
              if (ForegroundBridge.isAndroid) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('vaultWelcomePermissions'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () =>
                      Navigator.of(context).pop(_WelcomeAction.permissions),
                  icon: const Icon(Icons.notifications_none_rounded, size: 19),
                  label: Text(context.tr('Quyền và thông báo')),
                ),
              ],
              const SizedBox(height: 4),
              TextButton(
                key: const Key('vaultWelcomePrivacy'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                ),
                child: Text(context.tr('Chính sách quyền riêng tư')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeDetail extends StatelessWidget {
  const _WelcomeDetail({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 20, color: tp.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr(title),
                style: TextStyle(color: tp.ink, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              Text(
                context.tr(message),
                style: TextStyle(color: tp.muted, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
