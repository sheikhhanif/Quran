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
  final int endIndex; // End position in the line
  final bool isStart; // Is this the start of the ayah?
  final bool isEnd; // Is this the end of the ayah?
  final List<AyahWord> words; // Words in this segment

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

// Individual word in an ayah segment
class AyahWord {
  final String text;
  final int wordIndex; // Index within the ayah
  final int startIndex; // Start position in segment text
  final int endIndex; // End position in segment text

  AyahWord({
    required this.text,
    required this.wordIndex,
    required this.startIndex,
    required this.endIndex,
  });
}

// Audio segment timing
class AudioSegment {
  final int wordIndex;
  final int startTimeMs;
  final int endTimeMs;

  AudioSegment({
    required this.wordIndex,
    required this.startTimeMs,
    required this.endTimeMs,
  });
}

// Audio data for an ayah
class AudioData {
  final int surahNumber;
  final int ayahNumber;
  final String audioUrl;
  final int? duration;
  final List<AudioSegment> segments;

  AudioData({
    required this.surahNumber,
    required this.ayahNumber,
    required this.audioUrl,
    this.duration,
    required this.segments,
  });

  factory AudioData.fromJson(Map<String, dynamic> json) {
    final segments = <AudioSegment>[];
    if (json['segments'] != null) {
      for (var segment in json['segments']) {
        segments.add(AudioSegment(
          wordIndex: segment[0],
          startTimeMs: segment[1],
          endTimeMs: segment[2],
        ));
      }
    }

    return AudioData(
      surahNumber: json['surah_number'],
      ayahNumber: json['ayah_number'],
      audioUrl: json['audio_url'],
      duration: json['duration'],
      segments: segments,
    );
  }
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

// Audio playback state
enum AudioPlaybackState {
  stopped,
  playing,
  paused,
  loading,
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

// ===================== AUDIO SERVICE =====================

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  Map<String, AudioData>? _allAudioData;

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<AudioPlaybackState> _stateController =
      StreamController<AudioPlaybackState>.broadcast();
  final StreamController<String?> _highlightController =
      StreamController<String?>.broadcast();
  final StreamController<PageAyah?> _currentAyahController =
      StreamController<PageAyah?>.broadcast();

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<AudioPlaybackState> get stateStream => _stateController.stream;
  Stream<String?> get highlightStream => _highlightController.stream;
  Stream<PageAyah?> get currentAyahStream => _currentAyahController.stream;

  AudioData? _currentAudioData;
  PageAyah? _currentAyah;
  List<PageAyah>? _pageAyahs;
  int _currentAyahIndex = 0;

  Future<void> initialize() async {
    await _loadAudioData();

    _playerStateSubscription =
        _audioPlayer.onPlayerStateChanged.listen((state) {
      switch (state) {
        case PlayerState.playing:
          _stateController.add(AudioPlaybackState.playing);
          break;
        case PlayerState.paused:
          _stateController.add(AudioPlaybackState.paused);
          break;
        case PlayerState.stopped:
          _stateController.add(AudioPlaybackState.stopped);
          _highlightController.add(null);
          _currentAyahController.add(null);
          break;
        case PlayerState.completed:
          _onAudioCompleted();
          break;
        case PlayerState.disposed:
          break;
      }
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      _positionController.add(position);
      _updateWordHighlight(position);
    });
  }

  Future<void> _loadAudioData() async {
    try {
      final jsonString = await rootBundle.loadString(
          'assets/quran/audio/ayah-recitation-mahmoud-khalil-al-husary-mujawwad-hafs-956.json');
      final Map<String, dynamic> jsonData = json.decode(jsonString);

      _allAudioData = {};
      jsonData.forEach((key, value) {
        _allAudioData![key] = AudioData.fromJson(value);
      });
    } catch (e) {
      print('Error loading audio data: $e');
    }
  }

  AudioData? getAudioData(int surah, int ayah) {
    final key = '$surah:$ayah';
    return _allAudioData?[key];
  }

  Future<void> playPageAyahs(List<PageAyah> ayahs) async {
    if (ayahs.isEmpty) return;

    _pageAyahs = ayahs;
    _currentAyahIndex = 0;
    await _playCurrentAyah();
  }

  Future<void> _playCurrentAyah() async {
    if (_pageAyahs == null || _currentAyahIndex >= _pageAyahs!.length) {
      await stop();
      return;
    }

    final ayah = _pageAyahs![_currentAyahIndex];
    final audioData = getAudioData(ayah.surah, ayah.ayah);

    if (audioData == null) {
      // Skip to next ayah if no audio data
      _currentAyahIndex++;
      await _playCurrentAyah();
      return;
    }

    try {
      _stateController.add(AudioPlaybackState.loading);
      _currentAudioData = audioData;
      _currentAyah = ayah;
      _currentAyahController.add(ayah);

      await _audioPlayer.play(UrlSource(audioData.audioUrl));
    } catch (e) {
      print('Error playing ayah ${ayah.surah}:${ayah.ayah} - $e');
      // Skip to next ayah on error
      _currentAyahIndex++;
      await _playCurrentAyah();
    }
  }

  Future<void> _onAudioCompleted() async {
    _currentAyahIndex++;

    // Small delay before playing next ayah
    await Future.delayed(const Duration(milliseconds: 500));

    if (_currentAyahIndex < (_pageAyahs?.length ?? 0)) {
      await _playCurrentAyah();
    } else {
      // All ayahs completed
      _stateController.add(AudioPlaybackState.stopped);
      _highlightController.add(null);
      _currentAyahController.add(null);
      _pageAyahs = null;
    }
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  Future<void> resume() async {
    await _audioPlayer.resume();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    _highlightController.add(null);
    _currentAyahController.add(null);
    _pageAyahs = null;
    _currentAyahIndex = 0;
  }

  void _updateWordHighlight(Duration position) {
    if (_currentAudioData == null || _currentAyah == null) return;

    final positionMs = position.inMilliseconds;

    // Find the current segment being played
    for (final segment in _currentAudioData!.segments) {
      if (positionMs >= segment.startTimeMs && positionMs < segment.endTimeMs) {
        // Generate a unique identifier for the word
        final wordId =
            '${_currentAyah!.surah}:${_currentAyah!.ayah}:${segment.wordIndex}';
        _highlightController.add(wordId);
        return;
      }
    }

    _highlightController.add(null);
  }

  void dispose() {
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _positionController.close();
    _stateController.close();
    _highlightController.close();
    _currentAyahController.close();
    _audioPlayer.dispose();
  }
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

    // Build segments with individual words
    List<AyahSegment> segments = [];
    final sortedLineNumbers = wordsByLine.keys.toList()..sort();

    int globalWordIndex = 1;

    for (int i = 0; i < sortedLineNumbers.length; i++) {
      final lineNumber = sortedLineNumbers[i];
      final lineWords = wordsByLine[lineNumber]!;

      // Sort words by position
      lineWords.sort((a, b) => a.startIndex.compareTo(b.startIndex));

      final startIndex = lineWords.first.startIndex;
      final endIndex = lineWords.last.endIndex;
      final segmentText = lineWords.map((w) => w.text).join(' ');

      // Build AyahWord objects for this segment
      List<AyahWord> ayahWords = [];
      int segmentIndex = 0;

      for (int j = 0; j < lineWords.length; j++) {
        final word = lineWords[j];
        if (j > 0) segmentIndex++; // Account for space

        ayahWords.add(AyahWord(
          text: word.text,
          wordIndex: globalWordIndex++,
          startIndex: segmentIndex,
          endIndex: segmentIndex + word.text.length,
        ));

        segmentIndex += word.text.length;
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

  // Audio service
  final AudioService _audioService = AudioService();
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;
  PageAyah? _currentPlayingAyah;

  // Add this new variable for user selection
  String? _userSelectedWordId;

  // PageView controller
  late PageController _pageController;

  static final Set<int> _loadedFonts = <int>{};
  static bool _surahNameFontLoaded = false;

  // Preloading configuration
  static const int BATCH_SIZE = 10;
  static const int PRELOAD_RADIUS = 5;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _initDatabases();
    _initAudio();
  }

  Future<void> _initAudio() async {
    await _audioService.initialize();

    _audioService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _audioState = state;
        });
      }
    });

    _audioService.highlightStream.listen((wordId) {
      if (mounted) {
        setState(() {
          _highlightedWordId = wordId;
        });
      }
    });

    _audioService.currentAyahStream.listen((ayah) {
      if (mounted) {
        setState(() {
          _currentPlayingAyah = ayah;
        });
      }
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
        final wordsData =
            await rootBundle.load('assets/quran/scripts/qpc-v2.db');
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
      final fontData =
          await rootBundle.load('assets/quran/fonts/surah-name-v2.ttf');
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
      // Create empty page as fallback
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

    // Stop audio when page changes
    if (_audioState != AudioPlaybackState.stopped) {
      _stopAudio();
    }
  }

  Future<void> _playPageAudio() async {
    final page = _allPagesData[_currentPage];
    if (page == null || page.ayahs.isEmpty) return;

    // Filter out non-Quranic content and sort ayahs
    final ayahsToPlay =
        page.ayahs.where((ayah) => ayah.surah > 0 && ayah.ayah > 0).toList()
          ..sort((a, b) {
            if (a.surah != b.surah) return a.surah.compareTo(b.surah);
            return a.ayah.compareTo(b.ayah);
          });

    if (ayahsToPlay.isNotEmpty) {
      await _audioService.playPageAyahs(ayahsToPlay);
    }
  }

  Future<void> _toggleAudio() async {
    switch (_audioState) {
      case AudioPlaybackState.stopped:
        await _playPageAudio();
        break;
      case AudioPlaybackState.playing:
        await _audioService.pause();
        break;
      case AudioPlaybackState.paused:
        await _audioService.resume();
        break;
      case AudioPlaybackState.loading:
        // Do nothing while loading
        break;
    }
  }

  Future<void> _stopAudio() async {
    await _audioService.stop();
    setState(() {
      _currentPlayingAyah = null;
      _highlightedWordId = null;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _wordsDb?.close();
    _layoutDb?.close();
    _audioService.dispose();
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
            Text('Mushaf - Page $_currentPage'),
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
        toolbarHeight:
            _isPreloading ? (isTablet ? 90 : 76) : (isTablet ? 70 : 56),
        automaticallyImplyLeading: false,
        actions: [
          if (_audioState == AudioPlaybackState.playing ||
              _audioState == AudioPlaybackState.paused)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopAudio,
            ),
        ],
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
          : Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: 604,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final page = index + 1;
                    return _buildMushafPage(page);
                  },
                ),
                // Floating Audio Button
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: _buildFloatingAudioButton(),
                ),
              ],
            ),
    );
  }

  Widget _buildFloatingAudioButton() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            spreadRadius: 2,
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: FloatingActionButton(
        onPressed:
            _audioState == AudioPlaybackState.loading ? null : _toggleAudio,
        backgroundColor: _getAudioButtonColor(),
        foregroundColor: Colors.white,
        elevation: 0,
        child: _getAudioButtonIcon(),
      ),
    );
  }

  Color _getAudioButtonColor() {
    switch (_audioState) {
      case AudioPlaybackState.playing:
        return Colors.orange[600]!;
      case AudioPlaybackState.paused:
        return Colors.blue[600]!;
      case AudioPlaybackState.loading:
        return Colors.grey[600]!;
      case AudioPlaybackState.stopped:
      default:
        return Colors.green[600]!;
    }
  }

  Widget _getAudioButtonIcon() {
    switch (_audioState) {
      case AudioPlaybackState.playing:
        return const Icon(Icons.pause, size: 28);
      case AudioPlaybackState.paused:
        return const Icon(Icons.play_arrow, size: 28);
      case AudioPlaybackState.loading:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        );
      case AudioPlaybackState.stopped:
      default:
        return const Icon(Icons.play_arrow, size: 28);
    }
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
    final appBarHeight =
        _isPreloading ? (isTablet ? 90.0 : 76.0) : (isTablet ? 70.0 : 56.0);
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final availableHeight = screenSize.height - appBarHeight - statusBarHeight;

    return Container(
      width: double.infinity,
      height: availableHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFF0E6D6),
      ),
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
                      .map((line) =>
                          _buildLine(line, constraints, page, mushafPage))
                      .toList(),
                ),
              ),
            ),
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

            // Check if this line has ayah segments for word highlighting
            final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];

            return Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                  child: segments.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            // Handle line tap - you can highlight the first ayah in the line
                            if (segments.isNotEmpty) {
                              final firstSegment = segments.first;
                              final ayah = _findAyahForSegment(firstSegment);
                              if (ayah != null) {
                                setState(() {
                                  _userSelectedWordId =
                                      '${ayah.surah}:${ayah.ayah}:1';
                                });
                              }
                            }
                          },
                          child: _buildHighlightableText(line, segments, page),
                        )
                      : _buildTextWithThickness(
                          line.text,
                          _getMaximizedFontSize(
                              line.lineType, isTablet, isLandscape, screenSize),
                          line.lineType == 'surah_name'
                              ? 'SurahNameFont'
                              : 'QPCPageFont$page'),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHighlightableText(
      SimpleMushafLine line, List<AyahSegment> segments, int page) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final isLandscape = screenSize.width > screenSize.height;
    final fontSize =
        _getMaximizedFontSize(line.lineType, isTablet, isLandscape, screenSize);

    // Create a list of text spans with highlighting
    List<InlineSpan> spans = [];

    for (final segment in segments) {
      final ayah = _findAyahForSegment(segment);
      if (ayah == null) continue;

      // Build word spans with highlighting
      for (final word in segment.words) {
        final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
        final isHighlighted = _highlightedWordId == wordId;
        final isUserSelected = _userSelectedWordId == wordId;

        spans.add(
          WidgetSpan(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  // Toggle selection
                  if (_userSelectedWordId == wordId) {
                    _userSelectedWordId = null;
                  } else {
                    _userSelectedWordId = wordId;
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                decoration: BoxDecoration(
                  color: isUserSelected
                      ? Colors.blue.withOpacity(0.3)
                      : isHighlighted
                          ? Colors.yellow.withOpacity(0.7)
                          : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  word.text,
                  style: TextStyle(
                    fontFamily: 'QPCPageFont$page',
                    fontSize: fontSize,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        );

        // Add space between words (except for the last word)
        if (word != segment.words.last) {
          spans.add(
            TextSpan(
              text: ' ',
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: fontSize,
              ),
            ),
          );
        }
      }

      // Add space between segments
      if (segment != segments.last) {
        spans.add(
          TextSpan(
            text: ' ',
            style: TextStyle(
              fontFamily: 'QPCPageFont$page',
              fontSize: fontSize,
            ),
          ),
        );
      }
    }


    return RichText(
      textAlign: TextAlign.right,
      textDirection: TextDirection.rtl,
      text: TextSpan(children: spans),
    );
  }

  PageAyah? _findAyahForSegment(AyahSegment segment) {
    final page = _allPagesData[_currentPage];
    if (page == null) return null;

    for (final ayah in page.ayahs) {
      if (ayah.segments.contains(segment)) {
        return ayah;
      }
    }
    return null;
  }

  Widget _buildTextWithThickness(
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color textColor = Colors.black}) {
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
