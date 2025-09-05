import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

class SurahBanner extends StatefulWidget {
  final int surahNumber;
  final bool isCentered;

  const SurahBanner({
    super.key,
    required this.surahNumber,
    required this.isCentered,
  });

  // Static variables for font and ligatures
  static bool _surahHeaderFontLoaded = false;
  static Map<String, String>? _ligatures;
  static bool _isInitializing = false;

  static Future<void> _ensureFontAndLigaturesLoaded() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      if (!_surahHeaderFontLoaded) {
        final fontLoader = FontLoader('SurahHeaderFont');
        final fontData = await rootBundle
            .load('assets/quran/fonts/surah-header/surah-header.ttf');
        fontLoader.addFont(Future.value(fontData));
        await fontLoader.load();
        _surahHeaderFontLoaded = true;
      }
      if (_ligatures == null) {
        final jsonStr = await rootBundle
            .loadString('assets/quran/fonts/surah-header/ligatures.json');
        final Map<String, dynamic> decoded = json.decode(jsonStr);
        _ligatures = decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    } finally {
      _isInitializing = false;
    }
  }

  static String? _glyphForSurah(int number) {
    final map = _ligatures;
    if (map == null) return null;
    return map['surah-$number'];
  }

  // Public method to preload font and ligatures at startup
  static Future<void> preload() async {
    await _ensureFontAndLigaturesLoaded();
  }

  @override
  State<SurahBanner> createState() => _SurahBannerState();
}

class _SurahBannerState extends State<SurahBanner> {
  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final bannerHeight = isTablet ? 84.0 : 64.0;

    // Get glyph immediately if data is already loaded
    final glyph = SurahBanner._ligatures != null
        ? SurahBanner._glyphForSurah(widget.surahNumber)
        : null;

    Widget flutterFallback() => Container(
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: bannerHeight * 0.8,
        maxHeight: bannerHeight * 1.2,
      ),
      margin: EdgeInsets.symmetric(horizontal: isTablet ? 24 : 16),
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      child: FittedBox(
        fit: BoxFit.fitWidth,
        alignment: Alignment.center,
        child: Text(
          glyph ?? 'سورة ${widget.surahNumber}',
          maxLines: 1,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          style: TextStyle(
            fontFamily: glyph != null ? 'SurahHeaderFont' : 'SurahNameFont',
            fontSize: isTablet ? 96 : 72,
            height: 1.0,
            letterSpacing: 0.0,
            color: const Color(0xFF3E2723),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    // If data is not loaded yet, show loading state only once
    if (SurahBanner._ligatures == null && !SurahBanner._isInitializing) {
      // Start loading in background
      SurahBanner._ensureFontAndLigaturesLoaded();
      return Container(
        width: double.infinity,
        constraints: BoxConstraints(
          minHeight: bannerHeight * 0.8,
          maxHeight: bannerHeight * 1.2,
        ),
        margin: EdgeInsets.symmetric(horizontal: isTablet ? 24 : 16),
        alignment: Alignment.center,
        child: Text(
          'سورة ${widget.surahNumber}',
          maxLines: 1,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          style: TextStyle(
            fontFamily: 'SurahNameFont',
            fontSize: isTablet ? 96 : 72,
            height: 1.0,
            letterSpacing: 0.0,
            color: const Color(0xFF3E2723),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    if (Theme.of(context).platform == TargetPlatform.iOS && glyph != null) {
      return Container(
        width: double.infinity,
        constraints: BoxConstraints(
          minHeight: bannerHeight * 0.8,
          maxHeight: bannerHeight * 1.2,
        ),
        margin: EdgeInsets.symmetric(horizontal: isTablet ? 24 : 16),
        alignment: Alignment.center,
        child: UiKitView(
          viewType: 'SurahHeaderView',
          layoutDirection: TextDirection.rtl,
          creationParams: {
            'text': glyph,
          },
          creationParamsCodec: const StandardMessageCodec(),
        ),
      );
    }

    return flutterFallback();
  }
}
