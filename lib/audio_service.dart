import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// Import the models from quran_service
import 'quran_service.dart';

// ===================== AUDIO MODELS =====================

enum AudioPlaybackState {
  stopped,
  playing,
  paused,
  loading,
}

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

// ===================== AUDIO CACHE SERVICE =====================

class AudioCacheService {
  static final AudioCacheService _instance = AudioCacheService._internal();
  factory AudioCacheService() => _instance;
  AudioCacheService._internal();

  static Directory? _cacheDirectory;
  static const String _audioCacheFolder = 'audio_cache';
  static const int _maxCacheSize = 100;

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

    if (await file.exists()) {
      return filePath;
    }

    try {
      final response = await http.get(Uri.parse(audioUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
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
    final uri = Uri.parse(url);
    final pathSegments = uri.pathSegments;
    final fileName = pathSegments.isNotEmpty ? pathSegments.last : 'audio.mp3';

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

      fileInfos.sort((a, b) {
        final aStat = a.statSync();
        final bStat = b.statSync();
        return aStat.modified.compareTo(bStat.modified);
      });

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

// ===================== AUDIO SERVICE =====================

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioCacheService _cacheService = AudioCacheService();
  Map<String, AudioData>? _allAudioData;
  bool _isDisposed = false;

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
          if (!_stateController.isClosed) {
            _stateController.add(AudioPlaybackState.playing);
          }
          break;
        case PlayerState.paused:
          if (!_stateController.isClosed) {
            _stateController.add(AudioPlaybackState.paused);
          }
          break;
        case PlayerState.stopped:
          if (!_stateController.isClosed) {
            _stateController.add(AudioPlaybackState.stopped);
          }
          if (!_highlightController.isClosed) {
            _highlightController.add(null);
          }
          if (!_currentAyahController.isClosed) {
            _currentAyahController.add(null);
          }
          break;
        case PlayerState.completed:
          _onAudioCompleted();
          break;
        case PlayerState.disposed:
          break;
      }
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      if (!_positionController.isClosed) {
        _positionController.add(position);
      }
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
    if (_isDisposed) {
      print('AudioService is disposed, cannot play ayahs');
      return;
    }

    if (ayahs.isEmpty) return;

    _pageAyahs = ayahs;
    _currentAyahIndex = 0;
    await _playCurrentAyah();
  }

  Future<void> _playCurrentAyah() async {
    // Safety check: Don't proceed if disposed
    if (_isDisposed) {
      print('AudioService is disposed, skipping playback');
      return;
    }

    if (_pageAyahs == null || _currentAyahIndex >= _pageAyahs!.length) {
      await stop();
      return;
    }

    final ayah = _pageAyahs![_currentAyahIndex];
    final audioData = getAudioData(ayah.surah, ayah.ayah);

    if (audioData == null) {
      _currentAyahIndex++;
      await _playCurrentAyah();
      return;
    }

    try {
      // Check again before audio operations
      if (_isDisposed) {
        print('AudioService disposed during playback setup');
        return;
      }

      if (!_stateController.isClosed) {
        _stateController.add(AudioPlaybackState.loading);
      }
      _currentAudioData = audioData;
      _currentAyah = ayah;
      if (!_currentAyahController.isClosed) {
        _currentAyahController.add(ayah);
      }

      _lastHighlightedWordId = null;
      if (!_highlightController.isClosed) {
        _highlightController.add(null);
      }

      String audioPath;
      try {
        audioPath =
            await _cacheService.downloadAndCacheAudio(audioData.audioUrl);

        // Final check before playing
        if (_isDisposed) {
          print('AudioService disposed before playing audio');
          return;
        }

        await _audioPlayer.play(DeviceFileSource(audioPath));
      } catch (cacheError) {
        print('Cache error, falling back to URL: $cacheError');

        // Check again before URL fallback
        if (_isDisposed) {
          print('AudioService disposed before URL fallback');
          return;
        }

        await _audioPlayer.play(UrlSource(audioData.audioUrl));
      }
    } catch (e) {
      print('Error playing ayah ${ayah.surah}:${ayah.ayah} - $e');
      // Only continue if not disposed
      if (!_isDisposed) {
        _currentAyahIndex++;
        await _playCurrentAyah();
      }
    }
  }

  Future<void> _onAudioCompleted() async {
    _currentAyahIndex++;
    await Future.delayed(const Duration(milliseconds: 500));

    if (_currentAyahIndex < (_pageAyahs?.length ?? 0)) {
      await _playCurrentAyah();
    } else {
      if (!_stateController.isClosed) {
        _stateController.add(AudioPlaybackState.stopped);
      }
      if (!_highlightController.isClosed) {
        _highlightController.add(null);
      }
      if (!_currentAyahController.isClosed) {
        _currentAyahController.add(null);
      }
      _pageAyahs = null;
    }
  }

  Future<void> pause() async {
    if (_isDisposed) return;
    try {
      await _audioPlayer.pause();
    } catch (e) {
      print('Error pausing audio: $e');
    }
  }

  Future<void> resume() async {
    if (_isDisposed) return;
    try {
      await _audioPlayer.resume();
    } catch (e) {
      print('Error resuming audio: $e');
    }
  }

  Future<void> stop() async {
    if (_isDisposed) return;
    try {
      await _audioPlayer.stop();
    } catch (e) {
      print('Error stopping audio: $e');
    }

    if (!_highlightController.isClosed) {
      _highlightController.add(null);
    }
    if (!_currentAyahController.isClosed) {
      _currentAyahController.add(null);
    }
    _pageAyahs = null;
    _currentAyahIndex = 0;
  }

  Future<void> seekToAyah(int ayahIndex) async {
    if (_isDisposed) return;

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
    AudioSegment? currentSegment;

    for (final segment in _currentAudioData!.segments) {
      if (positionMs >= segment.startTimeMs && positionMs < segment.endTimeMs) {
        currentSegment = segment;
        break;
      }
    }

    String? newWordId;

    if (currentSegment != null) {
      final wordIndex = currentSegment.wordIndex;
      final ayahWords = _getAyahWords(_currentAyah!);

      if (wordIndex > 0 && wordIndex <= ayahWords.length) {
        newWordId = '${_currentAyah!.surah}:${_currentAyah!.ayah}:$wordIndex';
      } else if (ayahWords.isNotEmpty) {
        final fallbackWordIndex = wordIndex.clamp(1, ayahWords.length);
        newWordId =
            '${_currentAyah!.surah}:${_currentAyah!.ayah}:$fallbackWordIndex';
      }
    } else {
      AudioSegment? bestSegment;
      int minTimeDiff = 500;

      for (final segment in _currentAudioData!.segments) {
        int timeDiff;

        if (positionMs < segment.startTimeMs) {
          timeDiff = segment.startTimeMs - positionMs;
        } else if (positionMs > segment.endTimeMs) {
          timeDiff = positionMs - segment.endTimeMs;
        } else {
          continue;
        }

        if (timeDiff < minTimeDiff) {
          minTimeDiff = timeDiff;
          bestSegment = segment;
        }
      }

      if (bestSegment != null) {
        final ayahWords = _getAyahWords(_currentAyah!);
        final wordIndex = bestSegment.wordIndex;
        if (wordIndex > 0 && wordIndex <= ayahWords.length) {
          newWordId = '${_currentAyah!.surah}:${_currentAyah!.ayah}:$wordIndex';
        } else if (ayahWords.isNotEmpty) {
          final fallbackWordIndex = wordIndex.clamp(1, ayahWords.length);
          newWordId =
              '${_currentAyah!.surah}:${_currentAyah!.ayah}:$fallbackWordIndex';
        }
      }
    }

    if (newWordId != null && newWordId != _lastHighlightedWordId) {
      if (!_highlightController.isClosed) {
        _highlightController.add(newWordId);
        _lastHighlightedWordId = newWordId;
      }
    } else if (newWordId == null && _lastHighlightedWordId != null) {
      if (!_highlightController.isClosed) {
        _highlightController.add(null);
        _lastHighlightedWordId = null;
      }
    }
  }

  List<AyahWord> _getAyahWords(PageAyah ayah) {
    List<AyahWord> allWords = [];
    for (final segment in ayah.segments) {
      allWords.addAll(segment.words);
    }
    allWords.sort((a, b) => a.wordIndex.compareTo(b.wordIndex));
    return allWords;
  }

  void reset() {
    // Reset state without disposing the service
    try {
      _audioPlayer.stop();
      if (!_highlightController.isClosed) {
        _highlightController.add(null);
      }
      if (!_currentAyahController.isClosed) {
        _currentAyahController.add(null);
      }
      _pageAyahs = null;
      _currentAyahIndex = 0;
      _currentAudioData = null;
      _currentAyah = null;
      _lastHighlightedWordId = null;
    } catch (e) {
      print('Error during AudioService reset: $e');
    }
  }

  void dispose() {
    _isDisposed = true;

    try {
      _positionSubscription?.cancel();
      _playerStateSubscription?.cancel();
      _positionController.close();
      _stateController.close();
      _highlightController.close();
      _currentAyahController.close();
      _audioPlayer.dispose();
    } catch (e) {
      print('Error during AudioService disposal: $e');
    }
  }
}
