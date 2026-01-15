import 'package:flutter/material.dart';
import 'mushaf_models.dart';

class MushafAppBar extends StatelessWidget implements PreferredSizeWidget {
  final int currentPage;
  final bool isPreloading;
  final double preloadProgress;
  final RendererType? currentRenderer;
  final Function(RendererType)? onRendererChanged;

  const MushafAppBar({
    super.key,
    required this.currentPage,
    this.isPreloading = false,
    this.preloadProgress = 0.0,
    this.currentRenderer,
    this.onRendererChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text('Mushaf - Page $currentPage'),
      centerTitle: true,
      backgroundColor: const Color(0xFF8B7355),
      foregroundColor: Colors.white,
      automaticallyImplyLeading: false,
      actions: [
        if (currentRenderer != null && onRendererChanged != null)
          PopupMenuButton<RendererType>(
            icon: const Icon(Icons.text_fields),
            tooltip: 'Switch Renderer',
            onSelected: onRendererChanged,
            itemBuilder: (context) => [
              PopupMenuItem<RendererType>(
                value: RendererType.digitalKhatt,
                child: Row(
                  children: [
                    if (currentRenderer == RendererType.digitalKhatt)
                      const Icon(Icons.check, size: 20, color: Colors.green),
                    if (currentRenderer == RendererType.digitalKhatt)
                      const SizedBox(width: 8),
                    const Text('Digital Khatt'),
                  ],
                ),
              ),
              PopupMenuItem<RendererType>(
                value: RendererType.qpcUthmani,
                child: Row(
                  children: [
                    if (currentRenderer == RendererType.qpcUthmani)
                      const Icon(Icons.check, size: 20, color: Colors.green),
                    if (currentRenderer == RendererType.qpcUthmani)
                      const SizedBox(width: 8),
                    const Text('QPC Uthmani'),
                  ],
                ),
              ),
              PopupMenuItem<RendererType>(
                value: RendererType.qpcV2,
                child: Row(
                  children: [
                    if (currentRenderer == RendererType.qpcV2)
                      const Icon(Icons.check, size: 20, color: Colors.green),
                    if (currentRenderer == RendererType.qpcV2)
                      const SizedBox(width: 8),
                    const Text('QPC V2'),
                  ],
                ),
              ),
            ],
          ),
      ],
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
