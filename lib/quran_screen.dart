import 'package:flutter/material.dart';
import 'mushaf_models.dart';
import 'mushaf_data_service.dart';
import 'mushaf_app_bar.dart';
import 'surah_header_banner.dart';

// ===================== MAIN WIDGET =====================

class MushafPageViewer extends StatefulWidget {
  const MushafPageViewer({super.key});

  @override
  State<MushafPageViewer> createState() => _MushafPageViewerState();
}

class _MushafPageViewerState extends State<MushafPageViewer> {
  final MushafDataService _dataService = MushafDataService();
  int _currentPage = 1;

  bool _isInitializing = true;
  bool _isPreloading = false;
  String _loadingMessage = 'Initializing...';
  double _preloadProgress = 0.0;

  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _initDatabases();
  }

  Future<void> _initDatabases() async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      await _dataService.initDatabases();

      setState(() {
        _loadingMessage = 'Loading page...';
      });

      await _dataService.loadPage(_currentPage);

      setState(() {
        _isInitializing = false;
      });

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

    await _dataService.startBackgroundPreloading(
      onProgress: (progress) {
        setState(() {
          _preloadProgress = progress;
        });
      },
    );

    setState(() {
      _isPreloading = false;
    });
  }

  void _onPageChanged(int index) {
    final page = index + 1;
    setState(() {
      _currentPage = page;
    });
    _dataService.loadAroundCurrentPage(page);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dataService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F1E8),
      appBar: MushafAppBar(
        currentPage: _currentPage,
        isPreloading: _isPreloading,
        preloadProgress: _preloadProgress,
      ),
      bottomNavigationBar: const MushafBottomNavigationBar(),
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
        ],
      ),
    );
  }

  Widget _buildMushafPage(int page) {
    final mushafPage = _dataService.allPagesData[page];

    if (mushafPage == null) {
      if (!_dataService.loadedPages.contains(page)) {
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
    final appBarHeight = kToolbarHeight + (_isPreloading ? 4.0 : 0.0);
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Reserve standard bottom navigation bar space (56.0) plus system inset
    const double bottomNavBarHeight = 56.0;
    final availableHeight = screenSize.height -
        appBarHeight -
        statusBarHeight -
        bottomInset -
        bottomNavBarHeight;

    return Container(
      width: double.infinity,
      height: availableHeight,
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 12.0 : 8.0,
        vertical: isTablet ? 16.0 : 12.0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            mainAxisAlignment: page <= 2
                ? MainAxisAlignment.center
                : MainAxisAlignment.spaceEvenly,
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

            return _buildLineWithKashida(line, page, mushafPage,
                constraints.maxWidth, isTablet, isLandscape, screenSize);
          },
        ),
      );
    }

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

            return _buildLineWithKashida(line, page, mushafPage,
                constraints.maxWidth, isTablet, isLandscape, screenSize);
          },
        ),
      ),
    );
  }

  Widget _buildLineWithKashida(
      SimpleMushafLine line,
      int page,
      MushafPage mushafPage,
      double maxWidth,
      bool isTablet,
      bool isLandscape,
      Size screenSize,
      ) {
    // Use single shared Mushaf font family (not per-page fonts)
    final String fontFamily = 'MushafMadina';
    final double targetWidth =
        maxWidth - 8.0; // Reduced from 16.0 for more text width
    final double uniformFontSize = getMushafFontSize(isTablet, isLandscape);

    final segments = mushafPage.lineToSegments[line.lineNumber] ?? [];
    final List<String> words = [];

    for (final segment in segments) {
      for (final word in segment.words) {
        words.add(word.text);
      }
    }

    // Fallback to line text if no words found
    final List<String> finalWords = words.isNotEmpty ? words : [line.text];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 4.0), // Reduced from 8.0
      child: CustomPaint(
        size: Size(targetWidth, uniformFontSize * 2.2),
        painter: MushafLinePainter(
          words: finalWords,
          fontSize: uniformFontSize,
          fontFamily: fontFamily,
          targetWidth: targetWidth,
          textColor: Colors.black,
        ),
      ),
    );
  }

  double getMushafFontSize(bool isTablet, bool isLandscape) {
    if (isTablet && isLandscape) return 36;
    if (isTablet) return 32;
    if (isLandscape) return 28;
    return 24;
  }
}

// ===================== CUSTOM PAINTER =====================
// Digital Khatt V2 Mushaf Line-by-Line Justification Algorithm
//
// This implementation follows the exact Digital Khatt V2 specifications:
// - Database: digital-khatt-v2.db (words/scripts table with id, text, surah, ayah)
// - Layout: digital-khatt-15-lines.db (pages table: page_number, line_number,
//   line_type, is_centered, first_word_id, last_word_id, surah_number)
// - Font: madina.otf (Digital Khatt V2 variable font - 1421H Madani Mushaf)
//
// Digital Khatt V2 Specifications:
// - Font: madina.otf - Variable font replicating 1420H Madani Mushaf script
// - Letter spacing: 0.0 (Arabic letters connect naturally, no kerning)
// - Word spacing: Geometric distribution only (no TextStyle wordSpacing)
// - Justification: Pure geometric gap distribution between words
// - No kashida insertion (handled by font's variable features)
// - Fixed font size per device class (matches printed mushaf behavior)
// - Line spacing: 2.2x font size (adequate for diacritics and descenders)
// - 15 lines per page layout (standard Digital Khatt V2 format)
//
// Algorithm:
// 1. Measure each word individually (no text string manipulation)
// 2. Calculate geometric gap distribution to fill targetWidth exactly
// 3. Position words RTL (right-to-left) starting from targetWidth
// 4. Paint words individually at calculated positions
//
// Key principles:
// - No Unicode space insertion
// - No text string modification
// - Word-level measurement and painting
// - Deterministic gap distribution
// - Natural Arabic letter connections preserved

class MushafLinePainter extends CustomPainter {
  final List<String> words;
  final double fontSize;
  final String fontFamily;
  final double targetWidth;
  final Color textColor;
  final double baseGap;

  MushafLinePainter({
    required this.words,
    required this.fontSize,
    required this.fontFamily,
    required this.targetWidth,
    required this.textColor,
    // Digital Khatt V2: Base gap for natural word spacing
    // Digital Khatt V2 uses natural word spacing with geometric justification
    this.baseGap =
    4.0, // Baseline gap for Digital Khatt V2 (optimized for madina.otf font)
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (words.isEmpty) return;

    // Clip to ensure nothing paints outside bounds
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, targetWidth, size.height));

    // Digital Khatt spacing: No letter spacing, natural word spacing
    // Arabic letters connect naturally - we only adjust word gaps, not letter spacing
    final textStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      color: textColor,
      letterSpacing: 0.0, // Explicitly no letter spacing for Arabic
      wordSpacing: 0.0, // Word spacing handled by geometric gaps, not TextStyle
    );

    // Digital Khatt Algorithm: Line-by-line justification
    // 1. Measure each word individually (exact width)
    final List<double> wordWidths = [];
    for (final word in words) {
      final tp = _measure(word, textStyle);
      wordWidths.add(tp.width);
    }

    final int numWords = words.length;
    final int numGaps = numWords > 1 ? numWords - 1 : 0;

    // 2. Calculate total width of all words
    final double totalWordsWidth = wordWidths.fold(0.0, (a, b) => a + b);

    // 3. Calculate gap size to fill targetWidth exactly
    // Formula: targetWidth = totalWordsWidth + (numGaps * gapSize)
    // Therefore: gapSize = (targetWidth - totalWordsWidth) / numGaps
    double gapSize = 0.0;
    double adjustedFontSize = fontSize;
    TextStyle adjustedTextStyle = textStyle;
    List<double> adjustedWordWidths = wordWidths;
    double adjustedTotalWordsWidth = totalWordsWidth;

    if (numGaps > 0) {
      final double totalGapSpace = targetWidth - totalWordsWidth;
      gapSize = totalGapSpace / numGaps;

      // Digital Khatt V2: Enforce minimum gap to prevent overlapping
      final double minGap = 3.0;

      if (gapSize < minGap) {
        gapSize = minGap;
      }

      // Check if total width would exceed targetWidth
      final double totalLineWidth = totalWordsWidth + (numGaps * gapSize);

      if (totalLineWidth > targetWidth) {
        // Try reducing gap first
        gapSize = (targetWidth - totalWordsWidth) / numGaps;

        // If gap becomes too small (less than 3px), reduce font size instead
        if (gapSize < 3.0) {
          // Calculate required font size reduction
          final double maxAllowedWidth = targetWidth - (numGaps * 3.0);
          final double scaleFactor = maxAllowedWidth / totalWordsWidth;
          adjustedFontSize = fontSize * scaleFactor;

          // Re-measure with adjusted font size
          adjustedTextStyle = TextStyle(
            fontFamily: fontFamily,
            fontSize: adjustedFontSize,
            color: textColor,
            letterSpacing: 0.0,
            wordSpacing: 0.0,
          );

          adjustedWordWidths = [];
          for (final word in words) {
            final tp = _measure(word, adjustedTextStyle);
            adjustedWordWidths.add(tp.width);
          }
          adjustedTotalWordsWidth = adjustedWordWidths.fold(0.0, (a, b) => a + b);

          // Recalculate gap with new measurements
          gapSize = (targetWidth - adjustedTotalWordsWidth) / numGaps;
          if (gapSize < 0) gapSize = 0;
        } else if (gapSize < 0) {
          gapSize = 0;
        }
      }
    }

    // 4. Calculate word positions RTL (right-to-left)
    // Start from right edge (targetWidth) and work leftwards
    final List<double> wordPositions = [];
    double currentX = targetWidth; // Start at right edge

    for (int i = 0; i < numWords; i++) {
      final wordWidth = adjustedWordWidths[i];

      // Position word: move left by its width
      currentX -= wordWidth;
      wordPositions.add(currentX);

      // Move left by gap before positioning next word
      if (i < numWords - 1) {
        currentX -= gapSize;
      }
    }

    // 5. Calculate proper vertical positioning
    double y = 0.0;
    if (words.isNotEmpty) {
      final sampleTp = _measure(words.first, adjustedTextStyle);
      final double textHeight = sampleTp.height;
      y = size.height / 2 - textHeight / 2;
    } else {
      y = (size.height - adjustedFontSize) / 2;
    }

    for (int i = 0; i < numWords; i++) {
      final word = words[i];
      final wordWidth = adjustedWordWidths[i];
      final paintX = wordPositions[i];

      // Paint word if it fits within bounds (clipping handles overflow)
      if (paintX + wordWidth >= 0 && paintX <= targetWidth) {
        _paintWord(canvas, word, Offset(paintX, y), adjustedTextStyle);
      }
    }

    canvas.restore();
  }

  TextPainter _measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.right,
      maxLines: 1,
    );
    tp.layout(maxWidth: double.infinity);
    return tp;
  }

  void _paintWord(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.right,
      maxLines: 1,
    );
    tp.layout(maxWidth: double.infinity);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant MushafLinePainter oldDelegate) {
    return oldDelegate.words != words ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.targetWidth != targetWidth;
  }
}