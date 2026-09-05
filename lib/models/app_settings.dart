import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sentinel for [AppSettingsState.copyWith] so a nullable field can be
/// explicitly reset to null instead of "keep the current value".
const _sentinel = Object();

/// App-level preference toggles that must be readable from screens without
/// rebuilding connection state. Values are loaded lazily like the locale
/// provider: [loaded] flips once disk storage has been consulted, so callers
/// can distinguish "default" from "actually set" when needed.
class AppSettingsState {
  /// false = short tap joins a channel, long press opens its menu (default).
  /// true = the two are swapped.
  final bool channelGestureSwap;

  /// Absolute path of the user-custom background image, or null when the
  /// app uses its built-in solid colors.
  final String? backgroundPath;

  /// Darkening overlay opacity (0–0.8) applied on top of the background
  /// image so light wallpapers keep text readable.
  final double backgroundDim;

  /// Opacity (0.1–1.0) of the background image itself — lower values fade
  /// the picture toward the base color for a subtler look.
  final double backgroundOpacity;

  final bool loaded;

  const AppSettingsState({
    this.channelGestureSwap = false,
    this.backgroundPath,
    this.backgroundDim = 0.4,
    this.backgroundOpacity = 1.0,
    this.loaded = false,
  });

  AppSettingsState copyWith({
    bool? channelGestureSwap,
    Object? backgroundPath = _sentinel,
    double? backgroundDim,
    double? backgroundOpacity,
    bool? loaded,
  }) => AppSettingsState(
    channelGestureSwap: channelGestureSwap ?? this.channelGestureSwap,
    backgroundPath: backgroundPath == _sentinel
        ? this.backgroundPath
        : backgroundPath as String?,
    backgroundDim: backgroundDim ?? this.backgroundDim,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    loaded: loaded ?? this.loaded,
  );
}

class AppSettingsNotifier extends Notifier<AppSettingsState> {
  static const _kGestureSwap = 'channel_gesture_swap';
  static const _kBackgroundPath = 'custom_bg_path';
  static const _kBackgroundDim = 'custom_bg_dim';
  static const _kBackgroundOpacity = 'custom_bg_opacity';

  @override
  AppSettingsState build() {
    _load();
    return const AppSettingsState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Read state only after the async gap: _load() is kicked off from
    // build(), and during that synchronous tail the provider state is not
    // initialized yet — reading it there throws "Tried to read the state of
    // an uninitialized provider". After the await the state always exists.
    if (state.loaded) return;
    state = state.copyWith(
      channelGestureSwap: prefs.getBool(_kGestureSwap) ?? false,
      backgroundPath: prefs.getString(_kBackgroundPath),
      backgroundDim: prefs.getDouble(_kBackgroundDim) ?? 0.4,
      backgroundOpacity: prefs.getDouble(_kBackgroundOpacity) ?? 1.0,
      loaded: true,
    );
  }

  Future<void> setChannelGestureSwap(bool swap) async {
    state = state.copyWith(channelGestureSwap: swap);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureSwap, swap);
  }

  Future<void> setBackground(String path) async {
    state = state.copyWith(backgroundPath: path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackgroundPath, path);
  }

  Future<void> clearBackground() async {
    state = state.copyWith(backgroundPath: null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kBackgroundPath);
  }

  Future<void> setBackgroundDim(double dim) async {
    state = state.copyWith(backgroundDim: dim.clamp(0.0, 0.8));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kBackgroundDim, dim);
  }

  Future<void> setBackgroundOpacity(double opacity) async {
    state = state.copyWith(backgroundOpacity: opacity.clamp(0.1, 1.0));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kBackgroundOpacity, opacity);
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettingsState>(
      AppSettingsNotifier.new,
    );
