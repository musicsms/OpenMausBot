import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'credentials.dart';
import 'descriptor.dart';
import 'noise.dart';
import 'stream_transport.dart';
import 'yamux.dart';

enum RelayClientStatus {
  idle,
  connecting,
  connected,
  offline,
  error,
  closed,
}

class RelayException implements Exception {
  final String message;
  final int? code;
  final String? node;

  RelayException(this.message, {this.code, this.node});

  @override
  String toString() => 'RelayException: $message${code != null ? ' (code: $code)' : ''}';
}

class RelayOfflineException extends RelayException {
  RelayOfflineException([super.message = 'computer asleep or offline', String? node])
      : super(code: 4404, node: node);
}

abstract class RelayWebSocket {
  Stream<dynamic> get stream;
  void add(dynamic data);
  int? get closeCode;
  String? get closeReason;
  Future<void> close([int? code, String? reason]);
}

class IORelayWebSocket implements RelayWebSocket {
  final WebSocket _ws;

  IORelayWebSocket(this._ws);

  @override
  Stream<dynamic> get stream => _ws;

  @override
  void add(dynamic data) => _ws.add(data);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}

typedef WebSocketConnector = Future<RelayWebSocket> Function(
  Uri uri, {
  Iterable<String>? protocols,
});

Future<RelayWebSocket> defaultWebSocketConnector(
  Uri uri, {
  Iterable<String>? protocols,
}) async {
  final ws = await WebSocket.connect(uri.toString(), protocols: protocols);
  return IORelayWebSocket(ws);
}

class PhoneRelayClient {
  final E2EDescriptor descriptor;
  final Uint8List psk;
  final Uint8List adm;
  final WebSocketConnector connector;
  final String app;
  final Uint8List? fixedEphemeralPrivate;
  final Uint8List? fixedConn;
  final Duration timeout;

  RelayClientStatus _status = RelayClientStatus.idle;
  String? _errorMessage;
  String? _connectedNode;
  RelayWebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  NoiseInitiatorSession? _noiseSession;
  YamuxSession? _yamuxSession;
  YamuxHttpClient? _httpClient;
  bool _deviceRemoved = false;

  PhoneRelayClient({
    required this.descriptor,
    Uint8List? psk,
    Uint8List? adm,
    String? credentialToken,
    Uint8List? credentialHash,
    this.connector = defaultWebSocketConnector,
    this.app = 'mobile',
    this.fixedEphemeralPrivate,
    this.fixedConn,
    this.timeout = const Duration(seconds: 10),
  })  : psk = _resolvePsk(descriptor, psk, credentialToken, credentialHash),
        adm = _resolveAdm(descriptor, adm, credentialToken, credentialHash);

  static Uint8List _resolvePsk(
    E2EDescriptor desc,
    Uint8List? pskBytes,
    String? token,
    Uint8List? credHash,
  ) {
    if (pskBytes != null) return pskBytes;
    final hash = credHash ?? (token != null ? credentialHash(token) : null);
    if (hash == null) {
      throw ArgumentError('Either psk, credentialToken or credentialHash must be provided');
    }
    return derivePsk(hash, keyId(desc.transportPublicKey));
  }

  static Uint8List _resolveAdm(
    E2EDescriptor desc,
    Uint8List? admBytes,
    String? token,
    Uint8List? credHash,
  ) {
    if (admBytes != null) return admBytes;
    if (desc.hostId == null) {
      throw ArgumentError('Descriptor must have hostId for relay admission');
    }
    final hash = credHash ?? (token != null ? credentialHash(token) : null);
    if (hash == null) {
      throw ArgumentError('Either adm, credentialToken or credentialHash must be provided');
    }
    return deriveAdmission(hash, desc.hostId!);
  }

  RelayClientStatus get status => _status;
  bool get isConnected => _status == RelayClientStatus.connected;
  bool get isOffline => _status == RelayClientStatus.offline;
  String? get errorMessage => _errorMessage;
  String? get connectedNode => _connectedNode;
  NoiseInitiatorSession? get noiseSession => _noiseSession;
  YamuxSession? get yamuxSession => _yamuxSession;
  bool get isDeviceRemoved => _deviceRemoved;

  http.Client get httpClient {
    if (_httpClient == null || _status != RelayClientStatus.connected) {
      throw StateError('PhoneRelayClient is not connected');
    }
    return _httpClient!;
  }

  Future<void> connect() async {
    if (_status == RelayClientStatus.connected) return;
    if (!descriptor.hasRelay) {
      throw RelayException('Descriptor has no relay endpoints');
    }

    _status = RelayClientStatus.connecting;
    _errorMessage = null;

    var allFailedWith4404 = true;
    RelayException? lastError;

    for (final node in descriptor.relayNodes) {
      try {
        await _connectToNode(node);
        return;
      } on RelayException catch (e) {
        lastError = e;
        if (e.code == 4404) {
          continue;
        }
        allFailedWith4404 = false;
        if (e.code == 4401 || e.code == 4001) {
          _status = RelayClientStatus.error;
          _errorMessage = e.message;
          rethrow;
        }
      } catch (e) {
        allFailedWith4404 = false;
        lastError = RelayException('Connection error on node $node: $e', node: node);
      }
    }

    if (allFailedWith4404) {
      _status = RelayClientStatus.offline;
      _errorMessage = 'computer asleep or offline';
      throw RelayOfflineException('computer asleep or offline');
    }

    _status = RelayClientStatus.error;
    _errorMessage = lastError?.message ?? 'Connection failed';
    throw lastError ?? RelayException(_errorMessage!);
  }

  Future<void> _connectToNode(String node) async {
    final uri = Uri.parse('wss://$node/v1/phone');
    final socket = await connector(uri, protocols: const ['omb-relay.v1']).timeout(timeout);
    final completer = Completer<void>();

    var readyReceived = false;
    NoiseInitiatorSession? noise;
    StreamSubscription<dynamic>? subscription;

    void cleanup() {
      subscription?.cancel();
      socket.close();
    }

    subscription = socket.stream.listen(
      (data) {
        if (!readyReceived) {
          if (data is String) {
            try {
              final json = jsonDecode(data);
              if (json is Map && json['t'] == 'ready') {
                readyReceived = true;
                noise = NoiseInitiatorSession(
                  transportPublicKey: descriptor.transportPublicKey,
                  psk: psk,
                  prologueByte: transportRelay,
                  fixedEphemeralPrivate: fixedEphemeralPrivate,
                );
                final conn = fixedConn ?? _randomConn();
                final payload1 = encodePayload1(conn: conn, app: app);
                final msg1 = noise!.writeMessage1(payload: payload1);
                socket.add(msg1);
                return;
              }
            } catch (_) {}
          }
          socket.close(4400, 'malformed or unexpected message');
          if (!completer.isCompleted) {
            completer.completeError(
              RelayException('Unexpected message before ready', code: 4400, node: node),
            );
          }
          return;
        }

        if (!noise!.isComplete) {
          if (data is List<int>) {
            try {
              final msg2 = data is Uint8List ? data : Uint8List.fromList(data);
              noise!.readMessage2(msg2);
              _setupYamux(socket, subscription!, noise!, node);
              completer.complete();
              return;
            } catch (e) {
              socket.close(4000, 'handshake failed');
              if (!completer.isCompleted) {
                completer.completeError(
                  RelayException('Handshake error: $e', code: 4000, node: node),
                );
              }
              return;
            }
          } else {
            socket.close(4000, 'text during handshake');
            if (!completer.isCompleted) {
              completer.completeError(
                RelayException('Unexpected text during handshake', code: 4000, node: node),
              );
            }
            return;
          }
        }

        if (data is List<int>) {
          try {
            final record = data is Uint8List ? data : Uint8List.fromList(data);
            final plaintext = noise!.receiveCipher.open(record);
            final frame = YamuxFrame.decode(plaintext);
            _yamuxSession?.receive(frame);
          } catch (e) {
            socket.close(4000, 'protocol error');
            _handleDisconnect(RelayException('Transport record error: $e', code: 4000, node: node));
          }
        } else {
          socket.close(4000, 'text after handshake');
          _handleDisconnect(
            RelayException('Unexpected text message after handshake', code: 4000, node: node),
          );
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(RelayException('Socket error: $error', node: node));
        } else {
          _handleDisconnect(RelayException('Socket error: $error', node: node));
        }
      },
      onDone: () {
        final code = socket.closeCode;
        final reason = socket.closeReason;
        final ex = RelayException(
          reason ?? 'Socket closed with code $code',
          code: code,
          node: node,
        );
        if (!completer.isCompleted) {
          completer.completeError(ex);
        } else {
          _handleDisconnect(ex);
        }
      },
    );

    final phoneAuth = jsonEncode({
      't': 'phone',
      'v': 1,
      'hid': b64u(descriptor.hostId!),
      'adm': b64u(adm),
    });
    socket.add(phoneAuth);

    try {
      await completer.future.timeout(timeout);
    } catch (e) {
      cleanup();
      rethrow;
    }
  }

  void _setupYamux(
    RelayWebSocket socket,
    StreamSubscription<dynamic> subscription,
    NoiseInitiatorSession noise,
    String node,
  ) {
    _socket = socket;
    _socketSubscription = subscription;
    _noiseSession = noise;
    _connectedNode = node;
    _status = RelayClientStatus.connected;

    _yamuxSession = YamuxSession(
      role: YamuxRole.phone,
      onSend: (frame) {
        if (_status != RelayClientStatus.connected) return;
        try {
          final frameBytes = frame.encode();
          final record = noise.sendCipher.seal(frameBytes);
          socket.add(record);
        } catch (e) {
          socket.close(4000, 'send error');
          _handleDisconnect(RelayException('Send error: $e', code: 4000, node: node));
        }
      },
      onGoAway: (code) {
        if (code == YamuxGoAway.removed) {
          _deviceRemoved = true;
        }
      },
    );

    _httpClient = YamuxHttpClient(_yamuxSession!);
  }

  void _handleDisconnect(RelayException error) {
    if (_status == RelayClientStatus.closed) return;
    _status = RelayClientStatus.error;
    _errorMessage = error.message;
    _yamuxSession?.closeAll();
  }

  Future<void> close() async {
    if (_status == RelayClientStatus.closed) return;
    _status = RelayClientStatus.closed;
    try {
      _yamuxSession?.goAway(YamuxGoAway.normal);
      _yamuxSession?.closeAll();
    } catch (_) {}
    try {
      await _socket?.close(1000, 'normal close');
    } catch (_) {}
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket = null;
    _httpClient = null;
  }

  Uint8List _randomConn() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}
