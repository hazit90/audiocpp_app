import 'dart:io';

/// Whether this platform can show a file or folder in its file manager.
///
/// Used to decide whether to offer the affordance at all, so a menu item never
/// appears that would silently do nothing when pressed.
bool get canRevealInFileManager => Platform.isMacOS || Platform.isWindows;

/// What the platform's file manager is called, for button and menu labels.
String get fileManagerName => Platform.isWindows ? 'Explorer' : 'Finder';

/// Opens [directory] in the platform's file manager.
Future<void> openDirectory(Directory directory) async {
  if (Platform.isMacOS) {
    await Process.run('open', <String>[directory.path]);
  } else if (Platform.isWindows) {
    await Process.run('explorer.exe', <String>[directory.path]);
  }
}

/// Opens the file manager with [file] selected.
///
/// Selecting rather than opening is deliberate: opening a WAV hands it to
/// whatever is registered for playback, which is not what "reveal" means.
Future<void> revealFile(File file) async {
  if (Platform.isMacOS) {
    await Process.run('open', <String>['-R', file.path]);
  } else if (Platform.isWindows) {
    // explorer.exe wants /select,<path> as a single argument — a space after
    // the comma makes it open the user's Documents folder instead.
    await Process.run('explorer.exe', <String>['/select,${file.path}']);
  }
}
