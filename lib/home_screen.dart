import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Import services
import 'quran_service.dart';
import 'mushaf_widgets.dart';
import 'surah_header_banner.dart';
import 'theme.dart';
import 'quran_metadata_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final QuranService _quranService = QuranService();
  bool _isInitializing = true;
  String _loadingMessage = 'Initializing...';
  QuranThemeMode _currentTheme = QuranThemeMode.normal;

  @override
  void initState() {
    super.initState();
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

      setState(() {
        _loadingMessage = 'Loading surah banners...';
      });

      // Import SurahBanner for preloading
      await SurahBanner.preload();

      setState(() {
        _loadingMessage = 'Building surah mapping...';
      });

      await _quranService.buildSurahMapping();

      setState(() {
        _loadingMessage = 'Preloading key pages...';
      });

      // Preload first few pages and some common surahs for instant access
      final keyPages = [
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
      ]; // Common surah start pages
      for (final page in keyPages) {
        await _quranService.getPage(page);
        await Future.delayed(const Duration(
            milliseconds: 5)); // Small delay to keep UI responsive
      }

      setState(() {
        _isInitializing = false;
      });

      // Continue preloading remaining pages in background
      _startBackgroundPreloading();
    } catch (e) {
      print('Initialization error: $e');
      setState(() {
        _isInitializing = false;
        _loadingMessage = 'Error: $e';
      });
    }
  }

  void _navigateToMushaf(int surahId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MushafPageViewer(
          initialSurahId: surahId,
          quranService: _quranService,
          initialTheme: _currentTheme,
        ),
      ),
    );
  }

  void _navigateToPage(int pageNumber) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MushafPageViewer(
          initialPageNumber: pageNumber,
          quranService: _quranService,
          initialTheme: _currentTheme,
        ),
      ),
    );
  }

  void _toggleTheme() {
    setState(() {
      _currentTheme = QuranTheme.getNextTheme(_currentTheme);
    });
  }

  Future<void> _startBackgroundPreloading() async {
    // Preload all remaining pages in background without blocking UI
    for (int page = 1; page <= 604; page++) {
      if (!_quranService.allPagesData.containsKey(page)) {
        await _quranService.getPage(page);
        if (page % 50 == 0) {
          // Yield control periodically to keep UI responsive
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }
    }
  }

  @override
  void dispose() {
    _quranService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final backgroundColor = QuranTheme.getBackgroundColor(_currentTheme);
    final textColor = QuranTheme.getTextColor(_currentTheme);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          'Quran',
          style: TextStyle(
            color: textColor,
            fontSize: isTablet ? 24 : 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        backgroundColor: QuranTheme.getAppBarColor(_currentTheme),
        foregroundColor: textColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              QuranTheme.getStatusBarBrightness(_currentTheme),
        ),
        actions: [
          IconButton(
            onPressed: _toggleTheme,
            icon: Icon(
              QuranTheme.getThemeIcon(_currentTheme),
              color: textColor.withOpacity(0.7),
            ),
          ),
        ],
      ),
      body: _isInitializing
          ? LoadingScreen(
              message: _loadingMessage,
              textColor: textColor,
              isTablet: isTablet,
            )
          : HomeContent(
              quranService: _quranService,
              onSurahSelected: _navigateToMushaf,
              onPageSelected: _navigateToPage,
              theme: _currentTheme,
              isTablet: isTablet,
            ),
    );
  }
}

class HomeContent extends StatefulWidget {
  final QuranService quranService;
  final Function(int) onSurahSelected;
  final Function(int) onPageSelected;
  final QuranThemeMode theme;
  final bool isTablet;

  const HomeContent({
    Key? key,
    required this.quranService,
    required this.onSurahSelected,
    required this.onPageSelected,
    required this.theme,
    required this.isTablet,
  }) : super(key: key);

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent> {
  String _searchQuery = '';
  List<Surah> _filteredSurahs = [];
  bool _showMetadataOption = false;

  @override
  void initState() {
    super.initState();
    final surahs = widget.quranService.surahService.surahs;
    if (surahs != null) {
      _filteredSurahs = List.from(surahs);
    }
  }

  void _updateSearch(String value) {
    setState(() {
      _searchQuery = value.toLowerCase();
      _showMetadataOption = _searchQuery.contains('quran_metadata') ||
          _searchQuery.contains('metadata') ||
          _searchQuery.contains('quran metadata');

      final surahs = widget.quranService.surahService.surahs;
      if (surahs != null) {
        _filteredSurahs = surahs.where((surah) {
          return surah.nameSimple.toLowerCase().contains(_searchQuery) ||
              surah.nameArabic.contains(_searchQuery) ||
              surah.id.toString().contains(_searchQuery);
        }).toList();
      }
    });
  }

  void _navigateToMetadata() {
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
    final textColor = QuranTheme.getTextColor(widget.theme);

    return Column(
      children: [
        // Search bar
        Container(
          margin: EdgeInsets.all(widget.isTablet ? 20 : 16),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search surahs or type "quran_metadata"...',
              hintStyle: TextStyle(color: textColor.withOpacity(0.6)),
              prefixIcon: Icon(Icons.search, color: textColor.withOpacity(0.6)),
              filled: true,
              fillColor: textColor.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: widget.isTablet ? 20 : 16,
                vertical: widget.isTablet ? 16 : 12,
              ),
            ),
            style: TextStyle(
              color: textColor,
              fontSize: widget.isTablet ? 16 : 14,
            ),
            onChanged: _updateSearch,
          ),
        ),

        // Show metadata option if relevant search query
        if (_showMetadataOption) ...[
          Container(
            margin: EdgeInsets.symmetric(
              horizontal: widget.isTablet ? 20 : 16,
              vertical: 8,
            ),
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
                    size: widget.isTablet ? 24 : 20,
                  ),
                ),
                title: Text(
                  'Quran Metadata',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    fontSize: widget.isTablet ? 16 : 14,
                  ),
                ),
                subtitle: Text(
                  'View detailed information about all surahs',
                  style: TextStyle(
                    fontSize: widget.isTablet ? 14 : 12,
                    color: textColor.withOpacity(0.6),
                  ),
                ),
                trailing: Icon(
                  Icons.arrow_forward_ios,
                  size: widget.isTablet ? 18 : 16,
                  color: textColor.withOpacity(0.6),
                ),
                onTap: _navigateToMetadata,
              ),
            ),
          ),
        ],

        // Surah list
        Expanded(
          child: _filteredSurahs.isEmpty && !_showMetadataOption
              ? Center(
                  child: Text(
                    'No surahs found',
                    style: TextStyle(
                      fontSize: widget.isTablet ? 18 : 16,
                      color: textColor.withOpacity(0.6),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.isTablet ? 20 : 16,
                  ),
                  itemCount: _filteredSurahs.length,
                  itemBuilder: (context, index) {
                    final surah = _filteredSurahs[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        color: textColor.withOpacity(0.02),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: textColor.withOpacity(0.1),
                            width: 0.5,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: widget.isTablet ? 20 : 16,
                            vertical: widget.isTablet ? 12 : 8,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: textColor.withOpacity(0.1),
                            radius: widget.isTablet ? 24 : 20,
                            child: Text(
                              '${surah.id}',
                              style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.bold,
                                fontSize: widget.isTablet ? 16 : 14,
                              ),
                            ),
                          ),
                          title: Text(
                            surah.nameSimple,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: textColor,
                              fontSize: widget.isTablet ? 18 : 16,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                surah.nameArabic,
                                style: TextStyle(
                                  fontSize: widget.isTablet ? 18 : 16,
                                  fontWeight: FontWeight.w500,
                                  color: textColor.withOpacity(0.8),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Text(
                                    '${surah.versesCount} verses • ${surah.revelationPlace}',
                                    style: TextStyle(
                                      fontSize: widget.isTablet ? 14 : 12,
                                      color: textColor.withOpacity(0.6),
                                    ),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () =>
                                        widget.onPageSelected(surah.page),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: widget.isTablet ? 8 : 6,
                                        vertical: widget.isTablet ? 4 : 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: textColor.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: textColor.withOpacity(0.2),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        'Page ${surah.page}',
                                        style: TextStyle(
                                          fontSize: widget.isTablet ? 11 : 9,
                                          color: textColor.withOpacity(0.8),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          trailing: Icon(
                            Icons.arrow_forward_ios,
                            size: widget.isTablet ? 18 : 16,
                            color: textColor.withOpacity(0.6),
                          ),
                          onTap: () => widget.onSurahSelected(surah.id),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
