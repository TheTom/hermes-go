import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import 'package:hermes_mobile/core/models/context_usage.dart';
import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/config/reasoning_effort.dart';
import 'package:hermes_mobile/core/network/dashboard_client.dart';
import 'package:hermes_mobile/core/network/gateway_ws_client.dart';
import 'package:hermes_mobile/core/providers.dart';
import 'package:hermes_mobile/core/services/feedback.dart';
import 'package:hermes_mobile/core/services/slash_commands.dart';
import 'package:hermes_mobile/core/sync/completion_errors.dart';
import 'package:hermes_mobile/core/sync/session_sync_repository.dart';
import 'package:hermes_mobile/core/sync/session_touch.dart';
import 'package:hermes_mobile/core/theme/hermes_skins.dart';
import 'package:hermes_mobile/features/artifacts/artifact_detection.dart';
import 'package:hermes_mobile/features/artifacts/artifact_viewer_flags.dart';
import 'package:hermes_mobile/features/artifacts/artifact_viewer_screen.dart';
import 'package:hermes_mobile/features/bots/bot_mentions.dart';
import 'package:hermes_mobile/features/models/model_picker_sheet.dart';
import 'package:hermes_mobile/features/skills/skills_picker_sheet.dart';
import 'package:hermes_mobile/features/sessions/chat_composer.dart';
import 'package:hermes_mobile/features/sessions/context_usage_sheet.dart';
import 'package:hermes_mobile/features/sessions/message_markdown.dart';
import 'package:hermes_mobile/features/sessions/tool_message_card.dart';
import 'package:hermes_mobile/l10n/l10n.dart';

/// Distance (logical px) from the message list's "latest message" anchor
/// within which the user still counts as pinned to the bottom — i.e. the
/// scroll-anchoring threshold for autoscroll during streaming (matches the
/// Claude/ChatGPT/iMessage convention of a small tolerance rather than
/// requiring an exact-zero offset).
const double kAutoscrollPinThresholdPx = 96;

/// Pure decision function for scroll-anchoring: is [pixels] close enough to
/// the latest-message anchor to keep autoscrolling?
///
/// The message list below renders with `reverse: true` so that new content
/// stays glued to the bottom for free (index 0 is the newest message and
/// sits at scroll offset 0). That inverts the usual "bottom == maxScrollExtent"
/// convention — here "pinned to latest" means the offset is close to *zero*,
/// not close to the max extent. Extracted as a standalone function (no
/// BuildContext / ScrollController) so the threshold logic has a plain unit
/// test independent of widget pumping.
bool isPinnedToBottom(
  double pixels, {
  double threshold = kAutoscrollPinThresholdPx,
}) {
  return pixels <= threshold;
}

/// `ChatScrollObserver.fixedPositionOffset` this screen installs.
///
/// **Must equal [kAutoscrollPinThresholdPx].** The two numbers govern the two
/// halves of one behaviour and there is no coherent state where they differ:
///
/// * `ChatObserverScrollPhysicsMixin.adjustPositionForNewDimensions` (see
///   `scrollview_observer`) skips its correction only when
///   `newPosition.extentBefore <= fixedPositionOffset`; the list is
///   `reverse: true`, so `extentBefore == pixels`. Above the offset the
///   observer *pins the reading position*, and a streaming reply stops
///   visibly advancing.
/// * [isPinnedToBottom] decides whether the jump-to-latest chip is offered.
///
/// When the offset was smaller than the threshold, offsets in between put the
/// user in a dead zone: the transcript was frozen (observer holding) while the
/// screen still believed the user was pinned, so no chip was offered and there
/// was no way back to the live tail short of scrolling by hand. Nudging the
/// list ~50px mid-stream was enough to reach it.
const double kChatObserverFixedPositionOffset = kAutoscrollPinThresholdPx;

/// Mirrors the package's hold/release predicate for a `reverse: true` list:
/// true when the observer will hold the reading position instead of letting
/// new content push it.
///
/// Pure, so the "hold" and "offer the chip" switches can be tested to flip
/// together without pumping a widget.
bool chatObserverHoldsPositionAt(
  double pixels, {
  double fixedPositionOffset = kChatObserverFixedPositionOffset,
}) {
  return pixels > fixedPositionOffset;
}

/// Most recent durable model-switch marker in a chronological transcript.
///
/// A reconnect can miss the live `session.info` frame while still receiving
/// this persisted marker during transcript reconciliation.
String? latestModelSwitchMarkerId(List<HermesMessage> messages) {
  for (final message in messages.reversed) {
    if (message.displayKind == 'model_switch') return message.id;
  }
  return null;
}

/// Shared rename surface for embedded sessions and standalone bot chats.
Future<String?> showRenameSessionDialog(
  BuildContext context, {
  required String initialTitle,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RenameSessionDialog(initialTitle: initialTitle),
  );
}

class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.renameChat),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 1,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          hintText: context.l10n.title,
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}

/// Is this user turn unanswered — i.e. the turn at [index] never got a real
/// assistant reply (empty tail, or only an API-error / failed banner after
/// it)? Drives the "No response yet" label plus the Resend/Edit chips, which
/// *add height* to a bubble.
///
/// Takes the transcript and the in-flight flag as explicit parameters rather
/// than reading `_messages` / `_sending` off the State — that keeps the
/// decision pure and directly unit-testable, independent of widget pumping.
///
/// While a turn is in flight the latest user turn is *waiting*, not failed,
/// so it must not be marked unanswered.
bool isUnansweredUserAt(
  List<HermesMessage> messages,
  int index, {
  required bool sending,
}) {
  if (index < 0 || index >= messages.length) return false;
  final message = messages[index];
  if (!message.isVisibleUser) return false;
  if (sending) {
    final laterUser = messages.skip(index + 1).any((m) => m.isVisibleUser);
    if (!laterUser) return false;
  }
  for (var i = index + 1; i < messages.length; i++) {
    final m = messages[i];
    if (m.isVisibleUser) break;
    // System/tool rows AND synthetic user-role timeline markers (role "user"
    // but not visible — model_switch, …) are not turn boundaries; skip past
    // them looking for the real assistant reply.
    if (m.isSystem || m.isTool || m.isUser) continue;
    if (m.isAssistant) {
      final body = (m.content ?? '').trim();
      if (body.isEmpty) continue;
      if (m.finishReason == 'error' || isCompletionErrorText(body)) return true;
      return false;
    }
  }
  return true;
}

/// True when [a] and [b] would *render* identically — same length, and no
/// pair differs in any field `_MessageBubble` actually displays (id, role,
/// content, tool name, finish reason, and the synthetic-marker tag).
///
/// Used to short-circuit a background resync that changed nothing on
/// screen (see [SessionChatScreenState._replaceMessages]): the debounced
/// tool-event resync fires on almost every tool call in a turn, and without
/// this it would call `standby()`/`setState()` that often for content that
/// never actually changed.
///
/// Deliberately conservative — `toolCalls` (`dynamic`, not safely
/// comparable by value) and `timestamp`/`tokenCount`/`reasoning` (not
/// rendered) are not compared, so this can return `false` for a resync that
/// is in fact a no-op. That only costs a missed optimization, never
/// correctness: the caller falls through to the normal bracket-and-setState
/// path either way.
bool sameRenderedTranscript(List<HermesMessage> a, List<HermesMessage> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.id != y.id ||
        x.role != y.role ||
        x.content != y.content ||
        x.toolName != y.toolName ||
        x.finishReason != y.finishReason ||
        x.displayKind != y.displayKind) {
      return false;
    }
  }
  return true;
}

/// How a *wholesale* replacement of the transcript — a background
/// resync/reload, or the server-confirmed transcript landing at the end of
/// a turn — should be signalled to `ChatScrollObserver.standby()`, given
/// only the old and new list lengths.
///
/// This is a different situation from a single insert / remove /
/// generative-growth mutation (which each map onto one `standby()` call
/// directly — see the call sites in [SessionChatScreenState]): a wholesale
/// replacement can grow, shrink, or edit content in place all within one
/// assignment (dedup, an optimistic id swapped for its server id, a
/// truncate-and-resend, …), so there is no single obviously-correct
/// `standby()` call. This classifies by net length change against the
/// package's own primitives (read from the published source, not guessed):
///
/// * Net growth → [WholesaleReplaceMode.insertAtHead]. Every source that
///   can grow `_messages` appends to the end of the chronological list,
///   which is visual index 0 in this `reverse: true` list. That is
///   `ChatScrollObserverHandleMode.normal`'s built-in assumption (the
///   package's own doc comment on that mode: "Regular mode ... Such as
///   inserting or deleting messages."), so callers signal this with
///   `standby(changeCount: newLength - oldLength)`.
/// * Net shrink → [WholesaleReplaceMode.remove]. *Which* message(s)
///   disappeared isn't knowable from a count alone (dedup collapsing
///   entries, a message getting merged into another, …), so callers signal
///   this with `standby(isRemove: true)` — the package's own convention for
///   exactly this ambiguity: `ChatObserverScrollPhysicsMixin` skips the
///   position-preserving delta entirely whenever `observer.isRemove` is
///   true and falls back to the platform's default clamping, rather than
///   risk anchoring to the wrong item.
/// * Same length → [WholesaleReplaceMode.none]. Almost always an in-place
///   content swap (e.g. an optimistic id becoming its server id with
///   identical text), which moves no item's `layoutOffset` — there is
///   nothing to correct. It is also not a case for `generative` mode: that
///   mode assumes a single, already-known item is the one growing, which
///   isn't true for an arbitrary same-length replacement.
enum WholesaleReplaceMode { insertAtHead, remove, none }

WholesaleReplaceMode classifyWholesaleReplace({
  required int oldLength,
  required int newLength,
}) {
  if (newLength > oldLength) return WholesaleReplaceMode.insertAtHead;
  if (newLength < oldLength) return WholesaleReplaceMode.remove;
  return WholesaleReplaceMode.none;
}

/// Full-screen chat for an existing session (pushed from drawer / deep link).
class SessionChatScreen extends ConsumerStatefulWidget {
  const SessionChatScreen({
    super.key,
    required this.session,
    this.embedded = false,
    this.initialMessage,
    this.initialAttachments = const [],
    this.onSessionUpdated,
    this.onNewChat,
    this.onOpenSessionId,
    this.onOpenBotSessions,
    this.profileName,
    this.isCanonicalBotChat = false,
  });

  final HermesSession session;

  /// When true, no AppBar back — used inside the Claude-style home shell.
  final bool embedded;

  /// If set, auto-send once after the chat mounts (new-chat from home).
  final String? initialMessage;

  /// Images picked on the home composer before the session existed.
  final List<PendingImage> initialAttachments;

  final ValueChanged<HermesSession>? onSessionUpdated;

  /// `/new` / `/reset` — parent starts a fresh chat shell.
  final VoidCallback? onNewChat;

  /// `/resume <id>` — parent opens that session if known.
  final ValueChanged<String>? onOpenSessionId;

  /// Bot chats expose their conversation history and new-session action from
  /// the chat itself, instead of requiring a return to the Bots roster.
  final VoidCallback? onOpenBotSessions;

  /// Non-null for Bot Mode chats, whose durable session belongs to a named
  /// server profile rather than the gateway's default profile.
  final String? profileName;

  /// The exact `Bot Chat` registry row is a server-owned identity, not a
  /// display title. Ordinary bot sessions remain renameable.
  final bool isCanonicalBotChat;

  @override
  ConsumerState<SessionChatScreen> createState() => SessionChatScreenState();
}

class SessionChatScreenState extends ConsumerState<SessionChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _speaker = ReplySpeaker();

  /// Whether the viewport is currently anchored to the newest message. Drives
  /// both "should new content autoscroll" and "show the jump-to-latest chip".
  bool _pinnedToBottom = true;

  /// Guards [_scrollToBottom]'s own `jumpTo`/`animateTo` calls so the
  /// `_scroll` listener that recomputes [_pinnedToBottom] doesn't mistake
  /// our programmatic correction for the user scrolling away.
  bool _programmaticScroll = false;

  /// Feeds [_scroll] to the `scrollview_observer` package, which needs to
  /// know which child is currently displaying in order to compute a
  /// reference item for [_chatObserver].
  late final ListObserverController _observerController;

  /// Keeps the user's reading position fixed while the transcript mutates
  /// off-screen (streaming growth, inserts, removes). Unlike the previous
  /// freeze-based design, the list always renders the *live* `_messages` —
  /// this only corrects the scroll offset, during layout, so nothing wrong
  /// is ever painted. See `standby()` call sites below for how each kind of
  /// mutation is signalled (insert / remove / generative growth).
  late final ChatScrollObserver _chatObserver;

  /// Every site in this class that assigns `_messages`, classified. The
  /// list always renders live (there is no frozen snapshot to hide a
  /// mutation behind any more — see [_chatObserver]), so *every* assignment
  /// is a candidate for shoving a reader who has scrolled away, regardless
  /// of whether `_sending` happens to be true at that instant.
  ///
  /// * **Bracketed with `standby()`** — a real content change that isn't
  ///   provably safe another way:
  ///   * [_appendSystem] — single insert, `standby(changeCount: 1)`.
  ///   * [_deleteMessage] — single removal, `standby(isRemove: true)`.
  ///   * `onAssistantDelta` in [_send] — the streaming bubble growing in
  ///     place, `standby(mode: generative)`.
  ///   * [_applyReloadedMessages] and all four assignments in [_load] — a
  ///     background resync/reload can grow, shrink, or edit content in
  ///     place all in one replacement, so these route through
  ///     [_replaceMessages], which skips the whole thing when the merged
  ///     list would render identically to what's on screen (via
  ///     [sameRenderedTranscript] — this is the fix for the debounced
  ///     `tool.start`/`tool.complete` resync in `gateway_realtime.dart`
  ///     landing while a reader is scrolled away mid-turn: it used to reach
  ///     `_applyReloadedMessages` with no bracket at all) and otherwise
  ///     classifies the net change via [classifyWholesaleReplace].
  ///   * The final `_messages = next;` in [_send] (end of turn) — the
  ///     server-confirmed transcript replacing the optimistic one. Not
  ///     covered by the send-time re-pin below (that already ran, and the
  ///     user may have scrolled away again during the stream that
  ///     followed), so it goes through [_standbyForWholesaleReplace]
  ///     directly (the `setState` around it is unconditional regardless —
  ///     `_sending`/`_toolStatus`/etc. always change — so there's no
  ///     `setState` to skip the way [_replaceMessages] skips one).
  /// * **Safe because an explicit re-pin follows in the same synchronous
  ///   stretch of code** (the mutating `setState` and the subsequent
  ///   `unawaited(_scrollToBottom())` both run before this build ever
  ///   yields to the frame scheduler, so the first frame that lays out the
  ///   mutated list already has the scroll-to-bottom animation in flight —
  ///   this is also always a *direct result of the user's own action*
  ///   [send / retry / edit / run a slash command], so an animated jump to
  ///   the bottom is expected, not a surprise):
  ///   * The optimistic user-bubble append + dedupe in [_send].
  ///   * The optimistic append in [_runSlash].
  ///   * The optimistic truncate-and-replace in [_retryFrom] and
  ///     [_editUserMessage] (both call into [_send], which re-pins).
  /// * **Position-neutral — no `standby()`, no re-pin needed:**
  ///   * [didUpdateWidget]'s session-id-remap branch — same ids, same
  ///     content, same count, only `sessionId` changes; nothing
  ///     `_MessageBubble` renders differs, so no item's `layoutOffset`
  ///     moves.
  ///   * [didUpdateWidget]'s session-switch branch — resets to `const []`
  ///     for a genuinely different, unrelated session and forces
  ///     `_pinnedToBottom = true`; there is no old reading position that
  ///     belongs to the new session to preserve.
  List<HermesMessage> _messages = const [];
  List<PendingImage> _attachments = const [];
  bool _loading = true;
  bool _sending = false;
  bool _queuedHint = false;
  bool _readAloud = false;
  String? _error;
  String? _toolStatus;
  GatewayApprovalRequest? _approvalRequest;
  bool _approvalResponding = false;
  late HermesSession _session;
  StreamSubscription<SessionTouch>? _touchSub;
  StreamSubscription<GatewayWsEvent>? _runtimeSub;
  var _didSendInitial = false;
  String? _lastSpokenAssistantId;
  UsageStats? _usage;
  ContextBreakdown? _contextBreakdown;
  String? _sessionModel;
  String? _sessionProvider;
  String? _sessionReasoningEffort;
  bool? _sessionFastMode;
  Future<void>? _runtimeHydration;
  String? _lastModelSwitchMarkerId;

  /// Memo for [_knownArtifactPaths] — the transcript the current index was
  /// built from, compared by identity.
  List<HermesMessage>? _artifactPathsSource;
  SessionArtifactPaths _artifactPaths = SessionArtifactPaths.empty;

  HermesSession get session => _session;

  /// The session's known written-artifact paths, so a backticked filename in
  /// assistant prose can be resolved to the real path before it becomes a
  /// tappable chip (see `artifact_detection.dart`).
  ///
  /// Rebuilt only when the transcript list is replaced — every `_messages`
  /// mutation assigns a fresh list — so message bubbles never rescan the
  /// transcript themselves. Streaming replaces the list on every token, but
  /// the previous index is fed back in so unchanged tool results are reused
  /// rather than re-decoded.
  ///
  /// Gated by [kArtifactViewerEnabled]: with the viewer paused for v1, no
  /// chip can ever render, so there is nothing for this index to feed —
  /// bail out before scanning the transcript at all rather than build an
  /// index nobody reads.
  SessionArtifactPaths _knownArtifactPaths(List<HermesMessage> messages) {
    if (!kArtifactViewerEnabled) return SessionArtifactPaths.empty;
    if (identical(_artifactPathsSource, messages)) return _artifactPaths;
    _artifactPathsSource = messages;
    _artifactPaths = SessionArtifactPaths.fromMessages(
      messages,
      previous: _artifactPaths,
    );
    return _artifactPaths;
  }

  /// Show typing/thinking row until first stream token arrives.
  bool get _showThinkingBubble {
    if (!_sending) return false;
    final hasStream = _messages.any(
      (m) =>
          m.isAssistant &&
          m.id.startsWith('stream_') &&
          (m.content?.trim().isNotEmpty ?? false),
    );
    return !hasStream;
  }

  /// True while the framework is inside build/layout/paint, where
  /// `setState` is illegal.
  ///
  /// `ScrollPosition` runs its listeners and notifications synchronously, and
  /// some of those paths fire *during layout* — notably
  /// `applyContentDimensions` → `goBallistic` → `didEndScroll`, which a lazy
  /// list hits routinely because laying in another item revises
  /// `maxScrollExtent` mid-fling. So anything reachable from [_onScroll] has
  /// to tolerate that.
  bool get _inFrameCallback =>
      SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks;

  /// `setState`-equivalent that is safe from a scroll callback: the caller
  /// has already mutated state; this only defers the *rebuild request* out of
  /// a frame we happen to be inside.
  void _rebuildSoon() {
    if (!mounted) return;
    if (_inFrameCallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// Generic waiting copy — covered by the dots bubble; don't also print it.
  bool get _toolStatusIsGeneric {
    final s = (_toolStatus ?? '').trim().toLowerCase();
    if (s.isEmpty) return true;
    return s == L10n.current.thinking.toLowerCase() ||
        s == 'thinking…' ||
        s == 'thinking...' ||
        s == 'thinking' ||
        s == 'writing…' ||
        s == 'writing...' ||
        s == 'writing';
  }

  /// Status strip only for real progress (tools, upload), not duplicate "Thinking".
  bool get _showStatusStrip {
    if (_toolStatus == null || _toolStatus!.trim().isEmpty) return false;
    if (_showThinkingBubble && _toolStatusIsGeneric) return false;
    return true;
  }

  /// Platform-matched physics: `ChatObserverBouncingScrollPhysics`/
  /// `ChatObserverClampingScrollPhysics` are drop-in subclasses of Flutter's
  /// own `BouncingScrollPhysics`/`ClampingScrollPhysics` (the same pair
  /// `ScrollBehavior` itself picks between per platform), so this keeps
  /// native iOS overscroll/rubber-banding rather than flattening every
  /// platform to Android-style clamping.
  ScrollPhysics get _chatScrollPhysics {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return ChatObserverBouncingScrollPhysics(observer: _chatObserver);
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return ChatObserverClampingScrollPhysics(observer: _chatObserver);
    }
  }

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    final profile = widget.profileName?.trim();
    if (profile != null && profile.isNotEmpty) {
      ref
          .read(sessionSyncProvider)
          ?.registerSessionProfile(widget.session.id, profile);
    }
    _sessionModel = widget.session.model;
    _attachments = List.of(widget.initialAttachments);
    _observerController = ListObserverController(controller: _scroll)
      ..cacheJumpIndexOffset = false;
    _chatObserver = ChatScrollObserver(_observerController)
      ..fixedPositionOffset = kChatObserverFixedPositionOffset
      ..toRebuildScrollViewCallback = () {
        if (mounted) setState(() {});
      };
    _scroll.addListener(_onScroll);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _listenLive();
      _runtimeHydration = _hydrateSessionRuntime();
      unawaited(_runtimeHydration);
      _maybeSendInitial();
      unawaited(_refreshContextUsage());
    });
  }

  Future<void> _hydrateSessionRuntime() async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;

    // A historical session owns its runtime model/options. Wait for the
    // resume handshake before falling back to the phone-wide new-chat pick.
    try {
      await _runtimeHydration;
    } catch (_) {}
    final runtime = await sync.fetchSessionRuntime(_session.id);
    if (!mounted || runtime == null) return;
    _applySessionRuntime(runtime);
  }

  void _applySessionRuntime(SessionRuntimeState runtime) {
    if (!mounted) return;
    final nextModel = runtime.model ?? _sessionModel;
    setState(() {
      _sessionModel = nextModel;
      _sessionProvider = runtime.provider ?? _sessionProvider;
      _sessionReasoningEffort =
          runtime.reasoningEffort ?? _sessionReasoningEffort;
      _sessionFastMode = runtime.fastMode ?? _sessionFastMode;
      if (nextModel != null && nextModel.isNotEmpty) {
        _session = HermesSession(
          id: _session.id,
          source: _session.source,
          userId: _session.userId,
          model: nextModel,
          title: _session.title,
          startedAt: _session.startedAt,
          endedAt: _session.endedAt,
          endReason: _session.endReason,
          messageCount: _session.messageCount,
          toolCallCount: _session.toolCallCount,
          lastActive: _session.lastActive,
          preview: _session.preview,
          parentSessionId: _session.parentSessionId,
        );
      }
    });
    widget.onSessionUpdated?.call(_session);
  }

  Future<void> _refreshContextUsage({bool fullBreakdown = false}) async {
    try {
      await _runtimeHydration;
    } catch (_) {}
    final sync = ref.read(sessionSyncProvider);
    if (sync == null || !mounted) return;
    try {
      final usage = await sync.fetchSessionUsage(_session.id);
      if (!mounted) return;
      if (usage != null) {
        setState(() => _usage = (_usage ?? const UsageStats()).merge(usage));
      }
      if (fullBreakdown || _contextBreakdown == null) {
        try {
          final bd = await sync.fetchContextBreakdown(_session.id);
          if (!mounted) return;
          setState(() {
            _contextBreakdown = bd;
            if (bd.contextMax > 0) {
              _usage = (_usage ?? const UsageStats()).merge(
                UsageStats(
                  contextUsed: bd.contextUsed,
                  contextMax: bd.contextMax,
                  contextPercent: bd.contextPercent,
                  model: bd.model,
                ),
              );
            }
          });
        } catch (_) {
          // Breakdown needs a built agent; usage alone is still useful.
        }
      }
    } catch (_) {}
  }

  Future<void> _openContextUsage() async {
    hermesHaptic(HapticIntent.open);
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    await showContextUsageSheet(
      context,
      seedUsage: _usage,
      load: () => sync.fetchContextBreakdown(_session.id),
    );
    // Pull again after the sheet so the chip stays fresh.
    unawaited(_refreshContextUsage(fullBreakdown: true));
  }

  Future<void> _maybeSendInitial() async {
    final first = widget.initialMessage?.trim() ?? '';
    if (_didSendInitial) return;
    if (first.isEmpty && _attachments.isEmpty) return;
    _didSendInitial = true;
    // Wait for session row to settle after create.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    if (first.isNotEmpty) _composer.text = first;
    await _send();
  }

  @override
  void didUpdateWidget(covariant SessionChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      // Session id remap (local_* → server) must not wipe an in-flight turn.
      final wasSending = _sending;
      final keep = wasSending ? List<HermesMessage>.from(_messages) : null;
      _session = widget.session;
      _sessionModel = widget.session.model;
      _sessionProvider = null;
      _sessionReasoningEffort = null;
      _sessionFastMode = null;
      _approvalRequest = null;
      _approvalResponding = false;
      _runtimeHydration = _hydrateSessionRuntime();
      unawaited(_runtimeHydration);
      if (wasSending && keep != null) {
        // No standby() bracket — every field copied here is what
        // `_MessageBubble` renders *except* `sessionId`, so this is a
        // position-neutral remap (see the classification comment above the
        // `_messages` field): same ids, same content, same count, nothing
        // on screen moves.
        _messages = [
          for (final m in keep)
            HermesMessage(
              id: m.id,
              sessionId: widget.session.id,
              role: m.role,
              content: m.content,
              toolCallId: m.toolCallId,
              toolCalls: m.toolCalls,
              toolName: m.toolName,
              timestamp: m.timestamp,
              tokenCount: m.tokenCount,
              finishReason: m.finishReason,
              reasoning: m.reasoning,
              // Carried deliberately: `isVisibleUser` is `role == 'user' &&
              // displayKind` empty, so dropping the tag would turn every
              // synthetic marker in the kept transcript into a visible user
              // turn and shift the ordinals an edit/retry sends back to the
              // gateway (error 4018).
              displayKind: m.displayKind,
            ),
        ];
        // Background refresh only — do not clear the chat.
        unawaited(_softReloadMessages());
      } else {
        // No standby() bracket — a genuinely different session's transcript
        // is unrelated content, so there is no old reading position that
        // belongs to it. Pinned to its bottom explicitly.
        _messages = const [];
        _pinnedToBottom = true;
        _load();
      }
    }
  }

  void _listenLive() {
    final rt = ref.read(gatewayRealtimeProvider);
    if (rt == null) return;
    _touchSub?.cancel();
    _runtimeSub?.cancel();
    _touchSub = rt.sessionTouches.listen((touch) {
      if (_sending) return;
      final sid = touch.sessionId;
      if (sid != null &&
          sid.isNotEmpty &&
          sid != _session.id &&
          !sid.startsWith(_session.id) &&
          !_session.id.startsWith(sid)) {
        return;
      }
      unawaited(_softReloadMessages());
    });
    _runtimeSub = rt.events.listen(_onRuntimeEvent);
  }

  void _onRuntimeEvent(GatewayWsEvent event) {
    if (event.type != 'session.info') return;
    final sid = event.sessionId;
    final sync = ref.read(sessionSyncProvider);
    if (sid != null && sid.isNotEmpty) {
      final family = sync?.sessionIdFamily(_session.id) ?? {_session.id};
      if (!family.contains(sid) && sid != _session.id) return;
    }
    final nested = event.payload['payload'];
    final body = nested is Map ? nested.cast<String, dynamic>() : event.payload;
    final runtime = SessionRuntimeState.fromJson(body);
    final modelChanged =
        runtime.model != null && runtime.model != _sessionModel;
    _applySessionRuntime(runtime);
    if (modelChanged) {
      unawaited(_refreshContextUsage(fullBreakdown: true));
    }
  }

  Future<void> _softReloadMessages() async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null || !mounted || _sending) return;
    try {
      final merged = await sync.syncMessages(_session.id);
      if (!mounted || _sending) return;
      await _applyReloadedMessages(sync, merged);
    } catch (_) {
      try {
        final local = await sync.loadMessagesLocal(_session.id);
        if (!mounted || _sending) return;
        await _applyReloadedMessages(sync, local);
      } catch (_) {}
    }
  }

  /// Apply a background-refreshed transcript and, if this send was showing
  /// the "queued, will sync" state, reconcile it: a background/foreground
  /// outbox flush resolving the op (success OR permanent failure) must clear
  /// the "Queued for sync to gateway…" banner — otherwise it (and any
  /// "No reply yet" affordance the fresh transcript has already answered)
  /// sits there forever, since nothing else in this screen revisits it once
  /// [_send] returns.
  Future<void> _applyReloadedMessages(
    SessionSyncRepository sync,
    List<HermesMessage> incoming,
  ) async {
    final latestModelSwitchId = latestModelSwitchMarkerId(incoming);
    final runtimeMarkerChanged =
        latestModelSwitchId != null &&
        latestModelSwitchId != _lastModelSwitchMarkerId;
    if (latestModelSwitchId != null) {
      _lastModelSwitchMarkerId = latestModelSwitchId;
    }
    var stillQueued = _queuedHint;
    if (_queuedHint) {
      try {
        stillQueued = await sync.hasPendingOpsFor(_session.id);
      } catch (_) {
        // Unknown — leave the hint as-is rather than guess.
        stillQueued = _queuedHint;
      }
    }
    if (!mounted || _sending) return;
    _replaceMessages(
      _mergePreserveInflight(incoming),
      extra: (_queuedHint && !stillQueued)
          ? () {
              _queuedHint = false;
              if (_error == L10n.current.savedWaitingWs) _error = null;
            }
          : null,
    );
    // A reconnect can miss the live session.info event while still pulling
    // its durable model-switch marker. Rehydrate both runtime metadata and
    // context capacity so the header cannot retain the previous model's
    // 131k limit until another turn happens to correct it.
    if (runtimeMarkerChanged) {
      _runtimeHydration = _hydrateSessionRuntime();
      unawaited(_runtimeHydration);
      unawaited(_refreshContextUsage(fullBreakdown: true));
    }
  }

  /// Tells [_chatObserver] a wholesale replacement of `_messages` is about
  /// to land, via [classifyWholesaleReplace]. See the classification
  /// comment above the `_messages` field for why this exists and where it
  /// is (and isn't) used.
  void _standbyForWholesaleReplace(List<HermesMessage> incoming) {
    switch (classifyWholesaleReplace(
      oldLength: _messages.length,
      newLength: incoming.length,
    )) {
      case WholesaleReplaceMode.insertAtHead:
        _chatObserver.standby(changeCount: incoming.length - _messages.length);
      case WholesaleReplaceMode.remove:
        _chatObserver.standby(isRemove: true);
      case WholesaleReplaceMode.none:
        break;
    }
  }

  /// Replaces `_messages` the way every background resync/reload needs to:
  /// skip the whole thing — no `standby()`, no `setState()` — when
  /// [incoming] would render identically to what's already on screen (see
  /// [sameRenderedTranscript]; this matters because the debounced
  /// `tool.start`/`tool.complete` resync in `gateway_realtime.dart` fires on
  /// almost every tool call in a turn), and otherwise briefs
  /// [_chatObserver] via [_standbyForWholesaleReplace] before the swap so a
  /// reader scrolled away isn't shoved by it landing. [extra] runs inside
  /// the same `setState` for callers that also flip another field alongside
  /// the transcript.
  void _replaceMessages(List<HermesMessage> incoming, {VoidCallback? extra}) {
    final changed = !sameRenderedTranscript(_messages, incoming);
    if (!changed && extra == null) return;
    if (changed) _standbyForWholesaleReplace(incoming);
    setState(() {
      _messages = incoming;
      extra?.call();
    });
  }

  /// Never drop the optimistic user bubble / live stream row when a background
  /// sync returns a partial transcript (common mid-turn).
  List<HermesMessage> _mergePreserveInflight(List<HermesMessage> incoming) {
    if (!_sending) return dedupeAdjacentUserMessages(incoming);
    final out = List<HermesMessage>.from(incoming);
    for (final m in _messages) {
      final isOptimisticUser =
          m.isUser &&
          (m.id.startsWith('local_user_') || m.id.startsWith('local_slash_'));
      final isStream = m.isAssistant && m.id.startsWith('stream_');
      if (!isOptimisticUser && !isStream) continue;
      final already = out.any((o) {
        if (o.id == m.id) return true;
        if (isOptimisticUser &&
            o.isUser &&
            (o.content ?? '').trim() == (m.content ?? '').trim()) {
          return true;
        }
        // Keep a streamed completion-error banner if sync lags.
        if (isStream &&
            o.isAssistant &&
            isCompletionErrorText(m.content) &&
            (o.content ?? '').trim() == (m.content ?? '').trim()) {
          return true;
        }
        return false;
      });
      if (!already) out.add(m);
    }
    return dedupeAdjacentUserMessages(out);
  }

  @override
  void dispose() {
    _touchSub?.cancel();
    _runtimeSub?.cancel();
    _composer.dispose();
    _scroll.dispose();
    unawaited(_speaker.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final local = await sync.loadMessagesLocal(_session.id);
    if (!mounted) return;
    // Initial auto-send can race this load — never clobber an in-flight turn.
    // `_loading` must flip regardless of whether the transcript itself
    // changed, so `extra` always runs — see [_replaceMessages].
    if (_sending) {
      _replaceMessages(
        _mergePreserveInflight(local),
        extra: () => _loading = false,
      );
      return;
    }
    _replaceMessages(local, extra: () => _loading = false);

    try {
      final merged = await sync.syncMessages(_session.id);
      if (!mounted) return;
      if (_sending) {
        _replaceMessages(_mergePreserveInflight(merged));
        return;
      }
      _replaceMessages(merged);
    } catch (e) {
      if (!mounted) return;
      if (_messages.isEmpty) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && _attachments.isEmpty) || _sending) return;
    _composer.text = trimmed;
    await _send();
  }

  Future<void> _uploadAttachments(SessionSyncRepository sync) async {
    if (_attachments.isEmpty) return;
    final model = _sessionModel ?? _session.model;
    final provider = _sessionProvider;
    final pending = List<PendingImage>.from(_attachments);
    for (final img in pending) {
      await sync.attachImageBytes(
        sessionId: _session.id,
        bytes: img.bytes,
        filename: img.filename,
        model: model,
        provider: provider,
      );
    }
    if (mounted) setState(() => _attachments = const []);
  }

  void _maybeSpeakAssistant(List<HermesMessage> messages) {
    if (!_readAloud) return;
    HermesMessage? lastAssistant;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isAssistant) {
        lastAssistant = messages[i];
        break;
      }
    }
    if (lastAssistant == null) return;
    if (lastAssistant.id.startsWith('stream_')) return;
    if (lastAssistant.id == _lastSpokenAssistantId) return;
    final text = lastAssistant.content?.trim() ?? '';
    if (text.isEmpty) return;
    _lastSpokenAssistantId = lastAssistant.id;
    unawaited(_speaker.speak(text));
  }

  /// Real-time pin/unpin — fires on every drag, fling, and programmatic
  /// scroll. Programmatic corrections are skipped via [_programmaticScroll]
  /// so our own re-anchor jumps can't be misread as "user scrolled away".
  void _onScroll() {
    if (_programmaticScroll || !_scroll.hasClients) return;
    final pinned = isPinnedToBottom(_scroll.position.pixels);
    if (pinned != _pinnedToBottom) {
      _pinnedToBottom = pinned;
      _rebuildSoon();
    }
  }

  /// Explicit user action (sending a message, tapping "jump to latest") —
  /// always goes back to the newest message and re-pins, regardless of where
  /// the user had scrolled to.
  Future<void> _scrollToBottom({bool animate = true}) async {
    if (!_scroll.hasClients) {
      _pinnedToBottom = true;
      return;
    }
    if (mounted) setState(() => _pinnedToBottom = true);
    _programmaticScroll = true;
    try {
      if (animate) {
        await _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(0);
      }
    } catch (_) {
      // Controller may detach mid-animation (screen popped) — harmless.
    } finally {
      _programmaticScroll = false;
    }
  }

  Future<void> _stopGeneration() async {
    hermesHaptic(HapticIntent.cancel);
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    try {
      await sync.interruptSession(_session.id);
    } catch (e) {
      FeedbackService.instance.error();
      if (mounted) setState(() => _error = context.l10n.stopFailed('$e'));
    }
  }

  /// User ordinal for edit/retry (Desktop `visibleUserOrdinal`).
  ///
  /// Uses [HermesMessage.isVisibleUser], not `isUser` — a synthetic timeline
  /// marker (model_switch, …) carries `role: "user"` too but must not count
  /// as a turn boundary here, or this drifts from the gateway's own count
  /// and a submit built from it gets refused with 4018.
  int? _userOrdinalForMessage(HermesMessage message) {
    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) return null;
    if (message.isVisibleUser) {
      return SessionSyncRepository.userOrdinalAmong(_messages, idx);
    }
    // Assistant: find preceding user turn.
    for (var i = idx - 1; i >= 0; i--) {
      if (_messages[i].isVisibleUser) {
        return SessionSyncRepository.userOrdinalAmong(_messages, i);
      }
    }
    return null;
  }

  HermesMessage? _precedingUser(HermesMessage message) {
    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) return message.isVisibleUser ? message : null;
    if (message.isVisibleUser) return message;
    for (var i = idx - 1; i >= 0; i--) {
      if (_messages[i].isVisibleUser) return _messages[i];
    }
    return null;
  }

  Future<void> _waitUntilIdle() async {
    if (!_sending) return;
    await _stopGeneration();
    for (var i = 0; i < 80 && _sending; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// [isUnansweredUserAt] against the *live* transcript — for action sheets
  /// and retry wiring, which must reflect real state.
  bool _isUnansweredUser(HermesMessage message) {
    if (!message.isVisibleUser) return false;
    return isUnansweredUserAt(
      _messages,
      _messages.indexWhere((m) => m.id == message.id),
      sending: _sending,
    );
  }

  bool _isApiErrorMessage(HermesMessage message) {
    if (!message.isAssistant && !message.isSystem) return false;
    if (message.finishReason == 'error') return true;
    return isCompletionErrorText(message.content);
  }

  Future<void> _retryFrom(HermesMessage message) async {
    final user = _precedingUser(message);
    if (user == null) return;
    var text = stripBotMentionHandoff(user.content ?? '').trim();
    // Strip image-chip suffix from optimistic labels if present.
    if (text.contains('\n📷')) {
      text = text.split('\n📷').first.trim();
    }
    final ordinal = _userOrdinalForMessage(user);
    if (text.isEmpty) {
      if (mounted) {
        setState(() => _error = context.l10n.resubmitMessage);
      }
      return;
    }
    // Fall back to last user ordinal if id lookup failed (stale local ids).
    final resolvedOrdinal =
        ordinal ??
        SessionSyncRepository.userOrdinalAmong(
          _messages,
          _messages.lastIndexWhere((m) => m.isUser),
        );

    await _waitUntilIdle();
    if (!mounted) return;

    // Optimistic truncate: keep messages before this user turn. No
    // standby() bracket needed — the [_send] call right below always
    // re-pins to the bottom before this build yields a frame (see the
    // classification comment above the `_messages` field).
    final userIdx = _messages.indexWhere((m) => m.id == user.id);
    if (userIdx >= 0) {
      setState(() {
        _messages = [
          ..._messages.take(userIdx),
          HermesMessage(
            id: user.id,
            sessionId: _session.id,
            role: 'user',
            content: text,
            timestamp: user.timestamp,
          ),
        ];
        _error = null;
      });
    }
    await _send(
      text: text,
      truncateBeforeUserOrdinal: resolvedOrdinal,
      interruptFirst: true,
      skipOptimisticAppend: true,
    );
  }

  Future<void> _editUserMessage(HermesMessage message) async {
    if (!message.isVisibleUser) return;
    final original = stripBotMentionHandoff(message.content ?? '');
    final ctrl = TextEditingController(text: original);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.editMessage),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          minLines: 3,
          autofocus: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            hintText: context.l10n.messageHintShort,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(context.l10n.saveAndResend),
          ),
        ],
      ),
    );
    // dispose after dialog closes
    // ignore: unawaited_futures
    Future<void>.delayed(const Duration(milliseconds: 100), ctrl.dispose);

    if (next == null || next.isEmpty || next == original.trim()) return;
    final ordinal = _userOrdinalForMessage(message);
    if (ordinal == null) return;

    await _waitUntilIdle();

    // No standby() bracket needed here either — same reasoning as
    // [_retryFrom]'s truncate: the [_send] call right below re-pins.
    final userIdx = _messages.indexWhere((m) => m.id == message.id);
    if (userIdx >= 0) {
      setState(() {
        _messages = [
          ..._messages.take(userIdx),
          HermesMessage(
            id: message.id,
            sessionId: _session.id,
            role: 'user',
            content: next,
            timestamp: message.timestamp,
          ),
        ];
      });
    }
    await _send(
      text: next,
      truncateBeforeUserOrdinal: ordinal,
      interruptFirst: true,
      skipOptimisticAppend: true,
    );
  }

  Future<void> _onMessageLongPress(HermesMessage message) async {
    if (message.isTool) return;
    hermesHaptic(HapticIntent.selection);
    final isUser = message.isVisibleUser;
    final unanswered = isUser && _isUnansweredUser(message);
    final apiError = _isApiErrorMessage(message);
    // One primary re-run action: Resend (no reply / error) or Retry/Regenerate.
    // Edit is separate. No duplicate subtitles that restate the same thing.
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final l10n = ctx.l10n;
        final reRunLabel = isUser
            ? (unanswered ? l10n.resend : l10n.retry)
            : (apiError ? l10n.resend : l10n.regenerate);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isUser || apiError)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(l10n.editMessage),
                  onTap: () => Navigator.pop(ctx, 'edit'),
                ),
              ListTile(
                leading: Icon(
                  unanswered || apiError ? Icons.send_outlined : Icons.refresh,
                ),
                title: Text(reRunLabel),
                onTap: () => Navigator.pop(ctx, 'retry'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: Text(l10n.copy),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
              if (!isUser && !apiError)
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: Text(l10n.readAloud),
                  onTap: () => Navigator.pop(ctx, 'speak'),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.delete),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        final target = isUser ? message : _precedingUser(message);
        if (target != null) await _editUserMessage(target);
      case 'retry':
        await _retryFrom(message);
      case 'delete':
        await _deleteMessage(message);
      case 'copy':
        final text = stripBotMentionHandoff(message.content ?? '');
        if (text.isNotEmpty) {
          hermesHaptic(HapticIntent.selection);
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(context.l10n.copied)));
          }
        }
      case 'speak':
        final text = stripBotMentionHandoff(message.content ?? '');
        if (text.isNotEmpty) {
          hermesHaptic(HapticIntent.open);
          unawaited(_speaker.speakOnce(text));
        }
    }
  }

  /// Delete a single message. Destructive + not undoable, so this always
  /// confirms first.
  ///
  /// The gateway has no arbitrary single-message delete (only whole-session
  /// delete, and `session.undo`, which drops the trailing user turn plus
  /// everything after it — not just the one message being removed here), so
  /// this only ever removes the message from this device. The confirmation
  /// copy says so explicitly rather than silently implying server-side
  /// deletion.
  Future<void> _deleteMessage(HermesMessage message) async {
    hermesHaptic(HapticIntent.warning);
    final l10n = context.l10n;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.deleteMessageTitle),
            content: Text(l10n.deleteMessageBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    // Tell the observer a removal is coming *before* mutating the list, so
    // its scroll-physics override (invoked during the relayout that follows)
    // knows not to try to apply a growth-style correction.
    _chatObserver.standby(isRemove: true);
    setState(() {
      _messages = [
        for (final m in _messages)
          if (m.id != message.id) m,
      ];
    });

    final sync = ref.read(sessionSyncProvider);
    try {
      await sync?.deleteMessageLocal(_session.id, message.id);
    } catch (e) {
      debugPrint('SessionSync: deleteMessageLocal failed: $e');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.messageDeleted)));
  }

  void _appendSystem(String text) {
    if (!mounted) return;
    final body = text.trim();
    if (body.isEmpty) return;
    // A new message inserted at the newest-message end (list index 0 in the
    // reversed view) — tell the observer before mutating so a reader
    // scrolled up doesn't get shoved by it.
    _chatObserver.standby(changeCount: 1);
    setState(() {
      _messages = [
        ..._messages,
        HermesMessage(
          id: 'slash_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: _session.id,
          role: 'system',
          content: body,
          timestamp: DateTime.now().toUtc().toIso8601String(),
        ),
      ];
    });
  }

  /// Mobile-owned slash surfaces (mirror Desktop action handlers).
  Future<bool> _handleClientSlash(String name, String arg, String raw) async {
    switch (name) {
      case 'new':
      case 'reset':
      case 'clear':
        // clear = new session on mobile (no terminal screen clear).
        widget.onNewChat?.call();
        if (widget.onNewChat == null) {
          _appendSystem('Start a new chat from the menu (New chat).');
        }
        return true;
      case 'model':
        if (arg.isEmpty) {
          await _pickModel();
          return true;
        }
        // `/model provider:name` or bare model id — session-scope like Desktop.
        final colon = arg.indexOf(':');
        final model = colon > 0 ? arg.substring(colon + 1).trim() : arg.trim();
        final provider = colon > 0 ? arg.substring(0, colon).trim() : null;
        if (model.isEmpty) return false;
        await ref
            .read(selectedModelProvider.notifier)
            .select(model, provider: provider);
        final sync = ref.read(sessionSyncProvider);
        if (sync != null) {
          await sync.applySessionModel(
            sessionId: _session.id,
            model: model,
            provider: provider,
          );
        }
        _appendSystem(
          slashStatusText(
            raw,
            'Model set to $model${provider != null ? ' ($provider)' : ''}',
          ),
        );
        hermesHaptic(HapticIntent.success);
        return true;
      case 'title':
        if (arg.isEmpty) return false; // bare /title → gateway
        final sync = ref.read(sessionSyncProvider);
        if (sync == null) return false;
        await sync.renameSession(_session.id, arg);
        setState(() {
          _session = HermesSession(
            id: _session.id,
            source: _session.source,
            userId: _session.userId,
            model: _session.model,
            title: arg,
            startedAt: _session.startedAt,
            endedAt: _session.endedAt,
            endReason: _session.endReason,
            messageCount: _session.messageCount,
            toolCallCount: _session.toolCallCount,
            lastActive: _session.lastActive,
            preview: _session.preview,
            parentSessionId: _session.parentSessionId,
          );
        });
        widget.onSessionUpdated?.call(_session);
        _appendSystem(slashStatusText(raw, 'Session title set: $arg'));
        hermesHaptic(HapticIntent.success);
        return true;
      case 'resume':
      case 'sessions':
      case 'switch':
        if (arg.isEmpty) {
          _appendSystem(
            'Usage: /resume <session-id> — or open a chat from the drawer.',
          );
          return true;
        }
        final id = arg.split(RegExp(r'\s+')).first;
        widget.onOpenSessionId?.call(id);
        if (widget.onOpenSessionId == null) {
          _appendSystem('Open session $id from the chats drawer.');
        }
        return true;
      case 'skin':
        final skins = kBuiltinSkins;
        if (arg.isEmpty) {
          final cur = ref.read(appSkinProvider);
          final ids = skins.map((s) => s.id).toList();
          final i = ids.indexOf(cur.id);
          final next = skins[(i + 1) % skins.length];
          await ref.read(appSkinIdProvider.notifier).select(next.id);
          _appendSystem(slashStatusText(raw, 'Theme: ${next.label}'));
        } else {
          final needle = arg.toLowerCase();
          final match = skins.where(
            (s) =>
                s.id.toLowerCase() == needle || s.label.toLowerCase() == needle,
          );
          if (match.isEmpty) {
            _appendSystem(
              'Unknown skin. Try: ${skins.map((s) => s.id).join(', ')}',
            );
          } else {
            await ref.read(appSkinIdProvider.notifier).select(match.first.id);
            _appendSystem(slashStatusText(raw, 'Theme: ${match.first.label}'));
          }
        }
        hermesHaptic(HapticIntent.selection);
        return true;
      case 'stop':
        await _stopGeneration();
        _appendSystem(slashStatusText(raw, L10n.current.stopRequested));
        return true;
      case 'skills':
        // `/skills` subcommands (pending/approve/…) stay on gateway;
        // bare `/skills` opens the mobile catalog so users can pull & run.
        if (arg.trim().isNotEmpty) return false;
        await _pickAndRunSkill();
        return true;
      case 'reload-skills':
      case 'reload_skills':
        final sync = ref.read(sessionSyncProvider);
        if (sync == null) return false;
        final msg = await ref.read(skillsProvider.notifier).reloadFromGateway();
        _appendSystem(slashStatusText(raw, msg));
        hermesHaptic(HapticIntent.success);
        return true;
      default:
        return false;
    }
  }

  Future<void> _pickAndRunSkill() async {
    final cmd = await showSkillsPickerSheet(context, ref);
    if (cmd == null || !mounted) return;
    // Prefill so the user can add an instruction, or send bare.
    final withSpace = cmd.endsWith(' ') ? cmd : '$cmd ';
    _composer.value = TextEditingValue(
      text: withSpace,
      selection: TextSelection.collapsed(offset: withSpace.length),
    );
    hermesHaptic(HapticIntent.selection);
  }

  Future<void> _runSlash(String command) async {
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    final model = _sessionModel ?? _session.model;
    final provider = _sessionProvider;

    hermesHaptic(HapticIntent.submit);
    // No standby() bracket — this optimistic append is immediately followed
    // by the re-pin below, in the same synchronous stretch of code (see the
    // classification comment above the `_messages` field).
    setState(() {
      _composer.clear();
      _sending = true;
      _error = null;
      _toolStatus = 'Running $command…';
      _messages = [
        ..._messages,
        HermesMessage(
          id: 'local_slash_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: _session.id,
          role: 'user',
          content: command,
          timestamp: DateTime.now().toUtc().toIso8601String(),
        ),
      ];
    });
    // Explicit user action — always jump back to latest, even if they'd
    // scrolled up to read history.
    unawaited(_scrollToBottom());

    try {
      final result = await sync.runSlashCommand(
        sessionId: _session.id,
        command: command,
        model: model,
        provider: provider,
        callbacks: SlashCallbacks(
          sys: (t) {
            // Prefer slash:status framing when it's plain command output.
            _appendSystem(
              t.startsWith('slash:') ? t : slashStatusText(command, t),
            );
          },
          send: (msg) async {
            // Nested agent turn after skill/send dispatch.
            if (!mounted) return;
            setState(() => _sending = false);
            await _send(text: msg, skipOptimisticAppend: false);
          },
          prefill: (msg) {
            if (!mounted) return;
            _composer.text = msg;
            _composer.selection = TextSelection.collapsed(offset: msg.length);
          },
          onClientCommand: _handleClientSlash,
        ),
      );

      if (!mounted) return;
      if (result == SlashExecResult.error) {
        FeedbackService.instance.error();
      } else {
        hermesHaptic(HapticIntent.success);
      }
      // If send() already nested, _sending is false; otherwise clear here.
      if (_sending) {
        setState(() {
          _sending = false;
          _toolStatus = null;
        });
      } else {
        setState(() => _toolStatus = null);
      }
      unawaited(ref.read(sessionsProvider.notifier).softRefresh());
    } catch (e) {
      if (!mounted) return;
      FeedbackService.instance.error();
      setState(() {
        _sending = false;
        _toolStatus = null;
        _error = context.l10n.slashFailed('$e');
      });
      _appendSystem(slashStatusText(command, 'error: $e'));
    }
  }

  Future<void> _send({
    String? text,
    int? truncateBeforeUserOrdinal,
    bool interruptFirst = false,
    bool skipOptimisticAppend = false,
  }) async {
    final body = (text ?? _composer.text).trim();
    // Allow image-only sends (Desktop can attach then prompt "what's this?").
    final hasImages = _attachments.isNotEmpty;
    // Synchronous latch — setState is async to the next frame; double-tap
    // would otherwise append two optimistic user bubbles.
    if ((body.isEmpty && !hasImages) || _sending) return;
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;

    // Slash path — never hit prompt.submit for `/…` (web/Desktop parity).
    if (body.isNotEmpty && looksLikeSlashCommand(body) && !hasImages) {
      await _runSlash(body);
      return;
    }

    final model =
        _sessionModel ??
        _session.model ??
        ref.read(selectedModelProvider).value;
    var provider = _sessionProvider ?? ref.read(selectedProviderProvider).value;
    final reasoningEffort =
        _sessionReasoningEffort ??
        ref.read(selectedReasoningEffortProvider).value ??
        'medium';
    final fastMode =
        _sessionFastMode ?? ref.read(selectedFastModeProvider).value ?? false;
    // Older sessions may have no persisted provider; resolve it only when the
    // catalog confirms the model's owner.
    if (model != null && model.trim().isNotEmpty) {
      final opts = ref.read(modelOptionsProvider).value;
      if (opts != null) {
        provider = providerForModel(opts, model, preferred: provider);
      }
    }
    final prompt = body.isEmpty
        ? (hasImages
              ? 'Please look at the attached image${_attachments.length > 1 ? 's' : ''}.'
              : '')
        : body;
    if (prompt.isEmpty) return;

    _sending = true;
    hermesHaptic(HapticIntent.submit);
    hermesHaptic(HapticIntent.streamStart);

    // No standby() bracket — the optimistic append + dedupe below is
    // immediately followed by the re-pin further down (see the
    // classification comment above the `_messages` field).
    setState(() {
      if (text == null) _composer.clear();
      _sending = true;
      // Immediate feedback — don't wait for first token / tool event.
      _toolStatus = hasImages
          ? L10n.current.uploadingImage
          : L10n.current.thinking;
      _error = null;
      _queuedHint = false;
      if (!skipOptimisticAppend) {
        final label = hasImages && body.isEmpty
            ? '📷 ${_attachments.length} image${_attachments.length > 1 ? 's' : ''}'
            : (hasImages ? '$body\n📷 ${_attachments.length} image(s)' : body);
        final alreadyOptimistic = _messages.any(
          (m) =>
              m.isUser &&
              (m.id.startsWith('local_user_') || m.id.startsWith('local_')) &&
              (m.content ?? '').trim() == label.trim(),
        );
        if (!alreadyOptimistic) {
          _messages = [
            ..._messages,
            HermesMessage(
              id: 'local_user_${DateTime.now().microsecondsSinceEpoch}',
              sessionId: _session.id,
              role: 'user',
              content: label,
              timestamp: DateTime.now().toUtc().toIso8601String(),
            ),
          ];
        }
      }
      _messages = dedupeAdjacentUserMessages(_messages);
    });
    // Explicit user action — always jump back to latest, even if they'd
    // scrolled up to read history.
    unawaited(_scrollToBottom());

    try {
      await _uploadAttachments(sync);
    } catch (e) {
      if (!mounted) return;
      FeedbackService.instance.error();
      setState(() {
        _sending = false;
        _toolStatus = null;
        _error = L10n.current.imageAttachFailed('$e');
      });
      return;
    }

    final bots =
        ref.read(botsProvider).value?.profiles ?? const <HermesBotProfile>[];
    final activeProfile = widget.profileName?.trim().isNotEmpty == true
        ? widget.profileName!.trim()
        : 'default';
    final activeBot = bots
        .where(
          (bot) => bot.name.trim().toLowerCase() == activeProfile.toLowerCase(),
        )
        .firstOrNull;
    final wirePrompt = appendBotMentionHandoff(
      text: prompt,
      roster: bots,
      activeProfile: activeProfile,
      senderName: activeBot?.displayName ?? 'Hermes',
      senderHandle: activeBot?.handle ?? 'hermes',
    );

    final result = await sync.sendMessage(
      sessionId: _session.id,
      input: wirePrompt,
      model: model,
      provider: provider,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      interruptFirst: interruptFirst,
      onToolStatus: (s) {
        if (!mounted) return;
        // No standby() here: this only changes the status-strip text below
        // the list, which resizes the *viewport*, not any list item's
        // layoutOffset — the observer's ref-item delta would compute to
        // zero regardless, so there's nothing to correct for.
        setState(() {
          // Empty string = clear tool line but keep a soft "writing" cue while
          // tokens are still arriving (stream bubble covers that).
          if (s.isEmpty) {
            final hasStream = _messages.any(
              (m) => m.isAssistant && m.id.startsWith('stream_'),
            );
            _toolStatus = hasStream ? null : L10n.current.thinking;
          } else {
            _toolStatus = s;
          }
        });
      },
      onAssistantDelta: (partial) {
        if (!mounted) return;
        // The streaming bubble is growing in place (same id, more content) —
        // this is exactly scrollview_observer's "generative" case (its own
        // doc comment: "Such as ChatGPT streaming messages"). standby() runs
        // synchronously (no `await` on this code path), recording a
        // reference item's current layoutOffset *before* the mutation below;
        // ChatObserverClampingScrollPhysics.adjustPositionForNewDimensions
        // then re-measures that same item during the relayout this setState
        // triggers and corrects `pixels` by the delta — in the same frame,
        // so nothing is ever painted in the wrong place first.
        _chatObserver.standby(mode: ChatScrollObserverHandleMode.generative);
        setState(() {
          // Tokens flowing — drop status strip (bubble is the indicator).
          if (partial.trim().isNotEmpty) {
            _toolStatus = null;
          }
          final withoutTrailingAssistant = [
            for (final m in _messages)
              if (!(m.isAssistant && m.id.startsWith('stream_'))) m,
          ];
          _messages = [
            ...withoutTrailingAssistant,
            HermesMessage(
              id: 'stream_partial',
              sessionId: _session.id,
              role: 'assistant',
              content: partial,
              timestamp: DateTime.now().toIso8601String(),
            ),
          ];
        });
      },
      onApprovalRequest: (request) {
        if (!mounted) return;
        setState(() {
          _approvalRequest = request;
          if (request == null) _approvalResponding = false;
        });
      },
    );

    if (!mounted) return;
    final resultHasApiError =
        result.error != null ||
        result.messages.any((m) => isCompletionErrorText(m.content));
    if (resultHasApiError) {
      FeedbackService.instance.error();
    } else if (result.queued) {
      hermesHaptic(HapticIntent.warning);
    } else {
      FeedbackService.instance.streamDone();
      _maybeSpeakAssistant(result.messages);
    }
    // Prefer server transcript, but keep optimistic user/stream if sync was
    // empty. Computed outside `setState` (pure — reads `_messages` but
    // doesn't touch it) so [_standbyForWholesaleReplace] can brief the
    // observer with the *old* `_messages.length` before the swap below.
    var next = dedupeAdjacentUserMessages(result.messages);
    final hasUser = next.any((m) => m.isUser);
    if (next.isEmpty || !hasUser) {
      final preserved = [
        for (final m in _messages)
          if (m.isUser || (m.isAssistant && m.id.startsWith('stream_'))) m,
      ];
      next = dedupeAdjacentUserMessages([
        ...preserved,
        for (final m in next)
          if (!preserved.any(
            (p) =>
                p.id == m.id ||
                (p.isUser &&
                    m.isUser &&
                    (p.content ?? '').trim() == (m.content ?? '').trim()) ||
                (p.isAssistant &&
                    m.isAssistant &&
                    (p.content ?? '').trim() == (m.content ?? '').trim()),
          ))
            m,
      ]);
    }

    // Desktop parity: API failures must appear as an assistant bubble, e.g.
    // "API call failed after 3 retries: Connection error."
    String? resolvedError;
    if (result.error != null && result.error!.trim().isNotEmpty) {
      final userFacing = formatTurnErrorForUser(result.error);
      next = ensureErrorAssistantMessage(
        next,
        sessionId: _session.id,
        errorText: userFacing,
      );
      // Prefer the in-transcript banner; keep a short strip only if missing.
      resolvedError = transcriptHasErrorAssistant(next, errorText: userFacing)
          ? null
          : userFacing;
    } else if (result.queued) {
      resolvedError = L10n.current.savedWaitingWs;
    } else {
      resolvedError = null;
    }

    // End-of-turn wholesale replace: not covered by the send-time re-pin
    // (that already ran, and the user may have scrolled away again during
    // the stream that followed), so it needs its own bracket. The `setState`
    // below is unconditional regardless of whether the transcript itself
    // changed (`_sending`/`_toolStatus`/etc. always do), so this calls
    // [_standbyForWholesaleReplace] directly rather than going through
    // [_replaceMessages] (which would also decide whether to skip a
    // `setState` this call site can't skip anyway).
    _standbyForWholesaleReplace(next);

    setState(() {
      _error = resolvedError;
      _messages = next;
      _sending = false;
      _toolStatus = null;
      _approvalRequest = null;
      _approvalResponding = false;
      _queuedHint = result.queued;
      // Context occupancy updates after each turn (Desktop status bar).
      unawaited(_refreshContextUsage(fullBreakdown: true));
      if (result.sessionId != null && result.sessionId != _session.id) {
        _session = HermesSession(
          id: result.sessionId!,
          source: _session.source,
          userId: _session.userId,
          model: _session.model,
          title: _session.title,
          startedAt: _session.startedAt,
          endedAt: _session.endedAt,
          endReason: _session.endReason,
          messageCount: _session.messageCount,
          toolCallCount: _session.toolCallCount,
          lastActive: _session.lastActive,
          preview: _session.preview,
          parentSessionId: _session.parentSessionId,
        );
        widget.onSessionUpdated?.call(_session);
      }
    });
    unawaited(ref.read(sessionsProvider.notifier).softRefresh());
  }

  Future<void> _respondToApproval(String choice) async {
    final request = _approvalRequest;
    final sync = ref.read(sessionSyncProvider);
    if (request == null || sync == null || _approvalResponding) return;
    setState(() {
      _approvalResponding = true;
      _error = null;
    });
    try {
      await sync.respondToApproval(
        sessionId: request.sessionId,
        choice: choice,
      );
      if (!mounted) return;
      hermesHaptic(
        choice == 'deny' ? HapticIntent.cancel : HapticIntent.submit,
      );
      setState(() {
        _approvalRequest = null;
        _approvalResponding = false;
      });
    } catch (e) {
      if (!mounted) return;
      FeedbackService.instance.error();
      setState(() {
        _approvalResponding = false;
        _error = 'Could not send approval response: $e';
      });
    }
  }

  /// Look up provider slug for a model id from cached /api/model/options.
  String? _providerSlugForModel(String modelId) {
    final opts = ref.read(modelOptionsProvider).value;
    if (opts == null) return null;
    return providerForModel(opts, modelId);
  }

  Future<void> _pickModel() async {
    try {
      await _runtimeHydration;
    } catch (_) {}
    if (!mounted) return;
    final pick = await showModelPickerSheet(
      context,
      ref,
      sessionId: _session.id,
      initialModel: _sessionModel ?? _session.model,
      initialProvider: _sessionProvider,
      initialReasoningEffort: _sessionReasoningEffort,
      initialFastMode: _sessionFastMode,
    );
    if (pick == null || !mounted) return;

    final provider = (pick.provider != null && pick.provider!.trim().isNotEmpty)
        ? pick.provider
        : _providerSlugForModel(pick.model);
    final effort = pick.reasoningEffort ?? _sessionReasoningEffort ?? 'medium';
    final fast = pick.fastMode ?? _sessionFastMode ?? false;

    await ref
        .read(selectedModelProvider.notifier)
        .select(pick.model, provider: provider);
    await ref.read(selectedReasoningEffortProvider.notifier).select(effort);
    await ref.read(selectedFastModeProvider.notifier).select(fast);

    final sync = ref.read(sessionSyncProvider);
    if (sync != null) {
      try {
        await sync.applySessionModel(
          sessionId: _session.id,
          model: pick.model,
          provider: provider,
        );
        if (pick.reasoningSupported) {
          await sync.applySessionReasoning(
            sessionId: _session.id,
            effort: effort,
          );
        }
        if (pick.fastModeSupported) {
          await sync.applySessionFast(sessionId: _session.id, enabled: fast);
        }
        if (!mounted) return;
        setState(() {
          _sessionModel = pick.model;
          _sessionProvider = provider;
          _sessionReasoningEffort = effort;
          _sessionFastMode = pick.fastModeSupported ? fast : false;
          _session = HermesSession(
            id: _session.id,
            source: _session.source,
            userId: _session.userId,
            model: pick.model,
            title: _session.title,
            startedAt: _session.startedAt,
            endedAt: _session.endedAt,
            endReason: _session.endReason,
            messageCount: _session.messageCount,
            toolCallCount: _session.toolCallCount,
            lastActive: _session.lastActive,
            preview: _session.preview,
            parentSessionId: _session.parentSessionId,
          );
          _error = null;
        });
        widget.onSessionUpdated?.call(_session);
        unawaited(ref.read(sessionsProvider.notifier).softRefresh());
      } catch (e) {
        if (!mounted) return;
        FeedbackService.instance.error();
        setState(() => _error = context.l10n.modelSavedLocal('$e'));
      }
    }
  }

  Future<void> _renameCurrentSession() async {
    final next = await showRenameSessionDialog(
      context,
      initialTitle: _session.title ?? '',
    );
    if (!mounted || next == null || next == (_session.title ?? '').trim()) {
      return;
    }
    final sync = ref.read(sessionSyncProvider);
    if (sync == null) return;
    try {
      await sync.renameSession(_session.id, next);
      if (!mounted) return;
      final renamed = HermesSession(
        id: _session.id,
        source: _session.source,
        userId: _session.userId,
        model: _session.model,
        title: next.isEmpty ? null : next,
        startedAt: _session.startedAt,
        endedAt: _session.endedAt,
        endReason: _session.endReason,
        messageCount: _session.messageCount,
        toolCallCount: _session.toolCallCount,
        lastActive: _session.lastActive,
        preview: _session.preview,
        parentSessionId: _session.parentSessionId,
      );
      setState(() => _session = renamed);
      widget.onSessionUpdated?.call(renamed);
      hermesHaptic(HapticIntent.success);
      unawaited(ref.read(sessionsProvider.notifier).softRefresh());
    } catch (error) {
      if (!mounted) return;
      FeedbackService.instance.error();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.renameFailed('$error'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The list below always renders the *live* transcript — there is no
    // frozen snapshot any more. Reading-position preservation while
    // scrolled up mid-stream is handled by `_chatObserver` correcting the
    // scroll offset during layout (see the `standby()` call sites), not by
    // holding back what gets rendered.
    final renderMessages = _messages
        .where((message) => !isInternalBackgroundCompletion(message))
        .toList(growable: false);
    final artifactPaths = _knownArtifactPaths(renderMessages);
    final botProfiles =
        ref.watch(botsProvider).value?.profiles ?? const <HermesBotProfile>[];
    final activeProfile = widget.profileName?.trim().isNotEmpty == true
        ? widget.profileName!.trim()
        : 'default';
    final showThinking = _showThinkingBubble;
    final renderSending = _sending;
    final statusText = _showStatusStrip ? _toolStatus : null;
    final errorText = _error;
    // Existing sessions render their own runtime identity. The global sticky
    // pick is only a fallback for a brand-new session with no model yet.
    final modelId =
        (_sessionModel ?? _session.model ?? ref.watch(resolvedModelIdProvider))
            ?.trim() ??
        context.l10n.selectModel;
    final model = modelChipLabel(
      modelId,
      _sessionReasoningEffort ?? 'medium',
      fast: _sessionFastMode ?? false,
    );

    final body = Column(
      children: [
        // Model + context usage (Desktop status-bar parity).
        Material(
          color: theme.scaffoldBackgroundColor,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickModel,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.9,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              model,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 18,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ContextUsageChip(
                  usage: _usage,
                  breakdown: _contextBreakdown,
                  onTap: _openContextUsage,
                ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          color: theme.colorScheme.outline.withValues(alpha: 0.35),
        ),
        Expanded(
          child: Stack(
            children: [
              _loading && renderMessages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : renderMessages.isEmpty
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      child: Center(
                        child: Text(
                          context.l10n.sendAMessageToContinue,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                      ),
                    )
                  // reverse:true → newest at bottom, open already scrolled
                  // there; pin detection lives in _onScroll. Reading
                  // position while scrolled up mid-stream is held by
                  // ChatObserverClampingScrollPhysics (see _chatObserver
                  // standby() call sites) — not by anything in this list.
                  : ListViewObserver(
                      controller: _observerController,
                      child: ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        physics: _chatScrollPhysics,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        // +1 thinking/typing row while waiting for first token.
                        itemCount:
                            renderMessages.length + (showThinking ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (showThinking && i == 0) {
                            // reverse list: index 0 is visual bottom.
                            return const _ThinkingBubble();
                          }
                          final msgIndex = showThinking
                              ? renderMessages.length - i
                              : renderMessages.length - 1 - i;
                          final msg = renderMessages[msgIndex];
                          final unanswered =
                              msg.isUser &&
                              isUnansweredUserAt(
                                renderMessages,
                                msgIndex,
                                sending: renderSending,
                              );
                          final apiError = _isApiErrorMessage(msg);
                          return _MessageBubble(
                            message: msg,
                            loadGeneratedImage: _loadGeneratedImage,
                            knownArtifactPaths: artifactPaths,
                            unanswered: unanswered,
                            showRetryActions: unanswered || apiError,
                            onLongPress: () => _onMessageLongPress(msg),
                            onResend: () => unawaited(_retryFrom(msg)),
                            onEdit: () {
                              final target = msg.isUser
                                  ? msg
                                  : _precedingUser(msg);
                              if (target != null) {
                                unawaited(_editUserMessage(target));
                              }
                            },
                          );
                        },
                      ),
                    ),
              if (!_pinnedToBottom && renderMessages.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _JumpToLatestButton(
                    onTap: () => unawaited(_scrollToBottom()),
                  ),
                ),
            ],
          ),
        ),
        // Frozen along with the list: this strip sits below the Expanded
        // list, so it appearing/disappearing resizes the list viewport — and
        // a reverse viewport is anchored to its *bottom* edge, so that moves
        // every rendered pixel.
        if (statusText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    statusText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_queuedHint)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              context.l10n.queuedForSync,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              errorText,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        if (_approvalRequest case final request?)
          _GatewayApprovalBar(
            request: request,
            responding: _approvalResponding,
            onRespond: (choice) => unawaited(_respondToApproval(choice)),
          ),
        ChatComposerBar(
          controller: _composer,
          sending: _sending,
          onSend: () => _send(),
          onStop: _stopGeneration,
          // Short hint — long "Message Hermes Go…" wraps under the + chip.
          hint: context.l10n.messageHintShort,
          attachments: _attachments,
          onAttachmentsChanged: (next) => setState(() => _attachments = next),
          readAloud: _readAloud,
          onReadAloudChanged: (v) {
            setState(() => _readAloud = v);
            _speaker.setEnabled(v);
            if (!v) unawaited(_speaker.stop());
          },
          slashCompleter: (text) async {
            final sync = ref.read(sessionSyncProvider);
            if (sync == null) return const [];
            return sync.completeSlashWithSkills(text);
          },
          onPickSkill: () => unawaited(_pickAndRunSkill()),
          botMentions: botProfiles,
          activeProfile: activeProfile,
        ),
      ],
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: widget.isCanonicalBotChat ? null : _renameCurrentSession,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _session.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!widget.isCanonicalBotChat) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (widget.onOpenBotSessions != null)
            TextButton.icon(
              onPressed: widget.onOpenBotSessions,
              icon: const Icon(Icons.forum_outlined, size: 18),
              label: const Text('Sessions'),
            ),
          if (widget.onOpenBotSessions == null)
            IconButton(
              tooltip: context.l10n.sync,
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.sync),
            ),
        ],
      ),
      body: body,
    );
  }

  Future<String> _loadGeneratedImage(String source) async {
    final profile = ref.read(connectionProfileProvider).value;
    if (profile == null) {
      throw StateError('No active gateway connection');
    }
    return DashboardClient(profile: profile).readGeneratedImage(
      source,
      profileName: widget.profileName,
      sessionId: _session.id,
    );
  }
}

class _GatewayApprovalBar extends StatelessWidget {
  const _GatewayApprovalBar({
    required this.request,
    required this.responding,
    required this.onRespond,
  });

  final GatewayApprovalRequest request;
  final bool responding;
  final ValueChanged<String> onRespond;

  Future<void> _selectChoice(BuildContext context, String choice) async {
    if (choice != 'always') {
      onRespond(choice);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Always allow this command?'),
        content: const Text(
          'This permanently saves an approval rule on your Hermes server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Always allow'),
          ),
        ],
      ),
    );
    if (confirmed == true) onRespond(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choices = request.choices.toSet();
    final moreChoices = <String>[
      if (choices.contains('session')) 'session',
      if (choices.contains('always')) 'always',
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.description.isEmpty
                      ? 'Approval needed'
                      : request.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
          if (request.command.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              request.command,
              maxLines: 3,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: responding || !choices.contains('once')
                    ? null
                    : () => onRespond('once'),
                icon: responding
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Run'),
              ),
              if (moreChoices.isNotEmpty)
                PopupMenuButton<String>(
                  enabled: !responding,
                  tooltip: 'More approval options',
                  onSelected: (choice) => _selectChoice(context, choice),
                  itemBuilder: (_) => [
                    if (moreChoices.contains('session'))
                      const PopupMenuItem(
                        value: 'session',
                        child: Text('Allow for this session'),
                      ),
                    if (moreChoices.contains('always'))
                      const PopupMenuItem(
                        value: 'always',
                        child: Text('Always allow'),
                      ),
                  ],
                ),
              const Spacer(),
              TextButton(
                onPressed: responding || !choices.contains('deny')
                    ? null
                    : () => onRespond('deny'),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Floating "scroll to latest" affordance shown while the user has scrolled
/// away from the newest message. Icon-only (no label) so it doesn't need a
/// new l10n string — the down-arrow-into-a-pill is a widely understood chat
/// convention (Claude/ChatGPT/iMessage all use the same shape).
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          hermesHaptic(HapticIntent.selection);
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.arrow_downward_rounded,
            size: 20,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

/// Claude-style “thinking” row: pulsing dots + label while the agent works
/// before the first assistant token.
class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble();

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.55,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dots only — no "Thinking" label (status strip handles tools).
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final phase = (_ctrl.value + i * 0.2) % 1.0;
                    final t = (phase < 0.5 ? phase : 1 - phase) * 2;
                    final opacity = 0.35 + 0.65 * t;
                    final dy = -2.0 * t;
                    return Transform.translate(
                      offset: Offset(0, dy),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.loadGeneratedImage,
    this.knownArtifactPaths = SessionArtifactPaths.empty,
    this.onLongPress,
    this.onResend,
    this.onEdit,
    this.unanswered = false,
    this.showRetryActions = false,
  });

  final HermesMessage message;
  final GeneratedImageLoader? loadGeneratedImage;

  /// Session-wide artifact paths, computed once per transcript change by the
  /// screen — a bubble must not rebuild it, it rebuilds on every token.
  final SessionArtifactPaths knownArtifactPaths;
  final VoidCallback? onLongPress;
  final VoidCallback? onResend;
  final VoidCallback? onEdit;
  final bool unanswered;
  final bool showRetryActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final isTool = message.isTool;
    final isSystem = message.isSystem;
    // Gate: the artifact viewer is paused for v1 (see
    // kArtifactViewerEnabled's doc comment in artifact_viewer_flags.dart —
    // one line to flip when it comes back). This is the chip's single entry
    // point: with it off, `artifacts` is always empty, so the `Wrap` below
    // never builds and no `_ArtifactChip` is ever pushed.
    final artifacts = kArtifactViewerEnabled
        ? detectArtifactsInMessage(message, known: knownArtifactPaths)
        : const <DetectedArtifact>[];
    // Slash/system status — strip `slash:/cmd` prefix for a cleaner label.
    var body = stripBotMentionHandoff(message.content ?? '').trim();
    String? slashLabel;
    if (isSystem && body.startsWith('slash:')) {
      final nl = body.indexOf('\n');
      slashLabel = nl < 0 ? body.substring(6) : body.substring(6, nl);
      body = nl < 0 ? '' : body.substring(nl + 1).trim();
    }

    // Desktop parity: provider/API failures render as error banners, not
    // normal assistant prose (e.g. "API call failed after 3 retries: …").
    final isApiError =
        !isUser &&
        (message.finishReason == 'error' || isCompletionErrorText(body));
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.circular(isSystem || isApiError ? 12 : 18);
    final bg = isUser
        ? theme.colorScheme.primary.withValues(alpha: 0.16)
        : isApiError
        ? theme.colorScheme.errorContainer.withValues(alpha: 0.55)
        : isTool
        ? theme.colorScheme.surfaceContainerHighest
        : isSystem
        ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.45)
        : Colors.transparent;
    final fg = isApiError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurface;

    final bubble = Material(
      color: bg,
      borderRadius: radius,
      child: InkWell(
        // Material long-press wins over SelectableText selection on iOS.
        onLongPress: isTool ? null : onLongPress,
        borderRadius: radius,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isUser || isTool || isSystem || isApiError ? 14 : 4,
            vertical: isUser || isTool || isSystem || isApiError ? 10 : 4,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: isSystem || isApiError || unanswered
                ? Border.all(
                    color: isApiError || unanswered
                        ? theme.colorScheme.error.withValues(alpha: 0.45)
                        : theme.colorScheme.outline.withValues(alpha: 0.25),
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isApiError)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.l10n.error,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              if (unanswered && !isApiError)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    context.l10n.noResponseYet,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (isTool)
                ToolMessageContent(
                  message: message,
                  loadGeneratedImage: loadGeneratedImage,
                )
              else if (message.toolName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    message.toolName ?? 'tool',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ),
              if (slashLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    slashLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (!isTool && (body.isNotEmpty || !isSystem))
                _MessageBody(
                  text: body.isNotEmpty
                      ? body
                      : (isUser ? '' : (isSystem ? '' : '…')),
                  isUser: isUser,
                  color: fg,
                  // Selection fights long-press; copy lives in the sheet.
                  selectable: false,
                ),
              if (artifacts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: artifacts
                        .map((a) => _ArtifactChip(artifact: a))
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              MediaQuery.sizeOf(context).width *
              (isUser ? 0.86 : (isSystem || isApiError ? 0.92 : 0.96)),
        ),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: bubble,
            ),
            // Only the two primary recoveries — Copy / more stay on long-press.
            if (showRetryActions && !isTool)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
                  children: [
                    if (onResend != null)
                      ActionChip(
                        avatar: const Icon(Icons.send_outlined, size: 16),
                        label: Text(context.l10n.resend),
                        onPressed: onResend,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (onEdit != null)
                      ActionChip(
                        avatar: const Icon(Icons.edit_outlined, size: 16),
                        label: Text(context.l10n.editMessage),
                        onPressed: onEdit,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tappable row for a `.md`/`.html` file the agent produced this turn (see
/// `detectArtifactsInMessage`) — opens [ArtifactViewerScreen]. Sits inside
/// the tool/assistant bubble, below the body, in the same
/// Material+InkWell idiom as the rest of this screen's tappable rows
/// (e.g. `_JumpToLatestButton`, the bubble itself).
class _ArtifactChip extends StatelessWidget {
  const _ArtifactChip({required this.artifact});

  final DetectedArtifact artifact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = artifact.kind == ArtifactFileKind.markdown
        ? Icons.description_outlined
        : Icons.language_outlined;
    final kindLabel = artifact.kind == ArtifactFileKind.markdown
        ? context.l10n.artifactKindMarkdown
        : context.l10n.artifactKindHtml;

    return Tooltip(
      message: context.l10n.artifactOpenTooltip(artifact.name),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            hermesHaptic(HapticIntent.selection);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtifactViewerScreen(artifact: artifact),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.secondary),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artifact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        kindLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.text,
    required this.isUser,
    required this.color,
    this.selectable = true,
  });

  final String text;
  final bool isUser;
  final Color color;
  final bool selectable;

  /// Cheap heuristic: plain user lines rarely need full markdown.
  bool get _looksLikeMarkdown {
    if (text.contains('```') ||
        text.contains('`') ||
        text.contains('\n- ') ||
        text.contains('\n* ') ||
        text.contains('\n#') ||
        text.contains('**') ||
        (text.contains('[') && text.contains(']('))) {
      return true;
    }
    // Short plain user messages stay plain for snappier layout.
    if (isUser && text.length < 280 && !text.contains('\n\n')) return false;
    return !isUser;
  }

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    if (!_looksLikeMarkdown) {
      final style = Theme.of(
        context,
      ).textTheme.bodyLarge?.copyWith(color: color, height: 1.4);
      if (!selectable) {
        return Text(text, style: style);
      }
      return SelectableText(text, style: style);
    }
    return MessageMarkdown(data: text, color: color);
  }
}
