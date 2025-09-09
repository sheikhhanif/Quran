import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Import services
import 'quran_service.dart';
import 'audio_service.dart';
import 'surah_header_banner.dart';
import 'theme.dart';
import 'quran_metadata_page.dart';

// ===================== MAIN MUSHAF WIDGET =====================

class MushafPageViewer extends StatefulWidget {
  const MushafPageViewer({super.key});

  @override
  State<MushafPageViewer> createState() => _MushafPageViewerState();
}

class _MushafPageViewerState extends State<MushafPageViewer> {
  int _currentPage = 1;
  bool _isInitializing = true;
  String _loadingMessage = 'Initializing...';

  // Services
  final QuranService _quranService = QuranService();
  final AudioService _audioService = AudioService();

  // Audio state
  AudioPlaybackState _audioState = AudioPlaybackState.stopped;
  String? _highlightedWordId;
  String? _userSelectedAyahId;

  // Bottom bar state
  int _currentAyahIndex = 0;
  int? _highlightedAyahIndex;
  bool _isDragging = false;
  bool _isPlaying = false;
  bool _isLoading = false;

  // UI state
  late PageController _pageController;
  final Map<int, double> _uniformFontSizeCache = {};
  QuranThemeMode _currentTheme = QuranThemeMode.normal;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 603);
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      await _quranService.initialize();

      setState(() {
        _loadingMessage = 'Loading fonts...';
      });

      await _quranService.preloadAllFonts();
      await SurahBanner.preload();

      setState(() {
        _loadingMessage = 'Initializing audio...';
      });

      await _initAudio();

      setState(() {
        _loadingMessage = 'Loading first page...';
      });

      await _quranService.getPage(_currentPage);

      await Future.delayed(Duration.zero);
      await WidgetsBinding.instance.endOfFrame;

      await _quranService.buildSurahMapping();

      setState(() {
        _isInitializing = false;
      });

      _startBackgroundPreloading();
    } catch (e) {
      print('Initialization error: $e');
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $e';
      });
    }
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

  Future<void> _startBackgroundPreloading() async {
    for (int page = 1; page <= 604; page++) {
      await _quranService.getPage(page);
      if (page % 20 == 0) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
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
    await _audioService.stop();
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
        _audioService.seekToAyah(i);
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

  void _toggleTheme() {
    setState(() {
      _currentTheme = QuranTheme.getNextTheme(_currentTheme);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _quranService.dispose();
    _audioService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    return Scaffold(
      backgroundColor: QuranTheme.getBackgroundColor(_currentTheme),
      appBar: AppBar(
        title: SearchBox(
          currentPage: _currentPage,
          quranService: _quranService,
          onSurahSelected: (surahId) => _navigateToSurah(surahId),
          textColor: QuranTheme.getTextColor(_currentTheme),
          theme: _currentTheme,
        ),
        centerTitle: false,
        backgroundColor: QuranTheme.getAppBarColor(_currentTheme),
        foregroundColor: QuranTheme.getTextColor(_currentTheme),
        automaticallyImplyLeading: false,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 48,
        titleSpacing: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              QuranTheme.getStatusBarBrightness(_currentTheme),
        ),
      ),
      body: _isInitializing
          ? LoadingScreen(
              message: _loadingMessage,
              textColor: QuranTheme.getTextColor(_currentTheme),
              isTablet: isTablet,
            )
          : Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: 604,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final page = 604 - index;
                      return MushafPageWidget(
                        pageNumber: page,
                        quranService: _quranService,
                        highlightedWordId: _highlightedWordId,
                        userSelectedAyahId: _userSelectedAyahId,
                        onAyahTapped: (ayahId) {
                          setState(() {
                            _userSelectedAyahId =
                                _userSelectedAyahId == ayahId ? null : ayahId;
                          });
                          _seekToAyahFromId(ayahId);
                        },
                        uniformFontSizeCache: _uniformFontSizeCache,
                        backgroundColor:
                            QuranTheme.getBackgroundColor(_currentTheme),
                        textColor: QuranTheme.getTextColor(_currentTheme),
                        theme: _currentTheme,
                      );
                    },
                  ),
                ),
                AudioBottomBar(
                  currentPage: _currentPage,
                  currentAyahIndex: _currentAyahIndex,
                  highlightedAyahIndex: _highlightedAyahIndex,
                  isLoading: _isLoading,
                  isPlaying: _isPlaying,
                  ayahs: _getCurrentPageAyahs(),
                  onPlayPause: _togglePlayPause,
                  onProgressChanged: _onProgressBarChanged,
                  onProgressStart: () => setState(() => _isDragging = true),
                  onProgressEnd: () => setState(() => _isDragging = false),
                  onThemeToggle: _toggleTheme,
                  themeIcon: QuranTheme.getThemeIcon(_currentTheme),
                  backgroundColor: QuranTheme.getAppBarColor(_currentTheme),
                  textColor: QuranTheme.getTextColor(_currentTheme),
                  isTablet: isTablet,
                ),
              ],
            ),
    );
  }

  void _navigateToSurah(int surahId) {
    int? startPage = _quranService.surahService.getSurahStartPage(surahId);
    if (startPage == null) {
      startPage = _quranService.surahService
          .findSurahStartPageDirectly(surahId, _quranService.allPagesData);
    }

    if (startPage != null) {
      if (_audioState != AudioPlaybackState.stopped) {
        _stopAudio();
      }

      _pageController.animateToPage(
        604 - startPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

      _quranService.getPage(startPage);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not find the starting page for this surah'),
          backgroundColor: Colors.red,
        ),
      );
    }
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

// ===================== SEARCH BOX =====================

class SearchBox extends StatelessWidget {
  final int currentPage;
  final QuranService quranService;
  final Function(int) onSurahSelected;
  final Color textColor;
  final QuranThemeMode theme;

  const SearchBox({
    Key? key,
    required this.currentPage,
    required this.quranService,
    required this.onSurahSelected,
    required this.textColor,
    required this.theme,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final currentSurah = _getCurrentSurah();
    final surahInfo = currentSurah != null
        ? '${currentSurah.nameSimple} (${currentSurah.id})'
        : 'Page $currentPage';

    return GestureDetector(
      onTap: () => _showSearchBottomSheet(context),
      child: Container(
        height: 36,
        width: double.infinity,
        margin: EdgeInsets.zero,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.zero,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                surahInfo,
                style: TextStyle(
                  color: textColor.withOpacity(0.6),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Icon(
                Icons.search,
                color: textColor.withOpacity(0.5),
                size: 16,
              ),
            ],
          ),
        ),
      ),
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

  void _showSearchBottomSheet(BuildContext context) {
    final surahs = quranService.surahService.surahs;
    if (surahs == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return SearchBottomSheet(
          surahs: surahs,
          onSurahSelected: onSurahSelected,
          quranService: quranService,
          theme: theme,
        );
      },
    );
  }
}

// ===================== SEARCH BOTTOM SHEET =====================

class SearchBottomSheet extends StatefulWidget {
  final List<Surah> surahs;
  final Function(int) onSurahSelected;
  final QuranService quranService;
  final QuranThemeMode theme;

  const SearchBottomSheet({
    Key? key,
    required this.surahs,
    required this.onSurahSelected,
    required this.quranService,
    required this.theme,
  }) : super(key: key);

  @override
  State<SearchBottomSheet> createState() => _SearchBottomSheetState();
}

class _SearchBottomSheetState extends State<SearchBottomSheet> {
  String _searchQuery = '';
  List<Surah> _filteredSurahs = [];
  bool _showMetadataOption = false;

  @override
  void initState() {
    super.initState();
    _filteredSurahs = List.from(widget.surahs);
  }

  void _updateSearch(String value) {
    setState(() {
      _searchQuery = value.toLowerCase();
      _showMetadataOption = _searchQuery.contains('quran_metadata') ||
          _searchQuery.contains('metadata') ||
          _searchQuery.contains('quran metadata');

      _filteredSurahs = widget.surahs.where((surah) {
        return surah.nameSimple.toLowerCase().contains(_searchQuery) ||
            surah.nameArabic.contains(_searchQuery) ||
            surah.id.toString().contains(_searchQuery);
      }).toList();
    });
  }

  void _navigateToMetadata() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => QuranMetadataPage(
          quranService: widget.quranService,
          theme: widget.theme,
          onSurahSelected: widget.onSurahSelected,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = QuranTheme.getBackgroundColor(widget.theme);
    final textColor = QuranTheme.getTextColor(widget.theme);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, color: textColor),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search surahs or type "quran_metadata"...',
                    hintStyle: TextStyle(color: textColor.withOpacity(0.6)),
                    prefixIcon:
                        Icon(Icons.search, color: textColor.withOpacity(0.6)),
                    filled: true,
                    fillColor: textColor.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  style: TextStyle(color: textColor),
                  onChanged: _updateSearch,
                ),
              ),
              const SizedBox(height: 16),

              // Show metadata option if relevant search query
              if (_showMetadataOption) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Card(
                    color: textColor.withOpacity(0.05),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: textColor.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: textColor.withOpacity(0.1),
                        child: Icon(
                          Icons.info_outline,
                          color: textColor,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        'Quran Metadata',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      subtitle: Text(
                        'View detailed information about all surahs',
                        style: TextStyle(
                          fontSize: 12,
                          color: textColor.withOpacity(0.6),
                        ),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: textColor.withOpacity(0.6),
                      ),
                      onTap: _navigateToMetadata,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              Expanded(
                child: _filteredSurahs.isEmpty && !_showMetadataOption
                    ? Center(
                        child: Text(
                          'No surahs found',
                          style: TextStyle(
                            fontSize: 16,
                            color: textColor.withOpacity(0.6),
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
                              backgroundColor: textColor.withOpacity(0.1),
                              child: Text(
                                '${surah.id}',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            title: Text(
                              surah.nameSimple,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  surah.nameArabic,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: textColor.withOpacity(0.8),
                                  ),
                                ),
                                Text(
                                  '${surah.versesCount} verses • ${surah.revelationPlace}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: textColor.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            ),
                            trailing: Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                              color: textColor.withOpacity(0.6),
                            ),
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSurahSelected(surah.id);
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
  final VoidCallback onThemeToggle;
  final IconData themeIcon;
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
    required this.onThemeToggle,
    required this.themeIcon,
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
                    : Colors.grey.withOpacity(0.05),
                border: Border.all(
                  color: ayahs.isNotEmpty
                      ? textColor.withOpacity(0.15)
                      : Colors.grey.withOpacity(0.15),
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
          SizedBox(width: isTablet ? 12 : 8),
          GestureDetector(
            onTap: onThemeToggle,
            child: Container(
              width: isTablet ? 40 : 36,
              height: isTablet ? 40 : 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: textColor.withOpacity(0.1),
                border: Border.all(
                  color: textColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Icon(
                themeIcon,
                color: textColor.withOpacity(0.7),
                size: isTablet ? 20 : 18,
              ),
            ),
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

    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final appBarHeight = isTablet ? 60.0 : 48.0;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomBarHeight = isTablet ? 90.0 : 80.0;
    final availableHeight = screenSize.height -
        appBarHeight -
        statusBarHeight -
        bottomBarHeight -
        8.0;

    return Container(
      width: double.infinity,
      height: availableHeight,
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
            mainAxisAlignment: pageNumber <= 2
                ? MainAxisAlignment.center
                : MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: mushafPage.lines
                .map((line) => _buildLine(
                    line, constraints, pageNumber, mushafPage, context))
                .toList(),
          );
        },
      ),
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
                    maxWidth: constraints.maxWidth,
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
                        onTap: () => _handleLineTap(segments),
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
                      onTap: () => _handleLineTap(segments),
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
                    maxWidth: constraints.maxWidth,
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
                        onTap: () => _handleLineTap(segments),
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
                      onTap: () => _handleLineTap(segments),
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
                    isAudioHighlighted ? Colors.yellow.withOpacity(0.7) : null,
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
            onTap: () => onAyahTapped(ayahId),
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
            onTap: () => onAyahTapped(ayahId),
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
