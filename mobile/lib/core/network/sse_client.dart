import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class SseNetworkClient {
  final String lanUrl;
  final String? remoteUrl;
  final String deviceToken;
  final http.Client _client;

  SseNetworkClient({
    required String lanUrl,
    String? remoteUrl,
    required this.deviceToken,
    http.Client? httpClient,
  })  : lanUrl = _stripTrailingSlashes(lanUrl),
        remoteUrl = remoteUrl != null ? _stripTrailingSlashes(remoteUrl) : null,
        _client = httpClient ?? http.Client();

  static String _stripTrailingSlashes(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  Future<String> resolveActiveBaseUrl() async {
    try {
      final res = await _client
          .get(
            Uri.parse('$lanUrl/healthz'),
            headers: {'Authorization': 'Bearer $deviceToken'},
          )
          .timeout(const Duration(milliseconds: 1500));
      if (res.statusCode == 200) {
        return lanUrl;
      }
    } catch (_) {}

    if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      return remoteUrl!;
    }
    return lanUrl;
  }

  Future<String> resolveActiveEndpoint() => resolveActiveBaseUrl();

  Stream<String> streamMessages(String threadId, {String? lastEventId}) async* {
    final baseUrl = await resolveActiveBaseUrl();
    final uri = Uri.parse('$baseUrl/api/threads/$threadId/messages');
    final request = http.Request('GET', uri);

    request.headers['Authorization'] = 'Bearer $deviceToken';
    request.headers['Accept'] = 'text/event-stream';
    if (lastEventId != null) {
      request.headers['Last-Event-ID'] = lastEventId;
    }

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Failed to connect to SSE stream: ${response.statusCode}');
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.startsWith('data: ')) {
        final payload = line.substring(6).trim();
        if (payload.isNotEmpty) {
          yield payload;
        }
      }
    }
  }

  Stream<String> connectStream(String threadId, {String? lastEventId}) =>
      streamMessages(threadId, lastEventId: lastEventId);

  Future<bool> postJson(String path, Map<String, dynamic> body) async {
    try {
      final baseUrl = await resolveActiveBaseUrl();
      final normalizedPath = path.startsWith('/') ? path : '/$path';
      final uri = Uri.parse('$baseUrl$normalizedPath');

      final res = await _client.post(
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

  void close() => _client.close();
}
