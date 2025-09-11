import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Import services
import 'quran_service.dart';
import 'audio_service.dart';
import 'surah_header_banner.dart';
import 'theme.dart';

// ===================== VIEW MODES =====================

enum ViewMode { arabic, translation }

// ===================== CONSTANTS =====================

class _Constants {
  static const double topBarHeight = 32.0;
  static const int totalPages = 604;
  static const String thinSpace = '\u2009';
  static const Duration animationDuration = Duration(milliseconds: 300);
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
  // Core state
  int _currentPage = 1;
  bool _isInitializing = true;
  String _loadingMessage = 'Initializing...';
  bool _isDisposed = false;

  // Services
  late final QuranService _quranService;
  final AudioService _audioService = AudioService();

  // Audio state
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;
  String? _userSelectedAyahId;
  bool _audioInitialized = false;
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
  late AnimationController _controlsAnimationController;
  bool _areControlsVisible = true;

  @override
  void initState() {
    super.initState();
    _initializeState();
    _initializeApp();
  }

  void _initializeState() {
    _currentTheme = widget.initialTheme ?? QuranThemeMode.normal;
    _quranService = widget.quranService ?? QuranService();

    _controlsAnimationController = AnimationController(
      vsync: this,
      duration: _Constants.animationDuration,
    )..value = 1.0;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final initialPage = _calculateInitialPage();
    _pageController = PageController(initialPage: initialPage);
  }

  int _calculateInitialPage() {
    const defaultPage = _Constants.totalPages - 1; // Last page index

    if (widget.initialPageNumber != null) {
      final pageNumber = widget.initialPageNumber!;
      if (pageNumber >= 1 && pageNumber <= _Constants.totalPages) {
        _currentPage = pageNumber;
        return _Constants.totalPages - pageNumber;
      }
    } else if (widget.initialSurahId != null) {
      final startPage =
          _quranService.surahService.getSurahStartPage(widget.initialSurahId!);
      if (startPage != null) {
        _currentPage = startPage;
        return _Constants.totalPages - startPage;
      }
    }

    return defaultPage;
  }

  Future<void> _initializeApp() async {
    try {
      if (widget.quranService?.isInitialized == true) {
        await _loadInitialPage();
        return;
      }

      await _performInitialSetup();
    } catch (e) {
      _handleInitializationError(e);
    }
  }

  Future<void> _loadInitialPage() async {
    await _quranService.getPage(_currentPage);
    if (mounted) {
      setState(() => _isInitializing = false);
      _startBackgroundPreloading();
    }
  }

  Future<void> _performInitialSetup() async {
    setState(() {
      _isInitializing = true;
      _loadingMessage = 'Loading page...';
    });

    await _quranService.initialize();
    await _quranService.getPage(_currentPage);

    if (mounted) {
      setState(() => _isInitializing = false);
      _initializeRemainingResourcesInBackground();
    }
  }

  void _handleInitializationError(dynamic error) {
    print('Initialization error: $error');
    if (mounted) {
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $error';
      });
    }
  }

  void _initializeRemainingResourcesInBackground() {
    Future.microtask(() async {
      if (_isDisposed) return;

      try {
        await Future.wait([
          _quranService.preloadAllFonts(),
          SurahBanner.preload(),
          _initAudio(),
        ]);

        if (!_isDisposed) {
          await _quranService.preloadPagesAroundCurrent(_currentPage);
          await _quranService.buildSurahMapping();
          _startBackgroundPreloading();
        }
      } catch (e) {
        print('Background initialization error: $e');
      }
    });
  }

  Future<void> _initAudio() async {
    if (_audioInitialized || _isDisposed) return;

    await _audioService.initialize();
    _setupAudioListeners();
    _audioInitialized = true;
  }

  void _setupAudioListeners() {
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
        setState(() => _highlightedWordId = wordId);
      }
    });

    _audioService.currentAyahStream.listen((ayah) {
      if (mounted && ayah != null) {
        _updateCurrentAyahIndex(ayah);
      }
    });
  }

  void _updateCurrentAyahIndex(dynamic ayah) {
    final ayahs = _getCurrentPageAyahs();
    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == ayah.surah && ayahs[i].ayah == ayah.ayah) {
        setState(() {
          _currentAyahIndex = i;
          _highlightedAyahIndex = i;
        });
        break;
      }
    }
  }

  Future<void> _startBackgroundPreloading() async {
    Future.microtask(() async {
      try {
        if (!_isDisposed) {
          await _quranService.preloadPagesAroundCurrent(_currentPage);
        }

        if (!_isDisposed) {
          await _preloadCommonPages();
        }

        await _preloadRemainingPages();
      } catch (e) {
        print('Background preloading error: $e');
      }
    });
  }

  Future<void> _preloadCommonPages() async {
    const commonPages = [1, 2, 50, 77, 102, 128, 151, 177, 187, 201, 221, 235];
    final pagesToLoad = commonPages
        .where((page) => !_quranService.allPagesData.containsKey(page))
        .toList();

    if (pagesToLoad.isNotEmpty) {
      await Future.wait(pagesToLoad.map((page) => _quranService.getPage(page)));
    }
  }

  Future<void> _preloadRemainingPages() async {
    for (int page = 1; page <= _Constants.totalPages; page++) {
      if (_isDisposed) break;

      if (!_quranService.allPagesData.containsKey(page)) {
        try {
          await _quranService.getPage(page);
          if (page % 20 == 0) {
            await Future.delayed(const Duration(milliseconds: 5));
          }
        } catch (e) {
          print('Background loading stopped at page $page: $e');
          break;
        }
      }
    }
  }

  void _onPageChanged(int index) {
    final page = _Constants.totalPages - index;
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
    final parts = ayahId.split(':');
    if (parts.length != 2) return;

    final surah = int.tryParse(parts[0]);
    final ayah = int.tryParse(parts[1]);
    if (surah == null || ayah == null) return;

    final ayahs = _getCurrentPageAyahs();
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

  void _playAyah(PageAyah ayah) {
    final ayahs = _getCurrentPageAyahs();
    for (int i = 0; i < ayahs.length; i++) {
      if (ayahs[i].surah == ayah.surah && ayahs[i].ayah == ayah.ayah) {
        setState(() {
          _currentAyahIndex = i;
          _highlightedAyahIndex = i;
        });
        _togglePlayPause();
        break;
      }
    }
  }

  void _copyAyahToClipboard(PageAyah ayah) {
    final translation =
        _quranService.translationService.getTranslation(ayah.surah, ayah.ayah);
    final textToCopy =
        translation != null ? '${ayah.text}\n\n${translation.text}' : ayah.text;

    Clipboard.setData(ClipboardData(text: textToCopy));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Ayah ${ayah.surah}:${ayah.ayah} copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _togglePlayPause() async {
    final ayahs = _getCurrentPageAyahs();
    if (ayahs.isEmpty) return;

    setState(() => _isLoading = true);

    if (!_audioInitialized) {
      await _initAudio();
    }

    try {
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
    } catch (e) {
      setState(() => _isLoading = false);
      print('Audio toggle error: $e');
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
    if (_controlsAnimationController.isAnimating) return;

    setState(() {
      _areControlsVisible = !_areControlsVisible;
      if (_areControlsVisible) {
        _controlsAnimationController.forward();
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        _controlsAnimationController.reverse();
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
    _isDisposed = true;
    _pageController.dispose();

    if (widget.quranService == null) {
      _quranService.dispose();
    }

    _audioService.reset();
    _controlsAnimationController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return _buildLoadingScreen();
    }

    return _buildMainContent();
  }

  Widget _buildLoadingScreen() {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final textColor = QuranTheme.getTextColor(_currentTheme);
    final backgroundColor = QuranTheme.getBackgroundColor(_currentTheme);

    return Scaffold(
      backgroundColor: backgroundColor,
      body: LoadingScreen(
        message: _loadingMessage,
        textColor: textColor,
        isTablet: isTablet,
      ),
    );
  }

  Widget _buildMainContent() {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final textColor = QuranTheme.getTextColor(_currentTheme);
    final backgroundColor = QuranTheme.getBackgroundColor(_currentTheme);
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    final bottomBarHeight = isTablet ? 90.0 : 80.0;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Stack(
        children: [
          _buildPageView(),
          _buildTopBar(statusBarHeight, textColor, backgroundColor, isTablet),
          _buildBottomBar(bottomBarHeight, bottomSafeArea, backgroundColor,
              textColor, isTablet),
        ],
      ),
    );
  }

  Widget _buildPageView() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: _toggleControlsVisibility,
        behavior: HitTestBehavior.translucent,
        child: PageView.builder(
          controller: _pageController,
          itemCount: _Constants.totalPages,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) {
            final page = _Constants.totalPages - index;
            return _buildPage(page);
          },
        ),
      ),
    );
  }

  Widget _buildPage(int page) {
    final textColor = QuranTheme.getTextColor(_currentTheme);
    final backgroundColor = QuranTheme.getBackgroundColor(_currentTheme);

    return MushafPageWidget(
      pageNumber: page,
      quranService: _quranService,
      highlightedWordId: _highlightedWordId,
      userSelectedAyahId: _userSelectedAyahId,
      onAyahTapped: (ayahId) {
        setState(() {
          _userSelectedAyahId = _userSelectedAyahId == ayahId ? null : ayahId;
        });
        _seekToAyahFromId(ayahId);
      },
      uniformFontSizeCache: _uniformFontSizeCache,
      backgroundColor: backgroundColor,
      textColor: textColor,
      theme: _currentTheme,
      viewMode: _currentViewMode,
      areControlsVisible: _areControlsVisible,
      onPlayAyah: _playAyah,
      onCopyAyah: _copyAyahToClipboard,
    );
  }

  Widget _buildTopBar(double statusBarHeight, Color textColor,
      Color backgroundColor, bool isTablet) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: _controlsAnimationController,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(
              0,
              -(statusBarHeight + _Constants.topBarHeight) *
                  (1 - _controlsAnimationController.value),
            ),
            child: Opacity(
              opacity: _controlsAnimationController.value,
              child: Container(
                height: statusBarHeight + _Constants.topBarHeight,
                color: backgroundColor,
                child: Padding(
                  padding: EdgeInsets.only(top: statusBarHeight),
                  child: _buildTopBarContent(textColor, isTablet),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBarContent(Color textColor, bool isTablet) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(Icons.arrow_back, color: textColor, size: 20),
          tooltip: 'Back',
        ),
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
    );
  }

  Widget _buildBottomBar(double bottomBarHeight, double bottomSafeArea,
      Color backgroundColor, Color textColor, bool isTablet) {
    return Positioned(
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
                  (1 - _controlsAnimationController.value),
            ),
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
                onProgressChanged: (value) {
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
                },
                onProgressStart: () => setState(() => _isDragging = true),
                onProgressEnd: () => setState(() => _isDragging = false),
                backgroundColor: backgroundColor,
                textColor: textColor,
                isTablet: isTablet,
              ),
            ),
          );
        },
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
          _buildPageIndicator(),
          SizedBox(width: isTablet ? 10 : 8),
          _buildPlayButton(),
          SizedBox(width: isTablet ? 12 : 8),
          _buildProgressSlider(context),
          SizedBox(width: isTablet ? 12 : 8),
          _buildAyahIndicator(),
        ],
      ),
    );
  }

  Widget _buildPageIndicator() {
    return SizedBox(
      width: isTablet ? 50 : 45,
      child: Text(
        '$currentPage/${_Constants.totalPages}',
        style: TextStyle(
          fontSize: isTablet ? 10 : 8,
          fontWeight: FontWeight.w500,
          color: textColor.withOpacity(0.7),
        ),
      ),
    );
  }

  Widget _buildPlayButton() {
    return GestureDetector(
      onTap: ayahs.isNotEmpty ? onPlayPause : null,
      child: Container(
        width: isTablet ? 44 : 40,
        height: isTablet ? 44 : 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: textColor.withOpacity(0.05),
          border: Border.all(
            color: textColor.withOpacity(0.15),
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
    );
  }

  Widget _buildProgressSlider(BuildContext context) {
    return Expanded(
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
    );
  }

  Widget _buildAyahIndicator() {
    return Column(
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
  final Function(PageAyah) onPlayAyah;
  final Function(PageAyah) onCopyAyah;

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
    required this.onPlayAyah,
    required this.onCopyAyah,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mushafPage = quranService.allPagesData[pageNumber];

    if (mushafPage == null) {
      return _buildLoadingIndicator();
    }

    return viewMode == ViewMode.translation
        ? _buildTranslationView(context, mushafPage)
        : _buildArabicView(context, mushafPage);
  }

  Widget _buildLoadingIndicator() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Loading page $pageNumber...',
            style: TextStyle(fontSize: 16, color: textColor),
          ),
        ],
      ),
    );
  }

  Widget _buildArabicView(BuildContext context, MushafPage mushafPage) {
    return _ArabicPageLayout(
      pageNumber: pageNumber,
      mushafPage: mushafPage,
      backgroundColor: backgroundColor,
      textColor: textColor,
      areControlsVisible: areControlsVisible,
      theme: theme,
      uniformFontSizeCache: uniformFontSizeCache,
      highlightedWordId: highlightedWordId,
      userSelectedAyahId: userSelectedAyahId,
      onAyahTapped: onAyahTapped,
      onPlayAyah: onPlayAyah,
      onCopyAyah: onCopyAyah,
      quranService: quranService,
    );
  }

  Widget _buildTranslationView(BuildContext context, MushafPage mushafPage) {
    return _TranslationPageLayout(
      pageNumber: pageNumber,
      mushafPage: mushafPage,
      backgroundColor: backgroundColor,
      textColor: textColor,
      areControlsVisible: areControlsVisible,
      theme: theme,
      highlightedWordId: highlightedWordId,
      userSelectedAyahId: userSelectedAyahId,
      onAyahTapped: onAyahTapped,
      onPlayAyah: onPlayAyah,
      onCopyAyah: onCopyAyah,
      quranService: quranService,
    );
  }
}

// ===================== ARABIC PAGE LAYOUT =====================

class _ArabicPageLayout extends StatelessWidget {
  final int pageNumber;
  final MushafPage mushafPage;
  final Color backgroundColor;
  final Color textColor;
  final bool areControlsVisible;
  final QuranThemeMode theme;
  final Map<int, double> uniformFontSizeCache;
  final String? highlightedWordId;
  final String? userSelectedAyahId;
  final Function(String) onAyahTapped;
  final Function(PageAyah) onPlayAyah;
  final Function(PageAyah) onCopyAyah;
  final QuranService quranService;

  const _ArabicPageLayout({
    required this.pageNumber,
    required this.mushafPage,
    required this.backgroundColor,
    required this.textColor,
    required this.areControlsVisible,
    required this.theme,
    required this.uniformFontSizeCache,
    required this.highlightedWordId,
    required this.userSelectedAyahId,
    required this.onAyahTapped,
    required this.onPlayAyah,
    required this.onCopyAyah,
    required this.quranService,
  });

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final currentSurah = quranService.surahService.getSurahForPage(pageNumber);
    final surahName = currentSurah?.nameSimple ?? '';
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;

    return Column(
      children: [
        _buildTopIndicator(statusBarHeight, surahName, isTablet),
        _buildMainContent(context, isTablet, screenSize),
        _buildBottomIndicator(bottomSafeArea, isTablet),
      ],
    );
  }

  Widget _buildTopIndicator(
      double statusBarHeight, String surahName, bool isTablet) {
    return Container(
      height: statusBarHeight + _Constants.topBarHeight,
      width: double.infinity,
      child: areControlsVisible
          ? null
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
    );
  }

  Widget _buildMainContent(
      BuildContext context, bool isTablet, Size screenSize) {
    return Expanded(
      child: Center(
        child: Container(
          margin: EdgeInsets.symmetric(vertical: isTablet ? 19.0 : 15.0),
          padding: const EdgeInsets.all(4.0),
          decoration: BoxDecoration(color: backgroundColor),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = screenSize.width > screenSize.height;
              final computedSize = _computeUniformFontSizeForPage(
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
                    .map((line) => _buildLine(line, constraints, context,
                        isTablet, isLandscape, screenSize, computedSize))
                    .toList(),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBottomIndicator(double bottomSafeArea, bool isTablet) {
    return Container(
      height: _Constants.topBarHeight + bottomSafeArea,
      width: double.infinity,
      child: areControlsVisible
          ? null
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
    );
  }

  Widget _buildLine(
      SimpleMushafLine line,
      BoxConstraints constraints,
      BuildContext context,
      bool isTablet,
      bool isLandscape,
      Size screenSize,
      double uniformFontSize) {
    final isFirstTwoPages = pageNumber <= 2;
    final lineWidget = Container(
      width: double.infinity,
      child: _buildLineContent(
          line, context, isTablet, isLandscape, screenSize, uniformFontSize),
    );

    return isFirstTwoPages ? lineWidget : Expanded(flex: 1, child: lineWidget);
  }

  Widget _buildLineContent(
      SimpleMushafLine line,
      BuildContext context,
      bool isTablet,
      bool isLandscape,
      Size screenSize,
      double uniformFontSize) {
    if (line.lineType == 'surah_name') {
      final surahNumber =
          int.tryParse(line.text.replaceAll('SURAH_BANNER_', ''));
      if (surahNumber != null) {
        return SurahBanner(
          surahNumber: surahNumber,
          isCentered: line.isCentered,
          theme: theme,
          maxWidth: MediaQuery.of(context).size.width,
        );
      }
    }

    final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
    final fontFamily = 'QPCPageFont$pageNumber';

    if (line.lineType == 'basmallah') {
      return Center(
        child: _TextRenderer.buildBasmallah(
            line.text, uniformFontSize, fontFamily, textColor),
      );
    }

    return Center(
      child: segments.isNotEmpty
          ? _buildHighlightableLine(
              line, segments, uniformFontSize, fontFamily, context, isTablet)
          : _TextRenderer.buildRegularText(
              line.text, uniformFontSize, fontFamily, textColor),
    );
  }

  Widget _buildHighlightableLine(
      SimpleMushafLine line,
      List<AyahSegment> segments,
      double fontSize,
      String fontFamily,
      BuildContext context,
      bool isTablet) {
    return GestureDetector(
      onLongPress: () => _handleLineTap(segments),
      child: _HighlightableTextBuilder.build(
        line: line,
        segments: segments,
        pageNumber: pageNumber,
        fontSize: fontSize,
        fontFamily: fontFamily,
        textColor: textColor,
        highlightedWordId: highlightedWordId,
        userSelectedAyahId: userSelectedAyahId,
        onAyahContextMenu: (ayah, ayahId, position) =>
            _showAyahContextMenu(context, ayah, ayahId, isTablet, position),
        quranService: quranService,
      ),
    );
  }

  void _handleLineTap(List<AyahSegment> segments) {
    if (segments.isNotEmpty) {
      final ayah = _findAyahForSegment(segments.first);
      if (ayah != null) {
        onAyahTapped('${ayah.surah}:${ayah.ayah}');
      }
    }
  }

  PageAyah? _findAyahForSegment(AyahSegment segment) {
    for (final ayah in mushafPage.ayahs) {
      if (ayah.segments.contains(segment)) return ayah;
    }
    return null;
  }

  double _computeUniformFontSizeForPage(
      double maxWidth, bool isTablet, bool isLandscape, Size screenSize) {
    if (uniformFontSizeCache.containsKey(pageNumber)) {
      return uniformFontSizeCache[pageNumber]!;
    }

    double low = 8.0;
    double high = 300.0;

    final heuristic = _FontSizeCalculator.getMaximizedFontSize(
        'ayah', isTablet, isLandscape, screenSize);
    if (heuristic > low && heuristic < high) {
      high = heuristic * 1.5;
    }

    final fontFamily = 'QPCPageFont$pageNumber';
    final targetWidth = maxWidth - 8.0;

    bool fitsAll(double size) {
      for (final line in mushafPage.lines) {
        if (line.lineType == 'surah_name' || line.text.isEmpty) continue;

        if (!_FontSizeCalculator.textFitsWidth(
            line, mushafPage, size, fontFamily, targetWidth)) {
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

  void _showAyahContextMenu(BuildContext context, PageAyah ayah, String ayahId,
      bool isTablet, Offset position) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'highlight',
          child: Row(
            children: [
              Icon(Icons.highlight, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Highlight', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Copy', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'play',
          child: Row(
            children: [
              Icon(Icons.play_arrow, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Play', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
      ],
    ).then((String? value) {
      if (value != null) {
        _handleAyahContextAction(value, ayah, ayahId);
      }
    });
  }

  void _handleAyahContextAction(String action, PageAyah ayah, String ayahId) {
    switch (action) {
      case 'highlight':
        onAyahTapped(ayahId);
        break;
      case 'copy':
        onCopyAyah(ayah);
        break;
      case 'play':
        onPlayAyah(ayah);
        break;
    }
  }
}

// ===================== TRANSLATION PAGE LAYOUT =====================

class _TranslationPageLayout extends StatelessWidget {
  final int pageNumber;
  final MushafPage mushafPage;
  final Color backgroundColor;
  final Color textColor;
  final bool areControlsVisible;
  final QuranThemeMode theme;
  final String? highlightedWordId;
  final String? userSelectedAyahId;
  final Function(String) onAyahTapped;
  final Function(PageAyah) onPlayAyah;
  final Function(PageAyah) onCopyAyah;
  final QuranService quranService;

  const _TranslationPageLayout({
    required this.pageNumber,
    required this.mushafPage,
    required this.backgroundColor,
    required this.textColor,
    required this.areControlsVisible,
    required this.theme,
    required this.highlightedWordId,
    required this.userSelectedAyahId,
    required this.onAyahTapped,
    required this.onPlayAyah,
    required this.onCopyAyah,
    required this.quranService,
  });

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final currentSurah = quranService.surahService.getSurahForPage(pageNumber);
    final surahName = currentSurah?.nameSimple ?? '';
    final statusBar = MediaQuery.of(context).padding.top;
    final topSpacer = areControlsVisible
        ? (statusBar + _Constants.topBarHeight)
        : (statusBar + _Constants.topBarHeight);

    final uniqueAyahs = _getUniqueAyahs();

    return Container(
      decoration: BoxDecoration(color: backgroundColor),
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isTablet ? 20 : 16),
        child: Column(
          children: [
            SizedBox(height: topSpacer),
            if (!areControlsVisible) ...[
              _buildSurahName(surahName, isTablet),
              SizedBox(height: isTablet ? 19.0 : 15.0),
            ],
            ..._buildTranslationContent(
                uniqueAyahs, context, isTablet, screenSize),
            if (!areControlsVisible) ...[
              const SizedBox(height: 8),
              _buildPageNumber(isTablet),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 4),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSurahName(String surahName, bool isTablet) {
    return Text(
      surahName,
      style: TextStyle(
        color: textColor.withOpacity(0.6),
        fontSize: isTablet ? 12 : 10,
        fontWeight: FontWeight.w400,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildPageNumber(bool isTablet) {
    return Text(
      'Page $pageNumber',
      style: TextStyle(
        color: textColor.withOpacity(0.6),
        fontSize: isTablet ? 10 : 8,
        fontWeight: FontWeight.w400,
      ),
      textAlign: TextAlign.center,
    );
  }

  List<PageAyah> _getUniqueAyahs() {
    return mushafPage.ayahs
        .where((ayah) => ayah.surah > 0 && ayah.ayah > 0 && !_isBismillah(ayah))
        .toList()
      ..sort((a, b) {
        if (a.surah != b.surah) return a.surah.compareTo(b.surah);
        return a.ayah.compareTo(b.ayah);
      });
  }

  List<Widget> _buildTranslationContent(List<PageAyah> uniqueAyahs,
      BuildContext context, bool isTablet, Size screenSize) {
    List<Widget> widgets = [];

    final ayahsByStartLine = <int, List<PageAyah>>{};
    for (final ayah in uniqueAyahs) {
      ayahsByStartLine.putIfAbsent(ayah.startLineNumber, () => []).add(ayah);
    }

    ayahsByStartLine.forEach((lineNumber, ayahs) {
      ayahs.sort((a, b) {
        if (a.surah != b.surah) return a.surah.compareTo(b.surah);
        return a.ayah.compareTo(b.ayah);
      });
    });

    final processedAyahs = <String>{};

    for (final line in mushafPage.lines) {
      if (line.lineType == 'surah_name') {
        widgets.add(_buildMushafLine(line, context, isTablet, screenSize));
      } else if (line.lineType == 'basmallah') {
        if (_shouldShowBasmallah(uniqueAyahs, line.lineNumber)) {
          widgets.add(_buildMushafLine(line, context, isTablet, screenSize));
        }
      } else if (line.lineType == 'ayah') {
        final ayahs = ayahsByStartLine[line.lineNumber];
        if (ayahs != null && ayahs.isNotEmpty) {
          for (final ayah in ayahs) {
            final ayahKey = '${ayah.surah}:${ayah.ayah}';
            if (!processedAyahs.contains(ayahKey)) {
              widgets.add(
                  _buildAyahTranslation(context, ayah, isTablet, screenSize));
              processedAyahs.add(ayahKey);
            }
          }
        }
      }
    }

    // Add any remaining ayahs
    final remainingAyahs = uniqueAyahs
        .where((ayah) => !processedAyahs.contains('${ayah.surah}:${ayah.ayah}'))
        .toList()
      ..sort((a, b) {
        if (a.surah != b.surah) return a.surah.compareTo(b.surah);
        return a.ayah.compareTo(b.ayah);
      });

    for (final ayah in remainingAyahs) {
      widgets.add(_buildAyahTranslation(context, ayah, isTablet, screenSize));
    }

    return widgets;
  }

  bool _shouldShowBasmallah(List<PageAyah> uniqueAyahs, int lineNumber) {
    for (final ayah in uniqueAyahs) {
      if (ayah.ayah == 1 && ayah.startLineNumber == lineNumber + 1) {
        return true;
      }
    }
    return false;
  }

  Widget _buildMushafLine(SimpleMushafLine line, BuildContext context,
      bool isTablet, Size screenSize) {
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

    if (line.lineType == 'basmallah') {
      return Container(
        margin: EdgeInsets.symmetric(vertical: isTablet ? 20 : 16),
        child: Center(
          child: _TextRenderer.buildBasmallah(
            line.text,
            _FontSizeCalculator.getMaximizedFontSize('basmallah', isTablet,
                screenSize.width > screenSize.height, screenSize),
            'QPCPageFont$pageNumber',
            textColor,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildAyahTranslation(
      BuildContext context, PageAyah ayah, bool isTablet, Size screenSize) {
    final translation =
        quranService.translationService.getTranslation(ayah.surah, ayah.ayah);
    final ayahId = '${ayah.surah}:${ayah.ayah}';
    final isSelected = userSelectedAyahId == ayahId;
    final isHighlighted = highlightedWordId?.startsWith(ayahId) ?? false;

    return Container(
      margin: EdgeInsets.only(bottom: isTablet ? 24 : 20),
      child: GestureDetector(
        onLongPressStart: (details) => _showAyahContextMenu(
            context, ayah, ayahId, isTablet, details.globalPosition),
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
            border: Border(
              bottom: BorderSide(
                color: textColor.withOpacity(0.1),
                width: 1.0,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildVerseReference(ayah, isTablet, isHighlighted),
              _buildAyahTextForTranslation(ayah, isTablet, screenSize),
              SizedBox(height: isTablet ? 12 : 10),
              _buildTranslationText(translation, isTablet),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerseReference(
      PageAyah ayah, bool isTablet, bool isHighlighted) {
    return Padding(
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
    );
  }

  Widget _buildAyahTextForTranslation(
      PageAyah ayah, bool isTablet, Size screenSize) {
    final fontSize = isTablet ? 28.0 : 24.0;
    final fontFamily = 'QPCPageFont$pageNumber';

    if (ayah.segments.isEmpty) {
      return Text(
        ayah.text,
        textAlign: TextAlign.right,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          color: Colors.black,
          height: 1.8,
        ),
      );
    }

    return _HighlightableTextBuilder.buildForTranslation(
      segments: ayah.segments,
      fontSize: fontSize,
      fontFamily: fontFamily,
      textColor: Colors.black,
      highlightedWordId: highlightedWordId,
      surahNumber: ayah.surah,
      ayahNumber: ayah.ayah,
    );
  }

  Widget _buildTranslationText(Translation? translation, bool isTablet) {
    if (translation != null) {
      return Text(
        translation.text,
        textAlign: TextAlign.justify,
        textDirection: TextDirection.ltr,
        style: TextStyle(
          fontSize: isTablet ? 18 : 16,
          height: 1.6,
          color: textColor.withOpacity(0.85),
          fontWeight: FontWeight.w400,
        ),
      );
    } else {
      return Text(
        'Translation not available',
        textAlign: TextAlign.left,
        style: TextStyle(
          fontSize: isTablet ? 16 : 14,
          color: textColor.withOpacity(0.4),
          fontStyle: FontStyle.italic,
        ),
      );
    }
  }

  void _showAyahContextMenu(BuildContext context, PageAyah ayah, String ayahId,
      bool isTablet, Offset position) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'highlight',
          child: Row(
            children: [
              Icon(Icons.highlight, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Highlight', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Copy', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'play',
          child: Row(
            children: [
              Icon(Icons.play_arrow, size: isTablet ? 20 : 18),
              const SizedBox(width: 8),
              Text('Play', style: TextStyle(fontSize: isTablet ? 16 : 14)),
            ],
          ),
        ),
      ],
    ).then((String? value) {
      if (value != null) {
        _handleAyahContextAction(value, ayah, ayahId);
      }
    });
  }

  void _handleAyahContextAction(String action, PageAyah ayah, String ayahId) {
    switch (action) {
      case 'highlight':
        onAyahTapped(ayahId);
        break;
      case 'copy':
        onCopyAyah(ayah);
        break;
      case 'play':
        onPlayAyah(ayah);
        break;
    }
  }

  bool _isBismillah(PageAyah ayah) {
    if (ayah.ayah == 1) {
      return ayah.text.contains('بِسْمِ') || ayah.text.contains('﷽');
    }
    return false;
  }
}

// ===================== UTILITY CLASSES =====================

class _FontSizeCalculator {
  static double getMaximizedFontSize(
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

  static bool textFitsWidth(SimpleMushafLine line, MushafPage mushafPage,
      double fontSize, String fontFamily, double targetWidth) {
    String textToMeasure = line.text;

    if (line.lineType == 'ayah' || line.lineType == 'basmallah') {
      final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
      if (segments.isNotEmpty) {
        int totalWords = 0;
        for (final segment in segments) {
          totalWords += segment.words.length;
        }
        if (totalWords > 1) {
          textToMeasure = line.text + _Constants.thinSpace * (totalWords - 1);
        }
      }
    }

    final painter = TextPainter(
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.center,
      maxLines: 1,
      text: TextSpan(
        text: textToMeasure,
        style: TextStyle(fontFamily: fontFamily, fontSize: fontSize),
      ),
    );
    painter.layout(minWidth: 0, maxWidth: double.infinity);
    return painter.size.width <= targetWidth;
  }
}

class _TextRenderer {
  static Widget buildRegularText(
      String text, double fontSize, String fontFamily, Color textColor) {
    final strokeWidth = fontSize * 0.04;

    return Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = Colors.black,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: Colors.black,
          ),
        ),
      ],
    );
  }

  static Widget buildBasmallah(
      String text, double fontSize, String fontFamily, Color textColor) {
    return Text(
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
    );
  }
}

class _HighlightableTextBuilder {
  static Widget build({
    required SimpleMushafLine line,
    required List<AyahSegment> segments,
    required int pageNumber,
    required double fontSize,
    required String fontFamily,
    required Color textColor,
    required String? highlightedWordId,
    required String? userSelectedAyahId,
    required Function(PageAyah, String, Offset) onAyahContextMenu,
    required QuranService quranService,
  }) {
    segments.sort((a, b) {
      if (a.lineNumber != b.lineNumber)
        return a.lineNumber.compareTo(b.lineNumber);
      return a.startIndex.compareTo(b.startIndex);
    });

    final segmentsByAyah = <String, List<AyahSegment>>{};
    for (final segment in segments) {
      final ayah =
          _findAyahForSegment(segment, quranService.allPagesData[pageNumber]);
      if (ayah != null) {
        final ayahId = '${ayah.surah}:${ayah.ayah}';
        segmentsByAyah.putIfAbsent(ayahId, () => []).add(segment);
      }
    }

    final spans = <InlineSpan>[];
    for (final entry in segmentsByAyah.entries) {
      final ayahId = entry.key;
      final ayahSegments = entry.value
        ..sort((a, b) {
          if (a.lineNumber != b.lineNumber)
            return a.lineNumber.compareTo(b.lineNumber);
          return a.startIndex.compareTo(b.startIndex);
        });

      final isUserSelected = userSelectedAyahId == ayahId;
      final ayahSpans = <InlineSpan>[];

      for (final segment in ayahSegments) {
        final ayah =
            _findAyahForSegment(segment, quranService.allPagesData[pageNumber]);
        if (ayah == null) continue;

        final sortedWords = segment.words;
        for (int i = 0; i < sortedWords.length; i++) {
          final word = sortedWords[i];
          final wordId = '${ayah.surah}:${ayah.ayah}:${word.wordIndex}';
          final isAudioHighlighted = highlightedWordId == wordId;

          ayahSpans.add(TextSpan(
            text: word.text,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: textColor,
              backgroundColor:
                  isAudioHighlighted ? Colors.yellow.withOpacity(0.6) : null,
            ),
          ));

          if (i < sortedWords.length - 1) {
            ayahSpans.add(TextSpan(
              text: _Constants.thinSpace,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                color: textColor,
              ),
            ));
          }
        }
      }

      spans.add(WidgetSpan(
        child: GestureDetector(
          onLongPressStart: (details) {
            if (ayahSegments.isNotEmpty) {
              final ayah = _findAyahForSegment(
                  ayahSegments.first, quranService.allPagesData[pageNumber]);
              if (ayah != null) {
                onAyahContextMenu(ayah, ayahId, details.globalPosition);
              }
            }
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
      ));
    }

    return RichText(
      textAlign: TextAlign.center,
      textDirection: TextDirection.rtl,
      text: TextSpan(children: spans.reversed.toList()),
    );
  }

  static Widget buildForTranslation({
    required List<AyahSegment> segments,
    required double fontSize,
    required String fontFamily,
    required Color textColor,
    required String? highlightedWordId,
    required int surahNumber,
    required int ayahNumber,
  }) {
    final spans = <InlineSpan>[];

    for (final segment in segments) {
      final sortedWords = segment.words;
      for (int i = 0; i < sortedWords.length; i++) {
        final word = sortedWords[i];
        final wordId = '$surahNumber:$ayahNumber:${word.wordIndex}';
        final isAudioHighlighted = highlightedWordId == wordId;

        spans.add(TextSpan(
          text: word.text,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            color: textColor,
            backgroundColor:
                isAudioHighlighted ? Colors.yellow.withOpacity(0.6) : null,
          ),
        ));

        if (i < sortedWords.length - 1) {
          spans.add(TextSpan(
            text: _Constants.thinSpace,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: textColor,
            ),
          ));
        }
      }
    }

    return RichText(
      textAlign: TextAlign.right,
      textDirection: TextDirection.rtl,
      text: TextSpan(children: spans),
    );
  }

  static PageAyah? _findAyahForSegment(AyahSegment segment, MushafPage? page) {
    if (page == null) return null;

    for (final ayah in page.ayahs) {
      if (ayah.segments.contains(segment)) return ayah;
    }
    return null;
  }
}
