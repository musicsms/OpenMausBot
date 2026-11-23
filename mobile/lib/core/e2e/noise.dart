import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:nibble/core/e2e/credentials.dart';
import 'package:nibble/core/e2e/crypto.dart';

const String protocolName = 'Noise_NKpsk0_P256_AESGCM_SHA256';
const int publicKeyBytes = 65;
const int tagBytes = 16;
const int maxRecordBytes = 65535;
const int maxRecordPlaintext = maxRecordBytes - tagBytes;
const int maxHandshakePayload = 512;
const int maxHandshakeMessage = publicKeyBytes + maxHandshakePayload + tagBytes;
const int connBytes = 16;
const int maxAppChars = 40;
const int nonceLimit = 4294967296;
const int transportRelay = 0x01;
const int transportDirect = 0x02;

class NoiseError implements Exception {
  final String reason;

  NoiseError(this.reason);

  @override
  String toString() => 'NoiseError: $reason';
}

Uint8List prologue(int transport) {
  final prefix = utf8.encode('omb-e2e/1');
  final result = Uint8List(prefix.length + 2);
  result.setRange(0, prefix.length, prefix);
  result[prefix.length] = 0x00;
  result[prefix.length + 1] = transport;
  return result;
}

Uint8List _nonceBytes(int n) {
  final nonce = Uint8List(12);
  final byteData = ByteData.sublistView(nonce);
  byteData.setUint64(4, n, Endian.big);
  return nonce;
}

class CipherState {
  final Uint8List? _key;
  int _n;

  CipherState({Uint8List? key, int n = 0})
      : _key = key != null ? Uint8List.fromList(key) : null,
        _n = n;

  bool get hasKey => _key != null;

  int get nonce => _n;

  Uint8List? get keyBytes => _key != null ? Uint8List.fromList(_key) : null;

  Uint8List encryptWithAd(Uint8List ad, Uint8List plaintext) {
    if (_key == null) return Uint8List.fromList(plaintext);
    if (_n >= nonceLimit) throw NoiseError('nonce_exhausted');
    final out = AesGcm256.seal(_key, _nonceBytes(_n), ad, plaintext);
    _n += 1;
    return out;
  }

  Uint8List decryptWithAd(Uint8List ad, Uint8List ciphertext) {
    if (_key == null) return Uint8List.fromList(ciphertext);
    if (_n >= nonceLimit) throw NoiseError('nonce_exhausted');
    if (ciphertext.length < tagBytes) throw NoiseError('short_ciphertext');
    try {
      final out = AesGcm256.open(_key, _nonceBytes(_n), ad, ciphertext);
      _n += 1;
      return out;
    } catch (_) {
      throw NoiseError('aead');
    }
  }
}

class SymmetricState {
  Uint8List ck;
  Uint8List h;
  CipherState cipher;
  final List<Map<String, dynamic>>? trace;

  SymmetricState({
    required this.h,
    required this.ck,
    CipherState? cipher,
    this.trace,
  }) : cipher = cipher ?? CipherState();

  factory SymmetricState.initialize({List<Map<String, dynamic>>? trace}) {
    final nameBytes = utf8.encode(protocolName);
    final initH = Uint8List(32);
    if (nameBytes.length <= 32) {
      initH.setRange(0, nameBytes.length, nameBytes);
    } else {
      final digest = crypto.sha256.convert(nameBytes).bytes;
      initH.setRange(0, 32, digest);
    }
    return SymmetricState(
      h: initH,
      ck: Uint8List.fromList(initH),
      trace: trace,
    );
  }

  SymmetricState clone() {
    return SymmetricState(
      h: Uint8List.fromList(h),
      ck: Uint8List.fromList(ck),
      cipher: CipherState(
        key: cipher.keyBytes,
        n: cipher.nonce,
      ),
      trace: trace != null ? List<Map<String, dynamic>>.from(trace!) : null,
    );
  }

  void mark(String step) {
    if (trace != null) {
      trace!.add({
        'step': step,
        'h': hex.encode(h),
        'ck': hex.encode(ck),
        'k': cipher.keyBytes != null ? hex.encode(cipher.keyBytes!) : null,
      });
    }
  }

  void mixHash(Uint8List data) {
    final builder = BytesBuilder(copy: false)
      ..add(h)
      ..add(data);
    h = Uint8List.fromList(crypto.sha256.convert(builder.takeBytes()).bytes);
  }

  void mixKey(Uint8List ikm) {
    final derived = hkdf(ck, ikm, 2);
    ck = derived[0];
    cipher = CipherState(key: derived[1]);
  }

  void mixKeyAndHash(Uint8List ikm) {
    final derived = hkdf(ck, ikm, 3);
    ck = derived[0];
    mixHash(derived[1]);
    cipher = CipherState(key: derived[2]);
  }

  Uint8List encryptAndHash(Uint8List plaintext) {
    final out = cipher.encryptWithAd(h, plaintext);
    mixHash(out);
    return out;
  }

  Uint8List decryptAndHash(Uint8List ciphertext) {
    final out = cipher.decryptWithAd(h, ciphertext);
    mixHash(ciphertext);
    return out;
  }

  List<CipherState> split() {
    final derived = hkdf(ck, Uint8List(0), 2);
    return [CipherState(key: derived[0]), CipherState(key: derived[1])];
  }
}

class RecordCipher {
  final CipherState state;

  RecordCipher(this.state);

  int get nonce => state.nonce;

  Uint8List seal(Uint8List plaintext) {
    if (plaintext.length > maxRecordPlaintext) {
      throw NoiseError('record_too_large');
    }
    return state.encryptWithAd(Uint8List(0), plaintext);
  }

  Uint8List open(Uint8List record) {
    if (record.length > maxRecordBytes) {
      throw NoiseError('record_too_large');
    }
    return state.decryptWithAd(Uint8List(0), record);
  }
}

class TransportRecordCodec {
  final RecordCipher cipher;

  TransportRecordCodec(this.cipher);

  int get nonce => cipher.nonce;

  Uint8List seal(Uint8List plaintext) => cipher.seal(plaintext);

  Uint8List open(Uint8List record) => cipher.open(record);

  Uint8List encodeRecord(Uint8List plaintext) => cipher.seal(plaintext);

  Uint8List decodeRecord(Uint8List record) => cipher.open(record);

  Uint8List encode(Uint8List plaintext) {
    final sealed = cipher.seal(plaintext);
    final len = sealed.length;
    if (len > maxRecordBytes) {
      throw NoiseError('record_too_large');
    }
    final result = Uint8List(2 + len);
    result[0] = (len >> 8) & 0xff;
    result[1] = len & 0xff;
    result.setRange(2, 2 + len, sealed);
    return result;
  }

  Uint8List decode(Uint8List prefixedRecord) {
    if (prefixedRecord.length < 2) {
      throw NoiseError('short_record');
    }
    final len = (prefixedRecord[0] << 8) | prefixedRecord[1];
    if (prefixedRecord.length != 2 + len) {
      throw NoiseError('length_mismatch');
    }
    return cipher.open(Uint8List.sublistView(prefixedRecord, 2));
  }
}

class NoiseInitiatorSession {
  final Uint8List transportPublicKey;
  final Uint8List psk;
  final int prologueByte;
  final Uint8List? fixedEphemeralPrivate;
  final List<Map<String, dynamic>>? trace;

  late final SymmetricState _state;
  P256KeyPair? _ephemeralKeyPair;
  String? _conn;
  bool _msg1Written = false;
  bool _isComplete = false;

  RecordCipher? _sendCipher;
  RecordCipher? _receiveCipher;
  TransportRecordCodec? _sendCodec;
  TransportRecordCodec? _receiveCodec;
  Uint8List? _kPc;
  Uint8List? _kCp;
  Uint8List? _handshakeHash;

  NoiseInitiatorSession({
    required this.transportPublicKey,
    required this.psk,
    required this.prologueByte,
    this.fixedEphemeralPrivate,
    String? conn,
    this.trace,
  }) : _conn = conn {
    if (!P256.validatePublicKey(transportPublicKey)) {
      throw NoiseError('bad_point');
    }
    if (psk.length != 32) {
      throw NoiseError('bad_psk');
    }
    _state = SymmetricState.initialize(trace: trace);
    _state.mark('init');
    _state.mixHash(prologue(prologueByte));
    _state.mark('prologue');
    _state.mixHash(transportPublicKey);
    _state.mark('s');
  }

  bool get isComplete => _isComplete;

  RecordCipher get sendCipher {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _sendCipher!;
  }

  RecordCipher get receiveCipher {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _receiveCipher!;
  }

  TransportRecordCodec get sendCodec {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _sendCodec!;
  }

  TransportRecordCodec get receiveCodec {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _receiveCodec!;
  }

  Uint8List get kPc {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _kPc!;
  }

  Uint8List get kCp {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _kCp!;
  }

  Uint8List get handshakeHash {
    if (!_isComplete) throw StateError('Handshake not complete');
    return _handshakeHash!;
  }

  Uint8List writeMessage1({List<int> payload = const []}) {
    if (_msg1Written) throw NoiseError('already_written');
    if (payload.length > maxHandshakePayload) {
      throw NoiseError('payload_too_large');
    }

    try {
      final str = utf8.decode(payload);
      final json = jsonDecode(str);
      if (json is Map && json['conn'] is String) {
        _conn ??= json['conn'] as String;
      }
    } catch (_) {}

    _state.mixKeyAndHash(psk);
    _state.mark('msg1.psk');

    if (fixedEphemeralPrivate != null) {
      final pub = P256.publicKeyFromPrivate(fixedEphemeralPrivate!);
      _ephemeralKeyPair = P256KeyPair(
        privateKey: fixedEphemeralPrivate!,
        publicKey: pub,
      );
    } else {
      _ephemeralKeyPair = P256.generateKeyPair();
    }

    _state.mixHash(_ephemeralKeyPair!.publicKey);
    _state.mixKey(_ephemeralKeyPair!.publicKey);
    _state.mark('msg1.e');

    final es = P256.computeSecret(
      _ephemeralKeyPair!.privateKey,
      transportPublicKey,
    );
    _state.mixKey(es);
    _state.mark('msg1.es');

    final encryptedPayload = _state.encryptAndHash(
      payload is Uint8List ? payload : Uint8List.fromList(payload),
    );
    _state.mark('msg1.payload');

    _msg1Written = true;

    final result = Uint8List(_ephemeralKeyPair!.publicKey.length + encryptedPayload.length);
    result.setRange(0, _ephemeralKeyPair!.publicKey.length, _ephemeralKeyPair!.publicKey);
    result.setRange(
      _ephemeralKeyPair!.publicKey.length,
      result.length,
      encryptedPayload,
    );
    return result;
  }

  Uint8List readMessage2(Uint8List message2) {
    if (!_msg1Written) throw NoiseError('not_started');
    if (_isComplete) throw NoiseError('finished');

    if (message2.length < publicKeyBytes + tagBytes ||
        message2.length > maxHandshakeMessage) {
      throw NoiseError('message2_size');
    }

    final re = Uint8List.sublistView(message2, 0, publicKeyBytes);
    if (!P256.validatePublicKey(re)) {
      throw NoiseError('bad_point');
    }
    final ee = P256.computeSecret(_ephemeralKeyPair!.privateKey, re);

    _state.mixHash(re);
    _state.mixKey(re);
    _state.mark('msg2.e');

    _state.mixKey(ee);
    _state.mark('msg2.ee');

    final ciphertext = Uint8List.sublistView(message2, publicKeyBytes);
    final payload2 = _state.decryptAndHash(ciphertext);
    _state.mark('msg2.payload');

    if (payload2.length > maxHandshakePayload) {
      throw NoiseError('payload2_version');
    }

    Map<dynamic, dynamic>? json;
    try {
      final str = utf8.decode(payload2);
      final parsed = jsonDecode(str);
      if (parsed is Map) {
        json = parsed;
      }
    } catch (_) {
      throw NoiseError('payload2_version');
    }

    if (json == null || json['v'] != 1) {
      throw NoiseError('payload2_version');
    }
    if (_conn == null || json['conn'] != _conn) {
      throw NoiseError('payload2_conn');
    }

    final splitCiphers = _state.split();
    final pc = splitCiphers[0];
    final cp = splitCiphers[1];

    _kPc = pc.keyBytes;
    _kCp = cp.keyBytes;
    _handshakeHash = Uint8List.fromList(_state.h);

    _sendCipher = RecordCipher(pc);
    _receiveCipher = RecordCipher(cp);
    _sendCodec = TransportRecordCodec(_sendCipher!);
    _receiveCodec = TransportRecordCodec(_receiveCipher!);

    _isComplete = true;
    return payload2;
  }
}

Uint8List encodePayload1({required Uint8List conn, required String app}) {
  if (conn.length != connBytes) {
    throw ArgumentError('conn must be $connBytes bytes');
  }
  if (app.length > maxAppChars) {
    throw ArgumentError('app length cannot exceed $maxAppChars characters');
  }
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'v': 1, 'conn': b64u(conn), 'app': app})),
  );
}

Uint8List encodePayload2({required String conn}) {
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'v': 1, 'conn': conn})),
  );
}
