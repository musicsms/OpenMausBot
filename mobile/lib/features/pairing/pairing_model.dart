import 'dart:convert';

class CompanionEndpoint {
  final String url;
  final String kind;
  final int priority;

  const CompanionEndpoint({
    required this.url,
    required this.kind,
    required this.priority,
  });

  factory CompanionEndpoint.fromJson(Map<String, dynamic> json) {
    return CompanionEndpoint(
      url: _stripTrailingSlashes(json['url'] as String),
      kind: json['kind'] as String? ?? 'lan',
      priority: (json['priority'] as num?)?.toInt() ?? 200,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind,
        'priority': priority,
      };

  bool get isLocal => kind == 'lan' || kind == 'bonjour';

  static String _stripTrailingSlashes(String value) {
    var trimmed = value.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}

class PairingPayload {
  final String host;
  final int port;
  final String? remoteUrl;
  final String credential;
  final String? code;
  final String machineName;
  final List<CompanionEndpoint> endpoints;

  PairingPayload({
    required this.host,
    required this.port,
    this.remoteUrl,
    required this.credential,
    this.code,
    required this.machineName,
    List<CompanionEndpoint>? endpoints,
  }) : endpoints = endpoints ?? const [];

  /// Legacy alias used by older fixtures and QR JSON.
  String get pairingSecret => credential;

  factory PairingPayload.fromJsonString(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('openmausbot://') ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      return PairingPayload._fromUri(Uri.parse(trimmed));
    }

    final Map<String, dynamic> data = jsonDecode(trimmed);
    final host = data['host'] as String? ?? '';
    final port = (data['port'] as num?)?.toInt() ?? 8810;
    final remoteUrl = data['remoteUrl'] as String?;
    final credential = (data['credential'] as String?) ??
        (data['pairingSecret'] as String?) ??
        (data['token'] as String?) ??
        '';
    final code = data['code'] as String?;
    final endpoints = _endpointsFromJson(data['endpoints']) ??
        _endpointsFromLegacy(host: host, port: port, remoteUrl: remoteUrl);
    return PairingPayload(
      host: host,
      port: port,
      remoteUrl: remoteUrl,
      credential: credential,
      code: code,
      machineName: data['machineName'] as String? ??
          data['name'] as String? ??
          'OpenMausBot Desktop',
      endpoints: endpoints,
    );
  }

  factory PairingPayload._fromUri(Uri uri) {
    final address = uri.queryParameters['address'] ?? uri.host;
    final portStr = uri.queryParameters['port'];
    String host = address;
    int port = 8810;
    String? originUrl;

    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(address)) {
      final origin = Uri.parse(address);
      host = origin.host;
      port = origin.hasPort
          ? origin.port
          : (origin.scheme == 'https' ? 443 : 80);
      originUrl = origin.origin;
    } else if (address.contains(':') && !address.startsWith('[')) {
      final parts = address.split(':');
      host = parts.first;
      port = int.tryParse(parts.last) ?? 8810;
    } else if (address.startsWith('[') && address.contains(']:')) {
      final close = address.indexOf(']:');
      host = address.substring(1, close);
      port = int.tryParse(address.substring(close + 2)) ?? 8810;
    } else if (portStr != null) {
      port = int.tryParse(portStr) ?? 8810;
    }

    final token = uri.queryParameters['token'] ?? '';
    final code = uri.queryParameters['code'];
    final name = uri.queryParameters['name'] ?? 'OpenMausBot Desktop';
    final remoteUrl = uri.queryParameters['remoteUrl'];
    final hosts = (uri.queryParameters['hosts'] ?? '')
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();

    final decodedEndpoints = _decodeEndpointsParam(uri.queryParameters['endpoints']);
    final endpoints = decodedEndpoints.isNotEmpty
        ? decodedEndpoints
        : _endpointsFromAddress(
            host: host,
            port: port,
            originUrl: originUrl,
            remoteUrl: remoteUrl,
            hosts: hosts,
          );

    return PairingPayload(
      host: host,
      port: port,
      remoteUrl: remoteUrl,
      credential: token.isNotEmpty ? token : (code ?? ''),
      code: code,
      machineName: name,
      endpoints: endpoints,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      if (remoteUrl != null) 'remoteUrl': remoteUrl,
      'credential': credential,
      'pairingSecret': credential,
      if (code != null) 'code': code,
      'machineName': machineName,
      'endpoints': endpoints.map((endpoint) => endpoint.toJson()).toList(),
    };
  }

  String get lanUrl {
    if (host.isEmpty) return '';
    return 'http://$host:$port';
  }

  /// First URL the phone should dial for `POST /api/pair`.
  String? get dialUrl {
    if (endpoints.isNotEmpty) {
      final sorted = [...endpoints]..sort((a, b) => a.priority.compareTo(b.priority));
      return sorted.first.url;
    }
    if (lanUrl.isNotEmpty) return lanUrl;
    return remoteUrl;
  }

  static List<CompanionEndpoint> _decodeEndpointsParam(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    try {
      final normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');
      final padded = normalized.padRight(
        normalized.length + ((4 - normalized.length % 4) % 4),
        '=',
      );
      final decoded = utf8.decode(base64Decode(padded));
      return _endpointsFromJson(jsonDecode(decoded)) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static List<CompanionEndpoint>? _endpointsFromJson(dynamic raw) {
    if (raw is! List) return null;
    return raw
        .whereType<Map>()
        .map((item) => CompanionEndpoint.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  static List<CompanionEndpoint> _endpointsFromLegacy({
    required String host,
    required int port,
    String? remoteUrl,
  }) {
    final endpoints = <CompanionEndpoint>[];
    if (host.isNotEmpty) {
      endpoints.add(CompanionEndpoint(
        url: 'http://$host:$port',
        kind: 'lan',
        priority: 200,
      ));
    }
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      final kind = remoteUrl.startsWith('https://') ? 'hosted' : 'tailnet';
      endpoints.add(CompanionEndpoint(
        url: CompanionEndpoint._stripTrailingSlashes(remoteUrl),
        kind: kind,
        priority: kind == 'hosted' ? 0 : 100,
      ));
    }
    return endpoints;
  }

  static List<CompanionEndpoint> _endpointsFromAddress({
    required String host,
    required int port,
    String? originUrl,
    String? remoteUrl,
    List<String> hosts = const [],
  }) {
    final endpoints = <CompanionEndpoint>[];
    if (originUrl != null) {
      final kind = originUrl.startsWith('https://') ? 'hosted' : 'lan';
      endpoints.add(CompanionEndpoint(
        url: originUrl,
        kind: kind,
        priority: kind == 'hosted' ? 0 : 200,
      ));
    } else if (host.isNotEmpty) {
      endpoints.add(CompanionEndpoint(
        url: 'http://$host:$port',
        kind: host.endsWith('.ts.net') ? 'tailnet' : 'lan',
        priority: host.endsWith('.ts.net') ? 100 : 200,
      ));
    }
    for (var index = 0; index < hosts.length; index++) {
      final candidate = hosts[index];
      final url = candidate.contains('://') ? candidate : 'http://$candidate:$port';
      final kind = candidate.endsWith('.ts.net')
          ? 'tailnet'
          : candidate.endsWith('.local')
              ? 'bonjour'
              : 'lan';
      endpoints.add(CompanionEndpoint(
        url: CompanionEndpoint._stripTrailingSlashes(url),
        kind: kind,
        priority: kind == 'tailnet' ? 100 : kind == 'bonjour' ? 300 : 200 + index,
      ));
    }
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      endpoints.add(CompanionEndpoint(
        url: CompanionEndpoint._stripTrailingSlashes(remoteUrl),
        kind: remoteUrl.startsWith('https://') ? 'hosted' : 'tailnet',
        priority: remoteUrl.startsWith('https://') ? 0 : 100,
      ));
    }
    return endpoints;
  }
}

class PairResult {
  final String token;
  final String serverName;
  final String? deviceId;
  final List<CompanionEndpoint> endpoints;

  const PairResult({
    required this.token,
    required this.serverName,
    this.deviceId,
    this.endpoints = const [],
  });

  factory PairResult.fromJson(Map<String, dynamic> json) {
    final token = json['token'] as String?;
    if (token == null || token.isEmpty) {
      throw FormatException('pair response missing token');
    }
    final device = json['device'];
    return PairResult(
      token: token,
      serverName: json['serverName'] as String? ?? 'OpenMausBot',
      deviceId: device is Map ? device['id'] as String? : null,
      endpoints: PairingPayload._endpointsFromJson(json['endpoints']) ?? const [],
    );
  }
}
