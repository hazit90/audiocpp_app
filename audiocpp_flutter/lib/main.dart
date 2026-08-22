import 'package:flutter/material.dart';

import 'src/app_shell.dart';
import 'src/theme/app_theme.dart';

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
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // Dark is the design target; light exists so a system-light machine is
      // not unusable, not as an equal alternative.
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    );
  }
}
