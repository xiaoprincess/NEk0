import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

import '../models/ts_state.dart';

/// Maps a linear 0–1 mic level onto a 0–1 position on a −80 dB…0 dB scale.
/// Raw speech RMS sits around 0.01–0.3 (−40…−10 dB) and stops growing once
/// the mic signal clips, so on a linear bar it looked capped at a small
/// height. Bar and threshold knob are both drawn on this scale instead.
double _dbPos(double level) {
  if (level.isNaN || level <= 0.0) return 0.0;
  final db = 20.0 * math.log(level.clamp(0.0001, 1.0)) / math.ln10;
  return ((db + 80.0) / 80.0).clamp(0.0, 1.0);
}

/// Inverse of [_dbPos]: a slider position back to the linear threshold
/// value that is stored and handed to Rust.
double _dbPosToLinear(double pos) {
  final db = pos.clamp(0.0, 1.0) * 80.0 - 80.0;
  return math.pow(10.0, db / 20.0).toDouble();
}

/// Shared mic voice settings panel (PTT mode, VAD, threshold + level meter,
/// mic gain). Used by the server screen's long-press-mic bottom sheet and by
/// the settings screen.
class VoiceSettingsPanel extends StatefulWidget {
  const VoiceSettingsPanel({
    super.key,
    required this.conn,
    required this.notifier,
    this.showTitle = true,
    this.levelOverride,
  });

  final TsConnectionState conn;
  final TsConnectionNotifier notifier;
  final bool showTitle;

  /// External mic level (e.g. from the settings mic test). When null the
  /// panel falls back to the live [conn.micRms].
  final double? levelOverride;

  @override
  State<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

class _VoiceSettingsPanelState extends State<VoiceSettingsPanel> {
  late bool _pttMode;
  late bool _vadEnabled;
  late double _vadThreshold;
  late double _micGain;

  @override
  void initState() {
    super.initState();
    _pttMode = widget.conn.pttMode;
    _vadEnabled = widget.conn.vadEnabled;
    _vadThreshold = widget.conn.vadThreshold;
    _micGain = widget.conn.micGain;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showTitle) ...[
          Text(
            AppLocalizations.of(context).voiceSettings,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
        ],
        // PTT / VA mode toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              AppLocalizations.of(context).pttMode,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Switch(
              value: _pttMode,
              activeTrackColor: Colors.blue,
              onChanged: (v) {
                setState(() => _pttMode = v);
                widget.notifier.togglePttMode();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        // VAD enable/disable
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              AppLocalizations.of(context).voiceActivation,
              style: TextStyle(
                color: _pttMode ? Colors.grey : Colors.white,
                fontSize: 14,
              ),
            ),
            Switch(
              value: _vadEnabled,
              activeTrackColor: Colors.blue,
              onChanged: _pttMode
                  ? null
                  : (v) {
                      setState(() => _vadEnabled = v);
                      widget.notifier.setVadEnabled(v);
                    },
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Threshold slider stacked on mic level bar (both on a −80…0 dB
        // scale; the numbers on the right show the raw linear values)
        Builder(
          builder: (_) {
            final s = widget.conn;
            final micActive = !s.inputMuted && (!s.pttMode || s.pttPressed);
            final rms = widget.levelOverride ?? (micActive ? s.micRms : 0.0);
            final level = rms.isNaN ? 0.0 : rms;
            final fill = _dbPos(level);
            final over = level >= _vadThreshold && _vadThreshold > 0.0;
            return Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text(
                    AppLocalizations.of(context).level,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Bottom: mic level bar
                      LinearProgressIndicator(
                        value: fill,
                        backgroundColor: Colors.grey[800],
                        color: over ? Colors.blue : Colors.grey,
                        minHeight: 4,
                      ),
                      // Top: threshold slider (transparent track, only knob visible)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          thumbColor: Colors.blue,
                          disabledThumbColor: Colors.grey,
                        ),
                        child: Slider(
                          value: _dbPos(_vadThreshold),
                          min: 0.0,
                          max: 1.0,
                          onChanged: (_pttMode || !_vadEnabled)
                              ? null
                              : (v) {
                                  final t = _dbPosToLinear(v);
                                  setState(() => _vadThreshold = t);
                                  widget.notifier.setVadThreshold(t);
                                },
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Live mic input level (linear RMS, like the threshold
                      // below — the bar itself is dB-scaled for visibility).
                      Text(
                        level.toStringAsFixed(3),
                        style: TextStyle(
                          color: over ? Colors.blue : Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        _vadThreshold.toStringAsFixed(3),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        // Mic gain slider
        Row(
          children: [
            Text(
              AppLocalizations.of(context).micGain,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: _micGain,
                min: 0.0,
                max: 2.0,
                divisions: 40,
                activeColor: Colors.blue,
                onChanged: (v) {
                  setState(() => _micGain = v);
                  widget.notifier.setMicGain(v);
                },
              ),
            ),
            Text(
              _micGain.toStringAsFixed(2),
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}
