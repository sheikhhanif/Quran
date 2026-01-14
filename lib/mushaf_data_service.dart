import 'dart:io';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'mushaf_models.dart';
import 'mushaf_page_builder.dart';

class MushafDataService {
  Database? _wordsDb;
  Database? _layoutDb;
  final Map<int, MushafPage> _allPagesData = {};
  final Set<int> _loadedPages = {};

  static bool _surahNameFontLoaded = false;

  static const int BATCH_SIZE = 10;
  static const int PRELOAD_RADIUS = 5;
  static const int TOTAL_PAGES = 604;

  Database? get wordsDb => _wordsDb;
  Database? get layoutDb => _layoutDb;
  Map<int, MushafPage> get allPagesData => _allPagesData;
  Set<int> get loadedPages => _loadedPages;

  Future<void> initDatabases() async {
    final databasesPath = await getDatabasesPath();

    // Digital Khatt V2 database for words/scripts
    final wordsDbPath = p.join(databasesPath, 'digital-khatt-v2.db');
    if (!await File(wordsDbPath).exists()) {
      final wordsData =
          await rootBundle.load('assets/quran/scripts/digital-khatt-v2.db');
      final wordsBytes = wordsData.buffer
          .asUint8List(wordsData.offsetInBytes, wordsData.lengthInBytes);
      await File(wordsDbPath).writeAsBytes(wordsBytes, flush: true);
    }

    // Digital Khatt layout database (15 lines per page)
    final layoutDbPath = p.join(databasesPath, 'digital-khatt-15-lines.db');
    if (!await File(layoutDbPath).exists()) {
      final layoutData =
          await rootBundle.load('assets/quran/layout/digital-khatt-15-lines.db');
      final layoutBytes = layoutData.buffer
          .asUint8List(layoutData.offsetInBytes, layoutData.lengthInBytes);
      await File(layoutDbPath).writeAsBytes(layoutBytes, flush: true);
    }

    _wordsDb = await openDatabase(wordsDbPath);
    _layoutDb = await openDatabase(layoutDbPath);

    await _loadSurahNameFont();
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

  Future<void> loadPage(int page) async {
    if (_wordsDb == null || _layoutDb == null || _loadedPages.contains(page))
      return;

    try {
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

  Future<void> loadAroundCurrentPage(int currentPage) async {
    final pagesToLoad = <int>{};

    for (int i = -PRELOAD_RADIUS; i <= PRELOAD_RADIUS; i++) {
      final page = currentPage + i;
      if (page >= 1 && page <= TOTAL_PAGES && !_loadedPages.contains(page)) {
        pagesToLoad.add(page);
      }
    }

    final futures = pagesToLoad.map((page) => loadPage(page));
    await Future.wait(futures);
  }

  Future<void> startBackgroundPreloading({
    required Function(double progress) onProgress,
  }) async {
    int loadedCount = _loadedPages.length;

    for (int batchStart = 1; batchStart <= TOTAL_PAGES; batchStart += BATCH_SIZE) {
      final batchEnd = (batchStart + BATCH_SIZE - 1).clamp(1, TOTAL_PAGES);
      final batch = <Future<void>>[];

      for (int page = batchStart; page <= batchEnd; page++) {
        if (!_loadedPages.contains(page)) {
          batch.add(loadPage(page));
        }
      }

      if (batch.isNotEmpty) {
        await Future.wait(batch);
        loadedCount += batch.length;
        onProgress(loadedCount / TOTAL_PAGES);
      }

      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  void dispose() {
    _wordsDb?.close();
    _layoutDb?.close();
  }
}
