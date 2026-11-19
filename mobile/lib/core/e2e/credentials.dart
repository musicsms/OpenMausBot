import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const int keyIdBytes = 16;
const int hostIdBytes = 16;
const int KEY_ID_BYTES = keyIdBytes;
const int HOST_ID_BYTES = hostIdBytes;

final RegExp _b64uRegex = RegExp(r'^[A-Za-z0-9_-]*$');
final List<int> _pskLabel = utf8.encode('omb-e2e psk v1');
final List<int> _admissionLabel = utf8.encode('omb-relay admission v1');

String b64u(Uint8List bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Uint8List? fromB64u(String text) {
  if (!_b64uRegex.hasMatch(text) || text.length % 4 == 1) {
    return null;
  }
  try {
    final normalized = base64Url.normalize(text);
    final bytes = Uint8List.fromList(base64Url.decode(normalized));
    if (b64u(bytes) != text) {
      return null;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List credentialHash(String token) =>
    Uint8List.fromList(sha256.convert(utf8.encode(token)).bytes);

Uint8List keyId(Uint8List transportPublicKey) =>
    Uint8List.fromList(sha256.convert(transportPublicKey).bytes.sublist(0, keyIdBytes));

Uint8List derivePsk(Uint8List credHash, Uint8List transportKeyId) {
  final hmac = Hmac(sha256, credHash);
  final message = BytesBuilder(copy: false)
    ..add(_pskLabel)
    ..add(transportKeyId);
  return Uint8List.fromList(hmac.convert(message.takeBytes()).bytes);
}

Uint8List psk(Uint8List credHash, Uint8List transportKeyId) =>
    derivePsk(credHash, transportKeyId);

Uint8List deriveAdmission(Uint8List credHash, Uint8List hostId) {
  final hmac = Hmac(sha256, credHash);
  final message = BytesBuilder(copy: false)
    ..add(_admissionLabel)
    ..add(hostId);
  return Uint8List.fromList(hmac.convert(message.takeBytes()).bytes);
}

Uint8List admission(Uint8List credHash, Uint8List hostId) =>
    deriveAdmission(credHash, hostId);

String admissionHash(Uint8List adm) =>
    b64u(Uint8List.fromList(sha256.convert(adm).bytes));
