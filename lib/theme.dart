import 'package:flutter/material.dart';

// ===================== THEME ENUMS =====================

enum QuranThemeMode {
  normal,
  reading,
  dark,
}

// ===================== THEME MANAGER =====================

class QuranTheme {
  static Color getBackgroundColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFFFAFAFA); // Softer white for reduced eye strain
      case QuranThemeMode.reading:
        return const Color(0xFFF5F1E8); // Warmer, more paper-like sepia
      case QuranThemeMode.dark:
        return const Color(0xFF0F0F0F); // Deeper black for better contrast
    }
  }

  static Color getTextColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFF1A1A1A); // Softer black, easier on eyes
      case QuranThemeMode.reading:
        return const Color(0xFF2B1810); // Richer brown for better readability
      case QuranThemeMode.dark:
        return const Color(0xFFE8E3D3); // Warm white for comfortable reading
    }
  }

  static Color getSecondaryTextColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFF666666); // For translation text, verse numbers
      case QuranThemeMode.reading:
        return const Color(0xFF6B4423); // Muted brown for secondary elements
      case QuranThemeMode.dark:
        return const Color(0xFFB8B3A6); // Muted warm gray
    }
  }

  static Color getAppBarColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(
            0xFFF0F0F0); // Slightly darker than background for visibility
      case QuranThemeMode.reading:
        return const Color(
            0xFFE8E0D0); // Slightly darker than background for visibility
      case QuranThemeMode.dark:
        return const Color(0xFF2A2A2A); // Slightly lighter than background
    }
  }

  static Color getCardColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFFFFFFFF); // Pure white for cards
      case QuranThemeMode.reading:
        return const Color(0xFFFAF7F0); // Lighter sepia for cards
      case QuranThemeMode.dark:
        return const Color(0xFF1A1A1A); // Card background for dark mode
    }
  }

  static Color getDividerColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFFE0E0E0); // Subtle dividers
      case QuranThemeMode.reading:
        return const Color(0xFFD4C4B0); // Warm divider
      case QuranThemeMode.dark:
        return const Color(0xFF2A2A2A); // Dark mode dividers
    }
  }

  static Color getAccentColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFF0D7377); // Calming teal
      case QuranThemeMode.reading:
        return const Color(0xFF8B4513); // Rich brown accent
      case QuranThemeMode.dark:
        return const Color(0xFF14A085); // Bright teal for dark mode
    }
  }

  static Color getHighlightColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFFFFF3CD); // Soft yellow highlight
      case QuranThemeMode.reading:
        return const Color(0xFFFFE4B5); // Warm highlight
      case QuranThemeMode.dark:
        return const Color(0xFF2A4A3A); // Dark green highlight
    }
  }

  static Color getSelectionColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0xFFB3E5FC); // Light blue selection
      case QuranThemeMode.reading:
        return const Color(0xFFDEB887); // Warm selection
      case QuranThemeMode.dark:
        return const Color(0xFF37474F); // Dark selection
    }
  }

  static Color getShadowColor(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return const Color(0x0A000000); // Very subtle shadow
      case QuranThemeMode.reading:
        return const Color(0x08604020); // Ultra-soft warm shadow
      case QuranThemeMode.dark:
        return const Color(0x33000000); // Deeper shadow for dark mode
    }
  }

  // Reading-optimized text opacity
  static double getTextOpacity(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return 1.0; // Full opacity for normal mode
      case QuranThemeMode.reading:
        return 0.95; // Slightly reduced for warmth
      case QuranThemeMode.dark:
        return 0.92; // Reduced for eye comfort in dark mode
    }
  }

  static IconData getThemeIcon(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return Icons.wb_sunny; // Sun for light mode
      case QuranThemeMode.reading:
        return Icons.filter_vintage; // Vintage for sepia
      case QuranThemeMode.dark:
        return Icons.dark_mode; // Moon for dark mode
    }
  }

  static QuranThemeMode getNextTheme(QuranThemeMode currentTheme) {
    switch (currentTheme) {
      case QuranThemeMode.normal:
        return QuranThemeMode.reading;
      case QuranThemeMode.reading:
        return QuranThemeMode.dark;
      case QuranThemeMode.dark:
        return QuranThemeMode.normal;
    }
  }

  static Brightness getStatusBarBrightness(QuranThemeMode theme) {
    return theme == QuranThemeMode.dark ? Brightness.light : Brightness.dark;
  }

  // Helper method to check if theme is dark
  static bool isDarkTheme(QuranThemeMode theme) {
    return theme == QuranThemeMode.dark;
  }

  // Get theme display name
  static String getThemeDisplayName(QuranThemeMode theme) {
    switch (theme) {
      case QuranThemeMode.normal:
        return 'Light';
      case QuranThemeMode.reading:
        return 'Reading';
      case QuranThemeMode.dark:
        return 'Dark';
    }
  }
}
