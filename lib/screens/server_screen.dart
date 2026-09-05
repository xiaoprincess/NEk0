import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';

import '../models/app_settings.dart';
import '../models/channel.dart';
import '../models/client.dart';
import '../models/ts_state.dart';
import '../services/foreground_service.dart';
import '../widgets/channel_password_dialog.dart';
import '../widgets/channel_tree.dart';
import '../widgets/client_list.dart';
import '../widgets/chat_panel.dart';
import '../widgets/connection_bar.dart';
import '../screens/file_manager_screen.dart';
import '../widgets/channel_menu.dart';
import '../widgets/spotlight_tour.dart';
import '../widgets/voice_settings_panel.dart';

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  int _lastSeenMessageCount = 0;

  // Targets for the first-use spotlight guide.
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _speakerKey = GlobalKey();
  final GlobalKey _chatKey = GlobalKey();
  final GlobalKey _usersKey = GlobalKey();

  /// Show the control-bar guide the first time the server screen is opened.
  /// Deferred to the first successful connect (see [_onConnected]) so the
  /// user-list step has a real target instead of the connecting spinner.
  Future<void> _maybeAutoShowGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('tour_server_shown') ?? false) return;
    await prefs.setBool('tour_server_shown', true);
    if (!mounted) return;
    await _showGuide();
  }

  /// Runs right after the first successful connect: shows the OEM
  /// battery/auto-start guide first, then the spotlight tour (which now
  /// includes the user-list step, only meaningful once the roster exists).
  Future<void> _onConnected() async {
    await _maybeShowOemGuide();
    if (!mounted) return;
    await _maybeAutoShowGuide();
  }

  Future<void> _showGuide() async {
    final al = AppLocalizations.of(context);
    final connected = ref.read(tsConnectionProvider).connected;
    await showSpotlightTour(context, [
      TourStep(
        targetKey: _micKey,
        padding: 4,
        title: al.guideMicTitle,
        description: al.guideMicDesc,
      ),
      TourStep(
        targetKey: _speakerKey,
        padding: 4,
        title: al.guideSpeakerTitle,
        description: al.guideSpeakerDesc,
      ),
      TourStep(
        targetKey: _chatKey,
        padding: 4,
        title: al.guideChatTitle,
        description: al.guideChatDesc,
      ),
      // The user-list step needs the roster rendered, which only exists
      // while connected.
      if (connected)
        TourStep(
          targetKey: _usersKey,
          padding: 4,
          title: al.guideUsersTitle,
          description: al.guideUsersDesc,
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tsConnectionProvider.select((s) => s.connected), (prev, next) {
      if (prev == true && !next && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      if (prev == false && next && mounted) {
        _onConnected();
      }
    });
    // Pop on connect failure (connecting finished without success)
    ref.listen(tsConnectionProvider.select((s) => s.connecting), (prev, next) {
      if (prev == true && !next && mounted) {
        final st = ref.read(tsConnectionProvider);
        if (!st.connected) {
          Navigator.of(context).pop(st.error);
        }
      }
    });
    final conn = ref.watch(tsConnectionProvider);
    // Wrong password on a channel join: the selection was already rolled
    // back in ts_state — re-open the prompt with an error message and let
    // the user retry (or cancel to stay where they are).
    ref.listen(tsConnectionProvider.select((s) => s.failedPasswordChannelId), (
      prev,
      next,
    ) async {
      if (next == null || !mounted) return;
      final st = ref.read(tsConnectionProvider);
      final name =
          st.channels.where((c) => c.id == next).firstOrNull?.name ?? '';
      final al = AppLocalizations.of(context);
      final pw = await showChannelPasswordDialog(
        context,
        channelName: name,
        errorMessage: al.channelPasswordWrong,
      );
      if (!mounted) return;
      ref.read(tsConnectionProvider.notifier).clearPasswordRejection();
      if (pw == null || pw.isEmpty) return;
      ref.read(tsConnectionProvider.notifier).selectChannel(next, password: pw);
    });
    final connNotifier = ref.read(tsConnectionProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ConnectionBar(
              serverName: conn.serverName,
              connected: conn.connected,
              onDisconnect: () {
                connNotifier.disconnect();
              },
              onShowGuide: _showGuide,
            ),
            Expanded(
              child: conn.connecting
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.blue),
                    )
                  : _buildLeftPanel(conn, connNotifier),
            ),
            _buildChatBar(conn),
            _buildControls(conn, connNotifier),
          ],
        ),
      ),
    );
  }

  /// Joining a locked channel: prompt for the password the first time,
  /// reuse the session-cached one afterwards. A wrong password comes back
  /// as a move_rejected event (handled by the listener in build()).
  Future<void> _onChannelTap(TsChannel channel) async {
    final notifier = ref.read(tsConnectionProvider.notifier);
    final cached = notifier.channelPassword(channel.id);
    if (channel.hasPassword && cached == null) {
      final pw = await showChannelPasswordDialog(
        context,
        channelName: channel.name,
      );
      if (!mounted || pw == null || pw.isEmpty) return; // cancelled
      notifier.selectChannel(channel.id, password: pw);
    } else {
      // Unlocked, or the password is already known for this session.
      notifier.selectChannel(channel.id, password: cached);
    }
  }

  /// Opens the per-channel context menu and dispatches the chosen entry.
  /// The join action reuses [_onChannelTap] so password handling stays in
  /// one place regardless of which gesture summoned the menu.
  Future<void> _onChannelMenu(TsChannel channel) async {
    final result = await showChannelMenu(context, channel);
    if (!mounted || result == null) return;
    switch (result) {
      case channelMenuJoin:
        await _onChannelTap(channel);
      case channelMenuFileManager:
        final notifier = ref.read(tsConnectionProvider.notifier);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FileManagerScreen(
              channelId: channel.id,
              channelName: channel.name,
              channelPassword: notifier.channelPassword(channel.id) ?? '',
              connected: ref.read(tsConnectionProvider).connected,
            ),
          ),
        );
    }
  }

  Widget _buildLeftPanel(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    final gestureSwap = ref.watch(
      appSettingsProvider.select((s) => s.channelGestureSwap),
    );
    // Transparent root so the app-wide custom background shows through
    // behind the channel tree and the user list; the section headers above
    // and below stay opaque as visual anchors.
    return Container(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: Text(
              AppLocalizations.of(context).channels,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            // Material between the colored container and the tiles: ListTile
            // paints background and ink on the nearest Material — with only
            // the ColoredBox ancestor above, Flutter throws "ListTile
            // background color or ink splashes may be invisible" on every
            // rebuild.
            child: Material(
              type: MaterialType.transparency,
              child: ChannelTree(
                channels: conn.channels,
                selectedChannelId: conn.selectedChannelId,
                // Gesture swap from settings: default short tap joins and a
                // long press opens the menu; swapped, the roles are reversed.
                onChannelTap: gestureSwap ? _onChannelMenu : _onChannelTap,
                onChannelMenu: gestureSwap ? _onChannelTap : _onChannelMenu,
                // Open-lock hint for channels whose password is already
                // cached for this session.
                sessionPasswordKnown: (channelId) =>
                    ref
                        .read(tsConnectionProvider.notifier)
                        .channelPassword(channelId) !=
                    null,
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A4A)),
          Container(
            key: _usersKey,
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: Text(
              AppLocalizations.of(context).users,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (conn.selectedChannelId == null)
            Expanded(flex: 2, child: SizedBox.shrink()),
          if (conn.selectedChannelId != null)
            Expanded(
              flex: 2,
              // Same Material reason as the channel tree above: the client
              // ListTiles sit under a colored container.
              child: Material(
                type: MaterialType.transparency,
                child: ClientList(
                  clients: conn.clients,
                  currentChannelId: conn.selectedChannelId!,
                  // Tapping yourself opens the same voice settings as
                  // long-pressing the mic; tapping others opens their
                  // per-client volume + poke sheet.
                  onClientTap: (clientId) {
                    if (clientId == conn.ownClientId) {
                      _showVoiceSettings(conn, notifier);
                    } else {
                      _showClientVolume(clientId);
                    }
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// First-connect-only dialog guiding the user to whitelist the app in
  /// OEM battery/auto-start settings (MIUI/HyperOS/EMUI/ColorOS/OriginOS).
  /// The battery-optimization exemption is requested only AFTER the user
  /// acknowledges the dialog, so they know why the settings page opens.
  Future<void> _maybeShowOemGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('oem_guide_shown') ?? false) return;
    await prefs.setBool('oem_guide_shown', true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          AppLocalizations.of(ctx).keepAliveTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          AppLocalizations.of(ctx).keepAliveBody,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(ctx).gotIt),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      // User acknowledged the dialog — now open the battery optimization page.
      ForegroundService.requestBatteryOptimizationExemption();
    }
  }

  void _showClientVolume(int clientId) {
    final conn = ref.read(tsConnectionProvider);
    final connNotifier = ref.read(tsConnectionProvider.notifier);
    final client = conn.clients.where((c) => c.id == clientId).firstOrNull;
    if (client == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) =>
          _ClientVolumeSheet(client: client, notifier: connNotifier),
    );
  }

  void _openChat() async {
    final conn = ref.read(tsConnectionProvider);
    if (conn.selectedChannelId == null) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ChatPanel(channelId: conn.selectedChannelId!),
      ),
    );
    // Reset badge after sheet closes (re-read for latest count)
    if (mounted) {
      final latest = ref.read(tsConnectionProvider);
      setState(() => _lastSeenMessageCount = latest.messages.length);
    }
  }

  Widget _buildChatBar(TsConnectionState conn) {
    final lastMsg = conn.messages.isNotEmpty ? conn.messages.last : null;
    final unread = conn.messages.length - _lastSeenMessageCount;

    return GestureDetector(
      key: _chatKey,
      onTap: _openChat,
      child: Container(
        height: 36,
        // Translucent so a custom background tints through (same for the
        // other bars on this screen).
        color: const Color(0xD916213E),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline, color: Colors.grey, size: 16),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).chat,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Spacer(),
            if (lastMsg != null)
              Flexible(
                child: Text(
                  '${lastMsg.fromClient}: ${lastMsg.message}',
                  style: const TextStyle(
                    color: Color(0xFF555577),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unread',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up, color: Colors.grey, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(TsConnectionState conn, TsConnectionNotifier notifier) {
    // Mic color: red=muted, green=on-idle, blue=speaking/PTT-active
    Color micColor;
    if (conn.inputMuted) {
      micColor = Colors.red;
    } else if (conn.pttMode) {
      micColor = conn.pttPressed ? Colors.blue : Colors.green;
    } else {
      micColor = conn.voiceActive ? Colors.blue : Colors.green;
    }

    return Container(
      height: 52,
      color: const Color(0xD916213E),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // --- Mic icon (tap mute, long-press settings) ---
          GestureDetector(
            key: _micKey,
            onTap: () => notifier.toggleInputMute(),
            onLongPress: () => _showVoiceSettings(conn, notifier),
            child: Icon(Icons.mic, color: micColor, size: 28),
          ),
          const SizedBox(width: 24),
          // --- Away toggle ---
          Tooltip(
            message: conn.away
                ? AppLocalizations.of(context).awayDisable
                : AppLocalizations.of(context).awayEnable,
            child: GestureDetector(
              onTap: () => notifier.toggleAway(),
              child: Icon(
                Icons.access_time,
                color: conn.away ? Colors.amber : Colors.grey,
                size: 28,
              ),
            ),
          ),
          // --- PTT button (only in PTT mode) ---
          if (conn.pttMode) ...[
            const SizedBox(width: 24),

            IgnorePointer(
              ignoring: conn.inputMuted,
              child: Listener(
                onPointerDown: (_) => notifier.setPttPressed(true),
                onPointerUp: (_) => notifier.setPttPressed(false),
                onPointerCancel: (_) => notifier.setPttPressed(false),
                child: Container(
                  width: 64,
                  height: 40,
                  decoration: BoxDecoration(
                    color: conn.pttPressed
                        ? const Color(0xFF4444AA)
                        : const Color(0xFF2A2A4A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF888888),
                      // color: conn.pttPressed
                      //     ? Colors.lightGreenAccent
                      //     : const Color(0xFF888888),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'PTT',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 24),
          // --- Speaker icon (toggle output mute) ---
          GestureDetector(
            key: _speakerKey,
            onTap: () => notifier.toggleOutputMute(),
            child: Icon(
              Icons.volume_up,
              color: conn.outputMuted ? Colors.red : Colors.green,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  void _showVoiceSettings(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceSettingsPanel(conn: conn, notifier: notifier),
        );
      },
    );
  }
}

// ─── Per-client volume sheet ────────────────────────────────────────

class _ClientVolumeSheet extends StatefulWidget {
  final TsClient client;
  final TsConnectionNotifier notifier;

  const _ClientVolumeSheet({required this.client, required this.notifier});

  @override
  State<_ClientVolumeSheet> createState() => _ClientVolumeSheetState();
}

class _ClientVolumeSheetState extends State<_ClientVolumeSheet> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.client.volume;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                c.isTalking ? Icons.mic : Icons.person,
                color: c.isTalking ? Colors.blue : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                c.nickname,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (c.isTalking)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    AppLocalizations.of(context).talking,
                    style: const TextStyle(color: Colors.blue, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                AppLocalizations.of(context).volume,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: -20.0,
                  max: 20.0,
                  divisions: 80,
                  activeColor: Colors.blue,
                  onChanged: (v) {
                    setState(() => _volume = v);
                    widget.notifier.setClientVolume(c.id, v);
                  },
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${_volume.toStringAsFixed(1)} dB',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showPokeDialog(context),
                  icon: const Icon(Icons.notification_important, size: 18),
                  label: Text(AppLocalizations.of(context).poke),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blueAccent,
                    side: const BorderSide(color: Color(0xFF2A2A4A)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Ask for a poke message and send it to this client.
  Future<void> _showPokeDialog(BuildContext context) async {
    final al = AppLocalizations.of(context);
    final controller = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          al.poke,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: al.pokeHint,
            hintStyle: const TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(
              al.send,
              style: const TextStyle(color: Colors.blueAccent),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    final text = msg?.trim() ?? '';
    // An empty poke is allowed (TeamSpeak pokes without a message). Only
    // skip when the widget is gone.
    if (!mounted) return;
    widget.notifier.sendPoke(widget.client.id, text);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(al.pokeSent),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
