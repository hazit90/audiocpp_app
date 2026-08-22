import 'package:flutter/material.dart';

import 'src/music_generation_page.dart';

void main() {
  runApp(const AudioCppApp());
}

/// Root of the app.
///
/// Inference runs through `package:audiocpp`, which keeps every native handle
/// on its own worker isolate; nothing here has to worry about blocking the UI.
class AudioCppApp extends StatelessWidget {
  const AudioCppApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'audio.cpp',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const MusicGenerationPage(),
    );
  }
}
