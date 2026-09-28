import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hermes_mobile/core/models/hermes_models.dart';
import 'package:hermes_mobile/core/providers.dart';
import 'package:hermes_mobile/features/sessions/session_chat_screen.dart';

Future<void> showBotSessionsSheet(
  BuildContext context, {
  required HermesBotProfile bot,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BotSessionsSheet(bot: bot),
  );
}

class _BotSessionsSheet extends ConsumerStatefulWidget {
  const _BotSessionsSheet({required this.bot});

  final HermesBotProfile bot;

  @override
  ConsumerState<_BotSessionsSheet> createState() => _BotSessionsSheetState();
}

class _BotSessionsSheetState extends ConsumerState<_BotSessionsSheet> {
  final _filter = TextEditingController();
  List<HermesSession> _sessions = const [];
  var _loading = true;
  var _busy = false;
  Object? _error;
  late String? _stickySessionId;

  @override
  void initState() {
    super.initState();
    _stickySessionId = widget.bot.chatSessionId;
    _filter.addListener(_redraw);
    unawaited(_load());
  }

  @override
  void dispose() {
    _filter
      ..removeListener(_redraw)
      ..dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final sync = ref.read(sessionSyncProvider);
      if (sync == null) throw StateError('Gateway is not connected');
      final sessions = await sync.listBotSessions(widget.bot);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<HermesSession> get _filtered {
    final query = _filter.text.trim().toLowerCase();
    if (query.isEmpty) return _sessions;
    return _sessions
        .where(
          (session) =>
              '${session.title} ${session.preview ?? ''} ${session.source}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _togglePin(HermesSession session) async {
    await ref.read(pinnedSessionsProvider.notifier).toggle(session.id);
  }

  Future<void> _newSession() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final sync = ref.read(sessionSyncProvider);
      if (sync == null) throw StateError('Gateway is not connected');
      final session = await sync.createBotSession(widget.bot);
      if (!mounted) return;
      setState(() => _stickySessionId = session.id);
      await _openChat(session);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(HermesSession stored) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final sync = ref.read(sessionSyncProvider);
      if (sync == null) throw StateError('Gateway is not connected');
      final session = await sync.openBotSession(widget.bot, stored);
      if (!mounted) return;
      setState(() => _stickySessionId = session.id);
      await _openChat(session);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openChat(HermesSession session) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SessionChatScreen(
          session: session,
          profileName: widget.bot.name,
          isCanonicalBotChat: session.title?.trim() == 'Bot Chat',
        ),
      ),
    );
    if (mounted) {
      unawaited(ref.read(botsProvider.notifier).refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinnedIds = ref.watch(pinnedSessionsProvider).value ?? const [];
    final sessions = orderSessionsWithPins(_filtered, pinnedIds);
    final pinnedSet = pinnedIds.toSet();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.bot.displayName} sessions',
                          style: theme.textTheme.titleLarge,
                        ),
                        Text(
                          '@${widget.bot.handle} · tap a chat to continue it',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _newSession,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _filter,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Filter sessions…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _filter.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          onPressed: _filter.clear,
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading && _sessions.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: sessions.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                SizedBox(
                                  height:
                                      MediaQuery.sizeOf(context).height * 0.5,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(28),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.forum_outlined,
                                            size: 42,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            _error != null
                                                ? 'Could not load bot sessions\n$_error'
                                                : (_filter.text.trim().isEmpty
                                                      ? 'No conversations yet.'
                                                      : 'No sessions match that filter.'),
                                            textAlign: TextAlign.center,
                                          ),
                                          const SizedBox(height: 14),
                                          FilledButton.icon(
                                            onPressed: _error != null
                                                ? _load
                                                : _newSession,
                                            icon: Icon(
                                              _error != null
                                                  ? Icons.refresh
                                                  : Icons.add,
                                            ),
                                            label: Text(
                                              _error != null
                                                  ? 'Retry'
                                                  : 'Start new session',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: sessions.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1, indent: 20),
                              itemBuilder: (context, index) {
                                final session = sessions[index];
                                final sticky = session.id == _stickySessionId;
                                final pinned = pinnedSet.contains(session.id);
                                return ListTile(
                                  enabled: !_busy,
                                  onTap: () => _select(session),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 5,
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          session.title?.trim().isNotEmpty ==
                                                  true
                                              ? session.title!.trim()
                                              : 'Untitled session',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (sticky)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: Text(
                                            'Current',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                      if (pinned)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: Icon(
                                            Icons.push_pin,
                                            size: 16,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                    ],
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        session.preview?.trim().isNotEmpty ==
                                                true
                                            ? session.preview!.trim()
                                            : 'No messages yet',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        [
                                          formatSessionRelative(
                                            session.lastActive,
                                          ),
                                          '${session.messageCount} messages',
                                        ].whereType<String>().join(' · '),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    tooltip: 'Session actions',
                                    onSelected: (action) {
                                      if (action == 'pin') {
                                        unawaited(_togglePin(session));
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'pin',
                                        child: ListTile(
                                          leading: Icon(
                                            pinned
                                                ? Icons.push_pin
                                                : Icons.push_pin_outlined,
                                          ),
                                          title: Text(
                                            pinned ? 'Unpin' : 'Pin to top',
                                          ),
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
