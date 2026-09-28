import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:hermes_mobile/core/models/hermes_models.dart';

class ToolMessagePresentation {
  const ToolMessagePresentation({
    required this.title,
    required this.summary,
    this.details,
  });

  final String title;
  final String summary;
  final String? details;
}

typedef GeneratedImageLoader = Future<String> Function(String source);

/// Desktop-compatible display source for a completed `image_generate` tool.
/// The host path wins because it is the path the authenticated filesystem
/// bridge can serve; `image` remains the fallback for local and URL-returning
/// providers.
String? generatedImageSource(HermesMessage message) {
  if (message.toolName != 'image_generate') return null;
  final raw = message.content?.trim() ?? '';
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['success'] == false) return null;
    for (final key in const ['host_image', 'image']) {
      final value = decoded[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  } catch (_) {
    return null;
  }
  return null;
}

Uint8List? _imageBytesFromDataUrl(String source) {
  if (!source.startsWith('data:image/') || !source.contains(';base64,')) {
    return null;
  }
  try {
    return base64Decode(source.substring(source.indexOf(',') + 1));
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _toolArguments(dynamic toolCalls) {
  if (toolCalls is! Map) return const {};
  final map = toolCalls.cast<dynamic, dynamic>();
  final nested = map['args'];
  final source = nested is Map ? nested : map;
  return {
    for (final entry in source.entries)
      if (entry.key != null) '${entry.key}': entry.value,
  };
}

String _textArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  return value == null ? '' : '$value'.trim();
}

String _quoted(String value) => value.isEmpty ? '' : '“$value”';

String _friendlyToolName(String raw) {
  if (raw.trim().isEmpty) return 'Tool';
  final words = raw.trim().replaceAll(RegExp(r'[_-]+'), ' ').split(' ');
  final label = words.where((word) => word.isNotEmpty).join(' ');
  if (label.isEmpty) return 'Tool';
  return '${label[0].toUpperCase()}${label.substring(1)}';
}

ToolMessagePresentation presentToolMessage(HermesMessage message) {
  final name = (message.toolName ?? 'tool').trim();
  final args = _toolArguments(message.toolCalls);
  final context = (message.content ?? '').trim();
  late final String title;
  late final String summary;

  switch (name) {
    case 'skill_view':
      title = 'Skill';
      final skill = _textArg(args, 'name');
      summary = skill.isNotEmpty
          ? 'Opened the ${_quoted(skill)} skill'
          : (context.isNotEmpty ? 'Opened $context' : 'Opened a skill');
    case 'tool_search':
      title = 'Tool search';
      final query = _textArg(args, 'query');
      summary = query.isNotEmpty
          ? 'Searched tools for ${_quoted(query)}'
          : (context.isNotEmpty
                ? 'Searched tools for $context'
                : 'Searched available tools');
    case 'terminal':
      title = 'Terminal';
      final command = _textArg(args, 'command').isNotEmpty
          ? _textArg(args, 'command')
          : _textArg(args, 'cmd');
      summary = command.isNotEmpty
          ? 'Ran ${_quoted(command)}'
          : (context.isNotEmpty ? 'Ran $context' : 'Ran a terminal command');
    case 'apple_health_status':
      title = 'Apple Health';
      summary = 'Checked Apple Health availability';
    case 'apple_health_summary':
      title = 'Apple Health';
      final metrics = _textArg(args, 'metrics');
      summary = metrics.isNotEmpty
          ? 'Read $metrics health data'
          : (context.isNotEmpty
                ? 'Read $context'
                : 'Read an Apple Health summary');
    case 'image_generate':
      title = 'Generated image';
      final prompt = _textArg(args, 'prompt');
      summary = prompt.isNotEmpty
          ? 'Created an image for ${_quoted(prompt)}'
          : 'Created an image';
    default:
      title = _friendlyToolName(name);
      summary = context.isNotEmpty ? context : 'Completed tool call';
  }

  String? details;
  if (args.isNotEmpty) {
    const encoder = JsonEncoder.withIndent('  ');
    try {
      details = encoder.convert(args);
    } catch (_) {
      details = '$args';
    }
  }
  return ToolMessagePresentation(
    title: title,
    summary: summary,
    details: details,
  );
}

class ToolMessageContent extends StatefulWidget {
  const ToolMessageContent({
    super.key,
    required this.message,
    this.loadGeneratedImage,
  });

  final HermesMessage message;
  final GeneratedImageLoader? loadGeneratedImage;

  @override
  State<ToolMessageContent> createState() => _ToolMessageContentState();
}

class _ToolMessageContentState extends State<ToolMessageContent> {
  bool _expanded = false;
  Future<String>? _generatedImage;

  @override
  void initState() {
    super.initState();
    _prepareGeneratedImage();
  }

  @override
  void didUpdateWidget(covariant ToolMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.content != widget.message.content ||
        oldWidget.message.toolName != widget.message.toolName ||
        oldWidget.loadGeneratedImage != widget.loadGeneratedImage) {
      _prepareGeneratedImage();
    }
  }

  void _prepareGeneratedImage() {
    final source = generatedImageSource(widget.message);
    if (source == null) {
      _generatedImage = null;
      return;
    }
    final uri = Uri.tryParse(source);
    if (source.startsWith('data:image/') ||
        uri?.scheme == 'http' ||
        uri?.scheme == 'https') {
      _generatedImage = Future.value(source);
      return;
    }
    final loader = widget.loadGeneratedImage;
    _generatedImage = loader == null
        ? Future<String>.error(StateError('No gateway media loader'))
        : loader(source);
  }

  Widget _image(BuildContext context, String source) {
    final bytes = _imageBytesFromDataUrl(source);
    Widget image() => bytes != null
        ? Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true)
        : Image.network(source, fit: BoxFit.contain, gaplessPlayback: true);
    return Semantics(
      key: const ValueKey('generated-image'),
      label: 'Generated image',
      button: true,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: image(),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton.filledTonal(
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        ),
        borderRadius: BorderRadius.circular(14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: image(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = presentToolMessage(widget.message);
    final hasDetails = presentation.details?.isNotEmpty ?? false;
    final hasLongSummary =
        presentation.summary.length > 120 ||
        presentation.summary.contains('\n');
    final canExpand = hasDetails || hasLongSummary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: canExpand
              ? () => setState(() => _expanded = !_expanded)
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.build_circle_outlined,
                  size: 16,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    presentation.title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (canExpand) ...[
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          presentation.summary,
          maxLines: _expanded ? null : 2,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectableText(
              presentation.details ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOut,
        ),
        if (_generatedImage != null) ...[
          const SizedBox(height: 10),
          FutureBuilder<String>(
            future: _generatedImage,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final source = snapshot.data;
              if (snapshot.hasError || source == null || source.isEmpty) {
                return Text(
                  'Generated image is unavailable on this device.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                );
              }
              return _image(context, source);
            },
          ),
        ],
      ],
    );
  }
}
