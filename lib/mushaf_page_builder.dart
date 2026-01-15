import 'package:sqflite/sqflite.dart';
import 'mushaf_models.dart';

// ===================== HELPER FUNCTIONS =====================

int? _safeParseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) {
    return int.tryParse(value);
  }
  if (value is double) return value.toInt();
  return null;
}

int _safeParseIntRequired(dynamic value, {int defaultValue = 0}) {
  final parsed = _safeParseInt(value);
  return parsed ?? defaultValue;
}

// ===================== PAGE BUILDER =====================

class _LineBuilder {
  final SimpleMushafLine simpleLine;
  final List<AyahWordData> ayahWords;

  _LineBuilder({
    required this.simpleLine,
    required this.ayahWords,
  });
}

class _WordsResult {
  final String text;
  final List<AyahWordData> words;

  _WordsResult(this.text, this.words);
}

class MushafPageBuilder {
  static Future<MushafPage> buildPage({
    required int pageNumber,
    required Database wordsDb,
    required Database layoutDb,
  }) async {
    final layoutData = await layoutDb.rawQuery(
        "SELECT * FROM pages WHERE page_number = ? ORDER BY line_number ASC",
        [pageNumber]);

    List<SimpleMushafLine> lines = [];
    List<PageAyah> ayahs = [];
    Map<int, List<AyahSegment>> lineToSegments = {};

    Map<String, List<AyahWordData>> ayahWords = {};

    // Collect all word ID ranges for batch querying
    final List<Map<String, int?>> wordRanges = [];

    for (int i = 0; i < layoutData.length; i++) {
      final lineData = layoutData[i];
      final firstWordId = _safeParseInt(lineData['first_word_id']);
      final lastWordId = _safeParseInt(lineData['last_word_id']);
      
      if (firstWordId != null && lastWordId != null) {
        wordRanges.add({'first': firstWordId, 'last': lastWordId, 'index': i});
      }
    }

    // Batch query all words at once if there are ranges
    Map<int, Map<String, dynamic>>? allWordsMap;
    if (wordRanges.isNotEmpty) {
      final minWordId = wordRanges.map((r) => r['first']!).reduce((a, b) => a < b ? a : b);
      final maxWordId = wordRanges.map((r) => r['last']!).reduce((a, b) => a > b ? a : b);
      
      final allWords = await wordsDb.rawQuery(
          "SELECT * FROM words WHERE id >= ? AND id <= ? ORDER BY id ASC",
          [minWordId, maxWordId]);
      
      // Index words by ID for fast lookup
      allWordsMap = {};
      for (var word in allWords) {
        final id = _safeParseIntRequired(word['id']);
        allWordsMap[id] = word;
      }
    }

    // Build lines using pre-fetched words
    for (int i = 0; i < layoutData.length; i++) {
      final lineData = layoutData[i];
      final firstWordId = _safeParseInt(lineData['first_word_id']);
      final lastWordId = _safeParseInt(lineData['last_word_id']);
      
      _LineBuilder line;
      if (firstWordId != null && lastWordId != null && allWordsMap != null) {
        // Extract words for this line from pre-fetched data
        final lineWords = <Map<String, dynamic>>[];
        for (int id = firstWordId; id <= lastWordId; id++) {
          final word = allWordsMap[id];
          if (word != null) {
            lineWords.add(word);
          }
        }
        line = await _buildLineFromWords(lineData, lineWords);
      } else {
        line = await _buildLine(lineData, wordsDb);
      }
      
      lines.add(line.simpleLine);

      for (var ayahWord in line.ayahWords) {
        final key = "${ayahWord.surah}:${ayahWord.ayah}";
        ayahWords.putIfAbsent(key, () => []).add(ayahWord);
      }
    }

    for (var entry in ayahWords.entries) {
      final parts = entry.key.split(':');
      final surahNumber = int.parse(parts[0]);
      final ayahNumber = int.parse(parts[1]);
      final words = entry.value;

      final ayah = await _buildAyah(
        surahNumber: surahNumber,
        ayahNumber: ayahNumber,
        words: words,
      );

      ayahs.add(ayah);

      for (var segment in ayah.segments) {
        lineToSegments.putIfAbsent(segment.lineNumber, () => []).add(segment);
      }
    }

    ayahs.sort((a, b) {
      if (a.surah != b.surah) return a.surah.compareTo(b.surah);
      return a.ayah.compareTo(b.ayah);
    });

    return MushafPage(
      pageNumber: pageNumber,
      lines: lines,
      ayahs: ayahs,
      lineToSegments: lineToSegments,
    );
  }

  static Future<_LineBuilder> _buildLine(
      Map<String, dynamic> lineData, Database wordsDb) async {
    final lineNumber = _safeParseIntRequired(lineData['line_number']);
    final lineType = lineData['line_type'] as String? ?? 'ayah';
    final isCentered = _safeParseInt(lineData['is_centered']) == 1;
    final firstWordId = _safeParseInt(lineData['first_word_id']);
    final lastWordId = _safeParseInt(lineData['last_word_id']);
    final surahNumber = _safeParseInt(lineData['surah_number']);

    String lineText = '';
    int? lineSurahNumber = surahNumber;
    List<AyahWordData> ayahWords = [];

    switch (lineType) {
      case 'surah_name':
        if (lineSurahNumber != null) {
          lineText = 'SURAH_BANNER_$lineSurahNumber';
        }
        break;

      case 'basmallah':
        if (firstWordId != null && lastWordId != null) {
          final result = await _buildWordsFromRange(
              wordsDb, firstWordId, lastWordId, lineNumber);
          lineText = result.text;
          ayahWords = result.words;
        } else {
          lineText = '﷽';
          ayahWords = [
            AyahWordData(
              surah: lineSurahNumber ?? 1,
              ayah: 1,
              text: '﷽',
              lineNumber: lineNumber,
              startIndex: 0,
              endIndex: 1,
            )
          ];
        }
        break;

      case 'ayah':
      default:
        if (firstWordId != null && lastWordId != null) {
          final result = await _buildWordsFromRange(
              wordsDb, firstWordId, lastWordId, lineNumber);
          lineText = result.text;
          ayahWords = result.words;

          if (lineSurahNumber == null && ayahWords.isNotEmpty) {
            lineSurahNumber = ayahWords.first.surah;
          }
        }
        break;
    }

    return _LineBuilder(
      simpleLine: SimpleMushafLine(
        lineNumber: lineNumber,
        text: lineText,
        isCentered: isCentered,
        lineType: lineType,
        surahNumber: lineSurahNumber,
      ),
      ayahWords: ayahWords,
    );
  }

  /// Build line from pre-fetched words (more memory efficient)
  static Future<_LineBuilder> _buildLineFromWords(
      Map<String, dynamic> lineData, List<Map<String, dynamic>> words) async {
    final lineNumber = _safeParseIntRequired(lineData['line_number']);
    final lineType = lineData['line_type'] as String? ?? 'ayah';
    final isCentered = _safeParseInt(lineData['is_centered']) == 1;
    final surahNumber = _safeParseInt(lineData['surah_number']);

    String lineText = '';
    int? lineSurahNumber = surahNumber;
    List<AyahWordData> ayahWords = [];

    switch (lineType) {
      case 'surah_name':
        if (lineSurahNumber != null) {
          lineText = 'SURAH_BANNER_$lineSurahNumber';
        }
        break;

      case 'basmallah':
        if (words.isNotEmpty) {
          final result = _buildWordsFromList(words, lineNumber);
          lineText = result.text;
          ayahWords = result.words;
        } else {
          lineText = '﷽';
          ayahWords = [
            AyahWordData(
              surah: lineSurahNumber ?? 1,
              ayah: 1,
              text: '﷽',
              lineNumber: lineNumber,
              startIndex: 0,
              endIndex: 1,
            )
          ];
        }
        break;

      case 'ayah':
      default:
        if (words.isNotEmpty) {
          final result = _buildWordsFromList(words, lineNumber);
          lineText = result.text;
          ayahWords = result.words;

          if (lineSurahNumber == null && ayahWords.isNotEmpty) {
            lineSurahNumber = ayahWords.first.surah;
          }
        }
        break;
    }

    return _LineBuilder(
      simpleLine: SimpleMushafLine(
        lineNumber: lineNumber,
        text: lineText,
        isCentered: isCentered,
        lineType: lineType,
        surahNumber: lineSurahNumber,
      ),
      ayahWords: ayahWords,
    );
  }

  static Future<_WordsResult> _buildWordsFromRange(
    Database wordsDb,
    int firstWordId,
    int lastWordId,
    int lineNumber,
  ) async {
    try {
      final words = await wordsDb.rawQuery(
          "SELECT * FROM words WHERE id >= ? AND id <= ? ORDER BY id ASC",
          [firstWordId, lastWordId]);

      return _buildWordsFromList(words, lineNumber);
    } catch (e) {
      print('Error building words from range: $e');
      return _WordsResult('', []);
    }
  }

  /// Build words result from a list of word data (reusable for both DB queries and pre-fetched data)
  static _WordsResult _buildWordsFromList(
    List<Map<String, dynamic>> words,
    int lineNumber,
  ) {
    if (words.isEmpty) return _WordsResult('', []);

    List<String> wordTexts = [];
    List<AyahWordData> ayahWords = [];
    int currentIndex = 0;

    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      final wordText = word['text'] as String? ?? '';
      final surahNum = _safeParseInt(word['surah']);
      final ayahNum = _safeParseInt(word['ayah']);

      wordTexts.add(wordText);

      if (surahNum != null && ayahNum != null) {
        ayahWords.add(AyahWordData(
          surah: surahNum,
          ayah: ayahNum,
          text: wordText,
          lineNumber: lineNumber,
          startIndex: currentIndex,
          endIndex: currentIndex + wordText.length,
        ));

        currentIndex += wordText.length;
      } else {
        currentIndex += wordText.length;
      }
    }

    return _WordsResult(wordTexts.join(''), ayahWords);
  }

  static Future<PageAyah> _buildAyah({
    required int surahNumber,
    required int ayahNumber,
    required List<AyahWordData> words,
  }) async {
    Map<int, List<AyahWordData>> wordsByLine = {};
    for (var word in words) {
      wordsByLine.putIfAbsent(word.lineNumber, () => []).add(word);
    }

    List<AyahSegment> segments = [];
    final sortedLineNumbers = wordsByLine.keys.toList()..sort();

    int globalWordIndex = 1;

    for (int i = 0; i < sortedLineNumbers.length; i++) {
      final lineNumber = sortedLineNumbers[i];
      final lineWords = wordsByLine[lineNumber]!;

      lineWords.sort((a, b) => a.startIndex.compareTo(b.startIndex));

      final startIndex = lineWords.first.startIndex;
      final endIndex = lineWords.last.endIndex;
      final segmentText = lineWords.map((w) => w.text).join('');

      List<AyahWord> ayahWords = [];

      for (int j = 0; j < lineWords.length; j++) {
        final word = lineWords[j];

        ayahWords.add(AyahWord(
          text: word.text,
          wordIndex: globalWordIndex++,
          startIndex: word.startIndex,
          endIndex: word.endIndex,
        ));
      }

      segments.add(AyahSegment(
        lineNumber: lineNumber,
        text: segmentText,
        startIndex: startIndex,
        endIndex: endIndex,
        isStart: i == 0,
        isEnd: i == sortedLineNumbers.length - 1,
        words: ayahWords,
      ));
    }

    final fullText = segments.map((s) => s.text).join('');

    return PageAyah(
      surah: surahNumber,
      ayah: ayahNumber,
      text: fullText,
      segments: segments,
      startLineNumber: sortedLineNumbers.first,
      endLineNumber: sortedLineNumbers.last,
    );
  }
}
