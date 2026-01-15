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

  Future<void> _initDatabases({RendererType? renderer}) async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Setting up databases...';
      });

      await _dataService.initDatabases(renderer: renderer);

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

  Future<void> _switchRenderer(RendererType newRenderer) async {
    try {
      setState(() {
        _isInitializing = true;
        _loadingMessage = 'Switching renderer...';
      });

      await _dataService.switchRenderer(newRenderer);

      setState(() {
        _loadingMessage = 'Loading page...';
      });

      await _dataService.loadPage(_currentPage);

      setState(() {
        _isInitializing = false;
      });

      // Restart preloading with new renderer
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
    final isLandscape = screenSize.width > screenSize.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F1E8),
      appBar: MushafAppBar(
        currentPage: _currentPage,
        isPreloading: _isPreloading,
        preloadProgress: _preloadProgress,
        currentRenderer: _dataService.currentRenderer,
        onRendererChanged: _switchRenderer,
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
                return _buildMushafPage(page, isLandscape);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMushafPage(int page, bool isLandscape) {
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

    // Adjust margins based on device and orientation
    // Landscape and iPad: larger margins for better spacing
    // Normal phone portrait: smaller margins to maximize content
    double horizontalMargin;
    double verticalMargin;
    
    if (isLandscape || isTablet) {
      // Landscape or iPad: use larger margins
      horizontalMargin = isTablet ? 28.0 : 24.0;
      verticalMargin = isTablet ? 28.0 : 24.0;
    } else {
      // Normal phone portrait: reduced margins to maximize content
      horizontalMargin = 12.0;
      verticalMargin = 12.0;
    }
    
    // Calculate available space for content after margins
    final contentHeight = availableHeight - (verticalMargin * 2);
    final contentWidth = screenSize.width - (horizontalMargin * 2);

    // Calculate font size to maintain consistent white space across orientations
    // Scales font to fill available space while keeping margins consistent
    // Account for line height (2.2x) when calculating
    final int lineCount = mushafPage.lines.length;
    final double optimalFontSize = _calculateFontSizeFromCanvas(
      contentHeight: contentHeight,
      contentWidth: contentWidth,
      lineCount: lineCount,
      isTablet: isTablet,
      isLandscape: isLandscape,
    );

    final pageContent = Container(
      width: double.infinity,
      margin: EdgeInsets.symmetric(
        horizontal: horizontalMargin,
        vertical: verticalMargin,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 16.0 : 12.0,
        vertical: isTablet ? 20.0 : 16.0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            mainAxisAlignment: page <= 2
                ? MainAxisAlignment.center
                : (isLandscape ? MainAxisAlignment.start : MainAxisAlignment.start),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: mushafPage.lines
                .map((line) => _buildLine(
                      line, 
                      constraints, 
                      page, 
                      mushafPage, 
                      isLandscape,
                      optimalFontSize,
                      contentWidth - (isTablet ? 32.0 : 24.0), // Subtract padding
                    ))
                .toList(),
          );
        },
      ),
    );

    // In landscape mode, make the page scrollable
    if (isLandscape) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: availableHeight,
          ),
          child: pageContent,
        ),
      );
    }

    // In portrait mode, use fixed height
    return SizedBox(
      height: availableHeight,
      child: pageContent,
    );
  }

  Widget _buildLine(
    SimpleMushafLine line,
    BoxConstraints constraints,
    int page,
    MushafPage mushafPage,
    bool isLandscape,
    double fontSize,
    double contentWidth,
  ) {
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;

    final lineWidget = Builder(
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

        return _buildLineWithKashida(
          line,
          page,
          mushafPage,
          contentWidth,
          fontSize,
          isTablet,
          isLandscape,
        );
      },
    );

    if (page <= 2) {
      return SizedBox(
        width: double.infinity,
        child: lineWidget,
      );
    }

    // In landscape, don't use Expanded (doesn't work in scrollable context)
    if (isLandscape) {
      return SizedBox(
        width: double.infinity,
        child: lineWidget,
      );
    }

    // In portrait, use Expanded for proper spacing
    return Expanded(
      flex: 1,
      child: SizedBox(
        width: double.infinity,
        child: lineWidget,
      ),
    );
  }

  Widget _buildLineWithKashida(
      SimpleMushafLine line,
      int page,
      MushafPage mushafPage,
      double maxWidth,
      double fontSize,
      bool isTablet,
      bool isLandscape,
      ) {
    // Use renderer's font family
    final rendererType = _dataService.currentRenderer;
    String fontFamily = rendererType.fontFamily;
    
    // For QPC V2, use per-page fonts
    if (rendererType.hasPerPageFonts) {
      fontFamily = '${rendererType.fontFamily}_Page$page';
    }
    
    final double targetWidth = maxWidth;
    final double uniformFontSize = fontSize;

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
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
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

  /// Calculate font size to maintain consistent white space across orientations
  /// Accounts for line height (2.2x) constraint to ensure all lines fit
  double _calculateFontSizeFromCanvas({
    required double contentHeight,
    required double contentWidth,
    required int lineCount,
    required bool isTablet,
    required bool isLandscape,
  }) {
    const double lineSpacingMultiplier = 2.2; // Line height is 2.2x font size
    
    // Base font size for portrait mode (reference)
    final double basePortraitFontSize = getMushafFontSize(isTablet, false);
    
    // Reference width for portrait (used for width scaling in landscape)
    // Use smaller reference to make scaling more aggressive and reduce white space
    // Mobile portrait is typically 360-414px wide, landscape is 640-900px+ wide
    final double referencePortraitWidth = isTablet ? 600.0 : 300.0;
    
    double scaleFactor;
    
    if (isLandscape) {
      // In landscape: scale aggressively based on width to fill horizontal space
      // Use smaller reference width to make scaling more aggressive
      final double widthScale = contentWidth / referencePortraitWidth;
      scaleFactor = widthScale;
      
      // Make it even more aggressive - add 10% boost to really fill the space
      scaleFactor = scaleFactor * 1.1;
      
      // Ensure minimum scale in landscape (at least 1.0x to maintain or increase from portrait)
      if (scaleFactor < 1.0) {
        scaleFactor = 1.0;
      }
    } else {
      // In portrait: scale based on height, accounting for line height
      // Make it more aggressive to reduce white space
      final double maxFontSizeByHeight = contentHeight / (lineCount * lineSpacingMultiplier);
      scaleFactor = maxFontSizeByHeight / basePortraitFontSize;
      
      // Add 5% boost in portrait too to reduce white space
      scaleFactor = scaleFactor * 1.05;
    }
    
    // Scale the font size proportionally
    double scaledFontSize = basePortraitFontSize * scaleFactor;
    
    // Clamp to reasonable bounds (min 18px, max 60px to allow larger scaling)
    scaledFontSize = scaledFontSize.clamp(18.0, 60.0);
    
    // Round to nearest 0.5 for cleaner rendering
    return (scaledFontSize * 2).round() / 2.0;
  }

  /// Get base font size for device type (fallback)
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
    this.baseGap = 4.0,
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
    double gapSize = 0.0;
    TextStyle adjustedTextStyle = textStyle;
    List<double> adjustedWordWidths = wordWidths;
    double adjustedTotalWordsWidth = totalWordsWidth;
    double horizontalScale = 1.0; // For compression via scaling

    if (numGaps > 0) {
      final double totalGapSpace = targetWidth - totalWordsWidth;
      gapSize = totalGapSpace / numGaps;

      // Ensure minimum gap to prevent overlapping
      final double minGap = 3.0;

      if (gapSize < minGap) {
        gapSize = minGap;
      }

      // Check if total width would exceed targetWidth
      final double totalLineWidth = adjustedTotalWordsWidth + (numGaps * gapSize);

      if (totalLineWidth > targetWidth) {
        // Reduce gap to fit within bounds
        gapSize = (targetWidth - adjustedTotalWordsWidth) / numGaps;

        // If gap becomes less than minimum, use horizontal scaling (Tarteel's approach)
        if (gapSize < minGap) {
          gapSize = minGap;

          // Calculate horizontal scale factor needed
          final double requiredWidth = targetWidth - (numGaps * gapSize);
          horizontalScale = requiredWidth / adjustedTotalWordsWidth;

          // Recalculate with scaled widths
          adjustedWordWidths = wordWidths.map((w) => w * horizontalScale).toList();
          adjustedTotalWordsWidth = adjustedWordWidths.fold(0.0, (a, b) => a + b);

          // Recalculate final gap
          gapSize = (targetWidth - adjustedTotalWordsWidth) / numGaps;
          if (gapSize < 0) gapSize = 0;
        }
      }
    }

    // 4. Calculate word positions RTL (right-to-left)
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
      y = (size.height - fontSize) / 2;
    }

    for (int i = 0; i < numWords; i++) {
      final word = words[i];
      final wordWidth = adjustedWordWidths[i];
      final paintX = wordPositions[i];

      // Paint word if it fits within bounds (clipping handles overflow)
      if (paintX + wordWidth >= 0 && paintX <= targetWidth) {
        if (horizontalScale < 1.0) {
          // Apply horizontal scaling for compression (Tarteel's approach)
          _paintWordWithScale(canvas, word, Offset(paintX, y), adjustedTextStyle, horizontalScale);
        } else {
          _paintWord(canvas, word, Offset(paintX, y), adjustedTextStyle);
        }
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

  void _paintWordWithScale(Canvas canvas, String text, Offset offset, TextStyle style, double scaleX) {
    canvas.save();
    // Apply horizontal scaling from the offset point
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scaleX, 1.0);
    canvas.translate(-offset.dx, -offset.dy);

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.right,
      maxLines: 1,
    );
    tp.layout(maxWidth: double.infinity);
    tp.paint(canvas, offset);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MushafLinePainter oldDelegate) {
    return oldDelegate.words != words ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.targetWidth != targetWidth;
  }
}