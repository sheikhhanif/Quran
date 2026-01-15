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
  final List<int> _pageAccessOrder = []; // For LRU cache eviction
  RendererType _currentRenderer = RendererType.qpcUthmani;

  static final Map<RendererType, bool> _fontLoaded = {};
  static final Map<RendererType, bool> _surahNameFontLoaded = {};
  static final Map<String, bool> _perPageFontsLoaded = {};

  static const int BATCH_SIZE = 10;
  static const int PRELOAD_RADIUS = 5;
  static const int TOTAL_PAGES = 604;
  static const int MAX_CACHED_PAGES = 50; // Limit page cache to prevent memory issues

  Database? get wordsDb => _wordsDb;
  Database? get layoutDb => _layoutDb;
  Map<int, MushafPage> get allPagesData => _allPagesData;
  Set<int> get loadedPages => _loadedPages;
  RendererType get currentRenderer => _currentRenderer;

  Future<void> initDatabases({RendererType? renderer}) async {
    if (renderer != null && renderer != _currentRenderer) {
      // Switching renderers - clear cache and close old databases
      await _switchRenderer(renderer);
    }

    final databasesPath = await getDatabasesPath();
    final rendererType = renderer ?? _currentRenderer;

    // Load layout database with memory-efficient copying
    final layoutDbFileName = _getDbFileName(rendererType.layoutDbAsset);
    final layoutDbPath = p.join(databasesPath, layoutDbFileName);
    if (!await File(layoutDbPath).exists()) {
      await _copyAssetToFile(rendererType.layoutDbAsset, layoutDbPath);
    }

    _layoutDb = await openDatabase(
      layoutDbPath,
      readOnly: true,
      singleInstance: true,
    );

    // Load words database if renderer uses it
    if (rendererType.usesWordsDb) {
      final wordsDbFileName = _getDbFileName(rendererType.wordsDbAsset);
      final wordsDbPath = p.join(databasesPath, wordsDbFileName);
      if (!await File(wordsDbPath).exists()) {
        await _copyAssetToFile(rendererType.wordsDbAsset, wordsDbPath);
      }
      _wordsDb = await openDatabase(
        wordsDbPath,
        readOnly: true,
        singleInstance: true,
      );
    } else {
      // For renderers without separate words DB, use layout DB as words DB
      _wordsDb = _layoutDb;
    }

    await _loadRendererFont(rendererType);
    await _loadSurahNameFont(rendererType);
    
    // Ensure current renderer is set
    _currentRenderer = rendererType;
  }

  /// Copy asset to file in chunks to avoid loading entire file into memory
  Future<void> _copyAssetToFile(String assetPath, String targetPath) async {
    const chunkSize = 64 * 1024; // 64KB chunks
    final assetData = await rootBundle.load(assetPath);
    final file = File(targetPath);
    final sink = file.openWrite();

    try {
      int offset = 0;
      while (offset < assetData.lengthInBytes) {
        final end = (offset + chunkSize).clamp(0, assetData.lengthInBytes);
        final chunk = assetData.buffer.asUint8List(
          assetData.offsetInBytes + offset,
          end - offset,
        );
        sink.add(chunk);
        offset = end;
      }
    } finally {
      await sink.close();
    }
  }

  String _getDbFileName(String assetPath) {
    return p.basename(assetPath);
  }

  Future<void> _switchRenderer(RendererType newRenderer) async {
    // Close old databases
    await _wordsDb?.close();
    await _layoutDb?.close();
    _wordsDb = null;
    _layoutDb = null;

    // Clear cached pages
    _allPagesData.clear();
    _loadedPages.clear();
    _pageAccessOrder.clear();

    // Clear per-page font cache for the old renderer
    final oldRendererPrefix = '${_currentRenderer.name}_page_';
    _perPageFontsLoaded.removeWhere((key, _) => key.startsWith(oldRendererPrefix));

    // Update current renderer
    _currentRenderer = newRenderer;
  }

  Future<void> switchRenderer(RendererType newRenderer) async {
    if (newRenderer == _currentRenderer) return;
    await initDatabases(renderer: newRenderer);
  }

  Future<void> _loadRendererFont(RendererType rendererType) async {
    if (_fontLoaded[rendererType] == true) return;

    try {
      if (rendererType.hasPerPageFonts) {
        // QPC V2 uses per-page fonts, load them on demand
        // For now, we'll load the first page font as a fallback
        final fontLoader = FontLoader(rendererType.fontFamily);
        try {
          final fontData = await rootBundle.load('${rendererType.fontAsset}p1.ttf');
          fontLoader.addFont(Future.value(fontData));
          await fontLoader.load();
        } catch (e) {
          print('Failed to load QPC V2 per-page font: $e');
        }
      } else {
        final fontLoader = FontLoader(rendererType.fontFamily);
        final fontData = await rootBundle.load(rendererType.fontAsset);
        fontLoader.addFont(Future.value(fontData));
        await fontLoader.load();
      }
      _fontLoaded[rendererType] = true;
    } catch (e) {
      print('Renderer font loading failed for ${rendererType.name}: $e');
    }
  }

  Future<void> _loadSurahNameFont(RendererType rendererType) async {
    if (_surahNameFontLoaded[rendererType] == true) return;

    try {
      final fontLoader = FontLoader('SurahNameFont');
      // Surah name font is shared across renderers
      final fontData =
          await rootBundle.load('assets/quran/renderer/digital_khatt/font_v2.otf');
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _surahNameFontLoaded[rendererType] = true;
    } catch (e) {
      print('Surah name font loading failed: $e');
    }
  }

  Future<void> loadPerPageFont(int page, RendererType rendererType) async {
    if (!rendererType.hasPerPageFonts) return;

    final fontFamily = '${rendererType.fontFamily}_Page$page';
    final fontKey = '${rendererType.name}_page_$page';
    
    // Check if this specific page font is already loaded
    if (_perPageFontsLoaded[fontKey] == true) {
      return;
    }

    try {
      final fontLoader = FontLoader(fontFamily);
      final fontPath = '${rendererType.fontAsset}p$page.ttf';
      final fontData = await rootBundle.load(fontPath);
      fontLoader.addFont(Future.value(fontData));
      await fontLoader.load();
      _perPageFontsLoaded[fontKey] = true;
    } catch (e) {
      print('Failed to load per-page font for page $page: $e');
    }
  }

  Future<void> loadPage(int page) async {
    if (_layoutDb == null) {
      return;
    }

    // Update access order for LRU cache
    if (_loadedPages.contains(page)) {
      _pageAccessOrder.remove(page);
      _pageAccessOrder.add(page);
      return;
    }

    // For QPC V2, load per-page font
    if (_currentRenderer.hasPerPageFonts) {
      await loadPerPageFont(page, _currentRenderer);
    }

    try {
      final mushafPage = await MushafPageBuilder.buildPage(
        pageNumber: page,
        wordsDb: _wordsDb ?? _layoutDb!,
        layoutDb: _layoutDb!,
      );

      // Enforce cache limit using LRU eviction
      _enforceCacheLimit();

      _allPagesData[page] = mushafPage;
      _loadedPages.add(page);
      _pageAccessOrder.add(page);
    } catch (e) {
      print('Error loading page $page: $e');
      _allPagesData[page] = MushafPage(
        pageNumber: page,
        lines: [],
        ayahs: [],
        lineToSegments: {},
      );
      _loadedPages.add(page);
      _pageAccessOrder.add(page);
    }
  }

  /// Remove least recently used pages when cache exceeds limit
  void _enforceCacheLimit() {
    while (_allPagesData.length >= MAX_CACHED_PAGES && _pageAccessOrder.isNotEmpty) {
      final pageToRemove = _pageAccessOrder.removeAt(0);
      _allPagesData.remove(pageToRemove);
      _loadedPages.remove(pageToRemove);
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

    for (int batchStart = 1;
        batchStart <= TOTAL_PAGES;
        batchStart += BATCH_SIZE) {
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
