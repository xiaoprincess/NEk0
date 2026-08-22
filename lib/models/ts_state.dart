import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_locale.dart';
import '../models/channel.dart';
import '../models/client.dart';
import '../models/chat_message.dart';
import '../models/server.dart';
import '../services/ts_ffi.dart';
import '../services/audio_service.dart';
import '../services/foreground_service.dart';

// ─── Immutable State ────────────────────────────────────────────────

class TsConnectionState {
  final bool connected;
  final bool connecting;
  final String serverName;
  final String nickname;
  final int ownClientId;
  final List<TsChannel> channels;
  final List<TsClient> clients;
  final List<ChatMessage> messages;
  final int? selectedChannelId;
  final String? error;
  final List<String> diagMessages;
  final bool voiceActive;
  final bool inputMuted;
  final bool outputMuted;
  final bool away;
  final bool pttMode;
  final bool pttPressed;
  final bool vadEnabled;
  final double vadThreshold;
  final double micGain;
  final double micRms;

  const TsConnectionState({
    this.connected = false,
    this.connecting = false,
    this.serverName = '',
    this.nickname = '',
    this.ownClientId = 0,
    this.channels = const [],
    this.clients = const [],
    this.messages = const [],
    this.selectedChannelId,
    this.error,
    this.diagMessages = const [],
    this.voiceActive = false,
    this.inputMuted = false,
    this.outputMuted = false,
    this.away = false,
    this.pttMode = false,
    this.pttPressed = false,
    this.vadEnabled = true,
    this.vadThreshold = 0.005,
    this.micGain = 1.0,
    this.micRms = 0.0,
  });

  TsConnectionState copyWith({
    bool? connected,
    bool? connecting,
    String? serverName,
    String? nickname,
    int? ownClientId,
    List<TsChannel>? channels,
    List<TsClient>? clients,
    List<ChatMessage>? messages,
    Object? selectedChannelId = _sentinel,
    String? error,
    List<String>? diagMessages,
    bool? voiceActive,
    bool? inputMuted,
    bool? outputMuted,
    bool? away,
    bool? pttMode,
    bool? pttPressed,
    bool? vadEnabled,
    double? vadThreshold,
    double? micGain,
    double? micRms,
  }) => TsConnectionState(
    connected: connected ?? this.connected,
    connecting: connecting ?? this.connecting,
    serverName: serverName ?? this.serverName,
    nickname: nickname ?? this.nickname,
    ownClientId: ownClientId ?? this.ownClientId,
    channels: channels ?? this.channels,
    clients: clients ?? this.clients,
    messages: messages ?? this.messages,
    selectedChannelId: selectedChannelId == _sentinel
        ? this.selectedChannelId
        : selectedChannelId as int?,
    error: error,
    diagMessages: diagMessages ?? this.diagMessages,
    voiceActive: voiceActive ?? this.voiceActive,
    inputMuted: inputMuted ?? this.inputMuted,
    outputMuted: outputMuted ?? this.outputMuted,
    away: away ?? this.away,
    pttMode: pttMode ?? this.pttMode,
    pttPressed: pttPressed ?? this.pttPressed,
    vadEnabled: vadEnabled ?? this.vadEnabled,
    vadThreshold: vadThreshold ?? this.vadThreshold,
    micGain: micGain ?? this.micGain,
    micRms: micRms ?? this.micRms,
  );
}

const _sentinel = Object();

// ─── Saved Servers State ────────────────────────────────────────────

class ServerListState {
  final List<Server> servers;
  final bool loading;

  const ServerListState({this.servers = const [], this.loading = true});

  ServerListState copyWith({List<Server>? servers, bool? loading}) =>
      ServerListState(
        servers: servers ?? this.servers,
        loading: loading ?? this.loading,
      );
}

// ─── Connection Notifier (calls real Rust FFI) ──────────────────────

class TsConnectionNotifier extends Notifier<TsConnectionState> {
  Timer? _pollTimer;
  AudioService? _audioService;
  bool _micEnabled = false;
  bool _micGranted =
      false; // true only after enableMic() successfully completes
  SharedPreferences? _prefs; // cached for synchronous saves

  @override
  TsConnectionState build() {
    ForegroundService.init();
    ForegroundService.onToggleMute = (bool inputMuted) {
      if (state.inputMuted != inputMuted) {
        toggleInputMute();
      }
    };
    ForegroundService.onSetFullMute = setFullMute;
    ForegroundService.onNotificationDisconnect = () {
      disconnect();
    };

    ref.onDispose(() {
      _pollTimer?.cancel();
      ForegroundService.onToggleMute = null;
      ForegroundService.onSetFullMute = null;
      ForegroundService.onNotificationDisconnect = null;
    });
    return const TsConnectionState();
  }

  Future<void> _saveIdentity() async {
    final id = TsNative.getIdentity();
    if (id != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('client_identity', id);
      debugPrint('TS: identity saved to storage');
    }
  }

  Future<void> connect({
    required String address,
    required String nickname,
    String? channel,
    String? password,
  }) async {
    debugPrint('TS: connect($address, $nickname, ch=$channel)');
    state = state.copyWith(connecting: true, error: null);

    // Push persisted identity to Rust before connecting
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs; // cache for synchronous saves
    _migrateLegacyVolumeKeys();
    final id = prefs.getString('client_identity');
    if (id != null) {
      debugPrint('TS: pushing identity to Rust');
      TsNative.setIdentity(id);
    }
    final savedMicGain = prefs.getDouble('mic_gain');
    if (savedMicGain != null) {
      TsNative.setMicGain(savedMicGain);
      state = state.copyWith(micGain: savedMicGain);
    }

    // Call Rust FFI - starts async connection in background
    final resultJson = TsNative.connect(
      address,
      nickname,
      channel: channel,
      password: password,
    );
    debugPrint('TS: connect result = $resultJson');
    final result = jsonDecode(resultJson) as Map<String, dynamic>;

    if (result['type'] == 'error') {
      state = state.copyWith(
        connecting: false,
        error: result['message'] as String,
      );
      return;
    }

    // Start polling for events from Rust
    _startPolling();
  }

  void _startPolling() {
    debugPrint('TS: polling started');
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pollEvents();
    });
  }

  void _pollEvents() {
    try {
      final eventsJson = TsNative.pollEvents();
      final events = jsonDecode(eventsJson) as List;
      if (events.isNotEmpty) debugPrint('TS: poll got ${events.length} events');

      for (final raw in events) {
        final event = raw as Map<String, dynamic>;
        _handleEvent(event);
      }
      // Poll voice activity for UI indicator
      final va = TsNative.isVoiceActive();
      if (va != state.voiceActive) {
        state = state.copyWith(voiceActive: va);
        _refreshNotification();
      }
      // Refresh client talking indicators from live Rust data
      try {
        final clientsJson = TsNative.getClients();
        final clients = (jsonDecode(clientsJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();
        if (clients.isNotEmpty) {
          state = state.copyWith(clients: clients);
        }
      } catch (_) {} // ignore parse errors during refresh
      // Apply saved per-client volumes (UID-keyed) to any client whose volume
      // differs from the saved value. Runs on every refresh, so it also covers
      // late joiners and the brief window where a UID is not yet known.
      _applySavedClientVolumes();
    } catch (e) {
      debugPrint('FFI poll error: $e');
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String;
    debugPrint('TS: event $type');
    switch (type) {
      case 'connected':
        // Connection succeeded - refresh channels/clients from Rust
        final channelsJson = TsNative.getChannels();
        final clientsJson = TsNative.getClients();

        final channels = (jsonDecode(channelsJson) as List)
            .map((j) => TsChannel.fromJson(j as Map<String, dynamic>))
            .toList();
        final clients = (jsonDecode(clientsJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();

        final ownId = event['client_id'] as int? ?? state.ownClientId;
        // Find the channel the user is actually in
        final ownClient = clients.where((c) => c.id == ownId).firstOrNull;
        final joinedChannelId = ownClient?.channelId;

        state = state.copyWith(
          connecting: false,
          connected: true,
          serverName: event['server_name'] as String? ?? state.serverName,
          ownClientId: ownId,
          channels: channels,
          clients: clients,
          selectedChannelId: joinedChannelId,
        );

        // Auto-start audio playback (listening is always on in Teamspeak)
        _audioService = AudioService();
        _audioService!.onMicLevel = (double rms) {
          state = state.copyWith(micRms: rms);
        };
        _audioService!.start();
        // Init VAD defaults and start mic via control flow
        TsNative.setVadEnabled(true);
        TsNative.setVadThreshold(state.vadThreshold);
        _updateMicState();
        ForegroundService.start(
          title: state.serverName,
          text: _currentChannelName,
          mic: false,
          inputMuted: state.inputMuted,
          fullMuted: state.inputMuted && state.outputMuted,
          muteLabel: _notifMuteLabel,
          unmuteLabel: _notifUnmuteLabel,
          disconnectLabel: _notifDisconnectLabel,
        );
        // Battery-optimization exemption is requested AFTER the first-connect
        // OEM guide dialog (server_screen._maybeShowOemGuide), so the user
        // knows why the system settings page opens.
        _saveIdentity();
        break;

      case 'disconnected':
        if (state.connecting)
          break; // stale event from previous connection, ignore
        _pollTimer?.cancel();
        _audioService?.stop();
        _audioService = null;
        ForegroundService.stop();
        state = const TsConnectionState();
        break;

      case 'error':
        if (state.connecting) {
          state = state.copyWith(
            connecting: false,
            error: event['message'] as String,
          );
          _pollTimer?.cancel();
        }
        break;

      case 'text_message':
        final msg = ChatMessage(
          id: state.messages.length,
          fromClient: event['from_client'] as String,
          fromClientId: event['from_client_id'] as int,
          targetMode: event['target_mode'] as int,
          message: event['message'] as String,
          timestamp: DateTime.now(),
        );
        state = state.copyWith(messages: [...state.messages, msg]);
        break;

      case 'poke':
        // A poke is NOT a chat message — show a system notification.
        final from = event['from_client'] as String? ?? '';
        final pokeMsg = event['message'] as String? ?? '';
        final al = ref.read(localeProvider.notifier).localizations;
        ForegroundService.notifyPoke(
          title: al?.pokeNotificationTitle ?? 'You were poked',
          body:
              (al?.pokeNotificationBody(from, pokeMsg) ??
              '$from poked you: $pokeMsg'),
        );
        break;

      case 'client_joined':
        final client = TsClient(
          id: event['client_id'] as int,
          nickname: event['nickname'] as String,
          channelId: event['channel_id'] as int,
        );
        state = state.copyWith(clients: [...state.clients, client]);
        break;

      case 'client_left':
        final leftId = event['client_id'] as int;
        state = state.copyWith(
          clients: state.clients.where((c) => c.id != leftId).toList(),
        );
        break;

      case 'diag':
        final msg = event['msg'] as String;
        debugPrint('RUST: $msg');
        state = state.copyWith(diagMessages: [...state.diagMessages, msg]);
        break;

      case 'channels_updated':
        // Re-fetch channels and clients from Rust cache
        final chJson = TsNative.getChannels();
        final clJson = TsNative.getClients();
        final newChannels = (jsonDecode(chJson) as List)
            .map((j) => TsChannel.fromJson(j as Map<String, dynamic>))
            .toList();
        final newClients = (jsonDecode(clJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();
        state = state.copyWith(channels: newChannels, clients: newClients);
        _refreshNotification();
        break;
    }
  }

  Future<void> disconnect() async {
    debugPrint('TS: disconnect called, connected=${state.connected}');
    if (!state.connected && !state.connecting) return;
    // Ask Rust first: ts_disconnect sets the pending-disconnect flag
    // synchronously, so ts_stop_audio below keeps the output stream alive
    // until the "disconnected" sound finishes playing.
    TsNative.disconnect(); // sends Command::Disconnect to event loop
    _audioService?.stop();
    _audioService = null;
    _micEnabled = false;
    ForegroundService.stop();
    // Let the real 'disconnected' event from the event loop drive cleanup.
    // The poll timer keeps running — _handleEvent('disconnected') will
    // cancel it, reset state, and trigger the server_screen pop listener.
    state = state.copyWith(connecting: false);
  }

  Future<void> sendChannelMessage(String text) async {
    if (!state.connected || text.isEmpty) return;
    debugPrint(
      'TS: sendChannelMessage(cid=${state.selectedChannelId}, len=${text.length})',
    );
    TsNative.sendChannelMessage(state.selectedChannelId ?? 0, text);
    // Don't add optimistically — server echoes back as a text_message event
  }

  Future<void> sendPrivateMessage(int clientId, String text) async {
    if (!state.connected || text.isEmpty) return;
    final msg = ChatMessage(
      id: state.messages.length,
      fromClient: state.nickname,
      fromClientId: state.ownClientId,
      targetMode: 1,
      message: text,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, msg]);
  }

  void selectChannel(int channelId) {
    debugPrint('TS: selectChannel($channelId)');
    state = state.copyWith(selectedChannelId: channelId);
    TsNative.moveToChannel(channelId);
  }

  // ─── Voice control flow ──────────────────────────────────────────

  String get _currentChannelName {
    final own = state.clients
        .where((c) => c.id == state.ownClientId)
        .firstOrNull;
    if (own == null) return '';
    return state.channels
            .where((c) => c.id == own.channelId)
            .firstOrNull
            ?.name ??
        '';
  }

  // ─── Localized notification labels (no BuildContext here — read the
  // cached AppLocalizations from the locale provider) ───────────────────

  String get _notifMuteLabel =>
      ref.read(localeProvider.notifier).localizations?.notifMute ?? 'Mute';

  String get _notifUnmuteLabel =>
      ref.read(localeProvider.notifier).localizations?.notifUnmute ?? 'Unmute';

  String get _notifDisconnectLabel =>
      ref.read(localeProvider.notifier).localizations?.notifDisconnect ??
      'Disconnect';

  void _refreshNotification({bool? mic}) {
    final hasMic = mic ?? _micGranted;
    var text = _currentChannelName;
    if (!state.inputMuted || state.voiceActive) {
      text = '$text \u2014 Speaking';
    }
    ForegroundService.update(
      title: state.serverName,
      text: text,
      mic: hasMic,
      inputMuted: state.inputMuted,
      fullMuted: state.inputMuted && state.outputMuted,
      muteLabel: _notifMuteLabel,
      unmuteLabel: _notifUnmuteLabel,
      disconnectLabel: _notifDisconnectLabel,
    );
  }

  /// Diagram: Start -> PTT? -> pushed? -> send : mute? -> send : nothing
  bool get _shouldMicBeActive {
    if (state.pttMode) return state.pttPressed;
    return !state.inputMuted;
  }

  void _updateMicState() {
    if (_audioService == null) return;
    final should = _shouldMicBeActive;
    if (should && !_micEnabled) {
      _audioService!.enableMic().then((granted) {
        if (granted) {
          _micGranted = true;
          _refreshNotification(mic: true);
        }
      });
      _micEnabled = true;
    } else if (!should && _micEnabled) {
      _audioService!.disableMic();
      _micEnabled = false;
      _micGranted = false;
      _refreshNotification(mic: false);
    }
  }

  void togglePttMode() {
    final newPtt = !state.pttMode;
    state = state.copyWith(pttMode: newPtt);
    if (newPtt) {
      TsNative.setVadEnabled(false);
    } else {
      TsNative.setVadEnabled(state.vadEnabled);
      TsNative.setVadThreshold(state.vadThreshold);
    }
    _updateMicState();
  }

  void setPttPressed(bool pressed) {
    state = state.copyWith(pttPressed: pressed);
    _updateMicState();
  }

  void toggleInputMute() {
    final newMuted = !state.inputMuted;
    state = state.copyWith(inputMuted: newMuted);
    TsNative.setMuted(input: newMuted, output: state.outputMuted);
    _updateMicState();
    _refreshNotification();
  }

  /// Full mute: input + output muted and mic capture stopped. Idempotent —
  /// safe to call repeatedly (e.g. from the media card play/pause buttons).
  void setFullMute(bool muted) {
    if (state.inputMuted == muted && state.outputMuted == muted) return;
    state = state.copyWith(inputMuted: muted, outputMuted: muted);
    TsNative.setMuted(input: muted, output: muted);
    _updateMicState();
    _refreshNotification();
  }

  void toggleFullMute() {
    setFullMute(!(state.inputMuted && state.outputMuted));
  }

  void toggleOutputMute() {
    final newMuted = !state.outputMuted;
    state = state.copyWith(outputMuted: newMuted);
    TsNative.setMuted(input: state.inputMuted, output: newMuted);
    _refreshNotification();
  }

  /// Toggle our own away state. The server echo drives the
  /// away_activated/away_deactivated sounds via the Rust event loop.
  void toggleAway() {
    if (!state.connected) return;
    final newAway = !state.away;
    state = state.copyWith(away: newAway);
    TsNative.setAway(newAway);
  }

  /// Poke another client (sends a notifyclientpoke request).
  void sendPoke(int clientId, String message) {
    if (!state.connected) return;
    TsNative.sendPoke(clientId, message);
  }

  void setVadThreshold(double threshold) {
    state = state.copyWith(vadThreshold: threshold);
    TsNative.setVadThreshold(threshold);
  }

  void setVadEnabled(bool enabled) {
    state = state.copyWith(vadEnabled: enabled);
    TsNative.setVadEnabled(enabled);
  }

  void setMicGain(double gain) {
    state = state.copyWith(micGain: gain);
    TsNative.setMicGain(gain);
    _prefs?.setDouble('mic_gain', gain);
  }

  void setClientVolume(int clientId, double volumeDb) {
    TsNative.setClientVolume(clientId, volumeDb);
    final newClients = state.clients.map((c) {
      if (c.id == clientId) return c.copyWith(volume: volumeDb);
      return c;
    }).toList();
    state = state.copyWith(clients: newClients);
    // Persist per-client volume to SharedPreferences keyed by the user UID,
    // so it survives reconnects and client ID reuse. Without a UID (client
    // just joined and the roster hasn't refreshed yet) the change only
    // applies for this session; _applySavedClientVolumes re-applies it once
    // the UID shows up.
    final client = newClients.where((c) => c.id == clientId).firstOrNull;
    final uid = client?.uid;
    if (uid != null && uid.isNotEmpty) {
      _prefs?.setDouble('client_volume_uid_$uid', volumeDb);
    }
  }

  /// Removes legacy `client_volume_<clid>` keys persisted by older builds.
  /// Volume persistence now uses `client_volume_uid_<uid>`.
  void _migrateLegacyVolumeKeys() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith('client_volume_')) continue;
      final suffix = key.substring('client_volume_'.length);
      if (int.tryParse(suffix) != null) {
        prefs.remove(key);
      }
    }
  }

  /// Applies saved per-client volumes (keyed by user UID) to every client in
  /// the current roster whose saved volume differs from its current volume.
  /// Idempotent, so it is safe to call on every poll cycle: it covers the
  /// initial connect, clients that join later, and the window where a client's
  /// UID isn't known yet (the volume is re-applied once the UID appears).
  void _applySavedClientVolumes() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final client in state.clients) {
      final uid = client.uid;
      if (uid == null || uid.isEmpty) continue;
      final saved = prefs.getDouble('client_volume_uid_$uid');
      if (saved != null && (saved - client.volume).abs() > 0.001) {
        setClientVolume(client.id, saved);
      }
    }
  }
}

// ─── Server List Notifier ───────────────────────────────────────────

class ServerListNotifier extends Notifier<ServerListState> {
  @override
  ServerListState build() {
    _loadFromDisk();
    return const ServerListState();
  }

  Future<void> _loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList('servers') ?? [];
    final servers = data
        .map((s) => Server.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    state = state.copyWith(servers: servers, loading: false);
  }

  Future<void> _saveToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'servers',
      state.servers.map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  Future<void> addServer(Server server) async {
    state = state.copyWith(servers: [...state.servers, server]);
    await _saveToDisk();
  }

  Future<void> updateServer(Server server) async {
    final idx = state.servers.indexWhere((s) => s.id == server.id);
    if (idx < 0) return;
    final updated = [...state.servers];
    updated[idx] = server;
    state = state.copyWith(servers: updated);
    await _saveToDisk();
  }

  Future<void> removeServer(String serverId) async {
    state = state.copyWith(
      servers: state.servers.where((s) => s.id != serverId).toList(),
    );
    await _saveToDisk();
  }
}

// ─── Providers ──────────────────────────────────────────────────────

final tsConnectionProvider =
    NotifierProvider<TsConnectionNotifier, TsConnectionState>(
      TsConnectionNotifier.new,
    );

final serverListProvider =
    NotifierProvider<ServerListNotifier, ServerListState>(
      ServerListNotifier.new,
    );
