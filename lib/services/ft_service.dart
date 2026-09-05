import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'ts_ffi.dart';

// ─── Models ──────────────────────────────────────────────────────────

/// One entry of a remote channel directory listing.
class FtEntry {
  final String name;
  final int size;
  final int datetime; // unix seconds, -1 when unknown
  final bool isFile;

  const FtEntry({
    required this.name,
    required this.size,
    required this.datetime,
    required this.isFile,
  });

  /// The special ".." entry the server reports for the parent directory.
  bool get isParent => name == '..';
}

/// Carries the raw server-side reason (or a local description) upwards so
/// UI can show "operation failed: <reason>" instead of a generic message.
class TransferException implements Exception {
  final String reason;
  final bool canceled;
  TransferException(this.reason, {this.canceled = false});
  @override
  String toString() => reason;
}

enum TransferKind { download, upload }

enum TransferState { active, done, error, canceled }

/// A tracked transfer row for the UI: either one single-file transfer or an
/// aggregated progress row covering a whole folder cascade.
class TransferJob {
  final int taskId;
  final TransferKind kind;
  String displayName;
  int total;
  int transferred;
  TransferState state;
  String? error;

  /// Whether the row shows up in the transfer list (folder cascade steps are
  /// tracked internally but hidden behind their aggregate row).
  bool visible;

  double get progress => total > 0 ? (transferred / total).clamp(0.0, 1.0) : 0;

  bool get isActive => state == TransferState.active;

  TransferJob({
    required this.taskId,
    required this.kind,
    required this.displayName,
    required this.total,
    this.transferred = 0,
    this.state = TransferState.active,
    this.error,
    this.visible = true,
  });
}

/// Bookkeeping behind one aggregated folder-transfer row.
class FolderProgress {
  final TransferKind kind;
  final String label;
  final int totalBytes;
  int transferredBytes = 0;
  int steps = 0;
  int doneSteps = 0;
  bool canceled = false;
  bool error = false;

  /// While true new transfer tasks attach themselves to this aggregate.
  bool collecting = true;
  late final int rowTaskId;

  final List<int> stepIds = [];
  final Map<int, int> stepSeen = {};

  FolderProgress({
    required this.kind,
    required this.label,
    required this.totalBytes,
  });

  bool get isRunning => !canceled && doneSteps < steps;

  TransferJob row() => TransferJob(
    taskId: rowTaskId,
    kind: kind,
    displayName: label,
    total: totalBytes,
    transferred: transferredBytes,
    state: canceled
        ? TransferState.canceled
        : (!collecting && doneSteps >= steps
              ? (error ? TransferState.error : TransferState.done)
              : TransferState.active),
    error: error ? 'folder' : null,
  );
}

// ─── Service ─────────────────────────────────────────────────────────

/// Coordinates channel file management operations between the UI screens and
/// the Rust layer. Directory listings are correlated by a token; transfers by
/// a numeric task id assigned in Rust. Folder uploads/downloads cascade the
/// single-file primitives and report one aggregated progress row each.
class FtTransferService extends ChangeNotifier {
  FtTransferService._();
  static final FtTransferService instance = FtTransferService._();

  /// Safety bounds so a pathological folder cannot stall the app forever.
  static const _maxFolderFiles = 500;
  static const _maxFolderDepth = 20;

  // Pending directory listings keyed by correlation token.
  final Map<String, Completer<List<FtEntry>>> _pendingLists = {};

  // Single-file transfer rows keyed by task id (incl. hidden cascade steps).
  final Map<int, TransferJob> _jobs = {};

  // Waiters resolved when Rust reports ft_done for a task.
  final Map<int, Completer<void>> _taskWaiters = {};

  // Aggregated folder rows in creation order.
  final List<FolderProgress> _aggregates = [];

  /// Staging area handed back while walking trees (internal bookkeeping).
  final Map<String, int> _walkFileSizes = {};

  // ─── Derived state for the UI ─────────────────────────────────────

  bool get hasActiveJobs =>
      _jobs.values.any((j) => j.isActive && j.visible) ||
      _aggregates.any((f) => f.isRunning);

  /// Rows for display: folder aggregates first, then plain transfers.
  List<TransferJob> get jobs {
    return [
      for (final f in _aggregates) f.row(),
      ..._jobs.values.where((j) => j.visible),
    ];
  }

  // ─── Event intake (called from the connection poll loop) ──────────

  void handleEvent(Map<String, dynamic> event) {
    switch (event['type'] as String) {
      case 'ft_listing':
        _onListing(event);
      case 'ft_started':
        _onStarted(event);
      case 'ft_progress':
        _onProgress(event);
      case 'ft_op':
        _onOp(event);
      case 'ft_done':
        _onDone(event);
      case 'disconnected':
        if (_jobs.isEmpty && _aggregates.isEmpty && _pendingLists.isEmpty) {
          break;
        }
        for (final waiter in _taskWaiters.values) {
          if (!waiter.isCompleted)
            waiter.completeError(Exception('disconnected'));
        }
        _jobs.clear();
        _aggregates.clear();
        _taskWaiters.clear();
        for (final c in _pendingLists.values) {
          if (!c.isCompleted) c.completeError(Exception('disconnected'));
        }
        _pendingLists.clear();
        for (final c in _pendingOps.values) {
          if (!c.isCompleted)
            c.completeError(TransferException('disconnected'));
        }
        notifyListeners();
    }
  }

  // ─── Directory listings ───────────────────────────────────────────

  /// Lists one remote directory. Throws on timeout / server rejection /
  /// disconnect so callers can show an error message.
  Future<List<FtEntry>> listDirectory(
    int channelId,
    String path, {
    String? password,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final token = const Uuid().v4();
    final completer = Completer<List<FtEntry>>();
    _pendingLists[token] = completer;
    final ok = TsNative.ftListToken(channelId, path, token, password: password);
    if (!ok) {
      _pendingLists.remove(token);
      throw Exception('list request failed');
    }
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pendingLists.remove(token);
    }
  }

  void _onListing(Map<String, dynamic> event) {
    final token = event['token'] as String?;
    final completer = token == null ? null : _pendingLists.remove(token);
    if (completer == null || completer.isCompleted) return;
    final error = event['error'] as String?;
    if (error != null) {
      completer.completeError(Exception(error));
      return;
    }
    final rawList = event['entries'];
    final entries = rawList is List
        ? rawList
              .whereType<Map>()
              .map(
                (m) => FtEntry(
                  name: m['name'] as String? ?? '',
                  size: (m['size'] as num?)?.toInt() ?? 0,
                  datetime: (m['datetime'] as num?)?.toInt() ?? -1,
                  isFile: m['is_file'] == true,
                ),
              )
              .toList()
        : <FtEntry>[];
    completer.complete(entries);
  }

  // ─── Single-entry operations ──────────────────────────────────────

  // Pending mkdir/delete acks keyed by correlation token.
  final Map<String, Completer<void>> _pendingOps = {};

  /// Creates a directory at [fullPath] (a complete remote path such as
  /// "/photos/2024" relative to the channel storage). Resolves only after
  /// the server's ack frame arrived — throws with the server's reason when
  /// it rejected the operation.
  Future<void> mkDir(int channelId, String fullPath, {String? password}) async {
    final token = const Uuid().v4();
    final completer = Completer<void>();
    _pendingOps[token] = completer;
    if (!TsNative.ftMkDir(channelId, fullPath, token, password: password)) {
      _pendingOps.remove(token);
      throw TransferException('mkdir request failed');
    }
    await _awaitOp(token, completer);
  }

  /// Deletes entries (files and/or directories — folders are removed
  /// recursively by the server). Paths must be COMPLETE remote addresses.
  /// Each path gets its own acknowledged command so multi-part return_code
  /// quirks never arise.
  Future<void> deletePaths(
    int channelId,
    List<String> fullPaths, {
    String? password,
  }) async {
    for (final path in fullPaths) {
      final token = const Uuid().v4();
      final completer = Completer<void>();
      _pendingOps[token] = completer;
      if (!TsNative.ftDelete(channelId, [path], token, password: password)) {
        _pendingOps.remove(token);
        throw TransferException('delete request failed');
      }
      await _awaitOp(token, completer);
    }
  }

  /// Deletes a directory tree: depth-first children first (files via
  /// [deletePaths], subdirectories recursively), then the directory itself.
  /// Whether the server removes non-empty folders on its own becomes
  /// irrelevant — by the time the folder is deleted it is empty.
  Future<void> deleteTree(
    int channelId,
    String dirPath, {
    String? password,
  }) async {
    // Never carry a trailing slash into child joins ("//" paths would go
    // to the server); the root itself is never a deletion target here.
    final base = dirPath.length > 1 && dirPath.endsWith('/')
        ? dirPath.substring(0, dirPath.length - 1)
        : dirPath;
    final children = await listDirectory(channelId, base, password: password);
    for (final entry in children) {
      if (entry.isParent || entry.name == '.' || entry.name == '..') continue;
      final childPath = '$base/${entry.name}';
      if (entry.isFile) {
        await deletePaths(channelId, [childPath], password: password);
      } else {
        await deleteTree(channelId, childPath, password: password);
      }
    }
    await deletePaths(channelId, [base], password: password);
  }

  Future<void> _awaitOp(
    String token,
    Completer<void> completer, [
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    try {
      await completer.future.timeout(timeout);
    } finally {
      _pendingOps.remove(token);
    }
  }

  void _onOp(Map<String, dynamic> event) {
    final token = event['token'] as String?;
    final completer = token == null ? null : _pendingOps.remove(token);
    if (completer == null || completer.isCompleted) return;
    if (event['ok'] == true) {
      completer.complete();
    } else {
      completer.completeError(
        TransferException(event['error'] as String? ?? 'unknown server error'),
      );
    }
  }

  /// Starts one visible download row and resolves [Future] when finished.
  Future<void> downloadFile(
    int channelId,
    String remotePath,
    String destLocalPath, {
    String? password,
  }) async {
    final taskId = TsNative.ftDownload(
      channelId,
      remotePath,
      destLocalPath,
      password: password,
    );
    if (taskId == 0) throw Exception('download could not start');
    _jobs.putIfAbsent(
      taskId,
      () => TransferJob(
        taskId: taskId,
        kind: TransferKind.download,
        displayName: _basename(remotePath),
        total: 0,
      ),
    );
    notifyListeners();
    await waitTask(taskId);
  }

  /// Starts one visible upload row and resolves [Future] when finished.
  Future<void> uploadFile(
    int channelId,
    String remotePath,
    String srcLocalPath, {
    String? password,
  }) async {
    final taskId = TsNative.ftUpload(
      channelId,
      remotePath,
      srcLocalPath,
      password: password,
    );
    if (taskId == 0) throw Exception('upload could not start');
    _jobs.putIfAbsent(
      taskId,
      () => TransferJob(
        taskId: taskId,
        kind: TransferKind.upload,
        displayName: _basename(remotePath),
        total: 0,
      ),
    );
    notifyListeners();
    await waitTask(taskId);
  }

  /// Resolves once Rust pushed ft_done for [taskId]. Throws a
  /// [TransferException] when the transfer failed or was canceled, so every
  /// caller's toast agrees with what the progress bar shows.
  Future<void> waitTask(
    int taskId, [
    Duration timeout = const Duration(minutes: 60),
  ]) async {
    final completer = Completer<void>();
    _taskWaiters[taskId] = completer;
    try {
      await completer.future.timeout(timeout);
      final job = _jobs[taskId];
      if (job != null && !job.isActive) {
        switch (job.state) {
          case TransferState.error:
            throw TransferException(job.error ?? 'transfer failed');
          case TransferState.canceled:
            throw TransferException('canceled', canceled: true);
          case TransferState.active:
          case TransferState.done:
            break;
        }
      }
    } on TimeoutException {
      TsNative.ftCancel(taskId);
      rethrow;
    } finally {
      _taskWaiters.remove(taskId);
    }
  }

  /// Tracks a transfer Rust already started (e.g. an avatar fetch via its own
  /// FFI) as a hidden row — never shown in the transfer bar, but wired into
  /// the ft_done lifecycle so disconnects resolve its waiter. Resolves on
  /// success; throws like [waitTask] otherwise.
  Future<void> trackHiddenTask(
    int taskId,
    String displayName, {
    Duration timeout = const Duration(minutes: 60),
  }) async {
    _jobs.putIfAbsent(
      taskId,
      () => TransferJob(
        taskId: taskId,
        kind: TransferKind.download,
        displayName: displayName,
        total: 0,
        visible: false,
      ),
    );
    try {
      await waitTask(taskId, timeout);
    } finally {
      _jobs.remove(taskId);
      notifyListeners();
    }
  }

  // ─── Job-row plumbing ─────────────────────────────────────────────

  void cancel(int taskId) {
    final job = _jobs[taskId];
    if (job != null && job.isActive) {
      TsNative.ftCancel(taskId);
    }
    for (final fp in _aggregates) {
      if (fp.rowTaskId == taskId) {
        fp.canceled = true;
        for (final stepId in fp.stepIds) {
          TsNative.ftCancel(stepId);
        }
      }
    }
    notifyListeners();
  }

  /// Drops finished rows from the transfer bar.
  void clearFinished() {
    _jobs.removeWhere((_, j) => j.visible && !j.isActive);
    _aggregates.removeWhere((f) => !f.isRunning);
    notifyListeners();
  }

  /// Keeps history bounded: trims inactive visible rows beyond 20.
  void _trimHistory() {
    final inactive = _jobs.values
        .where((j) => j.visible && !j.isActive)
        .toList();
    if (inactive.length <= 20) return;
    for (final j in inactive.take(inactive.length - 20)) {
      _jobs.remove(j.taskId);
    }
  }

  // ─── Event handlers ───────────────────────────────────────────────

  void _onStarted(Map<String, dynamic> event) {
    final id = event['task_id'] as int?;
    if (id == null) return;
    final total = (event['total'] as num?)?.toInt() ?? 0;
    final existing = _jobs[id];
    if (existing != null) {
      // Fill in what Rust now knows (esp. download totals).
      existing.total = total > 0 ? total : existing.total;
    }
    notifyListeners();
  }

  void _onProgress(Map<String, dynamic> event) {
    final id = event['task_id'] as int?;
    if (id == null) return;
    final transferred = (event['transferred'] as num?)?.toInt() ?? 0;
    final job = _jobs[id];
    if (job != null) {
      job.transferred = transferred;
    }
    for (final fp in _aggregates) {
      if (!fp.stepIds.contains(id)) continue;
      final prev = fp.stepSeen[id] ?? 0;
      if (transferred > prev) {
        fp.transferredBytes += transferred - prev;
        fp.stepSeen[id] = transferred;
      }
      break;
    }
    notifyListeners();
  }

  void _onDone(Map<String, dynamic> event) {
    final id = event['task_id'] as int?;
    if (id == null) return;
    final ok = event['ok'] == true;
    final transferred = (event['transferred'] as num?)?.toInt() ?? 0;
    final error = event['error'] as String?;

    final job = _jobs[id];
    if (job != null) {
      job.transferred = transferred;
      job.error = error;
      job.state = ok
          ? TransferState.done
          : (error == 'canceled'
                ? TransferState.canceled
                : TransferState.error);
    }
    final waiter = _taskWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete();

    for (final fp in _aggregates) {
      if (!fp.stepIds.contains(id)) continue;
      fp.doneSteps += 1;
      if (!ok && error != 'canceled') fp.error = true;
      break;
    }
    _trimHistory();
    notifyListeners();
  }

  // ─── Folder cascades ──────────────────────────────────────────────

  FolderProgress _newAggregate(
    TransferKind kind,
    String label,
    int totalBytes,
  ) {
    final fp = FolderProgress(kind: kind, label: label, totalBytes: totalBytes)
      ..rowTaskId = -(1 + _aggregates.length);
    _aggregates.add(fp);
    notifyListeners();
    return fp;
  }

  void _closeAggregate(FolderProgress fp) {
    fp.collecting = false;
    // All steps are resolved by now — drop their hidden job records.
    for (final stepId in fp.stepIds) {
      _jobs.remove(stepId);
    }
    notifyListeners();
  }

  /// Recursively uploads the content of [localDirPath] into [remoteDirPath]
  /// (both sides addressed like folders); resolves with the number of files
  /// uploaded successfully.
  Future<int> uploadFolder(
    int channelId,
    String localDirPath,
    String remoteDirPath, {
    String? password,
  }) async {
    final root = Directory(localDirPath);
    if (!await root.exists()) return 0;

    // Walk the local tree, bounded.
    final files = <String, String>{}; // absolute local path → relative posix
    var totalBytes = 0;
    final pendingDirs = <Directory>[root];
    var visitedDirs = 0;
    while (pendingDirs.isNotEmpty) {
      final dir = pendingDirs.removeAt(0);
      visitedDirs += 1;
      if (visitedDirs > _maxFolderFiles) break;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final rel = entity.path.startsWith('$localDirPath/')
              ? entity.path
                    .substring(localDirPath.length + 1)
                    .replaceAll('\\', '/')
              : entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (rel.split('/').length > _maxFolderDepth) continue;
          files[entity.path] = rel;
          totalBytes += await entity.length();
          if (files.length >= _maxFolderFiles) break;
        } else if (entity is Directory) {
          pendingDirs.add(entity);
        }
      }
      if (files.length >= _maxFolderFiles) break;
    }

    final baseName =
        localDirPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';
    final fp = _newAggregate(TransferKind.upload, baseName, totalBytes);

    var okCount = 0;
    try {
      if (TsNative.isConnected()) {
        // Sort parents-first so nested directories exist before their content.
        final ordered = files.values.toList()
          ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
        final seenLevels = <String>{};
        for (final rel in ordered) {
          final segs = rel.split('/')..removeLast();
          if (segs.isEmpty) continue;
          final prefix = segs.join('/');
          if (!seenLevels.add(prefix)) continue;
          await _mkdirLevels(
            channelId,
            remoteDirPath,
            segs,
            password: password,
          );
        }

        for (final entry in files.entries) {
          if (fp.canceled || !TsNative.isConnected()) break;
          final rel = entry.value;
          final remoteFile = '${_joinRemote(remoteDirPath, rel)}';
          final taskId = TsNative.ftUpload(
            channelId,
            remoteFile,
            entry.key,
            password: password,
          );
          if (taskId == 0) {
            fp.error = true;
            continue;
          }
          fp.stepIds.add(taskId);
          fp.steps += 1;
          _jobs[taskId] = TransferJob(
            taskId: taskId,
            kind: TransferKind.upload,
            displayName: _basename(remoteFile),
            total: 0,
            visible: false,
          );
          try {
            await waitTask(taskId);
            okCount += 1;
          } catch (_) {
            fp.error = true;
            TsNative.ftCancel(taskId);
          }
        }
      } else {
        fp.error = true;
      }
    } finally {
      _closeAggregate(fp);
    }
    return okCount;
  }

  /// Creates each level of [segments] under [root] sequentially; TS3 has no
  /// recursive mkdir and "already exists" failures are simply ignored (the
  /// following uploads verify the path really works).
  Future<void> _mkdirLevels(
    int channelId,
    String root,
    List<String> segments, {
    String? password,
  }) async {
    for (var depth = 1; depth <= segments.length; depth++) {
      final partial = _joinRemote(root, segments.take(depth).join('/'));
      try {
        await mkDir(channelId, partial, password: password);
      } catch (_) {}
    }
  }

  /// Recursively downloads [remoteDirPath] into [localDestDir]; resolves
  /// with the number of downloaded files.
  Future<int> downloadFolder(
    int channelId,
    String remoteDirPath,
    String localDestDir, {
    String? password,
  }) async {
    // Breadth-first discovery of the remote subtree.
    final foundPaths = <String>[]; // relative file paths under the root
    _walkFileSizes.clear();
    final dirsToScan = <String>[''];
    for (var i = 0; i < dirsToScan.length; i++) {
      if (foundPaths.length >= _maxFolderFiles || i >= _maxFolderFiles) {
        break;
      }
      final rel = dirsToScan[i];
      if (rel.split('/').length > _maxFolderDepth) continue;
      List<FtEntry> entries;
      try {
        entries = await listDirectory(
          channelId,
          _joinRemote(remoteDirPath, rel),
          password: password,
        );
      } catch (_) {
        continue; // unreadable subtree skipped
      }
      for (final e in entries) {
        if (e.isParent || e.name.isEmpty || e.name == '.') continue;
        final childRel = rel.isEmpty ? e.name : '$rel/${e.name}';
        if (childRel.split('/').length > _maxFolderDepth) continue;
        if (e.isFile) {
          foundPaths.add(childRel);
          _walkFileSizes[childRel] = e.size;
        } else {
          dirsToScan.add(childRel);
        }
      }
    }

    var totalBytes = 0;
    for (final size in _walkFileSizes.values) {
      totalBytes += size;
    }
    final baseName =
        remoteDirPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';
    final fp = _newAggregate(TransferKind.download, baseName, totalBytes);

    var okCount = 0;
    try {
      for (final rel in foundPaths) {
        if (fp.canceled || !TsNative.isConnected()) break;
        final fileName = rel.split('/').last;
        final subSegments = rel.split('/')..removeLast();
        final localTarget =
            '$localDestDir/${subSegments.isEmpty ? '' : '${subSegments.join('/')}/'}$fileName';
        try {
          await Directory(
            localTarget.substring(0, localTarget.length - fileName.length),
          ).create(recursive: true);
        } catch (_) {}

        final remote = _joinRemote(remoteDirPath, rel);
        final taskId = TsNative.ftDownload(
          channelId,
          remote,
          localTarget,
          password: password,
        );
        if (taskId == 0) {
          fp.error = true;
          continue;
        }
        fp.stepIds.add(taskId);
        fp.steps += 1;
        _jobs[taskId] = TransferJob(
          taskId: taskId,
          kind: TransferKind.download,
          displayName: fileName,
          total: _walkFileSizes[rel] ?? 0,
          visible: false,
        );
        try {
          await waitTask(taskId);
          okCount += 1;
        } catch (_) {
          fp.error = true;
          TsNative.ftCancel(taskId);
        }
      }
    } finally {
      _closeAggregate(fp);
      _walkFileSizes.clear();
    }
    return okCount;
  }

  static String _joinRemote(String root, String rel) {
    final r = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    return rel.isEmpty ? r : '$r/$rel';
  }

  static String _basename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? '/' : parts.last;
  }
}
