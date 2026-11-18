import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/pairing/pairing_model.dart';

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
