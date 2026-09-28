import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/features/sessions/tool_message_card.dart';

HermesMessage _tool(String name, {String? context, dynamic args}) {
  return HermesMessage(
    id: 'tool-1',
    sessionId: 'session-1',
    role: 'tool',
    toolName: name,
    content: context,
    toolCalls: args == null ? null : {'args': args},
  );
}

void main() {
  test('tool search gets a readable activity summary', () {
    final presentation = presentToolMessage(
      _tool('tool_search', args: {'query': 'apple health sleep'}),
    );

    expect(presentation.title, 'Tool search');
    expect(presentation.summary, 'Searched tools for “apple health sleep”');
    expect(presentation.details, contains('"query": "apple health sleep"'));
  });

  test('generic tool uses the gateway context instead of an ellipsis', () {
    final presentation = presentToolMessage(
      _tool('weather_lookup', context: 'Austin, TX'),
    );

    expect(presentation.title, 'Weather lookup');
    expect(presentation.summary, 'Austin, TX');
  });

  test('generated image parser prefers the gateway-deliverable host path', () {
    final message = _tool(
      'image_generate',
      context: jsonEncode({
        'success': true,
        'host_image': '/home/me/.hermes/cache/images/cat.png',
        'image': 'https://images.example/cat.png',
      }),
    );

    expect(
      generatedImageSource(message),
      '/home/me/.hermes/cache/images/cat.png',
    );
    expect(presentToolMessage(message).title, 'Generated image');
  });

  testWidgets('generated image is resolved through the supplied media loader', (
    tester,
  ) async {
    const onePixelPng =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+AvzZAAAAAElFTkSuQmCC';
    String? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolMessageContent(
            message: _tool(
              'image_generate',
              context: jsonEncode({
                'success': true,
                'host_image': '/home/me/.hermes/cache/images/cat.png',
              }),
            ),
            loadGeneratedImage: (source) async {
              requested = source;
              return onePixelPng;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requested, '/home/me/.hermes/cache/images/cat.png');
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('generated-image')), findsOneWidget);
  });

  testWidgets('tool details expand when the activity is tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolMessageContent(
            message: _tool('skill_view', args: {'name': 'apple-health'}),
          ),
        ),
      ),
    );

    expect(find.text('Opened the “apple-health” skill'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showFirst,
    );

    await tester.tap(find.text('Skill'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showSecond,
    );
    expect(find.textContaining('"name": "apple-health"'), findsOneWidget);
  });

  testWidgets('long tool output is collapsed by default and expands on tap', (
    tester,
  ) async {
    final longOutput = List.filled(30, 'metadata').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolMessageContent(
            message: _tool('skill_view', context: longOutput),
          ),
        ),
      ),
    );

    var summary = tester.widget<Text>(find.text('Opened $longOutput'));
    expect(summary.maxLines, 2);
    expect(summary.overflow, TextOverflow.ellipsis);

    await tester.tap(find.text('Skill'));
    await tester.pumpAndSettle();

    summary = tester.widget<Text>(find.text('Opened $longOutput'));
    expect(summary.maxLines, isNull);
    expect(summary.overflow, TextOverflow.visible);
  });
}
