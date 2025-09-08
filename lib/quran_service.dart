import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

// ===================== MODELS =====================

class Surah {
  final int id;
  final String name;
  final String nameSimple;
  final String nameArabic;
  final int revelationOrder;
  final String revelationPlace;
  final int versesCount;
  final bool bismillahPre;

  Surah({
    required this.id,
    required this.name,
    required this.nameSimple,
    required this.nameArabic,
    required this.revelationOrder,
    required this.revelationPlace,
    required this.versesCount,
    required this.bismillahPre,
  });

  factory Surah.fromJson(Map<String, dynamic> json) {
    return Surah(
      id: json['id'],
      name: json['name'],
      nameSimple: json['name_simple'],
      nameArabic: json['name_arabic'],
      revelationOrder: json['revelation_order'],
      revelationPlace: json['revelation_place'],
      versesCount: json['verses_count'],
      bismillahPre: json['bismillah_pre'],
    );
  }
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

// ===================== HELPER CLASSES =====================

class _AyahWordData {
  final int surah;
  final int ayah;
  final String text;
  final int lineNumber;
  final int startIndex;
  final int endIndex;

  _AyahWordData({
    required this.surah,
    required this.ayah,
    required this.text,
    required this.lineNumber,
    required this.startIndex,
    required this.endIndex,
  });
}

class _LineBuilder {
  final SimpleMushafLine simpleLine;
  final List<_AyahWordData> ayahWords;

  _LineBuilder({
    required this.simpleLine,
    required this.ayahWords,
  });
}

class _WordsResult {
  final String text;
  final List<_AyahWordData> words;

  _WordsResult(this.text, this.words);
}

// ===================== UTILITY FUNCTIONS =====================

int? _safeParseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  if (value is double) return value.toInt();
  return null;
}

int _safeParseIntRequired(dynamic value, {int defaultValue = 0}) {
  return _safeParseInt(value) ?? defaultValue;
}

// ===================== DATABASE SERVICE =====================

class DatabaseService {
  static Database? _wordsDb;
  static Database? _layoutDb;
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    await _copyDatabases();

    final databasesPath = await getDatabasesPath();

    _wordsDb = await openDatabase(
      p.join(databasesPath, 'qpc-v2.db'),
      version: 1,
      onCreate: (db, version) async {
        await db
            .execute('CREATE INDEX IF NOT EXISTS idx_words_id ON words(id)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_words_surah_ayah ON words(surah, ayah)');
      },
    );

    _layoutDb = await openDatabase(
      p.join(databasesPath, 'qpc-v2-15-lines.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_pages_page_number ON pages(page_number)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_pages_line_number ON pages(page_number, line_number)');
      },
    );

    _isInitialized = true;
  }

  static Future<void> _copyDatabases() async {
    final databasesPath = await getDatabasesPath();

    // Copy words database
    final wordsDbPath = p.join(databasesPath, 'qpc-v2.db');
    if (!await File(wordsDbPath).exists()) {
      final wordsData = await rootBundle.load('assets/quran/scripts/qpc-v2.db');
      final wordsBytes = wordsData.buffer
          .asUint8List(wordsData.offsetInBytes, wordsData.lengthInBytes);
      await File(wordsDbPath).writeAsBytes(wordsBytes, flush: true);
    }

    // Copy layout database
    final layoutDbPath = p.join(databasesPath, 'qpc-v2-15-lines.db');
    if (!await File(layoutDbPath).exists()) {
      final layoutData =
          await rootBundle.load('assets/quran/layout/qpc-v2-15-lines.db');
      final layoutBytes = layoutData.buffer
          .asUint8List(layoutData.offsetInBytes, layoutData.lengthInBytes);
      await File(layoutDbPath).writeAsBytes(layoutBytes, flush: true);
    }
  }

  static Database get wordsDb => _wordsDb!;
  static Database get layoutDb => _layoutDb!;

  static Future<void> close() async {
    await _wordsDb?.close();
    await _layoutDb?.close();
    _isInitialized = false;
  }
}

// ===================== FONT SERVICE =====================

class FontService {
  static final Set<int> _loadedFonts = <int>{};
  static bool _surahNameFontLoaded = false;

  static Future<void> preloadAllFonts() async {
    final fontFutures = <Future<void>>[];

    for (int page = 1; page <= 604; page++) {
      if (!_loadedFonts.contains(page)) {
        fontFutures.add(_loadFontForPage(page));
      }
    }

    await Future.wait(fontFutures);
  }

  static Future<void> _loadFontForPage(int page) async {
    if (_loadedFonts.contains(page)) return;

    try {
      final fontLoader = FontLoader('QPCPageFont$page');
      final fontData =
          await rootBundle.load('assets/quran/fonts/qpc-v2-font/p$page.ttf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _loadedFonts.add(page);
    } catch (e) {
      print('Font loading failed for page $page: $e');
    }
  }

  static Future<void> loadSurahNameFont() async {
    if (_surahNameFontLoaded) return;

    try {
      final fontLoader = FontLoader('SurahNameFont');
      final fontData =
          await rootBundle.load('assets/quran/fonts/surah-name-v2.ttf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _surahNameFontLoaded = true;
    } catch (e) {
      print('Surah name font loading failed: $e');
    }
  }

  static bool isFontLoaded(int page) => _loadedFonts.contains(page);
  static bool isSurahNameFontLoaded() => _surahNameFontLoaded;
}

// ===================== CACHE SERVICE =====================

class PageCache {
  static final Map<int, MushafPage> _cache = {};
  static const int MAX_CACHE_SIZE = 604;
  static final List<int> _accessOrder = [];

  static MushafPage? getPage(int pageNumber) {
    if (_cache.containsKey(pageNumber)) {
      _accessOrder.remove(pageNumber);
      _accessOrder.add(pageNumber);
      return _cache[pageNumber];
    }
    return null;
  }

  static void cachePage(int pageNumber, MushafPage page) {
    if (_cache.length >= MAX_CACHE_SIZE) {
      final oldestKey = _accessOrder.removeAt(0);
      _cache.remove(oldestKey);
    }
    _cache[pageNumber] = page;
    _accessOrder.add(pageNumber);
  }

  static void clearCache() {
    _cache.clear();
    _accessOrder.clear();
  }

  static int get cacheSize => _cache.length;
}

// ===================== PAGE BUILDER =====================

class PageBuilder {
  static final Map<int, List<Map<String, dynamic>>> _layoutCache = {};
  static final Map<String, List<Map<String, dynamic>>> _wordsCache = {};

  static Future<MushafPage> buildPage({
    required int pageNumber,
    required Database wordsDb,
    required Database layoutDb,
  }) async {
    final layoutData = await _getLayoutData(pageNumber, layoutDb);
    if (layoutData.isEmpty) {
      return MushafPage(
        pageNumber: pageNumber,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
    }

    final allWords = await _getAllWordsForPage(pageNumber, layoutData, wordsDb);
    final wordsByLine = _groupWordsByLine(allWords, layoutData);

    return await _buildPageFromData(pageNumber, layoutData, wordsByLine);
  }

  static Future<List<Map<String, dynamic>>> _getLayoutData(
      int pageNumber, Database layoutDb) async {
    if (_layoutCache.containsKey(pageNumber)) {
      return _layoutCache[pageNumber]!;
    }

    final layoutData = await layoutDb.rawQuery(
        "SELECT * FROM pages WHERE page_number = ? ORDER BY line_number ASC",
        [pageNumber]);

    if (_layoutCache.length >= 604) {
      _layoutCache.remove(_layoutCache.keys.first);
    }
    _layoutCache[pageNumber] = layoutData;

    return layoutData;
  }

  static Future<List<Map<String, dynamic>>> _getAllWordsForPage(
    int pageNumber,
    List<Map<String, dynamic>> layoutData,
    Database wordsDb,
  ) async {
    final List<Map<String, int>> wordRanges = [];
    for (var lineData in layoutData) {
      final firstWordId = _safeParseInt(lineData['first_word_id']);
      final lastWordId = _safeParseInt(lineData['last_word_id']);
      if (firstWordId != null && lastWordId != null) {
        wordRanges.add({
          'first': firstWordId,
          'last': lastWordId,
          'line_number': _safeParseIntRequired(lineData['line_number']),
        });
      }
    }

    if (wordRanges.isEmpty) return [];

    final cacheKey =
        '${pageNumber}_${wordRanges.map((r) => '${r['first']}-${r['last']}').join('_')}';

    if (_wordsCache.containsKey(cacheKey)) {
      return _wordsCache[cacheKey]!;
    }

    final conditions = wordRanges
        .map((range) => "(id >= ${range['first']} AND id <= ${range['last']})")
        .join(' OR ');

    final query = "SELECT * FROM words WHERE $conditions ORDER BY id ASC";
    final allWords = await wordsDb.rawQuery(query);

    if (_wordsCache.length >= 604) {
      _wordsCache.remove(_wordsCache.keys.first);
    }
    _wordsCache[cacheKey] = allWords;

    return allWords;
  }

  static Map<int, List<Map<String, dynamic>>> _groupWordsByLine(
    List<Map<String, dynamic>> allWords,
    List<Map<String, dynamic>> layoutData,
  ) {
    final wordsByLine = <int, List<Map<String, dynamic>>>{};
    final lineRanges = <int, Map<String, int>>{};

    for (var lineData in layoutData) {
      final lineNumber = _safeParseIntRequired(lineData['line_number']);
      final firstWordId = _safeParseInt(lineData['first_word_id']);
      final lastWordId = _safeParseInt(lineData['last_word_id']);

      if (firstWordId != null && lastWordId != null) {
        lineRanges[lineNumber] = {'first': firstWordId, 'last': lastWordId};
      }
    }

    for (var word in allWords) {
      final wordId = _safeParseIntRequired(word['id']);
      for (var entry in lineRanges.entries) {
        final lineNumber = entry.key;
        final range = entry.value;
        if (wordId >= range['first']! && wordId <= range['last']!) {
          wordsByLine.putIfAbsent(lineNumber, () => []).add(word);
          break;
        }
      }
    }

    return wordsByLine;
  }

  static Future<MushafPage> _buildPageFromData(
    int pageNumber,
    List<Map<String, dynamic>> layoutData,
    Map<int, List<Map<String, dynamic>>> wordsByLine,
  ) async {
    List<SimpleMushafLine> lines = [];
    List<PageAyah> ayahs = [];
    Map<int, List<AyahSegment>> lineToSegments = {};
    Map<String, List<_AyahWordData>> ayahWords = {};

    final lineFutures = layoutData.map((lineData) => _buildLineFromData(
        lineData, wordsByLine[lineData['line_number']] ?? []));

    final lineResults = await Future.wait(lineFutures);

    for (var lineResult in lineResults) {
      lines.add(lineResult.simpleLine);

      for (var ayahWord in lineResult.ayahWords) {
        final key = "${ayahWord.surah}:${ayahWord.ayah}";
        ayahWords.putIfAbsent(key, () => []).add(ayahWord);
      }
    }

    final ayahFutures = ayahWords.entries.map((entry) async {
      final parts = entry.key.split(':');
      final surahNumber = int.parse(parts[0]);
      final ayahNumber = int.parse(parts[1]);
      final words = entry.value;

      final ayah = await _buildAyah(
        surahNumber: surahNumber,
        ayahNumber: ayahNumber,
        words: words,
      );

      for (var segment in ayah.segments) {
        lineToSegments.putIfAbsent(segment.lineNumber, () => []).add(segment);
      }

      return ayah;
    });

    ayahs = await Future.wait(ayahFutures);
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

  static Future<_LineBuilder> _buildLineFromData(
    Map<String, dynamic> lineData,
    List<Map<String, dynamic>> words,
  ) async {
    final lineNumber = _safeParseIntRequired(lineData['line_number']);
    final lineType = lineData['line_type'] as String? ?? 'ayah';
    final isCentered = _safeParseInt(lineData['is_centered']) == 1;
    final surahNumber = _safeParseInt(lineData['surah_number']);

    String lineText = '';
    int? lineSurahNumber = surahNumber;
    List<_AyahWordData> ayahWords = [];

    switch (lineType) {
      case 'surah_name':
        if (lineSurahNumber != null) {
          lineText = 'SURAH_BANNER_$lineSurahNumber';
        }
        break;

      case 'basmallah':
        if (words.isNotEmpty) {
          final result = _buildWordsFromData(words, lineNumber);
          lineText = result.text;
          ayahWords = result.words;
        } else {
          lineText = '﷽';
          ayahWords = [
            _AyahWordData(
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
          final result = _buildWordsFromData(words, lineNumber);
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

  static _WordsResult _buildWordsFromData(
    List<Map<String, dynamic>> words,
    int lineNumber,
  ) {
    if (words.isEmpty) return _WordsResult('', []);

    List<String> wordTexts = [];
    List<_AyahWordData> ayahWords = [];
    int currentIndex = 0;

    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      final wordText = word['text'] as String? ?? '';
      final surahNum = _safeParseInt(word['surah']);
      final ayahNum = _safeParseInt(word['ayah']);

      wordTexts.add(wordText);

      if (surahNum != null && ayahNum != null) {
        ayahWords.add(_AyahWordData(
          surah: surahNum,
          ayah: ayahNum,
          text: wordText,
          lineNumber: lineNumber,
          startIndex: currentIndex,
          endIndex: currentIndex + wordText.length,
        ));
      }
      currentIndex += wordText.length;
    }

    return _WordsResult(wordTexts.join(''), ayahWords);
  }

  static Future<PageAyah> _buildAyah({
    required int surahNumber,
    required int ayahNumber,
    required List<_AyahWordData> words,
  }) async {
    words.sort((a, b) {
      if (a.lineNumber != b.lineNumber) {
        return a.lineNumber.compareTo(b.lineNumber);
      }
      return a.startIndex.compareTo(b.startIndex);
    });

    Map<int, List<_AyahWordData>> wordsByLine = {};
    for (var word in words) {
      wordsByLine.putIfAbsent(word.lineNumber, () => []).add(word);
    }

    List<AyahSegment> segments = [];
    final sortedLineNumbers = wordsByLine.keys.toList()..sort();

    int globalWordIndex = 1;

    for (int i = 0; i < sortedLineNumbers.length; i++) {
      final lineNumber = sortedLineNumbers[i];
      final lineWords = wordsByLine[lineNumber]!;

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

// ===================== SURAH SERVICE =====================

class SurahService {
  static final SurahService _instance = SurahService._internal();
  factory SurahService() => _instance;
  SurahService._internal();

  List<Surah>? _surahs;
  Map<int, int>? _surahToPageMap;

  Future<void> initialize() async {
    await _loadSurahMetadata();
  }

  Future<void> buildSurahToPageMap(Map<int, MushafPage> allPagesData) async {
    if (_surahs == null) return;

    _surahToPageMap = _buildSurahToPageMapping(allPagesData);
  }

  Future<void> _loadSurahMetadata() async {
    try {
      final jsonString = await rootBundle
          .loadString('assets/quran/metadata/quran-metadata-surah-name.json');
      final Map<String, dynamic> jsonData = json.decode(jsonString);

      _surahs = [];
      jsonData.forEach((key, value) {
        _surahs!.add(Surah.fromJson(value));
      });

      _surahs!.sort((a, b) => a.id.compareTo(b.id));
    } catch (e) {
      print('Error loading surah metadata: $e');
    }
  }

  Map<int, int> _buildSurahToPageMapping(Map<int, MushafPage> allPagesData) {
    final surahToPage = <int, int>{};

    for (int page = 1; page <= 604; page++) {
      final pageData = allPagesData[page];
      if (pageData != null) {
        for (final ayah in pageData.ayahs) {
          final surahId = ayah.surah;
          final ayahNumber = ayah.ayah;

          if (ayahNumber == 1 && !surahToPage.containsKey(surahId)) {
            surahToPage[surahId] = page;
          }
        }
      }
    }

    return surahToPage;
  }

  List<Surah>? get surahs => _surahs;
  Map<int, int>? get surahToPageMap => _surahToPageMap;

  int? getSurahStartPage(int surahId) {
    return _surahToPageMap?[surahId];
  }

  Surah? getSurahById(int surahId) {
    return _surahs?.firstWhere((surah) => surah.id == surahId);
  }

  int? findSurahStartPageDirectly(
      int surahId, Map<int, MushafPage> allPagesData) {
    for (int page = 1; page <= 604; page++) {
      final pageData = allPagesData[page];
      if (pageData != null) {
        for (final ayah in pageData.ayahs) {
          if (ayah.surah == surahId && ayah.ayah == 1) {
            return page;
          }
        }
      }
    }
    return null;
  }
}

// ===================== QURAN SERVICE (MAIN) =====================

class QuranService {
  static final QuranService _instance = QuranService._internal();
  factory QuranService() => _instance;
  QuranService._internal();

  final SurahService _surahService = SurahService();
  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    await DatabaseService.initialize();
    await FontService.loadSurahNameFont();
    await _surahService.initialize();

    _isInitialized = true;
  }

  Future<void> preloadAllFonts() async {
    await FontService.preloadAllFonts();
  }

  Future<MushafPage?> getPage(int pageNumber) async {
    // Check cache first
    final cachedPage = PageCache.getPage(pageNumber);
    if (cachedPage != null) {
      _allPagesData[pageNumber] = cachedPage;
      _loadedPages.add(pageNumber);
      return cachedPage;
    }

    // Load page if not cached
    return await _loadPage(pageNumber);
  }

  Future<MushafPage?> _loadPage(int pageNumber) async {
    if (_loadedPages.contains(pageNumber)) {
      return _allPagesData[pageNumber];
    }

    try {
      final mushafPage = await PageBuilder.buildPage(
        pageNumber: pageNumber,
        wordsDb: DatabaseService.wordsDb,
        layoutDb: DatabaseService.layoutDb,
      );

      PageCache.cachePage(pageNumber, mushafPage);
      _allPagesData[pageNumber] = mushafPage;
      _loadedPages.add(pageNumber);

      return mushafPage;
    } catch (e) {
      print('Error loading page $pageNumber: $e');
      return null;
    }
  }

  Future<void> preloadPagesAroundCurrent(int currentPage) async {
    const preloadRadius = 3;
    final pagesToLoad = <int>{};

    for (int i = -preloadRadius; i <= preloadRadius; i++) {
      final page = currentPage + i;
      if (page >= 1 && page <= 604 && !_loadedPages.contains(page)) {
        pagesToLoad.add(page);
      }
    }

    for (final page in pagesToLoad) {
      await _loadPage(page);
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> buildSurahMapping() async {
    await _surahService.buildSurahToPageMap(_allPagesData);
  }

  SurahService get surahService => _surahService;
  Map<int, MushafPage> get allPagesData => _allPagesData;
  bool get isInitialized => _isInitialized;

  void dispose() {
    DatabaseService.close();
    PageCache.clearCache();
  }
}
