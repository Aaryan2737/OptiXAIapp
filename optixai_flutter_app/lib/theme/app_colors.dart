import 'package:flutter/material.dart';

class AppColors {
  // Backgrounds
  static const Color background = Color(0xFFF8FAFC); // Slate 50
  static const Color backgroundElement = Color(0xFFF1F5F9); // Slate 100
  static const Color surface = Color(0xFFFFFFFF); // White
  static const Color border = Color(0xFFE2E8F0); // Slate 200

  // Brand
  static const Color primary = Color(0xFF0F766E); // Teal 700
  static const Color primaryLight = Color(0xFFF0FDFA); // Teal 50
  static const Color primaryDark = Color(0xFF115E59); // Teal 800

  // Text
  static const Color textPrimary = Color(0xFF0F172A); // Slate 900
  static const Color textSecondary = Color(0xFF64748B); // Slate 500

  // Status: Online / Success (Emerald)
  static const Color onlineBackground = Color(0xFFECFDF5);
  static const Color onlineBorder = Color(0xFFA7F3D0);
  static const Color onlineIconBg = Color(0xFFD1FAE5);
  static const Color onlineText = Color(0xFF065F46);

  // Status: Offline / Error (Rose)
  static const Color offlineBackground = Color(0xFFFFF1F2);
  static const Color offlineBorder = Color(0xFFFECDD3);
  static const Color offlineIconBg = Color(0xFFFFE4E6);
  static const Color offlineText = Color(0xFF9F1239);
  static const Color offlineTextLight = Color(0xFFBE123C);

  // Status: Syncing / Warning (Orange)
  static const Color syncBackground = Color(0xFFFFF7ED);
  static const Color syncText = Color(0xFFC2410C);
  static const Color syncStatusText = Color(0xFFB45309);
  
  // Custom Dark Theme (used exclusively for capture/review screen)
  static const Color captureBackground = Color(0xFF000000);
  static const Color captureSurface = Color(0xFF121212);
  static const Color capturePrimary = Color(0xFF00E5FF);
}
