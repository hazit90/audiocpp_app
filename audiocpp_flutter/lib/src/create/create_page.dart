import 'dart:math';

import 'package:audiocpp/audiocpp.dart' show ModelSpec;
import 'package:flutter/material.dart';

import '../models/model_library_controller.dart';
import '../models/model_storage.dart' show formatBytes;
import '../theme/app_theme.dart';
import '../tracks/generation_queue.dart';
import '../tracks/track.dart';
import 'enqueue_button.dart';
import 'prompt.dart';

/// Whether the track has sung lyrics.
///
/// There is no "auto-generate lyrics" here, unlike the hosted services this
/// borrows its shape from: writing lyrics needs a language model we do not
/// ship. Offering a button that silently did nothing would be worse than
/// leaving it out.
enum LyricsMode { custom, instrumental }

/// The Create pane: describe a track, add it to the queue.
class CreatePage extends StatefulWidget {
  const CreatePage({
    required this.queue,
    required this.models,
    this.remix,
    this.onRemixApplied,
    this.onBrowseModels,
    super.key,
  });

  final GenerationQueue queue;
  final ModelLibraryController models;

  /// Settings to load into the form, from "Remix these settings".
  final GenerationParams? remix;

  /// Called once [remix] has been applied, so it is not reapplied on every
  /// rebuild — otherwise editing a remixed prompt would fight the form.
  final VoidCallback? onRemixApplied;

  /// Sends the user to the Models pane when nothing is installed.
  final VoidCallback? onBrowseModels;

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final TextEditingController _describe = TextEditingController(
    text: 'A bright pop rock song with crisp rhythm guitars, a clear female '
        'vocal, and polished studio production.',
  );
  final TextEditingController _lyrics = TextEditingController(
    text: '[verse] City lights are shining low. I keep moving with the glow.\n'
        '[chorus] Turn it up and let it fly. Sing the melody tonight.',
  );

  final Set<String> _tags = <String>{};
  LyricsMode _lyricsMode = LyricsMode.custom;
  int _tab = 0;

  int _durationSeconds = 30;
  int _steps = 30;
  int _seed = 0;
  double _guidance = 1.7;
  double _arGuidance = 1.5;
  int _topK = 50;
  bool _advancedOpen = false;

  String? _packageId;

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_onChanged);
    widget.models.addListener(_onChanged);
    if (widget.remix != null) {
      // Applied after the first frame so the callback that clears it does not
      // call setState during a build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyRemix());
    }
  }

  @override
  void didUpdateWidget(CreatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.remix != null && widget.remix != oldWidget.remix) {
      // Deferred for the same reason as in initState: _applyRemix tells the
      // shell to clear the pending remix, and that setState cannot run while
      // the shell is building us.
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyRemix());
    }
  }

  /// Loads a finished track's settings back into the form.
  ///
  /// Everything is restored, seed included: a remix that silently reseeded
  /// would make "change one thing" impossible, which is the whole point.
  void _applyRemix() {
    final params = widget.remix;
    if (params == null || !mounted) {
      return;
    }
    setState(() {
      _describe.text = params.caption;
      _lyrics.text = params.lyrics;
      _lyricsMode = params.isInstrumental
          ? LyricsMode.instrumental
          : LyricsMode.custom;
      _tags
        ..clear()
        ..addAll(params.styleTags);
      _durationSeconds = params.durationSeconds;
      _steps = params.inferenceSteps;
      _seed = params.seed;
      _guidance = params.guidanceScale;
      _arGuidance = params.arGuidanceScale;
      _topK = params.topK;
    });
    widget.onRemixApplied?.call();
  }

  @override
  void dispose() {
    widget.queue.removeListener(_onChanged);
    widget.models.removeListener(_onChanged);
    _describe.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  List<PackageStatus> get _installed => widget.models.installed;

  /// The package a new track will use.
  ///
  /// Falls back to whatever is installed rather than forcing a choice: with one
  /// package installed — the common case — the picker is a label, not a task.
  PackageStatus? get _selected {
    final installed = _installed;
    if (installed.isEmpty) {
      return null;
    }
    for (final status in installed) {
      if (status.package.id == _packageId) {
        return status;
      }
    }
    return installed.first;
  }

  /// Spec for the selected package, when the catalogue has one.
  ModelSpec? get _spec {
    final selected = _selected;
    return selected == null
        ? null
        : widget.models.catalog.specForPackage(selected.package.id);
  }

  /// Whether the selected model can only sing, never play instrumentally.
  ///
  /// Read from the spec rather than hardcoded: MiniMax Music 3 declares
  /// `lyrics` as a required request option, and offering an Instrumental button
  /// that produces a run the engine rejects is worse than not offering it.
  bool get _lyricsRequired =>
      _spec?.options.findRequest('lyrics')?.required ?? false;

  /// Why the track cannot be queued yet, if it cannot.
  String? get _blockedReason {
    if (_selected == null) {
      return 'Install a model first';
    }
    if (_effectiveLyricsMode == LyricsMode.custom &&
        _lyrics.text.trim().isEmpty) {
      return _lyricsRequired
          ? 'This model needs lyrics'
          : 'Write lyrics, or switch to Instrumental';
    }
    if (composeCaption(described: _describe.text, tags: _tags.toList())
        .trim()
        .isEmpty) {
      return 'Describe the track first';
    }
    return null;
  }

  /// The mode actually in force, which the spec can override.
  LyricsMode get _effectiveLyricsMode =>
      _lyricsRequired ? LyricsMode.custom : _lyricsMode;

  GenerationParams _buildParams() {
    return GenerationParams(
      caption: composeCaption(described: _describe.text, tags: _tags.toList()),
      lyrics: _effectiveLyricsMode == LyricsMode.instrumental
          ? ''
          : _lyrics.text.trim(),
      durationSeconds: _durationSeconds,
      inferenceSteps: _steps,
      guidanceScale: _guidance,
      arGuidanceScale: _arGuidance,
      topK: _topK,
      seed: _seed,
      styleTags: _tags.toList(),
    );
  }

  /// What a run with the settings currently in the form would cost.
  ///
  /// Read on every rebuild so the number under a slider moves with it. It is
  /// the queue's own measured estimate, self-correcting after the first run on
  /// this machine, and it cannot see the weight upload — hence `≈`, and hence
  /// [_coarseDuration] rounding it rather than reporting seconds it does not
  /// actually know.
  Duration? get _estimate {
    final selected = _selected;
    return selected == null
        ? null
        : widget.queue.estimateFor(_buildParams(), selected.package.id);
  }

  Future<void> _enqueue() async {
    final selected = _selected;
    if (selected == null) {
      return;
    }
    final params = _buildParams();
    await widget.queue.enqueue(
      params: params,
      modelPackageId: selected.package.id,
      title: deriveTitle(params.caption),
    );
    if (mounted) {
      // A queued track is not a finished one, and the pane it lands in may not
      // be on screen at this width, so say so.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added to the queue — ${widget.queue.waitingCount} '
              'waiting'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.models.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // A form you cannot submit is not a useful first screen. Until a model is
    // on disk, say what the app needs and offer the one action that helps.
    if (_installed.isEmpty) {
      return _FirstRun(onBrowse: widget.onBrowseModels);
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: <Widget>[
            _PromptCard(
              tab: _tab,
              describe: _describe,
              tags: _tags,
              onTab: (int value) => setState(() => _tab = value),
              onToggleTag: (String tag) => setState(() {
                if (!_tags.remove(tag)) {
                  _tags.add(tag);
                }
              }),
            ),
            const SizedBox(height: AppTheme.gap),
            _ModelCard(
              installed: _installed,
              selected: _selected,
              onSelected: (String id) => setState(() => _packageId = id),
            ),
            const SizedBox(height: AppTheme.gap),
            _LyricsCard(
              mode: _effectiveLyricsMode,
              controller: _lyrics,
              required: _lyricsRequired,
              onMode: (LyricsMode mode) => setState(() => _lyricsMode = mode),
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: AppTheme.gap),
            _LengthCard(
              seconds: _durationSeconds,
              onChanged: (int value) =>
                  setState(() => _durationSeconds = value),
            ),
            const SizedBox(height: AppTheme.gap),
            _AdvancedCard(
              open: _advancedOpen,
              steps: _steps,
              seed: _seed,
              guidance: _guidance,
              arGuidance: _arGuidance,
              topK: _topK,
              estimate: _estimate,
              onOpen: (bool value) => setState(() => _advancedOpen = value),
              onSteps: (int v) => setState(() => _steps = v),
              onSeed: (int v) => setState(() => _seed = v),
              onGuidance: (double v) => setState(() => _guidance = v),
              onArGuidance: (double v) => setState(() => _arGuidance = v),
              onTopK: (int v) => setState(() => _topK = v),
            ),
            const SizedBox(height: 20),
            EnqueueButton(
              enabled: _blockedReason == null,
              disabledReason: _blockedReason,
              waiting: widget.queue.waitingCount,
              wait: widget.queue.estimatedWait,
              onPressed: _enqueue,
            ),
          ],
        ),
      ),
    );
  }
}

/// Describe / Style, over one caption.
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.tab,
    required this.describe,
    required this.tags,
    required this.onTab,
    required this.onToggleTag,
  });

  final int tab;
  final TextEditingController describe;
  final Set<String> tags;
  final ValueChanged<int> onTab;
  final ValueChanged<String> onToggleTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _Tab(label: 'Describe', selected: tab == 0, onTap: () => onTab(0)),
                const SizedBox(width: 18),
                _Tab(label: 'Style', selected: tab == 1, onTap: () => onTab(1)),
                const Spacer(),
                if (tags.isNotEmpty)
                  Text(
                    '${tags.length} selected',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (tab == 0)
              TextField(
                controller: describe,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Instrumentation, mood, production…',
                ),
              )
            else
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: <Widget>[
                  for (final String tag in kStyleTags)
                    FilterChip(
                      label: Text(tag),
                      selected: tags.contains(tag),
                      onSelected: (_) => onToggleTag(tag),
                    ),
                ],
              ),
            if (tab == 1 && tags.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Added to the description: ${tags.join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Which installed package to generate with.
class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.installed,
    required this.selected,
    required this.onSelected,
  });

  final List<PackageStatus> installed;
  final PackageStatus? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('MODEL', style: _labelStyle(theme)),
            const SizedBox(height: 8),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selected?.package.id,
                isExpanded: true,
                borderRadius: BorderRadius.circular(10),
                items: <DropdownMenuItem<String>>[
                  for (final PackageStatus status in installed)
                    DropdownMenuItem<String>(
                      value: status.package.id,
                      child: Text(
                        '${status.package.id}  ·  '
                        '${formatBytes(status.installedBytes)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? value) {
                  if (value != null) {
                    onSelected(value);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LyricsCard extends StatelessWidget {
  const _LyricsCard({
    required this.mode,
    required this.controller,
    required this.required,
    required this.onMode,
    required this.onChanged,
  });

  final LyricsMode mode;
  final TextEditingController controller;

  /// The model cannot generate without lyrics, so there is no choice to offer.
  final bool required;

  final ValueChanged<LyricsMode> onMode;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('LYRICS', style: _labelStyle(theme)),
                if (required) ...<Widget>[
                  const SizedBox(width: 8),
                  Text(
                    '· required by this model',
                    style: _labelStyle(theme),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (!required)
              SegmentedButton<LyricsMode>(
              segments: const <ButtonSegment<LyricsMode>>[
                ButtonSegment<LyricsMode>(
                  value: LyricsMode.custom,
                  label: Text('Write lyrics'),
                ),
                ButtonSegment<LyricsMode>(
                  value: LyricsMode.instrumental,
                  label: Text('Instrumental'),
                ),
              ],
              selected: <LyricsMode>{mode},
              onSelectionChanged: (Set<LyricsMode> value) =>
                  onMode(value.first),
              showSelectedIcon: false,
            ),
            if (mode == LyricsMode.custom) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                onChanged: (String _) => onChanged(),
                decoration: const InputDecoration(
                  hintText: '[verse] …',
                  helperText: 'Section tags such as [verse], [chorus] and '
                      '[outro] are understood.',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LengthCard extends StatelessWidget {
  const _LengthCard({required this.seconds, required this.onChanged});

  final int seconds;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('LENGTH BUDGET · ${seconds}s', style: _labelStyle(theme)),
            Slider(
              value: seconds.toDouble(),
              min: 10,
              max: 120,
              divisions: 11,
              label: '${seconds}s',
              onChanged: (double value) => onChanged(value.round()),
            ),
            Text(
              'A frame budget, not a hard cap — the finished track may be '
              'shorter. Larger values raise peak memory and generation time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything under "Advanced controls".
///
/// Every row says the same thing twice, on purpose. First what moving it does
/// to the track you get, then the engine's own term for it underneath, dimmer.
/// The terms are worth keeping — they are what the model spec, the logs and
/// audio.cpp's documentation call these, so a term dropped here is a person who
/// cannot look the parameter up — but on their own they say what a knob *is* and
/// never whether you want more of it. The badge beside each number does the
/// third job: where the value sits on its range, which a bare `1.70` cannot say.
class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({
    required this.open,
    required this.steps,
    required this.seed,
    required this.guidance,
    required this.arGuidance,
    required this.topK,
    required this.estimate,
    required this.onOpen,
    required this.onSteps,
    required this.onSeed,
    required this.onGuidance,
    required this.onArGuidance,
    required this.onTopK,
  });

  final bool open;
  final int steps;
  final int seed;
  final double guidance;
  final double arGuidance;
  final int topK;

  /// Predicted run time at these settings, when a model is selected.
  final Duration? estimate;

  final ValueChanged<bool> onOpen;
  final ValueChanged<int> onSteps;
  final ValueChanged<int> onSeed;
  final ValueChanged<double> onGuidance;
  final ValueChanged<double> onArGuidance;
  final ValueChanged<int> onTopK;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final predicted = estimate;

    // The estimate rides the header only while the card is shut. Open, it sits
    // on the steps row where it belongs — steps are what move it — and showing
    // it twice a hundred pixels apart just looks like a bug.
    final summary = <String>[
      'seed $seed',
      '$steps steps',
      if (!open && predicted != null) '≈${_coarseDuration(predicted)}',
    ].join(' · ');

    return Card(
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () => onOpen(!open),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Text('Advanced controls',
                      style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(open ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: <Widget>[
                  _NumberRow(
                    label: 'Inference steps',
                    badge: <String>[
                      _stepsCharacter(steps),
                      if (predicted != null) '≈${_coarseDuration(predicted)}',
                    ].join(' · '),
                    meaning: 'Refinement passes over each chunk of audio. Too '
                        'few sounds smeared and watery; past roughly 50 the '
                        'difference stops being audible and you only wait '
                        'longer.',
                    detail: 'Flow-matching Euler steps per chunk — the biggest '
                        'single lever on how long a run takes.',
                    value: steps.toDouble(),
                    min: 4,
                    max: 100,
                    onChanged: (double v) => onSteps(v.round()),
                    format: (double v) => '${v.round()}',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text('Seed  ·  $seed',
                                  style: theme.textTheme.bodyMedium),
                            ),
                            TextButton.icon(
                              onPressed: () => onSeed(Random().nextInt(1 << 31)),
                              icon: const Icon(Icons.casino_outlined, size: 18),
                              label: const Text('Randomise'),
                            ),
                            TextButton(
                              onPressed: seed == 0 ? null : () => onSeed(0),
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                        const _Explainer(
                          meaning: 'The same seed with the same prompt and '
                              'settings gives you the same track every time. '
                              'Change it for a different take on the same idea, '
                              'keep it to hear one setting move on its own.',
                          // Worth stating outright: "Reset" reads like "no seed"
                          // and it is not one. 0 is a value like any other, and
                          // the run it produces is as fixed as 12345's.
                          detail: 'Starting noise for both samplers. 0 is a '
                              'fixed seed, not a random one.',
                        ),
                      ],
                    ),
                  ),
                  _NumberRow(
                    label: 'Guidance scale',
                    badge: _guidanceCharacter(guidance),
                    meaning: 'How literally the music follows your '
                        'description. Low drifts off-prompt and sounds freer; '
                        'high locks onto it but turns harsh and flat.',
                    detail: 'Flow transformer CFG. Both branches run whatever '
                        'it is set to, so moving it costs no extra time.',
                    value: guidance,
                    // The engine rejects a scale of zero outright ("guidance
                    // scales must be positive") rather than taking an unguided
                    // path, so a slider that reaches 0 only offers a run that
                    // cannot start. The spec's own min of 0.0 disagrees with
                    // the check in the pipeline; the check is the one that runs.
                    min: 0.1,
                    max: 5,
                    onChanged: onGuidance,
                    format: (double v) => v.toStringAsFixed(2),
                  ),
                  _NumberRow(
                    label: 'AR guidance scale',
                    badge: _guidanceCharacter(arGuidance),
                    meaning: 'The same, one stage earlier: how closely the '
                        'melody and phrasing follow the prompt, before any '
                        'audio exists to shape.',
                    detail: 'Semantic and depth AR CFG.',
                    value: arGuidance,
                    min: 0.1,
                    max: 5,
                    onChanged: onArGuidance,
                    format: (double v) => v.toStringAsFixed(2),
                  ),
                  _NumberRow(
                    label: 'Top-k',
                    badge: _topKCharacter(topK),
                    meaning: 'How many candidates the model may choose between '
                        'at each step. Low keeps it safe and repetitive; high '
                        'takes more risks, including bad ones.',
                    detail: 'Sampling bound for semantic and residual codes.',
                    value: topK.toDouble(),
                    min: 1,
                    max: 200,
                    onChanged: (double v) => onTopK(v.round()),
                    format: (double v) => '${v.round()}',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Where a value sits on its range, in a word.
///
/// Ranges rather than thresholds anyone should read as a recommendation: they
/// are here so a number has a direction, not to hide the number.
String _stepsCharacter(int steps) {
  if (steps < 14) {
    return 'rough';
  }
  if (steps < 26) {
    return 'quick';
  }
  if (steps <= 50) {
    return 'balanced';
  }
  return 'diminishing';
}

String _guidanceCharacter(double scale) {
  if (scale < 1.0) {
    return 'loose';
  }
  if (scale < 2.2) {
    return 'balanced';
  }
  if (scale < 3.5) {
    return 'literal';
  }
  return 'over-driven';
}

String _topKCharacter(int topK) {
  if (topK <= 10) {
    return 'safe';
  }
  if (topK <= 90) {
    return 'balanced';
  }
  return 'adventurous';
}

/// `≈4 min`, coarse on purpose.
///
/// The estimate behind it is measured but incomplete — it cannot see the weight
/// upload — and `4:07` would claim a precision this does not have. Anything a
/// person decides with it ("is this a coffee or a lunch") survives rounding.
String _coarseDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 90) {
    return '${(seconds / 10).round() * 10}s';
  }
  final minutes = (seconds / 60).round();
  return minutes < 60 ? '$minutes min' : '${minutes ~/ 60}h ${minutes % 60}m';
}

/// A control's two lines: what it does to the music, then what it is called.
class _Explainer extends StatelessWidget {
  const _Explainer({required this.meaning, required this.detail});

  final String meaning;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          meaning,
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 2),
        Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: muted.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.badge,
    required this.meaning,
    required this.detail,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.format,
  });

  final String label;

  /// Where this value sits, in a word or two — and, for steps, what it costs.
  final String badge;

  /// What moving the slider does to the track.
  final String meaning;

  /// What the engine calls it.
  final String detail;

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String Function(double) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A remixed track can carry a value from outside the range this slider now
    // offers — the guidance floor moved once already — and a Slider asserts on
    // one. Clamping shows the nearest legal value and the next drag writes it
    // back, which is better than the pane failing to build.
    final position = value.clamp(min, max);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Flexible(
                child: Text(
                  badge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                format(position),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          Slider(value: position, min: min, max: max, onChanged: onChanged),
          _Explainer(meaning: meaning, detail: detail),
        ],
      ),
    );
  }
}

/// What Create shows before any model is installed.
class _FirstRun extends StatelessWidget {
  const _FirstRun({required this.onBrowse});

  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.graphic_eq,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 18),
              Text(
                'Everything runs on this machine',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Music is generated locally, so the model has to be on disk '
                'first. It is a several-gigabyte download, once.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onBrowse,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Choose a model'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

TextStyle? _labelStyle(ThemeData theme) => theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      letterSpacing: 0.6,
    );
