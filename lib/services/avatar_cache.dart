import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/client.dart';
import 'ft_service.dart';
import 'ts_ffi.dart';

/// Avatar hash (MD5) → local image file path for clients that have one.
///
/// Content-addressed by the server-pushed avatar hash, so entries survive
/// reconnects and even server changes, and a user re-uploading their avatar
/// invalidates itself (new hash). Files live in `{temp}/avatars/`.
final avatarCacheProvider = NotifierProvider<AvatarCache, Map<String, String>>(
  AvatarCache.new,
);

class AvatarCache extends Notifier<Map<String, String>> {
  /// Avatars are tiny (server default cap ~8 KiB); a generous-per-byte but
  /// short timeout keeps a stalled server from parking the queue.
  static const _downloadTimeout = Duration(seconds: 20);

  /// Hashes waiting for their sequential download turn (FIFO), with the uid
  /// needed to address the avatar file server-side.
  final _pending = <String, String>{};

  /// Hash whose download is currently running (dedup guard).
  final _inFlight = <String>{};

  /// Failed during the current connection — no retries this session, the
  /// row keeps its fallback icon. Cleared by [reset] on disconnect.
  final _failed = <String>{};

  bool _draining = false;
  Directory? _cacheDir;

  @override
  Map<String, String> build() => const {};

  /// Feeds the roster (called on every poll tick + on connect): enqueues
  /// downloads for clients whose avatar is neither cached nor in flight.
  /// Fully synchronous — the 200 ms poll can never double-enqueue a hash.
  void updateFromClients(List<TsClient> clients) {
    var added = false;
    for (final c in clients) {
      final hash = c.avatarHash;
      final uid = c.uid;
      // Query clients have neither avatars nor a meaningful uid.
      if (c.clientType != 0 || uid == null || uid.isEmpty) continue;
      if (hash == null || hash.isEmpty) continue;
      if (state.containsKey(hash) ||
          _pending.containsKey(hash) ||
          _inFlight.contains(hash) ||
          _failed.contains(hash)) {
        continue;
      }
      _pending[hash] = uid;
      added = true;
    }
    if (added) _drain();
  }

  /// Drops per-connection bookkeeping (queue, in-flight, failures). The
  /// hash→path map and the cache files stay — they are content-addressed.
  void reset() {
    _pending.clear();
    _inFlight.clear();
    _failed.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        // A dropped connection fails every transfer; leave the hashes queued
        // so the next poll tick's updateFromClients resumes draining after a
        // reconnect.
        if (!TsNative.isConnected()) break;
        final hash = _pending.keys.first;
        final uid = _pending.remove(hash)!;
        if (state.containsKey(hash)) continue;
        final cached = await _cachedPath(hash);
        if (cached != null) {
          state = {...state, hash: cached};
          continue;
        }
        _inFlight.add(hash);
        try {
          final path = await _download(hash, uid);
          state = {...state, hash: path};
        } catch (e) {
          debugPrint('AvatarCache: download failed for $hash: $e');
          _failed.add(hash);
        } finally {
          _inFlight.remove(hash);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<String> _download(String hash, String uid) async {
    final dir = await _ensureDir();
    // Download to a temp name: a failed/canceled transfer leaves a partial
    // file, and the final name is what future polls treat as a cache hit.
    final partPath = '${dir.path}/$hash.img.part';
    final finalPath = '${dir.path}/$hash.img';
    final taskId = TsNative.downloadAvatar(uid, partPath);
    if (taskId == 0) {
      throw Exception('avatar download could not start');
    }
    try {
      await FtTransferService.instance.trackHiddenTask(
        taskId,
        'avatar',
        timeout: _downloadTimeout,
      );
    } catch (_) {
      // Never leave a partial file behind as a poisoned cache entry.
      await _deleteQuietly(partPath);
      rethrow;
    }
    // Success — publish under the final content-addressed name.
    final part = File(partPath);
    try {
      await part.rename(finalPath);
    } catch (_) {
      // Rename across file systems would fail; copy as the fallback.
      await part.copy(finalPath);
      await _deleteQuietly(partPath);
    }
    final file = File(finalPath);
    if (!await file.exists()) {
      throw Exception('avatar file missing after transfer');
    }
    return finalPath;
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<String?> _cachedPath(String hash) async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/$hash.img');
    return await file.exists() ? file.path : null;
  }

  Future<Directory> _ensureDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/avatars');
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    _cacheDir = dir;
    return dir;
  }
}
