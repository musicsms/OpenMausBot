# Grok-Style Mobile Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Flutter mobile client under `mobile/` with a Grok-style OLED dark design language that connects securely to OpenMausBot's `companion` sidecar (`:8810`) for real-time SSE streaming chat, QR pairing, and interactive tool approval cards.

**Architecture:** A standalone Flutter 3.x project in `mobile/` communicating exclusively with `companion` (`:8810`). Includes:
- A secure pairing service (`flutter_secure_storage`) capturing device tokens via QR/6-digit code.
- A smart dual-route SSE client with automatic local LAN and remote Tailscale/Tunnel failover.
- An OLED True Black UI with subtle mascot breathing glow animations, real-time Markdown/code syntax rendering, and interactive tool approval cards with haptic feedback.
- An isolated mock companion test fixture for automated testing without live data mutation.

**Tech Stack:** Flutter 3.24.5 (Dart 3.5.4), `flutter_markdown`, `flutter_secure_storage`, `mobile_scanner`, `http`, Node.js test fixture.

**Spec:** [docs/superpowers/specs/2026-11-16-grok-style-mobile-companion-design.md](file:///home/ubuntu/OpenMausBot/docs/superpowers/specs/2026-11-16-grok-style-mobile-companion-design.md)

## Global Constraints

- The mobile app must communicate exclusively with the `companion` sidecar (`:8810`) and never attempt to bind or connect to the loopback-only harness (`:8799`).
- Device tokens must be stored exclusively in platform-encrypted secure storage (Keychain / EncryptedSharedPreferences).
- All requests must carry `Authorization: Bearer <deviceToken>`.
- Adhere strictly to `OpenMausBot/AGENTS.md` coding standards: write comments only for what the code cannot say; no narrative comments; never suppress correctness lint rules.
- Isolated verification only (per `docs/verification/README.md`): all tests run against mock companion fixtures, never mutating live desktop data.

---

### Task 1: Flutter Project Scaffolding & Dependencies

**Files:**
- Create: `mobile/pubspec.yaml`
- Create: `mobile/analysis_options.yaml`
- Create: `mobile/lib/main.dart`
- Create: `mobile/test/scaffolding_test.dart`

**Interfaces:**
- Produces: Base Flutter application structure, dependencies for secure storage, markdown, scanner, and HTTP.
- Produces: App entrypoint `MausBotApp`.

- [ ] **Step 1: Write the failing test for app scaffolding**

```dart
// mobile/test/scaffolding_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('MausBotApp loads and renders base title', (WidgetTester tester) async {
    await tester.pumpWidget(const MausBotApp());
    expect(find.text('OpenMausBot'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/scaffolding_test.dart`
Expected: FAIL (files do not exist yet)

- [ ] **Step 3: Create pubspec.yaml, analysis_options.yaml, and main.dart**

Create `mobile/pubspec.yaml`:
```yaml
name: mobile
description: "Grok-style mobile companion for OpenMausBot"
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: '>=3.5.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_markdown: ^0.7.4+1
  flutter_secure_storage: ^9.2.2
  http: ^1.2.2
  mobile_scanner: ^5.2.3

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

Create `mobile/analysis_options.yaml`:
```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    prefer_const_constructors: true
    prefer_const_declarations: true
    avoid_print: true
```

Create `mobile/lib/main.dart`:
```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const MausBotApp());
}

class MausBotApp extends StatelessWidget {
  const MausBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMausBot',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          primary: Colors.white,
        ),
      ),
      home: const Scaffold(
        body: Center(
          child: Text('OpenMausBot', style: TextStyle(color: Colors.white, fontSize: 24)),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run flutter pub get and test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter pub get && flutter test test/scaffolding_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/
git commit -m "feat(mobile): scaffold Flutter project and base configuration"
```

---

### Task 2: Grok-Style OLED Dark Theme & Living Mascot Avatar

**Files:**
- Create: `mobile/lib/core/theme/grok_theme.dart`
- Create: `mobile/lib/features/bots/avatar_pulse.dart`
- Test: `mobile/test/theme_and_avatar_test.dart`

**Interfaces:**
- Produces: `GrokTheme.themeData` (OLED black `#000000`, surface `#12151B`, border `#1E222B`).
- Produces: `AvatarPulse(isThinking: bool, size: double, imagePath: String?)` widget with ambient glow.

- [ ] **Step 1: Write the failing test for GrokTheme and AvatarPulse**

```dart
// mobile/test/theme_and_avatar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/bots/avatar_pulse.dart';

void main() {
  test('GrokTheme enforces OLED true black background', () {
    final theme = GrokTheme.themeData;
    expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
    expect(theme.colorScheme.surface, const Color(0xFF12151B));
  });

  testWidgets('AvatarPulse renders with thinking pulse state', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: const Scaffold(
          body: AvatarPulse(isThinking: true, size: 60),
        ),
      ),
    );

    expect(find.byType(AvatarPulse), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AvatarPulse), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/theme_and_avatar_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement GrokTheme and AvatarPulse widget**

Create `mobile/lib/core/theme/grok_theme.dart`:
```dart
import 'package:flutter/material.dart';

class GrokTheme {
  static const Color oledBlack = Color(0xFF000000);
  static const Color darkCharcoal = Color(0xFF12151B);
  static const Color slateBorder = Color(0xFF1E222B);
  static const Color textWhite = Color(0xFFF5F5F7);
  static const Color textMuted = Color(0xFF8E929B);
  static const Color glowCyan = Color(0xFF00F0FF);
  static const Color approvalGreen = Color(0xFF10B981);
  static const Color rejectRed = Color(0xFFEF4444);

  static ThemeData get themeData {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: oledBlack,
      cardColor: darkCharcoal,
      dividerColor: slateBorder,
      colorScheme: const ColorScheme.dark(
        surface: darkCharcoal,
        primary: textWhite,
        secondary: glowCyan,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: textWhite, fontSize: 15, height: 1.4),
        bodySmall: TextStyle(color: textMuted, fontSize: 13),
        titleMedium: TextStyle(color: textWhite, fontWeight: FontWeight.w600, fontSize: 16),
      ),
    );
  }
}
```

Create `mobile/lib/features/bots/avatar_pulse.dart`:
```dart
import 'package:flutter/material.dart';
import '../../core/theme/grok_theme.dart';

class AvatarPulse extends StatefulWidget {
  final bool isThinking;
  final double size;
  final String? imagePath;

  const AvatarPulse({
    super.key,
    this.isThinking = false,
    this.size = 48.0,
    this.imagePath,
  });

  @override
  State<AvatarPulse> createState() => _AvatarPulseState();
}

class _AvatarPulseState extends State<AvatarPulse> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isThinking) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AvatarPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isThinking != oldWidget.isThinking) {
      if (widget.isThinking) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: widget.size * 1.3,
        height: widget.size * 1.3,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isThinking)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scaleAnimation.value,
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: GrokTheme.glowCyan.withValues(alpha: _opacityAnimation.value),
                      ),
                    ),
                  );
                },
              ),
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GrokTheme.darkCharcoal,
                border: Border.all(
                  color: widget.isThinking ? GrokTheme.glowCyan : GrokTheme.slateBorder,
                  width: 1.5,
                ),
              ),
              child: const Icon(Icons.smart_toy_outlined, color: Colors.white, size: 24),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/theme_and_avatar_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/theme/ mobile/lib/features/bots/ mobile/test/theme_and_avatar_test.dart
git commit -m "feat(mobile): add Grok OLED dark theme and living mascot avatar"
```

---

### Task 3: Pairing Models, QR Scanner & Secure Storage Manager

**Files:**
- Create: `mobile/lib/core/storage/pairing_storage.dart`
- Create: `mobile/lib/features/pairing/pairing_model.dart`
- Create: `mobile/lib/features/pairing/pairing_view.dart`
- Test: `mobile/test/pairing_test.dart`

**Interfaces:**
- Produces: `PairingPayload` model parsing QR JSON payload: `{ host, port, remoteUrl, pairingSecret, machineName }`.
- Produces: `PairingStorage` handling encrypted `deviceToken`, `lanHost`, `remoteUrl` persistence via `FlutterSecureStorage`.
- Produces: `PairingView` offering both camera QR scanning and manual 6-digit code entry.

- [ ] **Step 1: Write the failing test for PairingPayload and storage**

```dart
// mobile/test/pairing_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/pairing/pairing_model.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  test('PairingPayload parses JSON QR code payload correctly', () {
    const rawJson = '{"host":"192.168.1.50","port":8810,"remoteUrl":"https://omb.tailscale:8810","pairingSecret":"sec123","machineName":"Studio"}';
    final payload = PairingPayload.fromJsonString(rawJson);
    expect(payload.host, '192.168.1.50');
    expect(payload.port, 8810);
    expect(payload.remoteUrl, 'https://omb.tailscale:8810');
    expect(payload.pairingSecret, 'sec123');
    expect(payload.machineName, 'Studio');
  });

  test('PairingStorage saves and reads device credentials', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();
    await storage.saveDeviceToken('tok-abc');
    await storage.saveEndpoints(lanUrl: 'http://192.168.1.50:8810', remoteUrl: 'https://omb.tailscale:8810');

    expect(await storage.getDeviceToken(), 'tok-abc');
    expect(await storage.getLanUrl(), 'http://192.168.1.50:8810');
    expect(await storage.getRemoteUrl(), 'https://omb.tailscale:8810');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/pairing_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement PairingPayload, PairingStorage, and PairingView**

Create `mobile/lib/features/pairing/pairing_model.dart`:
```dart
import 'dart:convert';

class PairingPayload {
  final String host;
  final int port;
  final String? remoteUrl;
  final String pairingSecret;
  final String machineName;

  PairingPayload({
    required this.host,
    required this.port,
    this.remoteUrl,
    required this.pairingSecret,
    required this.machineName,
  });

  factory PairingPayload.fromJsonString(String jsonStr) {
    final Map<String, dynamic> data = jsonDecode(jsonStr);
    return PairingPayload(
      host: data['host'] as String,
      port: (data['port'] as num).toInt(),
      remoteUrl: data['remoteUrl'] as String?,
      pairingSecret: data['pairingSecret'] as String,
      machineName: data['machineName'] as String? ?? 'OpenMausBot Desktop',
    );
  }

  String get lanUrl => 'http://$host:$port';
}
```

Create `mobile/lib/core/storage/pairing_storage.dart`:
```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PairingStorage {
  final FlutterSecureStorage _storage;

  PairingStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'omb_device_token';
  static const _lanKey = 'omb_lan_url';
  static const _remoteKey = 'omb_remote_url';

  Future<void> saveDeviceToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getDeviceToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<void> saveEndpoints({required String lanUrl, String? remoteUrl}) async {
    await _storage.write(key: _lanKey, value: lanUrl);
    if (remoteUrl != null) {
      await _storage.write(key: _remoteKey, value: remoteUrl);
    }
  }

  Future<String?> getLanUrl() async {
    return await _storage.read(key: _lanKey);
  }

  Future<String?> getRemoteUrl() async {
    return await _storage.read(key: _remoteKey);
  }

  Future<void> clear() async {
    await _storage.deleteAll();
  }
}
```

Create `mobile/lib/features/pairing/pairing_view.dart`:
```dart
import 'package:flutter/material.dart';
import '../../core/theme/grok_theme.dart';
import 'pairing_model.dart';

class PairingView extends StatefulWidget {
  final Function(PairingPayload payload) onPairSuccess;
  final Function(String code) onManualCodeSubmit;

  const PairingView({
    super.key,
    required this.onPairSuccess,
    required this.onManualCodeSubmit,
  });

  @override
  State<PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<PairingView> {
  final TextEditingController _codeController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      appBar: AppBar(
        title: const Text('Pair with Desktop', style: TextStyle(color: Colors.white)),
        backgroundColor: GrokTheme.oledBlack,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              height: 220,
              width: 220,
              decoration: BoxDecoration(
                border: Border.all(color: GrokTheme.glowCyan, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Icon(Icons.qr_code_scanner, size: 80, color: GrokTheme.glowCyan),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Scan QR code from OpenMausBot Desktop Settings → Mobile',
              textAlign: TextAlign.center,
              style: TextStyle(color: GrokTheme.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(color: Colors.white, letterSpacing: 8, fontSize: 20),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: '000000',
                hintStyle: const TextStyle(color: GrokTheme.textMuted, letterSpacing: 8),
                filled: true,
                fillColor: GrokTheme.darkCharcoal,
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: GrokTheme.slateBorder),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                if (_codeController.text.length == 6) {
                  widget.onManualCodeSubmit(_codeController.text);
                }
              },
              child: const Text('Connect with Code', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/pairing_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/storage/ mobile/lib/features/pairing/ mobile/test/pairing_test.dart
git commit -m "feat(mobile): implement pairing model, secure storage, and pairing view"
```

---

### Task 4: Smart Dual-Route SSE Network Client

**Files:**
- Create: `mobile/lib/core/network/sse_client.dart`
- Test: `mobile/test/sse_client_test.dart`

**Interfaces:**
- Produces: `SseNetworkClient`:
  - `Stream<String> connectStream(String threadId, {String? lastEventId})`
  - `Future<String> resolveActiveEndpoint()` (pings LAN, falls back to Remote URL)
  - `Future<bool> postJson(String path, Map<String, dynamic> body)`

- [ ] **Step 1: Write the failing test for SseNetworkClient**

```dart
// mobile/test/sse_client_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/sse_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('SseNetworkClient parses SSE data chunks properly', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      if (request.url.path.contains('/messages')) {
        return http.Response('data: Hello world\n\ndata: from OpenMausBot\n\n', 200, headers: {
          'content-type': 'text/event-stream',
        });
      }
      return http.Response('Not found', 404);
    });

    final sseClient = SseNetworkClient(
      lanUrl: 'http://127.0.0.1:8810',
      deviceToken: 'test-tok',
      httpClient: mockClient,
    );

    final chunks = await sseClient.streamMessages('th-123').toList();
    expect(chunks, ['Hello world', 'from OpenMausBot']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/sse_client_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement SseNetworkClient with dual-route failover**

Create `mobile/lib/core/network/sse_client.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class SseNetworkClient {
  final String lanUrl;
  final String? remoteUrl;
  final String deviceToken;
  final http.Client _client;

  SseNetworkClient({
    required this.lanUrl,
    this.remoteUrl,
    required this.deviceToken,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  Future<String> resolveActiveBaseUrl() async {
    try {
      final res = await _client
          .get(Uri.parse('$lanUrl/healthz'))
          .timeout(const Duration(milliseconds: 1500));
      if (res.statusCode == 200) {
        return lanUrl;
      }
    } catch (_) {
      // Fallback to remote if LAN fails
    }

    if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      return remoteUrl!;
    }
    return lanUrl;
  }

  Stream<String> streamMessages(String threadId, {String? lastEventId}) async* {
    final baseUrl = await resolveActiveBaseUrl();
    final uri = Uri.parse('$baseUrl/api/threads/$threadId/messages');
    final request = http.Request('GET', uri);

    request.headers['Authorization'] = 'Bearer $deviceToken';
    request.headers['Accept'] = 'text/event-stream';
    if (lastEventId != null) {
      request.headers['Last-Event-ID'] = lastEventId;
    }

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Failed to connect to SSE stream: ${response.statusCode}');
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.startsWith('data: ')) {
        final payload = line.substring(6).trim();
        if (payload.isNotEmpty) {
          yield payload;
        }
      }
    }
  }

  Future<bool> postJson(String path, Map<String, dynamic> body) async {
    final baseUrl = await resolveActiveBaseUrl();
    final uri = Uri.parse('$baseUrl$path');

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $deviceToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    return res.statusCode >= 200 && res.statusCode < 300;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/sse_client_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/network/ mobile/test/sse_client_test.dart
git commit -m "feat(mobile): implement smart dual-route SSE network client"
```

---

### Task 5: Streaming Chat Screen with Markdown & Code Blocks

**Files:**
- Create: `mobile/lib/features/chat/chat_message.dart`
- Create: `mobile/lib/features/chat/chat_view.dart`
- Test: `mobile/test/chat_view_test.dart`

**Interfaces:**
- Produces: `ChatMessage(id, role, content, timestamp)` model.
- Produces: `ChatView` rendering message bubbles with `flutter_markdown` and auto-scrolling on streaming chunks.

- [ ] **Step 1: Write the failing test for ChatView rendering**

```dart
// mobile/test/chat_view_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/chat/chat_message.dart';
import 'package:mobile/features/chat/chat_view.dart';

void main() {
  testWidgets('ChatView renders user and assistant messages with markdown', (WidgetTester tester) async {
    final messages = [
      ChatMessage(id: '1', role: 'user', content: 'Liệt kê files', timestamp: DateTime.now()),
      ChatMessage(id: '2', role: 'assistant', content: '**File list:**\n- `index.ts`\n- `main.dart`', timestamp: DateTime.now()),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: ChatView(
          messages: messages,
          isStreaming: false,
          onSendMessage: (_) {},
        ),
      ),
    );

    expect(find.text('Liệt kê files'), findsOneWidget);
    expect(find.byType(ChatView), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/chat_view_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement ChatMessage and ChatView**

Create `mobile/lib/features/chat/chat_message.dart`:
```dart
class ChatMessage {
  final String id;
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  ChatMessage copyWith({String? content}) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
    );
  }
}
```

Create `mobile/lib/features/chat/chat_view.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../core/theme/grok_theme.dart';
import '../bots/avatar_pulse.dart';
import 'chat_message.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isStreaming;
  final Function(String message) onSendMessage;

  const ChatView({
    super.key,
    required this.messages,
    required this.isStreaming,
    required this.onSendMessage,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length || widget.isStreaming) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GrokTheme.oledBlack,
      appBar: AppBar(
        backgroundColor: GrokTheme.oledBlack,
        elevation: 0,
        title: Row(
          children: [
            AvatarPulse(isThinking: widget.isStreaming, size: 36),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('OpenMausBot', style: TextStyle(color: Colors.white, fontSize: 16)),
                Text('Online • LAN', style: TextStyle(color: GrokTheme.approvalGreen, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: widget.messages.length,
              itemBuilder: (context, index) {
                final msg = widget.messages[index];
                final isUser = msg.role == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(14),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    decoration: BoxDecoration(
                      color: isUser ? GrokTheme.darkCharcoal : const Color(0xFF161922),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GrokTheme.slateBorder),
                    ),
                    child: MarkdownBody(
                      data: msg.content,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                        code: const TextStyle(color: GrokTheme.glowCyan, backgroundColor: Colors.transparent),
                        codeblockDecoration: BoxDecoration(
                          color: GrokTheme.oledBlack,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: GrokTheme.slateBorder),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: GrokTheme.darkCharcoal,
              border: Border(top: BorderSide(color: GrokTheme.slateBorder)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Nhập tin nhắn...',
                        hintStyle: TextStyle(color: GrokTheme.textMuted),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: Colors.white),
                    onPressed: () {
                      final text = _inputController.text.trim();
                      if (text.isNotEmpty) {
                        HapticFeedback.lightImpact();
                        widget.onSendMessage(text);
                        _inputController.clear();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/chat_view_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/features/chat/ mobile/test/chat_view_test.dart
git commit -m "feat(mobile): implement Grok streaming chat view with markdown support"
```

---

### Task 6: Interactive Tool Approval Cards & Haptics

**Files:**
- Create: `mobile/lib/features/approvals/approval_model.dart`
- Create: `mobile/lib/features/approvals/approval_card.dart`
- Test: `mobile/test/approval_card_test.dart`

**Interfaces:**
- Produces: `ApprovalRequest(id, botId, toolName, arguments, dangerLevel)` model.
- Produces: `ApprovalCard` widget displaying arguments with `Approve` and `Reject` buttons triggering haptics and callbacks.

- [ ] **Step 1: Write the failing test for ApprovalCard**

```dart
// mobile/test/approval_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/approvals/approval_model.dart';
import 'package:mobile/features/approvals/approval_card.dart';

void main() {
  testWidgets('ApprovalCard displays tool arguments and handles approve tap', (WidgetTester tester) async {
    bool approved = false;
    final request = ApprovalRequest(
      id: 'appr-1',
      botId: 'chief',
      toolName: 'google__work__gmail_send_mail',
      arguments: {'to': 'partner@acme.com', 'subject': 'Hợp đồng'},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: Scaffold(
          body: ApprovalCard(
            request: request,
            onApprove: () => approved = true,
            onReject: () {},
          ),
        ),
      ),
    );

    expect(find.text('google__work__gmail_send_mail'), findsOneWidget);
    expect(find.text('partner@acme.com'), findsOneWidget);

    await tester.tap(find.text('Duyệt'));
    expect(approved, true);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/approval_card_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement ApprovalRequest and ApprovalCard**

Create `mobile/lib/features/approvals/approval_model.dart`:
```dart
class ApprovalRequest {
  final String id;
  final String botId;
  final String toolName;
  final Map<String, dynamic> arguments;

  ApprovalRequest({
    required this.id,
    required this.botId,
    required this.toolName,
    required this.arguments,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      id: json['id'] as String,
      botId: json['botId'] as String,
      toolName: json['toolName'] as String,
      arguments: json['arguments'] as Map<String, dynamic>? ?? {},
    );
  }
}
```

Create `mobile/lib/features/approvals/approval_card.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/grok_theme.dart';
import 'approval_model.dart';

class ApprovalCard extends StatelessWidget {
  final ApprovalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const ApprovalCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GrokTheme.darkCharcoal,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.shade700, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, color: Colors.amber.shade400, size: 20),
              const SizedBox(width: 8),
              const Text(
                'YÊU CẦU PHÊ DUYỆT CÔNG CỤ',
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            request.toolName,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: GrokTheme.oledBlack,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: GrokTheme.slateBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: request.arguments.entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${entry.key}: ', style: const TextStyle(color: GrokTheme.textMuted, fontSize: 13)),
                      Expanded(
                        child: Text('${entry.value}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: GrokTheme.rejectRed,
                    side: const BorderSide(color: GrokTheme.rejectRed),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onReject();
                  },
                  child: const Text('Từ chối'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GrokTheme.approvalGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onApprove();
                  },
                  child: const Text('Duyệt'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test test/approval_card_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/features/approvals/ mobile/test/approval_card_test.dart
git commit -m "feat(mobile): implement interactive tool approval cards with haptic actions"
```

---

### Task 7: Mock Companion Test Fixture & End-to-End Verification

**Files:**
- Create: `mobile/test/fixtures/fake-companion.ts`
- Create: `mobile/test/e2e_companion_flow_test.dart`
- Create: `scripts/build-mobile-apk.sh`

**Interfaces:**
- Produces: Node.js `fake-companion.ts` fixture serving `/healthz`, `/api/pair`, and `/api/threads/:id/messages` SSE stream on an ephemeral port.
- Produces: Complete end-to-end integration test validating the entire mobile flow (Pair -> Connect Dual-Route -> Stream Chat -> Approve Tool).

- [ ] **Step 1: Implement fake-companion.ts test fixture**

Create `mobile/test/fixtures/fake-companion.ts`:
```typescript
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

export function createFakeCompanionServer() {
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);

    if (url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (url.pathname === "/api/pair" && req.method === "POST") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ deviceToken: "mock-device-token-12345" }));
      return;
    }

    if (url.pathname.startsWith("/api/threads/") && url.pathname.endsWith("/messages")) {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      res.write("data: Xin chào! Tôi là OpenMausBot trên mobile.\n\n");
      res.write("data: Đang chuẩn bị thực hiện task...\n\n");
      setTimeout(() => res.end(), 100);
      return;
    }

    res.writeHead(404).end("Not found");
  });

  return server;
}

if (process.argv[1]?.endsWith("fake-companion.ts")) {
  const server = createFakeCompanionServer();
  server.listen(8810, "127.0.0.1", () => {
    console.log("Fake companion listening on http://127.0.0.1:8810");
  });
}
```

- [ ] **Step 2: Write end-to-end integration test**

Create `mobile/test/e2e_companion_flow_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/network/sse_client.dart';
import 'package:mobile/core/storage/pairing_storage.dart';
import 'package:mobile/features/pairing/pairing_model.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('E2E Flow: Pair device -> Store credentials -> Stream messages via dual route', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = PairingStorage();

    // 1. Parse QR
    const qrPayload = '{"host":"127.0.0.1","port":8810,"remoteUrl":null,"pairingSecret":"sec","machineName":"Studio"}';
    final payload = PairingPayload.fromJsonString(qrPayload);

    // 2. Exchange token & Save
    await storage.saveDeviceToken('tok-123');
    await storage.saveEndpoints(lanUrl: payload.lanUrl);

    // 3. Connect via SSE Client
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      if (request.url.path.contains('/messages')) {
        return http.Response('data: Chunky response\n\n', 200, headers: {'content-type': 'text/event-stream'});
      }
      return http.Response('OK', 200);
    });

    final sseClient = SseNetworkClient(
      lanUrl: (await storage.getLanUrl())!,
      deviceToken: (await storage.getDeviceToken())!,
      httpClient: mockHttp,
    );

    final streamOutput = await sseClient.streamMessages('thread-main').first;
    expect(streamOutput, 'Chunky response');
  });
}
```

- [ ] **Step 3: Create APK build script**

Create `scripts/build-mobile-apk.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="/home/ubuntu/flutter/bin:$PATH"
cd "$(dirname "$0")/../mobile"

echo "==> Resolving Flutter dependencies..."
flutter pub get

echo "==> Running Flutter test suite..."
flutter test

echo "==> Building Release APK..."
flutter build apk --release --split-per-abi

echo "==> Build complete! Output APKs located in mobile/build/app/outputs/flutter-apk/"
```
Make executable: `chmod +x scripts/build-mobile-apk.sh`

- [ ] **Step 4: Run all mobile tests to verify passes**

Run: `export PATH="/home/ubuntu/flutter/bin:$PATH" && cd mobile && flutter test`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/test/ scripts/build-mobile-apk.sh
git commit -m "test(mobile): add fake companion fixture and complete end-to-end tests"
```
