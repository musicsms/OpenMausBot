import 'dart:convert';
import 'dart:typed_data';

import 'credentials.dart';
import 'crypto.dart';

const int descriptorVersion = 1;
const int maxDescriptorChars = 1024;
const int maxRelayNodes = 4;

final RegExp _dnsNameRegex = RegExp(
  r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
);

bool isValidRelayHost(dynamic host) {
  if (host is! String) return false;
  if (host.isEmpty || host.length > 253) return false;
  return _dnsNameRegex.hasMatch(host);
}

class E2EDescriptor {
  final int version;
  final String k;
  final Uint8List transportPublicKey;
  final String? h;
  final Uint8List? hostId;
  final List<String> relayNodes;
  final String? routes;

  E2EDescriptor({
    this.version = descriptorVersion,
    required this.k,
    required this.transportPublicKey,
    this.h,
    this.hostId,
    this.relayNodes = const [],
    this.routes,
  });

  bool get hasRelay => hostId != null && relayNodes.isNotEmpty;

  factory E2EDescriptor.parseJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v is! int || v != descriptorVersion) {
      throw const FormatException('Unsupported or invalid descriptor version');
    }

    final kStr = json['k'];
    if (kStr is! String) {
      throw const FormatException('Missing or invalid transport public key field');
    }
    final pubBytes = fromB64u(kStr);
    if (pubBytes == null || pubBytes.length != 65 || !P256.validatePublicKey(pubBytes)) {
      throw const FormatException('Invalid transport public key');
    }

    final hasHost = json.containsKey('h') && json['h'] != null;
    final hasRelays = json.containsKey('r') && json['r'] != null;
    if (hasHost != hasRelays) {
      throw const FormatException('Relay fields h and r must both be present or both absent');
    }

    String? hStr;
    Uint8List? hostIdBytes;
    final nodes = <String>[];

    if (hasHost) {
      hStr = json['h'] as String?;
      if (hStr == null) {
        throw const FormatException('Invalid host id type');
      }
      hostIdBytes = fromB64u(hStr);
      if (hostIdBytes == null || hostIdBytes.length != hostIdBytesLength) {
        throw const FormatException('Invalid host id bytes');
      }

      final rList = json['r'];
      if (rList is! List || rList.isEmpty || rList.length > maxRelayNodes) {
        throw const FormatException('Relay nodes list must contain between 1 and 4 entries');
      }

      for (final node in rList) {
        if (!isValidRelayHost(node)) {
          throw FormatException('Invalid relay host: $node');
        }
        nodes.add(node as String);
      }
    }

    String? routesVal;
    if (json.containsKey('routes') && json['routes'] != null) {
      final r = json['routes'];
      if (r != 'any' && r != 'local') {
        throw FormatException('Invalid routes descriptor value: $r');
      }
      routesVal = r as String;
    }

    return E2EDescriptor(
      version: v,
      k: kStr,
      transportPublicKey: pubBytes,
      h: hStr,
      hostId: hostIdBytes,
      relayNodes: List.unmodifiable(nodes),
      routes: routesVal,
    );
  }

  factory E2EDescriptor.parse(dynamic input) {
    if (input is Map<String, dynamic>) {
      return E2EDescriptor.parseJson(input);
    }
    if (input is String) {
      if (input.length > maxDescriptorChars) {
        throw const FormatException('Descriptor exceeds maximum allowed length');
      }
      final trimmed = input.trim();
      if (trimmed.startsWith('{')) {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Descriptor JSON must be an object');
        }
        return E2EDescriptor.parseJson(decoded);
      }
      final rawBytes = fromB64u(trimmed);
      if (rawBytes == null) {
        throw const FormatException('Invalid base64url descriptor');
      }
      final decodedJson = jsonDecode(utf8.decode(rawBytes));
      if (decodedJson is! Map<String, dynamic>) {
        throw const FormatException('Descriptor JSON must be an object');
      }
      return E2EDescriptor.parseJson(decodedJson);
    }
    throw const FormatException('Unsupported descriptor input type');
  }

  static E2EDescriptor? tryParse(dynamic input) {
    try {
      return E2EDescriptor.parse(input);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'k': k,
        if (h != null) 'h': h,
        if (relayNodes.isNotEmpty) 'r': relayNodes,
        if (routes != null) 'routes': routes,
      };

  String toB64u() => b64u(Uint8List.fromList(utf8.encode(jsonEncode(toJson()))));
}

const int hostIdBytesLength = hostIdBytes;
