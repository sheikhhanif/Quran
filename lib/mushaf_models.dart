// ===================== MODELS =====================

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
