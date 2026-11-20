import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../e2e/descriptor.dart';
import '../../features/pairing/pairing_model.dart';

class E2EIdentity {
  final String transportPublicKey;
  final String? hostId;
  final List<String> relayNodes;

  const E2EIdentity({
    required this.transportPublicKey,
    this.hostId,
    this.relayNodes = const [],
  });

  String get k => transportPublicKey;
  String? get h => hostId;
  List<String> get r => relayNodes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is E2EIdentity &&
          runtimeType == other.runtimeType &&
          transportPublicKey == other.transportPublicKey &&
          hostId == other.hostId &&
          _listEquals(relayNodes, other.relayNodes);

  @override
  int get hashCode =>
      transportPublicKey.hashCode ^ hostId.hashCode ^ relayNodes.length.hashCode;

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class PairingStorage {
  final FlutterSecureStorage _storage;

  PairingStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'omb_device_token';
  static const _lanKey = 'omb_lan_url';
  static const _remoteKey = 'omb_remote_url';
  static const _endpointsKey = 'omb_endpoints';
  static const _botIdKey = 'omb_bot_id';
  static const _serverNameKey = 'omb_server_name';
  static const _e2eKeyKey = 'omb_e2e_k';
  static const _e2eHostKey = 'omb_e2e_h';
  static const _e2eRelaysKey = 'omb_e2e_r';

  Future<void> saveDeviceToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getDeviceToken() {
    return _storage.read(key: _tokenKey);
  }

  Future<void> saveEndpoints({
    String? lanUrl,
    String? remoteUrl,
    List<CompanionEndpoint>? endpoints,
  }) async {
    final resolved = endpoints ??
        _legacyEndpoints(lanUrl: lanUrl, remoteUrl: remoteUrl);

    await _storage.write(
      key: _endpointsKey,
      value: jsonEncode(resolved.map((endpoint) => endpoint.toJson()).toList()),
    );

    CompanionEndpoint? lan;
    CompanionEndpoint? hostedOrRemote;
    for (final endpoint in resolved) {
      if (lan == null && endpoint.isLocal) lan = endpoint;
      if (hostedOrRemote == null &&
          (endpoint.kind == 'hosted' || endpoint.kind == 'tailnet')) {
        hostedOrRemote = endpoint;
      }
    }

    final nextLan = lan?.url ?? lanUrl;
    final nextRemote = hostedOrRemote?.url ?? remoteUrl;

    if (nextLan != null && nextLan.isNotEmpty) {
      await _storage.write(key: _lanKey, value: nextLan);
    } else {
      await _storage.delete(key: _lanKey);
    }

    if (nextRemote != null && nextRemote.isNotEmpty) {
      await _storage.write(key: _remoteKey, value: nextRemote);
    } else {
      await _storage.delete(key: _remoteKey);
    }
  }

  Future<List<CompanionEndpoint>> getEndpoints() async {
    final raw = await _storage.read(key: _endpointsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((item) => CompanionEndpoint.fromJson(Map<String, dynamic>.from(item)))
              .toList();
        }
      } catch (_) {}
    }

    return _legacyEndpoints(
      lanUrl: await getLanUrl(),
      remoteUrl: await getRemoteUrl(),
    );
  }

  Future<String?> getLanUrl() {
    return _storage.read(key: _lanKey);
  }

  Future<String?> getRemoteUrl() {
    return _storage.read(key: _remoteKey);
  }

  Future<void> saveBotId(String botId) async {
    await _storage.write(key: _botIdKey, value: botId);
  }

  Future<String?> getBotId() {
    return _storage.read(key: _botIdKey);
  }

  Future<void> saveServerName(String name) async {
    await _storage.write(key: _serverNameKey, value: name);
  }

  Future<String?> getServerName() {
    return _storage.read(key: _serverNameKey);
  }

  Future<void> saveE2EIdentity({
    required String transportPublicKey,
    String? hostId,
    List<String>? relayNodes,
  }) async {
    await _storage.write(key: _e2eKeyKey, value: transportPublicKey);
    if (hostId != null && hostId.isNotEmpty) {
      await _storage.write(key: _e2eHostKey, value: hostId);
    } else {
      await _storage.delete(key: _e2eHostKey);
    }
    if (relayNodes != null && relayNodes.isNotEmpty) {
      await _storage.write(key: _e2eRelaysKey, value: jsonEncode(relayNodes));
    } else {
      await _storage.delete(key: _e2eRelaysKey);
    }
  }

  Future<void> saveE2EDescriptor(E2EDescriptor descriptor) {
    return saveE2EIdentity(
      transportPublicKey: descriptor.k,
      hostId: descriptor.h,
      relayNodes: descriptor.relayNodes,
    );
  }

  Future<E2EIdentity?> getE2EIdentity() async {
    final k = await _storage.read(key: _e2eKeyKey);
    if (k == null || k.isEmpty) return null;
    final h = await _storage.read(key: _e2eHostKey);
    final rRaw = await _storage.read(key: _e2eRelaysKey);
    List<String> relays = const [];
    if (rRaw != null && rRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(rRaw);
        if (decoded is List) {
          relays = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    return E2EIdentity(
      transportPublicKey: k,
      hostId: h,
      relayNodes: relays,
    );
  }

  Future<E2EDescriptor?> getE2EDescriptor() async {
    final identity = await getE2EIdentity();
    if (identity == null) return null;
    final hasRelay = identity.hostId != null && identity.relayNodes.isNotEmpty;
    return E2EDescriptor.parseJson({
      'v': 1,
      'k': identity.transportPublicKey,
      if (hasRelay) 'h': identity.hostId,
      if (hasRelay) 'r': identity.relayNodes,
    });
  }

  Future<void> clearE2EIdentity() async {
    await _storage.delete(key: _e2eKeyKey);
    await _storage.delete(key: _e2eHostKey);
    await _storage.delete(key: _e2eRelaysKey);
  }

  Future<void> clear() async {
    await _storage.deleteAll();
  }

  List<CompanionEndpoint> _legacyEndpoints({
    String? lanUrl,
    String? remoteUrl,
  }) {
    final endpoints = <CompanionEndpoint>[];
    if (lanUrl != null && lanUrl.isNotEmpty) {
      endpoints.add(CompanionEndpoint(url: lanUrl, kind: 'lan', priority: 200));
    }
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      endpoints.add(CompanionEndpoint(
        url: remoteUrl,
        kind: remoteUrl.startsWith('https://') ? 'hosted' : 'tailnet',
        priority: remoteUrl.startsWith('https://') ? 0 : 100,
      ));
    }
    return endpoints;
  }
}
