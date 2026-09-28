import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:hermes_mobile/core/db/app_database.dart';
import 'package:hermes_mobile/core/models/context_usage.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/dashboard_client.dart';
import 'package:hermes_mobile/core/network/gateway_ws_client.dart';
import 'package:hermes_mobile/core/network/hermes_api.dart';
import 'package:hermes_mobile/core/services/app_lifecycle.dart';
import 'package:hermes_mobile/core/services/result_notifier.dart';
import 'package:hermes_mobile/core/services/slash_commands.dart';
import 'package:hermes_mobile/core/sync/background_sync.dart';
import 'package:hermes_mobile/core/sync/completion_errors.dart';
import 'package:hermes_mobile/core/sync/gateway_realtime.dart';
import 'package:hermes_mobile/core/sync/single_flight.dart';
import 'package:hermes_mobile/core/sync/watch_store.dart';
import 'package:hermes_mobile/l10n/l10n.dart';

const _legacyHealthCoachSoulMarker = '<!-- hermes-go-health-coach -->';

String _withoutLegacyHealthRouting(String soul) {
  final lines = soul.split('\n');
  final marker = lines.indexOf(_legacyHealthCoachSoulMarker);
  if (marker >= 0) {
    final removeCount = (lines.length - marker).clamp(0, 3);
    lines.removeRange(marker, marker + removeCount);
    if (marker > 0 && lines[marker - 1].isEmpty) lines.removeAt(marker - 1);
  }
  return lines.join('\n').trim();
}

String _generatedBotSoul(String profile, String title, String description) {
  final displayName = title.isEmpty ? profile : title;
  return [
    '# $displayName',
    '',
    if (title.isNotEmpty) '**Role:** $title',
    if (description.isNotEmpty) '**Mission:** $description',
    '',
    'You are $displayName, a persistent named agent (profile `$profile`) on this machine.',
    'You keep your own memory, skills, and conversation history across sessions.',
  ].join('\n');
}

/// Update only identity lines written by [_generatedBotSoul]. A soul without
/// the generated marker is user-authored and is deliberately left untouched.
String? _updateGeneratedBotSoul(
  String soul, {
  required String profile,
  required String title,
  required String description,
}) {
  final marker = 'persistent named agent (profile `$profile`)';
  if (!soul.contains(marker)) return null;
  final displayName = title.isEmpty ? profile : title;
  final lines = soul.split('\n');

  final heading = lines.indexWhere((line) => line.startsWith('# '));
  if (heading >= 0) lines[heading] = '# $displayName';

  void replaceTagged(String prefix, String value) {
    final index = lines.indexWhere((line) => line.startsWith(prefix));
    if (index >= 0) {
      if (value.isEmpty) {
        lines.removeAt(index);
      } else {
        lines[index] = '$prefix$value';
      }
      return;
    }
    if (value.isEmpty) return;
    final markerIndex = lines.indexWhere((line) => line.contains(marker));
    lines.insert(markerIndex < 0 ? lines.length : markerIndex, '$prefix$value');
  }

  replaceTagged('**Role:** ', title);
  replaceTagged('**Mission:** ', description);
  final identity = lines.indexWhere((line) => line.contains(marker));
  if (identity >= 0) {
    lines[identity] =
        'You are $displayName, a persistent named agent (profile `$profile`) on this machine.';
  }
  final healthMarker = lines.indexOf(_legacyHealthCoachSoulMarker);
  if (healthMarker >= 0) {
    final removeCount = (lines.length - healthMarker).clamp(0, 3);
    lines.removeRange(healthMarker, healthMarker + removeCount);
    if (healthMarker > 0 && lines[healthMarker - 1].isEmpty) {
      lines.removeAt(healthMarker - 1);
    }
  }
  return lines.join('\n');
}

/// Local-first sessions for one gateway, with push/pull when online.
///
/// **Desktop parity:**
/// - Session list/messages: dashboard REST cookies (`DashboardClient`)
/// - New session + chat: live WS `session.create` + `prompt.submit` (not outbox)
/// - Outbox only when truly offline (no live WS / no legacy API)
///
/// Read path: SQLite → UI immediately, then pull from server and merge.
class SessionSyncRepository {
  SessionSyncRepository({
    required this.gatewayId,
    required AppDatabase db,
    DashboardClient? dashboard,
    HermesApi? api,
    GatewayRealtime? realtime,
  }) : // Public named parameters cannot use private field names.
       // ignore: prefer_initializing_formals
       _db = db,
       // ignore: prefer_initializing_formals
       _dashboard = dashboard,
       // ignore: prefer_initializing_formals
       _api = api,
       // ignore: prefer_initializing_formals
       _realtime = realtime;

  final String gatewayId;
  final AppDatabase _db;
  DashboardClient? _dashboard;
  HermesApi? _api;
  GatewayRealtime? _realtime;
  final _uuid = const Uuid();
  bool _flushing = false;

  /// Coalesces redundant startup pulls: several providers/screens each kick
  /// their own initial `syncSessions`/`listSkills` a few ms apart at cold
  /// launch. In-flight calls share one Future; a short TTL also collapses
  /// back-to-back triggers that arrive just after the first one completes.
  final _sessionsFlight = SingleFlight<List<HermesSession>>();
  final _skillsFlight = SingleFlight<List<HermesSkill>>();

  /// Live WS runtime id keyed by durable/stored session id (Desktop maps both).
  final Map<String, String> _liveByStored = {};
  final Map<String, String> _storedByLive = {};
  final Map<String, String> _profileBySession = {};
  final Set<String> _canonicalBotChatIds = {};

  void _registerCanonicalBotChat({required String storedId, String? liveId}) {
    final stored = storedId.trim();
    final live = liveId?.trim();
    if (stored.isNotEmpty) _canonicalBotChatIds.add(stored);
    if (live != null && live.isNotEmpty) _canonicalBotChatIds.add(live);
  }

  bool _isCanonicalBotChatId(String sessionId) {
    final id = sessionId.trim();
    if (id.isEmpty) return false;
    return _canonicalBotChatIds.contains(id) ||
        _canonicalBotChatIds.contains(_liveByStored[id]) ||
        _canonicalBotChatIds.contains(_storedByLive[id]);
  }

  /// Bind a durable bot-chat id to its owning server profile. Profile-scoped
  /// sessions live in a different state.db from ordinary mobile chats, so
  /// every later resume/history pull must retain this association.
  void registerSessionProfile(String sessionId, String profile) {
    final id = sessionId.trim();
    final name = profile.trim();
    if (id.isEmpty || name.isEmpty) return;
    final live = _liveByStored[id];
    final mappingWasProfileScoped =
        _profileBySession[id] == name ||
        (live != null && _profileBySession[live] == name);
    _profileBySession[id] = name;
    if (live != null && live.isNotEmpty) {
      _profileBySession[live] = name;
      if (!mappingWasProfileScoped) {
        // A runtime id obtained before we learned this was a Bot profile may
        // already be bound to the gateway's default HERMES_HOME.  Force the
        // next operation through profile-scoped session.resume instead of
        // trusting that ambiguous cached runtime.
        _liveByStored.remove(id);
        _liveByStored.remove(live);
        _storedByLive.remove(live);
      }
    }
  }

  String? _profileForSession(String sessionId) {
    return _profileBySession[sessionId] ??
        _profileBySession[_storedByLive[sessionId] ?? ''];
  }

  /// Completer for the in-flight agent turn (so [interruptSession] can unblock waiters).
  Completer<void>? _inflightTurnDone;
  String? _inflightLiveId;

  void bindDashboard(DashboardClient? client) {
    _dashboard = client;
  }

  void bindApi(HermesApi? api) {
    _api = api;
  }

  void bindRealtime(GatewayRealtime? realtime) {
    _realtime = realtime;
  }

  /// Best-effort bring-up of the Desktop WS before create/send.
  ///
  /// Chat requires `/api/ws` — cookie HTTPS alone is not enough. [force]
  /// reconnects (fresh ticket) when a prior attempt failed mid-send.
  Future<bool> _ensureWsLive({bool force = false}) async {
    final rt = _realtime;
    if (rt == null) {
      debugPrint('SessionSync: no GatewayRealtime bound');
      return false;
    }
    try {
      if (force) {
        return await rt.ensureLive(force: true);
      }
      if (rt.isLive) return true;
      return await rt.ensureLive();
    } catch (e) {
      debugPrint('SessionSync: WS start failed: $e');
      return false;
    }
  }

  // ── Read (local-first) ─────────────────────────────────────────────

  Future<List<HermesSession>> loadSessionsLocal() async {
    final rows = await _db.sessionsForGateway(gatewayId);
    return rows.map(_sessionFromRow).toList();
  }

  Future<List<HermesMessage>> loadMessagesLocal(String sessionId) async {
    final rows = await _db.messagesForSession(gatewayId, sessionId);
    final tombstoned = await _db.tombstonedMessageIds(gatewayId, sessionId);
    final messages = rows.map(_messageFromRow);
    if (tombstoned.isEmpty) return messages.toList();
    return messages.where((m) => !tombstoned.contains(m.id)).toList();
  }

  /// Delete a message from this device only. The gateway has no arbitrary
  /// single-message delete (only whole-session delete and `session.undo`,
  /// which drops the trailing turn) — see report notes on
  /// `hermes_cli/web_routers/sessions.py` and `tui_gateway/methods_session.py`
  /// for the full RPC/REST surface checked. The tombstone keeps the message
  /// filtered out of every subsequent local read even after a server pull
  /// repopulates the cache (the gateway still has its own copy).
  Future<List<HermesMessage>> deleteMessageLocal(
    String sessionId,
    String messageId,
  ) async {
    final rows = await _db.messagesForSession(gatewayId, sessionId);
    final row = rows.where((m) => m.id == messageId).firstOrNull;
    await _db.tombstoneMessage(
      gatewayId,
      sessionId,
      messageId,
      // Recorded so the tombstone survives a server-side rewind re-stamping
      // the row id — see [_reanchorTombstones].
      fingerprint: row == null
          ? null
          : messageFingerprint(row.role, row.content),
    );
    return loadMessagesLocal(sessionId);
  }

  /// Stable, content-derived identity for one message.
  ///
  /// The gateway's message id is an `AUTOINCREMENT` row id, and a server-side
  /// rewind (edit / retry / undo from any client) re-inserts the surviving
  /// prefix as fresh rows — see `replace_messages(..., archive_dropped=True)`
  /// in `hermes_state.py`. Every id in the session changes, so anything the
  /// client wants to keep pinned to a specific message across that event needs
  /// a second, content-derived key.
  ///
  /// FNV-1a over `role<NUL>content`, deliberately **not** `String.hashCode`:
  /// that is not guaranteed stable across Dart VM versions and this value is
  /// persisted in SQLite across app upgrades.
  static String messageFingerprint(String role, String? content) {
    final normalizedRole = role.trim().toLowerCase();
    final bytes = utf8.encode('$normalizedRole\u0000${(content ?? '').trim()}');
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = (hash ^ b) & 0xffffffff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$normalizedRole:${hash.toRadixString(16)}';
  }

  /// Whether [sessionId] still has an outbox op in flight — lets the UI tell
  /// a genuinely-still-queued send apart from one a background/foreground
  /// flush already resolved.
  Future<bool> hasPendingOpsFor(String sessionId) {
    return _db.hasPendingOpsForSession(gatewayId, sessionId);
  }

  /// Local list first; if online, pull + replace cache and return server view
  /// merged with any still-pending local creates and [keepIds] (pinned sessions).
  ///
  /// Desktop `mergeSessionPage` keeps pinned rows that fell off the recent page;
  /// without that, a pin "disappears until you refresh".
  ///
  /// Coalesced via [SingleFlight]: concurrent/rapid-fire callers (WS connect,
  /// shell boot, screen open, pull-to-refresh) share one pull. Pass
  /// [bypassTtl] for an explicit user-initiated refresh — it still joins an
  /// in-flight pull rather than firing a redundant concurrent request.
  Future<List<HermesSession>> syncSessions({
    Iterable<String>? keepIds,
    bool bypassTtl = false,
  }) {
    return _sessionsFlight.run(
      () => _syncSessionsImpl(keepIds: keepIds),
      bypassTtl: bypassTtl,
    );
  }

  Future<List<HermesSession>> _syncSessionsImpl({
    Iterable<String>? keepIds,
  }) async {
    final local = await loadSessionsLocal();
    try {
      await flushOutbox();
      final remote = await _pullSessions();
      if (remote == null) {
        debugPrint(
          'SessionSync: no dashboard/api client — keeping local cache',
        );
        return local;
      }
      debugPrint(
        'SessionSync: pulled ${remote.length} sessions from dashboard',
      );
      final remoteIds = {for (final s in remote) s.id};
      final keep = <String>{
        ...?keepIds,
        for (final s in local)
          if (s.id.startsWith('local_')) s.id,
      };
      // Survivors: pinned (or other keep) rows the server page omitted.
      final survivors = <HermesSession>[
        for (final s in local)
          if (keep.contains(s.id) && !remoteIds.contains(s.id)) s,
      ];
      await _db.replaceSessions(gatewayId, [
        for (final s in remote) _sessionToCompanion(s, syncStatus: 'synced'),
        for (final s in survivors)
          _sessionToCompanion(
            s,
            syncStatus: s.id.startsWith('local_') ? 'pending' : 'synced',
          ),
      ]);
      return await loadSessionsLocal();
    } catch (e, st) {
      debugPrint('SessionSync: pull sessions failed: $e\n$st');
      // Prefer showing a non-empty local cache; rethrow if cache empty so UI
      // can display the real error instead of a blank list.
      if (local.isEmpty) rethrow;
      return local;
    }
  }

  Future<List<HermesSession>?> _pullSessions() async {
    final dash = _dashboard;
    if (dash != null) {
      // Desktop listSessions defaults + recents exclude cron (session store).
      return dash.listSessions(
        limit: 100,
        order: 'recent',
        minMessages: 0,
        excludeSources: 'cron',
      );
    }
    final api = _api;
    if (api != null) {
      return api.listSessions(limit: 100);
    }
    return null;
  }

  Future<List<HermesMessage>> syncMessages(String sessionId) async {
    final local = await loadMessagesLocal(sessionId);
    try {
      await flushOutbox();
      final remote = await _pullMessages(sessionId);
      if (remote == null) return local;
      // Server view is authoritative for history — reconcile local delete
      // intent against it BEFORE the cache is rebuilt below, so a rewind that
      // re-stamped every row id can't resurrect a deleted message.
      await _reanchorTombstones(sessionId, remote);
      final authoritative = preserveTerminalErrorAfterSync(remote, local);

      // Preserve local pending rows the server has not echoed yet (mid-turn
      // pulls often omit the just-submitted user message — a blind replace
      // made the chat "eat" the query while tools kept running).
      final remoteIds = authoritative.map((m) => m.id).toSet();
      final remoteUserTexts = authoritative
          .where((m) => m.isUser)
          .map((m) => (m.content ?? '').trim())
          .where((t) => t.isNotEmpty)
          .toSet();
      final localRows = await _db.messagesForSession(gatewayId, sessionId);
      final keptIds = {for (final m in authoritative) m.id};

      CachedMessagesCompanion carry(CachedMessage row) =>
          CachedMessagesCompanion.insert(
            gatewayId: gatewayId,
            sessionId: sessionId,
            id: row.id,
            role: row.role,
            content: Value(row.content),
            toolCallId: Value(row.toolCallId),
            toolName: Value(row.toolName),
            timestamp: Value(row.timestamp),
            tokenCount: Value(row.tokenCount),
            finishReason: Value(row.finishReason),
            reasoning: Value(row.reasoning),
            toolCallsJson: Value(row.toolCallsJson),
            sortIndex: Value(row.sortIndex),
            syncStatus: Value(row.syncStatus),
            // `isVisibleUser` is `role == 'user' && displayKind` empty — a
            // carried-over row that loses the tag re-enters the transcript as
            // a *visible* user turn and shifts every later user ordinal, which
            // is what the gateway rejects with error 4018.
            displayKind: Value(row.displayKind),
          );

      final orphanCompanions = <CachedMessagesCompanion>[];
      final localErrorRows = <CachedMessage>[];
      for (final row in localRows) {
        final pending =
            row.syncStatus == 'pending' ||
            row.syncStatus == 'queued' ||
            row.id.startsWith('local_') ||
            row.id.startsWith('stream_');
        if (!pending) continue;
        if (remoteIds.contains(row.id)) continue;
        // Error bubbles are decided after the real orphans — see below.
        if (row.id.startsWith(kLocalErrorIdPrefix)) {
          localErrorRows.add(row);
          continue;
        }
        final text = (row.content ?? '').trim();
        if (row.role == 'user' &&
            text.isNotEmpty &&
            remoteUserTexts.contains(text)) {
          continue; // server already has this user turn under another id
        }
        orphanCompanions.add(carry(row));
      }

      // A terminal-error bubble is a client annotation on the tail of the
      // transcript, not server history. Two things may keep it alive:
      //
      // - [preserveTerminalErrorAfterSync] put it back into `authoritative`
      //   (the server still has no reply after its last user turn), or
      // - there is still undelivered local intent being carried above it —
      //   the user's own message that never reached the gateway. Dropping the
      //   explanation while keeping the unsent message would be the silent
      //   half of this bug.
      //
      // Otherwise it has expired and must be DELETED, not merely left out of
      // the merge: `AppDatabase.replaceMessages` deliberately preserves
      // `pending` rows, so an expired bubble used to survive every single pull
      // and stay pinned below every later successful turn — the chat kept
      // insisting the last thing that happened was a failure.
      final keepErrors = orphanCompanions.isNotEmpty;
      for (final row in localErrorRows) {
        if (keptIds.contains(row.id)) continue;
        if (keepErrors) {
          orphanCompanions.add(carry(row));
          continue;
        }
        await _db.deleteMessage(gatewayId, sessionId, row.id);
      }

      final mergedCompanions = <CachedMessagesCompanion>[
        for (var i = 0; i < authoritative.length; i++)
          _messageToCompanion(
            authoritative[i],
            sortIndex: i,
            syncStatus: 'synced',
          ),
        for (var i = 0; i < orphanCompanions.length; i++)
          orphanCompanions[i].copyWith(
            sortIndex: Value(authoritative.length + i),
          ),
      ];

      await _db.replaceMessages(gatewayId, sessionId, mergedCompanions);
      // Touch session preview from last message if present.
      final after = await loadMessagesLocal(sessionId);
      if (after.isNotEmpty) {
        final last = after.last;
        final sessions = await _db.sessionsForGateway(gatewayId);
        final existing = sessions.where((s) => s.id == sessionId).firstOrNull;
        if (existing != null) {
          await _db.upsertSession(
            CachedSessionsCompanion(
              gatewayId: Value(gatewayId),
              id: Value(sessionId),
              source: Value(existing.source),
              userId: Value(existing.userId),
              model: Value(existing.model),
              title: Value(existing.title),
              startedAt: Value(existing.startedAt),
              endedAt: Value(existing.endedAt),
              endReason: Value(existing.endReason),
              messageCount: Value(after.length),
              toolCallCount: Value(existing.toolCallCount),
              lastActive: Value(
                last.timestamp ?? DateTime.now().toUtc().toIso8601String(),
              ),
              preview: Value(
                (last.content ?? '').trim().isEmpty
                    ? existing.preview
                    : (last.content!.length > 120
                          ? '${last.content!.substring(0, 120)}…'
                          : last.content),
              ),
              parentSessionId: Value(existing.parentSessionId),
              syncStatus: const Value('synced'),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );
        }
      }
      return after;
    } catch (e, st) {
      debugPrint('SessionSync: pull messages failed: $e\n$st');
      return local;
    }
  }

  /// Page size the dashboard messages endpoint caps a transcript pull at
  /// (`hermes_cli/web_routers/sessions.py` — `_limit = 500` when the client
  /// sends no explicit `limit`, which is what [_pullMessages] does).
  static const messagesPageCap = 500;

  /// Reconcile local message tombstones against an authoritative server pull.
  ///
  /// **The conflict.** A tombstone is local-only intent ("hide this message on
  /// this phone") keyed on the gateway's message id. That id is a SQLite
  /// `AUTOINCREMENT` row id, and any edit / retry / undo — from Desktop, the
  /// CLI, or this phone — runs
  /// `replace_messages(..., archive_dropped=True)` server-side, which
  /// soft-archives the live rows and re-inserts the surviving prefix as
  /// **fresh rows with new ids** (`hermes_state.py`; the gateway even returns
  /// `survivor_user_row_ids` so clients can rebind, see
  /// `tui_gateway/methods_prompt.py`). After that every cached id in the
  /// session is stale, the tombstone matches nothing, and the message the user
  /// deleted here silently reappears in the transcript.
  ///
  /// **The resolution.** The gateway is the source of truth for history, so
  /// each tombstone is re-decided against the pulled transcript:
  ///
  /// - id still present remotely → nothing to do (the common case).
  /// - id gone, but an un-tombstoned remote message carries the same
  ///   [messageFingerprint] → that is the same message under its new id;
  ///   re-point the tombstone (and drop the row the pull is about to insert).
  /// - id gone and no fingerprint match → the gateway does not have this
  ///   message at all any more (the rewind cut past it); drop the tombstone
  ///   so it cannot later hide an unrelated row.
  ///
  /// Skipped when the pull came back full ([messagesPageCap]): an id missing
  /// from a truncated page proves nothing about the server's history. Also
  /// skipped for pre-v5 tombstones with no fingerprint, which keep their
  /// existing id-only behaviour rather than being guessed at.
  Future<void> _reanchorTombstones(
    String sessionId,
    List<HermesMessage> remote,
  ) async {
    if (remote.length >= messagesPageCap) return;
    final tombstones = await _db.tombstonesForSession(gatewayId, sessionId);
    if (tombstones.isEmpty) return;
    final remoteIds = {for (final m in remote) m.id};
    // Never re-anchor onto a row another tombstone already owns.
    final claimed = {for (final t in tombstones) t.messageId};

    for (final tombstone in tombstones) {
      if (remoteIds.contains(tombstone.messageId)) continue;
      final fingerprint = tombstone.fingerprint;
      if (fingerprint == null || fingerprint.isEmpty) continue;

      HermesMessage? match;
      for (final message in remote) {
        if (claimed.contains(message.id)) continue;
        if (messageFingerprint(message.role, message.content) != fingerprint) {
          continue;
        }
        match = message;
        break;
      }

      if (match == null) {
        await _db.removeTombstone(gatewayId, sessionId, tombstone.messageId);
        debugPrint(
          'SessionSync: dropped stale tombstone ${tombstone.messageId} '
          '(session $sessionId no longer has that message server-side)',
        );
        continue;
      }
      claimed.add(match.id);
      await _db.retargetTombstone(
        gatewayId,
        sessionId,
        fromId: tombstone.messageId,
        toId: match.id,
        fingerprint: fingerprint,
      );
      debugPrint(
        'SessionSync: re-anchored tombstone ${tombstone.messageId} → '
        '${match.id} (session $sessionId history was rewritten server-side)',
      );
    }
  }

  Future<List<HermesMessage>?> _pullMessages(String sessionId) async {
    final profile = _profileForSession(sessionId);
    if (profile != null) {
      if (!await _ensureWsLive()) return null;
      final liveId = await _ensureLiveSessionId(sessionId);
      final raw = await gatewayRequest('session.history', {
        'session_id': liveId,
      });
      final messages = raw['messages'];
      if (messages is! List) return const [];
      return [
        for (var i = 0; i < messages.length; i++)
          if (messages[i] is Map)
            _profileMessageFromGateway(
              (messages[i] as Map).cast<String, dynamic>(),
              sessionId: sessionId,
              index: i,
            ),
      ];
    }
    final dash = _dashboard;
    if (dash != null) {
      return dash.listMessages(sessionId);
    }
    final api = _api;
    if (api != null) {
      return api.listMessages(sessionId);
    }
    return null;
  }

  HermesMessage _profileMessageFromGateway(
    Map<String, dynamic> raw, {
    required String sessionId,
    required int index,
  }) {
    final rowId = raw['row_id'] ?? raw['id'];
    final stableId = rowId == null || '$rowId'.isEmpty
        ? 'profile_${messageFingerprint('${raw['role'] ?? ''}', '${raw['text'] ?? raw['content'] ?? ''}')}_$index'
        : '$rowId';
    return HermesMessage.fromJson({
      ...raw,
      'id': stableId,
      'session_id': sessionId,
      // The profile gateway intentionally projects tool calls as a compact
      // display context plus their original arguments. Preserve both: older
      // clients dropped these fields and rendered every tool row as just an
      // ellipsis after a history refresh.
      'content': raw['content'] ?? raw['text'] ?? raw['context'],
      'tool_name': raw['tool_name'] ?? raw['name'],
      'tool_calls':
          raw['tool_calls'] ??
          (raw['args'] == null ? null : <String, dynamic>{'args': raw['args']}),
    });
  }

  // ── Writes ─────────────────────────────────────────────────────────

  Future<HermesSession> createSession({
    String? title,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fastMode,
  }) async {
    final now = DateTime.now().toUtc();
    final displayTitle = title ?? 'Mobile chat';

    // Desktop path: session.create over live /api/ws — instant server id.
    if (await _ensureWsLive()) {
      try {
        final created = await _createSessionOnGateway(
          title: displayTitle,
          model: model,
          provider: provider,
          reasoningEffort: reasoningEffort,
          fastMode: fastMode,
        );
        await _db.upsertSession(
          _sessionToCompanion(created, syncStatus: 'synced'),
        );
        debugPrint('SessionSync: session.create → ${created.id} (live)');
        return created;
      } catch (e, st) {
        debugPrint(
          'SessionSync: session.create failed, offline draft: $e\n$st',
        );
      }
    }

    // Offline / WS down: local draft; first send will create on gateway.
    final localId = 'local_${_uuid.v4()}';
    final session = HermesSession(
      id: localId,
      source: 'mobile',
      model: model,
      title: displayTitle,
      startedAt: now.toIso8601String(),
      lastActive: now.toIso8601String(),
      messageCount: 0,
    );

    await _db.upsertSession(
      _sessionToCompanion(session, syncStatus: 'pending'),
    );
    if (_api != null) {
      await _db.enqueueOp(
        PendingOpsCompanion.insert(
          id: _uuid.v4(),
          gatewayId: gatewayId,
          opType: 'create_session',
          sessionId: Value(localId),
          payloadJson: jsonEncode({
            'local_id': localId,
            'title': displayTitle,
            'model': ?model,
            'provider': ?provider,
            if (fastMode == true) 'fast': true,
          }),
          createdAt: now,
        ),
      );
      await flushOutbox();
      final after = await loadSessionsLocal();
      final stillLocal = after.where((s) => s.id == localId).firstOrNull;
      if (stillLocal == null) {
        final match = after.where((s) => s.title == session.title).toList();
        if (match.isNotEmpty) return match.first;
      }
    }
    return session;
  }

  /// Session-scoped model value for `config.set` / slash `/model`.
  ///
  /// The provider keeps model aliases routed to the intended backend. The
  /// explicit `--session` is also required: the gateway otherwise applies its
  /// default persistence policy and can rewrite the global model even when a
  /// `session_id` accompanies `config.set`, leaking the pick to other chats.
  static String modelConfigValue(String model, {String? provider}) {
    final m = model.trim();
    final p = provider?.trim() ?? '';
    if (m.isEmpty) return '';
    if (p.isEmpty) return '$m --session';
    return '$m --provider $p --session';
  }

  /// Desktop-parity mid-session model switch: `config.set` key=model.
  ///
  /// Sticky UI pick alone is not enough — with a live session the gateway must
  /// learn the override or the next turn still uses the old model.
  Future<void> applySessionModel({
    required String sessionId,
    required String model,
    String? provider,
  }) async {
    final value = modelConfigValue(model, provider: provider);
    if (value.isEmpty) return;
    if (!await _ensureWsLive()) {
      throw StateError(
        'WebSocket not connected — model switch needs a live gateway',
      );
    }
    final liveId = await _ensureLiveSessionId(
      sessionId,
      model: model.trim(),
      provider: provider?.trim(),
    );
    await _pinLiveSessionModel(
      liveId: liveId,
      model: model,
      provider: provider,
    );
    // Keep local session row in sync for list subtitle.
    final sessions = await loadSessionsLocal();
    final existing =
        sessions.where((s) => s.id == sessionId).firstOrNull ??
        sessions
            .where((s) => s.id == (_storedByLive[liveId] ?? ''))
            .firstOrNull;
    if (existing != null) {
      await _db.upsertSession(
        _sessionToCompanion(
          HermesSession(
            id: existing.id,
            source: existing.source,
            userId: existing.userId,
            model: model.trim(),
            title: existing.title,
            startedAt: existing.startedAt,
            endedAt: existing.endedAt,
            endReason: existing.endReason,
            messageCount: existing.messageCount,
            toolCallCount: existing.toolCallCount,
            lastActive: existing.lastActive,
            preview: existing.preview,
            parentSessionId: existing.parentSessionId,
          ),
          syncStatus: 'synced',
        ),
      );
    }
    debugPrint('SessionSync: config.set model=$value session=$liveId');
  }

  /// Resolve the runtime id used by session-scoped gateway RPCs. Desktop's
  /// model.options request is session-aware, so the picker must use the live
  /// id rather than assuming a persisted REST id is already bound.
  Future<String> resolveLiveSessionId(String sessionId) {
    return _ensureLiveSessionId(sessionId);
  }

  /// Resume/read the runtime identity for one session. The gateway's response
  /// includes the effective model, provider, reasoning effort, and service
  /// tier; callers must not infer these from the global phone preference.
  Future<SessionRuntimeState?> fetchSessionRuntime(String sessionId) async {
    // A local draft has not been created on the gateway yet. Do not turn a
    // read-only hydration call into an empty remote session; the first send
    // creates it with the draft's selected model/provider.
    if (sessionId.startsWith('local_')) return null;
    if (!await _ensureWsLive()) return null;
    final rt = _realtime;
    if (rt == null || !rt.isLive) return null;
    try {
      // Resume exactly once. On a cold historical session the first response
      // carries its persisted model/options while the gateway builds the live
      // agent. A second immediate resume can hit that half-built live session
      // and report the global fallback model instead.
      final raw = await rt.request('session.resume', {
        'session_id': sessionId,
        'source': 'mobile',
        'profile': ?_profileForSession(sessionId),
      });
      final info = raw['info'];
      final state = SessionRuntimeState.fromJson(
        info is Map ? info.cast<String, dynamic>() : raw,
      );
      // Keep the runtime mapping alive even if the resume response was lazy.
      final returnedLive = '${raw['session_id'] ?? ''}'.trim();
      if (returnedLive.isNotEmpty) {
        _registerLiveMapping(storedId: sessionId, liveId: returnedLive);
      }
      return state;
    } catch (e) {
      debugPrint('SessionSync: session runtime fetch failed: $e');
      return null;
    }
  }

  /// Pin the live agent to the sticky UI model (Desktop `config.set` path).
  ///
  /// Called after resume and again before each `prompt.submit` so reconnects
  /// and mid-session picks always hit the right provider credentials.
  Future<void> _pinLiveSessionModel({
    required String liveId,
    String? model,
    String? provider,
  }) async {
    final value = modelConfigValue(model ?? '', provider: provider);
    if (value.isEmpty || liveId.isEmpty) return;
    final rt = _realtime;
    if (rt == null || !rt.isLive) return;
    try {
      await rt.request('config.set', {
        'session_id': liveId,
        'key': 'model',
        'value': value,
      });
      debugPrint('SessionSync: pinned model=$value live=$liveId');
    } catch (e) {
      // Session busy during another turn, or agent still building — surface
      // loudly so the user isn't left thinking Grok is active when it isn't.
      debugPrint('SessionSync: pin model failed ($value): $e');
      rethrow;
    }
  }

  /// Desktop status-bar context breakdown (`session.context_breakdown`).
  Future<ContextBreakdown> fetchContextBreakdown(String sessionId) async {
    if (!await _ensureWsLive()) {
      throw StateError('WebSocket not connected');
    }
    final liveId = await _ensureLiveSessionId(sessionId);
    final raw = await gatewayRequest('session.context_breakdown', {
      'session_id': liveId,
    });
    return ContextBreakdown.fromJson(raw);
  }

  /// Lightweight usage from `session.usage` when the agent is live.
  Future<UsageStats?> fetchSessionUsage(String sessionId) async {
    if (!await _ensureWsLive()) return null;
    try {
      final liveId = await _ensureLiveSessionId(sessionId);
      final raw = await gatewayRequest('session.usage', {'session_id': liveId});
      return UsageStats.fromJson(raw);
    } catch (e) {
      debugPrint('SessionSync: session.usage failed: $e');
    }
    return null;
  }

  /// Desktop-parity: `config.set` key=`reasoning` (effort / Thinking off).
  Future<void> applySessionReasoning({
    required String sessionId,
    required String effort,
  }) async {
    final value = effort.trim().toLowerCase();
    if (value.isEmpty) return;
    if (!await _ensureWsLive()) {
      throw StateError(
        'WebSocket not connected — reasoning switch needs a live gateway',
      );
    }
    final liveId = await _ensureLiveSessionId(sessionId);
    await _pinLiveSessionReasoning(liveId: liveId, effort: value);
  }

  Future<void> _pinLiveSessionReasoning({
    required String liveId,
    String? effort,
  }) async {
    final value = (effort ?? '').trim().toLowerCase();
    if (value.isEmpty || liveId.isEmpty) return;
    final rt = _realtime;
    if (rt == null || !rt.isLive) return;
    try {
      await rt.request('config.set', {
        'session_id': liveId,
        'key': 'reasoning',
        'value': value,
      });
      debugPrint('SessionSync: pinned reasoning=$value live=$liveId');
    } catch (e) {
      debugPrint('SessionSync: pin reasoning failed ($value): $e');
      rethrow;
    }
  }

  /// Desktop-parity: `config.set` key=`fast` (`fast` | `normal`).
  Future<void> applySessionFast({
    required String sessionId,
    required bool enabled,
  }) async {
    if (!await _ensureWsLive()) {
      throw StateError(
        'WebSocket not connected — fast switch needs a live gateway',
      );
    }
    final liveId = await _ensureLiveSessionId(sessionId);
    await _pinLiveSessionFast(liveId: liveId, enabled: enabled);
  }

  Future<void> _pinLiveSessionFast({
    required String liveId,
    required bool enabled,
  }) async {
    if (liveId.isEmpty) return;
    final rt = _realtime;
    if (rt == null || !rt.isLive) return;
    final value = enabled ? 'fast' : 'normal';
    try {
      await rt.request('config.set', {
        'session_id': liveId,
        'key': 'fast',
        'value': value,
      });
      debugPrint('SessionSync: pinned fast=$value live=$liveId');
    } catch (e) {
      debugPrint('SessionSync: pin fast failed ($value): $e');
      rethrow;
    }
  }

  /// Desktop `session.create` — returns durable id + registers live runtime id.
  Future<HermesSession> _createSessionOnGateway({
    String? title,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fastMode,
    String? profile,
    bool hidden = false,
    bool followProfileConfig = false,
  }) async {
    final rt = _realtime;
    if (rt == null || !rt.isLive) {
      throw StateError('gateway not live');
    }
    final result = await rt.request('session.create', {
      'source': 'mobile',
      if (profile != null && profile.isNotEmpty) 'profile': profile,
      'hidden': hidden,
      if (followProfileConfig) 'follow_profile_config': true,
      if (title != null && title.isNotEmpty) 'title': title,
      if (model != null && model.isNotEmpty) 'model': model,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      // Desktop composer ships effort on every new chat.
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoning_effort': reasoningEffort,
      if (fastMode == true) 'fast': true,
    });
    final liveId = '${result['session_id'] ?? ''}'.trim();
    if (liveId.isEmpty) {
      throw StateError('session.create missing session_id: $result');
    }
    // Durable DB key (YYYYMMDD_…); REST list/messages use this after first turn.
    final storedRaw = result['stored_session_id'];
    final storedId = (storedRaw == null || '$storedRaw'.trim().isEmpty)
        ? liveId
        : '$storedRaw'.trim();
    if (profile != null && profile.isNotEmpty) {
      registerSessionProfile(storedId, profile);
    }
    _registerLiveMapping(storedId: storedId, liveId: liveId);

    final info = result['info'];
    String? infoModel;
    if (info is Map) {
      infoModel = info['model']?.toString();
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return HermesSession(
      id: storedId,
      source: 'mobile',
      model: model ?? infoModel,
      title: title ?? 'Mobile chat',
      startedAt: now,
      lastActive: now,
      messageCount: 0,
    );
  }

  void _registerLiveMapping({
    required String storedId,
    required String liveId,
  }) {
    _liveByStored[storedId] = liveId;
    _storedByLive[liveId] = storedId;
    // Also allow looking up by live id as if it were the session key.
    _liveByStored[liveId] = liveId;
    final profile = _profileBySession[storedId];
    if (profile != null) _profileBySession[liveId] = profile;
  }

  /// Resolve a Bot Mode profile's canonical chat, matching the desktop plugin:
  /// reuse its pinned chat when present, recover to its newest session when a
  /// pin is stale, or create a Bot Chat when none exists.
  Future<({HermesSession session, bool created})> openBotChat(
    HermesBotProfile bot,
  ) async {
    final migrated = await _migrateLegacyHealthCoach(bot);
    return _openBotChat(migrated);
  }

  /// Convert profiles created by the retired Health Coach switch to the
  /// ordinary Apple Health toolset. Skills only teach the model how to use a
  /// tool; the toolset is what actually exposes it to a runtime. Saving the
  /// standard capability also pins a fresh session because tool schemas are
  /// immutable for the lifetime of a session.
  Future<HermesBotProfile> _migrateLegacyHealthCoach(
    HermesBotProfile bot,
  ) async {
    final rawUi = bot.raw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    if (rawMeta is! Map || rawMeta['healthCoach'] != true) return bot;

    final described = await describeBotProfile(bot.name);
    final enabledToolsets = described.toolsets
        .where((toolset) => toolset.enabled)
        .map((toolset) => toolset.name)
        .toList();
    if (!enabledToolsets.contains('apple_health')) {
      enabledToolsets.add('apple_health');
    }
    return updateBot(
      bot: bot,
      title: bot.displayName,
      description: bot.description ?? '',
      shape: bot.shape ?? 'circle',
      color: bot.color ?? '#f97316',
      usePhoto: bot.usesImageAvatar,
      enabledToolsets: enabledToolsets,
    );
  }

  Future<({HermesSession session, bool created})> _openBotChat(
    HermesBotProfile bot,
  ) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');

    Future<HermesSession> resume(HermesSession stored) async {
      final resumed = await gatewayRequest('session.resume', {
        'session_id': stored.id,
        'profile': profile,
      });
      final liveId = '${resumed['session_id'] ?? ''}'.trim();
      if (liveId.isEmpty) throw StateError('Gateway could not resume Bot Chat');
      registerSessionProfile(stored.id, profile);
      _registerLiveMapping(storedId: stored.id, liveId: liveId);
      _registerCanonicalBotChat(storedId: stored.id, liveId: liveId);
      return stored;
    }

    // Match Desktop on every explicit bot open: resolve the forever-chat from
    // the profile registry by its exact title. Roster payloads and the retired
    // ui_meta `chat` pointer are snapshots and must never choose identity.
    final listed = await gatewayRequest('session.list', {
      'profile': profile,
      'title': 'Bot Chat',
      'limit': 200,
      'include_hidden': true,
    });
    final rawRows = listed['sessions'];
    final rows = rawRows is List
        ? rawRows
              .whereType<Map>()
              .map((row) => row.cast<String, dynamic>())
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final selected = rows.where((row) {
      final rootTitle = '${row['root_title'] ?? ''}'.trim();
      final title = '${row['title'] ?? ''}'.trim();
      return rootTitle == 'Bot Chat' ||
          (rootTitle.isEmpty && title == 'Bot Chat');
    }).firstOrNull;
    if (selected != null) {
      final session = HermesSession.fromJson({
        ...selected,
        'id': selected['resolved_id'] ?? selected['id'],
        'model': bot.model,
        'last_active': selected['last_active'] ?? selected['started_at'],
      });
      return (session: await resume(session), created: false);
    }

    final created = await _createSessionOnGateway(
      title: 'Bot Chat',
      profile: profile,
      hidden: true,
      followProfileConfig: true,
    );
    final liveId = _liveByStored[created.id];
    if (liveId != null && liveId.isNotEmpty) {
      try {
        // Materialize the lazy row before opening it. This also closes the
        // window where auto-title could steal the canonical registry name.
        await gatewayRequest('session.title', {
          'session_id': liveId,
          'title': 'Bot Chat',
        });
      } catch (error) {
        if (!'$error'.toLowerCase().contains('already in use')) rethrow;
        // Another client won the title race. Adopt that row instead of
        // turning this empty lazy session into a second forever-chat.
        final winner = await gatewayRequest('session.list', {
          'profile': profile,
          'title': 'Bot Chat',
          'limit': 200,
          'include_hidden': true,
        });
        final winnerRows = winner['sessions'];
        if (winnerRows is List && winnerRows.whereType<Map>().isNotEmpty) {
          final row = winnerRows.whereType<Map>().first.cast<String, dynamic>();
          final session = HermesSession.fromJson({
            ...row,
            'id': row['resolved_id'] ?? row['id'],
            'model': bot.model,
            'last_active': row['last_active'] ?? row['started_at'],
          });
          return (session: await resume(session), created: false);
        }
        rethrow;
      }
    }
    _registerCanonicalBotChat(
      storedId: created.id,
      liveId: _liveByStored[created.id],
    );
    return (session: created, created: true);
  }

  /// Full profile-owned chat inventory, including older mobile Bot Chats that
  /// were deliberately hidden from the global recents list.
  Future<List<HermesSession>> listBotSessions(HermesBotProfile bot) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final listed = await gatewayRequest('session.list', {
      'profile': profile,
      'limit': 200,
      'include_hidden': true,
    });
    final rawRows = listed['sessions'];
    if (rawRows is! List) return const [];
    return rawRows
        .whereType<Map>()
        .map((row) {
          final json = row.cast<String, dynamic>();
          return HermesSession.fromJson({
            ...json,
            'last_active': json['last_active'] ?? json['started_at'],
            'model': json['model'] ?? bot.model,
          });
        })
        .where((session) => session.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Start a distinct, visible conversation for this bot. The roster tap
  /// continues to target the single canonical `Bot Chat`; alternate sessions
  /// never replace that server-owned identity.
  Future<HermesSession> createBotSession(HermesBotProfile bot) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final createdAt = DateTime.now().toLocal().toIso8601String();
    final created = await _createSessionOnGateway(
      title: 'Conversation ${createdAt.replaceFirst('T', ' ')}',
      profile: profile,
      hidden: false,
      followProfileConfig: true,
    );
    return created;
  }

  /// Resume one historical bot conversation without changing which session
  /// owns the bot's canonical roster entry.
  Future<HermesSession> openBotSession(
    HermesBotProfile bot,
    HermesSession stored,
  ) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final resumed = await gatewayRequest('session.resume', {
      'session_id': stored.id,
      'profile': profile,
    });
    final liveId = '${resumed['session_id'] ?? ''}'.trim();
    if (liveId.isEmpty) throw StateError('Gateway could not resume bot chat');
    _registerLiveMapping(storedId: stored.id, liveId: liveId);
    registerSessionProfile(stored.id, profile);
    return stored;
  }

  Future<BotProfileConfiguration> describeBotProfile(String name) async {
    final profile = name.trim();
    if (profile.isEmpty) throw StateError('Profile name is missing');
    return BotProfileConfiguration.fromJson(
      await gatewayRequest('profiles.describe', {'name': profile}),
    );
  }

  /// Create a real Bot Mode profile, then attach the same server-owned visual
  /// metadata Desktop consumes. Credentials/model configuration are inherited
  /// from the primary profile; OAuth state is shared rather than copied so
  /// refresh tokens cannot diverge between the main agent and its bots.
  Future<HermesBotProfile> createBot({
    required String name,
    required String title,
    required String description,
    required String shape,
    required String color,
    Uint8List? avatarBytes,
    String? cloneFrom = 'default',
    bool shareAuth = true,
    bool noSkills = false,
    String customSoul = '',
    String model = '',
    String provider = '',
    List<String>? disabledSkills,
    List<String>? enabledToolsets,
    List<String>? enabledMcpServers,
  }) async {
    final slug = name.trim();
    final cleanTitle = title.trim();
    final cleanDescription = description.trim();
    final descriptionText = [
      cleanTitle,
      cleanDescription,
    ].where((part) => part.isNotEmpty).join(' — ');
    final soul = customSoul.trim().isEmpty
        ? _generatedBotSoul(slug, cleanTitle, cleanDescription)
        : customSoul.trim();
    final cleanModel = model.trim();
    final cleanProvider = provider.trim();

    await gatewayRequest('profiles.create', {
      'name': slug,
      'description': descriptionText,
      'clone_from': cloneFrom?.trim().isEmpty == true ? null : cloneFrom,
      'share_auth': shareAuth,
      'no_skills': noSkills,
      'soul': soul,
      if (cleanModel.isNotEmpty && cleanProvider.isNotEmpty) ...{
        'model': cleanModel,
        'provider': cleanProvider,
      },
    });

    if (avatarBytes != null) {
      final asset = await gatewayRequest('profiles.set_asset', {
        'name': slug,
        'asset': 'avatar',
        'data': base64Encode(avatarBytes),
      });
      if (asset['ok'] == false) {
        throw StateError(
          'The profile was created, but its avatar was not saved',
        );
      }
    }

    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final metadata = <String, dynamic>{
      'shape': shape,
      'color': color,
      'imageKind': avatarBytes == null ? 'shape' : 'photo',
      'title': cleanTitle,
      'created': createdAt,
      'custom': true,
    };
    final configured = await gatewayRequest('profiles.configure', {
      'name': slug,
      'ui_meta': {'hermes-bots': metadata},
      'disabled_skills': ?disabledSkills,
      'enabled_toolsets': ?enabledToolsets,
      'enabled_mcp_servers': ?enabledMcpServers,
    });
    final applied = configured['applied'];
    if (applied is Map &&
        (applied['ui_meta'] != true ||
            (disabledSkills != null && applied['skills'] != true) ||
            (enabledToolsets != null && applied['toolsets'] != true) ||
            (enabledMcpServers != null && applied['mcp_servers'] != true))) {
      throw StateError(
        'The profile was created, but some advanced settings could not be saved',
      );
    }
    return HermesBotProfile.fromJson({
      'name': slug,
      'description': descriptionText,
      if (cleanModel.isNotEmpty) 'model': cleanModel,
      if (cleanProvider.isNotEmpty) 'provider': cleanProvider,
      'has_avatar': avatarBytes != null,
      'ui_meta': {'hermes-bots': metadata},
    });
  }

  /// Update the editable Bot Mode profile fields shared with Desktop.
  ///
  /// The profile slug is intentionally immutable: it is the bot's @handle
  /// and owns its profile directory, sessions, memory, and skills. The
  /// user-facing name lives in `title`. Compact appearance metadata remains
  /// server-owned in profile.yaml while an optional photo uses the profile
  /// asset RPC so it can sync without bloating every roster response.
  Future<HermesBotProfile> updateBot({
    required HermesBotProfile bot,
    required String title,
    required String description,
    required String shape,
    required String color,
    required bool usePhoto,
    Uint8List? avatarBytes,
    bool avatarChanged = false,
    String? soul,
    String model = '',
    String provider = '',
    List<String>? disabledSkills,
    List<String>? enabledToolsets,
    List<String>? enabledMcpServers,
  }) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');

    if (avatarChanged) {
      final asset = avatarBytes == null
          ? await gatewayRequest('profiles.set_asset', {
              'name': profile,
              'asset': 'avatar',
              'clear': true,
            })
          : await gatewayRequest('profiles.set_asset', {
              'name': profile,
              'asset': 'avatar',
              'data': base64Encode(avatarBytes),
            });
      if (asset['ok'] == false) {
        throw StateError('Server could not save the bot avatar');
      }
    }

    final rawUi = bot.raw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    final metadata = rawMeta is Map
        ? rawMeta.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    metadata
      ..['shape'] = shape
      ..['color'] = color
      ..['imageKind'] = usePhoto ? 'photo' : 'shape'
      ..['title'] = title.trim()
      ..['custom'] = true;
    metadata
      ..remove('chat')
      ..remove('healthCoach')
      ..remove('healthRoutingVersion');

    final described = await gatewayRequest('profiles.describe', {
      'name': profile,
    });
    final existingSoul = '${described['soul'] ?? ''}';
    final updatedSoul = soul == null
        ? _updateGeneratedBotSoul(
            existingSoul,
            profile: profile,
            title: title.trim(),
            description: description.trim(),
          )
        : _withoutLegacyHealthRouting(soul.trim());
    final soulChanged = updatedSoul != null && updatedSoul != existingSoul;
    final cleanDescription = description.trim();
    final cleanModel = model.trim();
    final cleanProvider = provider.trim();
    final configured = await gatewayRequest('profiles.configure', {
      'name': profile,
      'description': cleanDescription,
      if (soulChanged) 'soul': updatedSoul,
      if (cleanModel.isNotEmpty && cleanProvider.isNotEmpty) ...{
        'model': cleanModel,
        'provider': cleanProvider,
      },
      'ui_meta': {'hermes-bots': metadata},
      'disabled_skills': ?disabledSkills,
      'enabled_toolsets': ?enabledToolsets,
      'enabled_mcp_servers': ?enabledMcpServers,
    });
    final applied = configured['applied'];
    if (applied is Map &&
        (applied['ui_meta'] != true ||
            applied['description'] != true ||
            (soulChanged && applied['soul'] != true) ||
            (cleanModel.isNotEmpty && applied['model'] != true) ||
            (disabledSkills != null && applied['skills'] != true) ||
            (enabledToolsets != null && applied['toolsets'] != true) ||
            (enabledMcpServers != null && applied['mcp_servers'] != true))) {
      throw StateError('Server could not save all bot profile changes');
    }

    return HermesBotProfile.fromJson({
      ...bot.raw,
      'name': profile,
      'description': cleanDescription,
      if (cleanModel.isNotEmpty) 'model': cleanModel,
      if (cleanProvider.isNotEmpty) 'provider': cleanProvider,
      'has_avatar': usePhoto && (avatarBytes != null || bot.hasAvatar),
      'ui_meta': {'hermes-bots': metadata},
    });
  }

  /// Move a bot into a server-owned Bot Mode group, or clear its group.
  /// Group names are intentionally implicit: a group exists while at least
  /// one bot references it, matching Desktop's roster behavior.
  Future<void> updateBotGroup(HermesBotProfile bot, String? group) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final rawUi = bot.raw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    final metadata = rawMeta is Map
        ? rawMeta.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    final cleanGroup = group?.trim() ?? '';
    if (cleanGroup.isEmpty) {
      metadata.remove('group');
      metadata['groups'] = <String>[];
    } else {
      metadata['group'] = cleanGroup;
      metadata['groups'] = [cleanGroup];
    }
    final result = await gatewayRequest('profiles.configure', {
      'name': profile,
      'ui_meta': {'hermes-bots': metadata},
    });
    final applied = result['applied'];
    if (applied is Map && applied['ui_meta'] != true) {
      throw StateError('Server could not save the bot group');
    }
  }

  /// Toggle one group without replacing the bot's other memberships. The
  /// scalar `group` remains a first-membership projection for older clients.
  Future<void> updateBotGroupMembership(
    HermesBotProfile bot,
    String group,
    bool enabled, {
    Iterable<String>? currentGroups,
  }) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final cleanGroup = group.trim();
    if (cleanGroup.isEmpty) throw StateError('Group name is missing');
    // Refresh before applying the narrow membership delta. Starting from the
    // tile's stale snapshot could otherwise overwrite a Desktop title, pin,
    // canonical chat, or another group change made since the roster loaded.
    var currentRaw = bot.raw;
    try {
      final listed = await gatewayRequest('profiles.list', {
        'include_sessions': false,
      });
      final rawProfiles = listed['profiles'];
      if (rawProfiles is List) {
        for (final candidate in rawProfiles.whereType<Map>()) {
          if ('${candidate['name'] ?? ''}'.trim() == profile) {
            currentRaw = candidate.map((key, value) => MapEntry('$key', value));
            break;
          }
        }
      }
    } catch (_) {
      // Offline/older gateways retain the existing compatibility behavior.
    }
    final rawUi = currentRaw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    final metadata = rawMeta is Map
        ? rawMeta.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    final groups = [...(currentGroups ?? bot.groups)];
    if (enabled && !groups.contains(cleanGroup)) groups.add(cleanGroup);
    if (!enabled) groups.removeWhere((value) => value == cleanGroup);
    metadata['groups'] = groups;
    if (groups.isEmpty) {
      metadata.remove('group');
    } else {
      metadata['group'] = groups.first;
    }
    final result = await gatewayRequest('profiles.configure', {
      'name': profile,
      'ui_meta': {'hermes-bots': metadata},
    });
    final applied = result['applied'];
    if (applied is Map && applied['ui_meta'] != true) {
      throw StateError('Server could not save the bot groups');
    }
  }

  /// Pin or unpin a Bot Mode profile in the shared server roster metadata.
  Future<void> updateBotPinned(HermesBotProfile bot, bool pinned) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final rawUi = bot.raw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    final metadata = rawMeta is Map
        ? rawMeta.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    if (pinned) {
      metadata['pinned'] = true;
    } else {
      metadata.remove('pinned');
    }
    final result = await gatewayRequest('profiles.configure', {
      'name': profile,
      'ui_meta': {'hermes-bots': metadata},
    });
    final applied = result['applied'];
    if (applied is Map && applied['ui_meta'] != true) {
      throw StateError('Server could not save the bot pin');
    }
  }

  /// Hide or restore a Bot Mode profile using the shared Desktop metadata.
  /// A literal `false` is intentional: it clears a stale hidden value when
  /// older clients merge rather than replace the metadata object.
  Future<void> updateBotHidden(HermesBotProfile bot, bool hidden) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    final rawUi = bot.raw['ui_meta'];
    final rawMeta = rawUi is Map ? rawUi['hermes-bots'] : null;
    final metadata = rawMeta is Map
        ? rawMeta.map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    metadata['hidden'] = hidden;
    final result = await gatewayRequest('profiles.configure', {
      'name': profile,
      'ui_meta': {'hermes-bots': metadata},
    });
    final applied = result['applied'];
    if (applied is Map && applied['ui_meta'] != true) {
      throw StateError('Server could not save the bot visibility');
    }
  }

  /// Permanently delete the real Hermes profile backing a custom bot.
  Future<void> deleteBot(HermesBotProfile bot) async {
    final profile = bot.name.trim();
    if (profile.isEmpty) throw StateError('Bot profile name is missing');
    if (bot.isDefault || profile.toLowerCase() == 'default') {
      throw StateError('The default profile cannot be deleted.');
    }
    final dashboard = _dashboard;
    if (dashboard == null) {
      throw StateError('Dashboard connection is unavailable');
    }
    await dashboard.deleteProfile(profile);
    _profileBySession.removeWhere((_, value) => value == profile);
  }

  bool _isSessionNotFound(Object error) {
    final text = '$error'.toLowerCase();
    return text.contains('session not found') ||
        text.contains('unknown session') ||
        text.contains('no such session');
  }

  /// True when [error] is the gateway's own explicit, permanent rejection of
  /// this specific request rather than a transport/connectivity failure.
  ///
  /// Post-merge, code **4018** covers a whole class of permanent
  /// `prompt.submit` / slash-command validation failures beyond rewind
  /// staleness — see `tui_gateway/methods_prompt.py` (`target user message is
  /// no longer in session history`, oversized image/PDF attachments) and
  /// `tui_gateway/methods_tools.py` (bundle dispatch failures, "no previous
  /// user message to retry"). Every one of these means the gateway is live
  /// and reachable and is refusing THIS request specifically — retrying it,
  /// forcing a WS reconnect, or (worse) silently queuing it into the offline
  /// outbox can never fix it and just replays a doomed operation forever
  /// under a misleading "will send when WebSocket reconnects" banner.
  ///
  /// Keyed off the numeric [GatewayRpcException.code] (see
  /// gateway_ws_client.dart) rather than message text: the code is the one
  /// stable signal shared by every 4018 message string, present and future.
  bool _isTerminalGatewayRejection(Object error) =>
      error is GatewayRpcException &&
      const {4004, 4018, 4029, 4030}.contains(error.code);

  /// True when the gateway or the upstream provider refused this request
  /// because a rate limit / usage quota is exhausted (HTTP 429).
  ///
  /// Vocabulary mirrors the gateway's own `_GATEWAY_RATE_LIMIT_RE`
  /// (`gateway/run.py`). This is deliberately treated as terminal for the
  /// client: an immediate forced-reconnect resend, or an outbox replay every
  /// ~40s for eight attempts, is the one response guaranteed to make a rate
  /// limit worse. The user is told instead, and decides when to try again.
  static bool _isRateLimited(Object error) =>
      _rateLimitPattern.hasMatch('$error');

  static final _rateLimitPattern = RegExp(
    r'(rate[\s-]?limit|\b429\b|quota|usage limit)',
    caseSensitive: false,
  );

  /// True when a `prompt.submit` transport failure happened *before* the frame
  /// was written to the socket, so resending it cannot duplicate the turn.
  ///
  /// [GatewayWsClient.requestWithTimeout] has exactly one pre-write throw — the
  /// channel is absent or not `open`. Everything else it can surface
  /// (`WebSocket closed` / `disconnected` from `_failPending`, or the ack
  /// timeout) happens only after `sink.add`, i.e. with delivery unknown.
  static bool _submitNeverLeftThePhone(Object error) =>
      error is StateError && '$error'.contains('gateway not connected');

  /// True when the transcript already carries an assistant/system reply after
  /// its last user turn — i.e. the turn we lost the socket on actually landed.
  static bool _hasReplyAfterLastUser(List<HermesMessage> messages) {
    final lastUser = messages.lastIndexWhere((m) => m.isUser);
    if (lastUser < 0) return false;
    return messages
        .skip(lastUser + 1)
        .any(
          (m) =>
              (m.isAssistant || m.isSystem) &&
              (m.content ?? '').trim().isNotEmpty,
        );
  }

  /// Banner for a turn whose delivery we could not confirm. Deliberately not
  /// phrased as a failure: the gateway may be running it right now, and the
  /// bubble self-expires from the transcript once the real reply syncs in
  /// (see the [kLocalErrorIdPrefix] handling in [syncMessages]).
  static const _unconfirmedSubmitBanner =
      'Connection dropped before the gateway confirmed this message. '
      'It was not resent, so it cannot run twice — the reply may still '
      'arrive. Pull to refresh.';

  /// Shared handling for [PromptSubmitUnconfirmed]: never resend, resync, and
  /// only annotate the transcript when the server has no reply for this turn.
  Future<ChatSendResult> _resolveUnconfirmedSubmit(
    PromptSubmitUnconfirmed error,
    String fallbackSessionId,
  ) async {
    final sid = error.effectiveSessionId ?? fallbackSessionId;
    List<HermesMessage> msgs;
    try {
      msgs = await syncMessages(sid);
    } catch (_) {
      msgs = await loadMessagesLocal(sid);
    }
    if (_hasReplyAfterLastUser(msgs)) {
      return ChatSendResult(messages: msgs, queued: false, sessionId: sid);
    }
    return ChatSendResult(
      messages: ensureErrorAssistantMessage(
        msgs,
        sessionId: sid,
        errorText: _unconfirmedSubmitBanner,
      ),
      queued: false,
      sessionId: sid,
      error: _unconfirmedSubmitBanner,
    );
  }

  /// The one 4018 sub-case that IS recoverable: the client's cached
  /// `truncate_before_user_ordinal` no longer matches the gateway's live
  /// visible-user-turn count (e.g. a synthetic system marker miscounted as a
  /// user turn — see [HermesMessage.isVisibleUser] — or a concurrent
  /// edit/rewind from another client). Desktop used to retry this exact case
  /// as a plain resend before it moved to durable row-id addressing
  /// (`apps/desktop` git history at 23da6d6fe / 42eec4ab3); mobile has no
  /// row-id plumbing, so this stays the fallback.
  bool _isStaleTargetError(Object error) {
    final text = '$error'.toLowerCase();
    return text.contains('no longer in session history') ||
        text.contains('not in session history');
  }

  void _forgetLiveMapping(String sessionId) {
    final liveId = _liveByStored.remove(sessionId);
    if (liveId != null) {
      _storedByLive.remove(liveId);
      _liveByStored.remove(liveId);
    }
    final storedId = _storedByLive.remove(sessionId);
    if (storedId != null) {
      _liveByStored.remove(storedId);
    }
  }

  Future<List<HermesMessage>> _persistTerminalError(
    String sessionId,
    String error,
  ) async {
    final local = await loadMessagesLocal(sessionId);
    final next = ensureErrorAssistantMessage(
      local,
      sessionId: sessionId,
      errorText: error,
    );
    if (next.length > local.length) {
      await _db.upsertMessage(
        _messageToCompanion(
          next.last,
          sortIndex: local.length,
          syncStatus: 'pending',
        ),
      );
    }
    return next;
  }

  /// Resolve WS runtime id for [sessionId] (stored or live). Resumes if needed.
  Future<String> _ensureLiveSessionId(
    String sessionId, {
    String? model,
    String? provider,
  }) async {
    final rt = _realtime;
    if (rt == null || !rt.isLive) {
      throw StateError('gateway not live');
    }

    if (sessionId.startsWith('local_')) {
      final created = await _createSessionOnGateway(
        model: model,
        provider: provider,
      );
      await _remapSessionId(sessionId, created);
      final live = _liveByStored[created.id] ?? created.id;
      return live;
    }

    final cached = _liveByStored[sessionId];
    if (cached != null && cached.isNotEmpty) return cached;

    // Existing REST session — Desktop session.resume re-binds a runtime slot.
    try {
      final resumed = await rt.request('session.resume', {
        'session_id': sessionId,
        'source': 'mobile',
        'profile': ?_profileForSession(sessionId),
      });
      final liveId = '${resumed['session_id'] ?? ''}'.trim();
      if (liveId.isNotEmpty) {
        _registerLiveMapping(storedId: sessionId, liveId: liveId);
        return liveId;
      }
    } catch (e) {
      debugPrint('SessionSync: session.resume failed for $sessionId: $e');
    }

    // Fall back: treat the id as already-live (rare: short-lived create id).
    _registerLiveMapping(storedId: sessionId, liveId: sessionId);
    return sessionId;
  }

  /// Desktop rename — prefer live `session.title` RPC, else REST PATCH.
  Future<void> renameSession(String sessionId, String title) async {
    final trimmed = title.trim();
    // Optimistic local title for snappy drawer.
    final local = await loadSessionsLocal();
    final existing = local.where((s) => s.id == sessionId).firstOrNull;
    final profile = _profileForSession(sessionId);
    if (profile != null &&
        (_isCanonicalBotChatId(sessionId) ||
            existing?.title?.trim() == 'Bot Chat')) {
      throw StateError(
        'Bot Chat is the bot’s canonical conversation and cannot be renamed. '
        'Create another bot session to use a custom title.',
      );
    }
    if (existing != null) {
      await _db.upsertSession(
        _sessionToCompanion(
          HermesSession(
            id: existing.id,
            source: existing.source,
            userId: existing.userId,
            model: existing.model,
            title: trimmed.isEmpty ? null : trimmed,
            startedAt: existing.startedAt,
            endedAt: existing.endedAt,
            endReason: existing.endReason,
            messageCount: existing.messageCount,
            toolCallCount: existing.toolCallCount,
            lastActive: existing.lastActive,
            preview: existing.preview,
            parentSessionId: existing.parentSessionId,
          ),
          syncStatus: 'pending',
        ),
      );
    }

    // Active runtime id if we have one mapped.
    final liveId = _liveByStored[sessionId] ?? _storedByLive[sessionId];
    final rt = _realtime;
    if (trimmed.isNotEmpty &&
        rt != null &&
        rt.isLive &&
        liveId != null &&
        liveId.isNotEmpty) {
      try {
        await rt.request('session.title', {
          'session_id': liveId,
          'title': trimmed,
        });
        if (existing != null) {
          await _db.upsertSession(
            _sessionToCompanion(
              HermesSession(
                id: existing.id,
                source: existing.source,
                userId: existing.userId,
                model: existing.model,
                title: trimmed,
                startedAt: existing.startedAt,
                endedAt: existing.endedAt,
                endReason: existing.endReason,
                messageCount: existing.messageCount,
                toolCallCount: existing.toolCallCount,
                lastActive: existing.lastActive,
                preview: existing.preview,
                parentSessionId: existing.parentSessionId,
              ),
              syncStatus: 'synced',
            ),
          );
        }
        return;
      } catch (e) {
        debugPrint('SessionSync: session.title RPC failed, REST fallback: $e');
      }
    }

    final dash = _dashboard;
    if (dash != null) {
      await dash.renameSession(sessionId, trimmed);
      if (existing != null) {
        await _db.upsertSession(
          _sessionToCompanion(
            HermesSession(
              id: existing.id,
              source: existing.source,
              userId: existing.userId,
              model: existing.model,
              title: trimmed.isEmpty ? null : trimmed,
              startedAt: existing.startedAt,
              endedAt: existing.endedAt,
              endReason: existing.endReason,
              messageCount: existing.messageCount,
              toolCallCount: existing.toolCallCount,
              lastActive: existing.lastActive,
              preview: existing.preview,
              parentSessionId: existing.parentSessionId,
            ),
            syncStatus: 'synced',
          ),
        );
      }
      return;
    }

    final api = _api;
    if (api != null) {
      await api.patchSession(sessionId, title: trimmed);
      return;
    }
    throw StateError('No gateway connection for rename');
  }

  /// Desktop archive — PATCH archived=true, drop from local recents list.
  Future<void> archiveSession(String sessionId) async {
    final dash = _dashboard;
    if (dash != null) {
      try {
        await dash.setSessionArchived(sessionId, true);
        await _db.removeSession(gatewayId, sessionId);
        return;
      } catch (e) {
        debugPrint('SessionSync: archive failed: $e');
        rethrow;
      }
    }
    // Offline / no dashboard: hide locally; queue if we grow an outbox op later.
    await _db.removeSession(gatewayId, sessionId);
  }

  /// Desktop export — JSON of session + messages (caller shares the string).
  Future<Map<String, dynamic>> exportSessionPayload(String sessionId) async {
    List<HermesMessage> messages;
    try {
      messages = await syncMessages(sessionId);
    } catch (_) {
      messages = await loadMessagesLocal(sessionId);
    }
    final sessions = await loadSessionsLocal();
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    return {
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'session_id': sessionId,
      'title': session?.title,
      'session': session == null
          ? null
          : {
              'id': session.id,
              'source': session.source,
              'model': session.model,
              'title': session.title,
              'started_at': session.startedAt,
              'last_active': session.lastActive,
              'message_count': session.messageCount,
              'preview': session.preview,
            },
      'message_count': messages.length,
      'messages': [
        for (final m in messages)
          {
            'id': m.id,
            'session_id': m.sessionId,
            'role': m.role,
            'content': m.content,
            'timestamp': m.timestamp,
            if (m.toolName != null) 'tool_name': m.toolName,
          },
      ],
    };
  }

  Future<void> deleteSession(String sessionId) async {
    await _db.markSessionDeleted(gatewayId, sessionId);
    // Prefer immediate dashboard DELETE (Desktop path).
    final dash = _dashboard;
    if (dash != null) {
      try {
        await dash.deleteSession(sessionId);
        await _db.removeSession(gatewayId, sessionId);
        return;
      } catch (e) {
        debugPrint('SessionSync: dashboard delete failed, queueing: $e');
      }
    }
    await _db.enqueueOp(
      PendingOpsCompanion.insert(
        id: _uuid.v4(),
        gatewayId: gatewayId,
        opType: 'delete_session',
        sessionId: Value(sessionId),
        payloadJson: jsonEncode({'session_id': sessionId}),
        createdAt: DateTime.now().toUtc(),
      ),
    );
    await flushOutbox();
    final ops = await _db.pendingOpsForGateway(gatewayId);
    final stillPending = ops.any(
      (o) => o.opType == 'delete_session' && o.sessionId == sessionId,
    );
    if (!stillPending) {
      await _db.removeSession(gatewayId, sessionId);
    }
  }

  /// Live gateway JSON-RPC (used by slash + attach). Ensures WS is up.
  Future<Map<String, dynamic>> gatewayRequest(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final live = await _ensureWsLive();
    if (!live) {
      throw StateError(_realtime?.lastError ?? 'WebSocket not connected');
    }
    return _realtime!.request(method, params, timeout);
  }

  /// Ensure a live session id for slash/attach (creates from local_* if needed).
  Future<String> ensureLiveSessionId(
    String sessionId, {
    String? model,
    String? provider,
  }) async {
    final live = await _ensureWsLive();
    if (!live) {
      throw StateError(_realtime?.lastError ?? 'WebSocket not connected');
    }
    return _ensureLiveSessionId(sessionId, model: model, provider: provider);
  }

  /// Run a `/slash` command via `slash.exec` / `command.dispatch` (web parity).
  Future<SlashExecResult> runSlashCommand({
    required String sessionId,
    required String command,
    required SlashCallbacks callbacks,
    String? model,
    String? provider,
  }) async {
    final liveId = await ensureLiveSessionId(
      sessionId,
      model: model,
      provider: provider,
    );
    // Prefer durable stored id for session_id when we have it.
    final stored = _storedByLive[liveId] ?? sessionId;
    return executeSlash(
      command: command,
      sessionId: liveId.isNotEmpty ? liveId : stored,
      request: (method, params) => gatewayRequest(method, params),
      callbacks: callbacks,
    );
  }

  Future<List<SlashCompletion>> completeSlashText(String text) async {
    final live = await _ensureWsLive();
    if (!live) return const [];
    return completeSlash(
      text: text,
      request: (method, params) => gatewayRequest(method, params),
    );
  }

  /// Local-first skills catalog.
  ///
  /// 1. SQLite cache (instant)
  /// 2. REST `GET /api/skills`
  /// 3. WS `skills.manage` list (shape is category→names map, not list)
  /// 4. WS `commands.catalog` skill pairs as last remote fallback
  ///
  /// Successful remote pulls replace the cache. Failures keep last-known cache.
  ///
  /// Coalesced via [SingleFlight] (see [syncSessions] for the rationale and
  /// [bypassTtl] semantics).
  Future<List<HermesSkill>> listSkills({bool bypassTtl = false}) {
    return _skillsFlight.run(_listSkillsImpl, bypassTtl: bypassTtl);
  }

  Future<List<HermesSkill>> _listSkillsImpl() async {
    final local = await loadSkillsLocal();

    List<HermesSkill>? remote;
    final dash = _dashboard;
    if (dash != null) {
      try {
        final skills = await dash.listSkills();
        if (skills.isNotEmpty) remote = skills;
      } catch (e) {
        debugPrint('SessionSync: listSkills REST failed: $e');
      }
    }

    if (remote == null || remote.isEmpty) {
      try {
        final live = await _ensureWsLive();
        if (live) {
          final raw = await gatewayRequest('skills.manage', {'action': 'list'});
          final parsed = _parseSkillsManagePayload(raw['skills']);
          if (parsed.isNotEmpty) remote = parsed;
        }
      } catch (e) {
        debugPrint('SessionSync: skills.manage list failed: $e');
      }
    }

    if (remote == null || remote.isEmpty) {
      try {
        final live = await _ensureWsLive();
        if (live) {
          final catalog = await gatewayRequest('commands.catalog', {});
          final fromCatalog = _skillsFromCommandsCatalog(catalog);
          if (fromCatalog.isNotEmpty) remote = fromCatalog;
        }
      } catch (e) {
        debugPrint('SessionSync: skills from commands.catalog failed: $e');
      }
    }

    if (remote != null && remote.isNotEmpty) {
      await _cacheSkills(remote);
      return remote;
    }
    // Empty remote or total failure — never wipe a good local cache.
    return local;
  }

  Future<List<HermesSkill>> loadSkillsLocal() async {
    final rows = await _db.skillsForGateway(gatewayId);
    return rows
        .map(
          (r) => HermesSkill(
            name: r.name,
            description: r.description,
            category: r.category,
            enabled: r.enabled,
            provenance: r.provenance,
            usage: r.usage,
          ),
        )
        .toList();
  }

  Future<void> _cacheSkills(List<HermesSkill> skills) async {
    final now = DateTime.now().toUtc();
    await _db.replaceSkills(gatewayId, [
      for (final s in skills)
        if (s.name.trim().isNotEmpty)
          CachedSkillsCompanion.insert(
            gatewayId: gatewayId,
            name: s.name.trim(),
            description: Value(s.description),
            category: Value(s.category),
            enabled: Value(s.enabled),
            provenance: Value(s.provenance),
            usage: Value(s.usage),
            updatedAt: now,
          ),
    ]);
  }

  /// `skills.manage` returns either a List of skill maps **or**
  /// `{category: [name, …]}` from `get_available_skills()`.
  static List<HermesSkill> _parseSkillsManagePayload(Object? skills) {
    if (skills is List) {
      return skills
          .whereType<Map>()
          .map((m) => HermesSkill.fromJson(m.cast<String, dynamic>()))
          .where((s) => s.name.isNotEmpty)
          .toList();
    }
    if (skills is Map) {
      final out = <HermesSkill>[];
      skills.forEach((cat, names) {
        if (names is! List) return;
        for (final n in names) {
          final name = '$n'.trim();
          if (name.isEmpty) continue;
          out.add(HermesSkill(name: name, category: '$cat', enabled: true));
        }
      });
      return out;
    }
    return const [];
  }

  /// Skill slash pairs from `commands.catalog` (scan_skill_commands).
  static List<HermesSkill> _skillsFromCommandsCatalog(
    Map<String, dynamic> catalog,
  ) {
    final out = <HermesSkill>[];
    final seen = <String>{};

    void addPair(String command, String desc, String group) {
      final cmd = command.trim();
      if (!cmd.startsWith('/')) return;
      final name = cmd.substring(1).trim();
      if (name.isEmpty || seen.contains(name.toLowerCase())) return;
      // Skip known built-in commands — catalog mixes both.
      if (kKnownBuiltinSlashNames.contains(name.toLowerCase())) return;
      // Prefer categories that look skill-related, but also accept unknown
      // slash names (Desktop treats non-builtins as skills).
      final g = group.toLowerCase();
      final skillish =
          g.contains('skill') || g.contains('plugin') || isSkillSlashName(cmd);
      if (!skillish) return;
      seen.add(name.toLowerCase());
      out.add(
        HermesSkill(
          name: name,
          description: desc.isEmpty ? null : desc,
          category: group.isEmpty ? 'Skills' : group,
          enabled: true,
        ),
      );
    }

    final categories = catalog['categories'];
    if (categories is List) {
      for (final section in categories) {
        if (section is! Map) continue;
        final name = '${section['name'] ?? ''}';
        final pairs = section['pairs'];
        if (pairs is! List) continue;
        for (final pair in pairs) {
          if (pair is List && pair.isNotEmpty) {
            addPair('${pair[0]}', pair.length > 1 ? '${pair[1]}' : '', name);
          }
        }
      }
    }
    final pairs = catalog['pairs'];
    if (pairs is List) {
      for (final pair in pairs) {
        if (pair is List && pair.isNotEmpty) {
          addPair('${pair[0]}', pair.length > 1 ? '${pair[1]}' : '', 'Skills');
        }
      }
    }
    return out;
  }

  /// Rescan host skill dirs so new user skills show up as slash commands.
  Future<String> reloadSkills() async {
    final live = await _ensureWsLive();
    if (!live) {
      throw StateError(
        _realtime?.lastError ??
            'WebSocket not connected — cannot reload skills',
      );
    }
    final raw = await gatewayRequest('skills.reload', {});
    final out = raw['output']?.toString();
    if (out != null && out.trim().isNotEmpty) return out.trim();
    final result = raw['result'];
    if (result is Map) {
      final total = result['total'];
      return 'Skills reloaded${total != null ? ' ($total available)' : ''}.';
    }
    return 'Skills reloaded.';
  }

  /// Slash completions = Desktop pipeline + installed skills merge.
  ///
  /// Bare `/` uses `commands.catalog` (Desktop). Skills the user installed
  /// may lag in the slash worker until reload; REST/WS skill names fill gaps.
  Future<List<SlashCompletion>> completeSlashWithSkills(String text) async {
    // Ensure WS early so bare `/` isn't an empty spinner forever.
    await _ensureWsLive();
    final gatewayItems = await completeSlashText(text);
    final q = text.trim();
    // Only merge skill names at bare-command stage (`/`, `/gif`), not arg stage.
    if (q.contains(RegExp(r'\s'))) {
      return gatewayItems;
    }
    final needle = q.replaceFirst(RegExp(r'^/+'), '').toLowerCase();
    List<HermesSkill> skills;
    try {
      skills = await listSkills();
    } catch (_) {
      skills = const [];
    }
    final seen = <String>{
      for (final c in gatewayItems)
        c.text.toLowerCase().trim().split(RegExp(r'\s+')).first,
    };
    final skillItems = <SlashCompletion>[];
    for (final s in skills) {
      if (!s.enabled) continue;
      final cmd = s.slashCommand;
      final key = cmd.toLowerCase();
      if (seen.contains(key)) continue;
      final name = s.name.toLowerCase();
      if (needle.isNotEmpty &&
          !name.startsWith(needle) &&
          !name.contains(needle) &&
          !key.contains(needle)) {
        continue;
      }
      seen.add(key);
      skillItems.add(
        SlashCompletion(
          text: cmd,
          display: cmd,
          meta: s.description?.trim().isNotEmpty == true
              ? s.description!.trim()
              : (s.category ?? 'Skill'),
          group: 'Skills',
          isSkill: true,
        ),
      );
    }
    if (skillItems.isEmpty) return gatewayItems;

    // Prefer skills that match the typed prefix first.
    skillItems.sort((a, b) {
      if (needle.isEmpty) {
        return a.text.toLowerCase().compareTo(b.text.toLowerCase());
      }
      final an = a.text.toLowerCase().replaceFirst('/', '');
      final bn = b.text.toLowerCase().replaceFirst('/', '');
      final ap = an.startsWith(needle) ? 0 : 1;
      final bp = bn.startsWith(needle) ? 0 : 1;
      if (ap != bp) return ap - bp;
      return an.compareTo(bn);
    });

    // Gateway already orders Commands then Skills; append only missing skills.
    final builtins = gatewayItems.where((c) => !c.isSkill).toList();
    final gatewaySkills = gatewayItems.where((c) => c.isSkill).toList();
    return [...builtins, ...gatewaySkills, ...skillItems];
  }

  /// Desktop remote attach: `image.attach_bytes` (base64). Mobile never has
  /// host filesystem paths, so path-based `image.attach` is not used.
  ///
  /// Call before [sendMessage] so the agent turn sees the images.
  Future<void> attachImageBytes({
    required String sessionId,
    required List<int> bytes,
    required String filename,
    String? model,
    String? provider,
  }) async {
    final live = await _ensureWsLive();
    if (!live) {
      throw StateError(
        _realtime?.lastError ?? 'WebSocket not connected — cannot attach image',
      );
    }
    final liveId = await _ensureLiveSessionId(
      sessionId,
      model: model,
      provider: provider,
    );
    final result = await _realtime!.request('image.attach_bytes', {
      'session_id': liveId,
      'content_base64': base64Encode(bytes),
      'filename': filename,
    });
    final attached = result['attached'] == true || result['ok'] == true;
    if (!attached) {
      final msg = result['message'] ?? result['error'] ?? 'attach failed';
      throw StateError('$msg');
    }
    debugPrint(
      'SessionSync: image.attach_bytes ok session=$liveId file=$filename '
      '(${bytes.length} bytes)',
    );
  }

  /// Desktop `session.interrupt` — stop the live agent turn.
  Future<void> interruptSession(String sessionId) async {
    final rt = _realtime;
    if (rt == null || !rt.isLive) {
      // Unblock local waiter even if socket is down.
      final done = _inflightTurnDone;
      if (done != null && !done.isCompleted) done.complete();
      return;
    }
    try {
      final liveId =
          _liveByStored[sessionId] ?? _storedByLive[sessionId] ?? sessionId;
      // Prefer the in-flight live id when present.
      final target = _inflightLiveId ?? liveId;
      await rt.request('session.interrupt', {'session_id': target});
    } catch (e) {
      debugPrint('SessionSync: session.interrupt failed: $e');
      // Try resume+interrupt like Desktop when runtime id is stale.
      try {
        final liveId = await _ensureLiveSessionId(sessionId);
        await rt.request('session.interrupt', {'session_id': liveId});
      } catch (e2) {
        debugPrint('SessionSync: interrupt retry failed: $e2');
      }
    } finally {
      final done = _inflightTurnDone;
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  /// 0-based index among *visible* user turns only (Desktop
  /// `visibleUserOrdinal`) — must use [HermesMessage.isVisibleUser], not
  /// [HermesMessage.isUser]: synthetic timeline markers (model_switch, …)
  /// carry `role: "user"` too, and counting them drifts this ordinal away
  /// from the gateway's own `_history_user_indices` count.
  static int userOrdinalAmong(List<HermesMessage> messages, int absoluteIndex) {
    var n = 0;
    for (var i = 0; i < absoluteIndex && i < messages.length; i++) {
      if (messages[i].isVisibleUser) n++;
    }
    return n;
  }

  /// Persist a user message locally, send to server when possible, then
  /// refresh transcript from server (or keep optimistic local on failure).
  ///
  /// [truncateBeforeUserOrdinal] — Desktop edit/retry: drop that user turn and
  /// everything after it, then re-submit [input] (see `prompt.submit`).
  Future<ChatSendResult> sendMessage({
    required String sessionId,
    required String input,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fastMode,
    int? truncateBeforeUserOrdinal,
    bool interruptFirst = false,
    void Function(String toolStatus)? onToolStatus,
    void Function(String assistantPartial)? onAssistantDelta,
    void Function(GatewayApprovalRequest? request)? onApprovalRequest,
  }) async {
    final now = DateTime.now().toUtc();
    final userId = _uuid.v4();
    final userMsg = HermesMessage(
      id: userId,
      sessionId: sessionId,
      role: 'user',
      content: input,
      timestamp: now.toIso8601String(),
    );

    final existing = await loadMessagesLocal(sessionId);
    final sortIndex = existing.length;
    await _db.upsertMessage(
      _messageToCompanion(userMsg, sortIndex: sortIndex, syncStatus: 'pending'),
    );
    await _touchSessionPreview(sessionId, input, messageCount: sortIndex + 1);

    // Watch for result notifications (WS live id may differ from stored id).
    final sessions = await loadSessionsLocal();
    final sessionMeta = sessions.where((s) => s.id == sessionId).firstOrNull;
    try {
      await WatchStore().watch(
        gatewayId: gatewayId,
        sessionId: sessionId,
        baselineMessageCount: sortIndex + 1, // after local user msg
        baselineLastMessageId: userId,
        title: sessionMeta?.displayTitle,
        aliases: [
          if (_liveByStored[sessionId] != null) _liveByStored[sessionId]!,
        ],
      );
      // Nudge OS to run a sync soon (covers backgrounded waits).
      unawaited(
        BackgroundSync.scheduleSoon(delay: const Duration(seconds: 20)),
      );
    } catch (e) {
      debugPrint('SessionSync: watch/schedule failed: $e');
    }

    // ── Live gateway path (Desktop: prompt.submit + stream events) ──
    // Retry once with a forced reconnect — Settings can show "HTTPS connected"
    // while the WS is down, and a half-open socket needs a fresh ticket.
    //
    // Only PRE-submit failures are retried. Once `prompt.submit` was accepted
    // the gateway queues mid-turn prompts instead of rejecting them, so a
    // retry (or an outbox re-enqueue) would run the same prompt twice — for a
    // tool-using agent that re-executes side effects. A post-submit turn
    // error is surfaced to the user instead.
    Object? lastWsErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      final live = await _ensureWsLive(force: attempt > 0);
      if (!live) {
        lastWsErr = StateError(
          _realtime?.lastError ?? 'WebSocket not connected',
        );
        continue;
      }
      try {
        return await _sendViaGateway(
          sessionId: sessionId,
          input: input,
          model: model,
          provider: provider,
          reasoningEffort: reasoningEffort,
          fastMode: fastMode,
          userId: userId,
          userMsg: userMsg,
          sortIndex: sortIndex,
          sessionMeta: sessionMeta,
          truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
          interruptFirst: interruptFirst && attempt == 0,
          onToolStatus: onToolStatus,
          onAssistantDelta: onAssistantDelta,
          onApprovalRequest: onApprovalRequest,
        );
      } on PromptSubmitUnconfirmed catch (e) {
        debugPrint('SessionSync: submit delivery unconfirmed (no resend): $e');
        return _resolveUnconfirmedSubmit(e, sessionId);
      } on TurnFailedAfterSubmit catch (e) {
        debugPrint('SessionSync: turn failed after submit (no retry): $e');
        final sid = e.effectiveSessionId ?? sessionId;
        List<HermesMessage> msgs;
        try {
          msgs = await syncMessages(sid);
        } catch (_) {
          msgs = await loadMessagesLocal(sid);
        }
        final userFacing = formatTurnErrorForUser(e.message);
        msgs = ensureErrorAssistantMessage(
          msgs,
          sessionId: sid,
          errorText: userFacing,
        );
        return ChatSendResult(
          messages: msgs,
          queued: false,
          sessionId: sid,
          error: userFacing,
        );
      } catch (e, st) {
        lastWsErr = e;
        debugPrint('SessionSync: WS chat attempt $attempt failed: $e\n$st');
        // The socket can survive a gateway restart while its in-memory live
        // session does not. prompt.submit is rejected before execution in this
        // case, so discard the stale id and let the next attempt session.resume
        // the durable session instead of queueing it as if the phone were
        // offline.
        if (_isSessionNotFound(e)) {
          _forgetLiveMapping(sessionId);
        } else if (_isRateLimited(e)) {
          // A rate limit is the gateway/provider saying "not now". A forced
          // reconnect resends the identical request seconds later against the
          // same limit — it cannot succeed and it deepens the throttle.
          debugPrint('SessionSync: rate limited; not resending: $e');
          break;
        } else if (_isTerminalGatewayRejection(e)) {
          // The gateway is live and has permanently rejected this exact
          // request (4018). A forced-reconnect retry would resend the same
          // request and fail identically — stop the connectivity loop so the
          // dedicated stale-target retry (below) and the terminal-error
          // classification can run without a wasted round trip.
          break;
        }
      }
    }

    // A stale truncate ordinal is the one 4018 sub-case that's recoverable:
    // the client's cached ordinal no longer matches the gateway's live turn
    // count. Retry exactly once as a plain resend (no truncation) instead of
    // resending the same doomed ordinal again or falling into the outbox
    // below, which would misreport a live rejection as "will send when
    // WebSocket reconnects".
    if (truncateBeforeUserOrdinal != null &&
        lastWsErr != null &&
        _isStaleTargetError(lastWsErr)) {
      debugPrint(
        'SessionSync: stale truncate ordinal $truncateBeforeUserOrdinal; '
        'retrying once as a plain resend',
      );
      try {
        if (await _ensureWsLive()) {
          return await _sendViaGateway(
            sessionId: sessionId,
            input: input,
            model: model,
            provider: provider,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            userId: userId,
            userMsg: userMsg,
            sortIndex: sortIndex,
            sessionMeta: sessionMeta,
            truncateBeforeUserOrdinal: null,
            interruptFirst: false,
            onToolStatus: onToolStatus,
            onAssistantDelta: onAssistantDelta,
            onApprovalRequest: onApprovalRequest,
          );
        }
      } on PromptSubmitUnconfirmed catch (e) {
        debugPrint(
          'SessionSync: ordinal-free retry delivery unconfirmed (no resend): '
          '$e',
        );
        return _resolveUnconfirmedSubmit(e, sessionId);
      } on TurnFailedAfterSubmit catch (e) {
        debugPrint(
          'SessionSync: ordinal-free retry failed after submit (no retry): $e',
        );
        final sid = e.effectiveSessionId ?? sessionId;
        List<HermesMessage> msgs;
        try {
          msgs = await syncMessages(sid);
        } catch (_) {
          msgs = await loadMessagesLocal(sid);
        }
        final userFacing = formatTurnErrorForUser(e.message);
        msgs = ensureErrorAssistantMessage(
          msgs,
          sessionId: sid,
          errorText: userFacing,
        );
        return ChatSendResult(
          messages: msgs,
          queued: false,
          sessionId: sid,
          error: userFacing,
        );
      } catch (e, st) {
        debugPrint('SessionSync: ordinal-free retry failed: $e\n$st');
        lastWsErr = e;
      }
    }

    // A connected gateway's explicit, permanent rejection — session gone, or
    // any 4018 (including a stale-target retry that still failed) — is not
    // an offline condition. Queuing here creates a misleading "will send
    // when WebSocket reconnects" banner and repeatedly replays an operation
    // that can never succeed. Keep a durable terminal error instead.
    if (lastWsErr != null &&
        (_isSessionNotFound(lastWsErr) ||
            _isRateLimited(lastWsErr) ||
            _isTerminalGatewayRejection(lastWsErr))) {
      final userFacing = formatTurnErrorForUser('$lastWsErr');
      return ChatSendResult(
        messages: await _persistTerminalError(sessionId, userFacing),
        queued: false,
        sessionId: sessionId,
        error: userFacing,
      );
    }

    // Real server session ids only for legacy API chat; local_* must flush first.
    if (sessionId.startsWith('local_')) {
      await flushOutbox();
      final sessions = await loadSessionsLocal();
      final still = sessions.where((s) => s.id == sessionId).firstOrNull;
      if (still != null) {
        await _db.enqueueOp(
          PendingOpsCompanion.insert(
            id: _uuid.v4(),
            gatewayId: gatewayId,
            opType: 'chat',
            sessionId: Value(sessionId),
            payloadJson: jsonEncode({
              'session_id': sessionId,
              'input': input,
              'model': ?model,
              'provider': ?provider,
              'local_user_message_id': userId,
            }),
            createdAt: DateTime.now().toUtc(),
          ),
        );
        // No legacy API_SERVER_KEY — outbox only flushes when WS comes back.
        unawaited(flushPendingOverWs());
        return ChatSendResult(
          messages: await loadMessagesLocal(sessionId),
          queued: true,
          error: lastWsErr != null
              ? 'Live chat unavailable ($lastWsErr). Saved on phone — will send when WebSocket reconnects.'
              : 'Saved on phone — will send when WebSocket reconnects.',
        );
      }
    }

    final resolvedId = await _resolveSessionId(sessionId);
    final api = _api;
    if (api == null) {
      await _db.enqueueOp(
        PendingOpsCompanion.insert(
          id: _uuid.v4(),
          gatewayId: gatewayId,
          opType: 'chat',
          sessionId: Value(resolvedId),
          payloadJson: jsonEncode({
            'session_id': resolvedId,
            'input': input,
            'model': ?model,
            'provider': ?provider,
            'local_user_message_id': userId,
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      unawaited(flushPendingOverWs());
      return ChatSendResult(
        messages: await loadMessagesLocal(resolvedId),
        queued: true,
        sessionId: resolvedId,
        error: lastWsErr != null
            ? 'Live chat unavailable ($lastWsErr). Saved on phone — will send when WebSocket reconnects.'
            : 'Saved on phone — will send when WebSocket reconnects. '
                  'Settings may show HTTPS connected without a live socket.',
      );
    }

    var usedStream = false;
    try {
      var assistantText = '';
      final assistantId = _uuid.v4();

      await for (final event in api.chatStream(
        resolvedId,
        input: input,
        model: model,
      )) {
        usedStream = true;
        final type = '${event['event'] ?? event['type'] ?? ''}'.toLowerCase();

        if (type.contains('tool') && type.contains('start')) {
          onToolStatus?.call(
            'Running ${event['name'] ?? event['tool'] ?? 'tool'}…',
          );
        } else if (type.contains('tool') && type.contains('complete')) {
          onToolStatus?.call('');
        } else if (type.contains('completed') || type == 'done') {
          // Terminal event carries the FULL final text (assistant.completed
          // {content}) — it must REPLACE accumulated deltas, never append,
          // and must be checked before any generic delta extraction or the
          // reply renders doubled ("HelloHello").
          final finalText =
              event['output'] ?? event['content'] ?? event['text'];
          if (finalText != null && '$finalText'.isNotEmpty) {
            assistantText = '$finalText';
            onAssistantDelta?.call(assistantText);
          }
        } else if (type.contains('error')) {
          // The turn ran server-side and failed — surfacing (not re-sending)
          // is the only safe option once the prompt was delivered.
          throw TurnFailedAfterSubmit(
            '${event['message'] ?? event['error'] ?? 'stream error'}',
            effectiveSessionId: resolvedId,
          );
        } else {
          final delta =
              event['delta'] ??
              (event['data'] is Map ? (event['data'] as Map)['delta'] : null) ??
              (type.contains('delta')
                  ? (event['text'] ?? event['content'])
                  : null);
          if (delta != null) {
            assistantText += '$delta';
            onAssistantDelta?.call(assistantText);
          }
        }
      }

      // Non-stream fallback ONLY when the stream endpoint yielded nothing at
      // all. If the stream ran, the turn already executed — re-POSTing the
      // same input would run a second agent turn (duplicate side effects);
      // an empty assistantText self-heals via the syncMessages pull below.
      if (!usedStream) {
        final res = await api.chat(resolvedId, input: input, model: model);
        final out = _extractChatOutput(res);
        if (out != null) assistantText = out;
      }

      await _db.upsertMessage(
        _messageToCompanion(
          userMsg.copyWith(id: userId),
          sortIndex: sortIndex,
          syncStatus: 'synced',
        ).copyWith(sessionId: Value(resolvedId)),
      );
      if (assistantText.isNotEmpty) {
        await _db.upsertMessage(
          _messageToCompanion(
            HermesMessage(
              id: assistantId,
              sessionId: resolvedId,
              role: 'assistant',
              content: assistantText,
              timestamp: DateTime.now().toUtc().toIso8601String(),
            ),
            sortIndex: sortIndex + 1,
            syncStatus: 'synced',
          ),
        );
      }

      final msgs = await syncMessages(resolvedId);
      await _finalizeWatchAfterSend(
        sessionId: sessionId,
        resolvedId: resolvedId,
        liveId: resolvedId,
        sortIndex: sortIndex,
        userId: userId,
        msgs: msgs,
        sessionMeta: sessionMeta,
      );
      return ChatSendResult(
        messages: msgs,
        queued: false,
        sessionId: resolvedId,
      );
    } on TurnFailedAfterSubmit catch (e) {
      // Prompt was delivered; re-enqueueing would run the turn twice.
      debugPrint('SessionSync: API turn failed after submit (no queue): $e');
      List<HermesMessage> msgs;
      try {
        msgs = await syncMessages(resolvedId);
      } catch (_) {
        msgs = await loadMessagesLocal(resolvedId);
      }
      final userFacing = formatTurnErrorForUser(e.message);
      msgs = ensureErrorAssistantMessage(
        msgs,
        sessionId: resolvedId,
        errorText: userFacing,
      );
      return ChatSendResult(
        messages: msgs,
        queued: false,
        sessionId: resolvedId,
        error: userFacing,
      );
    } catch (e, st) {
      if (usedStream) {
        // The stream started, so the gateway accepted the prompt; a dropped
        // connection mid-turn must not requeue (duplicate turn). The
        // transcript self-heals on the next syncMessages pull.
        debugPrint('SessionSync: stream dropped mid-turn (no queue): $e');
        final userFacing = formatTurnErrorForUser('$e');
        var msgs = await loadMessagesLocal(resolvedId);
        msgs = ensureErrorAssistantMessage(
          msgs,
          sessionId: resolvedId,
          errorText: userFacing,
        );
        return ChatSendResult(
          messages: msgs,
          queued: false,
          sessionId: resolvedId,
          error: userFacing,
        );
      }
      debugPrint('SessionSync: chat failed, queueing: $e\n$st');
      await _db.enqueueOp(
        PendingOpsCompanion.insert(
          id: _uuid.v4(),
          gatewayId: gatewayId,
          opType: 'chat',
          sessionId: Value(resolvedId),
          payloadJson: jsonEncode({
            'session_id': resolvedId,
            'input': input,
            'model': ?model,
            'local_user_message_id': userId,
          }),
          createdAt: DateTime.now().toUtc(),
        ),
      );
      try {
        unawaited(
          BackgroundSync.scheduleSoon(delay: const Duration(seconds: 10)),
        );
      } catch (_) {}
      return ChatSendResult(
        messages: await loadMessagesLocal(resolvedId),
        queued: true,
        sessionId: resolvedId,
        error: '$e',
      );
    }
  }

  /// Desktop chat path: ensure live session → prompt.submit → stream deltas.
  Future<ChatSendResult> _sendViaGateway({
    required String sessionId,
    required String input,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fastMode,
    required String userId,
    required HermesMessage userMsg,
    required int sortIndex,
    HermesSession? sessionMeta,
    int? truncateBeforeUserOrdinal,
    bool interruptFirst = false,
    void Function(String toolStatus)? onToolStatus,
    void Function(String assistantPartial)? onAssistantDelta,
    void Function(GatewayApprovalRequest? request)? onApprovalRequest,
  }) async {
    final rt = _realtime!;
    final liveId = await _ensureLiveSessionId(
      sessionId,
      model: model,
      provider: provider,
    );
    // Desktop always scopes the live agent to the composer pick before the
    // turn. After session.resume the agent may still be on the profile default
    // (or a prior model) — without this, sticky "grok-5.4" in the UI can send
    // on the wrong provider and surface "API call failed… Connection error".
    if (model != null && model.trim().isNotEmpty) {
      try {
        await _pinLiveSessionModel(
          liveId: liveId,
          model: model,
          provider: provider,
        );
      } catch (e) {
        // Don't abort the turn solely for a pin failure if the session already
        // has the right override — but do tell the status line.
        onToolStatus?.call('Model switch warning: $e');
      }
    }
    if (reasoningEffort != null && reasoningEffort.trim().isNotEmpty) {
      try {
        await _pinLiveSessionReasoning(liveId: liveId, effort: reasoningEffort);
      } catch (e) {
        onToolStatus?.call('Reasoning switch warning: $e');
      }
    }
    if (fastMode != null) {
      try {
        await _pinLiveSessionFast(liveId: liveId, enabled: fastMode);
      } catch (e) {
        onToolStatus?.call('Fast mode warning: $e');
      }
    }
    final storedId =
        _storedByLive[liveId] ??
        (sessionId.startsWith('local_')
            ? (_storedByLive[liveId] ?? liveId)
            : sessionId);

    // If we remapped local_* → server id, move the optimistic user row.
    final effectiveStored = await _resolveSessionId(
      sessionId.startsWith('local_') ? storedId : sessionId,
    );

    // Re-register watch with live + stored ids so message.complete matches.
    try {
      final sessions = await loadSessionsLocal();
      final sessionMeta =
          sessions.where((s) => s.id == effectiveStored).firstOrNull ??
          sessions.where((s) => s.id == sessionId).firstOrNull;
      await WatchStore().watch(
        gatewayId: gatewayId,
        sessionId: effectiveStored.isNotEmpty ? effectiveStored : sessionId,
        baselineMessageCount: sortIndex + 1,
        baselineLastMessageId: userId,
        title: sessionMeta?.displayTitle,
        aliases: {
          sessionId,
          liveId,
          storedId,
          effectiveStored,
        }.where((s) => s.isNotEmpty),
      );
    } catch (e) {
      debugPrint('SessionSync: re-watch with live id failed: $e');
    }

    if (effectiveStored != sessionId) {
      // User message was written under local id — rewrite to durable id.
      await _db.upsertMessage(
        _messageToCompanion(
          HermesMessage(
            id: userId,
            sessionId: effectiveStored,
            role: 'user',
            content: input,
            timestamp: userMsg.timestamp,
          ),
          sortIndex: sortIndex,
          syncStatus: 'pending',
        ),
      );
    }

    // Edit/retry while a turn is live: interrupt first (Desktop submitRewindPrompt).
    if (interruptFirst) {
      try {
        await rt.request('session.interrupt', {'session_id': liveId});
      } catch (e) {
        debugPrint('SessionSync: pre-submit interrupt: $e');
      }
    }

    var assistantText = '';
    var thinkingText = '';
    final turnDone = Completer<void>();
    _inflightTurnDone = turnDone;
    _inflightLiveId = liveId;
    String? turnError;
    var interrupted = false;

    bool eventMatches(GatewayWsEvent e) {
      final sid = e.sessionId;
      // Some gateway frames omit session_id on early status/thinking — still
      // accept when we own the only in-flight turn.
      if (sid == null || sid.isEmpty) {
        return _inflightLiveId == liveId;
      }
      return sid == liveId ||
          sid == effectiveStored ||
          sid == sessionId ||
          _storedByLive[sid] == effectiveStored ||
          _liveByStored[effectiveStored] == sid;
    }

    // Immediate UI feedback before any token (TTFT can be multi-second).
    onToolStatus?.call(L10n.current.thinking);

    // Subscribe BEFORE submit so fast turns can't complete unobserved.
    final sub = rt.events.listen((event) {
      if (!eventMatches(event)) return;
      final type = event.type;
      final payload = event.payload;

      // Wire shape: params = {type, session_id, payload: {...}} — dig nested.
      final body = payload['payload'] is Map
          ? (payload['payload'] as Map).cast<String, dynamic>()
          : payload;

      if (type == 'message.delta' || type == 'assistant.delta') {
        final delta = body['text'] ?? body['delta'] ?? body['content'];
        if (delta != null) {
          assistantText += '$delta';
          onToolStatus?.call(''); // clear thinking once tokens flow
          onAssistantDelta?.call(assistantText);
        }
      } else if (type == 'thinking.delta' ||
          type == 'reasoning.delta' ||
          type == 'agent.thinking') {
        final delta = body['text'] ?? body['delta'] ?? body['content'] ?? '';
        final chunk = '$delta';
        if (chunk.isNotEmpty) {
          thinkingText += chunk;
          // Keep status strip short — last non-empty line of thinking.
          final lines = thinkingText
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          final tail = lines.isEmpty ? L10n.current.thinking : lines.last;
          final shown = tail.length > 80
              ? '…${tail.substring(tail.length - 80)}'
              : tail;
          onToolStatus?.call(shown);
        } else {
          onToolStatus?.call(L10n.current.thinking);
        }
      } else if (type == 'message.start' || type == 'assistant.start') {
        onToolStatus?.call(L10n.current.writing);
      } else if (type == 'tool.start') {
        final name = body['name'] ?? body['tool'] ?? 'tool';
        onToolStatus?.call(L10n.current.runningTool('$name'));
      } else if (type == 'tool.complete' || type == 'tool.generating') {
        if (type == 'tool.complete') {
          onToolStatus?.call(
            assistantText.isEmpty ? L10n.current.thinking : '',
          );
        }
      } else if (type == 'approval.request') {
        onApprovalRequest?.call(
          GatewayApprovalRequest.fromJson(
            body,
            sessionId: event.sessionId?.trim().isNotEmpty == true
                ? event.sessionId!.trim()
                : liveId,
          ),
        );
      } else if (type == 'status.update') {
        final kind = '${body['kind'] ?? ''}'.toLowerCase();
        final text =
            '${body['text'] ?? body['message'] ?? body['status'] ?? ''}'.trim();
        if (kind.contains('interrupt') ||
            text.toLowerCase().contains('interrupt')) {
          interrupted = true;
          if (!turnDone.isCompleted) turnDone.complete();
          return;
        }
        if (text.isNotEmpty) {
          onToolStatus?.call(text);
        }
      } else if (type == 'message.complete' || type == 'assistant.complete') {
        onApprovalRequest?.call(null);
        final finalText = body['text'] ?? body['content'] ?? body['output'];
        if (finalText != null && '$finalText'.isNotEmpty) {
          assistantText = '$finalText';
          onAssistantDelta?.call(assistantText);
          // Desktop: API failures often arrive as complete text, not error.
          final asErr = completionErrorText(assistantText);
          if (asErr != null) {
            turnError = asErr;
          }
        }
        onToolStatus?.call('');
        if (!turnDone.isCompleted) turnDone.complete();
      } else if (type == 'error') {
        onApprovalRequest?.call(null);
        final msg =
            '${body['message'] ?? body['error'] ?? payload['message'] ?? 'gateway error'}';
        // Interrupt often surfaces as a soft error; treat as stop, not failure.
        if (msg.toLowerCase().contains('interrupt') ||
            msg.toLowerCase().contains('cancelled') ||
            msg.toLowerCase().contains('canceled')) {
          interrupted = true;
          if (!turnDone.isCompleted) turnDone.complete();
        } else {
          final userFacing = formatTurnErrorForUser(msg);
          turnError = userFacing;
          // Stream the failure into the chat bubble immediately (Desktop
          // failAssistantMessage / completionErrorText parity).
          if (assistantText.trim().isEmpty ||
              isCompletionErrorText(assistantText)) {
            assistantText = userFacing;
            onAssistantDelta?.call(assistantText);
          }
          if (!turnDone.isCompleted) turnDone.complete();
        }
      }
    });

    try {
      try {
        await rt.request(
          'prompt.submit',
          {
            'session_id': liveId,
            'text': input,
            'truncate_before_user_ordinal': ?truncateBeforeUserOrdinal,
            // Gateway protocol requires an explicit opt-in before a request
            // may discard history. Desktop sends this alongside every rewind;
            // omitting it is a live validation error (4029), not a disconnect.
            if (truncateBeforeUserOrdinal != null) 'confirm_truncate': true,
          },
          // Desktop PROMPT_SUBMIT_REQUEST_TIMEOUT_MS — ack is usually instant.
          const Duration(minutes: 30),
        );
      } on GatewayRpcException {
        // The gateway received the request and answered with a decision.
        // Existing classification (4018, session-not-found, …) owns this.
        rethrow;
      } catch (e) {
        // Transport failure. Whether it is safe to resend depends entirely on
        // whether the frame reached the socket, and that is knowable:
        // [GatewayWsClient.requestWithTimeout] throws *before* writing only
        // when the channel is missing/not open. Every other failure here —
        // `WebSocket closed`, `disconnected`, a timeout — happened AFTER the
        // frame went out, so the gateway may already be running the turn.
        //
        // The caller's reconnect loop used to resend on all of these, which is
        // how one tap could become two upstream provider calls (and, against a
        // subscription-metered provider, a self-inflicted 429).
        if (_submitNeverLeftThePhone(e)) rethrow;
        throw PromptSubmitUnconfirmed(
          '$e',
          effectiveSessionId: effectiveStored,
        );
      }
      // Submit accepted — still waiting on stream unless already completed.
      if (!turnDone.isCompleted && assistantText.isEmpty) {
        onToolStatus?.call(L10n.current.thinking);
      }

      // Wait for turn completion (agent may run tools for a long time).
      // [interruptSession] completes this early when the user hits Stop.
      await turnDone.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () {
          debugPrint('SessionSync: turn wait timed out; keeping stream so far');
        },
      );

      // Persist user (+ assistant if we got any text) before possibly throwing
      // so the UI can show "API call failed after N retries: …" like Desktop.
      final assistantId = _uuid.v4();
      await _db.upsertMessage(
        _messageToCompanion(
          HermesMessage(
            id: userId,
            sessionId: effectiveStored,
            role: 'user',
            content: input,
            timestamp: userMsg.timestamp,
          ),
          sortIndex: sortIndex,
          syncStatus: 'synced',
        ),
      );
      final completionErr = completionErrorText(assistantText);
      final failed =
          !interrupted && (turnError != null || completionErr != null);
      final errorText = formatTurnErrorForUser(
        completionErr ?? turnError ?? assistantText,
      );
      if (failed && assistantText.trim().isEmpty) {
        assistantText = errorText;
      }
      if (assistantText.isNotEmpty) {
        await _db.upsertMessage(
          _messageToCompanion(
            HermesMessage(
              id: assistantId,
              sessionId: effectiveStored,
              role: 'assistant',
              content: assistantText,
              timestamp: DateTime.now().toUtc().toIso8601String(),
              finishReason: failed ? 'error' : null,
            ),
            sortIndex: sortIndex + 1,
            syncStatus: 'synced',
          ),
        );
      }

      // Authoritative transcript from dashboard once the DB row exists.
      List<HermesMessage> msgs;
      try {
        msgs = await syncMessages(effectiveStored);
        if (msgs.isEmpty && assistantText.isNotEmpty) {
          msgs = await loadMessagesLocal(effectiveStored);
        }
      } catch (_) {
        msgs = await loadMessagesLocal(effectiveStored);
      }
      if (failed) {
        msgs = ensureErrorAssistantMessage(
          msgs,
          sessionId: effectiveStored,
          errorText: errorText,
        );
      }

      // Notify if we still have a watch (WS path may have already notified).
      await _notifyTurnCompleteIfNeeded(
        sessionIds: {sessionId, effectiveStored, liveId},
        title: sessionMeta?.displayTitle,
        assistantText: assistantText,
      );

      await _finalizeWatchAfterSend(
        sessionId: sessionId,
        resolvedId: effectiveStored,
        liveId: liveId,
        sortIndex: sortIndex,
        userId: userId,
        msgs: msgs,
        sessionMeta: sessionMeta,
      );

      if (failed && !interrupted) {
        // Prompt was delivered — do not retry; surface Desktop-style banner.
        return ChatSendResult(
          messages: msgs,
          queued: false,
          sessionId: effectiveStored,
          error: errorText,
        );
      }

      return ChatSendResult(
        messages: msgs,
        queued: false,
        sessionId: effectiveStored,
      );
    } finally {
      onApprovalRequest?.call(null);
      if (_inflightTurnDone == turnDone) {
        _inflightTurnDone = null;
        _inflightLiveId = null;
      }
      await sub.cancel();
    }
  }

  /// Resolve a gateway approval that is currently blocking a session turn.
  /// The choice list comes from [GatewayApprovalRequest], never from a
  /// hardcoded model or provider capability table.
  Future<void> respondToApproval({
    required String sessionId,
    required String choice,
  }) async {
    final rt = _realtime;
    if (rt == null || !rt.isLive) {
      throw StateError('Gateway WebSocket is not connected');
    }
    await rt.request('approval.respond', {
      'session_id': sessionId,
      'choice': choice,
    });
  }

  /// Whether [sid] is the in-flight turn or one of its aliases.
  bool isInflightSession(String sid) {
    final live = _inflightLiveId;
    if (live == null || sid.isEmpty) return false;
    if (sid == live) return true;
    final stored = _storedByLive[live];
    if (stored != null && sid == stored) return true;
    final liveFor = _liveByStored[sid];
    return liveFor == live;
  }

  Set<String> sessionIdFamily(String anyId) {
    final live = _liveByStored[anyId] ?? anyId;
    final stored = _storedByLive[anyId] ?? anyId;
    return {anyId, live, stored}.where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _notifyTurnCompleteIfNeeded({
    required Set<String> sessionIds,
    String? title,
    required String assistantText,
  }) async {
    try {
      final watches = await WatchStore().forGateway(gatewayId);
      SessionWatch? matched;
      for (final w in watches) {
        if (sessionIds.any(w.matchesSession)) {
          matched = w;
          break;
        }
      }
      // Always notify when backgrounded; when foregrounded only if still watched
      // (user left the chat) or if this was an inflight turn they started.
      final bg = AppLifecycle.isBackground;
      if (matched == null && !bg) return;

      final preview = assistantText.trim();
      final body = preview.isEmpty
          ? 'Agent finished a turn'
          : (preview.length > 160 ? '${preview.substring(0, 160)}…' : preview);
      final sid =
          matched?.sessionId ??
          sessionIds.firstWhere((s) => s.isNotEmpty, orElse: () => 'session');
      await ResultNotifier.instance.showSessionResult(
        sessionId: sid,
        title: (matched?.title ?? title)?.trim().isNotEmpty == true
            ? (matched?.title ?? title)!.trim()
            : 'Hermes ready',
        body: body,
      );
    } catch (e) {
      debugPrint('SessionSync: turn notify failed: $e');
    }
  }

  Future<void> _finalizeWatchAfterSend({
    required String sessionId,
    required String resolvedId,
    required String liveId,
    required int sortIndex,
    required String userId,
    required List<HermesMessage> msgs,
    HermesSession? sessionMeta,
  }) async {
    try {
      final hasAssistant =
          msgs.length > sortIndex + 1 &&
          msgs.skip(sortIndex + 1).any((m) => m.isAssistant);
      final family = {sessionId, resolvedId, liveId};
      if (hasAssistant || msgs.any((m) => m.isAssistant && m.id != userId)) {
        await WatchStore().unwatchAllMatching(gatewayId, family);
      } else {
        await WatchStore().watch(
          gatewayId: gatewayId,
          sessionId: resolvedId.isNotEmpty ? resolvedId : sessionId,
          baselineMessageCount: sortIndex + 1,
          baselineLastMessageId: userId,
          title: sessionMeta?.displayTitle,
          aliases: family,
        );
        unawaited(BackgroundSync.scheduleSoon());
      }
    } catch (e) {
      debugPrint('SessionSync: watch update failed: $e');
    }
  }

  Future<String> _resolveSessionId(String sessionId) async {
    // After create flush, local id is deleted and server id inserted; mapping
    // stored in kv-like: we rewrite message session ids in flushOutbox.
    final sessions = await _db.sessionsForGateway(gatewayId);
    if (sessions.any((s) => s.id == sessionId)) return sessionId;
    return sessionId;
  }

  // ── Outbox flush ───────────────────────────────────────────────────

  /// How many times one outbox op may fail before the client stops replaying
  /// it and surfaces the failure instead.
  ///
  /// Both flush paths only run against a reachable gateway
  /// ([flushPendingOverWs] gates on a live socket, [flushOutbox] on a bound
  /// `HermesApi`), so attempts accrue only while the phone *can* talk to the
  /// gateway — this counts "the gateway keeps refusing this", never "the user
  /// was offline for a week". Without a ceiling, `AppDatabase.bumpOpFailure`
  /// rescheduled a doomed op every ~40s forever behind a permanent
  /// "will send when WebSocket reconnects" banner, and nothing ever told the
  /// user their message was never delivered.
  static const maxOutboxAttempts = 8;

  Future<void> flushOutbox() async {
    final api = _api;
    if (api == null || _flushing) return;
    _flushing = true;
    try {
      final ops = await _db.pendingOpsForGateway(gatewayId);
      final now = DateTime.now().toUtc();
      for (final op in ops) {
        if (op.nextAttemptAt != null && op.nextAttemptAt!.isAfter(now)) {
          continue;
        }
        final claimed = await _db.claimPendingOp(op.id);
        if (claimed == null) continue;
        try {
          await _runOp(api, claimed);
          await _db.removeOp(claimed.id);
          _notifyOutboxOpResolved(claimed);
        } catch (e) {
          if (await _abandonHopelessOp(claimed, e)) continue;
          await _db.bumpOpFailure(claimed.id, '$e');
          debugPrint('SessionSync: op ${claimed.opType} failed: $e');
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Whether a `create_session` op is still queued for [localSessionId].
  Future<bool> _hasQueuedCreateFor(String localSessionId) async {
    final ops = await _db.pendingOpsForGateway(gatewayId);
    return ops.any(
      (o) =>
          o.opType == 'create_session' &&
          (o.sessionId == localSessionId ||
              o.payloadJson.contains(localSessionId)),
    );
  }

  /// Stop replaying a queued op the gateway can never accept, loudly.
  ///
  /// Two give-up conditions, both meaning "retrying cannot help":
  /// - the gateway is live and explicitly, permanently rejecting this exact
  ///   request ([_isTerminalGatewayRejection] / [_isSessionNotFound]);
  /// - the op has burned [maxOutboxAttempts] against a reachable gateway.
  ///
  /// The op is dropped and a durable terminal-error bubble is written into the
  /// session so the user learns the message was not delivered. Silently
  /// retrying forever is the failure this replaces — the user's own message
  /// row stays in the transcript, so their text is never discarded, only the
  /// false promise that it is still on its way.
  ///
  /// Returns true when the op was abandoned (caller must not also bump it).
  Future<bool> _abandonHopelessOp(PendingOp op, Object error) async {
    final terminal =
        _isTerminalGatewayRejection(error) ||
        _isSessionNotFound(error) ||
        _isRateLimited(error);
    final attempts = op.attemptCount + 1;
    if (!terminal && attempts < maxOutboxAttempts) return false;

    await _db.removeOp(op.id);
    final detail = formatTurnErrorForUser('$error');
    final reason = terminal
        ? detail
        : 'Not delivered after $attempts attempts: $detail';
    final sid = op.sessionId;
    if (sid != null && sid.isNotEmpty) {
      try {
        await _persistTerminalError(sid, reason);
      } catch (e) {
        debugPrint('SessionSync: could not persist abandoned-op error: $e');
      }
    }
    _notifyOutboxOpResolved(op);
    debugPrint(
      'SessionSync: gave up on outbox op ${op.opType} (${op.id}): $reason',
    );
    return true;
  }

  /// A queued op just resolved (sent successfully, or dropped after reaching
  /// the gateway) — wake any listening UI so a stuck "No reply yet" /
  /// "Queued for sync…" state actually clears instead of sitting there until
  /// the user happens to trigger another send. Mirrors the notification the
  /// live WS path already fires on every push event; the outbox path had no
  /// equivalent, which is why a resolved background/foreground flush never
  /// reached the open chat screen.
  void _notifyOutboxOpResolved(PendingOp op) {
    final sid = op.sessionId;
    final rt = _realtime;
    if (rt == null || sid == null || sid.isEmpty) return;
    unawaited(rt.refreshCaches(sessionId: sid, reason: 'outbox_flush'));
  }

  /// Flush pending create/chat ops over live WS (password-auth path has no API key).
  Future<void> flushPendingOverWs() async {
    if (_flushing) return;
    // Claim the flag BEFORE any await: an await between check and set lets a
    // concurrent flushOutbox/flushPendingOverWs pass the guard and submit the
    // same queued chat op twice.
    _flushing = true;
    try {
      if (!await _ensureWsLive()) return;
      final ops = await _db.pendingOpsForGateway(gatewayId);
      final now = DateTime.now().toUtc();
      for (final op in ops) {
        if (op.nextAttemptAt != null && op.nextAttemptAt!.isAfter(now)) {
          continue;
        }
        final claimed = await _db.claimPendingOp(op.id);
        if (claimed == null) continue;
        try {
          await _runOpOverWs(claimed);
          await _db.removeOp(claimed.id);
          _notifyOutboxOpResolved(claimed);
        } on TurnFailedAfterSubmit catch (e) {
          // Prompt reached the gateway — drop the op instead of retrying it
          // into a duplicate turn; the transcript pull reflects the failure.
          await _db.removeOp(claimed.id);
          _notifyOutboxOpResolved(claimed);
          debugPrint('SessionSync: WS op ${claimed.opType} ran but failed: $e');
        } on PromptSubmitUnconfirmed catch (e) {
          // The frame left the phone; the gateway may be running it. Replaying
          // this op on the next flush is exactly how a queued message becomes
          // two upstream provider calls. Drop it — a later transcript pull is
          // the authority on whether the turn landed.
          await _db.removeOp(claimed.id);
          _notifyOutboxOpResolved(claimed);
          debugPrint(
            'SessionSync: WS op ${claimed.opType} delivery unconfirmed: $e',
          );
        } catch (e) {
          if (await _abandonHopelessOp(claimed, e)) continue;
          await _db.bumpOpFailure(claimed.id, '$e');
          debugPrint('SessionSync: WS op ${claimed.opType} failed: $e');
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _runOpOverWs(PendingOp op) async {
    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    switch (op.opType) {
      case 'create_session':
        final localId = '${payload['local_id']}';
        final created = await _createSessionOnGateway(
          title: payload['title'] as String?,
          model: payload['model'] as String?,
          provider: payload['provider'] as String?,
          fastMode: payload['fast'] == true,
        );
        await _remapSessionId(localId, created);
        break;
      case 'chat':
        var sid = '${payload['session_id']}';
        final input = '${payload['input']}';
        final model = payload['model'] as String?;
        final provider = payload['provider'] as String?;
        if (sid.startsWith('local_')) {
          if (await _hasQueuedCreateFor(sid)) {
            // A create op is queued ahead of us and hasn't landed yet — ops
            // run in createdAt order, so retry after it does.
            throw StateError('chat still bound to local session $sid');
          }
          // No create op exists and none ever will: [createSession] only
          // enqueues `create_session` when a legacy `HermesApi` is bound, and
          // the shipped cookie/session auth mode never has one. The draft was
          // therefore stranded — this op threw the same StateError on every
          // reconnect, forever, while the composer promised "will send when
          // WebSocket reconnects". Promote the draft here instead:
          // `_ensureLiveSessionId` does `session.create` + `_remapSessionId`
          // for a `local_*` id, which also rewrites this op's own payload.
          final live = await _ensureLiveSessionId(
            sid,
            model: model,
            provider: provider,
          );
          final promoted = _storedByLive[live] ?? live;
          debugPrint(
            'SessionSync: promoted stranded offline draft $sid → $promoted',
          );
          sid = promoted;
        }
        final userMsgId = payload['local_user_message_id'] as String?;
        // Replay at the queued user row's real position — a hardcoded 0
        // collides with existing rows 0/1 and scrambles the transcript until
        // (unless) a later server pull heals it.
        final existingRows = await _db.messagesForSession(gatewayId, sid);
        final queuedRow = userMsgId == null
            ? null
            : existingRows.where((m) => m.id == userMsgId).firstOrNull;
        final replaySortIndex = queuedRow?.sortIndex ?? existingRows.length;
        final replayId = userMsgId ?? _uuid.v4();
        await _sendViaGateway(
          sessionId: sid,
          input: input,
          model: model,
          provider: provider,
          userId: replayId,
          userMsg: HermesMessage(
            id: replayId,
            sessionId: sid,
            role: 'user',
            content: input,
            timestamp:
                queuedRow?.timestamp ??
                DateTime.now().toUtc().toIso8601String(),
          ),
          sortIndex: replaySortIndex,
        );
        break;
      case 'delete_session':
        final sid = '${payload['session_id']}';
        try {
          await _realtime!.request('session.close', {'session_id': sid});
        } catch (_) {}
        final dash = _dashboard;
        if (dash != null) {
          try {
            await dash.deleteSession(sid);
          } catch (_) {}
        }
        await _db.removeSession(gatewayId, sid);
        break;
      default:
        // Fall back to API path if present.
        final api = _api;
        if (api != null) {
          await _runOp(api, op);
          return;
        }
        throw StateError('unknown op ${op.opType} without API');
    }
  }

  Future<void> _runOp(HermesApi api, PendingOp op) async {
    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    switch (op.opType) {
      case 'create_session':
        final localId = '${payload['local_id']}';
        final created = await api.createSession(
          title: payload['title'] as String?,
          model: payload['model'] as String?,
        );
        // Rewrite local id → server id for session + messages.
        await _remapSessionId(localId, created);
        break;
      case 'delete_session':
        final sid = '${payload['session_id']}';
        try {
          await api.deleteSession(sid);
        } catch (_) {
          // 404 = already gone — treat as success
        }
        await _db.removeSession(gatewayId, sid);
        break;
      case 'patch_session':
        final sid = '${payload['session_id']}';
        await api.patchSession(
          sid,
          title: payload['title'] as String?,
          endReason: payload['end_reason'] as String?,
        );
        break;
      case 'chat':
        var sid = '${payload['session_id']}';
        if (sid.startsWith('local_')) {
          // Ensure create flushed first (ops are ordered by createdAt).
          throw StateError('chat still bound to local session $sid');
        }
        final input = '${payload['input']}';
        final model = payload['model'] as String?;
        await api.chat(sid, input: input, model: model);
        final userMsgId = payload['local_user_message_id'] as String?;
        if (userMsgId != null) {
          final msgs = await _db.messagesForSession(gatewayId, sid);
          final row = msgs.where((m) => m.id == userMsgId).firstOrNull;
          if (row != null) {
            await _db.upsertMessage(
              CachedMessagesCompanion(
                gatewayId: Value(row.gatewayId),
                sessionId: Value(row.sessionId),
                id: Value(row.id),
                role: Value(row.role),
                content: Value(row.content),
                toolCallId: Value(row.toolCallId),
                toolName: Value(row.toolName),
                timestamp: Value(row.timestamp),
                tokenCount: Value(row.tokenCount),
                finishReason: Value(row.finishReason),
                reasoning: Value(row.reasoning),
                toolCallsJson: Value(row.toolCallsJson),
                sortIndex: Value(row.sortIndex),
                syncStatus: const Value('synced'),
              ),
            );
          }
        }
        // Pull authoritative transcript.
        final remote = await api.listMessages(sid);
        await _db.replaceMessages(gatewayId, sid, [
          for (var i = 0; i < remote.length; i++)
            _messageToCompanion(remote[i], sortIndex: i, syncStatus: 'synced'),
        ]);
        break;
      default:
        throw StateError('unknown op ${op.opType}');
    }
  }

  Future<void> _remapSessionId(String localId, HermesSession server) async {
    final now = DateTime.now().toUtc();
    await _db.upsertSession(_sessionToCompanion(server, syncStatus: 'synced'));
    final msgs = await _db.messagesForSession(gatewayId, localId);
    for (final m in msgs) {
      await _db.upsertMessage(
        CachedMessagesCompanion.insert(
          gatewayId: gatewayId,
          sessionId: server.id,
          id: m.id,
          role: m.role,
          content: Value(m.content),
          toolCallId: Value(m.toolCallId),
          toolName: Value(m.toolName),
          timestamp: Value(m.timestamp),
          tokenCount: Value(m.tokenCount),
          finishReason: Value(m.finishReason),
          reasoning: Value(m.reasoning),
          toolCallsJson: Value(m.toolCallsJson),
          sortIndex: Value(m.sortIndex),
          syncStatus: Value(m.syncStatus),
        ),
      );
    }
    await _db.removeSession(gatewayId, localId);

    // Rewrite pending chat ops that still point at local id.
    final ops = await _db.pendingOpsForGateway(gatewayId);
    for (final op in ops) {
      if (op.sessionId != localId && !op.payloadJson.contains(localId)) {
        continue;
      }
      final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
      if (payload['session_id'] == localId) {
        payload['session_id'] = server.id;
      }
      if (payload['local_id'] == localId) {
        payload['local_id'] = server.id;
      }
      await _db.enqueueOp(
        PendingOpsCompanion(
          id: Value(op.id),
          gatewayId: Value(op.gatewayId),
          opType: Value(op.opType),
          sessionId: Value(server.id),
          payloadJson: Value(jsonEncode(payload)),
          attemptCount: Value(op.attemptCount),
          lastError: Value(op.lastError),
          createdAt: Value(op.createdAt),
          nextAttemptAt: Value(op.nextAttemptAt),
        ),
      );
    }

    // Keep linter happy if now unused in edge paths.
    assert(now.isUtc);
  }

  Future<void> _touchSessionPreview(
    String sessionId,
    String preview, {
    int? messageCount,
  }) async {
    final sessions = await _db.sessionsForGateway(gatewayId);
    final existing = sessions.where((s) => s.id == sessionId).firstOrNull;
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.upsertSession(
      CachedSessionsCompanion(
        gatewayId: Value(gatewayId),
        id: Value(sessionId),
        source: Value(existing?.source),
        userId: Value(existing?.userId),
        model: Value(existing?.model),
        title: Value(existing?.title),
        startedAt: Value(existing?.startedAt ?? now),
        endedAt: Value(existing?.endedAt),
        endReason: Value(existing?.endReason),
        messageCount: Value(messageCount ?? existing?.messageCount),
        toolCallCount: Value(existing?.toolCallCount),
        lastActive: Value(now),
        preview: Value(
          preview.length > 120 ? '${preview.substring(0, 120)}…' : preview,
        ),
        parentSessionId: Value(existing?.parentSessionId),
        syncStatus: Value(existing?.syncStatus ?? 'pending'),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  // ── Mapping ────────────────────────────────────────────────────────

  HermesSession _sessionFromRow(CachedSession r) {
    return HermesSession(
      id: r.id,
      source: r.source,
      userId: r.userId,
      model: r.model,
      title: r.title,
      startedAt: r.startedAt,
      endedAt: r.endedAt,
      endReason: r.endReason,
      messageCount: r.messageCount,
      toolCallCount: r.toolCallCount,
      lastActive: r.lastActive,
      preview: r.preview,
      parentSessionId: r.parentSessionId,
    );
  }

  HermesMessage _messageFromRow(CachedMessage r) {
    return HermesMessage(
      id: r.id,
      sessionId: r.sessionId,
      role: r.role,
      content: r.content,
      toolCallId: r.toolCallId,
      toolName: r.toolName,
      timestamp: r.timestamp,
      tokenCount: r.tokenCount,
      finishReason: r.finishReason,
      reasoning: r.reasoning,
      toolCalls: r.toolCallsJson == null ? null : jsonDecode(r.toolCallsJson!),
      displayKind: r.displayKind,
    );
  }

  CachedSessionsCompanion _sessionToCompanion(
    HermesSession s, {
    required String syncStatus,
  }) {
    return CachedSessionsCompanion.insert(
      gatewayId: gatewayId,
      id: s.id,
      source: Value(s.source),
      userId: Value(s.userId),
      model: Value(s.model),
      title: Value(s.title),
      startedAt: Value(s.startedAt),
      endedAt: Value(s.endedAt),
      endReason: Value(s.endReason),
      messageCount: Value(s.messageCount),
      toolCallCount: Value(s.toolCallCount),
      lastActive: Value(s.lastActive),
      preview: Value(s.preview),
      parentSessionId: Value(s.parentSessionId),
      syncStatus: Value(syncStatus),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  CachedMessagesCompanion _messageToCompanion(
    HermesMessage m, {
    required int sortIndex,
    required String syncStatus,
  }) {
    String? toolCallsJson;
    if (m.toolCalls != null) {
      try {
        toolCallsJson = jsonEncode(m.toolCalls);
      } catch (_) {
        toolCallsJson = '${m.toolCalls}';
      }
    }
    return CachedMessagesCompanion.insert(
      gatewayId: gatewayId,
      sessionId: m.sessionId,
      id: m.id,
      role: m.role,
      content: Value(m.content),
      toolCallId: Value(m.toolCallId),
      toolName: Value(m.toolName),
      timestamp: Value(m.timestamp),
      tokenCount: Value(m.tokenCount),
      finishReason: Value(m.finishReason),
      reasoning: Value(m.reasoning),
      toolCallsJson: Value(toolCallsJson),
      sortIndex: Value(sortIndex),
      syncStatus: Value(syncStatus),
      displayKind: Value(m.displayKind),
    );
  }

  String? _extractChatOutput(Map<String, dynamic> res) {
    final direct = res['output'] ?? res['content'] ?? res['message'];
    if (direct is String && direct.isNotEmpty) return direct;
    // API_SERVER sync chat: {"object": "hermes.session.chat.completion",
    //  "message": {"role": "assistant", "content": ...}} — dig the Map form.
    if (direct is Map) {
      final content = direct['content'];
      if (content is String && content.isNotEmpty) return content;
      if (content is List) {
        // Content-parts array: join the text parts.
        final text = content
            .whereType<Map>()
            .map((p) => '${p['text'] ?? ''}')
            .where((t) => t.isNotEmpty)
            .join();
        if (text.isNotEmpty) return text;
      }
    }
    if (direct != null && direct is! Map && direct is! List) return '$direct';
    final choices = res['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map && message['content'] != null) {
          return '${message['content']}';
        }
      }
    }
    return null;
  }
}

class BotCapabilityOption {
  const BotCapabilityOption({
    required this.name,
    required this.enabled,
    this.label = '',
    this.description = '',
    this.detail = '',
  });

  final String name;
  final bool enabled;
  final String label;
  final String description;
  final String detail;

  BotCapabilityOption copyWith({bool? enabled}) => BotCapabilityOption(
    name: name,
    enabled: enabled ?? this.enabled,
    label: label,
    description: description,
    detail: detail,
  );
}

class BotProfileConfiguration {
  const BotProfileConfiguration({
    required this.soul,
    required this.model,
    required this.provider,
    required this.skills,
    required this.toolsets,
    required this.mcpServers,
  });

  factory BotProfileConfiguration.fromJson(Map<String, dynamic> json) {
    List<BotCapabilityOption> options(Object? raw, {bool mcp = false}) =>
        raw is! List
        ? const []
        : raw
              .whereType<Map>()
              .map((item) {
                final name = '${item['name'] ?? ''}'.trim();
                return BotCapabilityOption(
                  name: name,
                  enabled: item['enabled'] == true,
                  label: '${item['label'] ?? ''}'.trim(),
                  description: '${item['description'] ?? ''}'.trim(),
                  detail: mcp
                      ? '${item['transport'] ?? ''}'.trim()
                      : item['tool_count'] == null
                      ? ''
                      : '${item['tool_count']} tools',
                );
              })
              .where((item) => item.name.isNotEmpty)
              .toList(growable: false);

    final model = json['model'];
    final modelMap = model is Map ? model : const {};
    return BotProfileConfiguration(
      soul: '${json['soul'] ?? ''}',
      model: '${modelMap['default'] ?? ''}'.trim(),
      provider: '${modelMap['provider'] ?? ''}'.trim(),
      skills: options(json['skills']),
      toolsets: options(json['toolsets']),
      mcpServers: options(json['mcp_servers'], mcp: true),
    );
  }

  final String soul;
  final String model;
  final String provider;
  final List<BotCapabilityOption> skills;
  final List<BotCapabilityOption> toolsets;
  final List<BotCapabilityOption> mcpServers;
}

class ChatSendResult {
  const ChatSendResult({
    required this.messages,
    required this.queued,
    this.sessionId,
    this.error,
  });

  final List<HermesMessage> messages;
  final bool queued;
  final String? sessionId;
  final String? error;
}

/// Thrown when a `prompt.submit` frame reached the socket but the gateway
/// never answered — the connection dropped, or the ack timed out.
///
/// Delivery is genuinely UNKNOWN here: the turn may be running upstream right
/// now, or the frame may have died in the network. Callers must therefore
/// treat it exactly like [TurnFailedAfterSubmit] for resend purposes (never
/// resend, never re-enqueue) but must NOT report it as a failed turn — resync
/// the transcript and only surface a banner when the server still has no
/// reply. Resending is what turns one tap into two upstream provider calls.
class PromptSubmitUnconfirmed implements Exception {
  PromptSubmitUnconfirmed(this.message, {this.effectiveSessionId});

  final String message;
  final String? effectiveSessionId;

  @override
  String toString() => 'PromptSubmitUnconfirmed: $message';
}

/// Thrown when `prompt.submit` was accepted but the agent turn failed.
/// Callers must NOT retry or re-enqueue the same prompt (side effects already ran).
class TurnFailedAfterSubmit implements Exception {
  TurnFailedAfterSubmit(this.message, {this.effectiveSessionId});

  final String message;
  final String? effectiveSessionId;

  @override
  String toString() => 'TurnFailedAfterSubmit: $message';
}
