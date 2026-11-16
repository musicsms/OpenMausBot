import 'dart:convert';

class PairingPayload {
  final String host;
  final int port;
  final String? remoteUrl;
  final String pairingSecret;
  final String machineName;

  PairingPayload({
    required this.host,
    required this.port,
    this.remoteUrl,
    required this.pairingSecret,
    required this.machineName,
  });

  factory PairingPayload.fromJsonString(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('openmausbot://') || trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final uri = Uri.parse(trimmed);
      final address = uri.queryParameters['address'] ?? uri.host;
      final portStr = uri.queryParameters['port'];
      String host = address;
      int port = 8810;
      if (address.contains(':')) {
        final parts = address.split(':');
        host = parts[0].replaceAll('[', '').replaceAll(']', '');
        port = int.tryParse(parts[1]) ?? 8810;
      } else if (portStr != null) {
        port = int.tryParse(portStr) ?? 8810;
      }
      final token = uri.queryParameters['token'] ?? uri.queryParameters['code'] ?? '';
      final name = uri.queryParameters['name'] ?? 'OpenMausBot Desktop';
      final remoteUrl = uri.queryParameters['remoteUrl'];
      return PairingPayload(
        host: host,
        port: port,
        remoteUrl: remoteUrl,
        pairingSecret: token,
        machineName: name,
      );
    }

    final Map<String, dynamic> data = jsonDecode(raw);
    return PairingPayload(
      host: data['host'] as String,
      port: (data['port'] as num).toInt(),
      remoteUrl: data['remoteUrl'] as String?,
      pairingSecret: data['pairingSecret'] as String,
      machineName: data['machineName'] as String? ?? 'OpenMausBot Desktop',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      if (remoteUrl != null) 'remoteUrl': remoteUrl,
      'pairingSecret': pairingSecret,
      'machineName': machineName,
    };
  }

  String get lanUrl => 'http://$host:$port';
}
