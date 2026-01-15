// ===================== MODELS =====================

enum RendererType {
  digitalKhatt,
  qpcUthmani,
  qpcV2,
}

extension RendererTypeExtension on RendererType {
  String get name {
    switch (this) {
      case RendererType.digitalKhatt:
        return 'Digital Khatt';
      case RendererType.qpcUthmani:
        return 'QPC Uthmani';
      case RendererType.qpcV2:
        return 'QPC V2';
    }
  }

  String get wordsDbAsset {
    switch (this) {
      case RendererType.digitalKhatt:
        return 'assets/quran/renderer/digital_khatt/digital-khatt-v2.db';
      case RendererType.qpcUthmani:
        return 'assets/quran/renderer/qpc_uthmani/qpc-hafs.db';
      case RendererType.qpcV2:
        return 'assets/quran/renderer/qpc_v2/qpc-v2.db';
    }
  }

  String get layoutDbAsset {
    switch (this) {
      case RendererType.digitalKhatt:
        return 'assets/quran/renderer/digital_khatt/digital-khatt-15-lines.db';
      case RendererType.qpcUthmani:
        return 'assets/quran/renderer/qpc_uthmani/qpc-v4-15-lines.db';
      case RendererType.qpcV2:
        return 'assets/quran/renderer/qpc_v2/qpc-v2-15-lines.db';
    }
  }

  String get fontFamily {
    switch (this) {
      case RendererType.digitalKhatt:
        return 'MushafDigitalKhatt';
      case RendererType.qpcUthmani:
        return 'MushafQPCUthmani';
      case RendererType.qpcV2:
        return 'MushafQPCV2';
    }
  }

  String get fontAsset {
    switch (this) {
      case RendererType.digitalKhatt:
        return 'assets/quran/renderer/digital_khatt/font_v2.otf';
      case RendererType.qpcUthmani:
        return 'assets/quran/renderer/qpc_uthmani/font.ttf';
      case RendererType.qpcV2:
        // QPC V2 uses per-page fonts, return base path
        return 'assets/quran/renderer/qpc_v2/qpc-v2-font/';
    }
  }

  bool get hasPerPageFonts => this == RendererType.qpcV2;
  bool get usesWordsDb => true; // All renderers now use separate words DB
}

class PageAyah {
  final int surah;
  final int ayah;
  final String text;
  final List<AyahSegment> segments;
  final int startLineNumber;
  final int endLineNumber;

  PageAyah({
    required this.surah,
    required this.ayah,
    required this.text,
    required this.segments,
    required this.startLineNumber,
    required this.endLineNumber,
  });
}

class AyahSegment {
  final int lineNumber;
  final String text;
  final int startIndex;
  final int endIndex;
  final bool isStart;
  final bool isEnd;
  final List<AyahWord> words;

  AyahSegment({
    required this.lineNumber,
    required this.text,
    required this.startIndex,
    required this.endIndex,
    required this.isStart,
    required this.isEnd,
    required this.words,
  });
}

class AyahWord {
  final String text;
  final int wordIndex;
  final int startIndex;
  final int endIndex;

  AyahWord({
    required this.text,
    required this.wordIndex,
    required this.startIndex,
    required this.endIndex,
  });
}

class SimpleMushafLine {
  final int lineNumber;
  final String text;
  final bool isCentered;
  final String lineType;
  final int? surahNumber;

  SimpleMushafLine({
    required this.lineNumber,
    required this.text,
    required this.isCentered,
    required this.lineType,
    this.surahNumber,
  });
}

class MushafPage {
  final int pageNumber;
  final List<SimpleMushafLine> lines;
  final List<PageAyah> ayahs;
  final Map<int, List<AyahSegment>> lineToSegments;

  MushafPage({
    required this.pageNumber,
    required this.lines,
    required this.ayahs,
    required this.lineToSegments,
  });
}

class AyahWordData {
  final int surah;
  final int ayah;
  final String text;
  final int lineNumber;
  final int startIndex;
  final int endIndex;

  AyahWordData({
    required this.surah,
    required this.ayah,
    required this.text,
    required this.lineNumber,
    required this.startIndex,
    required this.endIndex,
  });
}
