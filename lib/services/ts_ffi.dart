import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

// Load the native Rust library
final DynamicLibrary _lib = _loadLib();

DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtsclient.so');
  }
  throw UnsupportedError('Platform not supported');
}

// ─── C function typedefs ────────────────────────────────────────────

// ts_connect(address, nickname, channel, password) -> *char (JSON)
typedef _ConnectNative =
    Pointer<Utf8> Function(
      Pointer<Utf8> address,
      Pointer<Utf8> nickname,
      Pointer<Utf8> channel,
      Pointer<Utf8> password,
    );
typedef _ConnectDart =
    Pointer<Utf8> Function(
      Pointer<Utf8> address,
      Pointer<Utf8> nickname,
      Pointer<Utf8> channel,
      Pointer<Utf8> password,
    );

// ts_disconnect() -> *char (JSON)
typedef _DisconnectNative = Pointer<Utf8> Function();
typedef _DisconnectDart = Pointer<Utf8> Function();

// ts_poll_events() -> *char (JSON array)
typedef _PollEventsNative = Pointer<Utf8> Function();
typedef _PollEventsDart = Pointer<Utf8> Function();

// ts_get_channels() -> *char (JSON array)
typedef _GetChannelsNative = Pointer<Utf8> Function();
typedef _GetChannelsDart = Pointer<Utf8> Function();

// ts_get_clients() -> *char (JSON array)
typedef _GetClientsNative = Pointer<Utf8> Function();
typedef _GetClientsDart = Pointer<Utf8> Function();

// ts_send_channel_message(channel_id, message) -> bool
typedef _SendChannelMsgNative = Uint8 Function(Uint32, Pointer<Utf8>);
typedef _SendChannelMsgDart = int Function(int, Pointer<Utf8>);

// ts_move_to_channel(channel_id, password) -> bool
// password: null/empty for unlocked channels; plaintext, hashed in Rust.
typedef _MoveToChannelNative = Uint8 Function(Uint32, Pointer<Utf8>);
typedef _MoveToChannelDart = int Function(int, Pointer<Utf8>);

// ts_set_muted(input_muted, output_muted) -> bool
typedef _SetMutedNative = Uint8 Function(Uint8, Uint8);
typedef _SetMutedDart = int Function(int, int);

// ts_is_connected() -> bool
typedef _IsConnectedNative = Uint8 Function();
typedef _IsConnectedDart = int Function();

// ts_set_vad_threshold(threshold: f32)
typedef _SetVadThresholdNative = Void Function(Float);
typedef _SetVadThresholdDart = void Function(double);

// ts_set_vad_enabled(enabled: bool) -> bool
typedef _SetVadEnabledNative = Uint8 Function(Uint8);
typedef _SetVadEnabledDart = int Function(int);

// ts_start_audio() -> bool
typedef _StartAudioNative = Uint8 Function();
typedef _StartAudioDart = int Function();

// ts_stop_audio()
typedef _StopAudioNative = Void Function();
typedef _StopAudioDart = void Function();

// ts_send_audio(data: *const f32, data_len: u32) -> bool
typedef _SendAudioNative = Uint8 Function(Pointer<Float>, Uint32);
typedef _SendAudioDart = int Function(Pointer<Float>, int);

// ts_set_identity(json: *const c_char)
typedef _SetIdentityNative = Void Function(Pointer<Utf8>);
typedef _SetIdentityDart = void Function(Pointer<Utf8>);

// ts_get_identity() -> *mut c_char (null if none set)
typedef _GetIdentityNative = Pointer<Utf8> Function();
typedef _GetIdentityDart = Pointer<Utf8> Function();

// ts_set_mic_gain(gain: f32)
typedef _SetMicGainNative = Void Function(Float);
typedef _SetMicGainDart = void Function(double);

// ts_set_client_volume(client_id: u16, volume_db: f32)
typedef _SetClientVolumeNative = Void Function(Uint16, Float);
typedef _SetClientVolumeDart = void Function(int, double);

// ts_set_sfx_sample(kind: u8, data: *const u8, len: usize) -> i32
// Returns: 0 ok, 1 invalid kind, 2 unsupported format, 3 empty/too long.
typedef _SetSfxSampleNative = Int32 Function(Uint8, Pointer<Uint8>, IntPtr);
typedef _SetSfxSampleDart = int Function(int, Pointer<Uint8>, int);

// ts_clear_sfx_sample(kind: u8) -> i32
typedef _ClearSfxSampleNative = Int32 Function(Uint8);
typedef _ClearSfxSampleDart = int Function(int);

// ts_play_sfx(kind: u8) -> i32
typedef _PlaySfxNative = Int32 Function(Uint8);
typedef _PlaySfxDart = int Function(int);

// ts_set_away(away: bool) -> bool
typedef _SetAwayNative = Uint8 Function(Uint8);
typedef _SetAwayDart = int Function(int);

// ts_send_poke(client_id: u16, message: *const c_char) -> bool
typedef _SendPokeNative = Uint8 Function(Uint16, Pointer<Utf8>);
typedef _SendPokeDart = int Function(int, Pointer<Utf8>);

// ─── File transfer (channel file management) ────────────────────────

// ts_ft_list(channel_id, path, password, token) -> bool
typedef _FtListNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtListDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_mkdir(channel_id, dirname, password, token) -> bool
typedef _FtMkDirNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtMkDirDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_delete(channel_id, names_json, password, token) -> bool
typedef _FtDeleteNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtDeleteDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_download(channel_id, remote_path, dest_local_path, password) -> task_id
typedef _FtDownloadNative =
    Uint32 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtDownloadDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_upload(channel_id, remote_path, src_local_path, password) -> task_id
typedef _FtUploadNative =
    Uint32 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtUploadDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_cancel(task_id) -> bool
typedef _FtCancelNative = Uint8 Function(Uint32);
typedef _FtCancelDart = int Function(int);

// ─── Bindings ───────────────────────────────────────────────────────

final _connect = _lib.lookupFunction<_ConnectNative, _ConnectDart>(
  'ts_connect',
);
final _disconnect = _lib.lookupFunction<_DisconnectNative, _DisconnectDart>(
  'ts_disconnect',
);
final _pollEvents = _lib.lookupFunction<_PollEventsNative, _PollEventsDart>(
  'ts_poll_events',
);
final _getChannels = _lib.lookupFunction<_GetChannelsNative, _GetChannelsDart>(
  'ts_get_channels',
);
final _getClients = _lib.lookupFunction<_GetClientsNative, _GetClientsDart>(
  'ts_get_clients',
);
final _sendChannelMsg = _lib
    .lookupFunction<_SendChannelMsgNative, _SendChannelMsgDart>(
      'ts_send_channel_message',
    );
final _moveToChannel = _lib
    .lookupFunction<_MoveToChannelNative, _MoveToChannelDart>(
      'ts_move_to_channel',
    );
final _setMuted = _lib.lookupFunction<_SetMutedNative, _SetMutedDart>(
  'ts_set_muted',
);
final _isConnected = _lib.lookupFunction<_IsConnectedNative, _IsConnectedDart>(
  'ts_is_connected',
);
final _setVadThreshold = _lib
    .lookupFunction<_SetVadThresholdNative, _SetVadThresholdDart>(
      'ts_set_vad_threshold',
    );
final _setVadEnabled = _lib
    .lookupFunction<_SetVadEnabledNative, _SetVadEnabledDart>(
      'ts_set_vad_enabled',
    );
final _isVoiceActive = _lib
    .lookupFunction<_IsConnectedNative, _IsConnectedDart>('ts_is_voice_active');
final _startAudio = _lib.lookupFunction<_StartAudioNative, _StartAudioDart>(
  'ts_start_audio',
);
final _stopAudio = _lib.lookupFunction<_StopAudioNative, _StopAudioDart>(
  'ts_stop_audio',
);
final _sendAudio = _lib.lookupFunction<_SendAudioNative, _SendAudioDart>(
  'ts_send_audio',
);
final _setIdentity = _lib.lookupFunction<_SetIdentityNative, _SetIdentityDart>(
  'ts_set_identity',
);
final _getIdentity = _lib.lookupFunction<_GetIdentityNative, _GetIdentityDart>(
  'ts_get_identity',
);
final _setMicGain = _lib.lookupFunction<_SetMicGainNative, _SetMicGainDart>(
  'ts_set_mic_gain',
);
final _setClientVolume = _lib
    .lookupFunction<_SetClientVolumeNative, _SetClientVolumeDart>(
      'ts_set_client_volume',
    );
final _setSfxSample = _lib
    .lookupFunction<_SetSfxSampleNative, _SetSfxSampleDart>(
      'ts_set_sfx_sample',
    );
final _clearSfxSample = _lib
    .lookupFunction<_ClearSfxSampleNative, _ClearSfxSampleDart>(
      'ts_clear_sfx_sample',
    );
final _playSfx = _lib.lookupFunction<_PlaySfxNative, _PlaySfxDart>(
  'ts_play_sfx',
);
final _setAway = _lib.lookupFunction<_SetAwayNative, _SetAwayDart>(
  'ts_set_away',
);
final _sendPoke = _lib.lookupFunction<_SendPokeNative, _SendPokeDart>(
  'ts_send_poke',
);
final _ftList = _lib.lookupFunction<_FtListNative, _FtListDart>('ts_ft_list');
final _ftMkDir = _lib.lookupFunction<_FtMkDirNative, _FtMkDirDart>(
  'ts_ft_mkdir',
);
final _ftDelete = _lib.lookupFunction<_FtDeleteNative, _FtDeleteDart>(
  'ts_ft_delete',
);
final _ftDownload = _lib.lookupFunction<_FtDownloadNative, _FtDownloadDart>(
  'ts_ft_download',
);
final _ftUpload = _lib.lookupFunction<_FtUploadNative, _FtUploadDart>(
  'ts_ft_upload',
);
final _ftCancel = _lib.lookupFunction<_FtCancelNative, _FtCancelDart>(
  'ts_ft_cancel',
);

// ─── Helper ─────────────────────────────────────────────────────────

String _ptrToString(Pointer<Utf8> ptr) {
  try {
    return ptr.toDartString();
  } finally {
    // Use Rust's ts_free_string to free CString memory properly
    _freeString(ptr.cast());
  }
}

// ts_free_string frees memory allocated by Rust's CString::into_raw()
typedef _FreeStringNative = Void Function(Pointer<Void>);
typedef _FreeStringDart = void Function(Pointer<Void>);
final _freeString = _lib.lookupFunction<_FreeStringNative, _FreeStringDart>(
  'ts_free_string',
);

Pointer<Utf8> _strToPtr(String? s) {
  if (s == null) return Pointer<Utf8>.fromAddress(0);
  return s.toNativeUtf8();
}

// ─── Public API ─────────────────────────────────────────────────────

class TsNative {
  static String connect(
    String address,
    String nickname, {
    String? channel,
    String? password,
  }) {
    debugLog('connect($address, $nickname, ch=$channel)');
    final result = _connect(
      _strToPtr(address),
      _strToPtr(nickname),
      _strToPtr(channel),
      _strToPtr(password),
    );
    final str = _ptrToString(result);
    debugLog('connect -> $str');
    return str;
  }

  static String disconnect() {
    debugLog('disconnect()');
    final result = _ptrToString(_disconnect());
    debugLog('disconnect -> $result');
    return result;
  }

  static String pollEvents() {
    final result = _ptrToString(_pollEvents());
    // debugLog('pollEvents -> ${result.length > 200 ? result.substring(0, 200) + '...' : result}');
    return result;
  }

  static String getChannels() {
    return _ptrToString(_getChannels());
  }

  static String getClients() {
    return _ptrToString(_getClients());
  }

  static bool sendChannelMessage(int channelId, String message) {
    debugLog('sendChannelMessage(cid=$channelId, len=${message.length})');
    final result = _sendChannelMsg(channelId, _strToPtr(message));
    debugLog('sendChannelMessage -> $result');
    return result != 0;
  }

  static bool moveToChannel(int channelId, {String? password}) {
    debugLog(
      'moveToChannel($channelId, pw=${password == null ? 'no' : 'yes'})',
    );
    final ptr = _strToPtr(password ?? '');
    try {
      return _moveToChannel(channelId, ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  static bool setMuted({required bool input, required bool output}) {
    debugLog('setMuted(inp=$input, out=$output)');
    final result = _setMuted(input ? 1 : 0, output ? 1 : 0) != 0;
    debugLog('setMuted -> $result');
    return result;
  }

  static bool isConnected() {
    return _isConnected() != 0;
  }

  static void setIdentity(String json) {
    final ptr = _strToPtr(json);
    _setIdentity(ptr);
    malloc.free(ptr);
  }

  static String? getIdentity() {
    final ptr = _getIdentity();
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr.cast());
    }
  }

  static void setVadThreshold(double threshold) {
    _setVadThreshold(threshold);
  }

  static bool setVadEnabled(bool enabled) {
    return _setVadEnabled(enabled ? 1 : 0) != 0;
  }

  static bool isVoiceActive() {
    return _isVoiceActive() != 0;
  }

  static bool startAudio() {
    debugLog('startAudio');
    return _startAudio() != 0;
  }

  static void stopAudio() {
    debugLog('stopAudio');
    _stopAudio();
  }

  static bool sendAudio(Pointer<Float> data, int dataLen) {
    return _sendAudio(data, dataLen) != 0;
  }

  static void setMicGain(double gain) {
    debugLog('setMicGain($gain)');
    _setMicGain(gain);
  }

  static void setClientVolume(int clientId, double volumeDb) {
    _setClientVolume(clientId, volumeDb);
  }

  /// Install a custom WAV sample for an SFX kind (1..=25, see SfxKind).
  /// Returns 0 on success; see the typedef above for error codes.
  static int setSfxSample(int kind, Pointer<Uint8> data, int len) {
    return _setSfxSample(kind, data, len);
  }

  /// Restore the built-in sample for an SFX kind. Returns 0 on success, 1
  /// for an invalid kind.
  static int clearSfxSample(int kind) {
    return _clearSfxSample(kind);
  }

  /// Play the active sample for an SFX kind immediately (preview).
  /// Returns 0 on success, 1 for an invalid kind.
  static int playSfx(int kind) {
    return _playSfx(kind);
  }

  /// Set our own away state (server echo drives the away sounds).
  static bool setAway(bool away) {
    debugLog('setAway($away)');
    return _setAway(away ? 1 : 0) != 0;
  }

  /// Poke another client. Returns true when the request was queued.
  static bool sendPoke(int clientId, String message) {
    debugLog('sendPoke(client=$clientId, len=${message.length})');
    final ptr = _strToPtr(message);
    try {
      return _sendPoke(clientId, ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  // ─── File transfers ────────────────────────────────────────────────

  /// Requests a directory listing for a channel's file area. The answer
  /// arrives asynchronously as an `ft_listing` event carrying [token].
  static bool ftListToken(
    int channelId,
    String path,
    String token, {
    String? password,
  }) {
    final p = _strToPtr(path);
    final pw = _strToPtr(password);
    final t = _strToPtr(token);
    try {
      return _ftList(channelId, p, pw, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(pw);
      malloc.free(t);
    }
  }

  /// Creates a directory in a channel's file area. Returns true when the
  /// request was queued; the real outcome arrives as an `ft_op` event
  /// carrying [token].
  static bool ftMkDir(
    int channelId,
    String dirname,
    String token, {
    String? password,
  }) {
    debugLog('ftMkDir(cid=$channelId, dir=$dirname)');
    final pd = _strToPtr(dirname);
    final pw = _strToPtr(password);
    final pt = _strToPtr(token);
    try {
      return _ftMkDir(channelId, pd, pw, pt) != 0;
    } finally {
      malloc.free(pd);
      malloc.free(pw);
      malloc.free(pt);
    }
  }

  /// Deletes entries (files and/or folders — folders are removed
  /// recursively by the server). Paths must be COMPLETE remote addresses.
  /// Returns true when queued; the outcome arrives as `ft_op` with [token].
  static bool ftDelete(
    int channelId,
    List<String> fullPaths,
    String token, {
    String? password,
  }) {
    debugLog('ftDelete(cid=$channelId, names=${fullPaths.length})');
    final json = jsonEncode(fullPaths);
    final pj = _strToPtr(json);
    final pw = _strToPtr(password);
    final pt = _strToPtr(token);
    try {
      return _ftDelete(channelId, pj, pw, pt) != 0;
    } finally {
      malloc.free(pj);
      malloc.free(pw);
      malloc.free(pt);
    }
  }

  /// Starts downloading a remote file to a local absolute path. Returns a
  /// task id for progress/cancel tracking, or 0 when the request could not
  /// be queued at all.
  static int ftDownload(
    int channelId,
    String remotePath,
    String destLocalPath, {
    String? password,
  }) {
    debugLog('ftDownload(cid=$channelId, $remotePath)');
    final p = _strToPtr(remotePath);
    final d = _strToPtr(destLocalPath);
    final pw = _strToPtr(password);
    try {
      return _ftDownload(channelId, p, d, pw);
    } finally {
      malloc.free(p);
      malloc.free(d);
      malloc.free(pw);
    }
  }

  /// Starts uploading a local file to a remote path. Returns a task id or 0.
  static int ftUpload(
    int channelId,
    String remotePath,
    String srcLocalPath, {
    String? password,
  }) {
    debugLog('ftUpload(cid=$channelId, $remotePath)');
    final p = _strToPtr(remotePath);
    final s = _strToPtr(srcLocalPath);
    final pw = _strToPtr(password);
    try {
      return _ftUpload(channelId, p, s, pw);
    } finally {
      malloc.free(p);
      malloc.free(s);
      malloc.free(pw);
    }
  }

  /// Cancels an active transfer task (cooperative — some bytes may already
  /// be on disk / on the wire).
  static bool ftCancel(int taskId) => _ftCancel(taskId) != 0;
}

void debugLog(String msg) {
  // ignore: avoid_print
  print('[TS FFI] $msg');
}
