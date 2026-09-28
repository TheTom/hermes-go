import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hermes_mobile/core/config/reasoning_effort.dart';
import 'package:hermes_mobile/core/db/app_database.dart';
import 'package:hermes_mobile/core/demo/demo_mode.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/connection_store.dart';
import 'package:hermes_mobile/core/network/dashboard_client.dart'
    show
        DashboardAuthException,
        DashboardClient,
        ModelOptionProvider,
        ModelOptionsResult;
import 'package:hermes_mobile/core/network/gateway_auth.dart';
import 'package:hermes_mobile/core/network/hermes_api.dart';
import 'package:hermes_mobile/core/services/feedback.dart';
import 'package:hermes_mobile/core/services/job_notifier.dart';
import 'package:hermes_mobile/core/sync/gateway_realtime.dart';
import 'package:hermes_mobile/core/sync/session_sync_repository.dart';
import 'package:hermes_mobile/core/sync/single_flight.dart';
import 'package:hermes_mobile/core/theme/hermes_skins.dart';

final connectionStoreProvider = Provider<ConnectionStore>((ref) {
  return ConnectionStore();
});

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Full multi-gateway book (list + default + active).
final gatewayBookProvider =
    AsyncNotifierProvider<GatewayBookNotifier, GatewayBook>(
      GatewayBookNotifier.new,
    );

class GatewayBookNotifier extends AsyncNotifier<GatewayBook> {
  @override
  Future<GatewayBook> build() async {
    final elapsed = Stopwatch()..start();
    final book = await ref.read(connectionStoreProvider).readBook();
    debugPrint(
      'Startup: gateway profile ready in ${elapsed.elapsedMilliseconds}ms',
    );
    // The demo gateway binds a fresh ephemeral port every process launch, so
    // a previously-saved demo profile's baseUrl is dead by the time the app
    // reopens. Boot the sandbox and rewrite the stored URL *before* this
    // provider resolves — every client (dashboard/WS/session-sync) is built
    // off `connectionProfileProvider`, which only sees this book once build()
    // returns, so nothing gets constructed against the stale port.
    return _rehydrateDemoInBook(book);
  }

  Future<void> reload() async {
    state = AsyncData(await ref.read(connectionStoreProvider).readBook());
  }

  /// Boots the demo sandbox (if needed) and rewrites the resolved demo
  /// profile's `baseUrl` in place. No-op for a non-demo active profile, or a
  /// demo profile whose stored URL is already current.
  ///
  /// Public so app-resume (iOS may reclaim the loopback socket while
  /// backgrounded) can re-run the same fixup — see
  /// `_RootGateState.didChangeAppLifecycleState` in `app.dart`.
  Future<void> rehydrateDemoIfNeeded() async {
    final current = state.value;
    if (current == null) return;
    final next = await _rehydrateDemoInBook(current);
    if (!identical(next, current)) {
      state = AsyncData(next);
    }
  }

  Future<GatewayBook> _rehydrateDemoInBook(GatewayBook book) async {
    final resolved = book.resolved;
    if (resolved == null || !isDemoProfileId(resolved.id)) return book;
    try {
      final uri = await DemoGatewayHolder.instance.ensureRunning();
      final freshBaseUrl = uri.toString();
      if (resolved.baseUrl == freshBaseUrl) return book;
      return await ref
          .read(connectionStoreProvider)
          .upsertGateway(resolved.copyWith(baseUrl: freshBaseUrl));
    } catch (e) {
      debugPrint('GatewayBookNotifier: demo rehydrate failed: $e');
      return book;
    }
  }

  Future<void> saveAsPrimary(ConnectionProfile profile) async {
    final book = await ref.read(connectionStoreProvider).saveAsPrimary(profile);
    state = AsyncData(book);
  }

  Future<void> upsert(ConnectionProfile profile) async {
    final book = await ref.read(connectionStoreProvider).upsertGateway(profile);
    state = AsyncData(book);
  }

  Future<void> setActive(String gatewayId) async {
    final book = await ref.read(connectionStoreProvider).setActive(gatewayId);
    state = AsyncData(book);
  }

  Future<void> setDefault(String gatewayId) async {
    final book = await ref.read(connectionStoreProvider).setDefault(gatewayId);
    state = AsyncData(book);
  }

  Future<void> remove(String gatewayId) async {
    try {
      final jar = await GatewayAuthClient.persistentJar(gatewayId);
      await jar.deleteAll();
    } catch (e) {
      debugPrint('remove gateway: clear cookies failed: $e');
    }
    final book = await ref
        .read(connectionStoreProvider)
        .removeGateway(gatewayId);
    state = AsyncData(book);
  }

  Future<void> disconnectAll() async {
    await ref.read(connectionStoreProvider).disconnectAll();
    state = const AsyncData(GatewayBook.empty);
  }
}

final connectionProfileProvider = Provider<AsyncValue<ConnectionProfile?>>((
  ref,
) {
  final book = ref.watch(gatewayBookProvider);
  return book.when(
    data: (b) => AsyncData(b.resolved),
    loading: () => const AsyncLoading(),
    error: (e, st) => AsyncError(e, st),
  );
});

final connectionActionsProvider = Provider<ConnectionActions>((ref) {
  return ConnectionActions(ref);
});

class ConnectionActions {
  ConnectionActions(this._ref);
  final Ref _ref;

  Future<void> save(ConnectionProfile profile) =>
      _ref.read(gatewayBookProvider.notifier).saveAsPrimary(profile);

  Future<void> disconnect() async {
    final book = _ref.read(gatewayBookProvider).value;
    for (final profile in book?.gateways ?? const <ConnectionProfile>[]) {
      try {
        final jar = await GatewayAuthClient.persistentJar(profile.id);
        await jar.deleteAll();
      } catch (e) {
        debugPrint('disconnect: clear cookies failed: $e');
      }
    }
    try {
      await _ref.read(gatewayRealtimeProvider)?.stop();
    } catch (_) {}
    await _ref.read(gatewayBookProvider.notifier).disconnectAll();
  }

  /// Session expired / kicked — wipe cookies + stored password, force login UI.
  ///
  /// Intentionally does **not** silent-relogin: expiry may be purposeful
  /// (admin kick). User must re-enter credentials.
  Future<void> forceReauth({String? message}) async {
    final profile = _ref.read(connectionProfileProvider).value;
    if (profile != null) {
      try {
        final jar = await GatewayAuthClient.persistentJar(profile.id);
        await jar.deleteAll();
      } catch (e) {
        debugPrint('forceReauth: clear cookies failed: $e');
      }
      try {
        await _ref.read(connectionStoreProvider).clearPassword(profile.id);
      } catch (e) {
        debugPrint('forceReauth: clear password failed: $e');
      }
      try {
        await _ref.read(gatewayRealtimeProvider)?.stop();
      } catch (_) {}
    }
    _ref
        .read(needsReauthProvider.notifier)
        .require(
          message: message ?? 'Session expired. Sign in again to continue.',
        );
  }

  void clearReauth() => _ref.read(needsReauthProvider.notifier).clear();
}

/// When true, root shows [ConnectScreen] even if a gateway profile is saved.
final needsReauthProvider =
    NotifierProvider<NeedsReauthNotifier, NeedsReauthState>(
      NeedsReauthNotifier.new,
    );

class NeedsReauthState {
  const NeedsReauthState({this.required = false, this.message});

  final bool required;
  final String? message;
}

class NeedsReauthNotifier extends Notifier<NeedsReauthState> {
  @override
  NeedsReauthState build() => const NeedsReauthState();

  void require({String? message}) {
    state = NeedsReauthState(required: true, message: message);
  }

  void clear() {
    state = const NeedsReauthState();
  }
}

/// Detect REST/WS auth death and kick the user to interactive login.
Future<void> _maybeForceReauth(Ref ref, Object e) async {
  final msg = e.toString();
  final auth =
      e is DashboardAuthException ||
      e is GatewayAuthException ||
      msg.contains('Session expired') ||
      msg.contains('sign in again') ||
      msg.contains('HTTP 401') ||
      msg.contains('HTTP 403');
  if (!auth) return;
  if (ref.read(needsReauthProvider).required) return;
  await ref
      .read(connectionActionsProvider)
      .forceReauth(
        message: e is DashboardAuthException
            ? e.message
            : (e is GatewayAuthException
                  ? e.message
                  : 'Session expired. Sign in again to continue.'),
      );
}

/// Holds one [DashboardClient] per gateway so Dio/cookie setup is stable.
class _DashboardClientHolder {
  DashboardClient? client;
  String? gatewayId;
  String? baseUrl;
}

final _dashboardClientHolderProvider = Provider<_DashboardClientHolder>((ref) {
  return _DashboardClientHolder();
});

/// Cookie-auth dashboard client (Desktop HTTP surface).
///
/// Stable per gateway id + baseUrl. A fresh [DashboardClient] on every
/// [connectionProfileProvider] tick was thrashing [sessionSyncProvider] and
/// causing Riverpod `invalidateSelf` → `setState` during [SessionsScreen] build.
final dashboardClientProvider = Provider<DashboardClient?>((ref) {
  // Rebuild only when identity/URL changes — not on every book object rewrite.
  final key = ref.watch(
    connectionProfileProvider.select((av) {
      final p = av.value;
      if (p == null) return null;
      return '${p.id}\u0000${p.baseUrl}';
    }),
  );
  if (key == null) return null;
  final profile = ref.read(connectionProfileProvider).value;
  if (profile == null) return null;

  final holder = ref.watch(_dashboardClientHolderProvider);
  if (holder.client == null ||
      holder.gatewayId != profile.id ||
      holder.baseUrl != profile.baseUrl) {
    holder.client = DashboardClient(profile: profile);
    holder.gatewayId = profile.id;
    holder.baseUrl = profile.baseUrl;
  }
  return holder.client;
});

final hermesApiProvider = Provider<HermesApi?>((ref) {
  final key = ref.watch(
    connectionProfileProvider.select((av) {
      final p = av.value;
      if (p == null) return null;
      return '${p.id}\u0000${p.baseUrl}\u0000${p.apiKey}';
    }),
  );
  if (key == null) return null;
  final profile = ref.read(connectionProfileProvider).value;
  if (profile == null) return null;
  // Legacy API-server bearer only when a static key is stored.
  if (!profile.hasLegacyToken) return null;
  return HermesApi(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
});

/// Holds one [SessionSyncRepository] per gateway so live session id maps
/// survive Riverpod rebuilds (recreating the repo was dropping WS bindings).
class _SessionSyncHolder {
  SessionSyncRepository? repo;
  String? gatewayId;
}

final _sessionSyncHolderProvider = Provider<_SessionSyncHolder>((ref) {
  return _SessionSyncHolder();
});

/// Local-first session sync for the active gateway (null if not connected).
///
/// Only [ref.watch]es the gateway id. Dashboard / API / realtime clients are
/// rebound via [ref.listen] so their identity churn does not rebuild this
/// provider (and cascade-invalidate [sessionsProvider] mid-widget-build).
final sessionSyncProvider = Provider<SessionSyncRepository?>((ref) {
  final gatewayId = ref.watch(
    connectionProfileProvider.select((av) => av.value?.id),
  );
  if (gatewayId == null) return null;
  final profile = ref.read(connectionProfileProvider).value;
  if (profile == null) return null;

  final db = ref.watch(appDatabaseProvider);
  final holder = ref.watch(_sessionSyncHolderProvider);

  if (holder.repo == null || holder.gatewayId != profile.id) {
    holder.repo = SessionSyncRepository(
      gatewayId: profile.id,
      db: db,
      dashboard: ref.read(dashboardClientProvider),
      api: ref.read(hermesApiProvider),
    );
    holder.gatewayId = profile.id;
  }
  final repo = holder.repo!;

  void rebindClients() {
    repo.bindDashboard(ref.read(dashboardClientProvider));
    repo.bindApi(ref.read(hermesApiProvider));
    final rt = ref.read(gatewayRealtimeProvider);
    repo.bindRealtime(rt);
    rt?.bindSessionSync(repo);
    rt?.bindKeepIds(
      () => ref.read(pinnedSessionsProvider).value ?? const <String>[],
    );
  }

  rebindClients();
  ref.listen(dashboardClientProvider, (previous, next) => rebindClients());
  ref.listen(hermesApiProvider, (previous, next) => rebindClients());
  ref.listen(gatewayRealtimeProvider, (previous, next) => rebindClients());

  return repo;
});

/// Holds one [GatewayRealtime] so Riverpod rebuilds don't dispose the socket.
///
/// Bug we hit: `gatewayRealtimeProvider` recreated `GatewayRealtime` on every
/// `connectionProfileProvider` tick → `dispose()` mid-handshake → Settings
/// stuck on WebSocket **connecting** forever while Desktop (stable process)
/// stayed fine.
class _RealtimeHolder {
  GatewayRealtime? rt;
  String? gatewayId;
  String? baseUrl;
  String? authMode;
}

final _realtimeHolderProvider = Provider<_RealtimeHolder>((ref) {
  final holder = _RealtimeHolder();
  ref.onDispose(() {
    // ignore: discarded_futures
    holder.rt?.dispose();
  });
  return holder;
});

/// Desktop-parity live WebSocket (`/api/ws`) for the active gateway.
///
/// **Stable per gateway id** — do not recreate on every book/profile rebuild.
final gatewayRealtimeProvider = Provider<GatewayRealtime?>((ref) {
  final profile = ref.watch(connectionProfileProvider).value;
  final holder = ref.watch(_realtimeHolderProvider);

  if (profile == null) {
    final old = holder.rt;
    holder.rt = null;
    holder.gatewayId = null;
    holder.baseUrl = null;
    holder.authMode = null;
    if (old != null) {
      // ignore: discarded_futures
      old.dispose();
    }
    return null;
  }

  final needsNew =
      holder.rt == null ||
      holder.gatewayId != profile.id ||
      holder.baseUrl != profile.baseUrl ||
      holder.authMode != profile.authMode;

  if (needsNew) {
    final old = holder.rt;
    holder.rt = null;
    if (old != null) {
      // ignore: discarded_futures
      old.dispose();
    }

    final db = ref.read(appDatabaseProvider);
    // Lightweight sync stub for construction; rebinding happens in sessionSyncProvider.
    final sync = SessionSyncRepository(
      gatewayId: profile.id,
      db: db,
      dashboard: ref.read(dashboardClientProvider),
      api: ref.read(hermesApiProvider),
    );
    holder.rt = GatewayRealtime(
      profile: profile,
      sessionSync: sync,
      connectionStore: ref.read(connectionStoreProvider),
      onNeedsReauth: (msg) {
        // Defer so we don't mutate providers mid-build/connect.
        Future.microtask(() {
          unawaited(
            ref.read(connectionActionsProvider).forceReauth(message: msg),
          );
        });
      },
    );
    holder.gatewayId = profile.id;
    holder.baseUrl = profile.baseUrl;
    holder.authMode = profile.authMode;
  }

  return holder.rt;
});

/// Settings / chrome: signed-in REST vs live WebSocket (two different paths).
final gatewayLinkStatusProvider = Provider<GatewayLinkStatus>((ref) {
  final profile = ref.watch(connectionProfileProvider).value;
  final rt = ref.watch(gatewayRealtimeProvider);
  final reauth = ref.watch(needsReauthProvider);
  // Rebuild when WS state flips.
  ref.watch(gatewayRealtimeStateTickProvider);
  if (profile == null) {
    return const GatewayLinkStatus(signedIn: false, wsLive: false);
  }
  final wsLive = rt?.isLive == true;
  final ui = rt?.uiStatus;
  // Never surface stale errors while the socket is live (probe thrash used to
  // leave "reconnecting" copy visible under an otherwise working chat).
  final err = wsLive ? null : rt?.lastError?.trim();
  return GatewayLinkStatus(
    signedIn: true,
    wsLive: wsLive,
    wsError: (err != null && err.isNotEmpty) ? err : null,
    authMode: profile.authMode,
    needsReauth: reauth.required,
    reauthMessage: reauth.message,
    baseUrl: profile.baseUrl,
    username: profile.username,
    connectionState: rt?.connectionState.name,
    wsLabel: wsLive ? (ui?.label ?? 'Live') : ui?.label,
    wsPhase: wsLive ? 'live' : ui?.phase.name,
    reconnectAttempt: wsLive ? 0 : (ui?.attempt ?? 0),
    gaveUp: wsLive ? false : rt?.gaveUp == true,
  );
});

/// Lightweight REST health probe for Settings (not chat-capable alone).
final gatewayRestHealthProvider =
    AsyncNotifierProvider<GatewayRestHealthNotifier, GatewayRestHealth>(
      GatewayRestHealthNotifier.new,
    );

class GatewayRestHealth {
  const GatewayRestHealth({
    required this.ok,
    this.version,
    this.error,
    this.checkedAt,
  });

  final bool ok;
  final String? version;
  final String? error;
  final DateTime? checkedAt;
}

class GatewayRestHealthNotifier extends AsyncNotifier<GatewayRestHealth> {
  /// Coalesces redundant startup `/api/status` probes (cold provider build +
  /// Settings' `initState` silent check land within milliseconds).
  final _statusFlight = SingleFlight<GatewayRestHealth>();

  @override
  Future<GatewayRestHealth> build() => _probe();

  /// See [SessionsNotifier.refresh] for [bypassTtl] semantics.
  Future<GatewayRestHealth> _probe({bool bypassTtl = false}) {
    return _statusFlight.run(_probeImpl, bypassTtl: bypassTtl);
  }

  Future<GatewayRestHealth> _probeImpl() async {
    final dash = ref.watch(dashboardClientProvider);
    if (dash == null) {
      return const GatewayRestHealth(ok: false, error: 'No gateway configured');
    }
    try {
      final status = await dash.status();
      final version = status['version']?.toString();
      return GatewayRestHealth(
        ok: true,
        version: version,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      return GatewayRestHealth(
        ok: false,
        error: e.toString(),
        checkedAt: DateTime.now(),
      );
    }
  }

  /// See [SessionsNotifier.refresh] for [bypassTtl] semantics.
  Future<void> refresh({bool bypassTtl = false}) async {
    state = const AsyncLoading();
    state = AsyncData(await _probe(bypassTtl: bypassTtl));
  }
}

/// Tick stream so UI rebuilds when WS opens/closes.
final gatewayRealtimeStateTickProvider = StreamProvider<int>((ref) {
  final rt = ref.watch(gatewayRealtimeProvider);
  if (rt == null) return const Stream.empty();
  // Re-evaluate once after the StreamProvider has actually subscribed. A
  // broadcast `live` tick can otherwise land in the small gap between the
  // first provider build and stream attachment, leaving Settings stuck on the
  // earlier "connecting" snapshot while chat is already live.
  return (() async* {
    var tick = 0;
    yield tick++;
    await for (final _ in rt.stateChanges) {
      // `StreamProvider<void>` emitted the same null value for every state
      // change, which Riverpod correctly de-duplicated. A monotonic value makes
      // every socket transition observable by dependent providers.
      yield tick++;
    }
  })();
});

/// Combined health for Settings status card.
enum ConnectionHealthLevel {
  /// Live WebSocket — chat ready.
  live,

  /// Cookies OK / REST up, but chat socket is down.
  degraded,

  /// Session expired or kicked — needs interactive login.
  reauth,

  /// Not signed in / no profile.
  offline,

  /// Signed in but host unreachable.
  error,
}

class GatewayLinkStatus {
  const GatewayLinkStatus({
    required this.signedIn,
    required this.wsLive,
    this.wsError,
    this.authMode,
    this.needsReauth = false,
    this.reauthMessage,
    this.baseUrl,
    this.username,
    this.connectionState,
    this.wsLabel,
    this.wsPhase,
    this.reconnectAttempt = 0,
    this.gaveUp = false,
  });

  final bool signedIn;
  final bool wsLive;
  final String? wsError;
  final String? authMode;
  final bool needsReauth;
  final String? reauthMessage;
  final String? baseUrl;
  final String? username;
  final String? connectionState;

  /// Human label from [GatewayRealtime.uiStatus] (e.g. "Reconnecting · attempt 3 · 4s").
  final String? wsLabel;
  final String? wsPhase;
  final int reconnectAttempt;
  final bool gaveUp;

  ConnectionHealthLevel level({bool? restOk}) {
    if (needsReauth) return ConnectionHealthLevel.reauth;
    if (!signedIn) return ConnectionHealthLevel.offline;
    if (wsLive) return ConnectionHealthLevel.live;
    if (restOk == false) return ConnectionHealthLevel.error;
    if (wsError != null && wsError!.isNotEmpty) {
      final m = wsError!.toLowerCase();
      if (m.contains('expired') || m.contains('sign in')) {
        return ConnectionHealthLevel.reauth;
      }
      // Still auto-retrying — degraded, not hard error.
      if (!gaveUp && (wsPhase == 'connecting' || wsPhase == 'reconnecting')) {
        return ConnectionHealthLevel.degraded;
      }
      return ConnectionHealthLevel.error;
    }
    return ConnectionHealthLevel.degraded;
  }
}

final selectedModelProvider =
    AsyncNotifierProvider<SelectedModelNotifier, String?>(
      SelectedModelNotifier.new,
    );

class SelectedModelNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    final stored = await ref
        .read(connectionStoreProvider)
        .readSelectedModel(gatewayId);
    if (stored != null && stored.trim().isNotEmpty) return stored;

    // No sticky pick yet — use gateway default from model.options.
    final defaults = await _gatewayDefaultModel(ref);
    if (defaults != null && gatewayId != null) {
      final store = ref.read(connectionStoreProvider);
      await store.writeSelectedModel(gatewayId, defaults.model);
      if (defaults.provider != null && defaults.provider!.isNotEmpty) {
        await store.writeSelectedProvider(gatewayId, defaults.provider!);
      }
      return defaults.model;
    }
    return defaults?.model;
  }

  Future<void> select(String modelId, {String? provider}) async {
    final profile = ref.read(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    if (gatewayId == null) {
      state = AsyncData(modelId);
      if (provider != null) {
        ref.read(selectedProviderProvider.notifier).state = AsyncData(provider);
      }
      return;
    }
    final store = ref.read(connectionStoreProvider);
    await store.writeSelectedModel(gatewayId, modelId);
    if (provider != null && provider.isNotEmpty) {
      await store.writeSelectedProvider(gatewayId, provider);
      ref.read(selectedProviderProvider.notifier).state = AsyncData(provider);
    }
    state = AsyncData(modelId);
  }
}

/// Sticky provider slug for the selected model (Desktop `$currentProvider`).
final selectedProviderProvider =
    AsyncNotifierProvider<SelectedProviderNotifier, String?>(
      SelectedProviderNotifier.new,
    );

class SelectedProviderNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    final stored = await ref
        .read(connectionStoreProvider)
        .readSelectedProvider(gatewayId);
    if (stored != null && stored.trim().isNotEmpty) return stored;
    final defaults = await _gatewayDefaultModel(ref);
    return defaults?.provider;
  }
}

/// Sticky reasoning effort (Desktop `$currentReasoningEffort`).
///
/// Values: `none` (Thinking off) | `minimal` | `low` | `medium` | `high` | `xhigh`.
final selectedReasoningEffortProvider =
    AsyncNotifierProvider<SelectedReasoningEffortNotifier, String>(
      SelectedReasoningEffortNotifier.new,
    );

class SelectedReasoningEffortNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    final stored = await ref
        .read(connectionStoreProvider)
        .readSelectedEffort(gatewayId);
    if (stored != null && stored.trim().isNotEmpty) {
      return normalizeReasoningEffort(stored);
    }
    return 'medium';
  }

  Future<void> select(String effort) async {
    final next = normalizeReasoningEffort(effort);
    final profile = ref.read(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    if (gatewayId != null) {
      await ref
          .read(connectionStoreProvider)
          .writeSelectedEffort(gatewayId, next);
    }
    state = AsyncData(next);
  }
}

/// Sticky Desktop Fast / priority service tier.
final selectedFastModeProvider =
    AsyncNotifierProvider<SelectedFastModeNotifier, bool>(
      SelectedFastModeNotifier.new,
    );

class SelectedFastModeNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    return ref.read(connectionStoreProvider).readSelectedFast(profile?.id);
  }

  Future<void> select(bool enabled) async {
    final profile = ref.read(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    if (gatewayId != null) {
      await ref
          .read(connectionStoreProvider)
          .writeSelectedFast(gatewayId, enabled);
    }
    state = AsyncData(enabled);
  }
}

class _GatewayDefault {
  const _GatewayDefault({required this.model, this.provider});
  final String model;
  final String? provider;
}

Future<_GatewayDefault?> _gatewayDefaultModel(Ref ref) async {
  try {
    final opts = await ref.watch(modelOptionsProvider.future);
    final model = opts.model?.trim();
    if (model != null && model.isNotEmpty) {
      return _GatewayDefault(model: model, provider: opts.provider);
    }
    // First catalog entry as last resort.
    for (final p in opts.providers) {
      if (p.models.isNotEmpty) {
        return _GatewayDefault(model: p.models.first, provider: p.slug);
      }
    }
  } catch (_) {}
  return null;
}

/// Model id only (no effort suffix) — used for session.create / config.set.
final resolvedModelIdProvider = Provider<String>((ref) {
  final sticky = ref.watch(selectedModelProvider).value?.trim();
  if (sticky != null && sticky.isNotEmpty) return sticky;
  final opts = ref.watch(modelOptionsProvider).value;
  final def = opts?.model?.trim();
  if (def != null && def.isNotEmpty) return def;
  for (final p in opts?.providers ?? const <ModelOptionProvider>[]) {
    for (final m in p.models) {
      if (m.trim().isNotEmpty) return m.trim();
    }
  }
  return 'Select model';
});

/// Model chip label including effort (Desktop: `Grok 4.5 · Med`).
final resolvedModelLabelProvider = Provider<String>((ref) {
  final model = ref.watch(resolvedModelIdProvider);
  final effort = ref.watch(selectedReasoningEffortProvider).value ?? 'medium';
  final fast = ref.watch(selectedFastModeProvider).value ?? false;
  return modelChipLabel(model, effort, fast: fast);
});

/// Activity token used for unread dots (prefer lastActive).
String sessionActivityToken(HermesSession s) {
  final a = (s.lastActive ?? s.startedAt ?? '').trim();
  if (a.isNotEmpty) return a;
  return '${s.messageCount ?? 0}';
}

/// sessionId → last-read activity token for the active gateway.
final sessionReadMapProvider =
    AsyncNotifierProvider<SessionReadMapNotifier, Map<String, String>>(
      SessionReadMapNotifier.new,
    );

class SessionReadMapNotifier extends AsyncNotifier<Map<String, String>> {
  @override
  Future<Map<String, String>> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    if (profile == null) return {};
    return ref.read(connectionStoreProvider).readSessionReadMap(profile.id);
  }

  /// First install: treat existing sessions as read so history isn't all dotted.
  Future<void> seedExistingAsRead(List<HermesSession> sessions) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    final current =
        state.value ??
        await ref.read(connectionStoreProvider).readSessionReadMap(profile.id);
    if (current.isNotEmpty) return;
    if (sessions.isEmpty) return;
    final map = {
      for (final s in sessions)
        if (s.id.isNotEmpty) s.id: sessionActivityToken(s),
    };
    await ref
        .read(connectionStoreProvider)
        .writeSessionReadMap(profile.id, map);
    state = AsyncData(map);
  }

  Future<void> markRead(HermesSession session) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    final next = await ref
        .read(connectionStoreProvider)
        .markSessionRead(profile.id, session.id, sessionActivityToken(session));
    state = AsyncData(next);
  }

  bool isUnread(HermesSession session, {String? activeId}) {
    if (session.id == activeId) return false;
    final map = state.value ?? {};
    final readToken = map[session.id];
    final nowToken = sessionActivityToken(session);
    if (readToken == null) {
      // Never opened after seeding — only flag if there is real activity.
      return (session.messageCount ?? 0) > 0 ||
          (session.preview?.trim().isNotEmpty ?? false);
    }
    if (readToken == nowToken) return false;
    final readAt = parseSessionActivity(readToken);
    final nowAt = parseSessionActivity(nowToken);
    if (readAt != null && nowAt != null) {
      return nowAt.isAfter(readAt);
    }
    // Fallback string compare (ISO sorts; epochs numeric strings sort ok if same width).
    return nowToken.compareTo(readToken) > 0;
  }
}

/// Parse lastActive / startedAt: ISO, unix seconds, or unix ms.
DateTime? parseSessionActivity(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  final iso = DateTime.tryParse(t);
  if (iso != null) return iso;
  final n = num.tryParse(t);
  if (n == null) return null;
  // Heuristic: ms since epoch vs seconds.
  final ms = n > 1e12 ? n.round() : (n * 1000).round();
  if (ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Relative label for drawer ("2 hours ago"); never raw epoch dumps.
String? formatSessionRelative(String? raw) {
  final dt = parseSessionActivity(raw);
  if (dt == null) return null;
  // timeago is imported in UI; keep pure here via short hand-rolled labels.
  final local = dt.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 2) return 'a minute ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
  if (diff.inHours < 2) return 'an hour ago';
  if (diff.inHours < 24) return '${diff.inHours} hours ago';
  if (diff.inDays < 2) return 'a day ago';
  if (diff.inDays < 30) return '${diff.inDays} days ago';
  if (diff.inDays < 60) return 'a month ago';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()} months ago';
  return '${(diff.inDays / 365).floor()} years ago';
}

/// Pinned session ids for the active gateway (Desktop `$pinnedSessionIds`).
final pinnedSessionsProvider =
    AsyncNotifierProvider<PinnedSessionsNotifier, List<String>>(
      PinnedSessionsNotifier.new,
    );

class PinnedSessionsNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final profile = ref.watch(connectionProfileProvider).value;
    if (profile == null) return const [];
    return ref.read(connectionStoreProvider).readPinnedSessionIds(profile.id);
  }

  Future<void> pin(String sessionId) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    final next = await ref
        .read(connectionStoreProvider)
        .pinSession(profile.id, sessionId);
    state = AsyncData(next);
  }

  Future<void> unpin(String sessionId) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    final next = await ref
        .read(connectionStoreProvider)
        .unpinSession(profile.id, sessionId);
    state = AsyncData(next);
  }

  Future<void> toggle(String sessionId) async {
    final current = state.value ?? const [];
    if (current.contains(sessionId)) {
      await unpin(sessionId);
    } else {
      await pin(sessionId);
    }
  }
}

final sessionsProvider =
    AsyncNotifierProvider<SessionsNotifier, List<HermesSession>>(
      SessionsNotifier.new,
    );

class BotsViewState {
  const BotsViewState({
    required this.available,
    this.profiles = const [],
    this.hiddenProfiles = const [],
    this.groupRooms = const {},
    this.syncError,
  });

  const BotsViewState.unavailable()
    : available = false,
      profiles = const [],
      hiddenProfiles = const [],
      groupRooms = const {},
      syncError = null;

  final bool available;
  final List<HermesBotProfile> profiles;
  final List<HermesBotProfile> hiddenProfiles;
  final Map<String, HermesBotGroupRoom> groupRooms;
  final String? syncError;
}

/// Server-driven Bot Mode roster.
///
/// Unsupported and older gateways resolve to `available == false`, which
/// removes the tab. A transient reconnect error never removes a roster that
/// the server already confirmed, avoiding navigation churn while a Mac wakes.
final botsProvider = AsyncNotifierProvider<BotsNotifier, BotsViewState>(
  BotsNotifier.new,
);

/// Server-owned uploaded/generated/pet avatar. Shape avatars deliberately do
/// not use the server's raster backfill: mobile draws their live face from the
/// shared shape/color metadata so it can blink and move like Desktop.
final botAvatarProvider = FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, profileName) async {
    final sync = ref.watch(sessionSyncProvider);
    if (sync == null || profileName.trim().isEmpty) return null;
    final result = await sync.gatewayRequest('profiles.get_asset', {
      'name': profileName,
      'asset': 'avatar',
    });
    if (result['found'] != true) return null;
    final data = '${result['data'] ?? ''}';
    final comma = data.indexOf(',');
    final payload = comma >= 0 ? data.substring(comma + 1) : data;
    if (payload.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(payload));
    } catch (_) {
      return null;
    }
  },
);

/// Real in-flight agent turns used by Bot Mode's working animation. The
/// initial snapshot covers a turn that began before the roster subscribed;
/// subsequent values come from gateway start/complete events.
final botWorkingSessionsProvider = StreamProvider<Set<String>>((ref) async* {
  final realtime = ref.watch(gatewayRealtimeProvider);
  if (realtime == null) {
    yield const <String>{};
    return;
  }
  yield realtime.workingSessionIds;
  yield* realtime.workingSessions;
});

class BotsNotifier extends AsyncNotifier<BotsViewState> {
  final Set<String> _knownBotModeGateways = {};

  @override
  BotsViewState build() {
    ref.watch(sessionSyncProvider);
    final profile = ref.watch(connectionProfileProvider).value;
    if (profile == null) return const BotsViewState.unavailable();
    if (profile.botModeAvailable) _knownBotModeGateways.add(profile.id);
    return BotsViewState(available: _knownBotModeGateways.contains(profile.id));
  }

  Future<BotsViewState> _fetch(SessionSyncRepository sync) async {
    final profiles = await sync.gatewayRequest('profiles.list', {
      'include_sessions': true,
    });

    Map<String, dynamic>? plugins;
    final protocolAvailable =
        profiles['bot_mode_protocol'] == true ||
        profiles['bot_mode_available'] == true;
    if (!protocolAvailable) {
      try {
        plugins = await sync.gatewayRequest('plugins.list', const {});
      } catch (_) {
        // profiles.list is the canonical current capability source. The
        // plugin catalog is only a compatibility fallback for older servers.
      }
    }

    final roster = HermesBotRoster.fromServer(profiles, pluginPayload: plugins);
    return BotsViewState(
      available: roster.available,
      profiles: roster.profiles,
      hiddenProfiles: roster.hiddenProfiles,
      groupRooms: parseHermesBotGroupRooms(profiles),
    );
  }

  Future<void> refresh() async {
    final sync = ref.read(sessionSyncProvider);
    final profile = ref.read(connectionProfileProvider).value;
    if (sync == null) {
      state = const AsyncData(BotsViewState.unavailable());
      return;
    }
    final previous = state.value;
    try {
      final fresh = await _fetch(sync);
      final remembered =
          profile != null &&
          (profile.botModeAvailable ||
              _knownBotModeGateways.contains(profile.id));
      if (fresh.available && profile != null) {
        _knownBotModeGateways.add(profile.id);
        unawaited(
          ref.read(connectionStoreProvider).rememberBotMode(profile.id),
        );
      }
      state = AsyncData(
        BotsViewState(
          available: fresh.available || remembered,
          profiles: fresh.profiles,
          hiddenProfiles: fresh.hiddenProfiles,
          groupRooms: fresh.groupRooms,
          syncError: fresh.syncError,
        ),
      );
    } catch (e) {
      debugPrint('BotsNotifier.refresh: $e');
      if (previous?.available == true) {
        state = AsyncData(
          BotsViewState(
            available: true,
            profiles: previous!.profiles,
            hiddenProfiles: previous.hiddenProfiles,
            groupRooms: previous.groupRooms,
            syncError: '$e',
          ),
        );
      } else {
        // Lack of a confirmed capability is intentionally indistinguishable
        // from an unsupported server: the shell simply keeps the tab hidden.
        state = const AsyncData(BotsViewState.unavailable());
      }
    }
  }
}

class SessionsNotifier extends AsyncNotifier<List<HermesSession>> {
  @override
  Future<List<HermesSession>> build() async {
    final sync = ref.watch(sessionSyncProvider);
    if (sync == null) return const [];
    // Local first (instant), then pull dashboard REST (Desktop path).
    final local = await sync.loadSessionsLocal();
    Future.microtask(() async {
      try {
        final pins = ref.read(pinnedSessionsProvider).value ?? const [];
        final merged = await sync.syncSessions(keepIds: pins);
        if (ref.read(sessionSyncProvider)?.gatewayId == sync.gatewayId) {
          state = AsyncData(merged);
        }
      } catch (e, st) {
        debugPrint('SessionsNotifier background sync failed: $e\n$st');
        if (local.isEmpty) {
          state = AsyncError(e, st);
        }
      }
    });
    return local;
  }

  /// [bypassTtl] — pass `true` for an explicit user-initiated refresh (e.g.
  /// pull-to-refresh); it still joins an in-flight pull rather than firing a
  /// redundant concurrent request. Leave `false` for internal/boot triggers
  /// so they coalesce with each other via [SessionSyncRepository]'s
  /// [SingleFlight].
  Future<void> refresh({bool bypassTtl = false}) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) {
      state = const AsyncData([]);
      return;
    }
    final local = await sync.loadSessionsLocal();
    if (local.isNotEmpty) state = AsyncData(local);
    final pins = ref.read(pinnedSessionsProvider).value ?? const [];
    state = await AsyncValue.guard(
      () => sync.syncSessions(keepIds: pins, bypassTtl: bypassTtl),
    );
  }

  /// Soft re-pull from gateway without flipping the list into loading.
  ///
  /// See [refresh] for [bypassTtl] semantics.
  Future<void> softRefresh({bool bypassTtl = false}) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    try {
      final pins = ref.read(pinnedSessionsProvider).value ?? const [];
      final merged = await sync.syncSessions(
        keepIds: pins,
        bypassTtl: bypassTtl,
      );
      state = AsyncData(merged);
    } catch (e) {
      debugPrint('SessionsNotifier.softRefresh: $e');
      await _maybeForceReauth(ref, e);
    }
  }

  /// Re-read SQLite after GatewayRealtime already warmed the cache.
  Future<void> reloadLocal() async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    try {
      state = AsyncData(await sync.loadSessionsLocal());
    } catch (e) {
      debugPrint('SessionsNotifier.reloadLocal: $e');
    }
  }

  Future<HermesSession?> create({
    String? title,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool? fastMode,
  }) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return null;
    final session = await sync.createSession(
      title: title,
      model: model,
      provider: provider,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
    );
    await refresh();
    return session;
  }

  Future<void> delete(String id) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    // Drop pin so a deleted id doesn't stick in the Pinned section.
    await ref.read(pinnedSessionsProvider.notifier).unpin(id);
    await sync.deleteSession(id);
    await refresh();
  }

  Future<void> rename(String id, String title) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    await sync.renameSession(id, title);
    await softRefresh();
  }

  Future<void> archive(String id) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    await ref.read(pinnedSessionsProvider.notifier).unpin(id);
    await sync.archiveSession(id);
    await softRefresh();
  }
}

/// Sessions list with pinned rows first (Desktop sidebar order).
List<HermesSession> orderSessionsWithPins(
  List<HermesSession> sessions,
  List<String> pinnedIds,
) {
  if (pinnedIds.isEmpty || sessions.isEmpty) return sessions;
  final byId = {for (final s in sessions) s.id: s};
  final pinned = <HermesSession>[];
  final pinnedSet = <String>{};
  for (final id in pinnedIds) {
    final s = byId[id];
    if (s != null) {
      pinned.add(s);
      pinnedSet.add(id);
    }
  }
  final rest = [
    for (final s in sessions)
      if (!pinnedSet.contains(s.id)) s,
  ];
  return [...pinned, ...rest];
}

final modelsProvider =
    AsyncNotifierProvider<ModelsNotifier, List<HermesModelInfo>>(
      ModelsNotifier.new,
    );

/// Full Desktop `model.options` / GET /api/model/options payload.
/// Installed skills from the active gateway (user + hub + bundled).
final skillsProvider = AsyncNotifierProvider<SkillsNotifier, List<HermesSkill>>(
  SkillsNotifier.new,
);

class SkillsNotifier extends AsyncNotifier<List<HermesSkill>> {
  @override
  Future<List<HermesSkill>> build() => _load();

  List<HermesSkill> _sort(List<HermesSkill> list) {
    final sorted = [...list]
      ..sort((a, b) {
        if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
        final ca = (a.category ?? '').toLowerCase();
        final cb = (b.category ?? '').toLowerCase();
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return sorted;
  }

  Future<List<HermesSkill>> _load() async {
    final sync = ref.watch(sessionSyncProvider);
    if (sync == null) return const [];
    // Local first so the sheet isn't empty while remote is slow/failing.
    try {
      final local = await sync.loadSkillsLocal();
      if (local.isNotEmpty) {
        // Kick remote in background; keep UI responsive.
        Future.microtask(() async {
          try {
            final remote = await sync.listSkills();
            if (!ref.mounted) return;
            state = AsyncData(_sort(remote));
          } catch (e) {
            debugPrint('skillsProvider background: $e');
          }
        });
        return _sort(local);
      }
    } catch (e) {
      debugPrint('skillsProvider local: $e');
    }
    try {
      return _sort(await sync.listSkills());
    } catch (e) {
      debugPrint('skillsProvider: $e');
      return const [];
    }
  }

  /// See [SessionsNotifier.refresh] for [bypassTtl] semantics.
  Future<void> refresh({bool bypassTtl = false}) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) {
      state = const AsyncData([]);
      return;
    }
    // Keep showing cache while refreshing (don't blank the sheet).
    try {
      final local = await sync.loadSkillsLocal();
      if (local.isNotEmpty) state = AsyncData(_sort(local));
    } catch (_) {}
    try {
      final list = await sync.listSkills(bypassTtl: bypassTtl);
      state = AsyncData(_sort(list));
    } catch (e) {
      debugPrint('skillsProvider refresh: $e');
      // Leave prior state / local cache in place.
    }
  }

  /// Rescan host skill dirs, then re-pull the catalog.
  Future<String> reloadFromGateway() async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return 'Not connected';
    final msg = await sync.reloadSkills();
    await refresh();
    final n = state.value?.length ?? 0;
    return n > 0 ? '$msg\n$n skill(s) on phone.' : msg;
  }
}

/// Slash-command cheat sheet registry — `GET /api/commands`.
///
/// Lightweight, server-driven, no local cache: unlike [SkillsNotifier] /
/// [ModelOptionsNotifier] this doesn't need offline-first or realtime sync.
/// On error, state becomes [AsyncError] so the screen can show a retry —
/// never silently falls back to an empty or hardcoded list.
final commandsProvider =
    AsyncNotifierProvider<CommandsNotifier, List<SlashCommand>>(
      CommandsNotifier.new,
    );

class CommandsNotifier extends AsyncNotifier<List<SlashCommand>> {
  @override
  Future<List<SlashCommand>> build() => _load();

  Future<List<SlashCommand>> _load() async {
    final dash = ref.read(dashboardClientProvider);
    if (dash == null) return const [];
    return dash.listCommands();
  }

  Future<void> refresh() async {
    final dash = ref.read(dashboardClientProvider);
    if (dash == null) {
      state = const AsyncData([]);
      return;
    }
    final had = state.asData?.value;
    if (had == null || had.isEmpty) {
      state = const AsyncLoading();
    }
    state = await AsyncValue.guard(() => dash.listCommands());
  }
}

final modelOptionsProvider =
    AsyncNotifierProvider<ModelOptionsNotifier, ModelOptionsResult>(
      ModelOptionsNotifier.new,
    );

/// Model catalog: disk cache first, network only when empty or on explicit sync.
///
/// - First gateway connect / empty cache → fetch + persist
/// - Later app opens → instant local catalog
/// - Opening the model picker / pull-to-refresh → soft sync; UI updates only
///   when the provider/model list actually diffs
class ModelOptionsNotifier extends AsyncNotifier<ModelOptionsResult> {
  var _syncing = false;
  var _pendingForceRefresh = false;
  String? _pendingRefreshSessionId;

  // v3 preserves server-advertised reasoning levels/defaults/thinking gates.
  // v2 only cached the coarse {reasoning, fast} booleans.
  static const _cacheSchemaVersion = 3;

  @override
  Future<ModelOptionsResult> build() async {
    final cached = await _readCache();
    // Stale caches (pre-capabilities) must not gate the picker forever.
    if (cached != null &&
        cached.providers.isNotEmpty &&
        cached.hasCapabilityMaps) {
      Future.microtask(() => softSync(forceRefresh: false));
      return cached;
    }
    // Cold start or cache missing capability maps → fetch with caps.
    final fresh = await _load(refresh: false);
    await _writeCache(fresh);
    final nCaps = fresh.providers.fold<int>(
      0,
      (a, p) => a + p.capabilities.length,
    );
    debugPrint(
      'model.options cold load: ${fresh.providers.length} providers, '
      '$nCaps capability rows, hasMaps=${fresh.hasCapabilityMaps}',
    );
    return fresh;
  }

  Future<ModelOptionsResult?> _readCache() async {
    final profile = ref.read(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    if (gatewayId == null || gatewayId.isEmpty) return null;
    try {
      final raw = await ref
          .read(connectionStoreProvider)
          .readModelOptionsJson(gatewayId);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      // v2 wraps payload; v1 was bare ModelOptionsResult JSON.
      final version = map['v'] is num ? (map['v'] as num).toInt() : 1;
      final payload = version >= 2 && map['payload'] is Map
          ? (map['payload'] as Map).cast<String, dynamic>()
          : map;
      final parsed = ModelOptionsResult.fromJson(payload);
      if (version < _cacheSchemaVersion || !parsed.hasCapabilityMaps) {
        debugPrint(
          'model.options cache stale (v=$version, hasCaps=${parsed.hasCapabilityMaps})',
        );
        return null;
      }
      return parsed;
    } catch (e) {
      debugPrint('model.options cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeCache(ModelOptionsResult opts) async {
    final profile = ref.read(connectionProfileProvider).value;
    final gatewayId = profile?.id;
    if (gatewayId == null || gatewayId.isEmpty) return;
    if (opts.providers.isEmpty) return;
    try {
      final envelope = jsonEncode({
        'v': _cacheSchemaVersion,
        'payload': opts.toJson(),
      });
      await ref
          .read(connectionStoreProvider)
          .writeModelOptionsJson(gatewayId, envelope);
    } catch (e) {
      debugPrint('model.options cache write failed: $e');
    }
  }

  Future<ModelOptionsResult> _load({
    bool refresh = false,
    String? sessionId,
  }) async {
    final dash = ref.read(dashboardClientProvider);
    final rt = ref.read(gatewayRealtimeProvider);
    if (sessionId != null &&
        sessionId.trim().isNotEmpty &&
        rt != null &&
        rt.isLive) {
      try {
        final sync = ref.read(sessionSyncProvider);
        final liveId = await sync?.resolveLiveSessionId(sessionId) ?? sessionId;
        final raw = await rt.request('model.options', {
          'session_id': liveId,
          'explicit_only': true,
          if (refresh) 'refresh': true,
        });
        return ModelOptionsResult.fromJson(raw);
      } catch (e) {
        debugPrint('model.options session RPC failed: $e');
      }
    }
    if (dash != null) {
      try {
        return await dash.listModelOptions(
          explicitOnly: true,
          refresh: refresh,
        );
      } catch (e) {
        debugPrint('model.options REST failed: $e');
      }
    }
    // WS fallback (Desktop in-session path).
    if (rt != null && rt.isLive) {
      try {
        final raw = await rt.request('model.options', {
          'explicit_only': true,
          if (refresh) 'refresh': true,
        });
        return ModelOptionsResult.fromJson(raw);
      } catch (e) {
        debugPrint('model.options WS failed: $e');
      }
    }
    // Legacy API server /v1/models
    final api = ref.read(hermesApiProvider);
    if (api != null) {
      try {
        final flat = await api.listModels();
        return ModelOptionsResult(
          providers: [
            if (flat.isNotEmpty)
              ModelOptionProvider(
                slug: 'gateway',
                name: 'Gateway',
                models: flat.map((m) => m.id).toList(),
              ),
          ],
        );
      } catch (_) {}
    }
    return const ModelOptionsResult();
  }

  /// Background / picker open: fetch remote catalog, apply only if it diffs.
  ///
  /// Keeps existing [state] visible (no full-screen loading flash).
  Future<void> softSync({bool forceRefresh = true, String? sessionId}) async {
    if (_syncing) {
      // A startup/cache sync must never swallow the picker's stronger request
      // for authoritative per-model controls. Run it immediately after the
      // in-flight sync finishes instead of returning stale boolean-only caps.
      if (forceRefresh) {
        _pendingForceRefresh = true;
        _pendingRefreshSessionId = sessionId;
      }
      return;
    }
    _syncing = true;
    try {
      final next = await _load(refresh: forceRefresh, sessionId: sessionId);
      if (next.providers.isEmpty) {
        // Don't clobber a good cache with an empty failed probe.
        return;
      }
      await _writeCache(next);
      final prev = state.asData?.value;
      if (prev == null) {
        state = AsyncData(next);
        return;
      }
      final catalogChanged = !prev.sameCatalogAs(next);
      final currentChanged =
          prev.model != next.model || prev.provider != next.provider;
      final capsImproved = !prev.hasCapabilityMaps && next.hasCapabilityMaps;
      if (catalogChanged || currentChanged || capsImproved) {
        final nCaps = next.providers.fold<int>(
          0,
          (a, p) => a + p.capabilities.length,
        );
        debugPrint(
          'model.options softSync apply: '
          'catalog=$catalogChanged current=$currentChanged caps=$capsImproved '
          '(${next.providers.length} providers, $nCaps caps)',
        );
        state = AsyncData(next);
      }
    } catch (e) {
      debugPrint('model.options softSync failed: $e');
    } finally {
      _syncing = false;
      if (_pendingForceRefresh) {
        final pendingSessionId = _pendingRefreshSessionId;
        _pendingForceRefresh = false;
        _pendingRefreshSessionId = null;
        unawaited(softSync(forceRefresh: true, sessionId: pendingSessionId));
      }
    }
  }

  /// Hard refresh (Settings / error recovery) — may briefly show loading
  /// only when we have nothing cached.
  Future<void> refresh() async {
    final had = state.asData?.value;
    if (had == null || had.providers.isEmpty) {
      state = const AsyncLoading();
    }
    state = await AsyncValue.guard(() async {
      final next = await _load(refresh: true);
      if (next.providers.isNotEmpty) {
        await _writeCache(next);
        return next;
      }
      // Keep previous good catalog if network returned empty.
      return had ?? next;
    });
  }
}

class ModelsNotifier extends AsyncNotifier<List<HermesModelInfo>> {
  @override
  Future<List<HermesModelInfo>> build() async {
    final opts = await ref.watch(modelOptionsProvider.future);
    return opts.asFlatModels();
  }

  Future<void> refresh() async {
    await ref.read(modelOptionsProvider.notifier).refresh();
    final opts = ref.read(modelOptionsProvider).value;
    state = AsyncData(opts?.asFlatModels() ?? const []);
  }
}

/// Jobs list + soft sync error (connection refused still shows cache).
class JobsViewState {
  const JobsViewState({
    required this.jobs,
    this.syncError,
    this.fromCache = false,
  });

  final List<HermesJob> jobs;
  final String? syncError;
  final bool fromCache;
}

class JobDetailViewState {
  const JobDetailViewState({
    required this.job,
    required this.runs,
    this.syncError,
    this.fromCache = false,
  });

  final HermesJob job;
  final List<HermesSession> runs;
  final String? syncError;
  final bool fromCache;
}

final jobsProvider = AsyncNotifierProvider<JobsNotifier, JobsViewState>(
  JobsNotifier.new,
);

class JobsNotifier extends AsyncNotifier<JobsViewState> {
  /// Coalesces redundant startup pulls (build's background sync, shell boot,
  /// session-touch-triggered refresh) behind one `/api/cron/jobs` request.
  final _syncFlight = SingleFlight<JobsViewState>();

  @override
  Future<JobsViewState> build() async {
    // Local first so the tab is never blank on a flaky link.
    final local = await _loadLocal();
    Future.microtask(() async {
      try {
        final merged = await _syncFromServer();
        if (!ref.mounted) return;
        state = AsyncData(merged);
        await _reconcile(merged.jobs);
      } catch (e) {
        debugPrint('Jobs: background sync failed: $e');
        await _maybeForceReauth(ref, e);
        if (!ref.mounted) return;
        if (local.jobs.isNotEmpty) {
          state = AsyncData(
            JobsViewState(
              jobs: local.jobs,
              syncError: _friendlyErr(e),
              fromCache: true,
            ),
          );
        }
      }
    });
    return local;
  }

  Future<JobsViewState> _loadLocal() async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) {
      return const JobsViewState(jobs: []);
    }
    final db = ref.read(appDatabaseProvider);
    final rows = await db.jobsForGateway(profile.id);
    return JobsViewState(jobs: rows.map(_jobFromRow).toList(), fromCache: true);
  }

  /// Pull server; on success merge into SQLite. Never clears cache on failure.
  ///
  /// Coalesced via [SingleFlight]. See [SessionsNotifier.refresh] for
  /// [bypassTtl] semantics.
  Future<JobsViewState> _syncFromServer({bool bypassTtl = false}) {
    return _syncFlight.run(_syncFromServerImpl, bypassTtl: bypassTtl);
  }

  Future<JobsViewState> _syncFromServerImpl() async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) {
      return const JobsViewState(jobs: []);
    }
    final db = ref.read(appDatabaseProvider);
    Object? lastErr;
    List<HermesJob>? remote;

    final dash = ref.read(dashboardClientProvider);
    if (dash != null) {
      try {
        remote = await dash.listCronJobs();
      } catch (e) {
        lastErr = e;
        debugPrint('Jobs: dashboard cron list failed: $e');
      }
    }

    if (remote == null) {
      final rt = ref.read(gatewayRealtimeProvider);
      if (rt != null) {
        try {
          if (!rt.isLive) await rt.start();
          if (rt.isLive) {
            final raw = await rt.request('cron.manage', {'action': 'list'});
            remote = _jobsFromWs(raw);
          }
        } catch (e) {
          lastErr ??= e;
          debugPrint('Jobs: cron.manage list failed: $e');
        }
      }
    }

    if (remote == null) {
      final api = ref.read(hermesApiProvider);
      if (api != null) {
        try {
          remote = await api.listJobs();
        } catch (e) {
          lastErr ??= e;
          debugPrint('Jobs: hermesApi listJobs failed: $e');
        }
      }
    }

    if (remote == null) {
      final local = await db.jobsForGateway(profile.id);
      final jobs = local.map(_jobFromRow).toList();
      if (jobs.isEmpty && lastErr != null) {
        // Nothing cached — surface the error.
        throw lastErr;
      }
      return JobsViewState(
        jobs: jobs,
        syncError: lastErr != null ? _friendlyErr(lastErr) : null,
        fromCache: true,
      );
    }

    // Successful pull — merge; only drops rows the server no longer lists.
    final now = DateTime.now().toUtc();
    await db.mergeJobsFromServer(profile.id, [
      for (final j in remote)
        CachedJobsCompanion.insert(
          gatewayId: profile.id,
          id: j.id,
          name: Value(j.name),
          schedule: Value(j.schedule),
          prompt: Value(j.prompt),
          deliver: Value(j.deliver),
          enabled: Value(j.enabled),
          state: Value(j.state),
          lastRunAt: Value(j.lastRunAt),
          lastStatus: Value(j.lastStatus),
          nextRunAt: Value(j.nextRunAt),
          detailsJson: Value(jsonEncode(j.raw)),
          syncStatus: const Value('synced'),
          updatedAt: now,
        ),
    ]);

    final rows = await db.jobsForGateway(profile.id);
    return JobsViewState(
      jobs: rows.map(_jobFromRow).toList(),
      fromCache: false,
    );
  }

  HermesJob _jobFromRow(CachedJob r) {
    final details = r.detailsJson;
    if (details != null && details.isNotEmpty) {
      try {
        final decoded = jsonDecode(details);
        if (decoded is Map) {
          return HermesJob.fromJson(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        debugPrint('Jobs: cached detail decode failed for ${r.id}: $e');
      }
    }
    return HermesJob(
      id: r.id,
      name: r.name,
      schedule: r.schedule,
      prompt: r.prompt,
      deliver: r.deliver,
      enabled: r.enabled,
      state: r.state,
      lastRunAt: r.lastRunAt,
      lastStatus: r.lastStatus,
      nextRunAt: r.nextRunAt,
    );
  }

  Map<String, dynamic> _sessionToJson(HermesSession session) => {
    'id': session.id,
    'source': session.source,
    'user_id': session.userId,
    'model': session.model,
    'title': session.title,
    'started_at': session.startedAt,
    'ended_at': session.endedAt,
    'end_reason': session.endReason,
    'message_count': session.messageCount,
    'tool_call_count': session.toolCallCount,
    'last_active': session.lastActive,
    'preview': session.preview,
    'parent_session_id': session.parentSessionId,
  };

  Future<JobDetailViewState> loadJobDetail(String jobId) async {
    final profile = ref.read(connectionProfileProvider).value;
    final current = state.value?.jobs
        .where((job) => job.id == jobId)
        .firstOrNull;
    if (profile == null) {
      if (current == null) throw StateError('No gateway selected');
      return JobDetailViewState(job: current, runs: const [], fromCache: true);
    }
    final db = ref.read(appDatabaseProvider);
    final cachedJobs = await db.jobsForGateway(profile.id);
    final cachedRow = cachedJobs.where((row) => row.id == jobId).firstOrNull;
    final job = cachedRow == null
        ? current
        : (cachedRow.detailsJson == null && current != null
              ? current
              : _jobFromRow(cachedRow));
    if (job == null) throw StateError('Job not found');
    final runRows = await db.jobRunsForJob(profile.id, jobId);
    final runs = <HermesSession>[];
    for (final row in runRows) {
      try {
        final decoded = jsonDecode(row.sessionJson);
        if (decoded is Map) {
          final run = HermesSession.fromJson(decoded.cast<String, dynamic>());
          if (run.id.isNotEmpty) runs.add(run);
        }
      } catch (e) {
        debugPrint('Jobs: cached run decode failed for ${row.sessionId}: $e');
      }
    }
    return JobDetailViewState(job: job, runs: runs, fromCache: true);
  }

  /// Refresh detail and run history independently. Either successful response
  /// updates its cache; a failure keeps the last known half of the screen.
  Future<JobDetailViewState> refreshJobDetail(String jobId) async {
    var local = await loadJobDetail(jobId);
    final profile = ref.read(connectionProfileProvider).value;
    final dash = ref.read(dashboardClientProvider);
    if (profile == null || dash == null) {
      return JobDetailViewState(
        job: local.job,
        runs: local.runs,
        syncError: 'Gateway unavailable. Showing saved job information.',
        fromCache: true,
      );
    }
    final db = ref.read(appDatabaseProvider);
    final errors = <String>[];
    var job = local.job;
    var runs = local.runs;

    try {
      job = await dash.getCronJob(jobId);
      await db.upsertJob(
        CachedJobsCompanion.insert(
          gatewayId: profile.id,
          id: job.id,
          name: Value(job.name),
          schedule: Value(job.schedule),
          prompt: Value(job.prompt),
          deliver: Value(job.deliver),
          enabled: Value(job.enabled),
          state: Value(job.state),
          lastRunAt: Value(job.lastRunAt),
          lastStatus: Value(job.lastStatus),
          nextRunAt: Value(job.nextRunAt),
          detailsJson: Value(jsonEncode(job.raw)),
          syncStatus: const Value('synced'),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      final listState = state.value;
      if (listState != null) {
        state = AsyncData(
          JobsViewState(
            jobs: [
              for (final existing in listState.jobs)
                if (existing.id == jobId) job else existing,
            ],
            syncError: listState.syncError,
            fromCache: listState.fromCache,
          ),
        );
      }
    } catch (e) {
      errors.add('Job details: ${_friendlyErr(e)}');
    }

    try {
      runs = await dash.listCronJobRuns(jobId, limit: 20);
      final now = DateTime.now().toUtc();
      await db.replaceJobRuns(profile.id, jobId, [
        for (final run in runs)
          CachedJobRunsCompanion.insert(
            gatewayId: profile.id,
            jobId: jobId,
            sessionId: run.id,
            sessionJson: jsonEncode(_sessionToJson(run)),
            lastActive: Value(run.lastActive ?? run.startedAt),
            updatedAt: now,
          ),
      ]);
    } catch (e) {
      errors.add('Run history: ${_friendlyErr(e)}');
    }

    local = JobDetailViewState(
      job: job,
      runs: runs,
      syncError: errors.isEmpty ? null : errors.join('\n'),
      fromCache: errors.isNotEmpty,
    );
    return local;
  }

  List<HermesJob> _jobsFromWs(Map<String, dynamic> raw) {
    dynamic data = raw;
    if (data['jobs'] is List) {
      data = data['jobs'];
    } else if (data['data'] is List) {
      data = data['data'];
    } else if (data['value'] is List) {
      data = data['value'];
    } else if (data['value'] is Map && (data['value'] as Map)['jobs'] is List) {
      data = (data['value'] as Map)['jobs'];
    }
    if (data is! List) return const [];
    final out = <HermesJob>[];
    for (final item in data) {
      if (item is! Map) continue;
      try {
        final j = HermesJob.fromJson(item.cast<String, dynamic>());
        if (j.id.isNotEmpty) out.add(j);
      } catch (e) {
        debugPrint('Jobs: skip WS job row: $e');
      }
    }
    return out;
  }

  String _friendlyErr(Object e) {
    final s = '$e';
    if (s.contains('Connection refused') || s.contains('connection refused')) {
      return 'Gateway unreachable (connection refused). Showing cached jobs.';
    }
    if (s.contains('Failed host lookup') || s.contains('SocketException')) {
      return 'Network error. Showing cached jobs.';
    }
    if (s.toLowerCase().contains('timeout')) {
      return 'Gateway timed out. Showing cached jobs.';
    }
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  Future<void> _reconcile(List<HermesJob> jobs) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    await ref
        .read(jobNotifierServiceProvider)
        .reconcile(jobs, gatewayId: profile.id);
  }

  /// See [SessionsNotifier.refresh] for [bypassTtl] semantics.
  Future<void> refresh({bool bypassTtl = false}) async {
    final previous = state.value;
    try {
      final merged = await _syncFromServer(bypassTtl: bypassTtl);
      state = AsyncData(merged);
      await _reconcile(merged.jobs);
    } catch (e, st) {
      debugPrint('Jobs: refresh failed: $e\n$st');
      if (previous != null && previous.jobs.isNotEmpty) {
        state = AsyncData(
          JobsViewState(
            jobs: previous.jobs,
            syncError: _friendlyErr(e),
            fromCache: true,
          ),
        );
      } else {
        final local = await _loadLocal();
        if (local.jobs.isNotEmpty) {
          state = AsyncData(
            JobsViewState(
              jobs: local.jobs,
              syncError: _friendlyErr(e),
              fromCache: true,
            ),
          );
        } else {
          state = AsyncError(e, st);
        }
      }
    }
  }

  /// Optimistic local tombstone; server delete confirmation comes on next sync.
  Future<void> markDeletedLocally(String jobId) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) return;
    await ref.read(appDatabaseProvider).markJobDeleted(profile.id, jobId);
    final local = await _loadLocal();
    state = AsyncData(local);
  }
}

final jobNotifierServiceProvider = Provider<JobNotifierService>((ref) {
  return JobNotifierService();
});

// ── Theme (Desktop skins) ────────────────────────────────────────────

/// Selected skin id (`nous`, `midnight`, …).
final appSkinIdProvider = AsyncNotifierProvider<AppSkinIdNotifier, String>(
  AppSkinIdNotifier.new,
);

class AppSkinIdNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final id = await ref.read(connectionStoreProvider).readSkinId();
    return (id != null && id.isNotEmpty) ? id : kDefaultSkinId;
  }

  Future<void> select(String skinId) async {
    await ref.read(connectionStoreProvider).writeSkinId(skinId);
    state = AsyncData(skinId);
  }
}

/// system | light | dark
final appThemeModeProvider =
    AsyncNotifierProvider<AppThemeModeNotifier, ThemeMode>(
      AppThemeModeNotifier.new,
    );

class AppThemeModeNotifier extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() async {
    final raw = await ref.read(connectionStoreProvider).readThemeMode();
    return _parseMode(raw);
  }

  Future<void> select(ThemeMode mode) async {
    final name = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await ref.read(connectionStoreProvider).writeThemeMode(name);
    state = AsyncData(mode);
  }

  ThemeMode _parseMode(String? raw) {
    switch ((raw ?? 'system').trim().toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

/// Resolved skin for the current selection.
final appSkinProvider = Provider<HermesSkin>((ref) {
  final id = ref.watch(appSkinIdProvider).value ?? kDefaultSkinId;
  return skinById(id);
});

/// UI locale override. `null` = follow the device language.
final appLocaleProvider = AsyncNotifierProvider<AppLocaleNotifier, Locale?>(
  AppLocaleNotifier.new,
);

class AppLocaleNotifier extends AsyncNotifier<Locale?> {
  @override
  Future<Locale?> build() async {
    final code = await ref.read(connectionStoreProvider).readLocaleCode();
    return _parse(code);
  }

  Future<void> selectSystem() async {
    await ref.read(connectionStoreProvider).writeLocaleCode(null);
    state = const AsyncData(null);
  }

  Future<void> selectLanguageCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      await selectSystem();
      return;
    }
    await ref.read(connectionStoreProvider).writeLocaleCode(trimmed);
    state = AsyncData(Locale(trimmed));
  }

  Locale? _parse(String? raw) {
    final c = raw?.trim();
    if (c == null || c.isEmpty || c == 'system') return null;
    return Locale(c);
  }
}

/// Desktop `$hapticsMuted` — when true, no haptics and no completion chime.
final hapticsMutedProvider = AsyncNotifierProvider<HapticsMutedNotifier, bool>(
  HapticsMutedNotifier.new,
);

class HapticsMutedNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final muted = await ref.read(connectionStoreProvider).readHapticsMuted();
    FeedbackService.instance.muted = muted;
    return muted;
  }

  Future<void> setMuted(bool muted) async {
    await ref.read(connectionStoreProvider).writeHapticsMuted(muted);
    FeedbackService.instance.muted = muted;
    state = AsyncData(muted);
  }

  Future<void> toggle() async {
    final next = !(state.value ?? false);
    await setMuted(next);
  }
}
