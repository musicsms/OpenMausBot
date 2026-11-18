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
