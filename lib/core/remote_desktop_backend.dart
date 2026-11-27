import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/src/rust/api/remote_desktop_api.dart' as native;

export 'package:termpulse/src/rust/api/remote_desktop_api.dart'
    show RemoteDesktopEventDto;

/// Independent from terminal transports: desktop pixels and keyboard events
/// must never enter shell broadcasting, command macros or terminal logging.
abstract class RemoteDesktopBackend {
  Stream<native.RemoteDesktopEventDto> connectHost(String hostId);
  Future<void> pointer(
    String sessionId,
    int x,
    int y,
    int buttons,
    int scrollY,
  );
  Future<void> key(String sessionId, int key, bool down, bool unicode);
  Future<void> typeText(String sessionId, String text);
  Future<void> close(String sessionId);
  Future<String> probeCertificate(
    String hostname,
    int port,
    String? serverName,
  );
}

class RustRemoteDesktopBackend implements RemoteDesktopBackend {
  @override
  Stream<native.RemoteDesktopEventDto> connectHost(String hostId) =>
      native.connectRemoteDesktopHost(hostId: hostId);

  @override
  Future<void> pointer(
    String sessionId,
    int x,
    int y,
    int buttons,
    int scrollY,
  ) => native.sendRemoteDesktopPointer(
    sessionId: sessionId,
    x: x,
    y: y,
    buttons: buttons,
    scrollY: scrollY,
  );

  @override
  Future<void> key(String sessionId, int key, bool down, bool unicode) =>
      native.sendRemoteDesktopKey(
        sessionId: sessionId,
        key: key,
        down: down,
        unicode: unicode,
      );

  @override
  Future<void> typeText(String sessionId, String text) =>
      native.sendRemoteDesktopText(sessionId: sessionId, text: text);

  @override
  Future<void> close(String sessionId) =>
      native.closeRemoteDesktop(sessionId: sessionId);

  @override
  Future<String> probeCertificate(
    String hostname,
    int port,
    String? serverName,
  ) => native.probeRemoteDesktopCertificate(
    hostname: hostname,
    port: port,
    tlsServerName: serverName,
  );
}

final remoteDesktopBackendProvider = Provider<RemoteDesktopBackend>(
  (ref) => RustRemoteDesktopBackend(),
);
