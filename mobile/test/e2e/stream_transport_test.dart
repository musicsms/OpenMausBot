import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/core/e2e/stream_transport.dart';
import 'package:mobile/core/e2e/yamux.dart';

void main() {
  group('HTTP/1.1 over Yamux Stream', () {
    test('serializes HTTP request with phone-relay.invalid Host', () {
      final req = http.Request('GET', Uri.parse('http://phone-relay.invalid/api/health'));
      req.headers['Authorization'] = 'Bearer omb_test';
      final bytes = serializeHttpRequest(req);
      final text = utf8.decode(bytes);

      expect(text, contains('GET /api/health HTTP/1.1\r\n'));
      expect(text, contains('Host: phone-relay.invalid\r\n'));
      expect(text, contains('Authorization: Bearer omb_test\r\n'));
    });

    test('serializes POST request with JSON body and forced Host', () {
      final req = http.Request('POST', Uri.parse('http://example.com/api/pair'));
      req.headers['Content-Type'] = 'application/json';
      req.body = '{"credential":"test_secret"}';
      final bytes = serializeHttpRequest(req);
      final text = utf8.decode(bytes);

      expect(text, contains('POST /api/pair HTTP/1.1\r\n'));
      expect(text, contains('Host: phone-relay.invalid\r\n'));
      expect(text, contains('Content-Type: application/json\r\n'));
      expect(text, contains('Content-Length: 28\r\n'));
      expect(text.endsWith('\r\n\r\n{"credential":"test_secret"}'), isTrue);
    });

    test('serializes request with query parameters and root path', () {
      final req = http.Request('GET', Uri.parse('http://server/api/auth/session?ticket=abc&foo=bar'));
      final bytes = serializeHttpRequest(req);
      final text = utf8.decode(bytes);

      expect(text, startsWith('GET /api/auth/session?ticket=abc&foo=bar HTTP/1.1\r\n'));
      expect(text, contains('Host: phone-relay.invalid\r\n'));

      final rootReq = http.Request('GET', Uri.parse('http://server'));
      final rootText = utf8.decode(serializeHttpRequest(rootReq));
      expect(rootText, startsWith('GET / HTTP/1.1\r\n'));
    });

    test('parses HTTP response status, headers, and body', () async {
      const responseText =
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 15\r\n'
          '\r\n'
          '{"status":"ok"}';
      final response = await parseHttpResponse(Stream.value(utf8.encode(responseText)));
      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('application/json'));
      expect(await response.stream.bytesToString(), equals('{"status":"ok"}'));
    });

    test('parses fragmented HTTP response across multiple stream chunks', () async {
      final chunk1 = utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n');
      final chunk2 = utf8.encode('Content-Length: 11\r\n\r\nhello ');
      final chunk3 = utf8.encode('world');

      final controller = StreamController<List<int>>();
      final responseFuture = parseHttpResponse(controller.stream);

      controller.add(chunk1);
      controller.add(chunk2);
      controller.add(chunk3);
      await controller.close();

      final response = await responseFuture;
      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('text/plain'));
      expect(await response.stream.bytesToString(), equals('hello world'));
    });

    test('parses chunked transfer-encoded response body', () async {
      const chunkedText =
          'HTTP/1.1 200 OK\r\n'
          'Transfer-Encoding: chunked\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          '5\r\n'
          'hello\r\n'
          '6\r\n'
          ' world\r\n'
          '0\r\n'
          '\r\n';

      final response = await parseHttpResponse(Stream.value(utf8.encode(chunkedText)));
      expect(response.statusCode, equals(200));
      expect(await response.stream.bytesToString(), equals('hello world'));
    });

    test('parses SSE stream events until stream completes', () async {
      final controller = StreamController<List<int>>();
      final responseFuture = parseHttpResponse(controller.stream);

      controller.add(utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/event-stream\r\n'
        'Cache-Control: no-cache\r\n'
        '\r\n'
        'data: {"kind":"ready"}\n\n',
      ));

      final response = await responseFuture;
      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('text/event-stream'));

      final received = <String>[];
      final completer = Completer<void>();

      response.stream.transform(utf8.decoder).listen(
        received.add,
        onDone: completer.complete,
      );

      controller.add(utf8.encode('data: {"kind":"ping"}\n\n'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await controller.close();
      await completer.future;

      final fullBody = received.join();
      expect(fullBody, contains('data: {"kind":"ready"}\n\n'));
      expect(fullBody, contains('data: {"kind":"ping"}\n\n'));
    });

    test('parses error statuses and phrases without body or with error JSON', () async {
      const unauthText =
          'HTTP/1.1 401 Unauthorized\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 27\r\n'
          '\r\n'
          '{"error":"pair this phone"}';
      final unauthResponse = await parseHttpResponse(Stream.value(utf8.encode(unauthText)));
      expect(unauthResponse.statusCode, equals(401));
      expect(unauthResponse.reasonPhrase, equals('Unauthorized'));
      expect(await unauthResponse.stream.bytesToString(), equals('{"error":"pair this phone"}'));

      const notFoundText =
          'HTTP/1.1 404 Not Found\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      final notFoundResponse = await parseHttpResponse(Stream.value(utf8.encode(notFoundText)));
      expect(notFoundResponse.statusCode, equals(404));
      expect(notFoundResponse.contentLength, equals(0));
      expect(await notFoundResponse.stream.bytesToString(), isEmpty);
    });

    test('YamuxHttpClient sends GET and receives response via YamuxSession', () async {
      late final YamuxSession clientSession;
      late final YamuxSession serverSession;

      final serverReceived = <int, List<int>>{};
      clientSession = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => serverSession.receive(frame),
      );
      serverSession = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => clientSession.receive(frame),
        onOpened: (streamId) {
          serverSession.accept(streamId);
          final stream = serverSession.getStream(streamId)!;
          stream.listen((chunk) {
            serverReceived.putIfAbsent(streamId, () => []).addAll(chunk);
          }, onDone: () {
            final requestText = utf8.decode(serverReceived[streamId]!);
            if (requestText.contains('GET /api/health HTTP/1.1')) {
              const reply =
                  'HTTP/1.1 200 OK\r\n'
                  'Content-Type: application/json\r\n'
                  'Content-Length: 21\r\n'
                  '\r\n'
                  '{"app":"openmausbot"}';
              stream.add(utf8.encode(reply));
              stream.finish();
            }
          });
        },
      );

      final client = YamuxHttpClient(clientSession);
      final req = http.Request('GET', Uri.parse('http://phone-relay.invalid/api/health'));
      final response = await client.send(req);

      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('application/json'));
      expect(await response.stream.bytesToString(), equals('{"app":"openmausbot"}'));
      expect(serverReceived[1], isNotNull);
      final rawServerText = utf8.decode(serverReceived[1]!);
      expect(rawServerText, contains('Host: phone-relay.invalid\r\n'));
    });

    test('YamuxHttpClient sends POST with body and receives response', () async {
      late final YamuxSession clientSession;
      late final YamuxSession serverSession;

      final serverReceived = <int, List<int>>{};
      clientSession = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => serverSession.receive(frame),
      );

      serverSession = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => clientSession.receive(frame),
        onOpened: (streamId) {
          serverSession.accept(streamId);
          final stream = serverSession.getStream(streamId)!;
          stream.listen((chunk) {
            serverReceived.putIfAbsent(streamId, () => []).addAll(chunk);
          }, onDone: () {
            final requestText = utf8.decode(serverReceived[streamId]!);
            if (requestText.contains('POST /api/pair HTTP/1.1') &&
                requestText.contains('{"code":"123456"}')) {
              const reply =
                  'HTTP/1.1 201 Created\r\n'
                  'Content-Type: application/json\r\n'
                  'Content-Length: 17\r\n'
                  '\r\n'
                  '{"token":"omb_1"}';
              stream.add(utf8.encode(reply));
              stream.finish();
            }
          });
        },
      );

      final client = YamuxHttpClient(clientSession);
      final postReq = http.Request('POST', Uri.parse('http://phone-relay.invalid/api/pair'));
      postReq.headers['Content-Type'] = 'application/json';
      postReq.body = '{"code":"123456"}';

      final response = await client.send(postReq);
      expect(response.statusCode, equals(201));
      expect(await response.stream.bytesToString(), equals('{"token":"omb_1"}'));
    });

    test('parseHttpResponse reports premature closure when Content-Length is truncated', () async {
      final controller = StreamController<List<int>>();
      final responseFuture = parseHttpResponse(controller.stream);

      controller.add(utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/plain\r\n'
        'Content-Length: 100\r\n'
        '\r\n'
        'short body',
      ));
      final response = await responseFuture;
      expect(response.statusCode, equals(200));

      await controller.close();
      expect(
        () async => await response.stream.toBytes(),
        throwsA(isA<http.ClientException>().having((e) => e.message, 'message', contains('prematurely'))),
      );
    });

    test('parseHttpResponse reports premature closure when chunked stream terminates before end chunk', () async {
      final controller = StreamController<List<int>>();
      final responseFuture = parseHttpResponse(controller.stream);

      controller.add(utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'Transfer-Encoding: chunked\r\n'
        '\r\n'
        '5\r\n'
        'hello\r\n',
      ));
      final response = await responseFuture;
      expect(response.statusCode, equals(200));

      await controller.close();
      expect(
        () async => await response.stream.toBytes(),
        throwsA(isA<http.ClientException>().having((e) => e.message, 'message', contains('prematurely'))),
      );
    });

    test('parseHttpResponse cancels subscription and rejects completer on malformed status line', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );

      final responseFuture = parseHttpResponse(controller.stream);
      controller.add(utf8.encode('NOT_HTTP_DATA\r\n\r\n'));

      expect(
        () async => await responseFuture,
        throwsA(isA<FormatException>()),
      );
      await pumpEventQueue();
      expect(cancelled, isTrue);
    });

    test('YamuxHttpClient.send does not open stream if request finalization fails', () async {
      final session = YamuxSession(role: YamuxRole.phone);
      final client = YamuxHttpClient(session);

      final failingStream = Stream<List<int>>.error(Exception('read failure'));
      final req = http.StreamedRequest('POST', Uri.parse('http://phone-relay.invalid/test'));
      failingStream.listen(req.sink.add, onError: req.sink.addError, onDone: req.sink.close);

      expect(() async => await client.send(req), throwsA(isA<Exception>()));
      expect(session.activeStreams, equals(0));
    });
  });
}
