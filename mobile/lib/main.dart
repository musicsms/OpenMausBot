import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/network/sse_client.dart';
import 'core/storage/pairing_storage.dart';
import 'core/theme/grok_theme.dart';
import 'features/approvals/approval_model.dart';
import 'features/chat/chat_message.dart';
import 'features/chat/chat_view.dart';
import 'features/pairing/pairing_model.dart';
import 'features/pairing/pairing_view.dart';

void main() {
  runApp(const NibbleApp());
}

class NibbleApp extends StatefulWidget {
  final PairingStorage? storage;
  final SseNetworkClient? sseClient;
  final Widget? scannerWidget;
  final String deviceName;
  final http.Client? httpClient;

  const NibbleApp({
    super.key,
    this.storage,
    this.sseClient,
    this.scannerWidget,
    this.deviceName = 'Flutter Companion',
    this.httpClient,
  });

  @override
  State<NibbleApp> createState() => _NibbleAppState();
}

class _NibbleAppState extends State<NibbleApp> {
  late final PairingStorage _storage;
  SseNetworkClient? _sseClient;
  String? _deviceToken;
  String? _botId;
  String _connectionLabel = 'Online';
  String? _pairError;
  bool _isLoading = true;
  bool _isPairing = false;
  bool _showPairAgainBanner = false;
  bool _isRePairing = false;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? PairingStorage();
    _sseClient = widget.sseClient;
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final token = await _storage.getDeviceToken();
    final botId = await _storage.getBotId();
    final e2eDescriptor = await _storage.getE2EDescriptor();
    if (token != null && _sseClient == null) {
      final endpoints = await _storage.getEndpoints();
      _sseClient = SseNetworkClient(
        endpoints: endpoints,
        deviceToken: token,
        httpClient: widget.httpClient,
        e2e: e2eDescriptor,
      );
      final active = await _safeActiveLabel(_sseClient!);
      if (mounted) {
        setState(() {
          _deviceToken = token;
          _botId = botId;
          _connectionLabel = active;
          _isLoading = false;
        });
      }
      _checkE2EMigration();
      return;
    }

    if (mounted) {
      setState(() {
        _deviceToken = token;
        _botId = botId;
        _isLoading = false;
      });
    }
    _checkE2EMigration();
  }

  Future<void> _checkE2EMigration() async {
    final e2e = await _storage.getE2EIdentity();
    if (e2e != null && e2e.k.isNotEmpty) return;
    if (_sseClient == null) return;
    try {
      final endpointsInfo = await _sseClient!.getEndpointsInfo();
      if (endpointsInfo != null && endpointsInfo['e2e'] != null) {
        if (mounted) {
          setState(() {
            _showPairAgainBanner = true;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _onServerE2EDetected(dynamic e2e) async {
    final stored = await _storage.getE2EIdentity();
    if (stored == null || stored.k.isEmpty) {
      if (mounted) {
        setState(() {
          _showPairAgainBanner = true;
        });
      }
    }
  }

  Future<String> _safeActiveLabel(SseNetworkClient client) async {
    try {
      final url = await client.resolveActiveBaseUrl();
      CompanionEndpoint? match;
      for (final endpoint in client.endpoints) {
        if (endpoint.url == url) {
          match = endpoint;
          break;
        }
      }
      final kind = match?.kind ?? 'lan';
      return 'Online • ${kind.toUpperCase()}';
    } catch (_) {
      return 'Online';
    }
  }

  Future<void> _persistPairResult({
    required PairResult result,
    required List<CompanionEndpoint> fallbackEndpoints,
    required SseNetworkClient client,
  }) async {
    final endpoints = result.endpoints.isNotEmpty ? result.endpoints : fallbackEndpoints;
    await _storage.saveDeviceToken(result.token);
    await _storage.saveEndpoints(endpoints: endpoints);
    await _storage.saveServerName(result.serverName);

    String? botId;
    try {
      final bots = await client.listBots();
      if (bots.isNotEmpty) {
        botId = bots.first['id'] as String?;
        if (botId != null) await _storage.saveBotId(botId);
      }
    } catch (_) {}

    final label = await _safeActiveLabel(client);
    if (!mounted) return;
    setState(() {
      _deviceToken = result.token;
      _sseClient = client;
      _botId = botId;
      _connectionLabel = label;
      _pairError = null;
      _isPairing = false;
    });
  }

  Future<void> _onPairSuccess(PairingPayload payload) async {
    if (_isPairing) return;
    setState(() {
      _isPairing = true;
      _pairError = null;
    });

    try {
      final dialUrl = payload.dialUrl;
      if (payload.e2e == null && (dialUrl == null || dialUrl.isEmpty)) {
        throw Exception('pairing invite has no reachable host');
      }

      final result = await SseNetworkClient.redeemPair(
        baseUrl: dialUrl,
        deviceName: widget.deviceName,
        credential: payload.credential.isNotEmpty ? payload.credential : null,
        code: payload.code,
        httpClient: widget.httpClient,
        e2e: payload.e2e,
      );

      _sseClient?.close();
      _sseClient = null;

      await _storage.clear();

      final endpoints = result.endpoints.isNotEmpty ? result.endpoints : payload.endpoints;
      final e2eDesc = payload.e2e;

      final client = widget.sseClient ??
          SseNetworkClient(
            endpoints: endpoints,
            deviceToken: result.token,
            httpClient: widget.httpClient,
            e2e: e2eDesc,
          );

      if (e2eDesc != null) {
        await _storage.saveE2EIdentity(
          transportPublicKey: e2eDesc.k,
          hostId: e2eDesc.h,
          relayNodes: e2eDesc.relayNodes,
        );
      }

      await _persistPairResult(
        result: result,
        fallbackEndpoints: payload.endpoints,
        client: client,
      );

      if (mounted) {
        setState(() {
          _isRePairing = false;
          _showPairAgainBanner = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isPairing = false;
        _pairError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _onManualCodeSubmit(ManualPairRequest request) async {
    if (_isPairing) return;
    setState(() {
      _isPairing = true;
      _pairError = null;
    });

    try {
      final result = await SseNetworkClient.redeemPair(
        baseUrl: request.baseUrl,
        deviceName: widget.deviceName,
        code: request.code,
        httpClient: widget.httpClient,
      );

      _sseClient?.close();
      _sseClient = null;

      await _storage.clear();

      final endpoints = result.endpoints.isNotEmpty
          ? result.endpoints
          : [
              CompanionEndpoint(
                url: request.baseUrl,
                kind: request.baseUrl.startsWith('https://') ? 'hosted' : 'lan',
                priority: request.baseUrl.startsWith('https://') ? 0 : 200,
              ),
            ];

      final client = widget.sseClient ??
          SseNetworkClient(
            endpoints: endpoints,
            deviceToken: result.token,
            httpClient: widget.httpClient,
          );

      await _persistPairResult(
        result: result,
        fallbackEndpoints: endpoints,
        client: client,
      );

      if (mounted) {
        setState(() {
          _isRePairing = false;
          _showPairAgainBanner = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isPairing = false;
        _pairError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nibble',
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

    if (_deviceToken == null || _sseClient == null || _isRePairing) {
      return PairingView(
        scannerWidget: widget.scannerWidget,
        onPairSuccess: _onPairSuccess,
        onManualCodeSubmit: _onManualCodeSubmit,
        errorMessage: _pairError,
        isBusy: _isPairing,
        bannerMessage: _showPairAgainBanner ? 'Pair again to connect from anywhere' : null,
        onCancel: _isRePairing ? () => setState(() => _isRePairing = false) : null,
      );
    }

    return ChatConnectedView(
      sseClient: _sseClient!,
      botId: _botId,
      connectionLabel: _connectionLabel,
      showPairAgainBanner: _showPairAgainBanner,
      onPairAgain: () => setState(() => _isRePairing = true),
      onServerE2EDetected: _onServerE2EDetected,
      onBotIdResolved: (botId) async {
        await _storage.saveBotId(botId);
        if (mounted) setState(() => _botId = botId);
      },
    );
  }
}

class ChatConnectedView extends StatefulWidget {
  final SseNetworkClient sseClient;
  final String? botId;
  final String connectionLabel;
  final bool showPairAgainBanner;
  final VoidCallback? onPairAgain;
  final ValueChanged<dynamic>? onServerE2EDetected;
  final ValueChanged<String>? onBotIdResolved;

  const ChatConnectedView({
    super.key,
    required this.sseClient,
    this.botId,
    this.connectionLabel = 'Online',
    this.showPairAgainBanner = false,
    this.onPairAgain,
    this.onServerE2EDetected,
    this.onBotIdResolved,
  });

  @override
  State<ChatConnectedView> createState() => _ChatConnectedViewState();
}

class _ChatConnectedViewState extends State<ChatConnectedView> {
  final List<ChatMessage> _messages = [];
  StreamSubscription<CompanionEvent>? _subscription;
  String? _botId;
  String? _lastEventId;
  ApprovalRequest? _pendingApproval;
  bool _isStreaming = false;
  String _connectionLabel = 'Connecting…';

  @override
  void initState() {
    super.initState();
    _botId = widget.botId;
    _connectionLabel = widget.connectionLabel;
    _bootstrap();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      if (_botId == null) {
        final bots = await widget.sseClient.listBots();
        if (bots.isNotEmpty) {
          _botId = bots.first['id'] as String?;
          if (_botId != null) widget.onBotIdResolved?.call(_botId!);
        }
      }
      final info = await widget.sseClient.getEndpointsInfo();
      if (info != null && info['e2e'] != null) {
        widget.onServerE2EDetected?.call(info['e2e']);
      }
      final label = await _labelForActive();
      if (mounted) setState(() => _connectionLabel = label);
    } catch (_) {}
    _listenToEvents();
  }

  Future<String> _labelForActive() async {
    try {
      final url = await widget.sseClient.resolveActiveBaseUrl();
      CompanionEndpoint? match;
      for (final endpoint in widget.sseClient.endpoints) {
        if (endpoint.url == url) {
          match = endpoint;
          break;
        }
      }
      return 'Online • ${(match?.kind ?? 'lan').toUpperCase()}';
    } catch (_) {
      return widget.connectionLabel;
    }
  }

  void _listenToEvents() {
    _subscription?.cancel();
    _subscription = widget.sseClient.streamEvents(lastEventId: _lastEventId).listen(
      _onEvent,
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _isStreaming = false;
          _connectionLabel = 'Reconnecting…';
        });
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) _listenToEvents();
        });
      },
    );
  }

  void _onEvent(CompanionEvent event) {
    if (event.id != null) _lastEventId = event.id;
    if (event.data['e2e'] != null) {
      widget.onServerE2EDetected?.call(event.data['e2e']);
    }
    final kind = event.kind;
    if (kind == 'hello') {
      if (mounted) {
        setState(() => _connectionLabel = widget.connectionLabel);
      }
      return;
    }

    if (kind == 'message' || kind == 'message.patch') {
      _handleMessageFrame(event.data, patch: kind == 'message.patch');
    }
  }

  void _handleMessageFrame(Map<String, dynamic> frame, {required bool patch}) {
    final threadId = frame['threadId'] as String? ?? '';
    final messageRaw = frame['message'];
    if (messageRaw is! Map) return;
    final message = Map<String, dynamic>.from(messageRaw);
    final botId = message['botId'] as String? ?? frame['botId'] as String? ?? _botId ?? '';
    final messageKind = message['kind'] as String? ?? 'text';
    final role = message['role'] as String? ?? 'bot';
    final id = message['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString();
    final text = message['text'] as String? ?? '';

    if (messageKind == 'options') {
      final card = message['card'];
      final cardMap = card is Map ? Map<String, dynamic>.from(card) : null;
      final answered = cardMap?['answered'] != null || cardMap?['dismissed'] == true;
      if (!answered && cardMap?['requestId'] is String) {
        final approval = ApprovalRequest.fromWireMessage(
          botId: botId,
          threadId: threadId,
          message: message,
        );
        if (mounted) {
          setState(() {
            _pendingApproval = approval;
            _isStreaming = false;
          });
        }
      } else if (answered && mounted) {
        setState(() => _pendingApproval = null);
      }
      return;
    }

    if (text.isEmpty && !patch) return;

    final chatRole = role == 'user' ? 'user' : 'assistant';
    if (mounted) {
      setState(() {
        final existing = _messages.indexWhere((item) => item.id == id);
        if (existing >= 0) {
          _messages[existing] = _messages[existing].copyWith(content: text);
        } else if (text.isNotEmpty) {
          _messages.add(ChatMessage(
            id: id,
            role: chatRole,
            content: text,
            timestamp: DateTime.now(),
          ));
        }
        _isStreaming = patch && chatRole == 'assistant';
      });
    }
  }

  Future<void> _handleSendMessage(String text) async {
    final botId = _botId;
    if (botId == null || botId.isEmpty) {
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            id: 'err-${DateTime.now().millisecondsSinceEpoch}',
            role: 'assistant',
            content: 'No bot available yet. Open the desktop app and try again.',
            timestamp: DateTime.now(),
          ));
        });
      }
      return;
    }

    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );
    setState(() {
      _messages.add(userMessage);
      _isStreaming = true;
    });

    final ok = await widget.sseClient.sendBotMessage(botId: botId, text: text);
    if (!ok && mounted) {
      setState(() {
        _isStreaming = false;
        _messages.add(ChatMessage(
          id: 'err-${DateTime.now().millisecondsSinceEpoch}',
          role: 'assistant',
          content: 'Failed to send message to companion.',
          timestamp: DateTime.now(),
        ));
      });
    }
  }

  Future<void> _resolveApproval(String behavior) async {
    final pending = _pendingApproval;
    if (pending == null) return;
    final ok = await widget.sseClient.respondApproval(
      botId: pending.botId,
      threadId: pending.threadId,
      requestId: pending.requestId,
      behavior: behavior,
    );
    if (mounted) {
      setState(() {
        if (ok) _pendingApproval = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ChatView(
      messages: _messages,
      isStreaming: _isStreaming,
      onSendMessage: _handleSendMessage,
      connectionLabel: _connectionLabel,
      pendingApproval: _pendingApproval,
      onApprove: () => _resolveApproval('allow'),
      onReject: () => _resolveApproval('deny'),
    );

    if (!widget.showPairAgainBanner) return chat;

    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: GrokTheme.darkCharcoal,
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pair again to connect from anywhere',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: GrokTheme.glowCyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                    ),
                    onPressed: widget.onPairAgain,
                    child: const Text('Pair again', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: chat),
        ],
      ),
    );
  }
}
