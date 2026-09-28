import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/network/gateway_auth.dart';

/// Cookie-authenticated client for the **dashboard/serve** HTTP surface.
///
/// Source of truth: `apps/desktop/src/hermes.ts` (window.hermesDesktop.api paths).
/// Electron attaches the same session cookies after password/OAuth login; we
/// attach them via [PersistCookieJar] from [GatewayAuthClient.passwordLogin].
///
/// | Desktop function              | Path |
/// |-------------------------------|------|
/// | listSessions                  | GET  /api/sessions |
/// | getSessionMessages            | GET  /api/sessions/{id}/messages |
/// | deleteSession                 | DELETE /api/sessions/{id} |
/// | deleteProfile                 | DELETE /api/profiles/{name} |
/// | getGlobalModelOptions         | GET  /api/model/options |
/// | getCronJobs                   | GET  /api/cron/jobs |
/// | getCronJob / getCronJobRuns  | GET  /api/cron/jobs/{id}[/runs] |
/// | pause/resume/triggerCronJob   | POST /api/cron/jobs/{id}/… |
/// | getStatus                     | GET  /api/status |
///
/// Do **not** use API_SERVER `:8642` `/v1/*` shapes for these.
class DashboardClient {
  /// [dio] is a test-only injection point (mirrors `HermesApi`'s
  /// constructor) — when set, [_ensureDio] returns it directly instead of
  /// building one from the persistent cookie jar, so tests can exercise
  /// request/response handling without a real profile/keystore. Named `dio`
  /// (not `_dio`) so it's a usable public parameter; that mismatch is why
  /// this can't be an initializing formal.
  // ignore: prefer_initializing_formals
  DashboardClient({required this.profile, Dio? dio}) : _dio = dio;

  final ConnectionProfile profile;

  Dio? _dio;

  /// Last HTTP error message for UI diagnostics (not silent empty lists).
  String? lastError;

  Future<Dio> _ensureDio() async {
    final existing = _dio;
    if (existing != null) return existing;

    final jar = await GatewayAuthClient.persistentJar(profile.id);
    final base = _normalize(profile.baseUrl);
    final cookies = await jar.loadForRequest(Uri.parse(base));
    debugPrint(
      'DashboardClient: ${cookies.length} cookie(s) for $base '
      '(${cookies.map((c) => c.name).join(', ')})',
    );

    final dio = Dio(
      BaseOptions(
        baseUrl: base,
        // Match Desktop STARTUP_REQUEST_TIMEOUT_MS / SESSION_LIST (60s).
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'Accept': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(CookieManager(jar));
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (res, handler) {
          debugPrint(
            'DashboardClient ${res.requestOptions.method} '
            '${res.requestOptions.path} → ${res.statusCode}',
          );
          handler.next(res);
        },
        onError: (e, handler) {
          debugPrint(
            'DashboardClient ERROR ${e.requestOptions.method} '
            '${e.requestOptions.path}: $e',
          );
          handler.next(e);
        },
      ),
    );
    if (profile.hasLegacyToken) {
      dio.options.headers['Authorization'] = 'Bearer ${profile.apiKey}';
    }
    _dio = dio;
    return dio;
  }

  static String _normalize(String raw) {
    var v = raw.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// Desktop `listSessions` — hermes.ts L198-216.
  Future<List<HermesSession>> listSessions({
    int limit = 100,
    int minMessages = 0,
    String order = 'recent',
    String archived = 'exclude',
    String? excludeSources,
    String? source,
  }) async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/sessions',
      queryParameters: {
        'limit': limit,
        'offset': 0,
        'min_messages': minMessages,
        'order': order,
        'archived': archived,
        // Desktop recents: excludeSources: ['cron'] (session.ts comments).
        if (excludeSources != null && excludeSources.isNotEmpty)
          'exclude_sources': excludeSources,
        'source': ?source,
      },
    );
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      lastError = 'listSessions HTTP ${res.statusCode}: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = res.data;
    List? raw;
    if (body is Map) {
      final sessions = body['sessions'];
      final data = body['data'];
      raw = sessions is List ? sessions : (data is List ? data : null);
    } else if (body is List) {
      raw = body;
    }
    if (raw == null) {
      lastError = 'listSessions: unexpected body ${body.runtimeType}';
      debugPrint(lastError);
      return const [];
    }
    final list = raw
        .whereType<Map>()
        .map((m) => HermesSession.fromJson(m.cast<String, dynamic>()))
        .where((s) => s.id.isNotEmpty)
        .toList();
    debugPrint('DashboardClient.listSessions → ${list.length} rows');
    return list;
  }

  void _throwIfAuth(Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      lastError = 'Session expired — sign in again (HTTP ${res.statusCode}).';
      throw DashboardAuthException(lastError!);
    }
  }

  /// Desktop `getSessionMessages` — hermes.ts L295-301.
  Future<List<HermesMessage>> listMessages(String sessionId) async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/sessions/${Uri.encodeComponent(sessionId)}/messages',
    );
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      lastError = 'listMessages HTTP ${res.statusCode}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = res.data;
    List? raw;
    if (body is Map) {
      final messages = body['messages'];
      final data = body['data'];
      raw = messages is List ? messages : (data is List ? data : null);
    }
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((m) => HermesMessage.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Desktop `deleteSession` — hermes.ts L304-309.
  Future<void> deleteSession(String sessionId) async {
    final dio = await _ensureDio();
    final res = await dio.delete<dynamic>(
      '/api/sessions/${Uri.encodeComponent(sessionId)}',
    );
    _throwIfAuth(res);
  }

  /// Permanently delete a non-default Hermes profile. Bot Mode bots are real
  /// profiles, so this is the same server-owned operation Desktop uses after
  /// its confirmation dialog.
  Future<void> deleteProfile(String name) async {
    final profileName = name.trim();
    if (profileName.isEmpty) throw ArgumentError.value(name, 'name');
    if (profileName.toLowerCase() == 'default') {
      throw StateError('The default profile cannot be deleted.');
    }
    final dio = await _ensureDio();
    final res = await dio.delete<dynamic>(
      '/api/profiles/${Uri.encodeComponent(profileName)}',
    );
    _throwIfAuth(res);
    if (res.statusCode != null && res.statusCode! >= 400) {
      lastError = 'deleteProfile HTTP ${res.statusCode}: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
  }

  /// Desktop `renameSession` — PATCH /api/sessions/{id} `{ title }`.
  Future<void> renameSession(String sessionId, String title) async {
    final dio = await _ensureDio();
    final res = await dio.patch<dynamic>(
      '/api/sessions/${Uri.encodeComponent(sessionId)}',
      data: {'title': title},
    );
    _throwIfAuth(res);
    if (res.statusCode != null &&
        res.statusCode! >= 400 &&
        res.statusCode! < 600) {
      lastError = 'renameSession HTTP ${res.statusCode}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
  }

  /// Desktop `setSessionArchived` — PATCH `{ archived }`.
  Future<void> setSessionArchived(String sessionId, bool archived) async {
    final dio = await _ensureDio();
    final res = await dio.patch<dynamic>(
      '/api/sessions/${Uri.encodeComponent(sessionId)}',
      data: {'archived': archived},
    );
    _throwIfAuth(res);
    if (res.statusCode != null &&
        res.statusCode! >= 400 &&
        res.statusCode! < 600) {
      lastError = 'setSessionArchived HTTP ${res.statusCode}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
  }

  /// Desktop `getSkills` — hermes.ts L542-547 → `GET /api/skills`.
  ///
  /// Returns installed skills (bundled + hub + agent-authored) with
  /// enabled/provenance. User skills live under `~/.hermes/skills/` on the host.
  Future<List<HermesSkill>> listSkills() async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>('/api/skills');
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      lastError = 'listSkills HTTP ${res.statusCode}: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = res.data;
    List? raw;
    if (body is List) {
      raw = body;
    } else if (body is Map) {
      final skills = body['skills'];
      final data = body['data'];
      raw = skills is List ? skills : (data is List ? data : null);
    }
    if (raw == null) {
      lastError = 'listSkills: unexpected body ${body.runtimeType}';
      debugPrint(lastError);
      return const [];
    }
    final list = raw
        .whereType<Map>()
        .map((m) => HermesSkill.fromJson(m.cast<String, dynamic>()))
        .where((s) => s.name.isNotEmpty)
        .toList();
    debugPrint('DashboardClient.listSkills → ${list.length} skills');
    return list;
  }

  /// Slash-command cheat sheet — `GET /api/commands`.
  ///
  /// Returns the full registry of slash commands the gateway/CLI supports,
  /// with category, aliases, and gating metadata for client-side display.
  Future<List<SlashCommand>> listCommands() async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>('/api/commands');
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      lastError = 'listCommands HTTP ${res.statusCode}: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = res.data;
    List? raw;
    if (body is Map) {
      final commands = body['commands'];
      raw = commands is List ? commands : null;
    }
    if (raw == null) {
      lastError = 'listCommands: unexpected body ${body.runtimeType}';
      debugPrint(lastError);
      return const [];
    }
    final list = raw
        .whereType<Map>()
        .map((m) => SlashCommand.fromJson(m.cast<String, dynamic>()))
        .where((c) => c.name.isNotEmpty)
        .toList();
    debugPrint('DashboardClient.listCommands → ${list.length} commands');
    return list;
  }

  /// Desktop `getCronJobs` — hermes.ts L750-755 (returns CronJob[]).
  ///
  /// Dashboard returns a **JSON array** (not `{jobs:[]}`). Profile scope
  /// defaults to all profiles on the host.
  Future<List<HermesJob>> listCronJobs() async {
    lastError = null;
    final dio = await _ensureDio();
    try {
      final res = await dio.get<dynamic>(
        '/api/cron/jobs',
        queryParameters: const {'profile': 'all'},
      );
      _throwIfAuth(res);
      if (res.statusCode != 200) {
        lastError = 'getCronJobs HTTP ${res.statusCode}: ${res.data}';
        debugPrint(lastError);
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          message: lastError,
        );
      }
      final jobs = _parseJobs(res.data);
      if (jobs.isEmpty) {
        final body = res.data;
        debugPrint(
          'DashboardClient.getCronJobs → 0 jobs '
          '(bodyType=${body.runtimeType}, '
          'preview=${_previewBody(body)})',
        );
      } else {
        debugPrint('DashboardClient.getCronJobs → ${jobs.length} jobs');
      }
      return jobs;
    } on DioException catch (e) {
      lastError = e.message ?? e.toString();
      if (e.type == DioExceptionType.connectionError ||
          '$e'.contains('Connection refused')) {
        lastError =
            'Connection refused to ${profile.baseUrl} — is the gateway up?';
      }
      rethrow;
    }
  }

  String _previewBody(dynamic body) {
    try {
      final s = '$body';
      return s.length > 180 ? '${s.substring(0, 180)}…' : s;
    } catch (_) {
      return '?';
    }
  }

  List<HermesJob> _parseJobs(dynamic body) {
    dynamic data = body;
    // Some proxies double-encode JSON as a string.
    if (data is String) {
      final t = data.trim();
      if (t.isEmpty) return const [];
      try {
        data = jsonDecode(t);
      } catch (_) {
        return const [];
      }
    }

    List? raw;
    if (data is List) {
      raw = data;
    } else if (data is Map) {
      for (final key in const ['jobs', 'data', 'items', 'result']) {
        final value = data[key];
        if (value is List) {
          raw = value;
          break;
        }
      }
      // cron.manage list sometimes nests further.
      final nested = data['result'];
      if (raw == null && nested is Map) {
        final jobs = nested['jobs'];
        final rows = nested['data'];
        raw = jobs is List ? jobs : (rows is List ? rows : null);
      }
    }
    if (raw == null) return const [];

    final out = <HermesJob>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        final job = HermesJob.fromJson(item.cast<String, dynamic>());
        if (job.id.isNotEmpty) out.add(job);
      } catch (e) {
        debugPrint('DashboardClient: skip bad cron job row: $e item=$item');
      }
    }
    return out;
  }

  Future<HermesJob> getCronJob(String jobId) async {
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/cron/jobs/${Uri.encodeComponent(jobId)}',
    );
    _throwIfAuth(res);
    if (res.statusCode != 200 || res.data is! Map) {
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: 'getCronJob HTTP ${res.statusCode}',
      );
    }
    return HermesJob.fromJson((res.data as Map).cast<String, dynamic>());
  }

  Future<List<HermesSession>> listCronJobRuns(
    String jobId, {
    int limit = 20,
  }) async {
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/cron/jobs/${Uri.encodeComponent(jobId)}/runs',
      queryParameters: {'limit': limit.clamp(1, 100)},
    );
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: 'getCronJobRuns HTTP ${res.statusCode}',
      );
    }
    final body = res.data;
    final raw = body is Map && body['runs'] is List
        ? body['runs'] as List
        : const [];
    return raw
        .whereType<Map>()
        .map((row) => HermesSession.fromJson(row.cast<String, dynamic>()))
        .where((session) => session.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Desktop `pauseCronJob` — hermes.ts L787-791.
  Future<void> pauseJob(String jobId) async {
    final dio = await _ensureDio();
    final res = await dio.post<dynamic>(
      '/api/cron/jobs/${Uri.encodeComponent(jobId)}/pause',
    );
    _throwIfAuth(res);
  }

  /// Desktop `resumeCronJob` — hermes.ts L794-798.
  Future<void> resumeJob(String jobId) async {
    final dio = await _ensureDio();
    final res = await dio.post<dynamic>(
      '/api/cron/jobs/${Uri.encodeComponent(jobId)}/resume',
    );
    _throwIfAuth(res);
  }

  /// Desktop `triggerCronJob` — hermes.ts L801-805.
  Future<void> runJobNow(String jobId) async {
    final dio = await _ensureDio();
    final res = await dio.post<dynamic>(
      '/api/cron/jobs/${Uri.encodeComponent(jobId)}/trigger',
    );
    _throwIfAuth(res);
  }

  /// Desktop `getStatus` — hermes.ts L333-336.
  Future<Map<String, dynamic>> status() async {
    final dio = await _ensureDio();
    final res = await dio.get<Map<String, dynamic>>('/api/status');
    _throwIfAuth(res);
    return res.data ?? const {};
  }

  /// Apple Health user-plugin capability/status. A 404 means the gateway has
  /// not installed the optional bridge; it is not treated as an auth failure.
  Future<Map<String, dynamic>?> appleHealthStatus() async {
    final dio = await _ensureDio();
    final res = await dio.get<Map<String, dynamic>>(
      '/api/plugins/apple-health/status',
    );
    _throwIfAuth(res);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw DioException(requestOptions: res.requestOptions, response: res);
    }
    return res.data ?? const {};
  }

  Future<Map<String, dynamic>> syncAppleHealth(
    Map<String, dynamic> payload,
  ) async {
    final dio = await _ensureDio();
    final res = await dio.post<Map<String, dynamic>>(
      '/api/plugins/apple-health/sync',
      data: payload,
    );
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      throw DioException(requestOptions: res.requestOptions, response: res);
    }
    return res.data ?? const {};
  }

  Future<int> clearAppleHealth() async {
    final dio = await _ensureDio();
    final res = await dio.delete<Map<String, dynamic>>(
      '/api/plugins/apple-health/data',
    );
    _throwIfAuth(res);
    if (res.statusCode != 200) {
      throw DioException(requestOptions: res.requestOptions, response: res);
    }
    return (res.data?['deleted'] as num?)?.toInt() ?? 0;
  }

  /// Desktop `getGlobalModelOptions` — hermes.ts L872-895.
  Future<ModelOptionsResult> listModelOptions({
    bool explicitOnly = true,
    bool refresh = false,
  }) async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<Map<String, dynamic>>(
      '/api/model/options',
      queryParameters: {
        // Desktop default: explicitOnly !== false → explicit_only=1
        if (explicitOnly) 'explicit_only': '1',
        if (refresh) 'refresh': '1',
      },
    );
    _throwIfAuth(res);
    if (res.statusCode != 200 || res.data == null) {
      lastError = 'getGlobalModelOptions HTTP ${res.statusCode}: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final parsed = ModelOptionsResult.fromJson(res.data!);
    final n = parsed.providers.fold<int>(0, (a, p) => a + p.models.length);
    debugPrint(
      'DashboardClient.getGlobalModelOptions → '
      '${parsed.providers.length} providers, $n models '
      '(current=${parsed.provider}/${parsed.model})',
    );
    return parsed;
  }

  /// Reads an agent-written file for the in-app artifact viewer — Desktop's
  /// managed-files surface, `GET /api/files/read?path=...`
  /// (`hermes_cli/web_server.py:2413`). The bytes come back base64-encoded
  /// inside `data_url`; fetching them here (through the same authenticated
  /// client as every other dashboard call) means the artifact viewer's
  /// WebView never has to be pointed at a gateway URL, so session cookies
  /// never enter untrusted rendered content.
  ///
  /// Throws [ManagedFileException] for the three documented failure modes
  /// (404 missing, 403 sensitive-path block, 413 over the gateway's size
  /// cap) so callers can show a specific message instead of a generic
  /// network error.
  ///
  /// Deliberately does **not** route through [_throwIfAuth] for 403 the way
  /// every other method here does: on this endpoint a 403 means
  /// `_is_sensitive_path` blocked the specific path
  /// (`hermes_cli/web_server.py`), not an expired session — conflating the
  /// two would surface a "sign in again" prompt for a request that has
  /// nothing to do with auth. 401 still goes through the shared auth check.
  Future<ManagedFileContent> readManagedFile(String path) async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/files/read',
      queryParameters: {'path': path},
    );
    if (res.statusCode == 401) _throwIfAuth(res);
    final status = res.statusCode ?? 0;
    if (status == 404) {
      lastError = 'readManagedFile: file not found';
      throw ManagedFileException(ManagedFileErrorKind.notFound, lastError!);
    }
    if (status == 403) {
      lastError = 'readManagedFile: access denied';
      throw ManagedFileException(ManagedFileErrorKind.forbidden, lastError!);
    }
    if (status == 413) {
      lastError = 'readManagedFile: file is too large';
      throw ManagedFileException(ManagedFileErrorKind.tooLarge, lastError!);
    }
    if (status != 200 || res.data is! Map) {
      lastError = 'readManagedFile HTTP $status: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = (res.data as Map).cast<String, dynamic>();
    return ManagedFileContent.fromJson(body);
  }

  /// Resolves a gateway-local generated image for a remote phone.
  ///
  /// `image_generate` returns a path on the Hermes host. That path is useful
  /// to Desktop but cannot be opened directly by iOS/Android, so the phone
  /// asks the authenticated filesystem bridge for a data URL. This matches
  /// current Desktop remote mode: plugin providers are allowed to place an
  /// image outside the narrow `/api/media` roots, while `profile` +
  /// `session_id` still make the gateway validate the owning session before
  /// reading the path. Keeping this request on [DashboardClient] also ensures
  /// the host path is never exposed to an unauthenticated browser/WebView.
  Future<String> readGeneratedImage(
    String path, {
    String? profileName,
    String? sessionId,
  }) async {
    lastError = null;
    final dio = await _ensureDio();
    final res = await dio.get<dynamic>(
      '/api/fs/read-data-url',
      queryParameters: {
        'path': path,
        if (profileName?.trim().isNotEmpty == true)
          'profile': profileName!.trim(),
        if (sessionId?.trim().isNotEmpty == true)
          'session_id': sessionId!.trim(),
      },
    );
    _throwIfAuth(res);
    final status = res.statusCode ?? 0;
    if (status != 200 || res.data is! Map) {
      lastError = 'readGeneratedImage HTTP $status: ${res.data}';
      throw DioException(
        requestOptions: res.requestOptions,
        response: res,
        message: lastError,
      );
    }
    final body = (res.data as Map).cast<String, dynamic>();
    final dataUrl = '${body['dataUrl'] ?? body['data_url'] ?? ''}'.trim();
    if (!dataUrl.startsWith('data:image/')) {
      lastError = 'readGeneratedImage: gateway returned invalid image data';
      throw FormatException(lastError!);
    }
    return dataUrl;
  }
}

/// Result of `GET /api/files/read` — bytes always arrive base64-encoded
/// inside `dataUrl` (`data:<mime>;base64,<...>`), per
/// `hermes_cli/web_server.py:2413`.
class ManagedFileContent {
  const ManagedFileContent({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    required this.dataUrl,
  });

  final String name;
  final String path;
  final int size;
  final String mimeType;
  final String dataUrl;

  factory ManagedFileContent.fromJson(Map<String, dynamic> json) {
    final rawSize = json['size'];
    final size = rawSize is int
        ? rawSize
        : int.tryParse('${rawSize ?? ''}') ?? 0;
    return ManagedFileContent(
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      size: size,
      mimeType: '${json['mime_type'] ?? 'application/octet-stream'}',
      dataUrl: '${json['data_url'] ?? ''}',
    );
  }

  /// Decodes the base64 payload as UTF-8 text. Returns an empty string
  /// (rather than throwing) on a missing/malformed data URL, so callers can
  /// show an error state instead of crashing on a hostile or truncated
  /// response.
  ///
  /// The header is checked rather than skipped: the gateway always emits
  /// `data:<mime>;base64,<...>` (`hermes_cli/web_server.py:2413`), so a
  /// response whose data URL is shaped differently is treated as malformed
  /// instead of being guessed at. The declared MIME type inside the header
  /// is deliberately *not* consulted — it never decides how the bytes are
  /// decoded, and it never decides which renderer they reach (see
  /// `rendererKindFor`).
  String decodeText() {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return '';
    final header = dataUrl.substring(0, comma).toLowerCase();
    if (!header.startsWith('data:') || !header.endsWith(';base64')) return '';
    try {
      // `allowMalformed`: a stray byte in an otherwise readable file should
      // degrade to U+FFFD, not blank the whole viewer.
      return utf8.decode(
        base64.decode(dataUrl.substring(comma + 1)),
        allowMalformed: true,
      );
    } catch (_) {
      return '';
    }
  }
}

enum ManagedFileErrorKind { notFound, forbidden, tooLarge }

class ManagedFileException implements Exception {
  ManagedFileException(this.kind, this.message);
  final ManagedFileErrorKind kind;
  final String message;
  @override
  String toString() => message;
}

/// Dashboard / Desktop model picker payload.
class ModelOptionsResult {
  const ModelOptionsResult({
    this.model,
    this.provider,
    this.providers = const [],
  });

  final String? model;
  final String? provider;
  final List<ModelOptionProvider> providers;

  factory ModelOptionsResult.fromJson(Map<String, dynamic> json) {
    final raw = json['providers'];
    final providers = <ModelOptionProvider>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final p = ModelOptionProvider.fromJson(item.cast<String, dynamic>());
          if (p.slug.isNotEmpty) providers.add(p);
        }
      }
    }
    return ModelOptionsResult(
      model: json['model']?.toString(),
      provider: json['provider']?.toString(),
      providers: providers,
    );
  }

  Map<String, dynamic> toJson() => {
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    'providers': providers.map((p) => p.toJson()).toList(),
  };

  /// Catalog equality (provider slugs + model ids + capability flags).
  bool sameCatalogAs(ModelOptionsResult other) {
    if (providers.length != other.providers.length) return false;
    for (var i = 0; i < providers.length; i++) {
      final a = providers[i];
      final b = other.providers[i];
      if (a.slug != b.slug || a.name != b.name) return false;
      if (a.models.length != b.models.length) return false;
      for (var j = 0; j < a.models.length; j++) {
        if (a.models[j] != b.models[j]) return false;
      }
      if (!_sameCapabilities(a.capabilities, b.capabilities)) return false;
    }
    return true;
  }

  /// True when every provider with models has a non-empty capabilities map
  /// (Desktop inventory `capabilities=True` on /api/model/options).
  bool get hasCapabilityMaps {
    for (final p in providers) {
      if (p.models.isEmpty) continue;
      if (p.capabilities.isEmpty) return false;
    }
    return providers.any((p) => p.models.isNotEmpty);
  }

  static bool _sameCapabilities(
    Map<String, ModelCapabilities> a,
    Map<String, ModelCapabilities> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final o = b[e.key];
      if (o == null ||
          o.fast != e.value.fast ||
          o.reasoning != e.value.reasoning ||
          o.thinking != e.value.thinking ||
          o.defaultReasoningEffort != e.value.defaultReasoningEffort ||
          !_sameReasoningEfforts(
            o.reasoningEfforts,
            e.value.reasoningEfforts,
          )) {
        return false;
      }
    }
    return true;
  }

  static bool _sameReasoningEfforts(
    List<ReasoningEffortOption>? a,
    List<ReasoningEffortOption>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].effort != b[i].effort || a[i].description != b[i].description) {
        return false;
      }
    }
    return true;
  }

  /// Flat list for simple pickers: `provider/model` or just model id.
  List<HermesModelInfo> asFlatModels() {
    final out = <HermesModelInfo>[];
    for (final p in providers) {
      if (p.models.isEmpty) continue;
      for (final m in p.models) {
        if (m.isEmpty) continue;
        out.add(
          HermesModelInfo(id: m, ownedBy: p.name.isNotEmpty ? p.name : p.slug),
        );
      }
    }
    return out;
  }
}

/// Resolve the provider that actually advertises [model].
///
/// The selected model and provider are persisted independently on the phone,
/// so a provider can become stale when a gateway default/profile changes. Keep
/// a still-valid preferred provider, but repair that mismatch before creating
/// a session or submitting a turn. This is especially important for linked
/// subscription providers: sending a paid model through the wrong provider
/// falls back to that provider's billing route instead of the subscription.
String? providerForModel(
  ModelOptionsResult options,
  String model, {
  String? preferred,
}) {
  final wanted = model.trim().toLowerCase();
  if (wanted.isEmpty) return preferred;

  bool contains(ModelOptionProvider provider) => provider.models.any(
    (candidate) => candidate.trim().toLowerCase() == wanted,
  );

  if (preferred != null && preferred.trim().isNotEmpty) {
    for (final provider in options.providers) {
      if (provider.slug == preferred && contains(provider)) {
        return provider.slug;
      }
    }
  }
  for (final provider in options.providers) {
    if (contains(provider)) return provider.slug;
  }
  // Preserve custom/unknown providers when the catalog is incomplete or
  // offline; a known mismatch was handled above.
  return preferred;
}

class ReasoningEffortOption {
  const ReasoningEffortOption({required this.effort, this.description});

  final String effort;
  final String? description;

  Map<String, dynamic> toJson() => {
    'effort': effort,
    if (description != null && description!.isNotEmpty)
      'description': description,
  };
}

/// Per-model controls from inventory (`capabilities: true` on model.options).
class ModelCapabilities {
  const ModelCapabilities({
    this.fast = false,
    this.reasoning = true,
    this.thinking,
    this.reasoningEfforts,
    this.defaultReasoningEffort,
  });

  final bool fast;
  final bool reasoning;
  final bool? thinking;

  /// Null means an older server that only returned the reasoning boolean.
  /// An explicit empty list means the server offers no effort selector.
  final List<ReasoningEffortOption>? reasoningEfforts;
  final String? defaultReasoningEffort;

  // Do not infer a user-controllable Thinking toggle from the coarse
  // `reasoning` capability. Fixed-thinking models reason but cannot be
  // switched off; only an explicit server field may expose the toggle.
  bool get thinkingSupported => thinking == true;

  factory ModelCapabilities.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const ModelCapabilities(fast: false, reasoning: false);
    }
    final reasoning = json.containsKey('reasoning')
        ? json['reasoning'] == true
        : json['supports_reasoning'] == true;
    final rawEfforts =
        json['reasoning_efforts'] ??
        json['reasoning_effort_options'] ??
        json['effort_options'] ??
        json['supported_reasoning_levels'];
    List<ReasoningEffortOption>? efforts;
    if (rawEfforts is List) {
      efforts = [];
      final seen = <String>{};
      for (final raw in rawEfforts) {
        String effort;
        String? description;
        if (raw is Map) {
          effort = '${raw['effort'] ?? raw['id'] ?? raw['value'] ?? ''}'
              .trim()
              .toLowerCase();
          description = raw['description']?.toString().trim();
        } else {
          effort = '$raw'.trim().toLowerCase();
        }
        if (effort.isEmpty || !seen.add(effort)) continue;
        efforts.add(
          ReasoningEffortOption(
            effort: effort,
            description: description?.isEmpty == true ? null : description,
          ),
        );
      }
    }
    final thinking = json.containsKey('thinking')
        ? json['thinking'] == true
        : json.containsKey('supports_thinking')
        ? json['supports_thinking'] == true
        : null;
    final defaultEffort =
        '${json['default_reasoning_effort'] ?? json['default_reasoning_level'] ?? ''}'
            .trim()
            .toLowerCase();
    return ModelCapabilities(
      fast: json['fast'] == true,
      reasoning: reasoning,
      thinking: thinking,
      reasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort.isEmpty ? null : defaultEffort,
    );
  }

  Map<String, dynamic> toJson() => {
    'fast': fast,
    'reasoning': reasoning,
    if (thinking != null) 'thinking': thinking,
    if (reasoningEfforts != null)
      'reasoning_efforts': reasoningEfforts!
          .map((option) => option.toJson())
          .toList(),
    if (defaultReasoningEffort != null)
      'default_reasoning_effort': defaultReasoningEffort,
  };
}

class ModelOptionProvider {
  const ModelOptionProvider({
    required this.slug,
    required this.name,
    this.models = const [],
    this.warning,
    this.authenticated,
    this.capabilities = const {},
  });

  final String slug;
  final String name;
  final List<String> models;
  final String? warning;
  final bool? authenticated;

  /// model id → {fast, reasoning}
  final Map<String, ModelCapabilities> capabilities;

  ModelCapabilities capsFor(String modelId) {
    final id = modelId.trim();
    final hit = capabilities[id];
    if (hit != null) return hit;
    // Case-insensitive fallback (some catalogs differ on casing).
    final lower = id.toLowerCase();
    for (final e in capabilities.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    // A `-fast` sibling is a transport/model variant of its base row. Desktop
    // evaluates capability controls against that base family, so the variant
    // must retain Thinking even when inventory only reports caps for the base.
    if (lower.endsWith('-fast')) {
      final base = lower.substring(0, lower.length - '-fast'.length);
      for (final e in capabilities.entries) {
        if (e.key.trim().toLowerCase() == base) return e.value;
      }
    }
    // An explicit map that omits this model means the backend says there are
    // no supported controls. Do not invent Thinking in that case.
    if (capabilities.isNotEmpty) {
      return const ModelCapabilities(fast: false, reasoning: false);
    }
    // No map at all is an older/partial payload, not a negative capability
    // answer. Desktop keeps the reasoning control visible in this case and
    // only gates Fast on an explicit signal or a `-fast` sibling model.
    return const ModelCapabilities(fast: false, reasoning: true);
  }

  factory ModelOptionProvider.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    final models = <String>[];
    if (rawModels is List) {
      for (final m in rawModels) {
        final s = '$m'.trim();
        if (s.isNotEmpty) models.add(s);
      }
    }
    final caps = <String, ModelCapabilities>{};
    final rawCaps = json['capabilities'];
    if (rawCaps is Map) {
      for (final e in rawCaps.entries) {
        final id = '${e.key}'.trim();
        if (id.isEmpty) continue;
        final v = e.value;
        if (v is Map) {
          final map = v.cast<String, dynamic>();
          caps[id] = ModelCapabilities.fromJson(map);
        }
      }
    }
    return ModelOptionProvider(
      slug: '${json['slug'] ?? ''}'.trim(),
      name: '${json['name'] ?? json['slug'] ?? ''}'.trim(),
      models: models,
      warning: json['warning']?.toString(),
      authenticated: json['authenticated'] is bool
          ? json['authenticated'] as bool
          : null,
      capabilities: caps,
    );
  }

  Map<String, dynamic> toJson() => {
    'slug': slug,
    'name': name,
    'models': models,
    if (warning != null) 'warning': warning,
    if (authenticated != null) 'authenticated': authenticated,
    if (capabilities.isNotEmpty)
      'capabilities': {
        for (final e in capabilities.entries) e.key: e.value.toJson(),
      },
  };
}

class DashboardAuthException implements Exception {
  DashboardAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
