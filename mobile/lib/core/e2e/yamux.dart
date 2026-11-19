import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

const int yamuxVersion = 0;
const int yamuxHeaderBytes = 12;
const int yamuxMaxDataPayload = 65507;
const int yamuxInitialWindow = 256 * 1024;
const int yamuxStreamWindow = 2 * 1024 * 1024;
const int yamuxOpenWindowDelta = yamuxStreamWindow - yamuxInitialWindow;
const int yamuxWindowUpdateAfter = 1024 * 1024;
const int yamuxMaxStreams = 64;
const int yamuxMaxStreamId = 2147483647;
const int yamuxPingIntervalMs = 20000;
const int yamuxPingTimeoutMs = 10000;

abstract class YamuxType {
  static const int data = 0;
  static const int windowUpdate = 1;
  static const int ping = 2;
  static const int goAway = 3;
}

abstract class YamuxFlag {
  static const int syn = 0x1;
  static const int ack = 0x2;
  static const int fin = 0x4;
  static const int rst = 0x8;
}

abstract class YamuxGoAway {
  static const int normal = 0;
  static const int protocol = 1;
  static const int internal = 2;
  static const int removed = 3;
}

enum YamuxRole {
  phone,
  computer,
}

class YamuxError implements Exception {
  final String reason;

  YamuxError(this.reason);

  @override
  String toString() => 'YamuxError: $reason';
}

class YamuxFrame {
  final int type;
  final int flags;
  final int streamId;
  final int length;
  final Uint8List data;

  YamuxFrame({
    required this.type,
    required this.flags,
    required this.streamId,
    required this.length,
    Uint8List? data,
  }) : data = data ?? Uint8List(0);

  factory YamuxFrame.open(int streamId) => YamuxFrame(
        type: YamuxType.windowUpdate,
        flags: YamuxFlag.syn,
        streamId: streamId,
        length: yamuxOpenWindowDelta,
      );

  factory YamuxFrame.accept(int streamId) => YamuxFrame(
        type: YamuxType.windowUpdate,
        flags: YamuxFlag.ack,
        streamId: streamId,
        length: yamuxOpenWindowDelta,
      );

  factory YamuxFrame.reset(int streamId) => YamuxFrame(
        type: YamuxType.windowUpdate,
        flags: YamuxFlag.rst,
        streamId: streamId,
        length: 0,
      );

  factory YamuxFrame.fin(int streamId) => YamuxFrame(
        type: YamuxType.windowUpdate,
        flags: YamuxFlag.fin,
        streamId: streamId,
        length: 0,
      );

  factory YamuxFrame.windowUpdate(int streamId, int delta) => YamuxFrame(
        type: YamuxType.windowUpdate,
        flags: 0,
        streamId: streamId,
        length: delta,
      );

  factory YamuxFrame.data(int streamId, Uint8List data, {int flags = 0}) => YamuxFrame(
        type: YamuxType.data,
        flags: flags,
        streamId: streamId,
        length: data.length,
        data: data,
      );

  factory YamuxFrame.ping(int value, {int flags = YamuxFlag.syn}) => YamuxFrame(
        type: YamuxType.ping,
        flags: flags,
        streamId: 0,
        length: value & 0xFFFFFFFF,
      );

  factory YamuxFrame.goAway([int code = YamuxGoAway.normal]) => YamuxFrame(
        type: YamuxType.goAway,
        flags: 0,
        streamId: 0,
        length: code,
      );

  Uint8List encode() {
    final payload = type == YamuxType.data ? data : Uint8List(0);
    if (type == YamuxType.data && payload.length != length) {
      throw YamuxError('data_length');
    }
    if (payload.length > yamuxMaxDataPayload) {
      throw YamuxError('data_too_large');
    }

    final out = Uint8List(yamuxHeaderBytes + payload.length);
    final byteData = ByteData.sublistView(out);
    byteData.setUint8(0, yamuxVersion);
    byteData.setUint8(1, type);
    byteData.setUint16(2, flags, Endian.big);
    byteData.setUint32(4, streamId, Endian.big);
    byteData.setUint32(8, length, Endian.big);
    if (payload.isNotEmpty) {
      out.setRange(yamuxHeaderBytes, out.length, payload);
    }
    return out;
  }

  static YamuxFrame decode(Uint8List bytes) {
    if (bytes.length < yamuxHeaderBytes) {
      throw YamuxError('short_frame');
    }

    final byteData = ByteData.sublistView(bytes);
    final version = byteData.getUint8(0);
    if (version != yamuxVersion) {
      throw YamuxError('version');
    }
    final type = byteData.getUint8(1);
    if (type > YamuxType.goAway) {
      throw YamuxError('type');
    }
    final flags = byteData.getUint16(2, Endian.big);
    if ((flags & ~0x0f) != 0) {
      throw YamuxError('flags');
    }
    final streamId = byteData.getUint32(4, Endian.big);
    final length = byteData.getUint32(8, Endian.big);

    if (type == YamuxType.data) {
      if (length > yamuxMaxDataPayload) {
        throw YamuxError('data_too_large');
      }
      if (bytes.length != yamuxHeaderBytes + length) {
        throw YamuxError('data_length');
      }
      if (streamId == 0) {
        throw YamuxError('stream_zero');
      }
      final data = Uint8List.sublistView(bytes, yamuxHeaderBytes);
      return YamuxFrame(
        type: type,
        flags: flags,
        streamId: streamId,
        length: length,
        data: data,
      );
    }

    if (bytes.length != yamuxHeaderBytes) {
      throw YamuxError('trailing_bytes');
    }
    if (type == YamuxType.windowUpdate) {
      if (streamId == 0) {
        throw YamuxError('stream_zero');
      }
    } else {
      if (streamId != 0) {
        throw YamuxError('session_frame_stream');
      }
      if (type == YamuxType.ping && flags != YamuxFlag.syn && flags != YamuxFlag.ack) {
        throw YamuxError('ping_flags');
      }
      if (type == YamuxType.goAway && flags != 0) {
        throw YamuxError('goaway_flags');
      }
    }

    return YamuxFrame(
      type: type,
      flags: flags,
      streamId: streamId,
      length: length,
    );
  }
}

class YamuxEvents {
  final void Function(YamuxFrame frame)? send;
  final void Function(int streamId)? opened;
  final void Function(int streamId)? accepted;
  final void Function(int streamId, Uint8List data)? data;
  final void Function(int streamId)? ended;
  final void Function(int streamId)? reset;
  final void Function(int streamId)? writable;
  final void Function(int code)? goAway;
  final void Function(int value)? pong;

  const YamuxEvents({
    this.send,
    this.opened,
    this.accepted,
    this.data,
    this.ended,
    this.reset,
    this.writable,
    this.goAway,
    this.pong,
  });
}

class YamuxStream extends Stream<Uint8List> implements Sink<List<int>> {
  final YamuxSession session;
  final int streamId;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  final List<void Function()> _writableWaiters = [];
  Uint8List? _pendingWrite;

  bool _established;
  int _receiveWindow;
  int _sendWindow;
  int _uncredited = 0;
  bool _localFin = false;
  bool _remoteFin = false;
  bool _isReset = false;

  YamuxStream._({
    required this.session,
    required this.streamId,
    required bool established,
    required int receiveWindow,
    required int sendWindow,
  })  : _established = established,
        _receiveWindow = receiveWindow,
        _sendWindow = sendWindow;

  int get id => streamId;
  int get sendWindow => _sendWindow;
  int get receiveWindow => _receiveWindow;
  bool get isEstablished => _established;
  bool get isLocalFin => _localFin;
  bool get isRemoteFin => _remoteFin;
  bool get isClosed => (_localFin && _remoteFin) || _isReset;

  Stream<Uint8List> get stream => _controller.stream;
  Sink<List<int>> get sink => this;

  Future<void> get writable {
    if (isClosed || (sendWindow > 0 && (_pendingWrite == null || _pendingWrite!.isEmpty))) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _writableWaiters.add(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  void onWritable(void Function() callback) {
    _writableWaiters.add(callback);
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  int write(Uint8List data) => session.write(streamId, data);

  @override
  void add(List<int> data) {
    if (isClosed) return;
    _flushPending();
    var bytes = data is Uint8List ? data : Uint8List.fromList(data);
    while (bytes.isNotEmpty) {
      if (_pendingWrite != null && _pendingWrite!.isNotEmpty) {
        final merged = Uint8List(_pendingWrite!.length + bytes.length)
          ..setRange(0, _pendingWrite!.length, _pendingWrite!)
          ..setRange(_pendingWrite!.length, _pendingWrite!.length + bytes.length, bytes);
        _pendingWrite = merged;
        return;
      }
      final taken = write(bytes);
      if (taken == 0) {
        _pendingWrite = bytes;
        return;
      }
      bytes = Uint8List.sublistView(bytes, taken);
    }
  }

  void finish() {
    _flushPending();
    session.finish(streamId);
  }

  @override
  void close() => finish();

  void reset() => session.reset(streamId);

  void consumed(int bytes) => session.consumed(streamId, bytes);

  void _deliver(Uint8List data) {
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  void _remoteEnded() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  void _markReset() {
    _isReset = true;
    _pendingWrite = null;
    if (!_controller.isClosed) {
      _controller.addError(YamuxError('stream_reset'));
      _controller.close();
    }
    _notifyWritable();
  }

  void _onWritable() {
    _flushPending();
    _notifyWritable();
  }

  void _flushPending() {
    while (_pendingWrite != null && _pendingWrite!.isNotEmpty) {
      final taken = session.write(streamId, _pendingWrite!);
      if (taken == 0) return;
      if (taken == _pendingWrite!.length) {
        _pendingWrite = null;
      } else {
        _pendingWrite = Uint8List.sublistView(_pendingWrite!, taken);
      }
    }
  }

  void _notifyWritable() {
    final waiters = List<void Function()>.from(_writableWaiters);
    _writableWaiters.clear();
    for (final waiter in waiters) {
      waiter();
    }
  }
}

class YamuxSession {
  final YamuxRole role;
  final void Function(YamuxFrame frame)? _onSend;
  final void Function(int streamId)? _onOpened;
  final void Function(int streamId)? _onAccepted;
  final void Function(int streamId, Uint8List data)? _onData;
  final void Function(int streamId)? _onEnded;
  final void Function(int streamId)? _onReset;
  final void Function(int streamId)? _onWritable;
  final void Function(int code)? _onGoAway;
  final void Function(int value)? _onPong;

  final Map<int, YamuxStream> _streams = {};
  int _highestId = 0;
  bool _peerGoneAway = false;
  bool _localGoneAway = false;

  YamuxSession({
    this.role = YamuxRole.phone,
    void Function(YamuxFrame frame)? onSend,
    void Function(int streamId)? onOpened,
    void Function(int streamId)? onAccepted,
    void Function(int streamId, Uint8List data)? onData,
    void Function(int streamId)? onEnded,
    void Function(int streamId)? onReset,
    void Function(int streamId)? onWritable,
    void Function(int code)? onGoAway,
    void Function(int value)? onPong,
    YamuxEvents? events,
  })  : _onSend = onSend ?? events?.send,
        _onOpened = onOpened ?? events?.opened,
        _onAccepted = onAccepted ?? events?.accepted,
        _onData = onData ?? events?.data,
        _onEnded = onEnded ?? events?.ended,
        _onReset = onReset ?? events?.reset,
        _onWritable = onWritable ?? events?.writable,
        _onGoAway = onGoAway ?? events?.goAway,
        _onPong = onPong ?? events?.pong;

  int get activeStreams => _streams.length;
  bool get peerGoneAway => _peerGoneAway;
  bool get localGoneAway => _localGoneAway;

  bool has(int streamId) => _streams.containsKey(streamId);

  YamuxStream? getStream(int streamId) => _streams[streamId];

  int sendWindow(int streamId) => _streams[streamId]?._sendWindow ?? 0;

  YamuxStream openStream() {
    if (role != YamuxRole.phone) {
      throw YamuxError('computer_open');
    }
    if (_localGoneAway || _peerGoneAway) {
      throw YamuxError('gone_away');
    }
    if (_streams.length >= yamuxMaxStreams) {
      throw YamuxError('too_many_streams');
    }

    final streamId = _highestId == 0 ? 1 : _highestId + 2;
    if (streamId > yamuxMaxStreamId) {
      throw YamuxError('ids_exhausted');
    }

    _highestId = streamId;
    final stream = YamuxStream._(
      session: this,
      streamId: streamId,
      established: false,
      receiveWindow: yamuxInitialWindow + yamuxOpenWindowDelta,
      sendWindow: yamuxInitialWindow,
    );
    _streams[streamId] = stream;
    _send(YamuxFrame.open(streamId));
    return stream;
  }

  int open() => openStream().streamId;

  void accept(int streamId) {
    final stream = _streams[streamId];
    if (stream == null || stream._established || role != YamuxRole.computer) {
      return;
    }
    stream._established = true;
    stream._receiveWindow += yamuxOpenWindowDelta;
    _send(YamuxFrame.accept(streamId));
  }

  int write(int streamId, Uint8List data) {
    final stream = _streams[streamId];
    if (stream == null || stream._localFin || (role == YamuxRole.computer && !stream._established)) {
      return 0;
    }

    final size = min(data.length, min(stream._sendWindow, yamuxMaxDataPayload));
    if (size == 0) {
      return 0;
    }

    stream._sendWindow -= size;
    _send(YamuxFrame.data(streamId, Uint8List.sublistView(data, 0, size)));
    return size;
  }

  void finish(int streamId) {
    final stream = _streams[streamId];
    if (stream == null || stream._localFin) {
      return;
    }
    stream._localFin = true;
    _send(YamuxFrame.fin(streamId));
    _closeIfDone(streamId, stream);
  }

  void reset(int streamId) {
    final stream = _streams.remove(streamId);
    if (stream == null) {
      return;
    }
    stream._markReset();
    _send(YamuxFrame.reset(streamId));
    _onReset?.call(streamId);
  }

  void consumed(int streamId, int bytes) {
    final stream = _streams[streamId];
    if (stream == null || stream._remoteFin) {
      return;
    }

    stream._uncredited += bytes;
    if (stream._uncredited < yamuxWindowUpdateAfter) {
      return;
    }

    final delta = stream._uncredited;
    stream._uncredited = 0;
    stream._receiveWindow += delta;
    _send(YamuxFrame.windowUpdate(streamId, delta));
  }

  void ping(int value) {
    _send(YamuxFrame.ping(value));
  }

  void goAway([int code = YamuxGoAway.normal]) {
    _localGoneAway = true;
    _send(YamuxFrame.goAway(code));
  }

  void protocolError() {
    goAway(YamuxGoAway.protocol);
    closeAll();
  }

  void closeAll() {
    final ids = _streams.keys.toList();
    final streams = _streams.values.toList();
    _streams.clear();
    for (var i = 0; i < ids.length; i++) {
      streams[i]._markReset();
      _onReset?.call(ids[i]);
    }
  }

  void receiveBytes(Uint8List bytes) {
    receive(YamuxFrame.decode(bytes));
  }

  void receive(YamuxFrame frame) {
    if (frame.type == YamuxType.ping) {
      if (frame.flags == YamuxFlag.syn) {
        _send(YamuxFrame.ping(frame.length, flags: YamuxFlag.ack));
      } else {
        _onPong?.call(frame.length);
      }
      return;
    }

    if (frame.type == YamuxType.goAway) {
      _peerGoneAway = true;
      _onGoAway?.call(frame.length);
      return;
    }

    if ((frame.flags & YamuxFlag.syn) != 0) {
      _receiveOpen(frame);
      return;
    }

    if ((frame.flags & YamuxFlag.ack) != 0) {
      _receiveAck(frame);
      return;
    }

    final stream = _known(frame.streamId);
    if (stream == null) {
      return;
    }
    _receiveOnStream(frame.streamId, stream, frame);
  }

  YamuxStream? _known(int streamId) {
    if (streamId % 2 == 0 || streamId > _highestId) {
      throw YamuxError('unknown_stream');
    }
    return _streams[streamId];
  }

  void _receiveOpen(YamuxFrame frame) {
    if (role == YamuxRole.phone) {
      throw YamuxError('computer_opened_stream');
    }
    if (frame.type != YamuxType.windowUpdate || frame.flags != YamuxFlag.syn) {
      throw YamuxError('open_flags');
    }
    if (frame.streamId % 2 == 0) {
      throw YamuxError('even_stream');
    }
    if (frame.streamId <= _highestId) {
      throw YamuxError('stream_reused');
    }

    _highestId = frame.streamId;
    if (_localGoneAway || _streams.length >= yamuxMaxStreams) {
      _send(YamuxFrame.reset(frame.streamId));
      return;
    }

    final stream = YamuxStream._(
      session: this,
      streamId: frame.streamId,
      established: false,
      receiveWindow: yamuxInitialWindow,
      sendWindow: yamuxInitialWindow + frame.length,
    );
    _streams[frame.streamId] = stream;
    _onOpened?.call(frame.streamId);
  }

  void _receiveAck(YamuxFrame frame) {
    if (role == YamuxRole.computer) {
      throw YamuxError('phone_ack');
    }
    if (frame.type != YamuxType.windowUpdate ||
        (frame.flags & ~(YamuxFlag.ack | YamuxFlag.fin | YamuxFlag.rst)) != 0) {
      throw YamuxError('ack_flags');
    }

    final stream = _known(frame.streamId);
    if (stream == null) {
      return;
    }
    if (stream._established) {
      throw YamuxError('duplicate_ack');
    }

    stream._established = true;
    _onAccepted?.call(frame.streamId);
    _receiveOnStream(
      frame.streamId,
      stream,
      YamuxFrame(
        type: frame.type,
        flags: frame.flags & ~YamuxFlag.ack,
        streamId: frame.streamId,
        length: frame.length,
        data: frame.data,
      ),
    );
  }

  void _receiveOnStream(int streamId, YamuxStream stream, YamuxFrame frame) {
    if ((frame.flags & YamuxFlag.rst) != 0) {
      _streams.remove(streamId);
      stream._markReset();
      _onReset?.call(streamId);
      return;
    }

    if (frame.type == YamuxType.data) {
      if (stream._remoteFin && (frame.length > 0 || (frame.flags & YamuxFlag.fin) != 0)) {
        throw YamuxError('data_after_fin');
      }
      if (frame.length > stream._receiveWindow) {
        throw YamuxError('window_exceeded');
      }

      stream._receiveWindow -= frame.length;
      if (frame.length > 0) {
        stream._deliver(frame.data);
        _onData?.call(streamId, frame.data);
      }
    } else if (frame.length > 0) {
      stream._sendWindow += frame.length;
      stream._onWritable();
      _onWritable?.call(streamId);
    }

    if ((frame.flags & YamuxFlag.fin) != 0) {
      if (stream._remoteFin) {
        throw YamuxError('data_after_fin');
      }
      stream._remoteFin = true;
      stream._remoteEnded();
      _onEnded?.call(streamId);
      _closeIfDone(streamId, stream);
    }
  }

  void _closeIfDone(int streamId, YamuxStream stream) {
    if (stream._localFin && stream._remoteFin) {
      _streams.remove(streamId);
    }
  }

  void _send(YamuxFrame frame) {
    _onSend?.call(frame);
  }
}

typedef Mux = YamuxSession;
typedef Frame = YamuxFrame;
