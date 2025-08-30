import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'quran_screen.dart';


void main() {
  runApp(const MuslimlyApp());
}

class MuslimlyApp extends StatelessWidget {
  const MuslimlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Muslimly Mushaf',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: const Color(0xFFF5F1E8),
      ),
      home: const MushafPageViewer(),
    );
  }
}

