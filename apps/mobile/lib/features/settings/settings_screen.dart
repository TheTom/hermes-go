import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hermes_mobile/core/demo/demo_mode.dart';
import 'package:hermes_mobile/core/health/apple_health_sync.dart';
import 'package:hermes_mobile/core/network/gateway_auth.dart';
import 'package:hermes_mobile/core/providers.dart';
import 'package:hermes_mobile/core/services/feedback.dart';
import 'package:hermes_mobile/core/services/result_notifier.dart';
import 'package:hermes_mobile/core/sync/background_sync.dart';
import 'package:hermes_mobile/core/theme/hermes_skins.dart';
import 'package:hermes_mobile/features/settings/command_cheat_sheet_screen.dart';
import 'package:hermes_mobile/features/settings/privacy_dialog.dart';
import 'package:hermes_mobile/l10n/l10n.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  var _checking = false;

  @override
  void initState() {
    super.initState();
    // Probe REST + nudge WS as soon as Settings opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkConnection(silent: true));
    });
  }

  Future<void> _checkConnection({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      // Silent = boot/auto probe: coalesce with the cold provider build via
      // TTL. Explicit "Check connection" tap: bypass so the user always gets
      // a fresh probe.
      await ref
          .read(gatewayRestHealthProvider.notifier)
          .refresh(bypassTtl: !silent);
      final rt = ref.read(gatewayRealtimeProvider);
      if (rt != null) {
        // Opening Settings must NOT force-remint a healthy socket (that was
        // thrashing UI to "reconnecting" while chat still worked).
        if (silent) {
          if (!rt.isLive) {
            await rt.ensureLive(force: false);
          }
        } else {
          // Explicit "Check" / health button: soft first, force only if dead.
          final ok = await rt.ensureLive(force: false);
          if (!ok) await rt.ensureLive(force: true);
        }
      }
      if (!silent && mounted) {
        final link = ref.read(gatewayLinkStatusProvider);
        final rest = ref.read(gatewayRestHealthProvider).value;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              link.wsLive
                  ? context.l10n.liveChatReady
                  : (link.wsError ??
                        rest?.error ??
                        context.l10n.notLiveSeeStatus),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(connectionProfileProvider).value;
    final theme = Theme.of(context);
    final link = ref.watch(gatewayLinkStatusProvider);
    final restAsync = ref.watch(gatewayRestHealthProvider);
    final rest = restAsync.value;
    final level = link.level(restOk: rest?.ok);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.settingsTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.checkConnection,
            onPressed: _checking ? null : () => _checkConnection(),
            icon: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.health_and_safety_outlined),
          ),
        ],
      ),
      body: ListView(
        children: [
          _ConnectionStatusCard(
            link: link,
            rest: rest,
            restLoading: restAsync.isLoading,
            level: level,
            checking: _checking,
            onCheck: () => _checkConnection(),
            onReconnect: () async {
              hermesHaptic(HapticIntent.selection);
              final rt = ref.read(gatewayRealtimeProvider);
              final ok = await rt?.ensureLive(force: true) ?? false;
              await ref
                  .read(gatewayRestHealthProvider.notifier)
                  .refresh(bypassTtl: true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? context.l10n.wsConnectedChatReady
                          : (rt?.lastError ?? context.l10n.stillOffline),
                    ),
                  ),
                );
              }
            },
            onSignIn: profile?.usesSessionCookies == true
                ? () => _showReloginSheet(context, ref)
                : null,
          ),
          // Account / device actions (status card already shows host, user, version, live state).
          if (profile != null) ...[
            if (profile.hasLegacyToken)
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(context.l10n.apiToken),
                subtitle: Text(_mask(profile.apiKey)),
              ),
            // Sign-in is on the status card when reauth is required; keep a quiet
            // entry here only for optional password refresh while still live.
            if (profile.usesSessionCookies &&
                level != ConnectionHealthLevel.reauth)
              ListTile(
                leading: const Icon(Icons.login),
                title: Text(context.l10n.refreshSignIn),
                subtitle: Text(context.l10n.refreshSignInSubtitle),
                onTap: () => _showReloginSheet(context, ref),
              ),
            if (isDemoProfileId(profile.id))
              ListTile(
                leading: Icon(
                  Icons.exit_to_app,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  context.l10n.exitSampleWorkspace,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                subtitle: Text(context.l10n.exitSampleWorkspaceSubtitle),
                onTap: () => _exitSampleWorkspace(context),
              )
            else
              ListTile(
                leading: Icon(Icons.link_off, color: theme.colorScheme.error),
                title: Text(
                  context.l10n.disconnect,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                subtitle: Text(context.l10n.disconnectSubtitle),
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(context.l10n.disconnectConfirmTitle),
                      content: Text(context.l10n.disconnectConfirmBody),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(context.l10n.cancel),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(context.l10n.disconnect),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await ref.read(connectionActionsProvider).disconnect();
                  }
                },
              ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(context.l10n.theme),
            subtitle: Text(
              '${ref.watch(appSkinProvider).label} · '
              '${_modeLabel(context, ref.watch(appThemeModeProvider).value ?? ThemeMode.system)}',
            ),
            onTap: () => _showThemePicker(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(context.l10n.language),
            subtitle: Text(
              ref.watch(appLocaleProvider).value == null
                  ? context.l10n.languageSystem
                  : localeDisplayName(ref.watch(appLocaleProvider).value!),
            ),
            onTap: () => _showLanguagePicker(context, ref),
          ),
          Builder(
            builder: (context) {
              final muted = ref.watch(hapticsMutedProvider).value ?? false;
              return SwitchListTile(
                secondary: Icon(
                  muted ? Icons.volume_off_outlined : Icons.vibration,
                ),
                title: Text(context.l10n.hapticsSounds),
                subtitle: Text(
                  muted ? context.l10n.hapticsOff : context.l10n.hapticsOn,
                ),
                value: !muted,
                onChanged: (on) {
                  hermesHaptic(HapticIntent.selection);
                  ref.read(hapticsMutedProvider.notifier).setMuted(!on);
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(context.l10n.previewHaptics),
            onTap: () => FeedbackService.instance.preview(),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Text(context.l10n.notificationsTitle),
            subtitle: Text(
              ResultNotifier.instance.permissionGranted == false
                  ? 'Permission off — tap to enable & send a test'
                  : 'Tap to send a test alert (chat/job finishes)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              // OS notification permission only — independent of WebSocket live.
              hermesHaptic(HapticIntent.selection);
              final msg = await ResultNotifier.instance.showTest();
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(msg)));
              setState(() {});
            },
          ),
          if (Platform.isIOS && profile != null)
            ListTile(
              leading: const Icon(Icons.favorite_outline),
              title: const Text('Apple Health'),
              subtitle: const Text(
                'Works with the Apple Health app · optional and read-only',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showAppleHealthSettings(profile.id),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(context.l10n.syncNow),
            subtitle: Text(context.l10n.syncNowSubtitle),
            onTap: () async {
              final summary = await BackgroundSync.run(reason: 'settings');
              await ref
                  .read(sessionsProvider.notifier)
                  .refresh(bypassTtl: true);
              await ref.read(jobsProvider.notifier).refresh(bypassTtl: true);
              await ref.read(modelsProvider.notifier).refresh();
              await ref.read(skillsProvider.notifier).refresh(bypassTtl: true);
              await ref
                  .read(gatewayRestHealthProvider.notifier)
                  .refresh(bypassTtl: true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.l10n.syncedWithSummary(summary)),
                  ),
                );
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: Text(context.l10n.commandCheatSheetTitle),
            subtitle: Text(context.l10n.commandCheatSheetSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CommandCheatSheetScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(context.l10n.privacyAndData),
            subtitle: Text(context.l10n.privacyAndDataSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showPrivacyDialog(context),
          ),
          ListTile(
            title: Text(context.l10n.about),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.aboutBody),
                const SizedBox(height: 8),
                // Discloses the sample workspace to every user (not just App
                // Review) — see APP_REVIEW_NOTES.md. This line + the review
                // notes are the only two places the demo host is mentioned;
                // the connect screen never advertises it.
                Text(
                  context.l10n.sampleWorkspaceAboutLine,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Semantics(
                  container: true,
                  label: context.l10n.unofficialDisclaimer,
                  child: Text(
                    context.l10n.unofficialDisclaimer,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
            isThreeLine: true,
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }

  String _mask(String key) {
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}…${key.substring(key.length - 4)}';
  }

  Future<void> _showAppleHealthSettings(String gatewayId) async {
    final dashboard = ref.read(dashboardClientProvider);
    if (dashboard == null) return;
    final health = AppleHealthSync(gatewayId: gatewayId, dashboard: dashboard);
    var enabled = await health.isEnabled;
    var needsAuthorizationReview = await health.needsAuthorizationReview;
    var busy = false;
    String? message;
    Map<String, dynamic>? serverStatus;
    var lastReadCounts = await health.lastReadCounts;
    try {
      serverStatus = await dashboard.appleHealthStatus();
    } catch (e) {
      message = '$e';
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setLocal) {
          Future<void> run(Future<void> Function() action) async {
            setLocal(() {
              busy = true;
              message = null;
            });
            try {
              await action();
              lastReadCounts = await health.lastReadCounts;
              needsAuthorizationReview = await health.needsAuthorizationReview;
              serverStatus = await dashboard.appleHealthStatus();
            } catch (e) {
              message = '$e';
            } finally {
              if (sheetContext.mounted) setLocal(() => busy = false);
            }
          }

          final count = (serverStatus?['sample_count'] as num?)?.toInt() ?? 0;
          final last = serverStatus?['last_sync_at'];
          final serverTypes =
              (serverStatus?['types'] as List?)
                  ?.map((type) => '$type')
                  .toSet() ??
              const <String>{};
          final missingCategories = <String>[
            if (!serverTypes.any((type) => type.startsWith('SLEEP_'))) 'Sleep',
            if (!serverTypes.any(
              (type) => const {
                'HEART_RATE',
                'RESTING_HEART_RATE',
                'WALKING_HEART_RATE',
                'HEART_RATE_VARIABILITY_SDNN',
                'ELECTROCARDIOGRAM',
              }.contains(type),
            ))
              'Heart',
            if (!serverTypes.any(
              (type) => const {
                'WEIGHT',
                'HEIGHT',
                'BODY_MASS_INDEX',
                'BODY_FAT_PERCENTAGE',
                'LEAN_BODY_MASS',
                'WAIST_CIRCUMFERENCE',
              }.contains(type),
            ))
              'Body Measurements',
            if (!serverTypes.any(
              (type) => const {
                'BLOOD_OXYGEN',
                'BLOOD_GLUCOSE',
                'BLOOD_PRESSURE_SYSTOLIC',
                'BLOOD_PRESSURE_DIASTOLIC',
                'BODY_TEMPERATURE',
                'RESPIRATORY_RATE',
              }.contains(type),
            ))
              'Vitals',
          ];
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Apple Health',
                      style: Theme.of(sheetContext).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Hermes Go works with the Apple Health app. It reads health data only after your permission and sends authorized samples to this authenticated, self-hosted Hermes gateway. Health-capable bots can query bounded summaries; health data is never added to every chat prompt. Hermes Go never writes to the Apple Health app.',
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: enabled,
                      onChanged: busy || serverStatus == null
                          ? null
                          : (value) => run(() async {
                              if (value) {
                                final granted = await health
                                    .requestReadAuthorization();
                                if (!granted) {
                                  throw StateError(
                                    'Apple Health could not show its access request',
                                  );
                                }
                                await health.sync(initial: true);
                              } else {
                                await health.setEnabled(false);
                              }
                              enabled = value;
                            }),
                      title: Text(enabled ? 'Sync enabled' : 'Sync off'),
                      subtitle: Text(
                        serverStatus == null
                            ? 'Apple Health plugin not installed on this gateway'
                            : '$count samples on gateway${last == null ? '' : ' · last sync $last'}',
                      ),
                    ),
                    if (enabled && needsAuthorizationReview)
                      Card(
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.tertiaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'Hermes Go now supports additional Body Measurements, Heart, Sleep, Vitals, Mobility, Nutrition, and Activity data. Tap Review Health access below, then choose Turn On All—or select the individual data you want to share.',
                            style: TextStyle(
                              color: Theme.of(
                                sheetContext,
                              ).colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ),
                    if (enabled && missingCategories.isNotEmpty)
                      Card(
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'No ${missingCategories.join(', ')} samples have reached Hermes${lastReadCounts.isEmpty ? '.' : ' in the last phone read.'} Existing access must be changed in Health → Sharing → Apps → Hermes Go. The Apple Health app may also have no samples of that type.',
                            style: TextStyle(
                              color: Theme.of(
                                sheetContext,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    if (message != null)
                      Text(
                        message!,
                        style: TextStyle(
                          color: Theme.of(sheetContext).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: !enabled || busy
                          ? null
                          : () => run(() async {
                              // If whole coaching categories have never reached
                              // the gateway, reread the useful history window.
                              // An incremental cursor can otherwise miss an
                              // older weight measurement immediately after the
                              // user fixes Health access outside the app.
                              final result = await health.sync(
                                initial: missingCategories.isNotEmpty,
                              );
                              message = result.sleepRead == 0
                                  ? 'Synced ${result.accepted} samples, but the Apple Health app returned no sleep data. In Health, open Sharing → Apps → Hermes Go and change Sleep to Full Access.'
                                  : 'Synced ${result.accepted} new or updated samples, including ${result.sleepRead} sleep samples';
                            }),
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                    TextButton.icon(
                      onPressed: busy || serverStatus == null
                          ? null
                          : () async {
                              await run(() async {
                                final accepted = await health
                                    .requestReadAuthorization();
                                message = accepted
                                    ? 'Apple Health processed the access request.'
                                    : 'Apple Health could not process the access request.';
                              });
                              if (!sheetContext.mounted) return;
                              await showDialog<void>(
                                context: sheetContext,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Change Health access'),
                                  content: const Text(
                                    'If no Apple permission sheet appeared, iOS has already recorded a choice for every requested data type and will not show those existing choices again here.\n\nOpen the Health app, then go to Sharing → Apps → Hermes Go. Change any item showing None—including Sleep, Weight, Heart, and Vitals—to Full Access. Return here and tap Sync now to backfill the last 30 days.',
                                  ),
                                  actions: [
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext),
                                      child: const Text('Got it'),
                                    ),
                                  ],
                                ),
                              );
                            },
                      icon: const Icon(Icons.privacy_tip_outlined),
                      label: const Text('Review / change Health access'),
                    ),
                    TextButton.icon(
                      onPressed: busy || serverStatus == null || count == 0
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: sheetContext,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text(
                                    'Delete synced health data?',
                                  ),
                                  content: const Text(
                                    'This permanently deletes Apple Health samples stored by the plugin on this Hermes gateway. It does not change Apple Health on your iPhone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                              await run(() async {
                                final deleted = await dashboard
                                    .clearAppleHealth();
                                await health.forgetLocalState();
                                enabled = false;
                                message = 'Deleted $deleted samples';
                              });
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete gateway health data'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Tears down the sample workspace and returns to the connect screen
  /// clean: stops the in-process server, wipes its cached sessions/jobs/
  /// skills, and removes the saved profile via the same path a normal
  /// gateway removal uses (which also clears its cookie jar).
  Future<void> _exitSampleWorkspace(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.exitSampleWorkspaceConfirmTitle),
        content: Text(context.l10n.exitSampleWorkspaceConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.exitSampleWorkspace),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(gatewayRealtimeProvider)?.stop();
    } catch (e) {
      debugPrint('exitSampleWorkspace: realtime stop failed: $e');
    }
    await DemoGatewayHolder.instance.shutdown();
    try {
      await ref.read(appDatabaseProvider).clearGatewayData(demoProfileId);
    } catch (e) {
      debugPrint('exitSampleWorkspace: clear local data failed: $e');
    }
    // Same removal path as any other saved gateway — also clears the
    // gateway's persistent cookie jar.
    await ref.read(gatewayBookProvider.notifier).remove(demoProfileId);
  }
}

/// Big, obvious connection health at the top of Settings.
class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({
    required this.link,
    required this.rest,
    required this.restLoading,
    required this.level,
    required this.checking,
    required this.onCheck,
    required this.onReconnect,
    this.onSignIn,
  });

  final GatewayLinkStatus link;
  final GatewayRestHealth? rest;
  final bool restLoading;
  final ConnectionHealthLevel level;
  final bool checking;
  final VoidCallback onCheck;
  final Future<void> Function() onReconnect;
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (
      Color bg,
      Color fg,
      IconData icon,
      String title,
      String body,
    ) = switch (level) {
      ConnectionHealthLevel.live => (
        theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
        theme.colorScheme.onPrimaryContainer,
        Icons.check_circle,
        context.l10n.connectedChatReady,
        context.l10n.connectedChatReadyBody,
      ),
      ConnectionHealthLevel.degraded => (
        theme.colorScheme.tertiaryContainer.withValues(alpha: 0.65),
        theme.colorScheme.onTertiaryContainer,
        Icons.warning_amber_rounded,
        // Prefer offline wording unless we are *actually* mid-retry.
        link.gaveUp
            ? context.l10n.signedInChatOffline
            : (link.wsLive
                  ? context.l10n.connectedChatReady
                  : ((link.wsPhase == 'reconnecting' ||
                            link.wsPhase == 'connecting')
                        ? context.l10n.signedInReconnecting
                        : context.l10n.signedInChatOffline)),
        link.gaveUp
            ? context.l10n.autoReconnectGaveUp
            : (link.wsLive
                  ? context.l10n.connectedChatReadyBody
                  : context.l10n.signedInChatOfflineBody),
      ),
      ConnectionHealthLevel.reauth => (
        theme.colorScheme.errorContainer.withValues(alpha: 0.7),
        theme.colorScheme.onErrorContainer,
        Icons.lock_outline,
        context.l10n.sessionExpired,
        link.reauthMessage ?? link.wsError ?? context.l10n.sessionExpiredBody,
      ),
      ConnectionHealthLevel.error => (
        theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        theme.colorScheme.onErrorContainer,
        Icons.error_outline,
        link.gaveUp
            ? context.l10n.gaveUpReconnecting
            : context.l10n.connectionProblem,
        link.wsError ?? rest?.error ?? context.l10n.cannotReachGateway,
      ),
      ConnectionHealthLevel.offline => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
        Icons.cloud_off_outlined,
        context.l10n.notConnected,
        context.l10n.noGatewaySaved,
      ),
    };

    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: fg, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fg.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StatusLine(
              label: context.l10n.webSocket,
              value: link.wsLive
                  ? context.l10n.live
                  : (link.wsLabel ??
                        _wsStateLabel(
                          context,
                          link.connectionState,
                          link.wsError,
                          gaveUp: link.gaveUp,
                        )),
              ok: link.wsLive,
              fg: fg,
            ),
            _StatusLine(
              label: context.l10n.httpsRest,
              value: restLoading
                  ? context.l10n.checking
                  : (rest?.ok == true
                        ? '${context.l10n.ok}${rest?.version != null ? ' · ${rest!.version}' : ''}'
                        : (rest?.error != null
                              ? context.l10n.fail
                              : context.l10n.unknown)),
              ok: rest?.ok == true,
              fg: fg,
            ),
            if (link.baseUrl != null)
              _StatusLine(
                label: context.l10n.host,
                value: link.baseUrl!,
                ok: null,
                fg: fg,
              ),
            if (link.username != null && link.username!.isNotEmpty)
              _StatusLine(
                label: context.l10n.user,
                value: link.username!,
                ok: null,
                fg: fg,
              ),
            if (link.wsError != null && link.wsError!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                link.wsError!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fg.withValues(alpha: 0.85),
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (level == ConnectionHealthLevel.reauth && onSignIn != null)
                  FilledButton.icon(
                    onPressed: onSignIn,
                    icon: const Icon(Icons.login, size: 18),
                    label: Text(context.l10n.signIn),
                  )
                else if (level != ConnectionHealthLevel.live &&
                    level != ConnectionHealthLevel.offline)
                  FilledButton.icon(
                    onPressed: checking ? null : () => onReconnect(),
                    icon: const Icon(Icons.bolt, size: 18),
                    label: Text(
                      link.gaveUp
                          ? context.l10n.reconnectNow
                          : context.l10n.reconnect,
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: checking ? null : onCheck,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(context.l10n.checkNow),
                ),
                if (onSignIn != null &&
                    level != ConnectionHealthLevel.reauth &&
                    level != ConnectionHealthLevel.offline)
                  TextButton(
                    onPressed: onSignIn,
                    child: Text(context.l10n.refreshSignIn),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _wsStateLabel(
  BuildContext context,
  String? connectionState,
  String? wsError, {
  bool gaveUp = false,
}) {
  final l10n = context.l10n;
  if (gaveUp) return l10n.gaveUpTapReconnect;
  final s = (connectionState ?? '').toLowerCase();
  if (s == 'connecting') return l10n.connecting;
  if (s == 'error') return l10n.error;
  if (s == 'closed') return l10n.closed;
  if (s == 'idle') return l10n.idle;
  if (wsError != null && wsError.isNotEmpty) return l10n.offline;
  return connectionState ?? l10n.offline;
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.label,
    required this.value,
    required this.fg,
    this.ok,
  });

  final String label;
  final String value;
  final Color fg;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: fg.withValues(alpha: 0.75),
              ),
            ),
          ),
          if (ok != null) ...[
            Icon(
              ok! ? Icons.circle : Icons.circle_outlined,
              size: 8,
              color: ok!
                  ? Colors.greenAccent.shade400
                  : fg.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _modeLabel(BuildContext context, ThemeMode mode) {
  final l10n = context.l10n;
  return switch (mode) {
    ThemeMode.light => l10n.themeLight,
    ThemeMode.dark => l10n.themeDark,
    ThemeMode.system => l10n.themeSystem,
  };
}

Future<void> _showLanguagePicker(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final current = ref.read(appLocaleProvider).value;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                l10n.language,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.languageSubtitle,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: Icon(current == null ? Icons.check : Icons.phone_iphone),
              title: Text(l10n.languageSystem),
              selected: current == null,
              onTap: () {
                hermesHaptic(HapticIntent.selection);
                ref.read(appLocaleProvider.notifier).selectSystem();
                Navigator.pop(ctx);
              },
            ),
            for (final locale in supportedAppLocales)
              ListTile(
                leading: Icon(
                  current?.languageCode == locale.languageCode
                      ? Icons.check
                      : Icons.translate,
                ),
                title: Text(localeDisplayName(locale)),
                subtitle: Text(locale.languageCode),
                selected: current?.languageCode == locale.languageCode,
                onTap: () {
                  hermesHaptic(HapticIntent.selection);
                  ref
                      .read(appLocaleProvider.notifier)
                      .selectLanguageCode(locale.languageCode);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> _showThemePicker(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Consumer(
          builder: (ctx, ref, _) {
            final currentSkin =
                ref.watch(appSkinIdProvider).value ?? kDefaultSkinId;
            final currentMode =
                ref.watch(appThemeModeProvider).value ?? ThemeMode.system;
            final height = MediaQuery.sizeOf(ctx).height * 0.72;
            return SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: Text(
                        ctx.l10n.appearance,
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'PLACEHOLDER',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            ctx,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SegmentedButton<ThemeMode>(
                        segments: [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text(ctx.l10n.themeSystem),
                            icon: Icon(Icons.brightness_auto, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text(ctx.l10n.themeLight),
                            icon: Icon(Icons.light_mode_outlined, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text(ctx.l10n.themeDark),
                            icon: Icon(Icons.dark_mode_outlined, size: 16),
                          ),
                        ],
                        selected: {currentMode},
                        onSelectionChanged: (s) {
                          ref
                              .read(appThemeModeProvider.notifier)
                              .select(s.first);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: [
                          _SkinSectionLabel(ctx.l10n.skinSectionDesktop),
                          for (final skin in kBuiltinSkins.take(
                            kDesktopParitySkinCount,
                          ))
                            _SkinPickerTile(
                              skin: skin,
                              selected: skin.id == currentSkin,
                              brightness: Theme.of(ctx).brightness,
                              onTap: () {
                                ref
                                    .read(appSkinIdProvider.notifier)
                                    .select(skin.id);
                              },
                            ),
                          _SkinSectionLabel(ctx.l10n.skinSectionMobile),
                          for (final skin in kBuiltinSkins.skip(
                            kDesktopParitySkinCount,
                          ))
                            _SkinPickerTile(
                              skin: skin,
                              selected: skin.id == currentSkin,
                              brightness: Theme.of(ctx).brightness,
                              onTap: () {
                                ref
                                    .read(appSkinIdProvider.notifier)
                                    .select(skin.id);
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}

class _SkinSectionLabel extends StatelessWidget {
  const _SkinSectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SkinPickerTile extends StatelessWidget {
  const _SkinPickerTile({
    required this.skin,
    required this.selected,
    required this.brightness,
    required this.onTap,
  });

  final HermesSkin skin;
  final bool selected;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      leading: SkinSwatchRow(skin: skin, brightness: brightness),
      title: Text(skin.label),
      subtitle: Text(
        skin.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}

Future<void> _showReloginSheet(BuildContext context, WidgetRef ref) async {
  final profile = ref.read(connectionProfileProvider).value;
  if (profile == null) return;
  final user = profile.username ?? '';
  final provider = profile.provider ?? 'basic';
  final passCtrl = TextEditingController();
  final formKey = GlobalKey<FormState>();
  var busy = false;
  String? error;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Refresh sign-in',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Re-enter the password for $user on ${profile.baseUrl}. '
                    'We never auto-reconnect after expiry (kicks stay kicked).',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (!formKey.currentState!.validate()) return;
                            setLocal(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final jar = await GatewayAuthClient.persistentJar(
                                profile.id,
                              );
                              await jar.deleteAll();
                              final auth = GatewayAuthClient(
                                baseUrl: profile.baseUrl,
                                cookieJar: jar,
                              );
                              await auth.passwordLogin(
                                provider: provider,
                                username: user,
                                password: passCtrl.text,
                              );
                              await auth.mintWsTicket();
                              ref.read(connectionActionsProvider).clearReauth();
                              final rt = ref.read(gatewayRealtimeProvider);
                              final ok =
                                  await rt?.ensureLive(force: true) ?? false;
                              await ref
                                  .read(gatewayRestHealthProvider.notifier)
                                  .refresh();
                              if (ctx.mounted) {
                                Navigator.pop(ctx);
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? 'Signed in — WebSocket live'
                                          : 'Signed in; WebSocket: ${rt?.lastError ?? "still offline"}',
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              setLocal(() {
                                busy = false;
                                error = '$e';
                              });
                            }
                          },
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(context.l10n.signInAndReconnect),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  passCtrl.dispose();
}
