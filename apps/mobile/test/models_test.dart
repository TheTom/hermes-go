import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/dashboard_client.dart';

void main() {
  test('session runtime state parses model/provider and service tier', () {
    final state = SessionRuntimeState.fromJson({
      'model': 'gpt-5.4',
      'provider': 'openai-codex',
      'model_snapshot': 'old-model',
      'provider_snapshot': 'custom',
      'reasoning_effort': 'high',
      'service_tier': 'priority',
    });

    expect(state.model, 'gpt-5.4');
    expect(state.provider, 'openai-codex');
    expect(state.reasoningEffort, 'high');
    expect(state.fastMode, isTrue);
  });

  test('session parsing tolerates non-string optional fields', () {
    final session = HermesSession.fromJson({
      'id': 42,
      'title': {'unexpected': true},
      'model': 7,
      'message_count': '3',
    });

    expect(session.id, '42');
    expect(session.title, isNull);
    expect(session.model, '7');
    expect(session.messageCount, 3);
  });

  test('message parsing accepts structured reasoning content', () {
    final message = HermesMessage.fromJson({
      'id': 'm1',
      'role': 'assistant',
      'reasoning': [
        {'text': 'first'},
        {'text': 'second'},
      ],
    });

    expect(message.reasoning, 'first\nsecond');
  });

  test('cron job preserves rich server detail without conflating errors', () {
    final job = HermesJob.fromJson({
      'id': 'job-1',
      'name': 'Health sync',
      'last_status': 'error',
      'last_error': 'Model configuration drifted',
      'last_delivery_error': 'No home channel',
      'model': 'gpt-5.6-terra',
      'provider': 'openai-codex',
      'model_snapshot': 'old-model',
      'provider_snapshot': 'custom',
      'created_at': '2026-08-01T12:00:00Z',
      'paused_reason': 'manual',
      'skill': 'health-tracking',
      'skills': ['health-tracking', 'apple-health'],
      'workdir': '/workspace',
      'context_from': 'origin',
      'enabled_toolsets': ['web', 'terminal'],
      'no_agent': false,
      'repeat': {'completed': 42, 'times': 100},
      'future_server_field': {'kept': true},
    });

    expect(job.lastStatus, 'error');
    expect(job.lastError, 'Model configuration drifted');
    expect(job.lastDeliveryError, 'No home channel');
    expect(job.model, 'gpt-5.6-terra');
    expect(job.provider, 'openai-codex');
    expect(job.modelSnapshot, 'old-model');
    expect(job.providerSnapshot, 'custom');
    expect(job.skills, ['health-tracking', 'apple-health']);
    expect(job.completedRuns, 42);
    expect(job.totalRuns, 100);
    expect(job.enabledToolsets, ['web', 'terminal']);
    expect(job.raw['future_server_field'], {'kept': true});
  });

  test(
    'bot roster is gated by the server capability and mirrors ui metadata',
    () {
      final roster = HermesBotRoster.fromServer({
        'bot_mode_protocol': true,
        'profiles': [
          {
            'name': 'researcher',
            'model': 'gpt-5.6-terra',
            'provider': 'openai-codex',
            'description': 'Finds evidence',
            'last_session': {
              'id': 'session-1',
              'preview': 'Latest findings',
              'last_active': 1786924800,
              'message_count': 9,
            },
            'canonical_session': {
              'id': 'canonical-root',
              'resolved_id': 'canonical-tip',
              'root_title': 'Bot Chat',
              'title': 'Bot Chat',
              'preview': 'Fresh direct reply',
              'last_active': 1786924900,
              'message_count': 11,
            },
            'ui_meta': {
              'hermes-bots': {
                'title': 'Research Desk',
                'color': '#336699',
                'shape': 'hexagon',
                'imageKind': 'shape',
                'chat': 'session-1',
                'created': 1786800000000,
                'pinned': true,
                'group': 'Research',
                'groups': ['Research', 'Editorial'],
              },
            },
          },
          {
            'name': 'archived-researcher',
            'ui_meta': {
              'hermes-bots': {'title': 'Archived Researcher', 'hidden': true},
            },
          },
          {'name': 'default', 'is_default': true},
        ],
      });

      expect(roster.available, isTrue);
      expect(roster.profiles, hasLength(1));
      expect(roster.hiddenProfiles, hasLength(1));
      expect(roster.hiddenProfiles.single.name, 'archived-researcher');
      expect(roster.hiddenProfiles.single.hidden, isTrue);
      final researcher = roster.profiles.first;
      expect(researcher.displayName, 'Research Desk');
      expect(researcher.chatSessionId, 'canonical-tip');
      expect(researcher.canonicalRegistryId, 'canonical-root');
      expect(researcher.activitySession?.preview, 'Fresh direct reply');
      expect(researcher.handle, 'researcher');
      expect(researcher.showsHandle, isTrue);
      expect(researcher.shape, 'hexagon');
      expect(researcher.usesImageAvatar, isFalse);
      expect(researcher.lastSession?.preview, 'Latest findings');
      expect(researcher.pinned, isTrue);
      expect(researcher.group, 'Research');
      expect(researcher.groups, ['Research', 'Editorial']);

      final cleared = HermesBotProfile.fromJson({
        'name': 'cleared',
        'ui_meta': {
          'hermes-bots': {'group': 'Legacy stale value', 'groups': <String>[]},
        },
      });
      expect(cleared.group, isNull);
      expect(cleared.groups, isEmpty);
    },
  );

  test('ordinary default-profile chat is never presented as a bot', () {
    final roster = HermesBotRoster.fromServer({
      'bot_mode_protocol': true,
      'profiles': [
        {
          'name': 'default',
          'is_default': true,
          'last_session': {
            'id': 'apple-review',
            'preview': 'Hi, Apple Review Team!',
            'message_count': 2,
          },
        },
      ],
    });

    expect(roster.available, isTrue);
    expect(roster.profiles, isEmpty);
  });

  test('legacy named profiles remain visible without bot UI metadata', () {
    final profiles = <Map<String, dynamic>>[
      for (var index = 1; index <= 9; index++)
        {
          'name': 'probe-$index',
          if (index <= 6)
            'ui_meta': {
              'hermes-bots': {'title': 'Probe $index'},
            },
        },
      {
        'name': 'default',
        'is_default': true,
        'last_session': {'id': 'ordinary-chat'},
      },
    ];

    final roster = HermesBotRoster.fromServer({
      'bot_mode_protocol': true,
      'profiles': profiles,
    });

    expect(roster.profiles, hasLength(9));
    expect(
      roster.profiles.map((profile) => profile.name),
      containsAll(['probe-7', 'probe-8', 'probe-9']),
    );
    expect(
      roster.profiles.any((profile) => profile.name == 'default'),
      isFalse,
    );
  });

  test('group chat messages parse from the gateway profile metadata', () {
    final rooms = parseHermesBotGroupRooms({
      'profiles': [
        {
          'name': 'default',
          'is_default': true,
          'ui_meta': {
            'hermes-bots-groups': {
              'version': 1,
              'rooms': {
                'Research': {
                  'members': [
                    {'name': 'reader'},
                    {'name': 'writer'},
                  ],
                  'log': [
                    {
                      'from': {'kind': 'user', 'name': 'You'},
                      'text': 'What changed?',
                      'at': 1787072400000,
                    },
                    {
                      'from': {
                        'kind': 'member',
                        'name': 'reader',
                        'source': 'Mac mini',
                      },
                      'text': 'The gateway contract changed.',
                      'at': 1787072401000,
                    },
                  ],
                },
              },
            },
          },
        },
      ],
    });

    expect(rooms.keys, ['Research']);
    expect(rooms['Research']?.members, ['reader', 'writer']);
    expect(rooms['Research']?.messages, hasLength(2));
    expect(rooms['Research']?.messages.first.isUser, isTrue);
    expect(rooms['Research']?.messages.last.name, 'reader');
    expect(rooms['Research']?.messages.last.source, 'Mac mini');
  });

  test('v3 group rooms use their projected name and preserve identity', () {
    final rooms = parseHermesBotGroupRooms({
      'profiles': [
        {
          'name': 'default',
          'is_default': true,
          'ui_meta': {
            'hermes-bots-groups': {
              'version': 3,
              'rooms': {
                'id:room-123': {
                  'name': 'Research team',
                  'roomId': 'room-123',
                  'revision': 42,
                  'members': [
                    {'name': 'reader'},
                  ],
                  'log': [
                    {
                      'id': 'writer:7',
                      'thread': 'thread-9',
                      'from': {'kind': 'member', 'name': 'reader'},
                      'text': 'Found it.',
                      'at': 1787072401000,
                    },
                  ],
                },
              },
            },
          },
        },
      ],
    });

    expect(rooms.keys, ['Research team']);
    expect(rooms.containsKey('id:room-123'), isFalse);
    expect(rooms['Research team']?.roomId, 'room-123');
    expect(rooms['Research team']?.revision, 42);
    expect(rooms['Research team']?.messages.single.id, 'writer:7');
    expect(rooms['Research team']?.messages.single.thread, 'thread-9');
  });

  test('v3 group room tombstones prevent stale rooms from reappearing', () {
    final rooms = parseHermesBotGroupRooms({
      'profiles': [
        {
          'name': 'default',
          'is_default': true,
          'ui_meta': {
            'hermes-bots-groups': {
              'version': 3,
              'rooms': {
                'id:deleted-room': {
                  'name': 'Deleted room',
                  'roomId': 'deleted-room',
                  'revision': 99,
                  'log': [
                    {
                      'from': {'kind': 'user', 'name': 'You'},
                      'text': 'Stale message',
                    },
                  ],
                },
                'name:legacy-room': {
                  'name': 'Legacy room',
                  'revision': 4,
                  'log': [
                    {
                      'from': {'kind': 'user', 'name': 'You'},
                      'text': 'Also stale',
                    },
                  ],
                },
              },
              'deleted': {'id:deleted-room': 1, 'name:legacy-room': 4},
            },
          },
        },
      ],
    });

    expect(rooms, isEmpty);
  });

  test(
    'bot roster stays hidden when neither capability nor plugin is exposed',
    () {
      final roster = HermesBotRoster.fromServer({
        'profiles': [
          {'name': 'default'},
        ],
      });

      expect(roster.available, isFalse);
      expect(roster.profiles, isEmpty);
    },
  );

  test('installed hermes-bots plugin is a compatibility capability signal', () {
    final roster = HermesBotRoster.fromServer(
      {
        'profiles': [
          {'name': 'default'},
        ],
      },
      pluginPayload: {
        'plugins': [
          {'name': 'hermes-bots', 'enabled': true},
        ],
      },
    );

    expect(roster.available, isTrue);
    expect(roster.profiles, isEmpty);
  });

  test('gateway book ignores malformed selector types', () {
    final book = GatewayBook.fromJson({
      'gateways': [
        {'id': 'gw', 'baseUrl': 'https://gw.example'},
      ],
      'defaultGatewayId': {'not': 'a string'},
    });

    expect(book.resolved?.id, 'gw');
  });

  test('model options preserve server reasoning levels and thinking gate', () {
    final options = ModelOptionsResult.fromJson({
      'providers': [
        {
          'slug': 'openai-codex',
          'name': 'ChatGPT',
          'models': ['gpt-5.6-sol'],
          'capabilities': {
            'gpt-5.6-sol': {
              'reasoning': true,
              'thinking': false,
              'reasoning_efforts': [
                {'effort': 'low', 'description': 'Fast'},
                {'effort': 'ultra', 'description': 'Delegates'},
              ],
              'default_reasoning_effort': 'low',
              'fast': true,
            },
          },
        },
      ],
    });

    final caps = options.providers.single.capsFor('gpt-5.6-sol');
    expect(caps.thinkingSupported, isFalse);
    expect(caps.reasoningEfforts?.map((option) => option.effort), [
      'low',
      'ultra',
    ]);
    expect(caps.reasoningEfforts?.last.description, 'Delegates');
    expect(caps.defaultReasoningEffort, 'low');
    expect(caps.fast, isTrue);
  });
}
