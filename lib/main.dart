import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  runApp(const MuslimlyApp());
}

class MuslimlyApp extends StatelessWidget {
  const MuslimlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mushaf',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: const Color(0xFFF5F1E8),
      ),
      home: const HomeScreen(),
    );
  }
}



