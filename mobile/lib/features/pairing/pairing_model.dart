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

  factory PairingPayload.fromJsonString(String jsonStr) {
    final Map<String, dynamic> data = jsonDecode(jsonStr);
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
