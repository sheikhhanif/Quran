import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'surah_header_banner.dart';

// ===================== MODELS =====================

// Core Ayah Model
class PageAyah {
  final int surah;
  final int ayah;
  final String text;
  final List<AyahSegment> segments; // Ayah can span multiple lines
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

// Represents a portion of an ayah on a specific line
class AyahSegment {
  final int lineNumber;
  final String text;
  final int startIndex; // Start position in the line
  final int endIndex;   // End position in the line
  final bool isStart;   // Is this the start of the ayah?
  final bool isEnd;     // Is this the end of the ayah?

  AyahSegment({
    required this.lineNumber,
    required this.text,
    required this.startIndex,
    required this.endIndex,
    required this.isStart,
    required this.isEnd,
  });
}

// Simplified Line Model
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

// Page Model that contains both lines and ayahs
class MushafPage {
  final int pageNumber;
  final List<SimpleMushafLine> lines;
  final List<PageAyah> ayahs;
  final Map<int, List<AyahSegment>> lineToSegments; // line number -> segments

  MushafPage({
    required this.pageNumber,
    required this.lines,
    required this.ayahs,
    required this.lineToSegments,
  });
}

// Helper classes for building
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

// View Mode Enum
enum ViewMode {
  mushaf,
  list,
}

// ===================== HELPER FUNCTIONS =====================

// Safe integer conversion from database values
int? _safeParseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) {
    return int.tryParse(value);
  }
  if (value is double) return value.toInt();
  return null;
}

// Safe integer conversion with required value
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
        [pageNumber]
    );

    List<SimpleMushafLine> lines = [];
    List<PageAyah> ayahs = [];
    Map<int, List<AyahSegment>> lineToSegments = {};

    // Temporary storage for building ayahs
    Map<String, List<AyahWordData>> ayahWords = {}; // "surah:ayah" -> words

    // First pass: build lines and collect ayah words
    for (var lineData in layoutData) {
      final line = await _buildLine(lineData, wordsDb);
      lines.add(line.simpleLine);

      // Collect ayah words for this line
      for (var ayahWord in line.ayahWords) {
        final key = "${ayahWord.surah}:${ayahWord.ayah}";
        ayahWords.putIfAbsent(key, () => []).add(ayahWord);
      }
    }

    // Second pass: build complete ayahs from collected words
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

      // Map segments to lines
      for (var segment in ayah.segments) {
        lineToSegments.putIfAbsent(segment.lineNumber, () => []).add(segment);
      }
    }

    // Sort ayahs by order
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

  static Future<_LineBuilder> _buildLine(Map<String, dynamic> lineData, Database wordsDb) async {
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
          final result = await _buildWordsFromRange(wordsDb, firstWordId, lastWordId, lineNumber);
          lineText = result.text;
          ayahWords = result.words;
        } else {
          lineText = '﷽';
          ayahWords = [AyahWordData(
            surah: lineSurahNumber ?? 1,
            ayah: 1,
            text: '﷽',
            lineNumber: lineNumber,
            startIndex: 0,
            endIndex: 1,
          )];
        }
        break;

      case 'ayah':
      default:
        if (firstWordId != null && lastWordId != null) {
          final result = await _buildWordsFromRange(wordsDb, firstWordId, lastWordId, lineNumber);
          lineText = result.text;
          ayahWords = result.words;

          // Update surah number from words if not set
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
          [firstWordId, lastWordId]
      );

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
          // Add space before word if not first
          if (i > 0) currentIndex++;

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
          // Handle words without ayah info
          if (i > 0) currentIndex++;
          currentIndex += wordText.length;
        }
      }

      return _WordsResult(wordTexts.join(' '), ayahWords);
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
    // Group words by line
    Map<int, List<AyahWordData>> wordsByLine = {};
    for (var word in words) {
      wordsByLine.putIfAbsent(word.lineNumber, () => []).add(word);
    }

    // Build segments
    List<AyahSegment> segments = [];
    final sortedLineNumbers = wordsByLine.keys.toList()..sort();

    for (int i = 0; i < sortedLineNumbers.length; i++) {
      final lineNumber = sortedLineNumbers[i];
      final lineWords = wordsByLine[lineNumber]!;

      // Sort words by position
      lineWords.sort((a, b) => a.startIndex.compareTo(b.startIndex));

      final startIndex = lineWords.first.startIndex;
      final endIndex = lineWords.last.endIndex;
      final segmentText = lineWords.map((w) => w.text).join(' ');

      segments.add(AyahSegment(
        lineNumber: lineNumber,
        text: segmentText,
        startIndex: startIndex,
        endIndex: endIndex,
        isStart: i == 0,
        isEnd: i == sortedLineNumbers.length - 1,
      ));
    }

    final fullText = segments.map((s) => s.text).join(' ');

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

  // Store all pages data with new model
  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};

  bool _isInitializing = true;
  bool _isPreloading = false;
  String _loadingMessage = 'Initializing...';
  double _preloadProgress = 0.0;

  // View Mode
  ViewMode _viewMode = ViewMode.mushaf;

  // PageView controller
  late PageController _pageController;

  // Audio related
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoading = false;
  int _currentAyahIndex = 0;
  double _audioProgress = 0.0;
  String _reciterId = '7'; // Default reciter (Abdul Basit)

  // Highlight
  int? _highlightedAyahIndex;

  // Progress bar interaction
  bool _isDragging = false;

  static final Set<int> _loadedFonts = <int>{};
  static bool _surahNameFontLoaded = false;

  // Preloading configuration
  static const int BATCH_SIZE = 10;
  static const int PRELOAD_RADIUS = 5;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _setupAudioPlayer();
    _initDatabases();
  }

  void _setupAudioPlayer() {
    _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
        _isLoading = state == PlayerState.playing ? false : _isLoading;
      });
    });

    _audioPlayer.onPositionChanged.listen((Duration position) {
      if (!_isDragging && _isPlaying) {
        setState(() {
          _audioProgress = position.inMilliseconds.toDouble();
        });
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      _playNextAyah();
    });
  }

  Future<void> _initDatabases() async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      final databasesPath = await getDatabasesPath();

      final wordsDbPath = p.join(databasesPath, 'qpc-v2.db');
      if (!await File(wordsDbPath).exists()) {
        setState(() {
          _loadingMessage = 'Copying words database...';
        });
        final wordsData = await rootBundle.load('assets/quran/scripts/qpc-v2.db');
        final wordsBytes = wordsData.buffer
            .asUint8List(wordsData.offsetInBytes, wordsData.lengthInBytes);
        await File(wordsDbPath).writeAsBytes(wordsBytes, flush: true);
      }

      final layoutDbPath = p.join(databasesPath, 'qpc-v2-15-lines.db');
      if (!await File(layoutDbPath).exists()) {
        setState(() {
          _loadingMessage = 'Copying layout database...';
        });
        final layoutData =
        await rootBundle.load('assets/quran/layout/qpc-v2-15-lines.db');
        final layoutBytes = layoutData.buffer
            .asUint8List(layoutData.offsetInBytes, layoutData.lengthInBytes);
        await File(layoutDbPath).writeAsBytes(layoutBytes, flush: true);
      }

      _wordsDb = await openDatabase(wordsDbPath);
      _layoutDb = await openDatabase(layoutDbPath);

      await _loadSurahNameFont();

      // Load initial page immediately
      await _loadPage(_currentPage);

      setState(() {
        _isInitializing = false;
      });

      // Start background preloading
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

    for (int batchStart = 1; batchStart <= totalPages; batchStart += BATCH_SIZE) {
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
      final fontData =
      await rootBundle.load('assets/quran/fonts/qpc-v2-font/p$page.ttf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _loadedFonts.add(page);
    } catch (e) {
      // Font loading failed
    }
  }

  Future<void> _loadSurahNameFont() async {
    if (_surahNameFontLoaded) return;

    try {
      final fontLoader = FontLoader('SurahNameFont');
      final fontData = await rootBundle.load('assets/quran/fonts/surah-name-v2.ttf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _surahNameFontLoaded = true;
    } catch (e) {
      // Font loading failed
    }
  }

  Future<void> _loadPage(int page) async {
    if (_loadedPages.contains(page)) {
      setState(() {
        _currentPage = page;
        _updateCurrentPageAyahs();
      });
      return;
    }

    await _loadPageSilently(page);
    setState(() {
      _currentPage = page;
      _updateCurrentPageAyahs();
    });
  }

  Future<void> _loadPageSilently(int page) async {
    if (_wordsDb == null || _layoutDb == null || _loadedPages.contains(page)) return;

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
      // Create empty page as fallback
      _allPagesData[page] = MushafPage(
        pageNumber: page,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
    }
  }

  void _updateCurrentPageAyahs() {
    _stopAudio();

    setState(() {
      _currentAyahIndex = 0;
      _audioProgress = 0.0;
      _highlightedAyahIndex = null;
    });
  }

  MushafPage? _getCurrentPage() {
    return _allPagesData[_currentPage];
  }

  List<PageAyah> _getCurrentPageAyahs() {
    return _getCurrentPage()?.ayahs ?? [];
  }

  void _onPageChanged(int index) {
    final page = index + 1;
    _currentPage = page;
    _updateCurrentPageAyahs();

    _loadAroundCurrentPage(page);
  }

  // Find ayah index by surah and ayah number
  int? _findAyahIndex(int surahNumber, int ayahNumber) {
    final ayahs = _getCurrentPageAyahs();
    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == surahNumber && ayahs[i].ayah == ayahNumber) {
        return i;
      }
    }
    return null;
  }

  // Handle ayah click
  void _onAyahTap(int surahNumber, int ayahNumber) {
    final ayahIndex = _findAyahIndex(surahNumber, ayahNumber);
    if (ayahIndex != null) {
      setState(() {
        _currentAyahIndex = ayahIndex;
        _highlightedAyahIndex = ayahIndex;
        // Update progress bar position
        final ayahs = _getCurrentPageAyahs();
        _audioProgress = ayahs.length > 1
            ? ayahIndex / (ayahs.length - 1)
            : 0.0;
      });

      // If currently playing, play the clicked ayah
      if (_isPlaying) {
        _playCurrentAyah();
      }
    }
  }

  // Toggle between view modes
  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == ViewMode.mushaf ? ViewMode.list : ViewMode.mushaf;
    });
  }

  // Handle double tap to toggle view mode
  void _onDoubleTap() {
    _toggleViewMode();
  }

  // Get test translation for ayah
  String _getTestTranslation(int surahNumber, int ayahNumber) {
    // This is placeholder translation - replace with actual translation data
    return "This is a test translation for Surah $surahNumber, Ayah $ayahNumber. In a real implementation, you would load this from a translation database or API.";
  }

  // Audio Controls
  void _togglePlayPause() async {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      if (_currentAyahIndex < ayahs.length) {
        await _playCurrentAyah();
      }
    }
  }

  Future<void> _playCurrentAyah() async {
    final ayahs = _getCurrentPageAyahs();
    if (_currentAyahIndex >= ayahs.length) return;

    final ayah = ayahs[_currentAyahIndex];

    setState(() {
      _isLoading = true;
      _highlightedAyahIndex = _currentAyahIndex;
    });

    try {
      // First, get the audio file info from the API
      final apiUrl = 'https://api.quran.com/api/v4/recitations/$_reciterId/by_ayah/${ayah.surah}:${ayah.ayah}';

      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body);
        final audioFiles = jsonData['audio_files'] as List?;

        if (audioFiles != null && audioFiles.isNotEmpty) {
          final audioUrl = audioFiles[0]['url'] as String?;

          if (audioUrl != null) {
            // The URL is relative, so we need to prepend the base URL
            final fullAudioUrl = 'https://verses.quran.com/$audioUrl';
            await _audioPlayer.play(UrlSource(fullAudioUrl));
          } else {
            throw Exception('No audio URL found in response');
          }
        } else {
          throw Exception('No audio files found in response');
        }
      } else {
        throw Exception('Failed to fetch audio info: ${response.statusCode}');
      }

    } catch (e) {
      setState(() {
        _isLoading = false;
        _isPlaying = false;
      });
      print('Audio playback error: $e');
      // Show user-friendly error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to play audio. Please check your connection.'),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _playNextAyah() {
    final ayahs = _getCurrentPageAyahs();
    if (_currentAyahIndex < ayahs.length - 1) {
      setState(() {
        _currentAyahIndex++;
        _audioProgress = _currentAyahIndex / ayahs.length;
      });
      _playCurrentAyah();
    } else {
      setState(() {
        _isPlaying = false;
        _highlightedAyahIndex = null;
        _currentAyahIndex = 0;
        _audioProgress = 0.0;
      });
    }
  }

  void _stopAudio() async {
    await _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
      _isLoading = false;
      _highlightedAyahIndex = null;
      _currentAyahIndex = 0;
      _audioProgress = 0.0;
    });
  }

  void _onProgressBarChanged(double value) {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    final newIndex = (value * (ayahs.length - 1)).round();
    setState(() {
      _currentAyahIndex = newIndex;
      _audioProgress = value;
      _highlightedAyahIndex = newIndex;
    });

    if (_isPlaying) {
      _playCurrentAyah();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _audioPlayer.dispose();
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
        title: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Mushaf - Page $_currentPage'),
                SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleViewMode,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _viewMode == ViewMode.mushaf ? Icons.view_list : Icons.pages,
                          size: 16,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text(
                          _viewMode == ViewMode.mushaf ? 'List' : 'Page',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_isPreloading)
              Container(
                margin: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                  value: _preloadProgress,
                  backgroundColor: Colors.white30,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  minHeight: 2,
                ),
              ),
          ],
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF8B7355),
        foregroundColor: Colors.white,
        toolbarHeight: _isPreloading ? (isTablet ? 90 : 76) : (isTablet ? 70 : 56),
        automaticallyImplyLeading: false,
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
          : PageView.builder(
        controller: _pageController,
        itemCount: 604,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final page = index + 1;
          if (_viewMode == ViewMode.mushaf) {
            return _buildMushafPage(page);
          } else {
            return _buildListPage(page);
          }
        },
      ),
      bottomNavigationBar: _buildAudioBottomBar(isTablet),
    );
  }

  Widget _buildAudioBottomBar(bool isTablet) {
    final ayahs = _getCurrentPageAyahs();

    return Container(
      height: isTablet ? 100 : 80,
      decoration: const BoxDecoration(
        color: Color(0xFFF0E6D6),
        border: Border(
          top: BorderSide(color: Color(0xFFD2B48C), width: 1),
        ),
      ),
      padding: EdgeInsets.only(
        left: isTablet ? 20 : 16,
        right: isTablet ? 20 : 16,
        top: isTablet ? 12 : 10,
        bottom: isTablet ? 16 : 12,
      ),
      child: Row(
        children: [
          // Current Ayah Info
          Container(
            width: isTablet ? 50 : 45,
            child: Text(
              ayahs.isNotEmpty
                  ? '${_currentAyahIndex + 1}/${ayahs.length}'
                  : '0/0',
              style: TextStyle(
                fontSize: isTablet ? 12 : 10,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF8B7355),
              ),
            ),
          ),
          SizedBox(width: isTablet ? 12 : 10),

          // Single Play/Pause Button
          GestureDetector(
            onTap: ayahs.isNotEmpty ? _togglePlayPause : null,
            child: Container(
              width: isTablet ? 48 : 44,
              height: isTablet ? 48 : 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ayahs.isNotEmpty
                    ? const Color(0xFF8B7355)
                    : Colors.grey,
              ),
              child: _isLoading
                  ? SizedBox(
                width: isTablet ? 20 : 18,
                height: isTablet ? 20 : 18,
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
                  : Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                size: isTablet ? 26 : 24,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(width: isTablet ? 16 : 12),

          // Progress Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: isTablet ? 4 : 3,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: isTablet ? 10 : 8,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: isTablet ? 16 : 14,
                ),
                activeTrackColor: const Color(0xFF8B7355),
                inactiveTrackColor: const Color(0xFFD2B48C),
                thumbColor: const Color(0xFF8B7355),
                overlayColor: const Color(0xFF8B7355).withOpacity(0.2),
              ),
              child: Slider(
                value: ayahs.isEmpty ? 0.0 :
                (_currentAyahIndex / (ayahs.length - 1).clamp(1, double.infinity)),
                min: 0.0,
                max: 1.0,
                divisions: ayahs.length > 1 ? ayahs.length - 1 : 1,
                onChangeStart: (value) {
                  setState(() {
                    _isDragging = true;
                  });
                },
                onChanged: _onProgressBarChanged,
                onChangeEnd: (value) {
                  setState(() {
                    _isDragging = false;
                  });
                },
              ),
            ),
          ),
          SizedBox(width: isTablet ? 16 : 12),

          // Info Section - Right side
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Surah:Ayah Info
              if (ayahs.isNotEmpty && _highlightedAyahIndex != null)
                Text(
                  '${ayahs[_highlightedAyahIndex!].surah}:${ayahs[_highlightedAyahIndex!].ayah}',
                  style: TextStyle(
                    fontSize: isTablet ? 12 : 10,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF8B7355),
                  ),
                ),
              SizedBox(height: isTablet ? 4 : 3),
              // Page & Reciter Info
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isTablet ? 8 : 6,
                      vertical: isTablet ? 3 : 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6D7C3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD2B48C), width: 0.5),
                    ),
                    child: Text(
                      '$_currentPage/604',
                      style: TextStyle(
                        fontSize: isTablet ? 11 : 9,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF8B7355),
                      ),
                    ),
                  ),
                  SizedBox(width: isTablet ? 6 : 4),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isTablet ? 8 : 6,
                      vertical: isTablet ? 3 : 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6D7C3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD2B48C), width: 0.5),
                    ),
                    child: Text(
                      'باسط',
                      style: TextStyle(
                        fontSize: isTablet ? 11 : 9,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF8B7355),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListPage(int page) {
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
    final ayahs = mushafPage.ayahs;

    if (ayahs.isEmpty) {
      return const Center(
        child: Text(
          'No ayahs found on this page',
          style: TextStyle(
            fontSize: 16,
            color: Color(0xFF8B7355),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0E6D6),
      ),
      child: GestureDetector(
        onDoubleTap: _onDoubleTap,
        child: ListView.builder(
          padding: EdgeInsets.all(isTablet ? 16 : 12),
          itemCount: ayahs.length,
          itemBuilder: (context, index) {
            final ayah = ayahs[index];
            final isHighlighted = _highlightedAyahIndex == index;

            return _buildAyahCard(ayah, index, isHighlighted, isTablet);
          },
        ),
      ),
    );
  }

  Widget _buildAyahCard(PageAyah ayah, int index, bool isHighlighted, bool isTablet) {
    final translation = _getTestTranslation(ayah.surah, ayah.ayah);

    return Container(
      margin: EdgeInsets.only(bottom: isTablet ? 16 : 12),
      decoration: BoxDecoration(
        color: isHighlighted
            ? Colors.amber.withOpacity(0.1)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isHighlighted
              ? const Color(0xFF8B7355)
              : const Color(0xFFD2B48C),
          width: isHighlighted ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _onAyahTap(ayah.surah, ayah.ayah),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(isTablet ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Ayah Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Ayah Number Badge
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isTablet ? 12 : 10,
                      vertical: isTablet ? 6 : 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B7355),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${ayah.surah}:${ayah.ayah}',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: isTablet ? 14 : 12,
                      ),
                    ),
                  ),

                  // Play button for this ayah
                  Container(
                    decoration: BoxDecoration(
                      color: isHighlighted
                          ? const Color(0xFF8B7355)
                          : const Color(0xFFF0E6D6),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        (_isPlaying && _highlightedAyahIndex == index)
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: isHighlighted ? Colors.white : const Color(0xFF8B7355),
                        size: isTablet ? 24 : 20,
                      ),
                      onPressed: () => _onAyahTap(ayah.surah, ayah.ayah),
                    ),
                  ),
                ],
              ),

              SizedBox(height: isTablet ? 16 : 12),

              // Arabic Text
              Container(
                padding: EdgeInsets.all(isTablet ? 16 : 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F6F0),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFE6D7C3),
                    width: 1,
                  ),
                ),
                child: Text(
                  ayah.text,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    fontFamily: 'QPCPageFont$_currentPage',
                    fontSize: isTablet ? 24 : 20,
                    height: 1.8,
                    color: const Color(0xFF2C2C2C),
                  ),
                ),
              ),

              SizedBox(height: isTablet ? 12 : 8),

              // Translation
              Container(
                padding: EdgeInsets.all(isTablet ? 16 : 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F3ED),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  translation,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: isTablet ? 16 : 14,
                    height: 1.6,
                    color: const Color(0xFF4A4A4A),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
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
    final appBarHeight = _isPreloading ? (isTablet ? 90.0 : 76.0) : (isTablet ? 70.0 : 56.0);
    final bottomNavHeight = isTablet ? 110.0 : 90.0;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final availableHeight =
        screenSize.height - appBarHeight - bottomNavHeight - statusBarHeight;

    return Container(
      width: double.infinity,
      height: availableHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFF0E6D6),
      ),
      child: GestureDetector(
        onDoubleTap: _onDoubleTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: mushafPage.lines
                        .map((line) => _buildLine(line, constraints, page))
                        .toList(),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLine(SimpleMushafLine line, BoxConstraints constraints, int page) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final isLandscape = screenSize.width > screenSize.height;

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

            return GestureDetector(
              onTapUp: (details) => _handleLineClick(details, line),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 0),
                    child: _buildHighlightedText(line, isTablet, isLandscape, screenSize, page),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHighlightedText(SimpleMushafLine line, bool isTablet, bool isLandscape, Size screenSize, int page) {
    final fontSize = _getMaximizedFontSize(line.lineType, isTablet, isLandscape, screenSize);
    final fontFamily = line.lineType == 'surah_name'
        ? 'SurahNameFont'
        : 'QPCPageFont$page';

    final mushafPage = _getCurrentPage();
    if (mushafPage == null) {
      return _buildTextWithThickness(line.text, fontSize, fontFamily);
    }

    // Get segments for this line
    final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];

    // Check if any segment should be highlighted
    AyahSegment? highlightedSegment;
    if (_highlightedAyahIndex != null && _highlightedAyahIndex! < mushafPage.ayahs.length) {
      final highlightedAyah = mushafPage.ayahs[_highlightedAyahIndex!];

      // Find if any segment in this line belongs to the highlighted ayah
      for (var segment in segments) {
        if (highlightedAyah.segments.contains(segment)) {
          highlightedSegment = segment;
          break;
        }
      }
    }

    // If no highlighting needed, return normal clickable text
    if (highlightedSegment == null) {
      return _buildTextWithThickness(line.text, fontSize, fontFamily);
    }

    // Build highlighted text using character-by-character approach
    return _buildCharacterHighlightedText(
      text: line.text,
      startIndex: highlightedSegment.startIndex,
      endIndex: highlightedSegment.endIndex,
      fontSize: fontSize,
      fontFamily: fontFamily,
    );
  }

  Widget _buildCharacterHighlightedText({
    required String text,
    required int startIndex,
    required int endIndex,
    required double fontSize,
    required String fontFamily,
  }) {
    final strokeWidth = fontSize * 0.025;
    final spans = <TextSpan>[];

    // Build character by character
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      final isHighlighted = i >= startIndex && i < endIndex;

      spans.add(TextSpan(
        text: char,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = isHighlighted ? Colors.red.shade900 : Colors.black,
          backgroundColor: isHighlighted ? Colors.amber.withOpacity(0.3) : null,
        ),
      ));
    }

    return Stack(
      children: [
        // Stroke layer
        RichText(
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          text: TextSpan(children: spans),
        ),
        // Fill layer
        RichText(
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          text: TextSpan(
            children: spans.map((span) => TextSpan(
              text: span.text,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                color: span.style?.backgroundColor != null
                    ? const Color(0xFF8B7355)
                    : Colors.black,
                backgroundColor: span.style?.backgroundColor,
              ),
            )).toList(),
          ),
        ),
      ],
    );
  }

  // Handle click on text line to determine which ayah was clicked
  void _handleLineClick(TapUpDetails details, SimpleMushafLine line) {
    final mushafPage = _getCurrentPage();
    if (mushafPage == null) return;

    final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
    if (segments.isEmpty) return;

    // For simplicity, if multiple segments on line, use the first one
    // You could make this more sophisticated by calculating click position
    final segment = segments.first;

    // Find which ayah this segment belongs to
    PageAyah? clickedAyah;
    for (var ayah in mushafPage.ayahs) {
      if (ayah.segments.contains(segment)) {
        clickedAyah = ayah;
        break;
      }
    }

    if (clickedAyah != null) {
      _onAyahTap(clickedAyah.surah, clickedAyah.ayah);
    }
  }

  Widget _buildTextWithThickness(String text, double fontSize, String fontFamily, {Color? backgroundColor, Color textColor = Colors.black}) {
    final strokeWidth = fontSize * 0.025;

    Widget textWidget = Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = textColor,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: textColor,
          ),
        ),
      ],
    );

    if (backgroundColor != null) {
      return Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: textWidget,
      );
    }

    return textWidget;
  }

  double _getMaximizedFontSize(
      String lineType, bool isTablet, bool isLandscape, Size screenSize) {
    final screenMultiplier =
    isTablet ? (isLandscape ? 1.8 : 1.5) : (isLandscape ? 1.3 : 1.0);
    final widthMultiplier = (screenSize.width / 400).clamp(0.8, 2.5);
    return 20.0 * screenMultiplier * widthMultiplier;
  }
}