import 'package:flutter/material.dart';

class MushafAppBar extends StatelessWidget implements PreferredSizeWidget {
  final int currentPage;
  final bool isPreloading;
  final double preloadProgress;

  const MushafAppBar({
    super.key,
    required this.currentPage,
    this.isPreloading = false,
    this.preloadProgress = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text('Mushaf - Page $currentPage'),
      centerTitle: true,
      backgroundColor: const Color(0xFF8B7355),
      foregroundColor: Colors.white,
      automaticallyImplyLeading: false,
      bottom: isPreloading
          ? PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: LinearProgressIndicator(
                value: preloadProgress,
                backgroundColor: Colors.white30,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                minHeight: 2,
              ),
            )
          : null,
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(
      kToolbarHeight + (isPreloading ? 4.0 : 0.0));
}

class MushafBottomNavigationBar extends StatelessWidget {
  final Function(int)? onTap;

  const MushafBottomNavigationBar({
    super.key,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      backgroundColor: const Color(0xFF8B7355),
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.white70,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.book),
          label: 'Mushaf',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.search),
          label: 'Search',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.bookmark),
          label: 'Bookmarks',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
      onTap: onTap,
    );
  }
}
