import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'yamux.dart';

const String relayHost = 'phone-relay.invalid';

enum _ChunkState {
  readingSize,
  readingData,
  readingDataCrlf,
  readingTrailers,
  done,
}

class _ByteAccumulator {
  Uint8List _buffer = Uint8List(0);

  int get length => _buffer.length;

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    final next = Uint8List(_buffer.length + bytes.length);
    next.setRange(0, _buffer.length, _buffer);
    next.setRange(_buffer.length, next.length, bytes);
    _buffer = next;
  }

  Uint8List take(int count) {
    final slice = Uint8List.sublistView(_buffer, 0, count);
    _buffer = Uint8List.sublistView(_buffer, count);
    return slice;
  }

  Uint8List takeAll() {
    final all = _buffer;
    _buffer = Uint8List(0);
    return all;
  }

  int indexOfSequence(List<int> seq) {
    if (seq.isEmpty || _buffer.length < seq.length) return -1;
    for (var i = 0; i <= _buffer.length - seq.length; i++) {
      var match = true;
      for (var j = 0; j < seq.length; j++) {
        if (_buffer[i + j] != seq[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}

/// Serializes an HTTP/1.1 request into bytes, forcing Host to `phone-relay.invalid`.
Uint8List serializeHttpRequest(http.BaseRequest request, [List<int>? body]) {
  final bodyBytes = body != null
      ? (body is Uint8List ? body : Uint8List.fromList(body))
      : (request is http.Request ? Uint8List.fromList(request.bodyBytes) : Uint8List(0));

  var path = request.url.path;
  if (path.isEmpty) {
    path = '/';
  } else if (!path.startsWith('/')) {
    path = '/$path';
  }
  final target = request.url.hasQuery ? '$path?${request.url.query}' : path;

  final buffer = StringBuffer();
  buffer.write('${request.method.toUpperCase()} $target HTTP/1.1\r\n');
  buffer.write('Host: $relayHost\r\n');

  var hasContentLength = false;
  var hasTransferEncoding = false;

  for (final entry in request.headers.entries) {
    final lower = entry.key.toLowerCase();
    if (lower == 'host') continue;
    if (lower == 'content-length') hasContentLength = true;
    if (lower == 'transfer-encoding') hasTransferEncoding = true;
    buffer.write('${entry.key}: ${entry.value}\r\n');
  }

  if (!hasContentLength && !hasTransferEncoding) {
    if (bodyBytes.isNotEmpty ||
        request.method.toUpperCase() == 'POST' ||
        request.method.toUpperCase() == 'PUT' ||
        request.method.toUpperCase() == 'PATCH') {
      buffer.write('Content-Length: ${bodyBytes.length}\r\n');
    }
  }

  buffer.write('\r\n');
  final headerBytes = utf8.encode(buffer.toString());

  if (bodyBytes.isEmpty) {
    return headerBytes;
  }

  final out = Uint8List(headerBytes.length + bodyBytes.length);
  out.setRange(0, headerBytes.length, headerBytes);
  out.setRange(headerBytes.length, out.length, bodyBytes);
  return out;
}

/// Parses an HTTP/1.1 response from a byte stream into a streamed response.
Future<http.StreamedResponse> parseHttpResponse(
  Stream<List<int>> byteStream, {
  http.BaseRequest? request,
}) {
  final completer = Completer<http.StreamedResponse>();
  late final StreamSubscription<List<int>> subscription;
  late final StreamController<List<int>> bodyController;

  bodyController = StreamController<List<int>>(
    onCancel: () async {
      await subscription.cancel();
    },
  );

  void fail(Object error, [StackTrace? stackTrace]) {
    subscription.cancel();
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
    if (!bodyController.isClosed) {
      bodyController.addError(error, stackTrace);
      bodyController.close();
    }
  }

  final buffer = _ByteAccumulator();
  var headersParsed = false;
  var isChunked = false;
  var currentChunkRemaining = 0;
  var bodyRemaining = -1;
  _ChunkState chunkState = _ChunkState.readingSize;

  void processChunked() {
    while (true) {
      if (chunkState == _ChunkState.readingSize) {
        var crlfIndex = buffer.indexOfSequence(const [13, 10]);
        var delimiterLength = 2;
        if (crlfIndex == -1) {
          crlfIndex = buffer.indexOfSequence(const [10]);
          delimiterLength = 1;
        }
        if (crlfIndex == -1) break;

        final lineBytes = buffer.take(crlfIndex);
        buffer.take(delimiterLength);
        final line = utf8.decode(lineBytes).trim();
        if (line.isEmpty) continue;

        final sizeHex = line.split(';').first.trim();
        final size = int.parse(sizeHex, radix: 16);
        if (size == 0) {
          chunkState = _ChunkState.readingTrailers;
        } else {
          currentChunkRemaining = size;
          chunkState = _ChunkState.readingData;
        }
      } else if (chunkState == _ChunkState.readingData) {
        if (buffer.length == 0) break;
        final toTake = min(buffer.length, currentChunkRemaining);
        final chunkData = buffer.take(toTake);
        bodyController.add(chunkData);
        currentChunkRemaining -= toTake;
        if (currentChunkRemaining == 0) {
          chunkState = _ChunkState.readingDataCrlf;
        }
      } else if (chunkState == _ChunkState.readingDataCrlf) {
        if (buffer.length >= 2 && buffer._buffer[0] == 13 && buffer._buffer[1] == 10) {
          buffer.take(2);
          chunkState = _ChunkState.readingSize;
        } else if (buffer.length >= 1 && buffer._buffer[0] == 10) {
          buffer.take(1);
          chunkState = _ChunkState.readingSize;
        } else {
          break;
        }
      } else if (chunkState == _ChunkState.readingTrailers) {
        var crlfIndex = buffer.indexOfSequence(const [13, 10]);
        var delimiterLength = 2;
        if (crlfIndex == -1) {
          crlfIndex = buffer.indexOfSequence(const [10]);
          delimiterLength = 1;
        }
        if (crlfIndex == -1) break;

        final lineBytes = buffer.take(crlfIndex);
        buffer.take(delimiterLength);
        final line = utf8.decode(lineBytes).trim();
        if (line.isEmpty) {
          chunkState = _ChunkState.done;
          if (!bodyController.isClosed) bodyController.close();
          break;
        }
      } else if (chunkState == _ChunkState.done) {
        break;
      }
    }
  }

  void processFixedLength() {
    if (bodyRemaining == 0) {
      if (!bodyController.isClosed) bodyController.close();
      return;
    }
    if (buffer.length > 0) {
      final toTake = min(buffer.length, bodyRemaining);
      bodyController.add(buffer.take(toTake));
      bodyRemaining -= toTake;
      if (bodyRemaining == 0) {
        if (!bodyController.isClosed) bodyController.close();
      }
    }
  }

  void processStreamUntilClose() {
    if (buffer.length > 0) {
      bodyController.add(buffer.takeAll());
    }
  }

  void processBody() {
    if (bodyController.isClosed) return;
    if (isChunked) {
      processChunked();
    } else if (bodyRemaining >= 0) {
      processFixedLength();
    } else {
      processStreamUntilClose();
    }
  }

  subscription = byteStream.listen(
    (data) {
      try {
        if (byteStream is YamuxStream) {
          byteStream.consumed(data.length);
        }
        buffer.add(data);

        if (!headersParsed) {
          var headerEnd = buffer.indexOfSequence(const [13, 10, 13, 10]);
          var delimiterLength = 4;
          if (headerEnd == -1) {
            headerEnd = buffer.indexOfSequence(const [10, 10]);
            delimiterLength = 2;
          }
          if (headerEnd == -1) return;

          final headerBytes = buffer.take(headerEnd);
          buffer.take(delimiterLength);

          final headerText = utf8.decode(headerBytes);
          final lines = headerText.split(RegExp(r'\r?\n'));
          if (lines.isEmpty || lines[0].trim().isEmpty) {
            fail(const FormatException('Empty HTTP response'));
            return;
          }

          final statusLine = lines[0].trim();
          final firstSpace = statusLine.indexOf(' ');
          if (firstSpace == -1) {
            fail(FormatException('Invalid HTTP status line: $statusLine'));
            return;
          }
          final secondSpace = statusLine.indexOf(' ', firstSpace + 1);
          final int statusCode;
          final String? reasonPhrase;
          if (secondSpace == -1) {
            statusCode = int.parse(statusLine.substring(firstSpace + 1));
            reasonPhrase = null;
          } else {
            statusCode = int.parse(statusLine.substring(firstSpace + 1, secondSpace));
            reasonPhrase = statusLine.substring(secondSpace + 1);
          }

          final headers = <String, String>{};
          for (var i = 1; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.isEmpty) continue;
            final colon = line.indexOf(':');
            if (colon == -1) continue;
            final key = line.substring(0, colon).trim().toLowerCase();
            final value = line.substring(colon + 1).trim();
            if (headers.containsKey(key)) {
              headers[key] = '${headers[key]}, $value';
            } else {
              headers[key] = value;
            }
          }

          final isHead = request?.method.toUpperCase() == 'HEAD';
          final isNoBodyStatus = (statusCode >= 100 && statusCode < 200) || statusCode == 204 || statusCode == 304;

          int? parsedContentLength;
          if (headers.containsKey('content-length')) {
            parsedContentLength = int.tryParse(headers['content-length']!);
          }

          final transferEncoding = headers['transfer-encoding']?.toLowerCase() ?? '';
          isChunked = transferEncoding.contains('chunked');

          if (isHead || isNoBodyStatus) {
            bodyRemaining = 0;
            if (!bodyController.isClosed) bodyController.close();
          } else if (isChunked) {
            bodyRemaining = -1;
          } else if (parsedContentLength != null) {
            bodyRemaining = parsedContentLength;
            if (bodyRemaining == 0) {
              if (!bodyController.isClosed) bodyController.close();
            }
          } else {
            bodyRemaining = -1;
          }

          headersParsed = true;

          final streamedResponse = http.StreamedResponse(
            bodyController.stream,
            statusCode,
            contentLength: parsedContentLength,
            request: request,
            headers: headers,
            reasonPhrase: reasonPhrase,
          );
          completer.complete(streamedResponse);
          processBody();
        } else {
          processBody();
        }
      } catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    },
    onError: (error, stackTrace) {
      fail(error, stackTrace);
    },
    onDone: () {
      if (!headersParsed && !completer.isCompleted) {
        completer.completeError(
          http.ClientException('Connection closed before HTTP headers were received'),
        );
      }
      if (!bodyController.isClosed) {
        if (bodyRemaining > 0 || (isChunked && chunkState != _ChunkState.done)) {
          bodyController.addError(
            http.ClientException('Connection closed prematurely'),
          );
        }
        bodyController.close();
      }
    },
    cancelOnError: false,
  );

  return completer.future;
}

/// HTTP client transmitting HTTP/1.1 requests over yamux streams.
class YamuxHttpClient extends http.BaseClient {
  final YamuxSession session;

  YamuxHttpClient(this.session);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    final serialized = serializeHttpRequest(request, bodyBytes);
    final stream = session.openStream();
    stream.add(serialized);
    await stream.writable;
    final accept = request.headers.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'accept',
          orElse: () => const MapEntry('', ''),
        )
        .value;
    if (accept.toLowerCase() != 'text/event-stream') {
      stream.finish();
    }
    return parseHttpResponse(stream, request: request);
  }
}

typedef StreamTransportClient = YamuxHttpClient;
