import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'quran_service.dart';
import 'theme.dart';

class QuranMetadataPage extends StatefulWidget {
  final QuranService quranService;
  final QuranThemeMode theme;
  final Function(int)? onSurahSelected;

  const QuranMetadataPage({
    Key? key,
    required this.quranService,
    required this.theme,
    this.onSurahSelected,
  }) : super(key: key);

  @override
  State<QuranMetadataPage> createState() => _QuranMetadataPageState();
}

class _QuranMetadataPageState extends State<QuranMetadataPage> {
  Map<String, dynamic>? _metadataJson;
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    try {
      setState(() => _isLoading = true);

      final jsonString = await rootBundle
          .loadString('assets/quran/metadata/quran-metadata-surah-name.json');
      final Map<String, dynamic> jsonData = json.decode(jsonString);

      setState(() {
        _metadataJson = jsonData;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading metadata: $e');
      setState(() => _isLoading = false);
    }
  }

  List<MapEntry<String, dynamic>> _getFilteredSurahs() {
    if (_metadataJson == null) return [];

    var surahs = _metadataJson!.entries.toList();

    if (_searchQuery.isNotEmpty) {
      surahs = surahs.where((entry) {
        final surah = entry.value;
        final query = _searchQuery.toLowerCase();

        return surah['name'].toString().toLowerCase().contains(query) ||
            surah['name_simple'].toString().toLowerCase().contains(query) ||
            surah['name_arabic'].toString().contains(query) ||
            entry.key.contains(query) ||
            surah['revelation_place'].toString().toLowerCase().contains(query);
      }).toList();
    }

    // Sort by ID
    surahs.sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    return surahs;
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = QuranTheme.getBackgroundColor(widget.theme);
    final textColor = QuranTheme.getTextColor(widget.theme);
    final appBarColor = QuranTheme.getAppBarColor(widget.theme);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Quran Metadata'),
        backgroundColor: appBarColor,
        foregroundColor: textColor,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              QuranTheme.getStatusBarBrightness(widget.theme),
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(textColor),
              ),
            )
          : Column(
              children: [
                // Search bar
                Container(
                  padding: const EdgeInsets.all(16.0),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search surahs by name, place, or ID...',
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
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                ),

                // Metadata list
                Expanded(
                  child: _buildMetadataList(),
                ),
              ],
            ),
    );
  }

  Widget _buildMetadataList() {
    final filteredSurahs = _getFilteredSurahs();
    final textColor = QuranTheme.getTextColor(widget.theme);

    if (filteredSurahs.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isEmpty ? 'No metadata available' : 'No surahs found',
          style: TextStyle(
            fontSize: 16,
            color: textColor.withOpacity(0.6),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: filteredSurahs.length,
      itemBuilder: (context, index) {
        final entry = filteredSurahs[index];
        final surahId = entry.key;
        final surah = entry.value;

        return _buildSurahCard(surahId, surah, textColor);
      },
    );
  }

  Widget _buildSurahCard(
      String surahId, Map<String, dynamic> surah, Color textColor) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: textColor.withOpacity(0.05),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: textColor.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: textColor.withOpacity(0.1),
          child: Text(
            surahId,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    surah['name_simple'] ?? 'Unknown',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    surah['name_arabic'] ?? '',
                    style: TextStyle(
                      color: textColor.withOpacity(0.8),
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        subtitle: Text(
          '${surah['verses_count']} verses • ${surah['revelation_place']} • Page ${surah['page'] ?? 'N/A'}',
          style: TextStyle(
            color: textColor.withOpacity(0.6),
            fontSize: 12,
          ),
        ),
        iconColor: textColor.withOpacity(0.6),
        collapsedIconColor: textColor.withOpacity(0.6),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildMetadataRow('Full Name', surah['name'], textColor),
                _buildMetadataRow(
                    'Simple Name', surah['name_simple'], textColor),
                _buildMetadataRow(
                    'Arabic Name', surah['name_arabic'], textColor),
                _buildMetadataRow(
                    'Surah ID', surah['id'].toString(), textColor),
                _buildMetadataRow('Verses Count',
                    surah['verses_count'].toString(), textColor),
                _buildMetadataRow('Revelation Order',
                    surah['revelation_order'].toString(), textColor),
                _buildMetadataRow(
                    'Revelation Place', surah['revelation_place'], textColor),
                _buildMetadataRow('Bismillah Pre',
                    surah['bismillah_pre'].toString(), textColor),
                _buildMetadataRow(
                    'Page', surah['page']?.toString() ?? 'N/A', textColor),

                const SizedBox(height: 12),

                // Navigation button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final surahIdInt = int.tryParse(surahId);
                      if (surahIdInt != null &&
                          widget.onSurahSelected != null) {
                        Navigator.of(context).pop();
                        widget.onSurahSelected!(surahIdInt);
                      }
                    },
                    icon: const Icon(Icons.navigate_next, size: 16),
                    label: const Text('Go to Surah'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: textColor.withOpacity(0.1),
                      foregroundColor: textColor,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataRow(String label, String value, Color textColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: TextStyle(
                color: textColor.withOpacity(0.7),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
