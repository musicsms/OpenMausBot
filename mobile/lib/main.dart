import 'package:flutter/material.dart';
import 'core/network/sse_client.dart';
import 'core/storage/pairing_storage.dart';
import 'core/theme/grok_theme.dart';
import 'features/chat/chat_message.dart';
import 'features/chat/chat_view.dart';
import 'features/pairing/pairing_model.dart';
import 'features/pairing/pairing_view.dart';

void main() {
  runApp(const MausBotApp());
}

class MausBotApp extends StatefulWidget {
  final PairingStorage? storage;
  final SseNetworkClient? sseClient;
  final Widget? scannerWidget;

  const MausBotApp({
    super.key,
    this.storage,
    this.sseClient,
    this.scannerWidget,
  });

  @override
  State<MausBotApp> createState() => _MausBotAppState();
}

class _MausBotAppState extends State<MausBotApp> {
  late final PairingStorage _storage;
  SseNetworkClient? _sseClient;
  String? _deviceToken;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? PairingStorage();
    _sseClient = widget.sseClient;
    _checkDeviceToken();
  }

  Future<void> _checkDeviceToken() async {
    final token = await _storage.getDeviceToken();
    if (token != null && _sseClient == null) {
      final lanUrl = await _storage.getLanUrl() ?? 'http://127.0.0.1:8810';
      final remoteUrl = await _storage.getRemoteUrl();
      _sseClient = SseNetworkClient(
        lanUrl: lanUrl,
        remoteUrl: remoteUrl,
        deviceToken: token,
      );
    }
    if (mounted) {
      setState(() {
        _deviceToken = token;
        _isLoading = false;
      });
    }
  }

  void _onPairSuccess(PairingPayload payload) async {
    await _storage.saveDeviceToken(payload.pairingSecret);
    await _storage.saveEndpoints(
      lanUrl: payload.lanUrl,
      remoteUrl: payload.remoteUrl,
    );
    if (!mounted) return;
    setState(() {
      _deviceToken = payload.pairingSecret;
      _sseClient = widget.sseClient ??
          SseNetworkClient(
            lanUrl: payload.lanUrl,
            remoteUrl: payload.remoteUrl,
            deviceToken: payload.pairingSecret,
          );
    });
  }

  void _onManualCodeSubmit(String code) async {
    const defaultLan = 'http://127.0.0.1:8810';
    await _storage.saveDeviceToken(code);
    await _storage.saveEndpoints(lanUrl: defaultLan);
    if (!mounted) return;
    setState(() {
      _deviceToken = code;
      _sseClient = widget.sseClient ??
          SseNetworkClient(
            lanUrl: defaultLan,
            deviceToken: code,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMausBot',
      theme: GrokTheme.themeData,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: GrokTheme.oledBlack,
        body: Center(
          child: CircularProgressIndicator(color: GrokTheme.glowCyan),
        ),
      );
    }

    if (_deviceToken == null || _sseClient == null) {
      return PairingView(
        scannerWidget: widget.scannerWidget,
        onPairSuccess: _onPairSuccess,
        onManualCodeSubmit: _onManualCodeSubmit,
      );
    }

    return ChatConnectedView(sseClient: _sseClient!);
  }
}

class ChatConnectedView extends StatefulWidget {
  final SseNetworkClient sseClient;

  const ChatConnectedView({
    super.key,
    required this.sseClient,
  });

  @override
  State<ChatConnectedView> createState() => _ChatConnectedViewState();
}

class _ChatConnectedViewState extends State<ChatConnectedView> {
  final List<ChatMessage> _messages = [];
  bool _isStreaming = false;

  void _handleSendMessage(String text) async {
    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );
    setState(() {
      _messages.add(userMessage);
      _isStreaming = true;
    });

    try {
      await widget.sseClient.postJson('/api/threads/default/messages', {
        'content': text,
      });
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isStreaming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChatView(
      messages: _messages,
      isStreaming: _isStreaming,
      onSendMessage: _handleSendMessage,
    );
  }
}
