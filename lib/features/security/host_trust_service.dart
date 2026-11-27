import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/src/rust/api/host_keys_api.dart' as api;
import 'package:termpulse/state/app_providers.dart';

export 'package:termpulse/src/rust/api/host_keys_api.dart'
    show HostKeyPromptDto, HostKeyRecordDto;

abstract class HostTrustService {
  Future<List<api.HostKeyPromptDto>> pending();
  Future<void> decide(api.HostKeyPromptDto prompt, String decision);
  Future<List<api.HostKeyRecordDto>> records();
  Future<void> remove(api.HostKeyRecordDto record, String expectedFingerprint);
  Future<void> importKey({
    required String hostname,
    required int port,
    required String publicKey,
    required bool certificateAuthority,
    required bool replaceExisting,
    required String expectedFingerprint,
  });
}

class RustHostTrustService implements HostTrustService {
  const RustHostTrustService();

  @override
  Future<List<api.HostKeyPromptDto>> pending() => api.listHostKeyPrompts();

  @override
  Future<void> decide(api.HostKeyPromptDto prompt, String decision) =>
      api.decideHostKey(
        requestId: prompt.requestId,
        decision: decision,
        expectedFingerprint: prompt.fingerprint,
      );

  @override
  Future<List<api.HostKeyRecordDto>> records() => api.listHostKeys();

  @override
  Future<void> remove(
    api.HostKeyRecordDto record,
    String expectedFingerprint,
  ) => api.removeHostKey(
    recordId: record.recordId,
    expectedFingerprint: expectedFingerprint,
  );

  @override
  Future<void> importKey({
    required String hostname,
    required int port,
    required String publicKey,
    required bool certificateAuthority,
    required bool replaceExisting,
    required String expectedFingerprint,
  }) => api.importHostKey(
    hostname: hostname,
    port: port,
    publicKey: publicKey,
    certificateAuthority: certificateAuthority,
    replaceExisting: replaceExisting,
    expectedFingerprint: expectedFingerprint,
  );
}

/// Fake backends never initialize or poll the native bridge. Tests can override
/// this provider with a controlled service to exercise the trust UI itself.
final hostTrustServiceProvider = Provider<HostTrustService?>((ref) {
  if (ref.watch(backendProvider) is! RustCoreBackend) return null;
  return const RustHostTrustService();
});
