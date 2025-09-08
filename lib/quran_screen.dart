import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
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

    // If we're between segments, find the closest previous segment
    // This ensures smooth transitions between words
    AudioSegment? closestSegment;
    int smallestGap = 999999;

    for (final segment in _currentAudioData!.segments) {
      if (positionMs >= segment.startTimeMs) {
        final gap = positionMs - segment.endTimeMs;
        if (gap < smallestGap) {
          smallestGap = gap;
          closestSegment = segment;
        }
      }
    }

    // If we found a close segment (within 200ms), keep highlighting it
    if (closestSegment != null && smallestGap < 200) {
      final wordId =
          '${_currentAyah!.surah}:${_currentAyah!.ayah}:${closestSegment.wordIndex}';
      _highlightController.add(wordId);
    }
    // Otherwise, don't change the current highlight
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

      // Sort words by their original startIndex from the database
      lineWords.sort((a, b) => a.startIndex.compareTo(b.startIndex));

      final startIndex = lineWords.first.startIndex;
      final endIndex = lineWords.last.endIndex;
      final segmentText = lineWords.map((w) => w.text).join('');

      // Build AyahWord objects for this segment, preserving original order
      List<AyahWord> ayahWords = [];

      for (int j = 0; j < lineWords.length; j++) {
        final word = lineWords[j];

        ayahWords.add(AyahWord(
          text: word.text,
          wordIndex: globalWordIndex++,
          startIndex: word.startIndex, // Use original startIndex
          endIndex: word.endIndex, // Use original endIndex
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

  // Store all pages data with new model
  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};

  // Cache for uniform font sizes per page
  final Map<int, double> _uniformFontSizeCache = {};

  bool _isInitializing = true;
  bool _isPreloading = false;
  String _loadingMessage = 'Initializing...';
  double _preloadProgress = 0.0;

  // Audio service
  final AudioService _audioService = AudioService();
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;

  // Add this new variable for user selection
  String? _userSelectedAyahId; // Changed from _userSelectedWordId

  // Bottom bar state variables
  int _currentAyahIndex = 0;
  int? _highlightedAyahIndex;
  bool _isDragging = false;
  bool _isPlaying = false;
  bool _isLoading = false;

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
          _isLoading = state == AudioPlaybackState.loading;
          _isPlaying = state == AudioPlaybackState.playing;
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
          if (ayah != null) {
            // Update current ayah index based on playing ayah
            final ayahs = _getCurrentPageAyahs();
            for (int i = 0; i < ayahs.length; i++) {
              if (ayahs[i].surah == ayah.surah && ayahs[i].ayah == ayah.ayah) {
                _currentAyahIndex = i;
                _highlightedAyahIndex = i;
                break;
              }
            }
          }
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
      final fontData = await rootBundle.load('assets/quran/fonts/uth.ttf');
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

    // Reset bottom bar state for new page
    setState(() {
      _currentAyahIndex = 0;
      _highlightedAyahIndex = null;
      _isDragging = false;
    });
  }

  Future<void> _stopAudio() async {
    await _audioService.stop();
    setState(() {
      _highlightedWordId = null;
      _isPlaying = false;
      _isLoading = false;
      _currentAyahIndex = 0;
      _highlightedAyahIndex = null;
    });
  }

  // Helper method to get current page ayahs
  List<PageAyah> _getCurrentPageAyahs() {
    final page = _allPagesData[_currentPage];
    if (page == null) return [];

    // Filter out non-Quranic content and sort ayahs
    final ayahsToPlay =
        page.ayahs.where((ayah) => ayah.surah > 0 && ayah.ayah > 0).toList()
          ..sort((a, b) {
            if (a.surah != b.surah) return a.surah.compareTo(b.surah);
            return a.ayah.compareTo(b.ayah);
          });

    return ayahsToPlay;
  }

  // Progress bar change handler
  void _onProgressBarChanged(double value) {
    if (_isDragging) {
      final ayahs = _getCurrentPageAyahs();
      if (ayahs.isNotEmpty) {
        final newIndex = (value * (ayahs.length - 1)).round();
        setState(() {
          _currentAyahIndex = newIndex;
          _highlightedAyahIndex = newIndex;
        });
      }
    }
  }

  // Toggle play/pause for bottom bar
  Future<void> _togglePlayPause() async {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    setState(() {
      _isLoading = true;
    });

    if (_isPlaying) {
      await _audioService.pause();
      setState(() {
        _isPlaying = false;
        _isLoading = false;
      });
    } else {
      // Start playing from current ayah index
      final ayahsToPlay = ayahs.skip(_currentAyahIndex).toList();
      if (ayahsToPlay.isNotEmpty) {
        await _audioService.playPageAyahs(ayahsToPlay);
        setState(() {
          _isPlaying = true;
          _isLoading = false;
        });
      }
    }
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
                // Main content area
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
                // Audio Bottom Bar
                _buildAudioBottomBar(isTablet),
              ],
            ),
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
                color: ayahs.isNotEmpty ? const Color(0xFF8B7355) : Colors.grey,
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
                value: ayahs.isEmpty
                    ? 0.0
                    : (_currentAyahIndex /
                        (ayahs.length - 1).clamp(1, double.infinity)),
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
                      border: Border.all(
                          color: const Color(0xFFD2B48C), width: 0.5),
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
                      border: Border.all(
                          color: const Color(0xFFD2B48C), width: 0.5),
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
    final appBarHeight = isTablet ? 70.0 : 56.0;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomBarHeight = isTablet ? 100.0 : 80.0;
    final availableHeight =
        screenSize.height - appBarHeight - statusBarHeight - bottomBarHeight;

    return Container(
      width: double.infinity,
      height: availableHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
      ),
      padding: EdgeInsets.all(isTablet ? 16.0 : 12.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Compute a uniform font size for this page so all lines share the same size
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
                ? MainAxisAlignment.center // Center content for pages 1-2
                : MainAxisAlignment
                    .spaceEvenly, // Distribute evenly for other pages
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

    // For pages 1-2, use natural height instead of stretching
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

            // Check if this line has ayah segments for word highlighting
            final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];

            // Special formatting for different line types and pages
            return _buildLineWithSpecialFormatting(line, segments, page,
                mushafPage, isTablet, isLandscape, screenSize);
          },
        ),
      );
    }

    // For regular pages, use expanded to fill height
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

            // Special formatting for different line types and pages
            return _buildLineWithSpecialFormatting(line, segments, page,
                mushafPage, isTablet, isLandscape, screenSize);
          },
        ),
      ),
    );
  }

  Widget _buildLineWithSpecialFormatting(
      SimpleMushafLine line,
      List<AyahSegment> segments,
      int page,
      MushafPage mushafPage,
      bool isTablet,
      bool isLandscape,
      Size screenSize) {
    final double? uniformFontSize = _uniformFontSizeCache[page];
    // Special formatting for basmallah lines - scale uniformly to fit width
    if (line.lineType == 'basmallah') {
      return Container(
        width: double.infinity,
        child: (uniformFontSize != null)
            ? _buildTextWithThicknessFixedSize(
                line.text, uniformFontSize, 'QPCPageFont$page', page)
            : _buildTextWithThickness(
                line.text,
                _getMaximizedFontSize(
                    line.lineType, isTablet, isLandscape, screenSize),
                'QPCPageFont$page',
              ),
      );
    }

    // If we have a uniform size for the page, use fixed-size rendering
    if (uniformFontSize != null) {
      return Container(
        width: double.infinity,
        child: segments.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  // Handle line tap - highlight the first ayah in the line
                  if (segments.isNotEmpty) {
                    final firstSegment = segments.first;
                    final ayah = _findAyahForSegment(firstSegment);
                    if (ayah != null) {
                      setState(() {
                        _userSelectedAyahId = '${ayah.surah}:${ayah.ayah}';
                      });
                    }
                  }
                },
                child: _buildHighlightableTextFixedSize(
                    line, segments, page, uniformFontSize),
              )
            : _buildTextWithThicknessFixedSize(
                line.text, uniformFontSize, 'QPCPageFont$page', page),
      );
    }

    // Default formatting for regular pages - stretch to full width
    return Container(
      width: double.infinity,
      child: segments.isNotEmpty
          ? GestureDetector(
              onTap: () {
                // Handle line tap - highlight the first ayah in the line
                if (segments.isNotEmpty) {
                  final firstSegment = segments.first;
                  final ayah = _findAyahForSegment(firstSegment);
                  if (ayah != null) {
                    setState(() {
                      _userSelectedAyahId = '${ayah.surah}:${ayah.ayah}';
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
              'QPCPageFont$page'),
    );
  }

  Widget _buildHighlightableText(
      SimpleMushafLine line, List<AyahSegment> segments, int page) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final isLandscape = screenSize.width > screenSize.height;
    final fontSize =
        _getMaximizedFontSize(line.lineType, isTablet, isLandscape, screenSize);

    // Sort segments by their line number and position in the line
    segments.sort((a, b) {
      if (a.lineNumber != b.lineNumber) {
        return a.lineNumber.compareTo(b.lineNumber);
      }
      return a.startIndex.compareTo(b.startIndex);
    });

    // Group segments by ayah for continuous highlighting
    Map<String, List<AyahSegment>> segmentsByAyah = {};
    for (final segment in segments) {
      final ayah = _findAyahForSegment(segment);
      if (ayah != null) {
        final ayahId = '${ayah.surah}:${ayah.ayah}';
        segmentsByAyah.putIfAbsent(ayahId, () => []).add(segment);
      }
    }

    // Create a list of text spans with highlighting
    List<InlineSpan> spans = [];

    // Process ayahs to create continuous highlighting
    for (final entry in segmentsByAyah.entries) {
      final ayahId = entry.key;
      final ayahSegments = entry.value;

      // Sort segments by line number and position
      ayahSegments.sort((a, b) {
        if (a.lineNumber != b.lineNumber) {
          return a.lineNumber.compareTo(b.lineNumber);
        }
        return a.startIndex.compareTo(b.startIndex);
      });

      final isUserSelected = _userSelectedAyahId == ayahId;

      // Create a single container for the entire ayah
      List<InlineSpan> ayahSpans = [];

      for (final segment in ayahSegments) {
        final ayah = _findAyahForSegment(segment);
        if (ayah == null) continue;

        // Words are already sorted by startIndex in _buildAyah, so use them as-is
        final sortedWords = segment.words;

        // Build word spans for this segment
        for (int i = 0; i < sortedWords.length; i++) {
          final word = sortedWords[i];
          final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
          final isAudioHighlighted = _highlightedWordId == wordId;

          ayahSpans.add(
            TextSpan(
              text: word.text,
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: fontSize,
                color: Colors.black,
                backgroundColor:
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.7) : null,
              ),
            ),
          );

          // Add thin space between words (except after the last word)
          if (i < sortedWords.length - 1) {
            ayahSpans.add(
              TextSpan(
                text: '\u200A',
                style: TextStyle(
                  fontFamily: 'QPCPageFont$page',
                  fontSize: fontSize,
                  color: Colors.black,
                ),
              ),
            );
          }
        }
      }

      // Wrap the entire ayah in a single highlightable container
      spans.add(
        WidgetSpan(
          child: GestureDetector(
            onTap: () {
              setState(() {
                // Toggle ayah selection
                if (_userSelectedAyahId == ayahId) {
                  _userSelectedAyahId = null;
                } else {
                  _userSelectedAyahId = ayahId;
                }
              });

              // Position audio to this ayah
              _seekToAyahFromId(ayahId);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
              decoration: BoxDecoration(
                color: isUserSelected ? Colors.blue.withOpacity(0.3) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: RichText(
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                  text: TextSpan(children: ayahSpans),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Reverse the spans to display right-to-left
    spans = spans.reversed.toList();

    return Container(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: RichText(
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          text: TextSpan(children: spans),
        ),
      ),
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

  void _seekToAyahFromId(String ayahId) {
    final parts = ayahId.split(':');
    if (parts.length != 2) return;

    final surahNumber = int.tryParse(parts[0]);
    final ayahNumber = int.tryParse(parts[1]);

    if (surahNumber == null || ayahNumber == null) return;

    final ayahs = _getCurrentPageAyahs();
    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == surahNumber && ayahs[i].ayah == ayahNumber) {
        setState(() {
          _currentAyahIndex = i;
          _highlightedAyahIndex = i;
        });
        break;
      }
    }
  }

  Widget _buildTextWithThickness(
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color textColor = Colors.black}) {
    Widget textWidget = Container(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: textColor,
          ),
        ),
      ),
    );

    if (backgroundColor != null) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: textWidget,
      );
    }

    return textWidget;
  }

  Widget _buildTextWithThicknessFixedSize(
      String text, double fontSize, String fontFamily, int page,
      {Color? backgroundColor, Color textColor = Colors.black}) {
    Widget textWidget = Container(
      width: double.infinity,
      child: FittedBox(
        fit: page >= 3 ? BoxFit.fitWidth : BoxFit.scaleDown,
        child: Text(
          text,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: textColor,
          ),
        ),
      ),
    );

    if (backgroundColor != null) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: textWidget,
      );
    }

    return textWidget;
  }

  Widget _buildTextWithThicknessNoStretch(
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color textColor = Colors.black}) {
    Widget textWidget = Text(
      text,
      textAlign: TextAlign.center,
      textDirection: TextDirection.rtl,
      maxLines: 1,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: textColor,
      ),
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

  Widget _buildHighlightableTextNoStretch(SimpleMushafLine line,
      List<AyahSegment> segments, int page, double uniformFontSize) {
    // Sort segments by their line number and position in the line
    segments.sort((a, b) {
      if (a.lineNumber != b.lineNumber) {
        return a.lineNumber.compareTo(b.lineNumber);
      }
      return a.startIndex.compareTo(b.startIndex);
    });

    // Group segments by ayah for continuous highlighting
    Map<String, List<AyahSegment>> segmentsByAyah = {};
    for (final segment in segments) {
      final ayah = _findAyahForSegment(segment);
      if (ayah != null) {
        final ayahId = '${ayah.surah}:${ayah.ayah}';
        segmentsByAyah.putIfAbsent(ayahId, () => []).add(segment);
      }
    }

    // Create a list of text spans with highlighting
    List<InlineSpan> spans = [];

    // Process ayahs to create continuous highlighting
    for (final entry in segmentsByAyah.entries) {
      final ayahId = entry.key;
      final ayahSegments = entry.value;

      // Sort segments by line number and position
      ayahSegments.sort((a, b) {
        if (a.lineNumber != b.lineNumber) {
          return a.lineNumber.compareTo(b.lineNumber);
        }
        return a.startIndex.compareTo(b.startIndex);
      });

      final isUserSelected = _userSelectedAyahId == ayahId;

      // Create a single container for the entire ayah
      List<InlineSpan> ayahSpans = [];

      for (final segment in ayahSegments) {
        final ayah = _findAyahForSegment(segment);
        if (ayah == null) continue;

        // Words are already sorted by startIndex in _buildAyah, so use them as-is
        final sortedWords = segment.words;

        // Build word spans for this segment
        for (final word in sortedWords) {
          final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
          final isAudioHighlighted = _highlightedWordId == wordId;

          ayahSpans.add(
            TextSpan(
              text: word.text,
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: uniformFontSize,
                color: Colors.black,
                backgroundColor:
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.7) : null,
              ),
            ),
          );
        }
      }

      // Wrap the entire ayah in a single highlightable container
      spans.add(
        WidgetSpan(
          child: GestureDetector(
            onTap: () {
              setState(() {
                // Toggle ayah selection
                if (_userSelectedAyahId == ayahId) {
                  _userSelectedAyahId = null;
                } else {
                  _userSelectedAyahId = ayahId;
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: isUserSelected ? Colors.blue.withOpacity(0.3) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: RichText(
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                text: TextSpan(children: ayahSpans),
              ),
            ),
          ),
        ),
      );
    }

    // Reverse the spans to display right-to-left
    spans = spans.reversed.toList();

    return RichText(
      textAlign: TextAlign.center,
      textDirection: TextDirection.rtl,
      text: TextSpan(children: spans),
    );
  }

  Widget _buildHighlightableTextFixedSize(SimpleMushafLine line,
      List<AyahSegment> segments, int page, double fontSize) {
    // Sort segments
    segments.sort((a, b) {
      if (a.lineNumber != b.lineNumber) {
        return a.lineNumber.compareTo(b.lineNumber);
      }
      return a.startIndex.compareTo(b.startIndex);
    });

    Map<String, List<AyahSegment>> segmentsByAyah = {};
    for (final segment in segments) {
      final ayah = _findAyahForSegment(segment);
      if (ayah != null) {
        final ayahId = '${ayah.surah}:${ayah.ayah}';
        segmentsByAyah.putIfAbsent(ayahId, () => []).add(segment);
      }
    }

    List<InlineSpan> spans = [];

    for (final entry in segmentsByAyah.entries) {
      final ayahId = entry.key;
      final ayahSegments = entry.value;

      ayahSegments.sort((a, b) {
        if (a.lineNumber != b.lineNumber) {
          return a.lineNumber.compareTo(b.lineNumber);
        }
        return a.startIndex.compareTo(b.startIndex);
      });

      final isUserSelected = _userSelectedAyahId == ayahId;

      List<InlineSpan> ayahSpans = [];
      for (final segment in ayahSegments) {
        final ayah = _findAyahForSegment(segment);
        if (ayah == null) continue;
        final sortedWords = segment.words;
        for (int i = 0; i < sortedWords.length; i++) {
          final word = sortedWords[i];
          final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
          final isAudioHighlighted = _highlightedWordId == wordId;
          ayahSpans.add(
            TextSpan(
              text: word.text,
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: fontSize,
                color: Colors.black,
                backgroundColor:
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.7) : null,
              ),
            ),
          );

          // Add thin space between words (except after the last word)
          if (i < sortedWords.length - 1) {
            ayahSpans.add(
              TextSpan(
                text: '\u200A',
                style: TextStyle(
                  fontFamily: 'QPCPageFont$page',
                  fontSize: fontSize,
                  color: Colors.black,
                ),
              ),
            );
          }
        }
      }

      spans.add(
        WidgetSpan(
          child: GestureDetector(
            onTap: () {
              setState(() {
                if (_userSelectedAyahId == ayahId) {
                  _userSelectedAyahId = null;
                } else {
                  _userSelectedAyahId = ayahId;
                }
              });

              // Position audio to this ayah
              _seekToAyahFromId(ayahId);
            },
            child: Container(
              decoration: BoxDecoration(
                color: isUserSelected ? Colors.blue.withOpacity(0.3) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: RichText(
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                text: TextSpan(children: ayahSpans),
              ),
            ),
          ),
        ),
      );
    }

    spans = spans.reversed.toList();

    return Container(
      width: double.infinity,
      child: FittedBox(
        fit: page >= 3 ? BoxFit.fitWidth : BoxFit.scaleDown,
        child: RichText(
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          text: TextSpan(children: spans),
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
    // Binary search between reasonable bounds for the largest size that fits all lines
    double low = 8.0;
    double high = 300.0;

    // Start near the heuristic size to speed convergence
    final heuristic =
        _getMaximizedFontSize('ayah', isTablet, isLandscape, screenSize);
    if (heuristic > low && heuristic < high) {
      high = heuristic * 1.5;
    }

    final String fontFamily = 'QPCPageFont$page';

    bool fitsAll(double size) {
      final double targetWidth = maxWidth - 8.0; // small margin
      for (final line in mushafPage.lines) {
        // Only measure text-based lines shown with this font
        if (line.lineType == 'surah_name') continue;
        final String text = line.text;
        if (text.isEmpty) continue;

        // For lines with ayah segments, we need to account for thin spaces between words
        String textToMeasure = text;
        if (line.lineType == 'ayah' || line.lineType == 'basmallah') {
          // Get the segments for this line to count words
          final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
          if (segments.isNotEmpty) {
            // Count total words across all segments for this line
            int totalWords = 0;
            for (final segment in segments) {
              totalWords += segment.words.length;
            }
            // Add hair spaces between words (totalWords - 1 spaces)
            if (totalWords > 1) {
              textToMeasure = text + '\u200A' * (totalWords - 1);
            }
          }
        }

        final painter = TextPainter(
          textDirection: TextDirection.rtl,
          textAlign: TextAlign.center,
          maxLines: 1,
          text: TextSpan(
            text: textToMeasure,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: size,
            ),
          ),
        );
        painter.layout(minWidth: 0, maxWidth: double.infinity);
        if (painter.size.width > targetWidth) {
          return false;
        }
      }
      return true;
    }

    for (int i = 0; i < 18; i++) {
      final mid = (low + high) / 2.0;
      if (fitsAll(mid)) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return low;
  }

  double _getMaximizedFontSize(
      String lineType, bool isTablet, bool isLandscape, Size screenSize) {
    final screenMultiplier =
        isTablet ? (isLandscape ? 1.8 : 1.5) : (isLandscape ? 1.3 : 1.0);
    final widthMultiplier = (screenSize.width / 400).clamp(0.8, 2.5);

    // Base font size
    double baseFontSize = 20.0 * screenMultiplier * widthMultiplier;

    // Adjust font size based on line type
    switch (lineType) {
      case 'basmallah':
        return baseFontSize * 1.3; // Larger for basmallah
      case 'surah_name':
        return baseFontSize * 1.1; // Slightly larger for surah names
      case 'ayah':
      default:
        return baseFontSize; // Normal size for ayah text
    }
  }
}
