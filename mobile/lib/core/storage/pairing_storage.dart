import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PairingStorage {
  final FlutterSecureStorage _storage;

  PairingStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'omb_device_token';
  static const _lanKey = 'omb_lan_url';
  static const _remoteKey = 'omb_remote_url';

  Future<void> saveDeviceToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getDeviceToken() {
    return _storage.read(key: _tokenKey);
  }

  Future<void> saveEndpoints({required String lanUrl, String? remoteUrl}) async {
    await _storage.write(key: _lanKey, value: lanUrl);
    if (remoteUrl != null) {
      await _storage.write(key: _remoteKey, value: remoteUrl);
    } else {
      await _storage.delete(key: _remoteKey);
    }
  }

  Future<String?> getLanUrl() {
    return _storage.read(key: _lanKey);
  }

  Future<String?> getRemoteUrl() {
    return _storage.read(key: _remoteKey);
  }

  Future<void> clear() async {
    await _storage.deleteAll();
  }
}
