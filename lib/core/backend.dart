import 'dart:io';

import 'package:termpulse/core/android_serial.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/hosts_api.dart' as hosts_api;
import 'package:termpulse/src/rust/api/ops_api.dart' as ops_api;
import 'package:termpulse/src/rust/api/serial_api.dart' as serial_api;
import 'package:termpulse/src/rust/api/session_api.dart' as session_api;
import 'package:termpulse/src/rust/api/sftp_api.dart' as sftp_api;
import 'package:termpulse/src/rust/api/vault_api.dart' as vault_api;

abstract class CoreBackend {
  Future<VaultStatusDto> vaultInitPath(String dbPath);
  Future<VaultStatusDto> vaultStatus();
  Future<VaultStatusDto> vaultUnlock(String masterPassword);
  Future<void> vaultLock();
  Future<String> vaultExportJson({required bool includeSecrets});
  Future<int> vaultImportJson(String jsonStr);
  Future<ImportResultDto> importSshConfig(String content);
  Future<String> exportSshConfig();
  Future<ImportResultDto> importCsv(String content);
  Future<ImportResultDto> importPuttyReg(String content);

  Future<List<GroupDto>> listGroups();
  Future<void> upsertGroup(GroupDto group);
  Future<void> deleteGroup(String id);

  Future<List<CredentialDto>> listCredentials();
  Future<void> upsertCredential(CredentialDto cred);
  Future<void> deleteCredential(String id);

  Future<List<IdentityDto>> listIdentities();
  Future<void> upsertIdentity(IdentityDto identity);
  Future<void> deleteIdentity(String id);

  Future<List<ProxyDto>> listProxies();
  Future<void> upsertProxy(ProxyDto proxy);
  Future<void> deleteProxy(String id);

  Future<List<HostDto>> listHosts();
  Future<void> upsertHost(HostDto host);
  Future<void> deleteHost(String id);
  Future<EffectiveHostDto> resolveHostEffective(
    String hostId,
    bool globalFollowSftp,
  );

  Future<List<TunnelDto>> listTunnels();
  Future<void> upsertTunnel(TunnelDto tunnel);
  Future<void> deleteTunnel(String id);

  Future<List<SnippetDto>> listSnippets();
  Future<void> upsertSnippet(SnippetDto snippet);
  Future<void> deleteSnippet(String id);

  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows);
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  });
  Stream<TerminalEventDto> connectLocalShell({
    required int cols,
    required int rows,
    String? startupDir,
  });
  Stream<TerminalEventDto> connectTelnetHost({
    required String hostname,
    required int port,
    String? label,
  });
  bool serialSupported();
  Future<List<serial_api.SerialPortInfoDto>> listSerialPorts();
  Stream<TerminalEventDto> connectSerial({
    required serial_api.SerialConfigDto config,
    String? label,
    String? hostId,
  });
  Future<void> sendSessionInput(String sessionId, List<int> data);
  Future<int> broadcastSessionInput(List<String> sessionIds, List<int> data);
  Future<void> resizeTerminal(String sessionId, int cols, int rows);
  Future<void> closeSession(String sessionId);
  GuardResultDto checkCommandGuard(String input, String envTag);

  Future<SftpListingDto> sftpListDirectory(String sessionId, String path);
  Future<String> sftpReadText(String sessionId, String remotePath);
  Future<void> sftpWriteText(
    String sessionId,
    String remotePath,
    String content,
  );
  Future<void> sftpCreateDir(String sessionId, String remotePath);
  Future<void> sftpRenameEntry(
    String sessionId,
    String oldPath,
    String newPath,
  );
  Future<void> sftpDeleteEntry(String sessionId, String remotePath, bool isDir);
  Future<void> sftpSetPermissions(
    String sessionId,
    String remotePath,
    int mode,
  );
  Stream<TransferProgressDto> sftpStartTransfer({
    required String sessionId,
    required bool isUpload,
    required String localPath,
    required String remotePath,
  });
  Future<void> sftpControlTransfer(String transferId, String action);

  Future<TunnelStatusDto> startTunnelById(String tunnelId);
  Future<void> stopTunnelById(String tunnelId);
  Future<List<TunnelStatusDto>> listTunnelStatuses();
  Future<HostMetricsDto> pollSessionMetrics(String sessionId);
  Future<String?> suggestCommandGhost(String prefix);
  Future<AiDraftDto> aiDraftCommand({
    required String endpointUrl,
    String? apiKey,
    required String model,
    required String prompt,
    required String osHint,
    required String shellHint,
  });
  Future<void> sendWol(String mac, String broadcastAddr);
  Future<int> pingTcpMs(String host, int port);
}

class RustCoreBackend implements CoreBackend {
  final _androidSerial = AndroidSerial();
  @override
  Future<VaultStatusDto> vaultInitPath(String dbPath) =>
      vault_api.vaultInitPath(dbPath: dbPath);
  @override
  Future<VaultStatusDto> vaultStatus() => vault_api.vaultStatus();
  @override
  Future<VaultStatusDto> vaultUnlock(String masterPassword) =>
      vault_api.vaultUnlock(masterPassword: masterPassword);
  @override
  Future<void> vaultLock() async {
    if (Platform.isAndroid) await _androidSerial.closeAll();
    await vault_api.vaultLock();
  }

  @override
  Future<String> vaultExportJson({required bool includeSecrets}) =>
      vault_api.vaultExportJson(includeSecrets: includeSecrets);
  @override
  Future<int> vaultImportJson(String jsonStr) async =>
      (await vault_api.vaultImportJson(jsonStr: jsonStr)).toInt();
  @override
  Future<ImportResultDto> importSshConfig(String content) =>
      vault_api.importSshConfigText(content: content);
  @override
  Future<String> exportSshConfig() => vault_api.exportSshConfigText();
  @override
  Future<ImportResultDto> importCsv(String content) =>
      vault_api.importCsvText(content: content);
  @override
  Future<ImportResultDto> importPuttyReg(String content) =>
      vault_api.importPuttyRegText(content: content);

  @override
  Future<List<GroupDto>> listGroups() => hosts_api.listGroups();
  @override
  Future<void> upsertGroup(GroupDto group) =>
      hosts_api.upsertGroup(group: group);
  @override
  Future<void> deleteGroup(String id) => hosts_api.deleteGroup(id: id);

  @override
  Future<List<CredentialDto>> listCredentials() => hosts_api.listCredentials();
  @override
  Future<void> upsertCredential(CredentialDto cred) =>
      hosts_api.upsertCredential(cred: cred);
  @override
  Future<void> deleteCredential(String id) =>
      hosts_api.deleteCredential(id: id);

  @override
  Future<List<IdentityDto>> listIdentities() => hosts_api.listIdentities();
  @override
  Future<void> upsertIdentity(IdentityDto identity) =>
      hosts_api.upsertIdentity(identity: identity);
  @override
  Future<void> deleteIdentity(String id) => hosts_api.deleteIdentity(id: id);

  @override
  Future<List<ProxyDto>> listProxies() => hosts_api.listProxies();
  @override
  Future<void> upsertProxy(ProxyDto proxy) =>
      hosts_api.upsertProxy(proxy: proxy);
  @override
  Future<void> deleteProxy(String id) => hosts_api.deleteProxy(id: id);

  @override
  Future<List<HostDto>> listHosts() => hosts_api.listHosts();
  @override
  Future<void> upsertHost(HostDto host) => hosts_api.upsertHost(host: host);
  @override
  Future<void> deleteHost(String id) => hosts_api.deleteHost(id: id);
  @override
  Future<EffectiveHostDto> resolveHostEffective(
    String hostId,
    bool globalFollowSftp,
  ) => hosts_api.resolveHostEffective(
    hostId: hostId,
    globalFollowSftp: globalFollowSftp,
  );

  @override
  Future<List<TunnelDto>> listTunnels() => hosts_api.listTunnels();
  @override
  Future<void> upsertTunnel(TunnelDto tunnel) =>
      hosts_api.upsertTunnel(tunnel: tunnel);
  @override
  Future<void> deleteTunnel(String id) => hosts_api.deleteTunnel(id: id);

  @override
  Future<List<SnippetDto>> listSnippets() => hosts_api.listSnippets();
  @override
  Future<void> upsertSnippet(SnippetDto snippet) =>
      hosts_api.upsertSnippet(snippet: snippet);
  @override
  Future<void> deleteSnippet(String id) => hosts_api.deleteSnippet(id: id);

  @override
  Stream<TerminalEventDto> connectSshHost(String hostId, int cols, int rows) =>
      session_api.connectSshHost(hostId: hostId, cols: cols, rows: rows);
  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) => session_api.connectQuickSsh(
    target: target,
    password: password,
    privateKeyPem: privateKeyPem,
    cols: cols,
    rows: rows,
  );
  @override
  Stream<TerminalEventDto> connectLocalShell({
    required int cols,
    required int rows,
    String? startupDir,
  }) => session_api.connectLocalShell(
    cols: cols,
    rows: rows,
    startupDir: startupDir,
  );
  @override
  Stream<TerminalEventDto> connectTelnetHost({
    required String hostname,
    required int port,
    String? label,
  }) => session_api.connectTelnetHost(
    hostname: hostname,
    port: port,
    label: label,
  );
  @override
  bool serialSupported() => Platform.isAndroid || serial_api.serialSupported();
  @override
  Future<List<serial_api.SerialPortInfoDto>> listSerialPorts() =>
      Platform.isAndroid
      ? _androidSerial.listPorts()
      : serial_api.listSerialPorts();
  @override
  Stream<TerminalEventDto> connectSerial({
    required serial_api.SerialConfigDto config,
    String? label,
    String? hostId,
  }) => Platform.isAndroid
      ? _androidSerial.connect(config, label: label)
      : serial_api.connectSerial(config: config, label: label, hostId: hostId);
  @override
  Future<void> sendSessionInput(String sessionId, List<int> data) =>
      _androidSerial.owns(sessionId)
      ? _androidSerial.write(sessionId, data)
      : session_api.sendSessionInput(sessionId: sessionId, data: data);
  @override
  Future<int> broadcastSessionInput(
    List<String> sessionIds,
    List<int> data,
  ) async {
    var sent = 0;
    final native = sessionIds.where((id) => !_androidSerial.owns(id)).toList();
    if (native.isNotEmpty) {
      sent += (await session_api.broadcastSessionInput(
        sessionIds: native,
        data: data,
      )).toInt();
    }
    for (final id in sessionIds.where(_androidSerial.owns)) {
      await _androidSerial.write(id, data);
      sent++;
    }
    return sent;
  }

  @override
  Future<void> resizeTerminal(String sessionId, int cols, int rows) =>
      _androidSerial.owns(sessionId)
      ? Future.value()
      : session_api.resizeTerminal(
          sessionId: sessionId,
          cols: cols,
          rows: rows,
        );
  @override
  Future<void> closeSession(String sessionId) => _androidSerial.owns(sessionId)
      ? _androidSerial.close(sessionId)
      : session_api.closeSession(sessionId: sessionId);
  @override
  GuardResultDto checkCommandGuard(String input, String envTag) =>
      session_api.checkCommandGuard(input: input, envTag: envTag);

  @override
  Future<SftpListingDto> sftpListDirectory(String sessionId, String path) =>
      sftp_api.sftpListDirectory(sessionId: sessionId, path: path);
  @override
  Future<String> sftpReadText(String sessionId, String remotePath) =>
      sftp_api.sftpReadText(sessionId: sessionId, remotePath: remotePath);
  @override
  Future<void> sftpWriteText(
    String sessionId,
    String remotePath,
    String content,
  ) => sftp_api.sftpWriteText(
    sessionId: sessionId,
    remotePath: remotePath,
    content: content,
  );
  @override
  Future<void> sftpCreateDir(String sessionId, String remotePath) =>
      sftp_api.sftpCreateDir(sessionId: sessionId, remotePath: remotePath);
  @override
  Future<void> sftpRenameEntry(
    String sessionId,
    String oldPath,
    String newPath,
  ) => sftp_api.sftpRenameEntry(
    sessionId: sessionId,
    oldPath: oldPath,
    newPath: newPath,
  );
  @override
  Future<void> sftpDeleteEntry(
    String sessionId,
    String remotePath,
    bool isDir,
  ) => sftp_api.sftpDeleteEntry(
    sessionId: sessionId,
    remotePath: remotePath,
    isDir: isDir,
  );
  @override
  Future<void> sftpSetPermissions(
    String sessionId,
    String remotePath,
    int mode,
  ) => sftp_api.sftpSetPermissions(
    sessionId: sessionId,
    remotePath: remotePath,
    mode: mode,
  );
  @override
  Stream<TransferProgressDto> sftpStartTransfer({
    required String sessionId,
    required bool isUpload,
    required String localPath,
    required String remotePath,
  }) => sftp_api.sftpStartTransfer(
    sessionId: sessionId,
    isUpload: isUpload,
    localPath: localPath,
    remotePath: remotePath,
  );
  @override
  Future<void> sftpControlTransfer(String transferId, String action) =>
      sftp_api.sftpControlTransfer(transferId: transferId, action: action);

  @override
  Future<TunnelStatusDto> startTunnelById(String tunnelId) =>
      ops_api.startTunnelById(tunnelId: tunnelId);
  @override
  Future<void> stopTunnelById(String tunnelId) =>
      ops_api.stopTunnelById(tunnelId: tunnelId);
  @override
  Future<List<TunnelStatusDto>> listTunnelStatuses() =>
      ops_api.listTunnelStatuses();
  @override
  Future<HostMetricsDto> pollSessionMetrics(String sessionId) =>
      ops_api.pollSessionMetrics(sessionId: sessionId);
  @override
  Future<String?> suggestCommandGhost(String prefix) =>
      ops_api.suggestCommandGhost(prefix: prefix);
  @override
  Future<AiDraftDto> aiDraftCommand({
    required String endpointUrl,
    String? apiKey,
    required String model,
    required String prompt,
    required String osHint,
    required String shellHint,
  }) => ops_api.aiDraftCommand(
    endpointUrl: endpointUrl,
    apiKey: apiKey,
    model: model,
    prompt: prompt,
    osHint: osHint,
    shellHint: shellHint,
  );
  @override
  Future<void> sendWol(String mac, String broadcastAddr) =>
      ops_api.sendWol(mac: mac, broadcastAddr: broadcastAddr);
  @override
  Future<int> pingTcpMs(String host, int port) async =>
      (await ops_api.pingTcpMs(host: host, port: port)).toInt();
}
