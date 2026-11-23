import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nibble/core/theme/grok_theme.dart';
import 'package:nibble/features/bots/avatar_pulse.dart';
import 'package:nibble/features/chat/chat_message.dart';
import 'package:nibble/features/chat/chat_view.dart';

void main() {
  group('ChatMessage', () {
    test('creates ChatMessage and copyWith updates content', () {
      final now = DateTime.now();
      final msg = ChatMessage(id: '1', role: 'user', content: 'hello', timestamp: now);
      expect(msg.id, '1');
      expect(msg.role, 'user');
      expect(msg.content, 'hello');
      expect(msg.timestamp, now);

      final updated = msg.copyWith(content: 'updated');
      expect(updated.id, '1');
      expect(updated.role, 'user');
      expect(updated.content, 'updated');
      expect(updated.timestamp, now);
    });
  });

  group('ChatView', () {
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
      expect(find.text('Nibble'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
    });

    testWidgets('AvatarPulse reflects isStreaming state', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: const [],
            isStreaming: true,
            onSendMessage: (_) {},
          ),
        ),
      );

      final avatarPulse = tester.widget<AvatarPulse>(find.byType(AvatarPulse));
      expect(avatarPulse.isThinking, isTrue);
    });

    testWidgets('sends message and clears input when send button is tapped', (WidgetTester tester) async {
      String? sentMessage;
      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: const [],
            isStreaming: false,
            onSendMessage: (msg) {
              sentMessage = msg;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Test message');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(sentMessage, 'Test message');
      expect(find.text('Test message'), findsNothing);
    });

    testWidgets('sends message and clears input when submitted via keyboard action', (WidgetTester tester) async {
      String? sentMessage;
      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: const [],
            isStreaming: false,
            onSendMessage: (msg) {
              sentMessage = msg;
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Keyboard message');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(sentMessage, 'Keyboard message');
      expect(find.text('Keyboard message'), findsNothing);
    });

    testWidgets('does not send message when input is empty or whitespace', (WidgetTester tester) async {
      var sendCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: const [],
            isStreaming: false,
            onSendMessage: (_) => sendCount++,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(sendCount, 0);
    });

    testWidgets('triggers scroll on message list update or streaming', (WidgetTester tester) async {
      final messages1 = [
        ChatMessage(id: '1', role: 'user', content: 'Message 1', timestamp: DateTime.now()),
      ];
      final messages2 = [
        ChatMessage(id: '1', role: 'user', content: 'Message 1', timestamp: DateTime.now()),
        ChatMessage(id: '2', role: 'assistant', content: 'Message 2', timestamp: DateTime.now()),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: messages1,
            isStreaming: false,
            onSendMessage: (_) {},
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: messages2,
            isStreaming: true,
            onSendMessage: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Message 2'), findsOneWidget);
    });

    testWidgets('unmounting during post-frame callback does not throw', (WidgetTester tester) async {
      final messages1 = [
        ChatMessage(id: '1', role: 'user', content: 'Message 1', timestamp: DateTime.now()),
      ];
      final messages2 = [
        ChatMessage(id: '1', role: 'user', content: 'Message 1', timestamp: DateTime.now()),
        ChatMessage(id: '2', role: 'assistant', content: 'Message 2', timestamp: DateTime.now()),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: messages1,
            isStreaming: false,
            onSendMessage: (_) {},
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: GrokTheme.themeData,
          home: ChatView(
            messages: messages2,
            isStreaming: true,
            onSendMessage: (_) {},
          ),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox.shrink(),
        ),
      );

      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
