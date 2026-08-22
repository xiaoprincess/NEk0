mod api;

use crossbeam::queue::SegQueue;
use crossbeam::atomic::AtomicCell;
use dashmap::DashMap;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
use std::time::Instant;
use tokio::runtime::Runtime;

pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    Runtime::new().expect("Failed to create tokio runtime")
});

// ─── Command queue ───────────────────────────────────────────────────

#[derive(Debug)]
pub enum Command {
    SendMessage { target_mode: u8, target_cid: u64, message: String },
    MoveChannel { client_id: u16, channel_id: u64 },
    SetMuted { input: bool, output: bool },
    SetAway { away: bool },
    SendPoke { client_id: u16, message: String },
    Disconnect,
    SendAudio { data: Vec<f32> },
}

pub static COMMAND_TX: Lazy<Mutex<Option<tokio::sync::mpsc::UnboundedSender<Command>>>> =
    Lazy::new(|| Mutex::new(None));

pub static CONNECTION_GENERATION: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
pub static EVENT_LOOP_ALIVE: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static SWIPE_DISCONNECT: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
/// Set when the cpal output stream should be rebuilt (device route change,
/// stream error, or explicit restart request from the Android side). The
/// maintenance task performs the rebuild on its 500ms tick.
pub static OUTPUT_RESTART_REQUESTED: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static CONNECTION_STASH: Lazy<Mutex<Option<tsclientlib::Connection>>> = Lazy::new(|| Mutex::new(None));
pub static IDENTITY_STASH: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// ─── Types for Dart ─────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type")]
pub enum TsEvent {
    #[serde(rename = "connected")]
    Connected { server_name: String, client_id: u32 },
    #[serde(rename = "disconnected")]
    Disconnected { reason: String },
    #[serde(rename = "text_message")]
    TextMessage { from_client: String, from_client_id: u32, target_mode: u8, message: String },
    #[serde(rename = "client_joined")]
    ClientJoined { client_id: u32, nickname: String, channel_id: u32 },
    #[serde(rename = "client_left")]
    ClientLeft { client_id: u32, nickname: String },
    #[serde(rename = "channels_updated")]
    ChannelsUpdated {},
    #[serde(rename = "diag")]
    Diag { msg: String },
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsChannel {
    pub id: u32,
    pub name: String,
    pub parent_id: u32,
    pub topic: String,
    pub has_password: bool,
    pub client_count: u32,
    pub order: u32,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsClient {
    pub id: u32,
    pub nickname: String,
    pub channel_id: u32,
    pub away: bool,
    pub input_muted: bool,
    pub output_muted: bool,
    pub is_talking: bool,
    pub volume: f32,
    pub uid: Option<String>,
}

// ─── Per-client lock-free jitter buffer ──────────────────────────────

/// Lock-free per-client jitter buffer with 32 slots (640ms window at 20ms/frame).
/// Writer: decoding thread (one per client). Reader: cpal audio callback.
pub struct ClientJitterBuffer {
    /// Circular array of frame slots. AtomicCell swap provides lock-free read/write.
    pub slots: [AtomicCell<Option<Vec<i16>>>; 32],
    /// Sequence number of the most recently written frame (unwrapped to u32 space).
    pub write_seq: AtomicU32,
    /// First sequence number seen, unwrapped to u32 space. Set once with compare_exchange.
    pub base_seq: AtomicU32,
    /// Global play_slot at which base_seq should be played (base_seq → base_slot mapping).
    pub base_slot: AtomicU64,
    /// Monotonic timestamp of last received packet. None = never received. Used for cleanup.
    pub last_packet: AtomicCell<Option<Instant>>,
    /// Lock-free frame pool — callback pushes used frames, decoder pops them. No contention.
    pub frame_pool: SegQueue<Vec<i16>>,
    /// Linear gain as f32::to_bits, applied as mixing weight in the audio callback.
    pub volume: AtomicU32,
}

impl ClientJitterBuffer {
    pub fn new() -> Self {
        const NONE: AtomicCell<Option<Vec<i16>>> =
            AtomicCell::new(None);
        Self {
            slots: [NONE; 32],
            write_seq: AtomicU32::new(0),
            base_seq: AtomicU32::new(0),
            base_slot: AtomicU64::new(0),
            last_packet: AtomicCell::new(None),
            frame_pool: SegQueue::new(),
            volume: AtomicU32::new(f32::to_bits(1.0)),
        }
    }
}

// ─── Global State ───────────────────────────────────────────────────

pub struct TsConnection {
    pub connected: bool,
    pub connecting: bool,
    pub server_name: String,
    pub nickname: String,
    pub own_client_id: u32,
    pub channels: Vec<TsChannel>,
    pub clients: Vec<TsClient>,
    pub pending_events: VecDeque<TsEvent>,
    // Audio send state
    pub pcm_in: Vec<f32>,
    pub audio_encoder: Option<opus_rs::OpusEncoder>,
    pub audio_seq: u16,
    pub vad_threshold: f32,
    pub vad_enabled: bool,
    pub vad_hold: u32,
    pub voice_active: bool,
    pub disconnect_requested: bool,
    pub mic_gain: f32,
    // Audio receive state
    pub talking_clients: HashMap<u16, Instant>, // last audio timestamp per client (monotonic Instant)
    /// Per-client volume in decibels (dB), keyed by the client's user UID.
    /// Source of truth — NOT cleared on disconnect. The numeric client ID is
    /// only a session-scoped handle; the UID is what survives reconnects and
    /// identifies the same user across servers.
    pub client_volumes: HashMap<String, f32>,
}

impl TsConnection {
    fn new() -> Self {
        Self {
            connected: false,
            connecting: false,
            server_name: String::new(),
            nickname: String::new(),
            own_client_id: 0,
            channels: Vec::new(),
            clients: Vec::new(),
            pending_events: VecDeque::new(),
            pcm_in: Vec::new(),
            audio_encoder: None,
            audio_seq: 0,
            vad_threshold: 0.0,
            vad_enabled: false,
            vad_hold: 0,
            voice_active: false,
            disconnect_requested: false,
            mic_gain: 1.0,
            talking_clients: HashMap::new(),
            client_volumes: HashMap::new(),
        }
    }
}

pub static STATE: Lazy<Mutex<TsConnection>> = Lazy::new(|| Mutex::new(TsConnection::new()));
pub static PANIC_LOG: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

/// cpal output stream (Send-safe wrapper). Drop to stop audio playback.
pub struct SendStream(pub Option<cpal::Stream>);
unsafe impl Send for SendStream {}
pub static AUDIO_STREAM: std::sync::Mutex<SendStream> = std::sync::Mutex::new(SendStream(None));

// ─── Lock-free audio globals ─────────────────────────────────────────

pub static CLIENT_BUFFERS: Lazy<DashMap<u16, ClientJitterBuffer>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS_STEREO: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub const FRAME_SIZE: u64 = 960;
/// Total samples written to the hardware output buffer since stream start.
/// Logical frame number = PLAYED_SAMPLES / FRAME_SIZE.
pub static PLAYED_SAMPLES: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
/// Client ID snapshot for the audio callback — avoids iterating DashMap in the callback.
/// Refreshed by the maintenance task every 500ms. Lock-free via ArcSwap.
pub static ACTIVE_CLIENT_IDS: Lazy<arc_swap::ArcSwap<Vec<u16>>> =
    Lazy::new(|| arc_swap::ArcSwap::from(std::sync::Arc::new(Vec::new())));

// ─── Channel-event SFX (25 built-in sounds) ──────────────────────────

/// SFX request queue consumed by the cpal callback. Values 1..=25 map to
/// the built-in sounds (see `SFX_BUILTIN`); written by the event loop (one
/// request per triggering event), read lock-free by the audio callback.
/// Playback slots are per-stream, so the queue is drained on stream
/// restart/stop.
pub static SFX_QUEUE: Lazy<SegQueue<u8>> = Lazy::new(SegQueue::new);

/// Suppression flag for the initial roster sync. Reset when a connection is
/// established and when a temporary disconnect happens; set once the first
/// `BookEvents` batch has been processed. The connection library replays the
/// whole roster on reconnect, and the first event-loop batch after connect
/// may still carry late-arriving list data — neither should produce sounds.
pub static SFX_ARMED: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Set when our own client was kicked or banned. The server closes the
/// connection right after, and the "disconnected" sound must not play on
/// top of the kick/ban sound. Cleared when a new connection is established.
pub static SFX_SUPPRESS_DISCONNECT: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Set while a disconnect/error sound is still playing through the output
/// stream and its teardown has been deferred (see `schedule_sfx_teardown`
/// in api.rs). `ts_stop_audio` respects this flag and leaves the stream
/// alone so the sound can finish; the deferred task performs the teardown.
pub static SFX_DEFERRED_TEARDOWN: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Drop all pending SFX requests (e.g. when the output stream is rebuilt).
pub fn clear_sfx_queue() {
    while SFX_QUEUE.pop().is_some() {}
}

// ─── SFX sample storage (built-in assets + custom overrides) ────────

/// Parse a RIFF/WAVE file into 48 kHz mono f32 samples suitable for SFX
/// playback (the cpal output format).
///
/// Supported: PCM 16-bit and IEEE float32, 1 or 2 channels (stereo is
/// averaged down to mono), any sample rate (linearly resampled to 48 kHz).
/// Rejects non-RIFF/WAVE input, other encodings, files without audio data,
/// and files longer than 2 seconds.
pub(crate) fn parse_wav_pcm(data: &[u8]) -> Result<Vec<f32>, String> {
    const MAX_SECONDS: f64 = 2.0;
    const TARGET_RATE: u32 = 48_000;

    if data.len() < 12 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_string());
    }

    let mut fmt: Option<(u16, u16, u32, u16)> = None; // (format, channels, rate, bits)
    let mut data_chunks: Vec<&[u8]> = Vec::new();
    let mut off = 12usize;
    while off + 8 <= data.len() {
        let id = &data[off..off + 4];
        let size = u32::from_le_bytes(
            data[off + 4..off + 8]
                .try_into()
                .map_err(|_| "bad chunk size".to_string())?,
        ) as usize;
        let chunk_start = off + 8;
        if size > data.len().saturating_sub(chunk_start) {
            break; // truncated chunk — stop walking, keep what we have
        }
        let chunk = &data[chunk_start..chunk_start + size];
        match id {
            b"fmt " => {
                if chunk.len() < 16 {
                    return Err("fmt chunk too short".to_string());
                }
                let format = u16::from_le_bytes([chunk[0], chunk[1]]);
                let channels = u16::from_le_bytes([chunk[2], chunk[3]]);
                let rate = u32::from_le_bytes(
                    chunk[4..8]
                        .try_into()
                        .map_err(|_| "bad sample rate".to_string())?,
                );
                let bits = u16::from_le_bytes([chunk[14], chunk[15]]);
                fmt = Some((format, channels, rate, bits));
            }
            b"data" => data_chunks.push(chunk),
            _ => {}
        }
        off = chunk_start + size + (size & 1);
    }

    let (format, channels, rate, bits) =
        fmt.ok_or_else(|| "missing fmt chunk".to_string())?;
    if rate == 0 {
        return Err("invalid sample rate 0".to_string());
    }
    if channels != 1 && channels != 2 {
        return Err(format!("unsupported channel count {}", channels));
    }

    let decode = |chunk: &[u8]| -> Result<Vec<f32>, String> {
        match (format, bits) {
            // PCM 16-bit
            (1, 16) => {
                let frame_bytes = channels as usize * 2;
                let frames = chunk.len() / frame_bytes;
                let mut out = Vec::with_capacity(frames);
                for f in 0..frames {
                    let base = f * frame_bytes;
                    let mut sum = 0i64;
                    for ch in 0..channels as usize {
                        let idx = base + ch * 2;
                        let v = i16::from_le_bytes([chunk[idx], chunk[idx + 1]]) as i64;
                        sum += v;
                    }
                    out.push((sum as f32 / channels as f32) / 32768.0);
                }
                Ok(out)
            }
            // IEEE float32
            (3, 32) => {
                let frame_bytes = channels as usize * 4;
                let frames = chunk.len() / frame_bytes;
                let mut out = Vec::with_capacity(frames);
                for f in 0..frames {
                    let base = f * frame_bytes;
                    let mut sum = 0.0f32;
                    for ch in 0..channels as usize {
                        let idx = base + ch * 4;
                        let v = f32::from_le_bytes(
                            chunk[idx..idx + 4]
                                .try_into()
                                .map_err(|_| "bad float sample".to_string())?,
                        );
                        sum += v;
                    }
                    out.push(sum / channels as f32);
                }
                Ok(out)
            }
            _ => Err(format!(
                "unsupported WAV encoding format={} bits={} (expected PCM 16-bit or float32)",
                format, bits
            )),
        }
    };

    let mut pcm: Vec<f32> = Vec::new();
    for chunk in &data_chunks {
        pcm.extend(decode(chunk)?);
    }
    if pcm.is_empty() {
        return Err("no audio data".to_string());
    }

    let seconds = pcm.len() as f64 / rate as f64;
    if seconds > MAX_SECONDS {
        return Err(format!(
            "audio too long ({:.3}s > {:.0}s)",
            seconds, MAX_SECONDS
        ));
    }

    if rate == TARGET_RATE {
        return Ok(pcm);
    }

    // Linear resample to 48 kHz mono.
    let ratio = rate as f64 / TARGET_RATE as f64;
    let out_len = (pcm.len() as f64 * TARGET_RATE as f64 / rate as f64).ceil() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let pos = i as f64 * ratio;
        let idx = pos.floor() as usize;
        let frac = (pos - idx as f64) as f32;
        let a = pcm.get(idx).copied().unwrap_or(0.0);
        let b = pcm.get(idx + 1).copied().unwrap_or(a);
        out.push(a + (b - a) * frac);
    }
    Ok(out)
}

/// Parse a built-in channel-event SFX sample with startup diagnostics:
/// parse failures and silent (all-zero) samples are logged so asset problems
/// are visible in logcat instead of failing silently at playback time.
fn load_builtin_sfx(kind: usize, name: &str) -> Option<Vec<f32>> {
    let data: &[u8] = match kind {
        0 => include_bytes!("../assets/sfx/channel_switched.wav"),
        1 => include_bytes!("../assets/sfx/neutral_switched_tocurrentchannel.wav"),
        2 => include_bytes!("../assets/sfx/neutral_switched_awayfromcurrentchannel.wav"),
        3 => include_bytes!("../assets/sfx/you_were_moved.wav"),
        4 => include_bytes!("../assets/sfx/you_kicked_channel.wav"),
        5 => include_bytes!("../assets/sfx/you_kicked_server.wav"),
        6 => include_bytes!("../assets/sfx/you_were_banned.wav"),
        7 => include_bytes!("../assets/sfx/you_were_poked.wav"),
        8 => include_bytes!("../assets/sfx/chat_message_inbound.wav"),
        9 => include_bytes!("../assets/sfx/chat_message_outbound.wav"),
        10 => include_bytes!("../assets/sfx/connected.wav"),
        11 => include_bytes!("../assets/sfx/disconnected.wav"),
        12 => include_bytes!("../assets/sfx/connection_lost.wav"),
        13 => include_bytes!("../assets/sfx/error.wav"),
        14 => include_bytes!("../assets/sfx/mic_activated.wav"),
        15 => include_bytes!("../assets/sfx/mic_muted.wav"),
        16 => include_bytes!("../assets/sfx/sound_muted.wav"),
        17 => include_bytes!("../assets/sfx/sound_resumed.wav"),
        18 => include_bytes!("../assets/sfx/away_activated.wav"),
        19 => include_bytes!("../assets/sfx/away_deactivated.wav"),
        20 => include_bytes!("../assets/sfx/channel_created.wav"),
        21 => include_bytes!("../assets/sfx/channel_deleted.wav"),
        22 => include_bytes!("../assets/sfx/channel_edited.wav"),
        23 => include_bytes!("../assets/sfx/channel_moved.wav"),
        24 => include_bytes!("../assets/sfx/channelgroup_changed.wav"),
        25 => include_bytes!("../assets/sfx/neutral_connection_connected_currentchannel.wav"),
        26 => include_bytes!("../assets/sfx/neutral_connection_disconnected_currentchannel.wav"),
        27 => include_bytes!("../assets/sfx/neutral_connection_connectionlost_currentchannel.wav"),
        28 => include_bytes!("../assets/sfx/neutral_moved_tocurrentchannel.wav"),
        29 => include_bytes!("../assets/sfx/neutral_moved_awayfromcurrentchannel.wav"),
        30 => include_bytes!("../assets/sfx/neutral_kicked_channel_tocurrentchannel.wav"),
        31 => include_bytes!("../assets/sfx/neutral_kicked_channel_awayfromcurrentchannel.wav"),
        32 => include_bytes!("../assets/sfx/neutral_kicked_server_currentchannel.wav"),
        33 => include_bytes!("../assets/sfx/neutral_banned_server_currentchannel.wav"),
        34 => include_bytes!("../assets/sfx/neutral_recording_started_currentchannel.wav"),
        35 => include_bytes!("../assets/sfx/neutral_recording_stopped_currentchannel.wav"),
        _ => include_bytes!("../assets/sfx/neutral_recording_active_currentchannel.wav"),
    };
    match parse_wav_pcm(data) {
        Ok(samples) => {
            let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
            if peak < 1e-4 {
                eprintln!(
                    "[sfx] builtin kind={} \"{}\": SILENT sample (peak={:.2e})",
                    kind, name, peak
                );
            } else {
                eprintln!(
                    "[sfx] builtin kind={} \"{}\": {} samples, peak={:.3}",
                    kind,
                    name,
                    samples.len(),
                    peak
                );
            }
            Some(samples)
        }
        Err(msg) => {
            eprintln!("[sfx] builtin kind={} \"{}\": parse failed: {}", kind, name, msg);
            None
        }
    }
}

/// Built-in SFX samples, parsed once at startup from assets embedded with
/// `include_bytes!`. Index 0..37 = kind 1..=37 (see the order in
/// `load_builtin_sfx`): 0 channel_switched, 1 neutral_switched_tocurrent,
/// 2 neutral_switched_away, 3 you_were_moved, 4 you_kicked_channel,
/// 5 you_kicked_server, 6 you_were_banned, 7 you_were_poked,
/// 8 chat_message_inbound, 9 chat_message_outbound, 10 connected,
/// 11 disconnected, 12 connection_lost, 13 error, 14 mic_activated,
/// 15 mic_muted, 16 sound_muted, 17 sound_resumed, 18 away_activated,
/// 19 away_deactivated, 20 channel_created, 21 channel_deleted,
/// 22 channel_edited, 23 channel_moved, 24 channelgroup_changed,
/// 25..36 neutral_* other-user sounds (connection/moved/kicked/banned/
/// recording), 37 neutral_recording_active.
/// A `None` entry means the asset is missing or failed to parse (playback
/// falls back to silence for that kind).
pub static SFX_BUILTIN: Lazy<[Option<Vec<f32>>; 37]> = Lazy::new(|| {
    [
        load_builtin_sfx(0, "channel_switched"),
        load_builtin_sfx(1, "neutral_switched_tocurrentchannel"),
        load_builtin_sfx(2, "neutral_switched_awayfromcurrentchannel"),
        load_builtin_sfx(3, "you_were_moved"),
        load_builtin_sfx(4, "you_kicked_channel"),
        load_builtin_sfx(5, "you_kicked_server"),
        load_builtin_sfx(6, "you_were_banned"),
        load_builtin_sfx(7, "you_were_poked"),
        load_builtin_sfx(8, "chat_message_inbound"),
        load_builtin_sfx(9, "chat_message_outbound"),
        load_builtin_sfx(10, "connected"),
        load_builtin_sfx(11, "disconnected"),
        load_builtin_sfx(12, "connection_lost"),
        load_builtin_sfx(13, "error"),
        load_builtin_sfx(14, "mic_activated"),
        load_builtin_sfx(15, "mic_muted"),
        load_builtin_sfx(16, "sound_muted"),
        load_builtin_sfx(17, "sound_resumed"),
        load_builtin_sfx(18, "away_activated"),
        load_builtin_sfx(19, "away_deactivated"),
        load_builtin_sfx(20, "channel_created"),
        load_builtin_sfx(21, "channel_deleted"),
        load_builtin_sfx(22, "channel_edited"),
        load_builtin_sfx(23, "channel_moved"),
        load_builtin_sfx(24, "channelgroup_changed"),
        load_builtin_sfx(25, "neutral_connection_connected_currentchannel"),
        load_builtin_sfx(26, "neutral_connection_disconnected_currentchannel"),
        load_builtin_sfx(27, "neutral_connection_connectionlost_currentchannel"),
        load_builtin_sfx(28, "neutral_moved_tocurrentchannel"),
        load_builtin_sfx(29, "neutral_moved_awayfromcurrentchannel"),
        load_builtin_sfx(30, "neutral_kicked_channel_tocurrentchannel"),
        load_builtin_sfx(31, "neutral_kicked_channel_awayfromcurrentchannel"),
        load_builtin_sfx(32, "neutral_kicked_server_currentchannel"),
        load_builtin_sfx(33, "neutral_banned_server_currentchannel"),
        load_builtin_sfx(34, "neutral_recording_started_currentchannel"),
        load_builtin_sfx(35, "neutral_recording_stopped_currentchannel"),
        load_builtin_sfx(36, "neutral_recording_active_currentchannel"),
    ]
});

/// The active SFX samples (custom override or built-in fallback) as seen by
/// the cpal audio thread. `ArcSwap` gives lock-free reads, so the callback
/// never blocks while a custom sample is being installed from Dart.
pub static SFX_SAMPLES: Lazy<arc_swap::ArcSwap<[Option<std::sync::Arc<Vec<f32>>>; 37]>> =
    Lazy::new(|| {
        let builtin: [Option<std::sync::Arc<Vec<f32>>>; 37] =
            std::array::from_fn(|i| {
                SFX_BUILTIN[i]
                    .as_ref()
                    .map(|s| std::sync::Arc::new(s.clone()))
            });
        arc_swap::ArcSwap::from(std::sync::Arc::new(builtin))
    });

// ─── Diagnostic callback stats (all atomics, safe to write from audio thread) ──

pub struct CallbackStats {
    /// Total callback invocations since last stats print.
    pub callbacks: AtomicU64,
    /// Sum of data.len() across all callbacks since last print.
    pub samples_total: AtomicU64,
    /// Total mix frames generated (slot changes) since last print.
    pub mix_frames: AtomicU64,
    /// DRIFT CHECK: expected played value at next callback entry. Set at end of
    /// each callback to (PLAYED_SAMPLES after fetch_add). The next callback compares
    /// its played_before against this value; mismatch = audio clock drift.
    pub expected_next_played: AtomicU64,
    /// Total PLAYED_SAMPLES consistency violations.
    pub played_mismatches: AtomicU64,
    /// Microseconds since the previous callback entry (0 if this is first).
    pub last_interval_us: AtomicU64,
    /// Instant::now() at the start of the last callback, in nanoseconds from boot.
    /// Used to compute the interval to the next callback.
    pub last_cb_entry_ns: AtomicU64,
}

pub static CB_STATS: Lazy<CallbackStats> = Lazy::new(|| CallbackStats {
    callbacks: AtomicU64::new(0),
    samples_total: AtomicU64::new(0),
    mix_frames: AtomicU64::new(0),
    expected_next_played: AtomicU64::new(0),
    played_mismatches: AtomicU64::new(0),
    last_interval_us: AtomicU64::new(0),
    last_cb_entry_ns: AtomicU64::new(0),
});

pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let location = info.location()
            .map(|l| {
                let file = l.file();
                let short = file.rsplit(&['/', '\\']).next().unwrap_or(file);
                format!("{}:{}:{}", short, l.line(), l.column())
            })
            .unwrap_or_else(|| "unknown location".into());
        let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".into()
        };
        let msg = format!("PANIC {}: {}", location, payload);
        eprintln!("{}", msg);
        *PANIC_LOG.lock() = msg;
    }));
}

pub fn flush_panic_log() {
    let mut log = PANIC_LOG.lock();
    if !log.is_empty() {
        STATE.lock().pending_events.push_back(TsEvent::Diag {
            msg: log.clone(),
        });
        log.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::parse_wav_pcm;

    fn wav_pcm16(rate: u32, channels: u16, samples: &[i16]) -> Vec<u8> {
        let bits: u16 = 16;
        let block_align = channels * bits / 8;
        let byte_rate = rate * block_align as u32;
        let data_len = samples.len() as u32 * (bits as u32 / 8);
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for &s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    fn wav_f32(rate: u32, channels: u16, samples: &[f32]) -> Vec<u8> {
        let bits: u16 = 32;
        let block_align = channels * bits / 8;
        let byte_rate = rate * block_align as u32;
        let data_len = samples.len() as u32 * (bits as u32 / 8);
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&3u16.to_le_bytes()); // IEEE float
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for &s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    #[test]
    fn parses_mono_16bit() {
        let wav = wav_pcm16(48_000, 1, &[0, 16_384, 32_767, -32_768, -16_384]);
        let pcm = parse_wav_pcm(&wav).expect("valid mono 16-bit WAV");
        assert_eq!(pcm.len(), 5);
        assert!((pcm[0] - 0.0).abs() < 1e-6);
        assert!((pcm[1] - 0.5).abs() < 1e-4);
        assert!((pcm[2] - 1.0).abs() < 1e-4);
        assert!((pcm[3] + 1.0).abs() < 1e-4);
        assert!((pcm[4] + 0.5).abs() < 1e-4);
    }

    #[test]
    fn downmixes_stereo_to_mono() {
        // Interleaved L/R: each pair cancels to ~0.
        let samples: Vec<i16> = (0..20)
            .flat_map(|_| [10_000i16, -10_000i16])
            .collect();
        let wav = wav_pcm16(48_000, 2, &samples);
        let pcm = parse_wav_pcm(&wav).expect("valid stereo 16-bit WAV");
        assert_eq!(pcm.len(), 20);
        for s in pcm {
            assert!(s.abs() < 1e-6, "stereo pair should cancel, got {}", s);
        }
    }

    #[test]
    fn parses_float32() {
        let wav = wav_f32(48_000, 1, &[0.25, -0.5, 1.0]);
        let pcm = parse_wav_pcm(&wav).expect("valid float32 WAV");
        assert_eq!(pcm.len(), 3);
        assert!((pcm[0] - 0.25).abs() < 1e-6);
        assert!((pcm[1] + 0.5).abs() < 1e-6);
        assert!((pcm[2] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn resamples_44100_to_48000() {
        // 0.1s at 44.1 kHz = 4410 frames → exactly 4800 frames at 48 kHz.
        let samples = vec![0i16; 4410];
        let wav = wav_pcm16(44_100, 1, &samples);
        let pcm = parse_wav_pcm(&wav).expect("valid 44.1 kHz WAV");
        assert_eq!(pcm.len(), 4800);
    }

    #[test]
    fn rejects_non_pcm() {
        // ADPCM (format 2) is not supported.
        let mut wav = wav_pcm16(48_000, 1, &[0, 0]);
        wav[20..22].copy_from_slice(&2u16.to_le_bytes()); // format field
        let err = parse_wav_pcm(&wav).expect_err("ADPCM should be rejected");
        assert!(err.contains("unsupported"), "got: {}", err);
    }

    #[test]
    fn rejects_too_long() {
        // 48000 Hz * 2.1 s = 100_800 frames > 2 s limit.
        let samples = vec![0i16; 100_800];
        let wav = wav_pcm16(48_000, 1, &samples);
        let err = parse_wav_pcm(&wav).expect_err(">2s WAV should be rejected");
        assert!(err.contains("too long"), "got: {}", err);
    }

    #[test]
    fn rejects_garbage_and_empty() {
        assert!(parse_wav_pcm(b"NOTWAVE............").is_err());
        assert!(parse_wav_pcm(b"").is_err());
        // A WAVE with a fmt chunk but no data chunk.
        let mut wav = wav_pcm16(48_000, 1, &[0]);
        wav.truncate(44);
        let err = parse_wav_pcm(&wav).expect_err("no data chunk should be rejected");
        assert!(err.contains("no audio data"), "got: {}", err);
    }
}
