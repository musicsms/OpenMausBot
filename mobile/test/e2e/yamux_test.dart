import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:nibble/core/e2e/yamux.dart';

Map<String, dynamic> _runScript(
  YamuxRole role,
  String? accept,
  List<dynamic> steps,
) {
  final sent = <String>[];
  late final YamuxSession mux;
  mux = YamuxSession(
    role: role,
    onSend: (frame) => sent.add(hex.encode(frame.encode())),
    onOpened: (id) {
      if (accept != 'never') mux.accept(id);
    },
  );

  for (var index = 0; index < steps.length; index++) {
    final step = steps[index] as Map<String, dynamic>;
    try {
      if (step.containsKey('open')) {
        mux.open();
      } else if (step.containsKey('consume')) {
        final consume = step['consume'] as Map<String, dynamic>;
        mux.consumed(consume['stream'] as int, consume['bytes'] as int);
      } else {
        final stepIn = step['in'] as Map<String, dynamic>;
        final headerBytes = Uint8List.fromList(hex.decode(stepIn['header'] as String));
        final byteData = ByteData.sublistView(headerBytes);
        final length = byteData.getUint32(8, Endian.big);
        final Uint8List payload;
        if (stepIn['fill'] != null) {
          payload = Uint8List(length)..fillRange(0, length, stepIn['fill'] as int);
        } else if (stepIn['payload'] != null) {
          payload = Uint8List.fromList(hex.decode(stepIn['payload'] as String));
        } else {
          payload = Uint8List(0);
        }
        final fullBytes = Uint8List(headerBytes.length + payload.length)
          ..setRange(0, headerBytes.length, headerBytes)
          ..setRange(headerBytes.length, headerBytes.length + payload.length, payload);
        mux.receive(YamuxFrame.decode(fullBytes));
      }
    } on YamuxError {
      return {'errorAt': index};
    }
  }
  return {'sent': sent};
}

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V4 Yamux Frames in Transport Records', () {
    test('Decodes and re-encodes all yamux frames from V4 records', () {
      final records = (vectors['V4']['records'] as List).cast<Map<String, dynamic>>();
      for (final r in records) {
        final frameHex = r['frame'] as String;
        final decoded = YamuxFrame.decode(Uint8List.fromList(hex.decode(frameHex)));
        final encoded = decoded.encode();
        expect(hex.encode(encoded), equals(frameHex));
      }
    });
  });

  group('V5 Yamux Codec', () {
    test('Encodes and decodes yamux frames according to vector specifications', () {
      final rawFrames = vectors['V4']?['frames'] ?? vectors['V5'];
      final frames = (rawFrames as List).cast<Map<String, dynamic>>();
      for (final f in frames) {
        final expectedHex = f['hex'] as String;
        final dataHex = expectedHex.length > 24 ? expectedHex.substring(24) : null;
        final frame = YamuxFrame(
          type: f['type'] as int,
          flags: f['flags'] as int,
          streamId: f['streamId'] as int,
          length: f['length'] as int,
          data: f['data'] != null
              ? Uint8List.fromList(hex.decode(f['data'] as String))
              : (dataHex != null ? Uint8List.fromList(hex.decode(dataHex)) : Uint8List(0)),
        );
        final encoded = frame.encode();
        expect(hex.encode(encoded), equals(expectedHex), reason: 'Frame encode failed: ${f['name']}');

        final decoded = YamuxFrame.decode(Uint8List.fromList(hex.decode(expectedHex)));
        expect(decoded.type, equals(f['type']));
        expect(decoded.flags, equals(f['flags']));
        expect(decoded.streamId, equals(f['streamId']));
        expect(decoded.length, equals(f['length']));
        expect(hex.encode(decoded.encode()), equals(expectedHex));
      }
    });
  });

  group('V6 Invalid Frames', () {
    test('Rejects invalid frames with YamuxError', () {
      final invalidFrames = (vectors['V6']['frames'] as List).cast<Map<String, dynamic>>();
      for (final f in invalidFrames) {
        final frameHex = f['hex'] as String;
        expect(
          () => YamuxFrame.decode(Uint8List.fromList(hex.decode(frameHex))),
          throwsA(isA<YamuxError>()),
          reason: 'Failed to reject invalid frame: ${f['name']}',
        );
      }
    });
  });

  group('V6 Session Scenarios', () {
    final sessions = (vectors['V6']['sessions'] as List).cast<Map<String, dynamic>>();
    for (final s in sessions) {
      test('Session: ${s['name']}', () {
        final role = s['role'] == 'computer' ? YamuxRole.computer : YamuxRole.phone;
        final accept = s['accept'] as String?;
        final steps = s['steps'] as List<dynamic>;
        final expected = s['expect'] as Map<String, dynamic>;

        final actual = _runScript(role, accept, steps);
        expect(actual, equals(expected), reason: 'Session scenario failed: ${s['name']}');
      });
    }
  });

  group('Yamux Multiplexing & Stream Behaviors', () {
    test('Full bidirectional stream: open, write, accept, finish, close', () async {
      final log = <String>[];
      final phoneReceived = <int, List<Uint8List>>{};
      final computerReceived = <int, List<Uint8List>>{};

      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
        onAccepted: (id) => log.add('phone accepted $id'),
        onData: (id, data) {
          phoneReceived.putIfAbsent(id, () => []).add(data);
        },
        onEnded: (id) => log.add('phone ended $id'),
        onReset: (id) => log.add('phone reset $id'),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
        onOpened: (id) {
          log.add('computer opened $id');
          computer.accept(id);
        },
        onData: (id, data) {
          computerReceived.putIfAbsent(id, () => []).add(data);
        },
        onEnded: (id) => log.add('computer ended $id'),
        onReset: (id) => log.add('computer reset $id'),
      );

      final stream1 = phone.openStream();
      expect(stream1.id, equals(1));
      expect(phone.has(1), isTrue);

      final reqBytes = Uint8List.fromList(utf8.encode('GET /api/health HTTP/1.1\r\n\r\n'));
      final writtenPhone = stream1.write(reqBytes);
      expect(writtenPhone, equals(reqBytes.length));

      final respBytes = Uint8List.fromList(utf8.encode('HTTP/1.1 200 OK\r\n\r\n{"ok":true}'));
      final writtenComp = computer.write(1, respBytes);
      expect(writtenComp, equals(respBytes.length));

      stream1.finish();
      expect(phone.has(1), isTrue);
      expect(computer.has(1), isTrue);

      computer.finish(1);

      expect(phone.has(1), isFalse);
      expect(computer.has(1), isFalse);
      expect(log, equals([
        'computer opened 1',
        'phone accepted 1',
        'computer ended 1',
        'phone ended 1',
      ]));

      final compGot = computerReceived[1]!.expand((b) => b).toList();
      expect(utf8.decode(compGot), equals('GET /api/health HTTP/1.1\r\n\r\n'));

      final phoneGot = phoneReceived[1]!.expand((b) => b).toList();
      expect(utf8.decode(phoneGot), equals('HTTP/1.1 200 OK\r\n\r\n{"ok":true}'));
    });

    test('Initial window limit: phone can send 256 KiB before accept, then 2 MiB', () {
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
      );

      final id = phone.open();
      expect(id, equals(1));

      var sent = 0;
      final chunk = Uint8List(yamuxMaxDataPayload);
      while (true) {
        final taken = phone.write(id, chunk);
        if (taken == 0) break;
        sent += taken;
      }
      expect(sent, equals(yamuxInitialWindow));

      computer.accept(id);
      expect(phone.sendWindow(id), equals(yamuxStreamWindow - yamuxInitialWindow));
    });

    test('Window replenish: sends WindowUpdate only after 1 MiB consumed', () {
      final computerSent = <YamuxFrame>[];
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) {
          computerSent.add(frame);
          phone.receive(YamuxFrame.decode(frame.encode()));
        },
        onOpened: (id) => computer.accept(id),
      );

      final id = phone.open();
      final chunk = Uint8List(yamuxMaxDataPayload);
      while (phone.write(id, chunk) > 0) {}
      expect(phone.sendWindow(id), equals(0));

      final countBefore = computerSent.length;
      computer.consumed(id, yamuxWindowUpdateAfter - 1);
      expect(computerSent.length, equals(countBefore));
      expect(phone.sendWindow(id), equals(0));

      computer.consumed(id, 1);
      expect(computerSent.length, equals(countBefore + 1));
      expect(phone.sendWindow(id), equals(yamuxWindowUpdateAfter));
    });

    test('Computer cannot write before accept', () {
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
      );

      final id = phone.open();
      expect(computer.write(id, Uint8List.fromList([1, 2, 3])), equals(0));
    });

    test('Reset: closes stream on both sides and drops subsequent frames', () {
      final log = <String>[];
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
        onReset: (id) => log.add('phone reset $id'),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
        onOpened: (id) => computer.accept(id),
        onReset: (id) => log.add('computer reset $id'),
      );

      final id = phone.open();
      computer.reset(id);
      expect(log, contains('phone reset 1'));
      expect(phone.write(id, Uint8List.fromList([1, 2, 3])), equals(0));

      expect(
        () => computer.receive(YamuxFrame.data(1, Uint8List.fromList([4, 5, 6]))),
        returnsNormally,
      );
    });

    test('Ping / pong exchange with opaque uint32', () {
      final pongs = <int>[];
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
        onPong: (val) => pongs.add(val),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
      );

      phone.ping(0x12345678);
      expect(pongs, equals([0x12345678]));
    });

    test('GoAway prevents further open calls', () {
      final goAways = <int>[];
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
        onGoAway: (code) => goAways.add(code),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
      );

      computer.goAway(YamuxGoAway.normal);
      expect(goAways, equals([YamuxGoAway.normal]));
      expect(phone.peerGoneAway, isTrue);
      expect(() => phone.open(), throwsA(isA<YamuxError>()));
    });

    test('Refuses 65th open stream on phone', () {
      final phone = YamuxSession(role: YamuxRole.phone);
      for (var i = 0; i < yamuxMaxStreams; i++) {
        phone.open();
      }
      expect(phone.activeStreams, equals(yamuxMaxStreams));
      expect(() => phone.open(), throwsA(isA<YamuxError>()));
    });

    test('Computer cannot open streams', () {
      final computer = YamuxSession(role: YamuxRole.computer);
      expect(() => computer.open(), throwsA(isA<YamuxError>()));
    });

    test('YamuxStream listen and sink interface', () async {
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
        onOpened: (id) => computer.accept(id),
      );

      final phoneStream = phone.openStream();
      final computerStream = computer.getStream(phoneStream.id)!;

      final chunks = <Uint8List>[];
      phoneStream.listen(chunks.add);

      computerStream.write(Uint8List.fromList([10, 20, 30]));
      await Future<void>.delayed(Duration.zero);

      expect(chunks.length, equals(1));
      expect(chunks[0], equals(Uint8List.fromList([10, 20, 30])));
    });

    test('YamuxStream.add slices payloads larger than 65507 bytes without truncation', () async {
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
        onOpened: (id) => computer.accept(id),
      );

      final phoneStream = phone.openStream();
      final computerStream = computer.getStream(phoneStream.id)!;

      final receivedChunks = <Uint8List>[];
      computerStream.listen(receivedChunks.add);

      const largeSize = 100000;
      final largeData = Uint8List(largeSize);
      for (var i = 0; i < largeSize; i++) {
        largeData[i] = i % 251;
      }

      phoneStream.add(largeData);
      await Future<void>.delayed(Duration.zero);

      final totalReceived = receivedChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      expect(totalReceived, equals(largeSize));
      expect(receivedChunks.length, equals(2));
      expect(receivedChunks[0].length, equals(yamuxMaxDataPayload));
      expect(receivedChunks[1].length, equals(largeSize - yamuxMaxDataPayload));

      final assembled = Uint8List(largeSize);
      var offset = 0;
      for (final chunk in receivedChunks) {
        assembled.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      expect(assembled, equals(largeData));
    });

    test('YamuxStream.writable and onWritable notify when send window replenishes', () async {
      late final YamuxSession phone;
      late final YamuxSession computer;

      phone = YamuxSession(
        role: YamuxRole.phone,
        onSend: (frame) => computer.receive(YamuxFrame.decode(frame.encode())),
      );

      computer = YamuxSession(
        role: YamuxRole.computer,
        onSend: (frame) => phone.receive(YamuxFrame.decode(frame.encode())),
      );

      final phoneStream = phone.openStream();
      final id = phoneStream.id;

      final chunk = Uint8List(yamuxMaxDataPayload);
      while (phoneStream.write(chunk) > 0) {}
      expect(phoneStream.sendWindow, equals(0));

      var callbackFired = false;
      phoneStream.onWritable(() {
        callbackFired = true;
      });

      var futureCompleted = false;
      final future = phoneStream.writable.then((_) {
        futureCompleted = true;
      });

      expect(callbackFired, isFalse);
      expect(futureCompleted, isFalse);

      computer.accept(id);
      await future;

      expect(callbackFired, isTrue);
      expect(futureCompleted, isTrue);
      expect(phoneStream.sendWindow, greaterThan(0));
    });

    test('YamuxFrame.ping masks values to 32-bit unsigned integers', () {
      final ping = YamuxFrame.ping(0x100000001);
      expect(ping.length, equals(1));

      final ping2 = YamuxFrame.ping(-1);
      expect(ping2.length, equals(0xFFFFFFFF));
    });
  });
}
