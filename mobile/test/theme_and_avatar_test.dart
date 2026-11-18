import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/theme/grok_theme.dart';
import 'package:mobile/features/bots/avatar_pulse.dart';

void main() {
  test('GrokTheme enforces OLED true black background and styling', () {
    final theme = GrokTheme.themeData;
    expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
    expect(theme.colorScheme.surface, const Color(0xFF12151B));
    expect(theme.cardColor, const Color(0xFF12151B));
    expect(theme.dividerColor, const Color(0xFF1E222B));
    expect(theme.colorScheme.secondary, const Color(0xFF00F0FF));
  });

  testWidgets('AvatarPulse renders idle and thinking pulse states', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: const Scaffold(
          body: AvatarPulse(isThinking: false, size: 48),
        ),
      ),
    );

    expect(find.byType(AvatarPulse), findsOneWidget);

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

    await tester.pumpWidget(
      MaterialApp(
        theme: GrokTheme.themeData,
        home: const Scaffold(
          body: AvatarPulse(isThinking: false, size: 60, imagePath: 'assets/mascot.png'),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AvatarPulse), findsOneWidget);
  });
}
