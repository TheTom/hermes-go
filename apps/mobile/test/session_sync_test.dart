import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/db/app_database.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/hermes_api.dart';
import 'package:hermes_mobile/core/network/gateway_ws_client.dart';
import 'package:hermes_mobile/core/sync/gateway_realtime.dart';
import 'package:hermes_mobile/core/sync/session_sync_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );

  late AppDatabase db;
  late SessionSyncRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SessionSyncRepository(gatewayId: 'gw1', db: db, api: null);
  });

  tearDown(() async {
    await db.close();
  });

  test('model switches are explicitly scoped to one session', () {
    expect(
      SessionSyncRepository.modelConfigValue('grok-4.5', provider: 'xai'),
      'grok-4.5 --provider xai --session',
    );
    expect(
      SessionSyncRepository.modelConfigValue('local-model'),
      'local-model --session',
    );
  });

  test('create session is stored locally when offline', () async {
    final session = await repo.createSession(title: 'Offline chat');
    expect(session.title, 'Offline chat');
    expect(session.id, startsWith('local_'));

    final list = await repo.loadSessionsLocal();
    expect(list.length, 1);
    expect(list.first.id, session.id);
  });

  test('send message offline queues and keeps local transcript', () async {
    final session = await repo.createSession(title: 'Chat');
    final result = await repo.sendMessage(
      sessionId: session.id,
      input: 'hello offline',
    );
    expect(result.queued, isTrue);
    expect(result.messages.any((m) => m.content == 'hello offline'), isTrue);

    final msgs = await repo.loadMessagesLocal(session.id);
    expect(msgs.length, 1);
    expect(msgs.first.role, 'user');
  });

  test('sessions are scoped by gateway id', () async {
    final other = SessionSyncRepository(gatewayId: 'gw2', db: db, api: null);
    await repo.createSession(title: 'A');
    await other.createSession(title: 'B');

    expect((await repo.loadSessionsLocal()).length, 1);
    expect((await other.loadSessionsLocal()).length, 1);
    expect((await repo.loadSessionsLocal()).first.title, 'A');
    expect((await other.loadSessionsLocal()).first.title, 'B');
  });

  test('bot chat stays scoped to its server profile', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'researcher',
      'model': 'gpt-5.6-terra',
      'provider': 'openai-codex',
      'ui_meta': {
        'hermes-bots': {'chat': 'bot-session', 'title': 'Researcher'},
      },
    });

    final target = await repo.openBotChat(bot);
    expect(target.created, isFalse);
    expect(target.session.id, 'bot-session');

    final messages = await repo.syncMessages(target.session.id);
    expect(messages.single.content, 'Profile-specific answer');
    expect(
      realtime.calls
          .singleWhere((call) => call.method == 'session.resume')
          .params['profile'],
      'researcher',
    );
    expect(
      realtime.calls
          .singleWhere((call) => call.method == 'session.history')
          .params['session_id'],
      'bot-live',
    );
  });

  test(
    'profile tool history preserves gateway context and arguments',
    () async {
      final realtime = _BotRealtime(
        repo,
        historyMessages: const [
          {
            'role': 'tool',
            'name': 'tool_search',
            'context': 'apple health sleep',
            'args': {'query': 'apple health sleep'},
          },
        ],
      );
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'coach',
        'ui_meta': {
          'hermes-bots': {'chat': 'bot-session', 'title': 'Fitness Coach'},
        },
      });

      final target = await repo.openBotChat(bot);
      final message = (await repo.syncMessages(target.session.id)).single;

      expect(message.toolName, 'tool_search');
      expect(message.content, 'apple health sleep');
      expect(message.toolCalls, {
        'args': {'query': 'apple health sleep'},
      });
    },
  );

  test(
    'a stale hidden bot pointer is ignored when registry has no Bot Chat',
    () async {
      final realtime = _BotRealtime(repo, hidePinnedFromList: true);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'coach',
        'model': 'gpt-5.6-terra',
        'provider': 'openai-codex',
        'ui_meta': {
          'hermes-bots': {'chat': 'bot-session', 'title': 'Fitness Coach'},
        },
      });

      final target = await repo.openBotChat(bot);

      expect(target.created, isTrue);
      expect(target.session.id, 'fresh-health-chat');
      expect(
        realtime.calls.where(
          (call) =>
              call.method == 'session.resume' &&
              call.params['session_id'] == 'bot-session',
        ),
        isEmpty,
      );
      expect(
        realtime.calls
            .singleWhere((call) => call.method == 'session.create')
            .params,
        containsPair('title', 'Bot Chat'),
      );
    },
  );

  test('canonical Bot Chat cannot be renamed', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'coach',
      'ui_meta': {
        'hermes-bots': {'title': 'Fitness Coach'},
      },
    });

    final target = await repo.openBotChat(bot);

    await expectLater(
      repo.renameSession(target.session.id, 'Weekly review'),
      throwsA(isA<StateError>()),
    );
    expect(
      realtime.calls.where(
        (call) =>
            call.method == 'session.title' &&
            call.params['title'] == 'Weekly review',
      ),
      isEmpty,
    );
  });

  test('an ordinary bot session remains renameable', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'coach',
      'ui_meta': {
        'hermes-bots': {'title': 'Fitness Coach'},
      },
    });

    final session = await repo.createBotSession(bot);
    await repo.renameSession(session.id, 'Weekly review');

    final rename = realtime.calls.singleWhere(
      (call) =>
          call.method == 'session.title' &&
          call.params['title'] == 'Weekly review',
    );
    expect(rename.params['session_id'], 'fresh-health-live');
  });

  test('bot session inventory requests hidden profile history', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'coach',
      'model': 'gpt-5.6-terra',
      'ui_meta': {
        'hermes-bots': {'title': 'Fitness Coach'},
      },
    });

    final sessions = await repo.listBotSessions(bot);

    expect(sessions.single.id, 'bot-session');
    final list = realtime.calls.singleWhere(
      (call) => call.method == 'session.list',
    );
    expect(list.params['profile'], 'coach');
    expect(list.params['include_hidden'], isTrue);
  });

  test('starting another bot conversation does not replace Bot Chat', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'coach',
      'model': 'gpt-5.6-terra',
      'provider': 'openai-codex',
      'ui_meta': {
        'hermes-bots': {'title': 'Fitness Coach'},
      },
    });

    final created = await repo.createBotSession(bot);

    expect(created.id, 'fresh-health-chat');
    final create = realtime.calls.singleWhere(
      (call) => call.method == 'session.create',
    );
    expect(create.params['profile'], 'coach');
    expect(create.params['hidden'], isFalse);
    expect(create.params['follow_profile_config'], isTrue);
    expect(create.params['title'], startsWith('Conversation '));
    expect(
      realtime.calls.where((call) => call.method == 'profiles.configure'),
      isEmpty,
    );
  });

  test('selecting bot history leaves canonical Bot Chat unchanged', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'coach',
      'ui_meta': {
        'hermes-bots': {'title': 'Fitness Coach', 'chat': 'newer-chat'},
      },
    });
    final stored = HermesSession.fromJson({
      'id': 'older-chat',
      'title': 'Weekly check-in',
      'started_at': 1,
    });

    final selected = await repo.openBotSession(bot, stored);

    expect(selected.id, 'older-chat');
    final resume = realtime.calls.singleWhere(
      (call) => call.method == 'session.resume',
    );
    expect(resume.params['session_id'], 'older-chat');
    expect(resume.params['profile'], 'coach');
    expect(
      realtime.calls.where((call) => call.method == 'profiles.configure'),
      isEmpty,
    );
  });

  test('bot creation writes profile and desktop-compatible metadata', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);

    final bot = await repo.createBot(
      name: 'techno',
      title: 'Senior cat wrangler',
      description: 'Caturday jokes',
      shape: 'hexagon',
      color: '#f97316',
    );

    expect(bot.name, 'techno');
    expect(bot.displayName, 'Senior cat wrangler');
    final create = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.create',
    );
    expect(create.params['name'], 'techno');
    expect(create.params['clone_from'], 'default');
    expect(create.params['share_auth'], isTrue);
    final configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    final ui = configure.params['ui_meta'] as Map;
    final metadata = ui['hermes-bots'] as Map;
    expect(metadata['shape'], 'hexagon');
    expect(metadata['color'], '#f97316');
    expect(metadata['imageKind'], 'shape');
    expect(metadata['title'], 'Senior cat wrangler');
  });

  test('advanced bot creation reaches the server profile contract', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);

    await repo.createBot(
      name: 'triage',
      title: 'Inbox Triage',
      description: 'Sort incoming work',
      shape: 'circle',
      color: '#f97316',
      cloneFrom: null,
      shareAuth: false,
      noSkills: true,
      customSoul: '# Custom persona',
      model: 'gpt-5.6-sol',
      provider: 'openai-codex',
      disabledSkills: const ['unused-skill'],
      enabledToolsets: const ['web'],
      enabledMcpServers: const ['notion'],
    );

    final create = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.create',
    );
    expect(create.params['clone_from'], isNull);
    expect(create.params['share_auth'], isFalse);
    expect(create.params['no_skills'], isTrue);
    expect(create.params['soul'], startsWith('# Custom persona'));
    expect(create.params['model'], 'gpt-5.6-sol');
    expect(create.params['provider'], 'openai-codex');
    final configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    expect(configure.params['disabled_skills'], ['unused-skill']);
    expect(configure.params['enabled_toolsets'], ['web']);
    expect(configure.params['enabled_mcp_servers'], ['notion']);
  });

  test('new bot avatar is stored as the shared profile asset', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);

    final bot = await repo.createBot(
      name: 'pixel',
      title: 'Pixel',
      description: 'Pet bot',
      shape: 'circle',
      color: '#f97316',
      avatarBytes: Uint8List.fromList([1, 2, 3, 4]),
    );

    final asset = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.set_asset',
    );
    expect(asset.params['name'], 'pixel');
    expect(asset.params['asset'], 'avatar');
    expect(asset.params['data'], 'AQIDBA==');
    final configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    final metadata = (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
    expect(metadata['imageKind'], 'photo');
    expect(bot.hasAvatar, isTrue);
  });

  test(
    'bot groups update server-owned metadata without losing fields',
    () async {
      final realtime = _BotRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'techno',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Senior cat wrangler',
            'shape': 'hexagon',
            'group': 'Old group',
          },
        },
      });

      await repo.updateBotGroup(bot, 'Health and Fitness');

      final configure = realtime.calls.singleWhere(
        (call) => call.method == 'profiles.configure',
      );
      final metadata =
          (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
      expect(metadata['group'], 'Health and Fitness');
      expect(metadata['groups'], ['Health and Fitness']);
      expect(metadata['title'], 'Senior cat wrangler');
      expect(metadata['shape'], 'hexagon');
    },
  );

  test('bot group membership toggles preserve overlapping groups', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'techno',
      'ui_meta': {
        'hermes-bots': {
          'title': 'Senior cat wrangler',
          'group': 'Cats',
          'groups': ['Cats', 'Reviewers'],
        },
      },
    });

    await repo.updateBotGroupMembership(bot, 'Research', true);

    final configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    final metadata = (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
    expect(metadata['group'], 'Cats');
    expect(metadata['groups'], ['Cats', 'Reviewers', 'Research']);
  });

  test('bot pins update server metadata without losing fields', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'techno',
      'ui_meta': {
        'hermes-bots': {'title': 'Senior cat wrangler', 'group': 'Cats'},
      },
    });

    await repo.updateBotPinned(bot, true);

    final configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    final metadata = (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
    expect(metadata['pinned'], isTrue);
    expect(metadata['title'], 'Senior cat wrangler');
    expect(metadata['group'], 'Cats');
  });

  test('bot visibility writes literal values without losing fields', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'techno',
      'ui_meta': {
        'hermes-bots': {'title': 'Senior cat wrangler', 'group': 'Cats'},
      },
    });

    await repo.updateBotHidden(bot, true);

    var configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    var metadata = (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
    expect(metadata['hidden'], isTrue);
    expect(metadata['title'], 'Senior cat wrangler');
    expect(metadata['group'], 'Cats');

    realtime.calls.clear();
    await repo.updateBotHidden(bot, false);
    configure = realtime.calls.singleWhere(
      (call) => call.method == 'profiles.configure',
    );
    metadata = (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
    expect(metadata['hidden'], isFalse);
  });

  test('bot profile description parses server-owned capabilities', () async {
    final realtime = _BotRealtime(repo);
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);

    final profile = await repo.describeBotProfile('default');

    expect(profile.model, 'gpt-5.6-terra');
    expect(profile.provider, 'openai-codex');
    expect(profile.skills.single.name, 'apple-health');
    expect(profile.toolsets.single.enabled, isTrue);
    expect(profile.mcpServers.single.name, 'notion');
  });

  test(
    'Apple Health is configured through the standard capability list',
    () async {
      final realtime = _BotRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);

      await repo.createBot(
        name: 'coach',
        title: 'Fitness Coach',
        description: 'Daily health trends',
        shape: 'circle',
        color: '#f97316',
        enabledToolsets: const ['web', 'apple_health'],
      );

      final create = realtime.calls.singleWhere(
        (call) => call.method == 'profiles.create',
      );
      expect(create.params['soul'], isNot(contains('hermes-go-health-coach')));
      final configure = realtime.calls.singleWhere(
        (call) => call.method == 'profiles.configure',
      );
      expect(configure.params['enabled_toolsets'], ['web', 'apple_health']);
      final metadata =
          (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
      expect(metadata, isNot(contains('healthCoach')));
      expect(metadata, isNot(contains('healthRoutingVersion')));
    },
  );

  test(
    'opening a legacy Health Coach enables the standard toolset once',
    () async {
      final realtime = _BotRealtime(
        repo,
        soul:
            '# Fitness Coach\n\n**Role:** Fitness Coach\n\nYou are Fitness Coach, a persistent named agent (profile `coach`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions.',
        listSessionId: 'old-chat',
      );
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'coach',
        'description': 'Daily health trends',
        'model': 'gpt-5.6-terra',
        'provider': 'openai-codex',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Fitness Coach',
            'chat': 'old-chat',
            'healthCoach': true,
          },
        },
        'canonical_session': {
          'id': 'old-chat',
          'resolved_id': 'old-chat',
          'root_title': 'Bot Chat',
          'title': 'Bot Chat',
        },
      });

      final target = await repo.openBotChat(bot);

      expect(target.created, isFalse);
      expect(target.session.id, 'old-chat');
      expect(
        realtime.calls.where((call) => call.method == 'session.create'),
        isEmpty,
      );
      final capabilitySave = realtime.calls.firstWhere(
        (call) => call.params['enabled_toolsets'] != null,
      );
      expect(capabilitySave.params['enabled_toolsets'], [
        'web',
        'apple_health',
      ]);
      final metadata =
          (capabilitySave.params['ui_meta'] as Map)['hermes-bots'] as Map;
      expect(metadata, isNot(contains('chat')));
      expect(metadata, isNot(contains('healthCoach')));
      expect(metadata, isNot(contains('healthRoutingVersion')));
    },
  );

  test(
    'bot editing preserves identity metadata and updates server profile',
    () async {
      final realtime = _BotRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'techno',
        'description': 'Old description',
        'has_avatar': false,
        'ui_meta': {
          'hermes-bots': {
            'title': 'Old title',
            'shape': 'circle',
            'color': '#f97316',
            'imageKind': 'shape',
            'chat': 'bot-session',
            'created': 42,
          },
        },
      });

      final updated = await repo.updateBot(
        bot: bot,
        title: 'Senior cat wrangler',
        description: 'Caturday jokes',
        shape: 'cloud',
        color: '#8b5cf6',
        usePhoto: true,
        avatarBytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
        avatarChanged: true,
      );

      final asset = realtime.calls.singleWhere(
        (call) => call.method == 'profiles.set_asset',
      );
      expect(asset.params['name'], 'techno');
      expect(asset.params['data'], isNotEmpty);
      final configure = realtime.calls.lastWhere(
        (call) => call.method == 'profiles.configure',
      );
      expect(configure.params['description'], 'Caturday jokes');
      final metadata =
          (configure.params['ui_meta'] as Map)['hermes-bots'] as Map;
      expect(metadata['title'], 'Senior cat wrangler');
      expect(metadata['shape'], 'cloud');
      expect(metadata['imageKind'], 'photo');
      expect(metadata, isNot(contains('chat')));
      expect(metadata['created'], 42);
      expect(updated.displayName, 'Senior cat wrangler');
      expect(updated.description, 'Caturday jokes');
    },
  );

  test(
    'changing capabilities preserves the server-owned canonical chat',
    () async {
      final realtime = _BotRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'coach',
        'model': 'gpt-5.6-terra',
        'provider': 'openai-codex',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Coach',
            'chat': 'old-chat',
            'healthCoach': false,
          },
        },
      });

      await repo.updateBot(
        bot: bot,
        title: 'Coach',
        description: 'Health trends',
        shape: 'circle',
        color: '#f97316',
        usePhoto: false,
        enabledToolsets: const ['web', 'apple_health'],
      );

      final capabilitySave = realtime.calls.firstWhere(
        (call) => call.params['enabled_toolsets'] != null,
      );
      expect(capabilitySave.params['enabled_toolsets'], [
        'web',
        'apple_health',
      ]);
      final metadata =
          (capabilitySave.params['ui_meta'] as Map)['hermes-bots'] as Map;
      expect(metadata, isNot(contains('chat')));
      expect(metadata, isNot(contains('healthCoach')));
      expect(
        realtime.calls.where((call) => call.method == 'session.create'),
        isEmpty,
      );
    },
  );

  test('advanced bot edits update persona model and capabilities', () async {
    final realtime = _BotRealtime(repo, soul: '# Existing persona');
    repo.bindRealtime(realtime);
    addTearDown(realtime.dispose);
    final bot = HermesBotProfile.fromJson({
      'name': 'techno',
      'description': 'Old description',
      'ui_meta': {
        'hermes-bots': {
          'title': 'Techno',
          'chat': 'old-chat',
          'healthCoach': false,
        },
      },
    });

    await repo.updateBot(
      bot: bot,
      title: 'Techno',
      description: 'New description',
      shape: 'circle',
      color: '#f97316',
      usePhoto: false,
      soul: '# Deliberate persona',
      model: 'gpt-5.6-sol',
      provider: 'openai-codex',
      disabledSkills: const ['unused-skill'],
      enabledToolsets: const ['web'],
      enabledMcpServers: const ['notion'],
    );

    final configure = realtime.calls.firstWhere(
      (call) =>
          call.method == 'profiles.configure' && call.params['model'] != null,
    );
    expect(configure.params['soul'], '# Deliberate persona');
    expect(configure.params['model'], 'gpt-5.6-sol');
    expect(configure.params['provider'], 'openai-codex');
    expect(configure.params['disabled_skills'], ['unused-skill']);
    expect(configure.params['enabled_toolsets'], ['web']);
    expect(configure.params['enabled_mcp_servers'], ['notion']);
    expect(
      realtime.calls.where((call) => call.method == 'session.create'),
      isEmpty,
    );
  });

  test(
    'renaming a bot updates its generated soul without forking Bot Chat',
    () async {
      final realtime = _BotRealtime(
        repo,
        soul:
            '# Fotness coach\n\n**Role:** Fotness coach\n**Mission:** Daily fitness\n\nYou are Fotness coach, a persistent named agent (profile `coach`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions.',
      );
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      final bot = HermesBotProfile.fromJson({
        'name': 'coach',
        'description': 'Daily fitness',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Fotness coach',
            'chat': 'old-chat',
            'healthCoach': true,
          },
        },
      });

      await repo.updateBot(
        bot: bot,
        title: 'Fitness coach',
        description: 'Daily fitness',
        shape: 'circle',
        color: '#f97316',
        usePhoto: false,
      );

      final save = realtime.calls.firstWhere(
        (call) =>
            call.method == 'profiles.configure' && call.params['soul'] != null,
      );
      expect(save.params['soul'], contains('# Fitness coach'));
      expect(save.params['soul'], contains('You are Fitness coach,'));
      expect(save.params['soul'], isNot(contains('Fotness coach')));
      expect(
        realtime.calls.where((call) => call.method == 'session.create'),
        isEmpty,
      );
    },
  );

  test(
    'runtime hydration resumes once and keeps the session-specific model',
    () async {
      final realtime = _RuntimeRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);

      final runtime = await repo.fetchSessionRuntime('stored-session');

      expect(realtime.resumeCalls, 1);
      expect(runtime?.model, 'session-model');
      expect(runtime?.provider, 'openai-codex');
      expect(runtime?.reasoningEffort, 'high');
      expect(runtime?.fastMode, isFalse);
      expect(
        repo.sessionIdFamily('stored-session'),
        contains('live-stored-session'),
      );
    },
  );

  test(
    'approval choices come from the gateway and response is session scoped',
    () async {
      final request = GatewayApprovalRequest.fromJson({
        'command': 'python script.py',
        'description': 'Run generated code',
        'choices': ['once', 'deny'],
      }, sessionId: 'live-session');
      expect(request.command, 'python script.py');
      expect(request.description, 'Run generated code');
      expect(request.choices, ['once', 'deny']);

      final realtime = _RuntimeRealtime(repo);
      repo.bindRealtime(realtime);
      addTearDown(realtime.dispose);
      await repo.respondToApproval(
        sessionId: request.sessionId,
        choice: 'once',
      );

      expect(realtime.approvalResponses, [
        {'session_id': 'live-session', 'choice': 'once'},
      ]);
    },
  );

  group('replaceMessages re-inserts pending rows intact', () {
    test('a pending row keeps its display_kind', () async {
      // `HermesMessage.isVisibleUser` is `role == 'user' && displayKind`
      // empty. A re-insert that drops the tag turns a synthetic timeline
      // marker into a *visible* user turn, which shifts every later user
      // ordinal — the mismatch the gateway rejects with error 4018.
      await db.upsertMessage(
        CachedMessagesCompanion.insert(
          gatewayId: 'gw1',
          sessionId: 's1',
          id: 'local_marker',
          role: 'user',
          content: const Value('/model gpt-x'),
          sortIndex: const Value(3),
          syncStatus: const Value('pending'),
          displayKind: const Value('model_switch'),
        ),
      );

      // A server pull that does not include the pending row: it is deleted
      // and re-inserted from the in-memory copy.
      await db.replaceMessages('gw1', 's1', [
        CachedMessagesCompanion.insert(
          gatewayId: 'gw1',
          sessionId: 's1',
          id: 'm1',
          role: 'user',
          content: const Value('hello'),
          sortIndex: const Value(0),
        ),
      ]);

      final rows = await db.messagesForSession('gw1', 's1');
      final marker = rows.firstWhere((r) => r.id == 'local_marker');
      expect(marker.displayKind, 'model_switch');
      expect(marker.syncStatus, 'pending');
    });
  });

  group('tombstones do not outlive the session they belong to', () {
    setUp(() async {
      await db.upsertSession(
        CachedSessionsCompanion.insert(
          gatewayId: 'gw1',
          id: 's1',
          updatedAt: DateTime.utc(2026),
        ),
      );
      await db.tombstoneMessage('gw1', 's1', 'm1', fingerprint: 'user:abc');
      expect(await db.tombstonedMessageIds('gw1', 's1'), contains('m1'));
    });

    test('removeSession clears them', () async {
      await db.removeSession('gw1', 's1');
      expect(await db.tombstonedMessageIds('gw1', 's1'), isEmpty);
    });

    test('clearGatewayData clears them', () async {
      await db.clearGatewayData('gw1');
      expect(await db.tombstonedMessageIds('gw1', 's1'), isEmpty);
    });

    test(
      'the replaceSessions GC clears them once the delete is confirmed',
      () async {
        await db.markSessionDeleted('gw1', 's1');
        // Server no longer lists s1 → the delete is confirmed and the session,
        // its transcript and its tombstones all go.
        await db.replaceSessions('gw1', [
          CachedSessionsCompanion.insert(
            gatewayId: 'gw1',
            id: 's2',
            updatedAt: DateTime.utc(2026),
          ),
        ]);
        expect(await db.tombstonedMessageIds('gw1', 's1'), isEmpty);
        expect((await db.sessionsForGateway('gw1')).map((s) => s.id), ['s2']);
      },
    );

    test('a session the server still lists keeps its tombstones', () async {
      await db.replaceSessions('gw1', [
        CachedSessionsCompanion.insert(
          gatewayId: 'gw1',
          id: 's1',
          updatedAt: DateTime.utc(2026),
        ),
      ]);
      expect(await db.tombstonedMessageIds('gw1', 's1'), contains('m1'));
    });
  });

  // ── Startup redundant-fetch coalescing (single-flight) ─────────────────
  //
  // Reproduces the cold-launch shape from the bug report: several callers
  // (sessionsProvider.build(), GatewayRealtime connect, GatewayShell boot)
  // each kick their own `syncSessions()` within milliseconds of each other.
  // Only one `GET /api/sessions` should reach the network.
  group('syncSessions single-flight coalescing', () {
    late _CountingAdapter adapter;
    late SessionSyncRepository apiRepo;

    setUp(() {
      adapter = _CountingAdapter(
        '/api/sessions',
        '{"data": [{"id": "s1", "title": "Hello"}]}',
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://gw.test'))
        ..httpClientAdapter = adapter;
      final api = HermesApi(baseUrl: 'https://gw.test', apiKey: 'k', dio: dio);
      apiRepo = SessionSyncRepository(gatewayId: 'gw-flight', db: db, api: api);
    });

    test('concurrent startup triggers collapse into one HTTP call', () async {
      final results = await Future.wait([
        apiRepo.syncSessions(),
        apiRepo.syncSessions(),
        apiRepo.syncSessions(),
      ]);

      expect(adapter.calls, 1);
      for (final list in results) {
        expect(list.map((s) => s.id), ['s1']);
      }
    });

    test('a back-to-back call right after completion reuses the cached '
        'result (TTL) instead of hitting the network again', () async {
      await apiRepo.syncSessions();
      expect(adapter.calls, 1);

      // Arrives moments later — well inside the single-flight TTL.
      final again = await apiRepo.syncSessions();
      expect(adapter.calls, 1);
      expect(again.map((s) => s.id), ['s1']);
    });

    test(
      'bypassTtl (explicit user pull-to-refresh) still hits the network',
      () async {
        await apiRepo.syncSessions();
        expect(adapter.calls, 1);

        await apiRepo.syncSessions(bypassTtl: true);
        expect(adapter.calls, 2);
      },
    );
  });
}

/// Minimal Dio [HttpClientAdapter] that counts requests to [path] and
/// returns a fixed JSON [body] for every call — enough to prove single-flight
/// coalescing without a real gateway.
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.path, this.body);

  final String path;
  final String body;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains(path) || options.uri.path.contains(path)) {
      calls++;
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Simulates the cold-resume gateway race: the first response contains the
/// persisted session identity, while an erroneous second resume would expose
/// the global fallback model.
class _RuntimeRealtime extends GatewayRealtime {
  _RuntimeRealtime(SessionSyncRepository repository)
    : super(
        profile: const ConnectionProfile(
          id: 'runtime-test',
          baseUrl: 'https://gateway.test',
        ),
        sessionSync: repository,
      );

  int resumeCalls = 0;
  final List<Map<String, dynamic>> approvalResponses = [];

  @override
  bool get isLive => true;

  @override
  Stream<GatewayWsEvent> get events => const Stream.empty();

  @override
  Future<bool> ensureLive({bool force = false}) async => true;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
    Duration? timeout,
  ]) async {
    if (method == 'approval.respond') {
      approvalResponses.add(Map<String, dynamic>.from(params ?? const {}));
      return {'resolved': true};
    }
    if (method != 'session.resume') return <String, dynamic>{};
    resumeCalls++;
    return {
      'session_id': 'live-${params?['session_id']}',
      'info': {
        'model': resumeCalls == 1 ? 'session-model' : 'global-model',
        'provider': 'openai-codex',
        'reasoning_effort': 'high',
        'fast': false,
      },
    };
  }
}

class _BotRealtime extends GatewayRealtime {
  _BotRealtime(
    SessionSyncRepository repository, {
    this.soul = '',
    this.hidePinnedFromList = false,
    this.listSessionId = 'bot-session',
    this.historyMessages = const [
      {'row_id': 7, 'role': 'assistant', 'text': 'Profile-specific answer'},
    ],
  }) : super(
         profile: const ConnectionProfile(
           id: 'bot-test',
           baseUrl: 'https://gateway.test',
         ),
         sessionSync: repository,
       );

  final calls = <({String method, Map<String, dynamic> params})>[];
  final String soul;
  final bool hidePinnedFromList;
  final String listSessionId;
  final List<Map<String, dynamic>> historyMessages;

  @override
  bool get isLive => true;

  @override
  Stream<GatewayWsEvent> get events => const Stream.empty();

  @override
  Future<bool> ensureLive({bool force = false}) async => true;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
    Duration? timeout,
  ]) async {
    calls.add((method: method, params: {...?params}));
    return switch (method) {
      'session.list' => {
        'sessions': hidePinnedFromList
            ? const []
            : [
                {'id': listSessionId, 'title': 'Bot Chat', 'message_count': 1},
              ],
      },
      'session.resume' => {'session_id': 'bot-live', 'messages': const []},
      'session.history' => {'messages': historyMessages},
      'session.create' => {
        'session_id': 'fresh-health-live',
        'stored_session_id': 'fresh-health-chat',
      },
      'profiles.configure' => {
        'applied': {
          'ui_meta': true,
          'description': true,
          'soul': true,
          'model': true,
          'skills': true,
          'toolsets': true,
          'mcp_servers': true,
        },
      },
      'profiles.describe' => {
        'soul': soul,
        'model': {'default': 'gpt-5.6-terra', 'provider': 'openai-codex'},
        'skills': [
          {'name': 'apple-health', 'enabled': true},
        ],
        'toolsets': [
          {
            'name': 'web',
            'label': 'Web',
            'description': 'Search and browse',
            'tool_count': 4,
            'enabled': true,
          },
        ],
        'mcp_servers': [
          {'name': 'notion', 'enabled': false, 'transport': 'http'},
        ],
      },
      'profiles.set_asset' => {'ok': true, 'asset': 'avatar', 'size': 4},
      _ => <String, dynamic>{},
    };
  }
}
