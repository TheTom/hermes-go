/// Shared DTOs for the Hermes API server surface used by the mobile connector.
library;

/// One saved Hermes gateway the phone can talk to.
///
/// Desktop remote flow (not API_SERVER_KEY):
/// - authMode `session` → username/password login → cookies + ws-ticket
/// - authMode `open`    → loopback/insecure gateway, no password gate
///
/// [apiKey] is only for rare legacy token mode; password gateways leave it empty.
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.baseUrl,
    this.apiKey = '',
    this.authMode = 'session',
    this.username,
    this.provider,
    this.label,
    this.displayName,
    this.createdAt,
    this.lastUsedAt,
    this.botModeAvailable = false,
  });

  /// Stable client-side id (uuid). Not the host session id.
  final String id;

  /// User-facing name ("Home", "Spark", "VPS"). Falls back to host/url.
  final String? label;

  final String baseUrl;

  /// Legacy static token only. Empty for password/session auth.
  final String apiKey;

  /// `session` (password/OAuth cookies), `open` (no gate), `token` (legacy).
  final String authMode;

  /// Signed-in username (password providers). Not the password.
  final String? username;

  /// Auth provider name used at login (e.g. `basic`).
  final String? provider;

  /// Optional host-advertised model / nickname from capabilities probe.
  final String? displayName;

  final String? createdAt;
  final String? lastUsedAt;

  /// Sticky server capability hint used to keep bottom navigation stable.
  /// Once Bot Mode is confirmed for a saved gateway, transient probes no
  /// longer make its tab appear late or disappear between launches.
  final bool botModeAvailable;

  bool get usesSessionCookies =>
      authMode == 'session' || authMode == 'oauth' || authMode == 'password';

  bool get hasLegacyToken => apiKey.trim().isNotEmpty;

  String get displayLabel {
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l;
    final u = username?.trim();
    if (u != null && u.isNotEmpty) {
      try {
        return '$u@${Uri.parse(baseUrl).host}';
      } catch (_) {
        return u;
      }
    }
    final d = displayName?.trim();
    if (d != null && d.isNotEmpty) return d;
    try {
      return Uri.parse(baseUrl).host;
    } catch (_) {
      return baseUrl;
    }
  }

  ConnectionProfile copyWith({
    String? id,
    String? label,
    String? baseUrl,
    String? apiKey,
    String? authMode,
    String? username,
    String? provider,
    String? displayName,
    String? createdAt,
    String? lastUsedAt,
    bool? botModeAvailable,
  }) {
    return ConnectionProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      authMode: authMode ?? this.authMode,
      username: username ?? this.username,
      provider: provider ?? this.provider,
      displayName: displayName ?? this.displayName,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      botModeAvailable: botModeAvailable ?? this.botModeAvailable,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'authMode': authMode,
    if (username != null) 'username': username,
    if (provider != null) 'provider': provider,
    if (label != null) 'label': label,
    if (displayName != null) 'displayName': displayName,
    if (createdAt != null) 'createdAt': createdAt,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
    if (botModeAvailable) 'botModeAvailable': true,
  };

  /// Same shape as [toJson] but with [apiKey] (the legacy static gateway
  /// token — a bearer-equivalent secret, see [hasLegacyToken]) omitted.
  ///
  /// Use this — never [toJson] — for anything written outside platform
  /// secure storage (Keychain / EncryptedSharedPreferences). Today that's
  /// [ConnectionStore]'s plaintext Application Support mirror file.
  Map<String, dynamic> toMirrorJson() => {
    'id': id,
    'baseUrl': baseUrl,
    'authMode': authMode,
    if (username != null) 'username': username,
    if (provider != null) 'provider': provider,
    if (label != null) 'label': label,
    if (displayName != null) 'displayName': displayName,
    if (createdAt != null) 'createdAt': createdAt,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
    if (botModeAvailable) 'botModeAvailable': true,
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? ''}'.trim();
    final key = '${json['apiKey'] ?? ''}';
    // Infer auth mode for older saved profiles.
    var mode = '${json['authMode'] ?? ''}'.trim();
    if (mode.isEmpty) {
      mode = key.isNotEmpty ? 'token' : 'session';
    }
    return ConnectionProfile(
      id: id.isEmpty ? 'legacy' : id,
      label: _asString(json['label']),
      baseUrl: '${json['baseUrl'] ?? ''}'.trim(),
      apiKey: key,
      authMode: mode,
      username: _asString(json['username']),
      provider: _asString(json['provider']),
      displayName: _asString(json['displayName']),
      createdAt: json['createdAt']?.toString(),
      lastUsedAt: json['lastUsedAt']?.toString(),
      botModeAvailable: json['botModeAvailable'] == true,
    );
  }
}

/// Multi-gateway book on device.
///
/// - [gateways] — all saved connections (v1: length 0 or 1)
/// - [defaultGatewayId] — boots the app / "home" gateway
/// - [activeGatewayId] — currently selected for Sessions/Jobs/Chat
///
/// Active and default can diverge later (browse another host without changing
/// default). v1 keeps them equal.
class GatewayBook {
  const GatewayBook({
    this.gateways = const [],
    this.defaultGatewayId,
    this.activeGatewayId,
  });

  static const empty = GatewayBook();

  final List<ConnectionProfile> gateways;
  final String? defaultGatewayId;
  final String? activeGatewayId;

  bool get isEmpty => gateways.isEmpty;
  bool get isNotEmpty => gateways.isNotEmpty;

  ConnectionProfile? get active => _byId(activeGatewayId);
  ConnectionProfile? get defaultGateway => _byId(defaultGatewayId);

  /// Boot target: active if set, else default, else sole gateway.
  ConnectionProfile? get resolved {
    return active ??
        defaultGateway ??
        (gateways.length == 1 ? gateways.first : null);
  }

  ConnectionProfile? _byId(String? id) {
    if (id == null) return null;
    for (final g in gateways) {
      if (g.id == id) return g;
    }
    return null;
  }

  GatewayBook copyWith({
    List<ConnectionProfile>? gateways,
    String? defaultGatewayId,
    String? activeGatewayId,
    bool clearDefault = false,
    bool clearActive = false,
  }) {
    return GatewayBook(
      gateways: gateways ?? this.gateways,
      defaultGatewayId: clearDefault
          ? null
          : (defaultGatewayId ?? this.defaultGatewayId),
      activeGatewayId: clearActive
          ? null
          : (activeGatewayId ?? this.activeGatewayId),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'gateways': gateways.map((g) => g.toJson()).toList(),
    'defaultGatewayId': defaultGatewayId,
    'activeGatewayId': activeGatewayId,
  };

  /// Mirror-safe encoding — every gateway's secret fields are dropped (see
  /// [ConnectionProfile.toMirrorJson]). This is what [ConnectionStore]'s
  /// plaintext Application Support mirror must be built from; [toJson] is
  /// for the secure-storage copy only.
  Map<String, dynamic> toMirrorJson() => {
    'version': 2,
    'gateways': gateways.map((g) => g.toMirrorJson()).toList(),
    'defaultGatewayId': defaultGatewayId,
    'activeGatewayId': activeGatewayId,
  };

  factory GatewayBook.fromJson(Map<String, dynamic> json) {
    final rawList = json['gateways'];
    final list = <ConnectionProfile>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map) {
          final p = ConnectionProfile.fromJson(
            item.map((k, v) => MapEntry('$k', v)),
          );
          // Session/password profiles may have empty apiKey (cookies hold auth).
          if (p.baseUrl.isNotEmpty) {
            list.add(p);
          }
        }
      }
    }
    String? def = _asString(json['defaultGatewayId']);
    String? act = _asString(json['activeGatewayId']);
    if (def != null && !list.any((g) => g.id == def)) def = null;
    if (act != null && !list.any((g) => g.id == act)) act = null;
    if (list.length == 1) {
      def ??= list.first.id;
      act ??= list.first.id;
    }
    return GatewayBook(
      gateways: list,
      defaultGatewayId: def,
      activeGatewayId: act,
    );
  }
}

class HermesSession {
  const HermesSession({
    required this.id,
    this.source,
    this.userId,
    this.model,
    this.title,
    this.startedAt,
    this.endedAt,
    this.endReason,
    this.messageCount,
    this.toolCallCount,
    this.lastActive,
    this.preview,
    this.parentSessionId,
  });

  final String id;
  final String? source;
  final String? userId;
  final String? model;
  final String? title;
  final String? startedAt;
  final String? endedAt;
  final String? endReason;
  final int? messageCount;
  final int? toolCallCount;
  final String? lastActive;
  final String? preview;
  final String? parentSessionId;

  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final p = preview?.trim();
    if (p != null && p.isNotEmpty) {
      return p.length > 48 ? '${p.substring(0, 48)}…' : p;
    }
    return id;
  }

  factory HermesSession.fromJson(Map<String, dynamic> json) {
    return HermesSession(
      id: '${json['id'] ?? ''}',
      source: _asString(json['source']),
      userId: _asString(json['user_id']),
      model: _asString(json['model']),
      title: _asString(json['title']),
      startedAt: json['started_at']?.toString(),
      endedAt: json['ended_at']?.toString(),
      endReason: _asString(json['end_reason']),
      messageCount: _asInt(json['message_count']),
      toolCallCount: _asInt(json['tool_call_count']),
      lastActive: json['last_active']?.toString(),
      preview: _asString(json['preview']),
      parentSessionId: _asString(json['parent_session_id']),
    );
  }
}

/// Runtime identity returned by the gateway for one live/resumed session.
/// This is deliberately separate from the global model preference: opening a
/// historical chat must restore the model/provider/options that chat actually
/// used, even when another device has since changed the global default.
class SessionRuntimeState {
  const SessionRuntimeState({
    this.model,
    this.provider,
    this.reasoningEffort,
    this.fastMode,
  });

  final String? model;
  final String? provider;
  final String? reasoningEffort;
  final bool? fastMode;

  factory SessionRuntimeState.fromJson(Map<String, dynamic>? raw) {
    if (raw == null) return const SessionRuntimeState();
    final model = raw['model']?.toString().trim();
    final provider = raw['provider']?.toString().trim();
    final effort = raw['reasoning_effort']?.toString().trim();
    final fastRaw = raw['fast'];
    final tier = raw['service_tier']?.toString().trim().toLowerCase();
    return SessionRuntimeState(
      model: model == null || model.isEmpty ? null : model,
      provider: provider == null || provider.isEmpty ? null : provider,
      reasoningEffort: effort == null || effort.isEmpty ? null : effort,
      fastMode: fastRaw is bool ? fastRaw : (tier == 'priority' ? true : null),
    );
  }
}

/// A dangerous-command approval parked by the gateway while a turn waits for
/// an explicit user decision. Choices are supplied by the server so clients do
/// not invent permissions the active Hermes version will not honor.
class GatewayApprovalRequest {
  const GatewayApprovalRequest({
    required this.sessionId,
    required this.command,
    required this.description,
    required this.choices,
  });

  final String sessionId;
  final String command;
  final String description;
  final List<String> choices;

  factory GatewayApprovalRequest.fromJson(
    Map<String, dynamic> raw, {
    required String sessionId,
  }) {
    final supplied = raw['choices'];
    final choices = supplied is List
        ? supplied
              .map((choice) => '$choice'.trim().toLowerCase())
              .where((choice) => choice.isNotEmpty)
              .toList(growable: false)
        : raw['smart_denied'] == true
        ? const ['once', 'deny']
        : raw['allow_permanent'] == false
        ? const ['once', 'session', 'deny']
        : const ['once', 'session', 'always', 'deny'];
    return GatewayApprovalRequest(
      sessionId: sessionId,
      command: '${raw['command'] ?? ''}'.trim(),
      description: '${raw['description'] ?? 'Approval needed'}'.trim(),
      choices: choices,
    );
  }
}

class HermesMessage {
  const HermesMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content,
    this.toolCallId,
    this.toolCalls,
    this.toolName,
    this.timestamp,
    this.tokenCount,
    this.finishReason,
    this.reasoning,
    this.displayKind,
  });

  final String id;
  final String sessionId;
  final String role;
  final String? content;
  final String? toolCallId;
  final dynamic toolCalls;
  final String? toolName;
  final String? timestamp;
  final int? tokenCount;
  final String? finishReason;
  final String? reasoning;

  /// Gateway `display_kind` tag (e.g. `model_switch`, `personality_switch`,
  /// `auto_continue`, `async_delegation_complete`, `hidden`, …) — set on
  /// synthetic timeline markers that ride the wire with `role: "user"` but
  /// are not user-originated turns. Null for ordinary messages.
  final String? displayKind;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isTool => role == 'tool' || role == 'function';
  bool get isSystem => role == 'system' || role == 'slash';

  /// Model-visible user turn — mirrors the gateway's
  /// `_history_user_indices` filter (`role == "user" and not
  /// m.get("display_kind")`, `tui_gateway/methods_prompt.py`). Synthetic
  /// timeline markers carry `role: "user"` but must NOT count as a real user
  /// turn for ordinal/edit/retry/resend math — counting them drifts the
  /// client's `truncate_before_user_ordinal` away from the gateway's live
  /// turn count and gets refused with 4018 ("target user message is no
  /// longer in session history").
  bool get isVisibleUser =>
      role == 'user' && (displayKind == null || displayKind!.isEmpty);

  factory HermesMessage.fromJson(Map<String, dynamic> json) {
    return HermesMessage(
      id: '${json['id'] ?? ''}',
      sessionId: '${json['session_id'] ?? ''}',
      role: '${json['role'] ?? 'assistant'}',
      content: _contentToString(json['content']),
      toolCallId: _asString(json['tool_call_id']),
      toolCalls: json['tool_calls'],
      toolName: _asString(json['tool_name']),
      timestamp: json['timestamp']?.toString(),
      tokenCount: _asInt(json['token_count']),
      finishReason: _asString(json['finish_reason']),
      reasoning: _contentToString(
        json['reasoning'] ?? json['reasoning_content'],
      ),
      displayKind: _asString(json['display_kind']),
    );
  }

  HermesMessage copyWith({String? content, String? id}) {
    return HermesMessage(
      id: id ?? this.id,
      sessionId: sessionId,
      role: role,
      content: content ?? this.content,
      toolCallId: toolCallId,
      toolCalls: toolCalls,
      toolName: toolName,
      timestamp: timestamp,
      tokenCount: tokenCount,
      finishReason: finishReason,
      reasoning: reasoning,
      displayKind: displayKind,
    );
  }
}

class HermesModelInfo {
  const HermesModelInfo({required this.id, this.object, this.ownedBy});

  final String id;
  final String? object;
  final String? ownedBy;

  factory HermesModelInfo.fromJson(Map<String, dynamic> json) {
    return HermesModelInfo(
      id: '${json['id'] ?? ''}',
      object: _asString(json['object']),
      ownedBy: _asString(json['owned_by']),
    );
  }
}

/// Installed skill from `GET /api/skills` / `skills.manage` list.
///
/// Invoked as a slash command: `/{name}` (or `/{name} <instruction>`).
class HermesSkill {
  const HermesSkill({
    required this.name,
    this.description,
    this.category,
    this.enabled = true,
    this.provenance,
    this.usage,
  });

  final String name;
  final String? description;
  final String? category;
  final bool enabled;

  /// `agent` | `bundled` | `hub` (Desktop SkillInfo).
  final String? provenance;
  final int? usage;

  /// Slash form including leading `/`.
  String get slashCommand {
    final n = name.trim();
    if (n.isEmpty) return '/';
    return n.startsWith('/') ? n : '/$n';
  }

  factory HermesSkill.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? json['slug'] ?? json['id'] ?? ''}'.trim();
    final enabledRaw = json['enabled'];
    final enabled = enabledRaw is bool
        ? enabledRaw
        : enabledRaw == null
        ? true
        : '$enabledRaw' != 'false' && '$enabledRaw' != '0';
    final usageRaw = json['usage'] ?? json['activity'];
    int? usage;
    if (usageRaw is num) {
      usage = usageRaw.round();
    } else if (usageRaw != null) {
      usage = int.tryParse('$usageRaw');
    }
    return HermesSkill(
      name: name,
      description: (json['description'] ?? json['desc'] ?? json['summary'])
          ?.toString(),
      category: (json['category'] ?? json['group'])?.toString(),
      enabled: enabled,
      provenance: json['provenance']?.toString(),
      usage: usage,
    );
  }
}

/// A slash command from `GET /api/commands`.
///
/// Invoked as a slash command: `/{name}` (or `/{name} <args>`).
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.description,
    required this.category,
    this.aliases = const [],
    this.argsHint = '',
    this.cliOnly = false,
    this.gatewayOnly = false,
    this.configGated = false,
  });

  final String name;
  final String description;
  final String category;
  final List<String> aliases;
  final String argsHint;
  final bool cliOnly;
  final bool gatewayOnly;
  final bool configGated;

  /// Slash form including leading `/`.
  String get slashCommand {
    final n = name.trim();
    if (n.isEmpty) return '/';
    return n.startsWith('/') ? n : '/$n';
  }

  factory SlashCommand.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? json['slug'] ?? json['id'] ?? ''}'.trim();
    final aliasesRaw = json['aliases'];
    final aliases = aliasesRaw is List
        ? aliasesRaw.map((a) => '$a').where((a) => a.isNotEmpty).toList()
        : const <String>[];
    bool asBool(dynamic raw) {
      if (raw is bool) return raw;
      if (raw == null) return false;
      return '$raw' == 'true' || '$raw' == '1';
    }

    return SlashCommand(
      name: name,
      description:
          (json['description'] ?? json['desc'] ?? json['summary'] ?? '')
              .toString(),
      category: (json['category'] ?? json['group'] ?? '').toString(),
      aliases: aliases,
      argsHint: (json['args_hint'] ?? json['argsHint'] ?? '').toString(),
      cliOnly: asBool(json['cli_only'] ?? json['cliOnly']),
      gatewayOnly: asBool(json['gateway_only'] ?? json['gatewayOnly']),
      configGated: asBool(json['config_gated'] ?? json['configGated']),
    );
  }
}

class HermesJob {
  const HermesJob({
    required this.id,
    this.name,
    this.schedule,
    this.prompt,
    this.script,
    this.deliver,
    this.enabled,
    this.state,
    this.lastRunAt,
    this.lastStatus,
    this.nextRunAt,
    this.lastError,
    this.lastDeliveryError,
    this.model,
    this.provider,
    this.modelSnapshot,
    this.providerSnapshot,
    this.createdAt,
    this.pausedAt,
    this.pausedReason,
    this.skill,
    this.skills = const [],
    this.workdir,
    this.contextFrom,
    this.enabledToolsets = const [],
    this.noAgent,
    this.completedRuns,
    this.totalRuns,
    this.raw = const {},
  });

  final String id;
  final String? name;
  final String? schedule;
  final String? prompt;
  final String? script;
  final String? deliver;
  final bool? enabled;
  final String? state;
  final String? lastRunAt;
  final String? lastStatus;
  final String? nextRunAt;
  final String? lastError;
  final String? lastDeliveryError;
  final String? model;
  final String? provider;
  final String? modelSnapshot;
  final String? providerSnapshot;
  final String? createdAt;
  final String? pausedAt;
  final String? pausedReason;
  final String? skill;
  final List<String> skills;
  final String? workdir;
  final String? contextFrom;
  final List<String> enabledToolsets;
  final bool? noAgent;
  final int? completedRuns;
  final int? totalRuns;

  /// Original server row retained for forward-compatible offline caching.
  /// Typed fields above drive today's UI; a newer server can add data without
  /// the phone erasing it on the next cache write.
  final Map<String, dynamic> raw;

  String get displayName {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return id;
  }

  factory HermesJob.fromJson(Map<String, dynamic> json) {
    // Cron payloads vary slightly; accept both nested and flat shapes.
    // Desktop CronJob.schedule is often `{ kind, expr, display }`.
    // Never `as String?` cast — non-string name/prompt would throw and drop
    // the entire jobs list.
    final nested = json['job'];
    final map = nested is Map
        ? nested.map((k, v) => MapEntry('$k', v))
        : Map<String, dynamic>.from(json);

    String? schedule;
    final rawSchedule =
        map['schedule'] ?? map['schedule_display'] ?? map['cron'];
    if (rawSchedule is Map) {
      schedule =
          (rawSchedule['display'] ?? rawSchedule['expr'] ?? rawSchedule['kind'])
              ?.toString();
    } else if (rawSchedule != null) {
      schedule = '$rawSchedule';
    }

    String? str(dynamic v) {
      if (v == null) return null;
      if (v is String) return v;
      if (v is Map || v is List) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }

    final id = str(map['id'] ?? map['job_id'] ?? map['jobId']) ?? '';
    final rawSkills = map['skills'];
    final skills = rawSkills is List
        ? rawSkills
              .map(str)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final rawToolsets = map['enabled_toolsets'];
    final enabledToolsets = rawToolsets is List
        ? rawToolsets
              .map(str)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final repeat = map['repeat'];
    int? integer(dynamic value) {
      if (value is int) return value;
      return int.tryParse('${value ?? ''}');
    }

    return HermesJob(
      id: id,
      name: str(map['name'] ?? map['title'] ?? map['label']),
      schedule: schedule,
      prompt: str(map['prompt']),
      script: str(map['script']),
      deliver: str(map['deliver'] ?? map['delivery']),
      enabled: map['enabled'] is bool
          ? map['enabled'] as bool
          : map['enabled']?.toString().toLowerCase() == 'true',
      state: str(map['state'] ?? map['status']),
      lastRunAt: str(map['last_run_at'] ?? map['last_run'] ?? map['lastRunAt']),
      lastStatus: str(map['last_status'] ?? map['last_run_status']),
      nextRunAt: str(map['next_run_at'] ?? map['next_run'] ?? map['nextRunAt']),
      lastError: str(map['last_error'] ?? map['lastError']),
      lastDeliveryError: str(
        map['last_delivery_error'] ?? map['lastDeliveryError'],
      ),
      model: str(map['model']),
      provider: str(map['provider']),
      modelSnapshot: str(map['model_snapshot']),
      providerSnapshot: str(map['provider_snapshot']),
      createdAt: str(map['created_at'] ?? map['createdAt']),
      pausedAt: str(map['paused_at'] ?? map['pausedAt']),
      pausedReason: str(map['paused_reason'] ?? map['pausedReason']),
      skill: str(map['skill']),
      skills: skills,
      workdir: str(map['workdir']),
      contextFrom: str(map['context_from']),
      enabledToolsets: enabledToolsets,
      noAgent: map['no_agent'] is bool ? map['no_agent'] as bool : null,
      completedRuns: repeat is Map ? integer(repeat['completed']) : null,
      totalRuns: repeat is Map ? integer(repeat['times']) : null,
      raw: Map<String, dynamic>.from(map),
    );
  }
}

/// One server-side Hermes profile exposed through the Bot Mode roster.
///
/// The desktop plugin stores presentation data in
/// `ui_meta['hermes-bots']`; keeping that metadata server-side lets mobile
/// render the same names and ordering without maintaining a second roster.
class HermesBotProfile {
  const HermesBotProfile({
    required this.name,
    this.description,
    this.model,
    this.provider,
    this.isDefault = false,
    this.hasAvatar = false,
    this.lastSession,
    this.canonicalSession,
    this.canonicalRegistryId,
    this.title,
    this.color,
    this.shape,
    this.imageKind,
    this.group,
    this.groups = const [],
    this.chatSessionId,
    this.createdAt,
    this.pinned = false,
    this.hidden = false,
    this.raw = const {},
  });

  final String name;
  final String? description;
  final String? model;
  final String? provider;
  final bool isDefault;
  final bool hasAvatar;
  final HermesSession? lastSession;
  final HermesSession? canonicalSession;
  final String? canonicalRegistryId;
  final String? title;
  final String? color;
  final String? shape;
  final String? imageKind;

  /// Canonical multi-group membership. [group] remains the legacy first-room
  /// projection used by older Desktop and gateway builds.
  final String? group;
  final List<String> groups;
  final String? chatSessionId;
  final int? createdAt;
  final bool pinned;
  final bool hidden;
  final Map<String, dynamic> raw;

  /// Profiles explicitly enrolled by Bot Mode carry its UI metadata. Older
  /// Desktop/gateway builds still treated every named profile as a bot but
  /// did not persist that metadata, so named legacy profiles remain eligible.
  /// The sole exception is an unmanaged `default` profile: its latest session
  /// is normally an ordinary chat and must not be promoted into the roster.
  bool get isBotModeManaged {
    final ui = raw['ui_meta'];
    return ui is Map && ui['hermes-bots'] is Map;
  }

  bool get belongsInBotRoster {
    if (isBotModeManaged) return true;
    return !isDefault && name.trim().toLowerCase() != 'default';
  }

  String get displayName {
    final label = title?.trim();
    if (label != null && label.isNotEmpty) return label;
    if (isDefault || name.trim().toLowerCase() == 'default') return 'Hermes';
    return name;
  }

  String get handle => name.trim().toLowerCase() == 'default' ? 'hermes' : name;

  bool get showsHandle =>
      handle.isNotEmpty && displayName.toLowerCase() != handle.toLowerCase();

  bool get usesImageAvatar => imageKind?.toLowerCase() == 'photo';

  int get activityMillis {
    final last = parseServerTimeMillis(activitySession?.lastActive);
    return last > (createdAt ?? 0) ? last : (createdAt ?? 0);
  }

  /// The newest conversation signal for the roster. Canonical Bot Chats are
  /// hidden from ordinary session listings, so `last_session` alone can show
  /// a bot as idle even after a recent direct conversation.
  HermesSession? get activitySession {
    final canonical = canonicalSession;
    final last = lastSession;
    if (canonical == null || last == null) return canonical ?? last;
    return parseServerTimeMillis(canonical.lastActive) >=
            parseServerTimeMillis(last.lastActive)
        ? canonical
        : last;
  }

  factory HermesBotProfile.fromJson(Map<String, dynamic> json) {
    int? integer(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse('${value ?? ''}');
    }

    String? text(dynamic value) {
      final result = _asString(value)?.trim();
      return result == null || result.isEmpty ? null : result;
    }

    final rawUi = json['ui_meta'];
    final ui = rawUi is Map ? rawUi['hermes-bots'] : null;
    final meta = ui is Map
        ? ui.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final rawLast = json['last_session'];
    final last = rawLast is Map
        ? HermesSession.fromJson(
            rawLast.map((key, value) => MapEntry('$key', value)),
          )
        : null;
    final rawCanonical = json['canonical_session'];
    final canonicalMap = rawCanonical is Map
        ? rawCanonical.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final canonicalResolvedId = text(canonicalMap['resolved_id']);
    final canonicalRegistryId = text(canonicalMap['id']);
    final canonical = canonicalMap.isEmpty
        ? null
        : HermesSession.fromJson({
            ...canonicalMap,
            'id': canonicalResolvedId ?? canonicalRegistryId ?? '',
            'title':
                text(canonicalMap['title']) ??
                text(canonicalMap['root_title']) ??
                'Bot Chat',
            'last_active':
                canonicalMap['last_active'] ?? canonicalMap['started_at'],
            'model': json['model'],
          });

    final rawGroups = meta['groups'];
    final hasCanonicalGroups = rawGroups is List;
    final groups = <String>[];
    final seenGroups = <String>{};
    if (rawGroups is List) {
      for (final value in rawGroups) {
        final group = text(value);
        if (group != null && seenGroups.add(group)) groups.add(group);
      }
    }
    final legacyGroup = text(meta['group']);
    if (!hasCanonicalGroups && legacyGroup != null) groups.add(legacyGroup);

    return HermesBotProfile(
      name: text(json['name']) ?? '',
      description: text(json['description']),
      model: text(json['model']),
      provider: text(json['provider']),
      isDefault: json['is_default'] == true,
      hasAvatar: json['has_avatar'] == true,
      lastSession: last,
      canonicalSession: canonical,
      canonicalRegistryId: canonicalRegistryId,
      title: text(meta['title']),
      color: text(meta['color']),
      shape: text(meta['shape']),
      imageKind: text(meta['imageKind']),
      group: groups.isEmpty ? null : groups.first,
      groups: List.unmodifiable(groups),
      // Modern gateways resolve the canonical Bot Chat by title and return
      // both its registry root and compression tip. The ui_meta pointer is a
      // legacy fallback only; Desktop deliberately ignores and removes it.
      chatSessionId:
          canonicalResolvedId ?? canonicalRegistryId ?? text(meta['chat']),
      createdAt: integer(meta['created']),
      pinned: meta['pinned'] == true,
      hidden: meta['hidden'] == true,
      raw: Map<String, dynamic>.from(json),
    );
  }
}

/// Feature-detected Bot Mode roster returned by the gateway.
class HermesBotRoster {
  const HermesBotRoster({
    required this.available,
    this.profiles = const [],
    this.hiddenProfiles = const [],
  });

  const HermesBotRoster.unavailable()
    : available = false,
      profiles = const [],
      hiddenProfiles = const [];

  final bool available;
  final List<HermesBotProfile> profiles;
  final List<HermesBotProfile> hiddenProfiles;

  factory HermesBotRoster.fromServer(
    Map<String, dynamic> profilePayload, {
    Map<String, dynamic>? pluginPayload,
  }) {
    final features = profilePayload['features'];
    final featureMap = features is Map
        ? features.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final plugins = pluginPayload?['plugins'];
    final pluginAvailable =
        plugins is List &&
        plugins.whereType<Map>().any((entry) {
          final id = '${entry['id'] ?? entry['name'] ?? ''}'.trim();
          return id == 'hermes-bots' && entry['enabled'] != false;
        });
    final available =
        profilePayload['bot_mode_protocol'] == true ||
        profilePayload['bot_mode_available'] == true ||
        featureMap['bot_mode'] == true ||
        pluginAvailable;

    final rawProfiles = profilePayload['profiles'];
    final allProfiles = rawProfiles is List
        ? rawProfiles
              .whereType<Map>()
              .map(
                (entry) => HermesBotProfile.fromJson(
                  entry.map((key, value) => MapEntry('$key', value)),
                ),
              )
              .where(
                (profile) =>
                    profile.name.isNotEmpty && profile.belongsInBotRoster,
              )
              .toList(growable: false)
        : const <HermesBotProfile>[];

    allProfiles.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.activityMillis.compareTo(a.activityMillis);
    });
    return HermesBotRoster(
      available: available,
      profiles: available
          ? allProfiles
                .where((profile) => !profile.hidden)
                .toList(growable: false)
          : const [],
      hiddenProfiles: available
          ? allProfiles
                .where((profile) => profile.hidden)
                .toList(growable: false)
          : const [],
    );
  }
}

/// Display copy of one Desktop Bot Mode group-chat message.
///
/// Desktop mirrors a bounded room log through the default profile's
/// `ui_meta['hermes-bots-groups']` block. The gateway remains the source of
/// truth; mobile never tries to reconstruct room order from member sessions.
class HermesBotGroupMessage {
  const HermesBotGroupMessage({
    required this.kind,
    required this.name,
    required this.text,
    this.id,
    this.source,
    this.at,
    this.thread,
  });

  final String kind;
  final String name;
  final String text;
  final String? id;
  final String? source;
  final int? at;
  final String? thread;

  bool get isUser => kind == 'user';

  factory HermesBotGroupMessage.fromJson(Map<String, dynamic> json) {
    final rawFrom = json['from'];
    final from = rawFrom is Map
        ? rawFrom.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final rawAt = json['at'];
    final at = rawAt is num ? rawAt.toInt() : int.tryParse('${rawAt ?? ''}');
    final kind = '${from['kind'] ?? 'user'}'.trim().toLowerCase();
    return HermesBotGroupMessage(
      kind: kind == 'member' ? 'member' : 'user',
      name: '${from['name'] ?? (kind == 'member' ? 'Bot' : 'You')}'.trim(),
      id: _asString(json['id'])?.trim(),
      source: _asString(from['source'])?.trim(),
      text: '${json['text'] ?? ''}'.trim(),
      at: at,
      thread: _asString(json['thread'])?.trim(),
    );
  }
}

class HermesBotGroupRoom {
  const HermesBotGroupRoom({
    required this.name,
    this.roomId,
    this.revision = 0,
    this.messages = const [],
    this.members = const [],
  });

  final String name;
  final String? roomId;
  final int revision;
  final List<HermesBotGroupMessage> messages;
  final List<String> members;

  factory HermesBotGroupRoom.fromJson(String name, Map<String, dynamic> json) {
    final rawLog = json['log'];
    final messages = rawLog is List
        ? rawLog
              .whereType<Map>()
              .map(
                (entry) => HermesBotGroupMessage.fromJson(
                  entry.map((key, value) => MapEntry('$key', value)),
                ),
              )
              .where((message) => message.text.isNotEmpty)
              .toList(growable: false)
        : const <HermesBotGroupMessage>[];
    final rawMembers = json['members'];
    final members = rawMembers is List
        ? rawMembers
              .whereType<Map>()
              .map((entry) => '${entry['name'] ?? ''}'.trim())
              .where((member) => member.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final rawRevision = json['revision'];
    final revision = rawRevision is num
        ? rawRevision.toInt()
        : int.tryParse('${rawRevision ?? ''}') ?? 0;
    return HermesBotGroupRoom(
      name: name,
      roomId: _asString(json['roomId'])?.trim(),
      revision: revision,
      messages: messages,
      members: members,
    );
  }
}

Map<String, HermesBotGroupRoom> parseHermesBotGroupRooms(
  Map<String, dynamic> profilePayload,
) {
  final rawProfiles = profilePayload['profiles'];
  if (rawProfiles is! List) return const {};
  for (final rawProfile in rawProfiles.whereType<Map>()) {
    final name = '${rawProfile['name'] ?? ''}'.trim().toLowerCase();
    if (name != 'default' && rawProfile['is_default'] != true) continue;
    final rawUi = rawProfile['ui_meta'];
    if (rawUi is! Map) continue;
    final rawEnvelope = rawUi['hermes-bots-groups'];
    if (rawEnvelope is! Map) continue;
    final rawRooms = rawEnvelope['rooms'];
    if (rawRooms is! Map) return const {};
    final rawDeleted = rawEnvelope['deleted'];
    final deleted = rawDeleted is Map ? rawDeleted : const {};
    final rooms = <String, HermesBotGroupRoom>{};
    for (final entry in rawRooms.entries) {
      final roomKey = '${entry.key}'.trim();
      if (roomKey.isEmpty || entry.value is! Map) continue;
      final roomJson = (entry.value as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final rawDeletedRevision = deleted[entry.key] ?? deleted[roomKey];
      final deletedRevision = rawDeletedRevision is num
          ? rawDeletedRevision.toInt()
          : int.tryParse('${rawDeletedRevision ?? ''}');
      final rawRoomRevision = roomJson['revision'];
      final roomRevision = rawRoomRevision is num
          ? rawRoomRevision.toInt()
          : int.tryParse('${rawRoomRevision ?? ''}') ?? 0;
      if (deletedRevision != null &&
          (roomKey.startsWith('id:') || deletedRevision >= roomRevision)) {
        continue;
      }
      final projectedName = _asString(roomJson['name'])?.trim();
      final legacyName = roomKey.startsWith('name:')
          ? roomKey.substring('name:'.length).trim()
          : roomKey;
      final roomName = projectedName?.isNotEmpty == true
          ? projectedName!
          : legacyName;
      if (roomName.isEmpty) continue;
      final room = HermesBotGroupRoom.fromJson(roomName, roomJson);
      rooms[roomName] = room;
    }
    return Map.unmodifiable(rooms);
  }
  return const {};
}

/// Converts the ISO/unix timestamps used by gateway session rows to millis.
int parseServerTimeMillis(String? raw) {
  if (raw == null) return 0;
  final value = raw.trim();
  if (value.isEmpty) return 0;
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed.millisecondsSinceEpoch;
  final number = num.tryParse(value);
  if (number == null || number <= 0) return 0;
  return number > 1e12 ? number.round() : (number * 1000).round();
}

class HermesCapabilities {
  const HermesCapabilities({
    required this.raw,
    this.model,
    this.features = const {},
  });

  final Map<String, dynamic> raw;
  final String? model;
  final Map<String, dynamic> features;

  bool feature(String key) {
    final v = features[key];
    if (v is bool) return v;
    return false;
  }

  factory HermesCapabilities.fromJson(Map<String, dynamic> json) {
    final features = json['features'];
    return HermesCapabilities(
      raw: json,
      model: _asString(json['model']),
      features: features is Map<String, dynamic>
          ? features
          : features is Map
          ? features.map((k, v) => MapEntry('$k', v))
          : const {},
    );
  }
}

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

String? _asString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  return null;
}

String? _contentToString(dynamic content) {
  if (content == null) return null;
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];
    for (final item in content) {
      if (item is String) {
        parts.add(item);
      } else if (item is Map) {
        final text = item['text'] ?? item['content'] ?? item['output_text'];
        if (text != null) parts.add('$text');
      }
    }
    return parts.join('\n');
  }
  if (content is Map) {
    final text = content['text'] ?? content['content'];
    if (text != null) return '$text';
  }
  return content.toString();
}
