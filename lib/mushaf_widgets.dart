import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Import services
import 'quran_service.dart';
import 'audio_service.dart';
import 'surah_header_banner.dart';
import 'theme.dart';

// ===================== VIEW MODES =====================

enum ViewMode {
  arabic,
  translation,
}

// ===================== MAIN MUSHAF WIDGET =====================

class MushafPageViewer extends StatefulWidget {
  final int? initialSurahId;
  final int? initialPageNumber;
  final QuranService? quranService;
  final QuranThemeMode? initialTheme;

  const MushafPageViewer({
    super.key,
    this.initialSurahId,
    this.initialPageNumber,
    this.quranService,
    this.initialTheme,
  });

  @override
  State<MushafPageViewer> createState() => _MushafPageViewerState();
}

class _MushafPageViewerState extends State<MushafPageViewer>
    with SingleTickerProviderStateMixin {
  int _currentPage = 1;
  bool _isInitializing = true;
  String _loadingMessage = 'Initializing...';

  // Services
  late final QuranService _quranService;
  final AudioService _audioService = AudioService();

  // Audio state
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;
  String? _userSelectedAyahId;
  bool _audioInitialized = false;

  // Bottom bar state
  int _currentAyahIndex = 0;
  int? _highlightedAyahIndex;
  bool _isDragging = false;
  bool _isPlaying = false;
  bool _isLoading = false;

  // UI state
  late PageController _pageController;
  final Map<int, double> _uniformFontSizeCache = {};
  late QuranThemeMode _currentTheme;
  ViewMode _currentViewMode = ViewMode.arabic;

  // Controls visibility state
  late AnimationController _controlsAnimationController;
  bool _areControlsVisible = true;

  // Background loading control
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();

    // Initialize theme
    _currentTheme = widget.initialTheme ?? QuranThemeMode.normal;

    // Initialize QuranService
    _quranService = widget.quranService ?? QuranService();

    // Initialize animation controller for header/footer visibility
    _controlsAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Start with controls visible
    _controlsAnimationController.value = 1.0;

    // Ensure system UI is visible initially
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Determine initial page
    int initialPage = 603; // Default to last page (page 1)

    // Priority: initialPageNumber > initialSurahId > default
    if (widget.initialPageNumber != null) {
      // Direct page navigation
      final pageNumber = widget.initialPageNumber!;
      if (pageNumber >= 1 && pageNumber <= 604) {
        initialPage = 604 - pageNumber; // Convert to PageView index
        _currentPage = pageNumber;
      }
    } else if (widget.initialSurahId != null) {
      // Surah-based navigation
      final startPage =
          _quranService.surahService.getSurahStartPage(widget.initialSurahId!);
      if (startPage != null) {
        initialPage = 604 - startPage; // Convert to PageView index
        _currentPage = startPage;
      }
    }

    _pageController = PageController(initialPage: initialPage);
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // If QuranService is already passed and initialized, show page immediately
      if (widget.quranService != null && widget.quranService!.isInitialized) {
        // Load target page immediately
        await _quranService.getPage(_currentPage);

        setState(() {
          _isInitializing = false;
        });

        // Start background preloading without blocking UI
        _startBackgroundPreloading();
        return;
      }

      // PRIORITY 1: Show target page as fast as possible
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Loading page...';
      });

      // Essential initialization only
      await _quranService.initialize();

      // Load ONLY the target page immediately
      await _quranService.getPage(_currentPage);

      // Show the page to user immediately
      setState(() {
        _isInitializing = false;
      });

      // PRIORITY 2: Load everything else in background without blocking
      _initializeRemainingResourcesInBackground();
    } catch (e) {
      print('Initialization error: $e');
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $e';
      });
    }
  }

  void _initializeRemainingResourcesInBackground() {
    Future.microtask(() async {
      try {
        // Load fonts in background
        await _quranService.preloadAllFonts();
        await SurahBanner.preload();

        // Initialize audio in background
        await _initAudio();

        // Preload surrounding pages
        await _quranService.preloadPagesAroundCurrent(_currentPage);

        // Build surah mapping
        await _quranService.buildSurahMapping();

        // Start full background preloading
        _startBackgroundPreloading();
      } catch (e) {
        print('Background initialization error: $e');
      }
    });
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

    _audioInitialized = true;
  }

  Future<void> _ensureAudioInitialized() async {
    if (!_audioInitialized) {
      await _initAudio();
    }
  }

  Future<void> _startBackgroundPreloading() async {
    // All background loading - don't block UI
    Future.microtask(() async {
      try {
        // Priority 1: Load pages around current page (if not already loaded)
        if (!_isDisposed) {
          await _quranService.preloadPagesAroundCurrent(_currentPage);
        }

        // Priority 2: Load common surah start pages in parallel
        if (!_isDisposed) {
          final commonPages = [
            1,
            2,
            50,
            77,
            102,
            128,
            151,
            177,
            187,
            201,
            221,
            235
          ];
          final pagesToLoad = commonPages
              .where((page) => !_quranService.allPagesData.containsKey(page))
              .toList();

          if (pagesToLoad.isNotEmpty) {
            await Future.wait(
                pagesToLoad.map((page) => _quranService.getPage(page)));
          }
        }

        // Priority 3: Load remaining pages sequentially
        for (int page = 1; page <= 604; page++) {
          // Check if widget is disposed to avoid database_closed errors
          if (_isDisposed) break;

          if (!_quranService.allPagesData.containsKey(page)) {
            try {
              await _quranService.getPage(page);
            } catch (e) {
              // Stop background loading if database is closed or other errors
              print('Background loading stopped at page $page: $e');
              break;
            }

            if (page % 20 == 0) {
              // Yield control more frequently to keep UI responsive
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }
        }
      } catch (e) {
        print('Background preloading error: $e');
      }
    });
  }

  void _onPageChanged(int index) {
    final page = 604 - index;
    _currentPage = page;
    _quranService.preloadPagesAroundCurrent(page);

    if (_audioState != AudioPlaybackState.stopped) {
      _stopAudio();
    }

    setState(() {
      _currentAyahIndex = 0;
      _highlightedAyahIndex = null;
      _isDragging = false;
    });
  }

  Future<void> _stopAudio() async {
    if (_audioInitialized) {
      await _audioService.stop();
    }
    setState(() {
      _highlightedWordId = null;
      _isPlaying = false;
      _isLoading = false;
      _currentAyahIndex = 0;
      _highlightedAyahIndex = null;
    });
  }

  List<PageAyah> _getCurrentPageAyahs() {
    final page = _quranService.allPagesData[_currentPage];
    if (page == null) return [];

    final ayahsToPlay =
        page.ayahs.where((ayah) => ayah.surah > 0 && ayah.ayah > 0).toList()
          ..sort((a, b) {
            if (a.surah != b.surah) return a.surah.compareTo(b.surah);
            return a.ayah.compareTo(b.ayah);
          });

    return ayahsToPlay;
  }

  void _seekToAyahFromId(String ayahId) {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    final parts = ayahId.split(':');
    if (parts.length != 2) return;

    final surah = int.tryParse(parts[0]);
    final ayah = int.tryParse(parts[1]);
    if (surah == null || ayah == null) return;

    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == surah && ayahs[i].ayah == ayah) {
        setState(() {
          _currentAyahIndex = i;
          _highlightedAyahIndex = i;
        });
        if (_audioInitialized) {
          _audioService.seekToAyah(i);
        }
        break;
      }
    }
  }

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

  Future<void> _togglePlayPause() async {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    setState(() {
      _isLoading = true;
    });

    // Ensure audio is initialized before using it
    await _ensureAudioInitialized();

    if (_isPlaying) {
      await _audioService.pause();
      setState(() {
        _isPlaying = false;
        _isLoading = false;
      });
    } else {
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

  void _toggleViewMode() {
    setState(() {
      _currentViewMode = _currentViewMode == ViewMode.arabic
          ? ViewMode.translation
          : ViewMode.arabic;
    });
  }

  void _toggleControlsVisibility() {
    // Prevent rapid toggling during gestures
    if (_controlsAnimationController.isAnimating) return;

    setState(() {
      _areControlsVisible = !_areControlsVisible;
      if (_areControlsVisible) {
        _controlsAnimationController.forward();
        // Show system status/navigation bars
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        _controlsAnimationController.reverse();
        // Hide system status/navigation bars for immersive reading
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  String _getCurrentSurahName() {
    final currentSurah =
        _quranService.surahService.getSurahForPage(_currentPage);
    return currentSurah?.nameSimple ?? 'Page $_currentPage';
  }

  @override
  void dispose() {
    // Mark as disposed to stop background loading
    _isDisposed = true;

    _pageController.dispose();
    // Only dispose QuranService if we created it (not passed from parent)
    if (widget.quranService == null) {
      _quranService.dispose();
    }
    _audioService.dispose();
    _controlsAnimationController.dispose();
    // Restore system UI mode on dispose
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final textColor = QuranTheme.getTextColor(_currentTheme);
    final backgroundColor = QuranTheme.getBackgroundColor(_currentTheme);
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    const double topBarHeight = 32.0;
    final double bottomBarHeight = isTablet ? 90.0 : 80.0;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: _isInitializing
          ? LoadingScreen(
              message: _loadingMessage,
              textColor: textColor,
              isTablet: isTablet,
            )
          : Stack(
              children: [
                // Main content - full screen with gesture detection
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _toggleControlsVisibility,
                    onPanStart: (_) => _toggleControlsVisibility(),
                    onPanUpdate: (_) => _toggleControlsVisibility(),
                    behavior: HitTestBehavior.deferToChild,
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: 604,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (context, index) {
                        final page = 604 - index;
                        return GestureDetector(
                          onTap: _toggleControlsVisibility,
                          onPanStart: (_) => _toggleControlsVisibility(),
                          onPanUpdate: (_) => _toggleControlsVisibility(),
                          behavior: HitTestBehavior.deferToChild,
                          child: MushafPageWidget(
                            pageNumber: page,
                            quranService: _quranService,
                            highlightedWordId: _highlightedWordId,
                            userSelectedAyahId: _userSelectedAyahId,
                            onAyahTapped: (ayahId) {
                              setState(() {
                                _userSelectedAyahId =
                                    _userSelectedAyahId == ayahId
                                        ? null
                                        : ayahId;
                              });
                              _seekToAyahFromId(ayahId);
                            },
                            uniformFontSizeCache: _uniformFontSizeCache,
                            backgroundColor: backgroundColor,
                            textColor: textColor,
                            theme: _currentTheme,
                            viewMode: _currentViewMode,
                            areControlsVisible: _areControlsVisible,
                          ),
                        );
                      },
                    ),
                  ),
                ),

                // App bar overlay (covers status bar area)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: _controlsAnimationController,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(
                            0,
                            -(statusBarHeight + topBarHeight) *
                                (1 - _controlsAnimationController.value)),
                        child: Opacity(
                          opacity: _controlsAnimationController.value,
                          child: Container(
                            height: statusBarHeight + topBarHeight,
                            color:
                                backgroundColor, // Use same color as background
                            child: Padding(
                              padding: EdgeInsets.only(top: statusBarHeight),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  // Left side - back button
                                  IconButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    icon: Icon(
                                      Icons.arrow_back,
                                      color: textColor,
                                      size: 20,
                                    ),
                                    tooltip: 'Back',
                                  ),

                                  // Center - title
                                  Expanded(
                                    child: Text(
                                      _getCurrentSurahName(),
                                      style: TextStyle(
                                        color: textColor,
                                        fontSize: isTablet ? 16 : 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),

                                  // Right side - action button
                                  IconButton(
                                    onPressed: _toggleViewMode,
                                    icon: Icon(
                                      _currentViewMode == ViewMode.arabic
                                          ? Icons.translate
                                          : Icons.menu_book,
                                      color: textColor.withOpacity(0.7),
                                      size: 20,
                                    ),
                                    tooltip: _currentViewMode == ViewMode.arabic
                                        ? 'Show Translation'
                                        : 'Show Arabic',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Audio bottom bar overlay with animation (includes bottom safe area)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedBuilder(
                    animation: _controlsAnimationController,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(
                            0,
                            (bottomBarHeight + bottomSafeArea) *
                                (1 - _controlsAnimationController.value)),
                        child: Opacity(
                          opacity: _controlsAnimationController.value,
                          child: AudioBottomBar(
                            currentPage: _currentPage,
                            currentAyahIndex: _currentAyahIndex,
                            highlightedAyahIndex: _highlightedAyahIndex,
                            isLoading: _isLoading,
                            isPlaying: _isPlaying,
                            ayahs: _getCurrentPageAyahs(),
                            onPlayPause: _togglePlayPause,
                            onProgressChanged: _onProgressBarChanged,
                            onProgressStart: () =>
                                setState(() => _isDragging = true),
                            onProgressEnd: () =>
                                setState(() => _isDragging = false),
                            backgroundColor: backgroundColor,
                            textColor: textColor,
                            isTablet: isTablet,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

// ===================== LOADING SCREEN =====================

class LoadingScreen extends StatelessWidget {
  final String message;
  final Color textColor;
  final bool isTablet;

  const LoadingScreen({
    Key? key,
    required this.message,
    required this.textColor,
    required this.isTablet,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(strokeWidth: isTablet ? 6 : 4),
          SizedBox(height: isTablet ? 24 : 16),
          Text(
            message,
            style: TextStyle(
              fontSize: isTablet ? 18 : 16,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== SURAH NAME DISPLAY =====================

class SurahNameDisplay extends StatelessWidget {
  final int currentPage;
  final QuranService quranService;
  final Color textColor;
  final bool isTablet;

  const SurahNameDisplay({
    Key? key,
    required this.currentPage,
    required this.quranService,
    required this.textColor,
    required this.isTablet,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final currentSurah = _getCurrentSurah();
    final surahInfo =
        currentSurah != null ? currentSurah.nameSimple : 'Page $currentPage';

    return Text(
      surahInfo,
      style: TextStyle(
        color: textColor,
        fontSize: isTablet ? 20 : 16,
        fontWeight: FontWeight.w600,
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Surah? _getCurrentSurah() {
    final pageData = quranService.allPagesData[currentPage];
    if (pageData == null || pageData.ayahs.isEmpty) return null;

    final surahCounts = <int, int>{};
    for (final ayah in pageData.ayahs) {
      surahCounts[ayah.surah] = (surahCounts[ayah.surah] ?? 0) + 1;
    }

    if (surahCounts.isEmpty) return null;

    int mainSurahId =
        surahCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return quranService.surahService.getSurahById(mainSurahId);
  }
}

// ===================== AUDIO BOTTOM BAR =====================

class AudioBottomBar extends StatelessWidget {
  final int currentPage;
  final int currentAyahIndex;
  final int? highlightedAyahIndex;
  final bool isLoading;
  final bool isPlaying;
  final List<PageAyah> ayahs;
  final VoidCallback onPlayPause;
  final Function(double) onProgressChanged;
  final VoidCallback onProgressStart;
  final VoidCallback onProgressEnd;
  final Color backgroundColor;
  final Color textColor;
  final bool isTablet;

  const AudioBottomBar({
    Key? key,
    required this.currentPage,
    required this.currentAyahIndex,
    required this.highlightedAyahIndex,
    required this.isLoading,
    required this.isPlaying,
    required this.ayahs,
    required this.onPlayPause,
    required this.onProgressChanged,
    required this.onProgressStart,
    required this.onProgressEnd,
    required this.backgroundColor,
    required this.textColor,
    required this.isTablet,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: isTablet ? 90 : 80,
      decoration: BoxDecoration(color: backgroundColor),
      padding: EdgeInsets.only(
        left: isTablet ? 20 : 16,
        right: isTablet ? 20 : 16,
        top: isTablet ? 16 : 14,
        bottom: isTablet ? 20 : 16,
      ),
      child: Row(
        children: [
          Container(
            width: isTablet ? 50 : 45,
            child: Text(
              '$currentPage/604',
              style: TextStyle(
                fontSize: isTablet ? 10 : 8,
                fontWeight: FontWeight.w500,
                color: textColor.withOpacity(0.7),
              ),
            ),
          ),
          SizedBox(width: isTablet ? 10 : 8),
          GestureDetector(
            onTap: ayahs.isNotEmpty ? onPlayPause : null,
            child: Container(
              width: isTablet ? 44 : 40,
              height: isTablet ? 44 : 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ayahs.isNotEmpty
                    ? textColor.withOpacity(0.05)
                    : textColor.withOpacity(0.05),
                border: Border.all(
                  color: ayahs.isNotEmpty
                      ? textColor.withOpacity(0.15)
                      : textColor.withOpacity(0.15),
                  width: 0.5,
                ),
              ),
              child: isLoading
                  ? SizedBox(
                      width: isTablet ? 16 : 14,
                      height: isTablet ? 16 : 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(textColor),
                      ),
                    )
                  : Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: isTablet ? 24 : 22,
                      color: textColor.withOpacity(0.5),
                    ),
            ),
          ),
          SizedBox(width: isTablet ? 12 : 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: isTablet ? 3 : 2,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: isTablet ? 8 : 6,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: isTablet ? 12 : 10,
                ),
                activeTrackColor: textColor.withOpacity(0.3),
                inactiveTrackColor: textColor.withOpacity(0.1),
                thumbColor: textColor.withOpacity(0.4),
                overlayColor: textColor.withOpacity(0.1),
              ),
              child: Slider(
                value: ayahs.isEmpty
                    ? 0.0
                    : (currentAyahIndex /
                        (ayahs.length - 1).clamp(1, double.infinity)),
                min: 0.0,
                max: 1.0,
                divisions: ayahs.length > 1 ? ayahs.length - 1 : 1,
                onChangeStart: (value) => onProgressStart(),
                onChanged: onProgressChanged,
                onChangeEnd: (value) => onProgressEnd(),
              ),
            ),
          ),
          SizedBox(width: isTablet ? 12 : 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (ayahs.isNotEmpty && highlightedAyahIndex != null)
                Text(
                  '${ayahs[highlightedAyahIndex!].surah}:${ayahs[highlightedAyahIndex!].ayah}',
                  style: TextStyle(
                    fontSize: isTablet ? 10 : 8,
                    fontWeight: FontWeight.w600,
                    color: textColor.withOpacity(0.7),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ===================== MUSHAF PAGE WIDGET =====================

class MushafPageWidget extends StatelessWidget {
  final int pageNumber;
  final QuranService quranService;
  final String? highlightedWordId;
  final String? userSelectedAyahId;
  final Function(String) onAyahTapped;
  final Map<int, double> uniformFontSizeCache;
  final Color backgroundColor;
  final Color textColor;
  final QuranThemeMode theme;
  final ViewMode viewMode;
  final bool areControlsVisible;

  const MushafPageWidget({
    Key? key,
    required this.pageNumber,
    required this.quranService,
    this.highlightedWordId,
    this.userSelectedAyahId,
    required this.onAyahTapped,
    required this.uniformFontSizeCache,
    required this.backgroundColor,
    required this.textColor,
    required this.theme,
    required this.viewMode,
    required this.areControlsVisible,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mushafPage = quranService.allPagesData[pageNumber];

    if (mushafPage == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Loading page $pageNumber...',
                style: TextStyle(fontSize: 16, color: textColor)),
          ],
        ),
      );
    }

    // Build the main content based on view mode
    Widget content;
    if (viewMode == ViewMode.translation) {
      content = _buildTranslationView(context, mushafPage);
    } else {
      content = _buildArabicView(context, mushafPage);
    }

    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final currentSurah = quranService.surahService.getSurahForPage(pageNumber);
    final surahName = currentSurah?.nameSimple ?? '';

    // Calculate consistent layout dimensions
    final appBarHeight = 32.0; // Very compact app bar height
    final bottomBarHeight = 32.0; // Match the compact app bar height
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;

    // For translation mode, return content directly (indicators are part of content)
    if (viewMode == ViewMode.translation) {
      return Container(
        padding: EdgeInsets.only(top: statusBarHeight),
        child: content,
      );
    }

    // For Arabic mode, use fixed layout with overlay indicators
    return Column(
      children: [
        // Top area (same as app bar area) - shows surah name when controls hidden
        Container(
          height: statusBarHeight + appBarHeight,
          width: double.infinity,
          child: areControlsVisible
              ? null // Empty when controls visible (app bar will cover this)
              : Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: statusBarHeight + 1),
                    child: Text(
                      surahName,
                      style: TextStyle(
                        color: textColor.withOpacity(0.6),
                        fontSize: isTablet ? 12 : 10,
                        fontWeight: FontWeight.w400,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
        ),

        // Main mushaf content - takes remaining space and centers content
        Expanded(
          child: Center(
            child: Container(
              margin: EdgeInsets.symmetric(vertical: isTablet ? 19.0 : 15.0),
              child: content,
            ),
          ),
        ),

        // Bottom area (same as bottom bar area) - shows page number when controls hidden
        Container(
          height: bottomBarHeight + bottomSafeArea,
          width: double.infinity,
          child: areControlsVisible
              ? null // Empty when controls visible (bottom bar will cover this)
              : Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomSafeArea + 1),
                    child: Text(
                      'Page $pageNumber',
                      style: TextStyle(
                        color: textColor.withOpacity(0.6),
                        fontSize: isTablet ? 12 : 10,
                        fontWeight: FontWeight.w400,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildArabicView(BuildContext context, MushafPage mushafPage) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(color: backgroundColor),
      padding: const EdgeInsets.all(4.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = screenSize.width > screenSize.height;
          final computedSize = _computeUniformFontSizeForPage(
            pageNumber,
            mushafPage,
            constraints.maxWidth,
            isTablet,
            isLandscape,
            screenSize,
          );
          uniformFontSizeCache[pageNumber] = computedSize;

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: mushafPage.lines
                .map((line) => _buildLine(
                    line, constraints, pageNumber, mushafPage, context))
                .toList(),
          );
        },
      ),
    );
  }

  /// Builds the translation view with proper positioning of basmallah, surah banners, and ayahs
  Widget _buildTranslationView(BuildContext context, MushafPage mushafPage) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final currentSurah = quranService.surahService.getSurahForPage(pageNumber);
    final surahName = currentSurah?.nameSimple ?? '';
    final statusBar = MediaQuery.of(context).padding.top;
    const double appBarHeightArabicMode = 32.0; // keep in sync with Arabic mode
    const double topBarHeight = 32.0; // overlay bar height (reduced)
    final double topSpacer = areControlsVisible
        ? (statusBar + topBarHeight)
        : (statusBar + appBarHeightArabicMode);

    // Get all ayahs from the page, excluding bismallah
    // No need for deduplication here as the PageAyah objects are already unique
    final uniqueAyahs = mushafPage.ayahs
        .where((ayah) => ayah.surah > 0 && ayah.ayah > 0 && !_isBismillah(ayah))
        .toList()
      ..sort((a, b) {
        if (a.surah != b.surah) return a.surah.compareTo(b.surah);
        return a.ayah.compareTo(b.ayah);
      });

    return Container(
      decoration: BoxDecoration(color: backgroundColor),
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isTablet ? 20 : 16),
        child: Column(
          children: [
            // Consistent top spacing and optional surah name when controls hidden
            SizedBox(height: topSpacer),
            if (!areControlsVisible) ...[
              Text(
                surahName,
                style: TextStyle(
                  color: textColor.withOpacity(0.6),
                  fontSize: isTablet ? 12 : 10,
                  fontWeight: FontWeight.w400,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: isTablet ? 19.0 : 15.0),
            ],

            // Main translation content
            ..._buildTranslationContent(
                mushafPage, uniqueAyahs, context, isTablet, screenSize),

            // Page number at the bottom of scrollable content
            if (!areControlsVisible) ...[
              SizedBox(height: 8),
              Text(
                'Page $pageNumber',
                style: TextStyle(
                  color: textColor.withOpacity(0.6),
                  fontSize: isTablet ? 10 : 8,
                  fontWeight: FontWeight.w400,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 4),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds translation content by processing lines in order to maintain exact positioning
  /// as in Mushaf mode, with proper basmallah and surah banner placement
  List<Widget> _buildTranslationContent(
      MushafPage mushafPage,
      List<PageAyah> uniqueAyahs,
      BuildContext context,
      bool isTablet,
      Size screenSize) {
    List<Widget> widgets = [];

    // Map ayahs by their start line number for quick lookup
    // Use a multimap since multiple ayahs could start on the same line
    final Map<int, List<PageAyah>> ayahsByStartLine = {};
    for (final ayah in uniqueAyahs) {
      ayahsByStartLine.putIfAbsent(ayah.startLineNumber, () => []).add(ayah);
    }

    // Sort ayahs within each start line by surah and ayah number
    ayahsByStartLine.forEach((lineNumber, ayahs) {
      ayahs.sort((a, b) {
        if (a.surah != b.surah) return a.surah.compareTo(b.surah);
        return a.ayah.compareTo(b.ayah);
      });
    });

    // Track which ayahs we've already processed
    final Set<String> processedAyahs = {};

    // Process lines in their original order to maintain correct positioning
    for (final line in mushafPage.lines) {
      if (line.lineType == 'surah_name') {
        // Always show surah banners when they appear
        widgets.add(
            _buildMushafLine(line, mushafPage, context, isTablet, screenSize));
      } else if (line.lineType == 'basmallah') {
        // Show basmallah only if it's followed by ayah 1 of a surah on this page
        bool shouldShow = false;
        for (final ayah in uniqueAyahs) {
          if (ayah.ayah == 1 && ayah.startLineNumber == line.lineNumber + 1) {
            shouldShow = true;
            break;
          }
        }
        if (shouldShow) {
          widgets.add(_buildMushafLine(
              line, mushafPage, context, isTablet, screenSize));
        }
      } else if (line.lineType == 'ayah') {
        // Check if this line is the start of any ayahs
        final ayahs = ayahsByStartLine[line.lineNumber];
        if (ayahs != null && ayahs.isNotEmpty) {
          // Process all ayahs that start on this line in sorted order
          for (final ayah in ayahs) {
            final ayahKey = '${ayah.surah}:${ayah.ayah}';
            if (!processedAyahs.contains(ayahKey)) {
              widgets.add(_buildAyahTranslation(ayah, isTablet, screenSize));
              processedAyahs.add(ayahKey);
            }
          }
        }
      }
    }

    // Add any remaining ayahs that weren't processed (safety check)
    // First, collect remaining ayahs
    final List<PageAyah> remainingAyahs = [];
    for (final ayah in uniqueAyahs) {
      final ayahKey = '${ayah.surah}:${ayah.ayah}';
      if (!processedAyahs.contains(ayahKey)) {
        remainingAyahs.add(ayah);
      }
    }

    // Sort remaining ayahs by surah first, then ayah number
    remainingAyahs.sort((a, b) {
      if (a.surah != b.surah) return a.surah.compareTo(b.surah);
      return a.ayah.compareTo(b.ayah);
    });

    // Add the sorted remaining ayahs
    for (final ayah in remainingAyahs) {
      widgets.add(_buildAyahTranslation(ayah, isTablet, screenSize));
    }

    return widgets;
  }

  Widget _buildMushafLine(SimpleMushafLine line, MushafPage mushafPage,
      BuildContext context, bool isTablet, Size screenSize) {
    final isLandscape = screenSize.width > screenSize.height;
    final uniformFontSize = uniformFontSizeCache[pageNumber];

    // Handle surah banners
    if (line.lineType == 'surah_name') {
      final surahNumber =
          int.tryParse(line.text.replaceAll('SURAH_BANNER_', ''));
      if (surahNumber != null) {
        return Container(
          margin: EdgeInsets.symmetric(vertical: isTablet ? 16 : 12),
          child: SurahBanner(
            surahNumber: surahNumber,
            isCentered: line.isCentered,
            theme: theme,
            maxWidth: screenSize.width,
          ),
        );
      }
    }

    // Handle basmallah
    if (line.lineType == 'basmallah') {
      return Container(
        margin: EdgeInsets.symmetric(vertical: isTablet ? 20 : 16),
        child: Center(
          child: uniformFontSize != null
              ? _buildBasmallahTextFixedSize(
                  line.text, uniformFontSize, 'QPCPageFont$pageNumber')
              : _buildBasmallahText(
                  line.text,
                  _getMaximizedFontSize(
                      line.lineType, isTablet, isLandscape, screenSize),
                  'QPCPageFont$pageNumber'),
        ),
      );
    }

    return SizedBox.shrink();
  }

  Widget _buildAyahTranslation(PageAyah ayah, bool isTablet, Size screenSize) {
    final translation =
        quranService.translationService.getTranslation(ayah.surah, ayah.ayah);
    final ayahId = '${ayah.surah}:${ayah.ayah}';
    final isSelected = userSelectedAyahId == ayahId;
    final isHighlighted = highlightedWordId?.startsWith(ayahId) ?? false;

    return Container(
      margin: EdgeInsets.only(bottom: isTablet ? 24 : 20),
      child: GestureDetector(
        onLongPress: () => onAyahTapped(ayahId),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 4 : 2,
            vertical: isTablet ? 8 : 6,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.blue.withOpacity(0.2)
                : isHighlighted
                    ? Colors.cyan.withOpacity(0.15)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Verse reference
              Padding(
                padding: EdgeInsets.only(bottom: isTablet ? 8 : 6),
                child: Row(
                  children: [
                    Text(
                      '${ayah.surah}:${ayah.ayah}',
                      style: TextStyle(
                        fontSize: isTablet ? 11 : 9,
                        fontWeight: FontWeight.w500,
                        color: textColor.withOpacity(0.5),
                      ),
                    ),
                    const Spacer(),
                    if (isHighlighted)
                      Icon(
                        Icons.volume_up,
                        size: isTablet ? 16 : 14,
                        color: textColor.withOpacity(0.7),
                      ),
                  ],
                ),
              ),

              // Arabic text
              _buildAyahTextForTranslation(
                  ayah, pageNumber, isTablet, screenSize),

              SizedBox(height: isTablet ? 12 : 10),

              // English translation
              if (translation != null)
                Text(
                  translation.text,
                  textAlign: TextAlign.justify,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: isTablet ? 18 : 16,
                    height: 1.6,
                    color: textColor.withOpacity(0.85),
                    fontWeight: FontWeight.w400,
                  ),
                )
              else
                Text(
                  'Translation not available',
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: isTablet ? 16 : 14,
                    color: textColor.withOpacity(0.4),
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isBismillah(PageAyah ayah) {
    // Bismillah is typically verse 1 of most surahs (except Al-Fatiha and At-Tawbah)
    // But it should be identified by its content or line type, not just verse number
    // For safety, we'll check if it's verse 1 and contains the bismillah text
    if (ayah.ayah == 1) {
      // Check if the text contains bismillah content
      return ayah.text.contains('بِسْمِ') || ayah.text.contains('﷽');
    }
    return false;
  }

  double _getAyahFontSize(bool isTablet, Size screenSize) {
    final isLandscape = screenSize.width > screenSize.height;
    final screenMultiplier =
        isTablet ? (isLandscape ? 1.8 : 1.5) : (isLandscape ? 1.3 : 1.0);
    final widthMultiplier = (screenSize.width / 400).clamp(0.8, 2.5);

    return 20.0 * screenMultiplier * widthMultiplier;
  }

  Widget _buildAyahTextForTranslation(
      PageAyah ayah, int pageNumber, bool isTablet, Size screenSize) {
    final baseFontSize = uniformFontSizeCache[pageNumber] ??
        _getAyahFontSize(isTablet, screenSize);
    final fontSize = baseFontSize +
        5.0; // Increase Arabic font size by 5px in translation mode

    // Find segments for this ayah to render with proper word spacing
    final mushafPage = quranService.allPagesData[pageNumber];
    if (mushafPage == null) {
      // Fallback to simple text rendering
      return Text(
        ayah.text,
        textAlign: TextAlign.right,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontFamily: 'QPCPageFont$pageNumber',
          fontSize: fontSize, // Uses the increased font size
          color: textColor,
          height: 1.8,
          shadows: [
            Shadow(offset: Offset(0.025, 0.025), color: textColor),
            Shadow(offset: Offset(-0.025, 0.025), color: textColor),
            Shadow(offset: Offset(0.025, -0.025), color: textColor),
            Shadow(offset: Offset(-0.025, -0.025), color: textColor),
          ],
        ),
      );
    }

    // Find segments for this specific ayah
    List<AyahSegment> ayahSegments = [];
    for (final segment in ayah.segments) {
      ayahSegments.add(segment);
    }

    if (ayahSegments.isEmpty) {
      // Fallback to simple text rendering
      return Text(
        ayah.text,
        textAlign: TextAlign.right,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontFamily: 'QPCPageFont$pageNumber',
          fontSize: fontSize, // Uses the increased font size
          color: textColor,
          height: 1.8,
          shadows: [
            Shadow(offset: Offset(0.025, 0.025), color: textColor),
            Shadow(offset: Offset(-0.025, 0.025), color: textColor),
            Shadow(offset: Offset(0.025, -0.025), color: textColor),
            Shadow(offset: Offset(-0.025, -0.025), color: textColor),
          ],
        ),
      );
    }

    // Build text with proper word spacing using segments
    List<InlineSpan> spans = [];

    for (final segment in ayahSegments) {
      final sortedWords = segment.words;

      for (int i = 0; i < sortedWords.length; i++) {
        final word = sortedWords[i];
        final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
        final isAudioHighlighted = highlightedWordId == wordId;

        spans.add(
          TextSpan(
            text: word.text,
            style: TextStyle(
              fontFamily: 'QPCPageFont$pageNumber',
              fontSize: fontSize,
              color: textColor,
              backgroundColor:
                  isAudioHighlighted ? Colors.yellow.withOpacity(0.6) : null,
              shadows: [
                Shadow(offset: Offset(0.025, 0.025), color: textColor),
                Shadow(offset: Offset(-0.025, 0.025), color: textColor),
                Shadow(offset: Offset(0.025, -0.025), color: textColor),
                Shadow(offset: Offset(-0.025, -0.025), color: textColor),
              ],
            ),
          ),
        );

        // Add thin space between words (except after the last word)
        if (i < sortedWords.length - 1) {
          spans.add(
            TextSpan(
              text: '\u2009', // Thin space
              style: TextStyle(
                fontFamily: 'QPCPageFont$pageNumber',
                fontSize: fontSize,
                color: textColor,
                shadows: [
                  Shadow(offset: Offset(0.025, 0.025), color: textColor),
                  Shadow(offset: Offset(-0.025, 0.025), color: textColor),
                  Shadow(offset: Offset(0.025, -0.025), color: textColor),
                  Shadow(offset: Offset(-0.025, -0.025), color: textColor),
                ],
              ),
            ),
          );
        }
      }
    }

    return RichText(
      textAlign: TextAlign.right,
      textDirection: TextDirection.rtl,
      text: TextSpan(children: spans),
    );
  }

  Widget _buildLine(SimpleMushafLine line, BoxConstraints constraints, int page,
      MushafPage mushafPage, BuildContext context) {
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
                    theme: theme,
                    maxWidth: MediaQuery.of(context).size.width,
                  ),
                );
              }
            }

            // Check if this line has ayah segments for word highlighting
            final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
            final double? uniformFontSize = uniformFontSizeCache[page];

            // Special formatting for different line types and pages
            if (line.lineType == 'basmallah') {
              return Center(
                child: uniformFontSize != null
                    ? _buildBasmallahTextFixedSize(
                        line.text, uniformFontSize, 'QPCPageFont$page')
                    : _buildBasmallahText(
                        line.text,
                        _getMaximizedFontSize(
                            line.lineType, isTablet, isLandscape, screenSize),
                        'QPCPageFont$page'),
              );
            }

            if (uniformFontSize != null) {
              return Center(
                child: segments.isNotEmpty
                    ? GestureDetector(
                        onLongPress: () => _handleLineTap(segments),
                        child: _buildHighlightableTextFixedSize(
                            line, segments, page, uniformFontSize, context),
                      )
                    : _buildTextWithThicknessFixedSize(
                        line.text, uniformFontSize, 'QPCPageFont$page'),
              );
            }

            return Container(
              width: double.infinity,
              child: segments.isNotEmpty
                  ? GestureDetector(
                      onLongPress: () => _handleLineTap(segments),
                      child: _buildHighlightableText(
                          line, segments, page, context),
                    )
                  : _buildTextWithThickness(
                      line.text,
                      _getMaximizedFontSize(
                          line.lineType, isTablet, isLandscape, screenSize),
                      'QPCPageFont$page'),
            );
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
                    theme: theme,
                    maxWidth: MediaQuery.of(context).size.width,
                  ),
                );
              }
            }

            // Check if this line has ayah segments for word highlighting
            final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
            final double? uniformFontSize = uniformFontSizeCache[page];

            // Special formatting for different line types and pages
            if (line.lineType == 'basmallah') {
              return Center(
                child: uniformFontSize != null
                    ? _buildBasmallahTextFixedSize(
                        line.text, uniformFontSize, 'QPCPageFont$page')
                    : _buildBasmallahText(
                        line.text,
                        _getMaximizedFontSize(
                            line.lineType, isTablet, isLandscape, screenSize),
                        'QPCPageFont$page'),
              );
            }

            if (uniformFontSize != null) {
              return Center(
                child: segments.isNotEmpty
                    ? GestureDetector(
                        onLongPress: () => _handleLineTap(segments),
                        child: _buildHighlightableTextFixedSize(
                            line, segments, page, uniformFontSize, context),
                      )
                    : _buildTextWithThicknessFixedSize(
                        line.text, uniformFontSize, 'QPCPageFont$page'),
              );
            }

            return Container(
              width: double.infinity,
              child: segments.isNotEmpty
                  ? GestureDetector(
                      onLongPress: () => _handleLineTap(segments),
                      child: _buildHighlightableText(
                          line, segments, page, context),
                    )
                  : _buildTextWithThickness(
                      line.text,
                      _getMaximizedFontSize(
                          line.lineType, isTablet, isLandscape, screenSize),
                      'QPCPageFont$page'),
            );
          },
        ),
      ),
    );
  }

  void _handleLineTap(List<AyahSegment> segments) {
    if (segments.isNotEmpty) {
      final firstSegment = segments.first;
      final ayah = _findAyahForSegment(firstSegment);
      if (ayah != null) {
        final ayahId = '${ayah.surah}:${ayah.ayah}';
        onAyahTapped(ayahId);
      }
    }
  }

  PageAyah? _findAyahForSegment(AyahSegment segment) {
    final page = quranService.allPagesData[pageNumber];
    if (page == null) return null;

    for (final ayah in page.ayahs) {
      if (ayah.segments.contains(segment)) {
        return ayah;
      }
    }
    return null;
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

    final heuristic =
        _getMaximizedFontSize('ayah', isTablet, isLandscape, screenSize);
    if (heuristic > low && heuristic < high) {
      high = heuristic * 1.5;
    }

    final String fontFamily = 'QPCPageFont$page';

    bool fitsAll(double size) {
      final double targetWidth = maxWidth - 8.0;
      for (final line in mushafPage.lines) {
        if (line.lineType == 'surah_name') continue;
        final String text = line.text;
        if (text.isEmpty) continue;

        String textToMeasure = text;
        if (line.lineType == 'ayah' || line.lineType == 'basmallah') {
          final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
          if (segments.isNotEmpty) {
            int totalWords = 0;
            for (final segment in segments) {
              totalWords += segment.words.length;
            }
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
            style: TextStyle(fontFamily: fontFamily, fontSize: size),
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

    double baseFontSize = 20.0 * screenMultiplier * widthMultiplier;

    switch (lineType) {
      case 'basmallah':
        return baseFontSize * 1.3;
      case 'surah_name':
        return baseFontSize * 1.1;
      case 'ayah':
      default:
        return baseFontSize;
    }
  }

  // Text rendering methods would continue here...
  // For brevity, I'll include the key methods

  Widget _buildHighlightableText(SimpleMushafLine line,
      List<AyahSegment> segments, int page, BuildContext context) {
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

      final isUserSelected = userSelectedAyahId == ayahId;

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
          final isAudioHighlighted = highlightedWordId == wordId;

          ayahSpans.add(
            TextSpan(
              text: word.text,
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: fontSize,
                color: textColor,
                backgroundColor:
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.6) : null,
                shadows: [
                  Shadow(
                    offset: Offset(0.025, 0.025),
                    color: textColor,
                  ),
                  Shadow(
                    offset: Offset(-0.025, 0.025),
                    color: textColor,
                  ),
                  Shadow(
                    offset: Offset(0.025, -0.025),
                    color: textColor,
                  ),
                  Shadow(
                    offset: Offset(-0.025, -0.025),
                    color: textColor,
                  ),
                ],
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
                  color: textColor,
                  shadows: [
                    Shadow(
                      offset: Offset(0.025, 0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(-0.025, 0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(0.025, -0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(-0.025, -0.025),
                      color: textColor,
                    ),
                  ],
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
            onLongPress: () => onAyahTapped(ayahId),
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

  Widget _buildHighlightableTextFixedSize(
      SimpleMushafLine line,
      List<AyahSegment> segments,
      int page,
      double fontSize,
      BuildContext context) {
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

      final isUserSelected = userSelectedAyahId == ayahId;

      List<InlineSpan> ayahSpans = [];
      for (final segment in ayahSegments) {
        final ayah = _findAyahForSegment(segment);
        if (ayah == null) continue;
        final sortedWords = segment.words;
        for (int i = 0; i < sortedWords.length; i++) {
          final word = sortedWords[i];
          final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
          final isAudioHighlighted = highlightedWordId == wordId;
          ayahSpans.add(
            TextSpan(
              text: word.text,
              style: TextStyle(
                fontFamily: 'QPCPageFont$page',
                fontSize: fontSize,
                color: textColor,
                backgroundColor:
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.6) : null,
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
                  color: textColor,
                  shadows: [
                    Shadow(
                      offset: Offset(0.025, 0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(-0.025, 0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(0.025, -0.025),
                      color: textColor,
                    ),
                    Shadow(
                      offset: Offset(-0.025, -0.025),
                      color: textColor,
                    ),
                  ],
                ),
              ),
            );
          }
        }
      }

      spans.add(
        WidgetSpan(
          child: GestureDetector(
            onLongPress: () => onAyahTapped(ayahId),
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

  Widget _buildTextWithThickness(
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color? textColorOverride}) {
    final actualTextColor = textColorOverride ?? textColor;

    Widget textWidget = Container(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Stack(
          children: [
            // Overlay text for thickness effect
            Text(
              text,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              maxLines: 1,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                color: actualTextColor,
                shadows: [
                  Shadow(
                    offset: Offset(0.025, 0.025),
                    color: actualTextColor,
                  ),
                  Shadow(
                    offset: Offset(-0.025, 0.025),
                    color: actualTextColor,
                  ),
                  Shadow(
                    offset: Offset(0.025, -0.025),
                    color: actualTextColor,
                  ),
                  Shadow(
                    offset: Offset(-0.025, -0.025),
                    color: actualTextColor,
                  ),
                ],
              ),
            ),
            // Main text
            Text(
              text,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              maxLines: 1,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                color: actualTextColor,
              ),
            ),
          ],
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
      {Color? backgroundColor, Color? textColorOverride}) {
    final actualTextColor = textColorOverride ?? textColor;

    Widget textWidget = Container(
      width: double.infinity,
      child: Stack(
        children: [
          // Overlay text for thickness effect
          Text(
            text,
            textAlign: TextAlign.center,
            textDirection: TextDirection.rtl,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: actualTextColor,
              shadows: [
                Shadow(
                  offset: Offset(0.025, 0.025),
                  color: actualTextColor,
                ),
                Shadow(
                  offset: Offset(-0.025, 0.025),
                  color: actualTextColor,
                ),
                Shadow(
                  offset: Offset(0.025, -0.025),
                  color: actualTextColor,
                ),
                Shadow(
                  offset: Offset(-0.025, -0.025),
                  color: actualTextColor,
                ),
              ],
            ),
          ),
          // Main text
          Text(
            text,
            textAlign: TextAlign.center,
            textDirection: TextDirection.rtl,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: actualTextColor,
            ),
          ),
        ],
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

  Widget _buildBasmallahText(String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color? textColorOverride}) {
    final actualTextColor = textColorOverride ?? textColor;

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
            color: actualTextColor,
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

  Widget _buildBasmallahTextFixedSize(
      String text, double fontSize, String fontFamily,
      {Color? backgroundColor, Color? textColorOverride}) {
    final actualTextColor = textColorOverride ?? textColor;

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
          color: actualTextColor,
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
}
