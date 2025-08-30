import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

class SurahBanner extends StatelessWidget {
  final int surahNumber;
  final bool isCentered;

  const SurahBanner({
    super.key,
    required this.surahNumber,
    required this.isCentered,
  });

  String _getSurahSvgPath(int surahNumber) {
    final paddedNumber = surahNumber.toString().padLeft(3, '0');
    return 'assets/quran/svg/surah_name/$paddedNumber.svg';
  }

  @override
  Widget build(BuildContext context) {
    final surahNamePath = _getSurahSvgPath(surahNumber);
    final screenSize = MediaQuery.of(context).size;
    final isTablet = screenSize.width > 600;
    final bannerHeight = isTablet ? 50.0 : 40.0;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: bannerHeight * 0.8,
        maxHeight: bannerHeight * 1.2,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: FutureBuilder(
              future: rootBundle.load('assets/quran/svg/surah_banner.svg'),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return SvgPicture.asset(
                    'assets/quran/svg/surah_banner.svg',
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.center,
                  );
                } else {
                  return Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6D7C3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFD2B48C),
                        width: 1,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          Center(
            child: FutureBuilder(
              future: rootBundle.load(surahNamePath),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return SvgPicture.asset(
                    surahNamePath,
                    height: bannerHeight * 0.6,
                    fit: BoxFit.contain,
                  );
                } else {
                  return Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'سورة $surahNumber',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: isTablet ? 18 : 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'SurahNameFont',
                      ),
                      textDirection: TextDirection.rtl,
                    ),
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}