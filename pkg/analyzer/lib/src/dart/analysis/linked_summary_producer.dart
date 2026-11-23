// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'linked_summary_coordinator.dart';

enum _ProducerEvent { failed }

/// Runs requests serially in a dedicated isolate. Each request applies its
/// editor overlays before linking and publishes dependency cycles as they finish.
final class _SummaryProducer(
  final SendPort _host,
  final String _sdk,
  final _ArenaDescriptor _descriptor,
  final Stopwatch _clock,
  final FileByteStore? _diskStore,
) {
  static const _notificationInterval = Duration(milliseconds: 80);

  final SummaryCycleWriter _writer = SummaryCycleWriter(_descriptor.directory);
  late final _contexts = SummaryProducerContexts(
    _sdk,
    PublishingSummaryStore(_diskStore ?? NullByteStore(), _writer),
  );
  final _stats = _traceDirectory == null ? null : _SummaryProducerStats();
  int _nextNotificationMs = 0;

  Future<void> _close() async {
    try {
      await _diskStore?.flush();
    } finally {
      _writer.close();
    }
  }

  /// Returns the published arena, or null if the reader must handle the request
  /// locally. Validate the entire request before it can change cached contexts.
  Future<_ArenaDescriptor?> _produce(SummaryRequest request) async {
    if (!_hasValidPaths(request)) {
      return null;
    }

    var (:collection, :scopeKey) = await _contexts.prepare(request);
    _writer.selectScope(scopeKey);

    for (var path in request.paths) {
      var owner = collection.contextForOrNull(path);

      if (owner == null) {
        return null;
      }

      owner.driver.produceSummary(path, _publishCycle);
    }

    _stats?.recordRequest(
      _writer,
      _contexts.length,
      hasOverlays: request.overlays.isNotEmpty,
    );

    return _descriptor;
  }

  /// Publishes [cycle] immediately. A single progress notification can cover
  /// several cycles so that small cycles do not flood the editor's event queue.
  void _publishCycle(LibraryCycle cycle) {
    _writer.publish([for (var library in cycle.libraries) library.file.path]);
    var now = _clock.elapsedMilliseconds;

    _stats?.recordCycle(_writer, now);

    if (now >= _nextNotificationMs) {
      _nextNotificationMs = now + _notificationInterval.inMilliseconds;
      _host.send(_descriptor);
    }
  }

  static Future<void> start(
    ({SendPort host, String sdk, String directory}) init,
  ) async {
    var (:host, :sdk, :directory) = init;
    var clock = Stopwatch()..start();
    var descriptor = (
      directory: directory,
      length: SummaryCycleWriter.capacity,
      epoch: DateTime.now().microsecondsSinceEpoch,
    );
    var inbox = ReceivePort();
    host.send(inbox.sendPort);

    // A broker can start and stop without ever requesting an arena.
    _SummaryProducer? producer;
    try {
      await for (var message in inbox) {
        if (message == null) {
          break;
        }

        switch (message) {
          case (:String invalidatedRoot):
            await producer?._contexts.invalidateRoot(invalidatedRoot);
          case SummaryRequest request:
            producer ??= _SummaryProducer(
              host,
              sdk,
              descriptor,
              clock,
              _openDiskStore(directory),
            );
            var arena = await producer._produce(request);
            host.send((reader: request.reply, arena: arena));
        }
      }
    } catch (error, stack) {
      host.send(_ProducerEvent.failed);

      if (_traceDirectory != null) {
        _writeTrace('producer-error.txt', '$error\n$stack');
      }
    } finally {
      inbox.close();
      try {
        await producer?._close();
      } finally {
        // Analysis drivers can still own live ports after cleanup.
        Isolate.exit();
      }
    }
  }

  static bool _hasValidPaths(SummaryRequest request) {
    bool valid(String? value) =>
        value == null ||
        (path.isAbsolute(value) &&
            path.normalize(value) == value &&
            !value.contains('\x00'));

    var scope = request.scope;

    return valid(scope.root) &&
        valid(scope.options) &&
        valid(scope.packages) &&
        request.paths.every(valid) &&
        request.changedFiles.every(valid) &&
        request.overlays.keys.every(valid);
  }

  static FileByteStore? _openDiskStore(String directory) {
    var cache = PhysicalResourceProvider.INSTANCE.getStateLocation(
      '.analysis-driver',
    );

    if (cache == null) {
      return null;
    }

    return FileByteStore(cache.path, tempNameSuffix: path.basename(directory));
  }
}

final class _SummaryProducerStats {
  static const _initialRequestsToTrace = 3;
  static const _traceInterval = 32;

  int _requests = 0;
  int _editorRequests = 0;
  ({int milliseconds, int bytes})? _firstCycle;

  void recordCycle(SummaryCycleWriter writer, int elapsedMs) {
    _firstCycle ??= (milliseconds: elapsedMs, bytes: writer.bytesWritten);
  }

  void recordRequest(
    SummaryCycleWriter writer,
    int contexts, {
    required bool hasOverlays,
  }) {
    _requests++;

    if (hasOverlays) {
      _editorRequests++;
    }

    if (_requests <= _initialRequestsToTrace ||
        _requests % _traceInterval == 0) {
      _writeTrace(
        'producer-progress.json',
        jsonEncode({
          'requests': _requests,
          'editorRequests': _editorRequests,
          'firstCycleBytes': _firstCycle?.bytes ?? 0,
          'firstCycleMs': _firstCycle?.milliseconds ?? -1,
          'bytes': writer.bytesWritten,
          'linked': writer.cycles,
          'unlinked': writer.units,
          'contexts': contexts,
        }),
      );
    }
  }
}
