import 'dart:async';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/material.dart';

import '../platform/reveal.dart';
import 'model_downloader.dart';
import 'model_library_controller.dart';
import 'model_storage.dart';

/// Browse, download and manage model packages.
class ModelsPage extends StatefulWidget {
  const ModelsPage({required this.controller, super.key});

  final ModelLibraryController controller;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = controller.loadError;
    if (error != null) {
      return _CentredMessage(
        icon: Icons.error_outline,
        title: 'Catalogue unavailable',
        body: '$error\n\nCheck assets/model_specs/ and rebuild.',
      );
    }

    final families = controller.families;
    if (families.isEmpty) {
      return const _CentredMessage(
        icon: Icons.inbox_outlined,
        title: 'No models available',
        body: 'No supported family is bundled with this build.',
      );
    }

    return Column(
      children: <Widget>[
        _StorageBar(controller: controller),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            itemCount: families.length,
            itemBuilder: (BuildContext context, int index) => _FamilyCard(
              spec: families[index],
              controller: controller,
            ),
          ),
        ),
      ],
    );
  }
}

class _StorageBar extends StatelessWidget {
  const _StorageBar({required this.controller});

  final ModelLibraryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = controller.installed.length;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(Icons.storage_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(
              count == 0
                  ? 'No models installed'
                  : '$count model${count == 1 ? '' : 's'} · '
                      '${formatBytes(controller.totalInstalledBytes)}',
              style: theme.textTheme.bodyMedium,
            ),
            const Spacer(),
            // The path itself, not a pointer at a Settings screen that does
            // not exist. Clicking it opens the folder, which is the thing
            // anyone wanting to "change the location" is really after.
            if (canRevealInFileManager)
              Flexible(
                child: Tooltip(
                  message: controller.storage.root.path,
                  child: TextButton.icon(
                    onPressed: () => openDirectory(controller.storage.root),
                    icon: const Icon(Icons.folder_open, size: 15),
                    label: Text(
                      'Show in $fileManagerName',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FamilyCard extends StatelessWidget {
  const _FamilyCard({required this.spec, required this.controller});

  final ModelSpec spec;
  final ModelLibraryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final packages = spec.packages;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(spec.displayName, style: theme.textTheme.titleMedium),
                ),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final String tag in spec.tags)
                      Chip(
                        label: Text(tag),
                        labelStyle: theme.textTheme.labelSmall,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ],
            ),
            if (spec.description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                spec.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            for (final ModelPackage package in packages)
              _PackageRow(
                package: package,
                isRecommended: spec.recommendedPackage?.id == package.id,
                controller: controller,
              ),
          ],
        ),
      ),
    );
  }
}

class _PackageRow extends StatefulWidget {
  const _PackageRow({
    required this.package,
    required this.isRecommended,
    required this.controller,
  });

  final ModelPackage package;
  final bool isRecommended;
  final ModelLibraryController controller;

  @override
  State<_PackageRow> createState() => _PackageRowState();
}

class _PackageRowState extends State<_PackageRow> {
  @override
  void initState() {
    super.initState();
    // Probing costs one HEAD per file, so only do it for packages a person can
    // actually install.
    if (widget.package.isFetchable) {
      unawaited(widget.controller.probeSize(widget.package));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.controller.statusFor(widget.package.id);
    if (status == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            widget.package.displayName,
                            style: theme.textTheme.bodyLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.isRecommended) ...<Widget>[
                          const SizedBox(width: 8),
                          _Badge(
                            label: 'Recommended',
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(status),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _actionFor(context, status),
            ],
          ),
          if (status.state == InstallState.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _DownloadProgressBar(progress: status.progress),
            ),
          if (status.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _ErrorNote(message: status.error!),
            ),
        ],
      ),
    );
  }

  String _subtitle(PackageStatus status) {
    final parts = <String>[
      if (widget.package.precision.isNotEmpty) widget.package.precision,
      '${widget.package.files.length} files',
    ];

    switch (status.state) {
      case InstallState.installed:
        parts.add('${formatBytes(status.installedBytes)} on disk');
      case InstallState.unavailable:
        parts.add('not published for download');
      case InstallState.incomplete:
        parts.add('files missing');
      case InstallState.notInstalled:
      case InstallState.downloading:
        if (status.remoteBytes != null) {
          parts.add(formatBytes(status.remoteBytes!));
        }
    }
    if (widget.package.download.gated) {
      parts.add('needs a Hugging Face token');
    }
    return parts.join(' · ');
  }

  Widget _actionFor(BuildContext context, PackageStatus status) {
    switch (status.state) {
      case InstallState.unavailable:
        return const _Badge(label: 'Unavailable', color: Colors.grey);

      case InstallState.downloading:
        return TextButton(
          onPressed: () => widget.controller.cancel(widget.package),
          child: const Text('Cancel'),
        );

      case InstallState.installed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.check_circle,
                size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmRemove(context),
            ),
          ],
        );

      case InstallState.incomplete:
        return FilledButton.tonal(
          onPressed: () => unawaited(widget.controller.install(widget.package)),
          child: const Text('Repair'),
        );

      case InstallState.notInstalled:
        return FilledButton(
          onPressed: () => unawaited(widget.controller.install(widget.package)),
          child: const Text('Download'),
        );
    }
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove ${widget.package.displayName}?'),
        content: const Text(
          'The files are deleted from disk. Anything shared with another '
          'installed variant is kept.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await widget.controller.remove(widget.package);
    }
  }
}

class _DownloadProgressBar extends StatelessWidget {
  const _DownloadProgressBar({required this.progress});

  final DownloadProgress? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = progress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LinearProgressIndicator(value: value?.fraction),
        const SizedBox(height: 4),
        Text(
          value == null
              ? 'Starting…'
              : '${formatBytes(value.receivedBytes)}'
                  '${value.totalBytes != null ? ' of ${formatBytes(value.totalBytes!)}' : ''}'
                  ' · file ${value.filesDone + 1} of ${value.fileCount}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CentredMessage extends StatelessWidget {
  const _CentredMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
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
