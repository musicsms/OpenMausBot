import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../e2e/descriptor.dart';
import '../e2e/relay_client.dart';
import '../e2e/stream_transport.dart';
import '../../features/pairing/pairing_model.dart';

class CompanionEvent {
  final String? id;
  final Map<String, dynamic> data;

  const CompanionEvent({this.id, required this.data});

  String? get kind => data['kind'] as String?;
}

class SseNetworkClient {
  final List<CompanionEndpoint> endpoints;
  final String deviceToken;
  final E2EDescriptor? e2e;
  final http.Client _client;
  PhoneRelayClient? _relayClient;
  final WebSocketConnector? _connector;

  SseNetworkClient({
    List<CompanionEndpoint>? endpoints,
    String? lanUrl,
    String? remoteUrl,
    required this.deviceToken,
    http.Client? httpClient,
    this.e2e,
    PhoneRelayClient? relayClient,
    WebSocketConnector? connector,
  })  : endpoints = _normalizeEndpoints(
          endpoints: endpoints,
          lanUrl: lanUrl,
          remoteUrl: remoteUrl,
        ),
        _client = httpClient ?? http.Client(),
        _relayClient = relayClient,
        _connector = connector;

  bool get isE2E => e2e != null;

  /// Back-compat for tests that still read these fields.
  String get lanUrl {
    final local = endpoints.where((endpoint) => endpoint.isLocal);
    if (local.isNotEmpty) return local.first.url;
    return endpoints.isNotEmpty ? endpoints.first.url : '';
  }

  String? get remoteUrl {
    final remote = endpoints.where(
      (endpoint) => endpoint.kind == 'hosted' || endpoint.kind == 'tailnet',
    );
    return remote.isEmpty ? null : remote.first.url;
  }

  static List<CompanionEndpoint> _normalizeEndpoints({
    List<CompanionEndpoint>? endpoints,
    String? lanUrl,
    String? remoteUrl,
  }) {
    if (endpoints != null && endpoints.isNotEmpty) {
      return endpoints
          .map(
            (endpoint) => CompanionEndpoint(
              url: _stripTrailingSlashes(endpoint.url),
              kind: endpoint.kind,
              priority: endpoint.priority,
            ),
          )
          .toList();
    }

    final resolved = <CompanionEndpoint>[];
    if (lanUrl != null && lanUrl.trim().isNotEmpty) {
      resolved.add(CompanionEndpoint(
        url: _stripTrailingSlashes(lanUrl),
        kind: 'lan',
        priority: 200,
      ));
    }
    if (remoteUrl != null && remoteUrl.trim().isNotEmpty) {
      final trimmed = _stripTrailingSlashes(remoteUrl);
      resolved.add(CompanionEndpoint(
        url: trimmed,
        kind: trimmed.startsWith('https://') ? 'hosted' : 'tailnet',
        priority: trimmed.startsWith('https://') ? 0 : 100,
      ));
    }
    return resolved;
  }

  static String _stripTrailingSlashes(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  Future<http.Client> _getActiveClient() async {
    if (e2e != null) {
      _relayClient ??= PhoneRelayClient(
        descriptor: e2e!,
        credentialToken: deviceToken,
        connector: _connector ?? defaultWebSocketConnector,
      );
      if (!_relayClient!.isConnected) {
        await _relayClient!.connect();
      }
      return _relayClient!.httpClient;
    }
    return _client;
  }

  Future<String> resolveActiveBaseUrl() async {
    if (e2e != null) {
      final client = await _getActiveClient();
      final healthy = await _isHealthy('http://$relayHost', client);
      if (healthy) {
        return 'http://$relayHost';
      }
      return 'http://$relayHost';
    }

    final local = endpoints.where((endpoint) => endpoint.isLocal).toList();
    final hosted = endpoints.where((endpoint) => endpoint.kind == 'hosted').toList();
    final tailnet = endpoints.where((endpoint) => endpoint.kind == 'tailnet').toList();
    final other = endpoints
        .where(
          (endpoint) =>
              !endpoint.isLocal &&
              endpoint.kind != 'hosted' &&
              endpoint.kind != 'tailnet',
        )
        .toList();

    final ordered = [...local, ...hosted, ...tailnet, ...other];
    for (final endpoint in ordered) {
      if (await _isHealthy(endpoint.url)) {
        return endpoint.url;
      }
    }

    if (ordered.isNotEmpty) return ordered.first.url;
    throw StateError('no companion endpoints configured');
  }

  Future<String> resolveActiveEndpoint() => resolveActiveBaseUrl();

  Future<bool> _isHealthy(String baseUrl, [http.Client? client]) async {
    final httpClient = client ?? _client;
    try {
      final res = await httpClient
          .get(
            Uri.parse('$baseUrl/api/health'),
            headers: {'Authorization': 'Bearer $deviceToken'},
          )
          .timeout(const Duration(milliseconds: 1500));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body);
      return body is Map && body['app'] == 'openmausbot';
    } catch (_) {
      return false;
    }
  }

  static Future<PairResult> redeemPair({
    String? baseUrl,
    required String deviceName,
    String? credential,
    String? code,
    String? pairRequestId,
    http.Client? httpClient,
    E2EDescriptor? e2e,
    PhoneRelayClient? relayClient,
    WebSocketConnector? connector,
  }) async {
    if (e2e != null) {
      if (credential == null || credential.isEmpty) {
        throw ArgumentError('E2E pairing requires a pairing credential');
      }
      final relay = relayClient ??
          PhoneRelayClient(
            descriptor: e2e,
            credentialToken: credential,
            connector: connector ?? defaultWebSocketConnector,
          );
      await relay.connect();
      final client = relay.httpClient;
      try {
        final body = <String, dynamic>{
          'deviceName': deviceName,
          'credential': credential,
          if (code != null && code.isNotEmpty) 'code': code,
          if (pairRequestId != null) 'pairRequestId': pairRequestId,
        };
        final res = await client.post(
          Uri.parse('http://$relayHost/api/pair'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          String error = 'pairing failed (${res.statusCode})';
          try {
            final parsed = jsonDecode(res.body);
            if (parsed is Map && parsed['error'] is String) {
              error = parsed['error'] as String;
            }
          } catch (_) {}
          throw Exception(error);
        }
        final parsedJson = jsonDecode(res.body) as Map<String, dynamic>;
        final pairResult = PairResult.fromJson(parsedJson);
        return PairResult(
          token: pairResult.token,
          serverName: pairResult.serverName,
          deviceId: pairResult.deviceId,
          endpoints: pairResult.endpoints,
          e2e: pairResult.e2e ?? e2e,
        );
      } finally {
        if (relayClient == null) {
          await relay.close();
        }
      }
    }

    if (baseUrl == null || baseUrl.isEmpty) {
      throw Exception('pairing invite has no reachable host');
    }

    final client = httpClient ?? http.Client();
    final shouldClose = httpClient == null;
    try {
      final body = <String, dynamic>{
        'deviceName': deviceName,
        if (credential != null && credential.isNotEmpty) 'credential': credential,
        if (code != null && code.isNotEmpty) 'code': code,
        if (pairRequestId != null) 'pairRequestId': pairRequestId,
      };
      final res = await client.post(
        Uri.parse('${_stripTrailingSlashes(baseUrl)}/api/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String error = 'pairing failed (${res.statusCode})';
        try {
          final parsed = jsonDecode(res.body);
          if (parsed is Map && parsed['error'] is String) {
            error = parsed['error'] as String;
          }
        } catch (_) {}
        throw Exception(error);
      }
      return PairResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } finally {
      if (shouldClose) client.close();
    }
  }

  Stream<CompanionEvent> streamEvents({String? lastEventId}) async* {
    final client = await _getActiveClient();
    final baseUrl = await resolveActiveBaseUrl();
    final uri = Uri.parse('$baseUrl/api/events');
    final request = http.Request('GET', uri);

    request.headers['Authorization'] = 'Bearer $deviceToken';
    request.headers['Accept'] = 'text/event-stream';
    if (lastEventId != null) {
      request.headers['Last-Event-ID'] = lastEventId;
    }

    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Failed to connect to SSE stream: ${response.statusCode}');
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    String? eventId;
    final dataLines = <String>[];

    await for (final line in lines) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final payload = dataLines.join('\n').trim();
          dataLines.clear();
          final currentId = eventId;
          eventId = null;
          if (payload.isEmpty) continue;
          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map<String, dynamic>) {
              yield CompanionEvent(id: currentId, data: decoded);
            } else if (decoded is Map) {
              yield CompanionEvent(
                id: currentId,
                data: Map<String, dynamic>.from(decoded),
              );
            }
          } catch (_) {
            // Ignore non-JSON frames from a misbehaving peer.
          }
        }
        continue;
      }

      if (line.startsWith(':')) continue;
      if (line.startsWith('id:')) {
        eventId = line.substring(3).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
  }

  /// Legacy helper used by older tests; yields JSON string payloads from `/api/events`.
  Stream<String> streamMessages(String threadId, {String? lastEventId}) async* {
    await for (final event in streamEvents(lastEventId: lastEventId)) {
      yield jsonEncode(event.data);
    }
  }

  Stream<CompanionEvent> connectStream({String? lastEventId}) =>
      streamEvents(lastEventId: lastEventId);

  Future<List<Map<String, dynamic>>> listBots() async {
    final body = await getJson('/api/bots');
    if (body is List) {
      return body
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    if (body is Map && body['bots'] is List) {
      return (body['bots'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return const [];
  }

  Future<bool> sendBotMessage({
    required String botId,
    required String text,
    String? threadId,
    String? sendId,
  }) {
    return postJson('/api/bots/$botId/messages', {
      'text': text,
      if (threadId != null) 'threadId': threadId,
      if (sendId != null) 'sendId': sendId,
    });
  }

  Future<bool> respondApproval({
    required String botId,
    required String threadId,
    required String requestId,
    required String behavior,
  }) {
    return postJson('/api/bots/$botId/respond', {
      'threadId': threadId,
      'requestId': requestId,
      'behavior': behavior,
    });
  }

  Future<bool> patchCard({
    required String botId,
    required String messageId,
    required String threadId,
    required String answered,
  }) async {
    try {
      final client = await _getActiveClient();
      final baseUrl = await resolveActiveBaseUrl();
      final uri = Uri.parse('$baseUrl/api/bots/$botId/cards/$messageId');
      final res = await client.patch(
        uri,
        headers: {
          'Authorization': 'Bearer $deviceToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'threadId': threadId,
          'answered': answered,
        }),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> getJson(String path) async {
    final client = await _getActiveClient();
    final baseUrl = await resolveActiveBaseUrl();
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final res = await client.get(
      Uri.parse('$baseUrl$normalizedPath'),
      headers: {'Authorization': 'Bearer $deviceToken'},
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('GET $normalizedPath failed: ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  Future<bool> postJson(String path, Map<String, dynamic> body) async {
    try {
      final client = await _getActiveClient();
      final baseUrl = await resolveActiveBaseUrl();
      final normalizedPath = path.startsWith('/') ? path : '/$path';
      final uri = Uri.parse('$baseUrl$normalizedPath');

      final res = await client.post(
        uri,
        headers: {
          'Authorization': 'Bearer $deviceToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getEndpointsInfo() async {
    try {
      final data = await getJson('/api/companion/endpoints');
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  void close() {
    _client.close();
    _relayClient?.close();
  }
}
