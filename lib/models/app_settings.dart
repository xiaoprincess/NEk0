import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level preference toggles that must be readable from screens without
/// rebuilding connection state. Values are loaded lazily like the locale
/// provider: [loaded] flips once disk storage has been consulted, so callers
/// can distinguish "default" from "actually set" when needed.
class AppSettingsState {
  /// false = short tap joins a channel, long press opens its menu (default).
  /// true = the two are swapped.
  final bool channelGestureSwap;
  final bool loaded;

  const AppSettingsState({
    this.channelGestureSwap = false,
    this.loaded = false,
  });

  AppSettingsState copyWith({bool? channelGestureSwap, bool? loaded}) =>
      AppSettingsState(
        channelGestureSwap: channelGestureSwap ?? this.channelGestureSwap,
        loaded: loaded ?? this.loaded,
      );
}

class AppSettingsNotifier extends Notifier<AppSettingsState> {
  static const _kGestureSwap = 'channel_gesture_swap';

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
      loaded: true,
    );
  }

  Future<void> setChannelGestureSwap(bool swap) async {
    state = state.copyWith(channelGestureSwap: swap);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGestureSwap, swap);
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettingsState>(
      AppSettingsNotifier.new,
    );
