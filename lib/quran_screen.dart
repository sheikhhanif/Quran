import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'surah_header_banner.dart';

// ===================== MODELS =====================

// Surah Model
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

// ===================== SURAH SERVICE =====================

class SurahService {
  static final SurahService _instance = SurahService._internal();
  factory SurahService() => _instance;
  SurahService._internal();

  List<Surah>? _surahs;
  Map<int, int>? _surahToPageMap; // Maps surah ID to starting page

  Future<void> initialize() async {
    await _loadSurahMetadata();
  }

  Future<void> buildSurahToPageMap(Map<int, MushafPage> allPagesData) async {
    if (_surahs == null) return;

    print('Building surah mapping with ${allPagesData.length} pages...');
    _surahToPageMap = _buildSurahToPageMapping(allPagesData);

    // Debug: Print some sample mappings
    if (_surahToPageMap != null && _surahToPageMap!.isNotEmpty) {
      print('Sample surah mappings:');
      final sortedEntries = _surahToPageMap!.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));

      for (int i = 0; i < min(10, sortedEntries.length); i++) {
        final entry = sortedEntries[i];
        final surah = getSurahById(entry.key);
        print(
            '  Surah ${entry.key} (${surah?.nameSimple}) starts on page ${entry.value}');
      }
    } else {
      print('ERROR: Surah mapping is empty or null!');
    }
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

      // Sort by surah ID
      _surahs!.sort((a, b) => a.id.compareTo(b.id));
    } catch (e) {
      print('Error loading surah metadata: $e');
    }
  }

  // Add this method to find surah start pages
  Map<int, int> _buildSurahToPageMapping(Map<int, MushafPage> allPagesData) {
    final surahToPage = <int, int>{};
    final surahFirstAyah =
    <int, int>{}; // Track the lowest ayah number for each surah

    print('Building mapping with ${allPagesData.length} pages available');

    for (int page = 1; page <= 604; page++) {
      final pageData = allPagesData[page];
      if (pageData != null) {
        // Debug: Print ayah info for first few pages
        if (page <= 5) {
          print(
              'Page $page ayahs: ${pageData.ayahs.map((a) => '${a.surah}:${a.ayah}').join(', ')}');
        }

        // Find the first occurrence of each surah (ayah number 1)
        for (final ayah in pageData.ayahs) {
          final surahId = ayah.surah;
          final ayahNumber = ayah.ayah;

          // Only consider ayah number 1 as the start of a surah
          if (ayahNumber == 1 && !surahToPage.containsKey(surahId)) {
            surahToPage[surahId] = page;
            surahFirstAyah[surahId] = ayahNumber;
            print(
                '  Found surah $surahId starting on page $page (ayah $ayahNumber)');
          }
        }
      } else {
        if (page <= 10) {
          print('Page $page has no data');
        }
      }
    }

    print('Surah mapping built: ${surahToPage.length} surahs mapped');

    // Debug: Print some sample mappings
    final sortedEntries = surahToPage.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    for (int i = 0; i < min(10, sortedEntries.length); i++) {
      final entry = sortedEntries[i];
      final surah = getSurahById(entry.key);
      print(
          '  Surah ${entry.key} (${surah?.nameSimple}) starts on page ${entry.value} (first ayah: ${surahFirstAyah[entry.key]})');
    }

    return surahToPage;
  }

  List<Surah>? get surahs => _surahs;
  Map<int, int>? get surahToPageMap => _surahToPageMap;

  int? getSurahStartPage(int surahId) {
    final page = _surahToPageMap?[surahId];
    print('getSurahStartPage($surahId) = $page');
    if (_surahToPageMap != null) {
      print('Available surahs in mapping: ${_surahToPageMap!.keys.toList()}');
    } else {
      print('Surah mapping is null!');
    }
    return page;
  }

  Surah? getSurahById(int surahId) {
    return _surahs?.firstWhere((surah) => surah.id == surahId);
  }
}

// ===================== AUDIO SERVICE =====================

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioCacheService _cacheService = AudioCacheService();
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
  String? _lastHighlightedWordId;

  Future<void> initialize() async {
    await _loadAudioData();
    await _cacheService.initialize();

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

      // Reset highlighting state for new ayah
      _lastHighlightedWordId = null;
      _highlightController.add(null);

      // Check if audio is cached first
      String audioPath;
      try {
        audioPath =
        await _cacheService.downloadAndCacheAudio(audioData.audioUrl);
        await _audioPlayer.play(DeviceFileSource(audioPath));
      } catch (cacheError) {
        print('Cache error, falling back to URL: $cacheError');
        // Fallback to URL if cache fails
        await _audioPlayer.play(UrlSource(audioData.audioUrl));
      }
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

  Future<void> seekToAyah(int ayahIndex) async {
    if (_pageAyahs == null ||
        ayahIndex < 0 ||
        ayahIndex >= _pageAyahs!.length) {
      return;
    }

    _currentAyahIndex = ayahIndex;
    await _playCurrentAyah();
  }

  Future<int> getCacheSize() async {
    return await _cacheService.getCacheSize();
  }

  Future<void> clearCache() async {
    await _cacheService.clearCache();
  }

  void _updateWordHighlight(Duration position) {
    if (_currentAudioData == null || _currentAyah == null) return;

    final positionMs = position.inMilliseconds;

    // Find the current segment being played
    AudioSegment? currentSegment;
    for (final segment in _currentAudioData!.segments) {
      if (positionMs >= segment.startTimeMs && positionMs < segment.endTimeMs) {
        currentSegment = segment;
        break;
      }
    }

    String? newWordId;

    // If we found a current segment, highlight it
    if (currentSegment != null) {
      // Use the word index from the segment directly
      // This correctly handles backward repetition because the wordIndex reflects which word is actually being recited
      final wordIndex = currentSegment.wordIndex;

      // Get all words from the current ayah
      final ayahWords = _getAyahWords(_currentAyah!);

      // Map the word index to the actual word in the ayah
      // Use the audio wordIndex directly - the UI should follow what the audio says
      if (wordIndex > 0 && wordIndex <= ayahWords.length) {
        newWordId = '${_currentAyah!.surah}:${_currentAyah!.ayah}:$wordIndex';

        // Debug output to verify the mapping
        print('Audio wordIndex: $wordIndex -> UI word: $wordIndex');
      } else if (ayahWords.isNotEmpty) {
        // Fallback: clamp to valid range
        final fallbackWordIndex = wordIndex.clamp(1, ayahWords.length);
        newWordId =
        '${_currentAyah!.surah}:${_currentAyah!.ayah}:$fallbackWordIndex';
        print(
            'Fallback: Audio wordIndex: $wordIndex -> UI word: $fallbackWordIndex');
      }
    } else {
      // If we're between segments, find the most appropriate segment to highlight
      // This handles both forward and backward movement properly
      AudioSegment? bestSegment;
      int minTimeDiff = 500; // Maximum time difference to consider

      // Find the closest segment (either before or after current position)
      for (final segment in _currentAudioData!.segments) {
        int timeDiff;

        if (positionMs < segment.startTimeMs) {
          // Position is before this segment
          timeDiff = segment.startTimeMs - positionMs;
        } else if (positionMs > segment.endTimeMs) {
          // Position is after this segment
          timeDiff = positionMs - segment.endTimeMs;
        } else {
          // This shouldn't happen since we're in the "else" branch
          continue;
        }

        // If this segment is closer than the current best, use it
        if (timeDiff < minTimeDiff) {
          minTimeDiff = timeDiff;
          bestSegment = segment;
        }
      }

      // Highlight the closest segment if found
      if (bestSegment != null) {
        // Apply the same mapping logic as above - use audio wordIndex directly
        final ayahWords = _getAyahWords(_currentAyah!);
        final wordIndex = bestSegment.wordIndex;
        if (wordIndex > 0 && wordIndex <= ayahWords.length) {
          newWordId = '${_currentAyah!.surah}:${_currentAyah!.ayah}:$wordIndex';
        } else if (ayahWords.isNotEmpty) {
          // Fallback: clamp to valid range
          final fallbackWordIndex = wordIndex.clamp(1, ayahWords.length);
          newWordId =
          '${_currentAyah!.surah}:${_currentAyah!.ayah}:$fallbackWordIndex';
        }
      }
    }

    // Update highlight if it's different from the last one
    // For better responsiveness to seeking/scrubbing, we don't throttle updates
    if (newWordId != null && newWordId != _lastHighlightedWordId) {
      _highlightController.add(newWordId);
      _lastHighlightedWordId = newWordId;
    } else if (newWordId == null && _lastHighlightedWordId != null) {
      // Clear highlight if no segment should be highlighted
      _highlightController.add(null);
      _lastHighlightedWordId = null;
    }
  }

  // Helper method to get all words from an ayah in order
  List<AyahWord> _getAyahWords(PageAyah ayah) {
    List<AyahWord> allWords = [];
    for (final segment in ayah.segments) {
      allWords.addAll(segment.words);
    }
    // Sort by wordIndex to ensure proper order
    allWords.sort((a, b) => a.wordIndex.compareTo(b.wordIndex));
    return allWords;
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

// ===================== AUDIO CACHE SERVICE =====================

class AudioCacheService {
  static final AudioCacheService _instance = AudioCacheService._internal();
  factory AudioCacheService() => _instance;
  AudioCacheService._internal();

  static Directory? _cacheDirectory;
  static const String _audioCacheFolder = 'audio_cache';
  static const int _maxCacheSize = 100; // Maximum number of cached files

  Future<void> initialize() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory(p.join(appDir.path, _audioCacheFolder));
    await _cacheDirectory!.create(recursive: true);
  }

  Future<String?> getCachedAudioPath(String audioUrl) async {
    if (_cacheDirectory == null) await initialize();

    final fileName = _getFileNameFromUrl(audioUrl);
    final filePath = p.join(_cacheDirectory!.path, fileName);
    final file = File(filePath);

    if (await file.exists()) {
      return filePath;
    }
    return null;
  }

  Future<String> downloadAndCacheAudio(String audioUrl) async {
    if (_cacheDirectory == null) await initialize();

    final fileName = _getFileNameFromUrl(audioUrl);
    final filePath = p.join(_cacheDirectory!.path, fileName);
    final file = File(filePath);

    // Check if already cached
    if (await file.exists()) {
      return filePath;
    }

    try {
      // Download the audio file
      final response = await http.get(Uri.parse(audioUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);

        // Clean up old cache files if needed
        await _cleanupOldCache();

        return filePath;
      } else {
        throw Exception('Failed to download audio: ${response.statusCode}');
      }
    } catch (e) {
      print('Error downloading audio: $e');
      rethrow;
    }
  }

  String _getFileNameFromUrl(String url) {
    // Extract a safe filename from the URL
    final uri = Uri.parse(url);
    final pathSegments = uri.pathSegments;
    final fileName = pathSegments.isNotEmpty ? pathSegments.last : 'audio.mp3';

    // Ensure the filename has an extension
    if (!fileName.contains('.')) {
      return '$fileName.mp3';
    }

    return fileName;
  }

  Future<void> _cleanupOldCache() async {
    if (_cacheDirectory == null) return;

    try {
      final files = await _cacheDirectory!.list().toList();
      final fileInfos = <FileSystemEntity>[];

      for (final file in files) {
        if (file is File) {
          fileInfos.add(file);
        }
      }

      // Sort by modification time (oldest first)
      fileInfos.sort((a, b) {
        final aStat = a.statSync();
        final bStat = b.statSync();
        return aStat.modified.compareTo(bStat.modified);
      });

      // Remove oldest files if we exceed the cache limit
      if (fileInfos.length > _maxCacheSize) {
        final filesToDelete = fileInfos.take(fileInfos.length - _maxCacheSize);
        for (final file in filesToDelete) {
          await file.delete();
        }
      }
    } catch (e) {
      print('Error cleaning up cache: $e');
    }
  }

  Future<void> clearCache() async {
    if (_cacheDirectory == null) return;

    try {
      if (await _cacheDirectory!.exists()) {
        await _cacheDirectory!.delete(recursive: true);
        await _cacheDirectory!.create(recursive: true);
      }
    } catch (e) {
      print('Error clearing cache: $e');
    }
  }

  Future<int> getCacheSize() async {
    if (_cacheDirectory == null) return 0;

    try {
      final files = await _cacheDirectory!.list().toList();
      int totalSize = 0;

      for (final file in files) {
        if (file is File) {
          totalSize += await file.length();
        }
      }

      return totalSize;
    } catch (e) {
      print('Error getting cache size: $e');
      return 0;
    }
  }
}

// ===================== OPTIMIZED DATABASE SERVICE =====================

class OptimizedDatabaseService {
  static Database? _wordsDb;
  static Database? _layoutDb;
  static bool _isInitialized = false;

  // Connection pooling simulation with singleton pattern
  static Future<void> initialize() async {
    if (_isInitialized) return;

    final databasesPath = await getDatabasesPath();

    // Open databases with optimized settings
    _wordsDb = await openDatabase(
      p.join(databasesPath, 'qpc-v2.db'),
      version: 1,
      onCreate: (db, version) async {
        // Create indexes for better performance
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

  static Database get wordsDb {
    if (_wordsDb == null) throw Exception('Database not initialized');
    return _wordsDb!;
  }

  static Database get layoutDb {
    if (_layoutDb == null) throw Exception('Database not initialized');
    return _layoutDb!;
  }

  static Future<void> close() async {
    await _wordsDb?.close();
    await _layoutDb?.close();
    _isInitialized = false;
  }
}

// ===================== OPTIMIZED PAGE BUILDER =====================

class MushafPageBuilder {
  // Cache for frequently accessed data
  static final Map<int, List<Map<String, dynamic>>> _layoutCache = {};
  static final Map<String, List<Map<String, dynamic>>> _wordsCache = {};
  static const int MAX_CACHE_SIZE =
  604; // Cache ALL pages in memory like Quran.com/Tarteel

  static Future<MushafPage> buildPage({
    required int pageNumber,
    required Database wordsDb,
    required Database layoutDb,
  }) async {
    final stopwatch = Stopwatch()..start();

    // Get layout data (cached)
    final layoutData = await _getLayoutData(pageNumber, layoutDb);

    if (layoutData.isEmpty) {
      return MushafPage(
        pageNumber: pageNumber,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
    }

    // Get all words for the page in a single optimized query
    final allWords = await _getAllWordsForPage(pageNumber, layoutData, wordsDb);

    // Group words by line for efficient lookup
    final wordsByLine = _groupWordsByLine(allWords, layoutData);

    // Build lines and ayahs in parallel
    final result =
    await _buildPageFromData(pageNumber, layoutData, wordsByLine);

    stopwatch.stop();
    PerformanceMonitor.logPerformance(
        'buildPage_$pageNumber', stopwatch.elapsed);

    return result;
  }

  static Future<List<Map<String, dynamic>>> _getLayoutData(
      int pageNumber, Database layoutDb) async {
    // Check cache first
    if (_layoutCache.containsKey(pageNumber)) {
      return _layoutCache[pageNumber]!;
    }

    final layoutData = await layoutDb.rawQuery(
        "SELECT * FROM pages WHERE page_number = ? ORDER BY line_number ASC",
        [pageNumber]);

    // Cache the result
    if (_layoutCache.length >= MAX_CACHE_SIZE) {
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
    // Collect all word ID ranges
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

    // Create cache key for this page's word ranges
    final cacheKey =
        '${pageNumber}_${wordRanges.map((r) => '${r['first']}-${r['last']}').join('_')}';

    // Check cache first
    if (_wordsCache.containsKey(cacheKey)) {
      return _wordsCache[cacheKey]!;
    }

    // Build optimized query with multiple ranges
    final conditions = wordRanges
        .map((range) => "(id >= ${range['first']} AND id <= ${range['last']})")
        .join(' OR ');

    final query = "SELECT * FROM words WHERE $conditions ORDER BY id ASC";
    final allWords = await wordsDb.rawQuery(query);

    // Cache the result
    if (_wordsCache.length >= MAX_CACHE_SIZE) {
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

    // Create a map of word ID ranges to line numbers
    final lineRanges = <int, Map<String, int>>{};
    for (var lineData in layoutData) {
      final lineNumber = _safeParseIntRequired(lineData['line_number']);
      final firstWordId = _safeParseInt(lineData['first_word_id']);
      final lastWordId = _safeParseInt(lineData['last_word_id']);

      if (firstWordId != null && lastWordId != null) {
        lineRanges[lineNumber] = {
          'first': firstWordId,
          'last': lastWordId,
        };
      }
    }

    // Group words by line
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
    Map<String, List<AyahWordData>> ayahWords = {};

    // Process all lines in parallel
    final lineFutures = layoutData.map((lineData) => _buildLineFromData(
        lineData, wordsByLine[lineData['line_number']] ?? []));

    final lineResults = await Future.wait(lineFutures);

    // Collect results
    for (var lineResult in lineResults) {
      lines.add(lineResult.simpleLine);

      // Collect ayah words for this line
      for (var ayahWord in lineResult.ayahWords) {
        final key = "${ayahWord.surah}:${ayahWord.ayah}";
        ayahWords.putIfAbsent(key, () => []).add(ayahWord);
      }
    }

    // Build complete ayahs from collected words
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

      // Map segments to lines
      for (var segment in ayah.segments) {
        lineToSegments.putIfAbsent(segment.lineNumber, () => []).add(segment);
      }

      return ayah;
    });

    ayahs = await Future.wait(ayahFutures);

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
    List<AyahWordData> ayahWords = [];

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
          final result = _buildWordsFromData(words, lineNumber);
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

  static _WordsResult _buildWordsFromData(
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
        // Handle words without ayah info
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
    // Sort all words by line number first, then by startIndex to ensure proper order
    words.sort((a, b) {
      if (a.lineNumber != b.lineNumber) {
        return a.lineNumber.compareTo(b.lineNumber);
      }
      return a.startIndex.compareTo(b.startIndex);
    });

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

      // Words are already sorted by startIndex from the initial sort
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

// ===================== OPTIMIZED FONT SERVICE =====================

class OptimizedFontService {
  static final Set<int> _loadedFonts = <int>{};
  static bool _surahNameFontLoaded = false;
  static const int FONT_PRELOAD_RADIUS =
  604; // Preload ALL fonts like Quran.com/Tarteel

  static Future<void> preloadFontsAroundPage(int pageNumber) async {
    final fontsToLoad = <int>{};

    for (int i = -FONT_PRELOAD_RADIUS; i <= FONT_PRELOAD_RADIUS; i++) {
      final page = pageNumber + i;
      if (page >= 1 && page <= 604 && !_loadedFonts.contains(page)) {
        fontsToLoad.add(page);
      }
    }

    // Load fonts in parallel
    final fontFutures = fontsToLoad.map((page) => _loadFontForPage(page));
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
      // Font loading failed - continue silently
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
      // Font loading failed - continue silently
    }
  }

  // Preload ALL fonts at startup like Quran.com/Tarteel
  static Future<void> preloadAllFonts() async {
    final fontFutures = <Future<void>>[];

    // Load all 604 page fonts in parallel
    for (int page = 1; page <= 604; page++) {
      if (!_loadedFonts.contains(page)) {
        fontFutures.add(_loadFontForPage(page));
      }
    }

    // Load all fonts in parallel for maximum speed
    await Future.wait(fontFutures);
    print('All 604 fonts preloaded successfully!');
  }

  static bool isFontLoaded(int page) => _loadedFonts.contains(page);
  static bool isSurahNameFontLoaded() => _surahNameFontLoaded;
}

// ===================== OPTIMIZED PAGE CACHE =====================

class OptimizedPageCache {
  static final Map<int, MushafPage> _pageCache = {};
  static const int MAX_CACHE_SIZE =
  604; // Cache ALL pages in memory like Quran.com/Tarteel
  static final List<int> _accessOrder = [];

  static MushafPage? getPage(int pageNumber) {
    if (_pageCache.containsKey(pageNumber)) {
      // Update access order for LRU
      _accessOrder.remove(pageNumber);
      _accessOrder.add(pageNumber);
      return _pageCache[pageNumber];
    }
    return null;
  }

  static void cachePage(int pageNumber, MushafPage page) {
    if (_pageCache.length >= MAX_CACHE_SIZE) {
      // Remove least recently used page
      final oldestKey = _accessOrder.removeAt(0);
      _pageCache.remove(oldestKey);
    }

    _pageCache[pageNumber] = page;
    _accessOrder.add(pageNumber);
  }

  static void clearCache() {
    _pageCache.clear();
    _accessOrder.clear();
  }

  static int get cacheSize => _pageCache.length;
}

// ===================== PERFORMANCE MONITORING =====================

class PerformanceMonitor {
  static final Map<String, List<Duration>> _metrics = {};
  static const int MAX_METRICS_PER_OPERATION = 100;

  static void startTimer(String operation) {
    _metrics[operation] ??= [];
  }

  static void endTimer(String operation, Duration duration) {
    final metrics = _metrics[operation];
    if (metrics != null) {
      metrics.add(duration);
      // Keep only recent metrics to prevent memory bloat
      if (metrics.length > MAX_METRICS_PER_OPERATION) {
        metrics.removeAt(0);
      }
    }
  }

  static Duration? getAverageTime(String operation) {
    final metrics = _metrics[operation];
    if (metrics == null || metrics.isEmpty) return null;

    final totalMs =
    metrics.fold<int>(0, (sum, duration) => sum + duration.inMilliseconds);
    return Duration(milliseconds: totalMs ~/ metrics.length);
  }

  static void logPerformance(String operation, Duration duration) {
    print('Performance: $operation took ${duration.inMilliseconds}ms');
  }

  static void printSummary() {
    print('\n=== Performance Summary ===');
    for (final entry in _metrics.entries) {
      final avgTime = getAverageTime(entry.key);
      if (avgTime != null) {
        print(
            '${entry.key}: ${avgTime.inMilliseconds}ms average (${entry.value.length} samples)');
      }
    }
    print('========================\n');
  }

  static void clearMetrics() {
    _metrics.clear();
  }
}

// ===================== MAIN WIDGET =====================

class MushafPageViewer extends StatefulWidget {
  const MushafPageViewer({super.key});

  @override
  State<MushafPageViewer> createState() => _MushafPageViewerState();
}

class _MushafPageViewerState extends State<MushafPageViewer> {
  int _currentPage = 1;

  // Store all pages data with new model
  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};

  bool _isInitializing = true;
  bool _hasInitialPageLoaded = false;
  String _loadingMessage = 'Initializing...';

  // Audio service
  final AudioService _audioService = AudioService();
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;

  // Surah service
  final SurahService _surahService = SurahService();

  // Add this new variable for user selection
  String? _userSelectedAyahId;

  // Bottom bar state variables
  int _currentAyahIndex = 0;
  int? _highlightedAyahIndex;
  bool _isDragging = false;
  bool _isPlaying = false;
  bool _isLoading = false;

  // PageView controller
  late PageController _pageController;

  final Map<int, double> _uniformFontSizeCache = {};

  // Preloading configuration
  static const int PRELOAD_RADIUS = 3;

  // Search state
  String _searchQuery = '';
  List<Surah> _filteredSurahs = [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _initializeApp();
  }

  // Coordinated initialization method
  Future<void> _initializeApp() async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      // 1. Initialize databases first
      await _initDatabases();

      // 2. Initialize services in parallel
      await Future.wait([
        _initAudio(),
        _initSurahService(),
      ]);

      setState(() {
        _loadingMessage = 'Loading fonts...';
      });

      // 3. Load essential fonts
      await OptimizedFontService.loadSurahNameFont();
      await SurahBanner.preload();

      await OptimizedFontService.preloadAllFonts();

      setState(() {
        _loadingMessage = 'Loading first page...';
      });

      // 4. Load the initial page and ensure it's displayed
      await _loadPageOptimized(_currentPage);

      // 5. Wait for the UI to render the first page
      await Future.delayed(Duration.zero);
      await WidgetsBinding.instance.endOfFrame;

      // 6. Mark that we have initial content
      setState(() {
        _hasInitialPageLoaded = true;
        _loadingMessage = 'Loading additional content...';
      });

      // 7. Wait one more frame to ensure content is visible
      await Future.delayed(Duration.zero);
      await WidgetsBinding.instance.endOfFrame;

      // 8. Build surah mapping with available data
      await _surahService.buildSurahToPageMap(_allPagesData);

      // 9. Now we can hide the loading screen
      setState(() {
        _isInitializing = false;
      });

      // 10. Start background preloading (non-blocking)
      _startBackgroundPreloading();

    } catch (e) {
      print('Initialization error: $e');
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $e';
      });
    }
  }

  Future<void> _initSurahService() async {
    await _surahService.initialize();
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
    final databasesPath = await getDatabasesPath();

    // Copy databases if they don't exist
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

    // Initialize optimized database service
    await OptimizedDatabaseService.initialize();
  }

  Future<void> _startBackgroundPreloading() async {
    // Load a few critical pages first (pages around current page)
    final criticalPages = <int>{};
    for (int i = -2; i <= 2; i++) {
      final page = _currentPage + i;
      if (page >= 1 && page <= 604 && !_loadedPages.contains(page)) {
        criticalPages.add(page);
      }
    }

    // Load critical pages first
    for (final page in criticalPages) {
      if (!_loadedPages.contains(page)) {
        await _loadPageSilentlyOptimized(page);
        // Small delay to prevent blocking
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // Then load all remaining pages in background
    for (int page = 1; page <= 604; page++) {
      if (!_loadedPages.contains(page)) {
        await _loadPageSilentlyOptimized(page);
        // Yield control periodically to prevent ANR
        if (page % 20 == 0) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }
    }

    print('Background preloading completed: ${_loadedPages.length} pages loaded');
  }

  Future<void> _loadAroundCurrentPage(int currentPage) async {
    final pagesToLoad = <int>{};

    for (int i = -PRELOAD_RADIUS; i <= PRELOAD_RADIUS; i++) {
      final page = currentPage + i;
      if (page >= 1 && page <= 604 && !_loadedPages.contains(page)) {
        pagesToLoad.add(page);
      }
    }

    // Load pages in smaller batches to prevent overwhelming the system
    const maxConcurrentPages = 3;
    for (int i = 0; i < pagesToLoad.length; i += maxConcurrentPages) {
      final batch = pagesToLoad.skip(i).take(maxConcurrentPages).toList();
      final futures = batch.map((page) => _loadPageSilentlyOptimized(page));
      await Future.wait(futures);

      // Small delay between batches to prevent UI blocking
      if (i + maxConcurrentPages < pagesToLoad.length) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> _loadPageOptimized(int page) async {
    // Check cache first - should always be available after preloading
    final cachedPage = OptimizedPageCache.getPage(page);
    if (cachedPage != null) {
      _allPagesData[page] = cachedPage;
      _loadedPages.add(page);
      setState(() {
        _currentPage = page;
      });
      return;
    }

    // If not in cache, load it (shouldn't happen after full preload)
    await _loadPageSilentlyOptimized(page);
    setState(() {
      _currentPage = page;
    });
  }

  Future<void> _loadPageSilentlyOptimized(int page) async {
    if (_loadedPages.contains(page)) return;

    final stopwatch = Stopwatch()..start();

    try {
      // All fonts are already preloaded at startup
      final mushafPage = await MushafPageBuilder.buildPage(
        pageNumber: page,
        wordsDb: OptimizedDatabaseService.wordsDb,
        layoutDb: OptimizedDatabaseService.layoutDb,
      );

      // Cache the page
      OptimizedPageCache.cachePage(page, mushafPage);
      _allPagesData[page] = mushafPage;
      _loadedPages.add(page);

      stopwatch.stop();
      PerformanceMonitor.logPerformance('loadPage_$page', stopwatch.elapsed);
    } catch (e) {
      print('Error loading page $page: $e');
      // Create empty page as fallback
      final emptyPage = MushafPage(
        pageNumber: page,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
      _allPagesData[page] = emptyPage;
      _loadedPages.add(page);

      stopwatch.stop();
      PerformanceMonitor.logPerformance('loadPage_', stopwatch.elapsed);
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

  // Helper method to seek to a specific ayah by ID
  void _seekToAyahFromId(String ayahId) {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    // Parse the ayahId (format: "surah:ayah")
    final parts = ayahId.split(':');
    if (parts.length != 2) return;

    final surah = int.tryParse(parts[0]);
    final ayah = int.tryParse(parts[1]);
    if (surah == null || ayah == null) return;

    // Find the ayah index in the current page
    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == surah && ayahs[i].ayah == ayah) {
        // Update the current ayah index and highlighted ayah
        setState(() {
          _currentAyahIndex = i;
          _highlightedAyahIndex = i;
        });

        // Seek to this ayah in the audio service
        _audioService.seekToAyah(i);
        break;
      }
    }
  }

  // Direct search for surah start page when mapping is not available
  int? _findSurahStartPageDirectly(int surahId) {
    print('Searching for surah $surahId start page directly...');

    // Search through available pages
    for (int page = 1; page <= 604; page++) {
      final pageData = _allPagesData[page];
      if (pageData != null) {
        for (final ayah in pageData.ayahs) {
          if (ayah.surah == surahId && ayah.ayah == 1) {
            print('Found surah $surahId starting on page $page');
            return page;
          }
        }
      }
    }

    // If not found in loaded pages, load more pages and search
    print('Surah $surahId not found in loaded pages, loading more...');
    return null; // For now, return null. We could implement async loading here
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

  Widget _buildSearchBox() {
    // Get current surah info
    final currentSurah = _getCurrentSurah();
    final surahInfo = currentSurah != null
        ? '${currentSurah.nameSimple} (${currentSurah.id})'
        : 'Page $_currentPage';

    return GestureDetector(
      onTap: _showSurahListBottomSheet,
      child: Container(
        height: 40,
        width: double
            .infinity, // Full width to match mushaf// Match content padding
        margin: const EdgeInsets.only(bottom: 12), // Match content padding
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF)
              .withOpacity(0.0), // Completely transparent
          borderRadius: BorderRadius.zero, // No rounded corners - rectangular
          border: Border.all(
            color:
            const Color(0xFFE0E0E0).withOpacity(0.3), // Very subtle border
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisAlignment:
          MainAxisAlignment.spaceBetween, // Space between left and right
          children: [
            // Surah name on the left
            Text(
              surahInfo,
              style: TextStyle(
                color: const Color(0xFF424242)
                    .withOpacity(0.6), // More subtle text
                fontSize: 16,
                fontWeight: FontWeight.w400, // Lighter weight
              ),
              overflow: TextOverflow.ellipsis,
            ),
            // Search button on the right
            Icon(
              Icons.search,
              color:
              const Color(0xFF424242).withOpacity(0.5), // More subtle icon
              size: 18, // Slightly smaller
            ),
          ],
        ),
      ),
    );
  }

  Surah? _getCurrentSurah() {
    // Get the current page data to find which surah(s) are on this page
    final pageData = _allPagesData[_currentPage];
    if (pageData == null || pageData.ayahs.isEmpty) {
      print('No page data or ayahs found for page $_currentPage');
      return null;
    }

    // Count ayahs per surah to find the main surah
    final surahCounts = <int, int>{};
    for (final ayah in pageData.ayahs) {
      surahCounts[ayah.surah] = (surahCounts[ayah.surah] ?? 0) + 1;
    }

    if (surahCounts.isEmpty) {
      print('No surahs found on page $_currentPage');
      return null;
    }

    // Find the surah with the most ayahs on this page (main surah)
    int mainSurahId =
        surahCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;

    final surah = _surahService.getSurahById(mainSurahId);

    if (surah != null) {
      if (surahCounts.length > 1) {
        final surahNames = surahCounts.entries
            .map((e) =>
        '${_surahService.getSurahById(e.key)?.nameSimple ?? 'Unknown'} (${e.value} ayahs)')
            .join(', ');
        print(
            'Page $_currentPage has multiple surahs: $surahNames - showing main surah: ${surah.nameSimple}');
      } else {
        print(
            'Page $_currentPage belongs to surah: ${surah.nameSimple} (ID: $mainSurahId)');
      }
      return surah;
    } else {
      print('Surah with ID $mainSurahId not found in metadata');
      return null;
    }
  }

  void _showSurahListBottomSheet() {
    final surahs = _surahService.surahs;
    if (surahs == null) return;

    // Initialize filtered surahs with all surahs
    _filteredSurahs = List.from(surahs);
    _searchQuery = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Handle bar
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      // Header
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Text(
                              'Select Surah',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      // Search bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Search surahs...',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onChanged: (value) {
                            setModalState(() {
                              _searchQuery = value.toLowerCase();
                              _filteredSurahs = surahs.where((surah) {
                                return surah.nameSimple
                                    .toLowerCase()
                                    .contains(_searchQuery) ||
                                    surah.nameArabic.contains(_searchQuery) ||
                                    surah.id.toString().contains(_searchQuery);
                              }).toList();
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Surah list
                      Expanded(
                        child: _filteredSurahs.isEmpty
                            ? const Center(
                          child: Text(
                            'No surahs found',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                            ),
                          ),
                        )
                            : ListView.builder(
                          controller: scrollController,
                          itemCount: _filteredSurahs.length,
                          itemBuilder: (context, index) {
                            final surah = _filteredSurahs[index];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: const Color(0xFF616161),
                                child: Text(
                                  '${surah.id}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                surah.nameSimple,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    surah.nameArabic,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    '${surah.versesCount} verses • ${surah.revelationPlace}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                              trailing: const Icon(
                                  Icons.arrow_forward_ios,
                                  size: 16),
                              onTap: () {
                                Navigator.of(context).pop();
                                _navigateToSurah(surah.id);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _navigateToSurah(int surahId) {
    // Check if mapping is available, if not try to rebuild it
    if (_surahService.surahToPageMap == null ||
        _surahService.surahToPageMap!.isEmpty) {
      print('Surah mapping is empty, rebuilding...');
      _surahService.buildSurahToPageMap(_allPagesData);
    }

    // If still no mapping, try to find the surah start page directly
    int? startPage = _surahService.getSurahStartPage(surahId);
    if (startPage == null) {
      print('Surah $surahId not found in mapping, searching directly...');
      startPage = _findSurahStartPageDirectly(surahId);
    }

    print('Navigating to surah $surahId, start page: $startPage');

    if (startPage != null) {
      // Stop audio if playing
      if (_audioState != AudioPlaybackState.stopped) {
        _stopAudio();
      }

      // Navigate to the surah's starting page
      _pageController.animateToPage(
        startPage - 1, // PageController uses 0-based index
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

      // Load the page if not already loaded
      _loadPageOptimized(startPage);
    } else {
      // Show error message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not find the starting page for this surah'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    OptimizedDatabaseService.close();
    _audioService.dispose();

    // Print performance summary before disposing
    PerformanceMonitor.printSummary();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    return Scaffold(
      backgroundColor:
      const Color(0xFFFFFFFF), // White to match mushaf background
      appBar: AppBar(
        title: _buildSearchBox(),
        centerTitle: false, // Don't center since we want full width
        backgroundColor:
        const Color(0xFFFFFFFF), // White to match mushaf background
        foregroundColor:
        const Color(0xFF424242), // Neutral dark gray for subtle contrast
        automaticallyImplyLeading: false,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
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
                  color: const Color(0xFF424242)),
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
          // Audio Bottom Bar - always visible
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
        color: Color(0xFFFFFFFF), // White to match mushaf background
        // Removed top border for seamless blending
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
              '$_currentPage/604',
              style: TextStyle(
                fontSize: isTablet ? 11 : 9,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF424242).withOpacity(0.7),
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
                    ? const Color(0xFF424242)
                    .withOpacity(0.05) // Even more transparent
                    : Colors.grey.withOpacity(0.05),
                border: Border.all(
                  color: ayahs.isNotEmpty
                      ? const Color(0xFF424242).withOpacity(0.15)
                      : Colors.grey.withOpacity(0.15),
                  width: 0.5, // Thinner border
                ),
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
                color: const Color(0xFF424242)
                    .withOpacity(0.5), // More subtle gray
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
                activeTrackColor: const Color(0xFF424242).withOpacity(0.3),
                inactiveTrackColor: const Color(0xFFE0E0E0),
                thumbColor: const Color(0xFF424242).withOpacity(0.4),
                overlayColor: const Color(0xFF424242).withOpacity(0.1),
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
                    color: const Color(0xFF424242).withOpacity(0.7),
                  ),
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
      return Center(
        child: (uniformFontSize != null)
            ? _buildTextWithThicknessFixedSize(
            line.text, uniformFontSize, 'QPCPageFont$page')
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
      return Center(
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
            line.text, uniformFontSize, 'QPCPageFont$page'),
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
                text: '\u2009',
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
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color textColor = Colors.black}) {
    Widget textWidget = Container(
      width: double.infinity,
      child: Text(
        text,
        textAlign: TextAlign.center,
        textDirection: TextDirection.rtl,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          color: textColor,
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
                text: '\u2009',
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
      child: RichText(
        textAlign: TextAlign.center,
        textDirection: TextDirection.rtl,
        text: TextSpan(children: spans),
      ),
    );
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
            // Add thin spaces between words (totalWords - 1 spaces)
            if (totalWords > 1) {
              textToMeasure = text + '\u2009' * (totalWords - 1);
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
}