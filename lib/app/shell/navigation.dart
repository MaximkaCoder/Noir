import 'package:flutter/material.dart';

/// Shell branches, in `StatefulShellRoute` order.
enum Branch {
  home('Home', Icons.home_outlined, Icons.home_rounded),
  search('Search', Icons.search_rounded, Icons.search_rounded),
  library('Library', Icons.library_music_outlined, Icons.library_music_rounded),
  settings('Settings', Icons.settings_outlined, Icons.settings_rounded);

  Branch(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
