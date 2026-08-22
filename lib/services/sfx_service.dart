import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ts_ffi.dart';

/// SFX kinds, mirroring the Rust mapping (see the `SFX_*` consts in
/// api.rs). Persisted custom samples are stored per kind — do not renumber.
class SfxKind {
  SfxKind._();

  static const int channelSwitched = 1;
  static const int neutralToCurrent = 2;
  static const int neutralAwayFromCurrent = 3;
  static const int youWereMoved = 4;
  static const int youKickedChannel = 5;
  static const int youKickedServer = 6;
  static const int youWereBanned = 7;
  static const int youWerePoked = 8;
  static const int chatInbound = 9;
  static const int chatOutbound = 10;
  static const int connected = 11;
  static const int disconnected = 12;
  static const int connectionLost = 13;
  static const int error = 14;
  static const int micActivated = 15;
  static const int micMuted = 16;
  static const int soundMuted = 17;
  static const int soundResumed = 18;
  static const int awayActivated = 19;
  static const int awayDeactivated = 20;
  static const int channelCreated = 21;
  static const int channelDeleted = 22;
  static const int channelEdited = 23;
  static const int channelMoved = 24;
  static const int channelgroupChanged = 25;
  static const int neutralConnConnected = 26;
  static const int neutralConnDisconnected = 27;
  static const int neutralConnConnectionLost = 28;
  static const int neutralMovedToCurrent = 29;
  static const int neutralMovedAwayFromCurrent = 30;
  static const int neutralKickedChannelToCurrent = 31;
  static const int neutralKickedChannelAwayFromCurrent = 32;
  static const int neutralKickedServer = 33;
  static const int neutralBannedServer = 34;
  static const int neutralRecordingStarted = 35;
  static const int neutralRecordingStopped = 36;
  static const int neutralRecordingActive = 37;

  static const List<int> all = [
    channelSwitched,
    neutralToCurrent,
    neutralAwayFromCurrent,
    youWereMoved,
    youKickedChannel,
    youKickedServer,
    youWereBanned,
    youWerePoked,
    chatInbound,
    chatOutbound,
    connected,
    disconnected,
    connectionLost,
    error,
    micActivated,
    micMuted,
    soundMuted,
    soundResumed,
    awayActivated,
    awayDeactivated,
    channelCreated,
    channelDeleted,
    channelEdited,
    channelMoved,
    channelgroupChanged,
    neutralConnConnected,
    neutralConnDisconnected,
    neutralConnConnectionLost,
    neutralMovedToCurrent,
    neutralMovedAwayFromCurrent,
    neutralKickedChannelToCurrent,
    neutralKickedChannelAwayFromCurrent,
    neutralKickedServer,
    neutralBannedServer,
    neutralRecordingStarted,
    neutralRecordingStopped,
    neutralRecordingActive,
  ];
}

/// Error codes returned by `ts_set_sfx_sample` (also used here for
/// convenience so the settings UI can show localized messages).
class SfxError {
  SfxError._();

  static const int invalidKind = 1;
  static const int unsupportedFormat = 2;
  static const int emptyOrTooLong = 3;
}

/// Persists and plays user-custom channel-event sounds.
///
/// Custom WAV files are copied into the app's private documents directory
/// (`<docs>/sfx/<kind>.wav`) so they survive restarts without any storage
/// permission (the file picker uses SAF). On startup [init] replays them into
/// the Rust side; missing or unparseable files are skipped and the built-in
/// sample stays active.
class SfxService {
  SfxService._();

  static const _sfxDir = 'sfx';
  static const _namePrefix = 'sfx_name_';

  static Future<Directory> _directory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_sfxDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _fileFor(int kind) async {
    final dir = await _directory();
    return File('${dir.path}/$kind.wav');
  }

  /// Push persisted custom samples into Rust at startup. Missing files are
  /// skipped; unparseable ones leave the built-in sample active.
  static Future<void> init() async {
    for (final kind in SfxKind.all) {
      final file = await _fileFor(kind);
      if (!await file.exists()) {
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        continue;
      }
      final code = _setSample(kind, bytes);
      debugLog('[sfx] init kind=$kind -> $code');
    }
  }

  /// Install a custom WAV for a channel-event kind: pushes it to Rust, copies
  /// it into the private documents directory, and remembers the display name.
  /// Returns 0 on success, otherwise an [SfxError] code; on failure nothing is
  /// changed and the previously active sample stays in place.
  static Future<int> setCustom(
    int kind,
    Uint8List bytes, {
    String? fileName,
  }) async {
    if (!SfxKind.all.contains(kind)) {
      return SfxError.invalidKind;
    }
    if (bytes.isEmpty) {
      return SfxError.emptyOrTooLong;
    }
    final code = _setSample(kind, bytes);
    if (code != 0) {
      return code;
    }
    final file = await _fileFor(kind);
    await file.writeAsBytes(bytes, flush: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_namePrefix$kind',
      fileName == null || fileName.isEmpty ? '$kind.wav' : fileName,
    );
    return 0;
  }

  /// Restore the built-in sample for a kind: deletes the copied WAV, forgets
  /// the display name, and clears the Rust override. Returns 0 on success, 1
  /// for an invalid kind.
  static Future<int> resetToDefault(int kind) async {
    if (!SfxKind.all.contains(kind)) {
      return SfxError.invalidKind;
    }
    final file = await _fileFor(kind);
    if (await file.exists()) {
      await file.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_namePrefix$kind');
    return TsNative.clearSfxSample(kind);
  }

  /// Play the active sample for a kind immediately (settings-page preview).
  static int preview(int kind) {
    return TsNative.playSfx(kind);
  }

  /// Whether a custom sample is currently installed for [kind].
  static Future<bool> isCustom(int kind) async {
    final file = await _fileFor(kind);
    return file.exists();
  }

  /// Display name of the custom sample for [kind], or null when using the
  /// built-in sample.
  static Future<String?> customName(int kind) async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('$_namePrefix$kind');
    if (name != null && name.isNotEmpty) {
      return name;
    }
    final file = await _fileFor(kind);
    return (await file.exists()) ? '$kind.wav' : null;
  }

  static int _setSample(int kind, Uint8List bytes) {
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return TsNative.setSfxSample(kind, ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }
}
