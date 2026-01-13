import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'surah_header_banner.dart';

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

    for (var lineData in layoutData) {
      final line = await _buildLine(lineData, wordsDb);
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
    } catch (e) {
      print('Error building words from range: $e');
      return _WordsResult('', []);
    }
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

// ===================== MAIN WIDGET =====================

class MushafPageViewer extends StatefulWidget {
  const MushafPageViewer({super.key});

  @override
  State<MushafPageViewer> createState() => _MushafPageViewerState();
}

class _MushafPageViewerState extends State<MushafPageViewer> {
  Database? _wordsDb;
  Database? _layoutDb;
  int _currentPage = 1;

  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};
  final Map<int, double> _uniformFontSizeCache = {};

  bool _isInitializing = true;
  bool _isPreloading = false;
  String _loadingMessage = 'Initializing...';
  double _preloadProgress = 0.0;

  late PageController _pageController;

  static final Set<int> _loadedFonts = <int>{};
  static bool _surahNameFontLoaded = false;

  static const int BATCH_SIZE = 10;
  static const int PRELOAD_RADIUS = 5;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _initDatabases();
  }

  Future<void> _initDatabases() async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      final databasesPath = await getDatabasesPath();

      final wordsDbPath = p.join(databasesPath, 'qpc-hafs.db');
      if (!await File(wordsDbPath).exists()) {
        setState(() {
          _loadingMessage = 'Copying words database...';
        });
        final wordsData =
            await rootBundle.load('assets/quran/scripts/qpc-hafs.db');
        final wordsBytes = wordsData.buffer
            .asUint8List(wordsData.offsetInBytes, wordsData.lengthInBytes);
        await File(wordsDbPath).writeAsBytes(wordsBytes, flush: true);
      }

      final layoutDbPath = p.join(databasesPath, 'qpc-v4-15-lines.db');
      if (!await File(layoutDbPath).exists()) {
        setState(() {
          _loadingMessage = 'Copying layout database...';
        });
        final layoutData =
            await rootBundle.load('assets/quran/layout/qpc-v4-15-lines.db');
        final layoutBytes = layoutData.buffer
            .asUint8List(layoutData.offsetInBytes, layoutData.lengthInBytes);
        await File(layoutDbPath).writeAsBytes(layoutBytes, flush: true);
      }

      _wordsDb = await openDatabase(wordsDbPath);
      _layoutDb = await openDatabase(layoutDbPath);

      await _loadSurahNameFont();

      await _loadPage(_currentPage);

      setState(() {
        _isInitializing = false;
      });

      _startBackgroundPreloading();
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $e';
      });
    }
  }

  Future<void> _startBackgroundPreloading() async {
    setState(() {
      _isPreloading = true;
      _preloadProgress = 0.0;
    });

    final totalPages = 604;
    int loadedCount = _loadedPages.length;

    for (int batchStart = 1;
        batchStart <= totalPages;
        batchStart += BATCH_SIZE) {
      final batchEnd = (batchStart + BATCH_SIZE - 1).clamp(1, totalPages);
      final batch = <Future<void>>[];

      for (int page = batchStart; page <= batchEnd; page++) {
        if (!_loadedPages.contains(page)) {
          batch.add(_loadPageSilently(page));
        }
      }

      if (batch.isNotEmpty) {
        await Future.wait(batch);
        loadedCount += batch.length;

        setState(() {
          _preloadProgress = loadedCount / totalPages;
        });
      }

      await Future.delayed(const Duration(milliseconds: 50));
    }

    setState(() {
      _isPreloading = false;
    });
  }

  Future<void> _loadAroundCurrentPage(int currentPage) async {
    final pagesToLoad = <int>{};

    for (int i = -PRELOAD_RADIUS; i <= PRELOAD_RADIUS; i++) {
      final page = currentPage + i;
      if (page >= 1 && page <= 604 && !_loadedPages.contains(page)) {
        pagesToLoad.add(page);
      }
    }

    final futures = pagesToLoad.map((page) => _loadPageSilently(page));
    await Future.wait(futures);
  }

  Future<void> _loadFontForPage(int page) async {
    if (_loadedFonts.contains(page)) return;

    try {
      final fontLoader = FontLoader('QPCPageFont$page');
      final fontData = await rootBundle.load('assets/quran/fonts/uth.ttf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _loadedFonts.add(page);
    } catch (e) {
      print('Font loading failed for page $page: $e');
    }
  }

  Future<void> _loadSurahNameFont() async {
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

  Future<void> _loadPage(int page) async {
    if (_loadedPages.contains(page)) {
      setState(() {
        _currentPage = page;
      });
      return;
    }

    await _loadPageSilently(page);
    setState(() {
      _currentPage = page;
    });
  }

  Future<void> _loadPageSilently(int page) async {
    if (_wordsDb == null || _layoutDb == null || _loadedPages.contains(page))
      return;

    try {
      await _loadFontForPage(page);

      final mushafPage = await MushafPageBuilder.buildPage(
        pageNumber: page,
        wordsDb: _wordsDb!,
        layoutDb: _layoutDb!,
      );

      _allPagesData[page] = mushafPage;
      _loadedPages.add(page);
    } catch (e) {
      print('Error loading page $page: $e');
      _allPagesData[page] = MushafPage(
        pageNumber: page,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
    }
  }

  void _onPageChanged(int index) {
    final page = index + 1;
    _currentPage = page;
    _loadAroundCurrentPage(page);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _wordsDb?.close();
    _layoutDb?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F1E8),
      appBar: AppBar(
        title: Text('Mushaf - Page $_currentPage'),
        centerTitle: true,
        backgroundColor: const Color(0xFF8B7355),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        bottom: _isPreloading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: _preloadProgress,
                  backgroundColor: Colors.white30,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  minHeight: 2,
                ),
              )
            : null,
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF8B7355),
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.book),
            label: 'Mushaf',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search),
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bookmark),
            label: 'Bookmarks',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
        onTap: (index) {
          // Placeholder for navigation
        },
      ),
      body: _isInitializing
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    strokeWidth: isTablet ? 6 : 4,
                  ),
                  SizedBox(height: isTablet ? 24 : 16),
                  Text(
                    _loadingMessage,
                    style: TextStyle(
                        fontSize: isTablet ? 18 : 16,
                        color: const Color(0xFFD2B48C)),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: 604,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final page = index + 1;
                      return _buildMushafPage(page);
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildMushafPage(int page) {
    final mushafPage = _allPagesData[page];

    if (mushafPage == null) {
      if (!_loadedPages.contains(page)) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Loading page $page...',
                  style: const TextStyle(fontSize: 16)),
            ],
          ),
        );
      }

      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Color(0xFF8B4513)),
            SizedBox(height: 16),
            Text('No content found for this page',
                style: TextStyle(fontSize: 18)),
          ],
        ),
      );
    }

    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final appBarHeight = kToolbarHeight + (_isPreloading ? 4.0 : 0.0);
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Reserve standard bottom navigation bar space (56.0) plus system inset
    const double bottomNavBarHeight = 56.0;
    final availableHeight = screenSize.height -
        appBarHeight -
        statusBarHeight -
        bottomInset -
        bottomNavBarHeight;

    return Container(
      width: double.infinity,
      height: availableHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 24.0 : 16.0,
        vertical: isTablet ? 16.0 : 12.0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = MediaQuery.of(context).size;
          final isTablet = screenSize.width > 600;
          final isLandscape = screenSize.width > screenSize.height;
          final computedSize = _computeUniformFontSizeForPage(
            page,
            mushafPage,
            constraints.maxWidth,
            isTablet,
            isLandscape,
            screenSize,
          );
          _uniformFontSizeCache[page] = computedSize;
          return Column(
            mainAxisAlignment: page <= 2
                ? MainAxisAlignment.center
                : MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: mushafPage.lines
                .map((line) => _buildLine(line, constraints, page, mushafPage))
                .toList(),
          );
        },
      ),
    );
  }

  Widget _buildLine(SimpleMushafLine line, BoxConstraints constraints, int page,
      MushafPage mushafPage) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final isLandscape = screenSize.width > screenSize.height;

    if (page <= 2) {
      return Container(
        width: double.infinity,
        child: Builder(
          builder: (context) {
            if (line.lineType == 'surah_name') {
              final surahNumber =
                  int.tryParse(line.text.replaceAll('SURAH_BANNER_', ''));
              if (surahNumber != null) {
                return GestureDetector(
                  child: SurahBanner(
                    surahNumber: surahNumber,
                    isCentered: line.isCentered,
                  ),
                );
              }
            }

            return _buildLineWithKashida(line, page, mushafPage,
                constraints.maxWidth, isTablet, isLandscape, screenSize);
          },
        ),
      );
    }

    return Expanded(
      flex: 1,
      child: Container(
        width: double.infinity,
        child: Builder(
          builder: (context) {
            if (line.lineType == 'surah_name') {
              final surahNumber =
                  int.tryParse(line.text.replaceAll('SURAH_BANNER_', ''));
              if (surahNumber != null) {
                return GestureDetector(
                  child: SurahBanner(
                    surahNumber: surahNumber,
                    isCentered: line.isCentered,
                  ),
                );
              }
            }

            return _buildLineWithKashida(line, page, mushafPage,
                constraints.maxWidth, isTablet, isLandscape, screenSize);
          },
        ),
      ),
    );
  }

  Widget _buildLineWithKashida(
    SimpleMushafLine line,
    int page,
    MushafPage mushafPage,
    double maxWidth,
    bool isTablet,
    bool isLandscape,
    Size screenSize,
  ) {
    final double? uniformFontSize = _uniformFontSizeCache[page];

    if (uniformFontSize == null) {
      return Container(
        width: double.infinity,
        child: Center(
          child: Text(
            line.text,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontFamily: 'QPCPageFont$page',
              fontSize: _getBaseFontSize(isTablet, isLandscape, screenSize),
            ),
          ),
        ),
      );
    }

    final String fontFamily = 'QPCPageFont$page';
    final double targetWidth = maxWidth - 16.0;

    final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
    final List<String> words = [];

    for (final segment in segments) {
      for (final word in segment.words) {
        words.add(word.text);
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: CustomPaint(
        size: Size(targetWidth, uniformFontSize * 1.5),
        painter: UniformTextPainter(
          text: line.text,
          words: words.isNotEmpty ? words : [line.text],
          fontSize: uniformFontSize,
          fontFamily: fontFamily,
          targetWidth: targetWidth,
          textColor: Colors.black,
        ),
      ),
    );
  }

  double _computeUniformFontSizeForPage(
    int page,
    MushafPage mushafPage,
    double maxWidth,
    bool isTablet,
    bool isLandscape,
    Size screenSize,
  ) {
    double low = 8.0;
    double high = 300.0;

    final String fontFamily = 'QPCPageFont$page';
    final double targetWidth = maxWidth - 16.0;
    // Use hair space (U+200A) – one of the thinnest spaces
    const thinSpace = '\u200A';

    bool fitsAll(double size) {
      for (final line in mushafPage.lines) {
        if (line.lineType == 'surah_name') continue;
        final String text = line.text;
        if (text.isEmpty) continue;

        // Build text with thin spaces between words (same as in rendering)
        final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
        final List<String> words = [];
        for (final segment in segments) {
          for (final word in segment.words) {
            words.add(word.text);
          }
        }

        // Use text with thin spaces if we have words, otherwise use original text
        final String textToMeasure =
            words.isNotEmpty ? words.join(thinSpace) : text;

        final textSpan = TextSpan(
          text: textToMeasure,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: size,
          ),
        );

        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.rtl,
          textAlign: TextAlign.left,
        );
        textPainter.layout();

        if (textPainter.width > targetWidth) {
          return false;
        }
      }
      return true;
    }

    for (int i = 0; i < 20; i++) {
      final mid = (low + high) / 2.0;
      if (fitsAll(mid)) {
        low = mid;
      } else {
        high = mid;
      }
    }

    return low;
  }

  double _getBaseFontSize(bool isTablet, bool isLandscape, Size screenSize) {
    final screenMultiplier =
        isTablet ? (isLandscape ? 1.8 : 1.5) : (isLandscape ? 1.3 : 1.0);
    final widthMultiplier = (screenSize.width / 400).clamp(0.8, 2.5);

    return 20.0 * screenMultiplier * widthMultiplier;
  }
}

// ===================== CUSTOM PAINTER =====================

class UniformTextPainter extends CustomPainter {
  final String text;
  final List<String> words;
  final double fontSize;
  final String fontFamily;
  final double targetWidth;
  final Color textColor;

  UniformTextPainter({
    required this.text,
    required this.words,
    required this.fontSize,
    required this.fontFamily,
    required this.targetWidth,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty || words.isEmpty) return;

    // Join words with hair space (U+200A) – very thin gap between words
    const thinSpace = '\u200A';
    final String lineText = words.join(thinSpace);

    final result = _renderText(lineText);

    // If text is already close to or exceeds target width, don't add extra spaces
    if (result.width >= targetWidth * 0.98) {
      _paintText(canvas, size, lineText);
      return;
    }

    // Find optimal number of extra thin spaces to add between words
    final int extraSpacesCount =
        _findOptimalExtraSpacesCount(lineText, targetWidth);
    final String justifiedText =
        _addExtraThinSpaces(lineText, extraSpacesCount);

    // Verify the justified text doesn't exceed target width
    final verifiedResult = _renderText(justifiedText);
    if (verifiedResult.width > targetWidth * 1.02) {
      // If justified text exceeds width, use original text with thin spaces
      _paintText(canvas, size, lineText);
    } else {
      _paintText(canvas, size, justifiedText);
    }
  }

  TextPainter _renderText(String text) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: textColor,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.left,
    );
    textPainter.layout();

    return textPainter;
  }

  int _findOptimalExtraSpacesCount(String text, double targetWidth) {
    if (words.length < 2)
      return 0; // Need at least 2 words to add spaces between them

    int low = 0;
    int high = 50; // Maximum extra thin spaces to try
    int bestCount = 0;
    double bestDiff = double.infinity;

    for (int i = 0; i < 15; i++) {
      int mid = (low + high) ~/ 2;
      final justifiedText = _addExtraThinSpaces(text, mid);
      final painter = _renderText(justifiedText);
      final diff = (painter.width - targetWidth).abs();

      if (diff < bestDiff) {
        bestDiff = diff;
        bestCount = mid;
      }

      if (painter.width < targetWidth * 0.98) {
        low = mid + 1;
      } else if (painter.width > targetWidth * 1.02) {
        high = mid - 1;
      } else {
        break;
      }
    }

    return bestCount;
  }

  String _addExtraThinSpaces(String text, int extraSpacesCount) {
    if (extraSpacesCount == 0 || words.length < 2) return text;

    const thinSpace = '\u200A';

    // Calculate how many spaces to add between each word pair
    // We have (words.length - 1) gaps between words
    final int gaps = words.length - 1;
    if (gaps == 0) return text;

    // Distribute extra spaces evenly
    final int baseSpacesPerGap = extraSpacesCount ~/ gaps;
    final int remainder = extraSpacesCount % gaps;

    // Build the justified text by adding extra thin spaces between words
    final List<String> resultWords = [];
    for (int i = 0; i < words.length; i++) {
      resultWords.add(words[i]);

      // Add spaces after each word except the last one
      if (i < words.length - 1) {
        // Base spaces (1 original + extra)
        int spacesToAdd = 1 + baseSpacesPerGap;
        // Distribute remainder from left to right
        if (i < remainder) {
          spacesToAdd += 1;
        }
        resultWords.add(thinSpace * spacesToAdd);
      }
    }

    return resultWords.join('');
  }

  void _paintText(Canvas canvas, Size size, String text) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: textColor,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.left,
    );
    textPainter.layout();

    final double x = (targetWidth - textPainter.width) / 2;
    final double y = (size.height - textPainter.height) / 2;

    textPainter.paint(canvas, Offset(x, y));
  }

  @override
  bool shouldRepaint(UniformTextPainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.words != words ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.targetWidth != targetWidth ||
        oldDelegate.textColor != textColor;
  }
}
