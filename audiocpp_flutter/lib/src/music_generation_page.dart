import 'dart:async';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/material.dart';

import 'music_generation_controller.dart';

/// Drives [MusicGenerationController]: pick a model package, describe a track,
/// generate it.
class MusicGenerationPage extends StatefulWidget {
  const MusicGenerationPage({super.key});

  @override
  State<MusicGenerationPage> createState() => _MusicGenerationPageState();
}

class _MusicGenerationPageState extends State<MusicGenerationPage> {
  final MusicGenerationController _controller = MusicGenerationController();

  final TextEditingController _modelPath = TextEditingController();
  final TextEditingController _caption = TextEditingController(
    text: 'A bright pop rock song with clean drums, crisp rhythm guitars, '
        'a clear female vocal, and polished studio production.',
  );
  final TextEditingController _lyrics = TextEditingController(
    text: '[verse] City lights are shining low. I keep moving with the glow.\n'
        '[chorus] Turn it up and let it fly. Sing the melody tonight.',
  );

  int _durationSeconds = 30;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    // Bring the engine up front so device enumeration and any missing-dylib
    // error surface before the user has typed anything.
    unawaited(_controller.initialise());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _modelPath.dispose();
    _caption.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('audio.cpp — MiniMax Music 3'),
        bottom: _controller.isBusy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              _DeviceSummary(devices: _controller.devices),
              const SizedBox(height: 24),
              _ModelSection(
                controller: _modelPath,
                enabled: !_controller.isBusy,
                loadedPath: _controller.loadedModelPath,
                onLoad: () => _controller.loadModel(_modelPath.text.trim()),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _caption,
                enabled: !_controller.isBusy,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Style caption',
                  helperText: 'Describes instrumentation, mood and production.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _lyrics,
                enabled: !_controller.isBusy,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Lyrics',
                  helperText: 'Section tags such as [verse], [chorus] and [outro] are understood.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _DurationSlider(
                seconds: _durationSeconds,
                enabled: !_controller.isBusy,
                onChanged: (int value) => setState(() => _durationSeconds = value),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _controller.canGenerate ? _generate : null,
                icon: const Icon(Icons.music_note),
                label: Text(
                  _controller.stage == GenerationStage.generating
                      ? 'Generating…'
                      : 'Generate',
                ),
              ),
              const SizedBox(height: 24),
              _StatusPanel(controller: _controller, theme: theme),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _generate() {
    return _controller.generate(
      caption: _caption.text.trim(),
      lyrics: _lyrics.text.trim(),
      durationSeconds: _durationSeconds,
    );
  }
}

class _DeviceSummary extends StatelessWidget {
  const _DeviceSummary({required this.devices});

  final List<AudioCppDevice> devices;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Text('No compute devices reported yet.');
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Compute devices', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final AudioCppDevice device in devices) Text('• $device'),
          ],
        ),
      ),
    );
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.controller,
    required this.enabled,
    required this.loadedPath,
    required this.onLoad,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? loadedPath;
  final Future<void> Function() onLoad;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Model package directory',
                  hintText: '/path/to/MiniMax-Music3-GGUF',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: enabled ? () => unawaited(onLoad()) : null,
                child: const Text('Load'),
              ),
            ),
          ],
        ),
        if (loadedPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                const Icon(Icons.check_circle, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(child: Text('Loaded: $loadedPath')),
              ],
            ),
          ),
      ],
    );
  }
}

class _DurationSlider extends StatelessWidget {
  const _DurationSlider({
    required this.seconds,
    required this.enabled,
    required this.onChanged,
  });

  final int seconds;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Frame budget: ${seconds}s'),
        Slider(
          value: seconds.toDouble(),
          min: 10,
          max: 120,
          divisions: 11,
          label: '${seconds}s',
          onChanged: enabled ? (double value) => onChanged(value.round()) : null,
        ),
        Text(
          'An autoregressive budget, not a hard length cap. Larger values raise '
          'peak memory and generation time.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller, required this.theme});

  final MusicGenerationController controller;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final String? error = controller.errorMessage;
    if (error != null) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  error,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final output = controller.lastOutput;
    if (output == null) {
      return Text(_describe(controller.stage), style: theme.textTheme.bodyMedium);
    }

    final duration = controller.lastOutputDuration;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Last generation', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(output.path),
            if (duration != null) Text('${duration.inSeconds}s of audio'),
          ],
        ),
      ),
    );
  }

  static String _describe(GenerationStage stage) => switch (stage) {
        GenerationStage.idle => 'Load a model package to begin.',
        GenerationStage.startingEngine => 'Starting the audio.cpp worker…',
        GenerationStage.loadingModel => 'Loading model weights…',
        GenerationStage.ready => 'Ready to generate.',
        GenerationStage.generating => 'Generating. This takes minutes, not seconds.',
        GenerationStage.failed => 'Something went wrong.',
      };
}
