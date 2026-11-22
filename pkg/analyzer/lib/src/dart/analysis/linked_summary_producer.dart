// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'linked_summary_coordinator.dart';

final class _ProducerStats {
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

/// Runs requests serially in a dedicated isolate. Each request applies its
/// editor overlays before linking and publishes dependency cycles as they finish.
final class _SummaryProducer(
  final SendPort _host,
  final String _sdk,
  final _ArenaDescriptor _descriptor,
  final Stopwatch _clock,
) {
  static const _notificationInterval = Duration(milliseconds: 80);

  final SummaryCycleWriter _writer = SummaryCycleWriter(_descriptor.directory);
  late final _contexts = SummaryProducerContexts(_sdk, _store);
  final _stats = _traceDirectory == null ? null : _ProducerStats();
  late final _diskStore = _openDiskStore();
  late final _store = PublishingSummaryStore(
    _diskStore ?? NullByteStore(),
    _writer,
  );
  int _nextNotificationMs = 0;

  FileByteStore? _openDiskStore() {
    var cache = PhysicalResourceProvider.INSTANCE.getStateLocation(
      '.analysis-driver',
    );

    if (cache == null) {
      return null;
    }

    return FileByteStore(
      cache.path,
      tempNameSuffix: path.basename(_descriptor.directory),
    );
  }

  Future<void> _produce(SummaryRequest request) async {
    var (:collection, :scopeKey) = await _contexts.prepare(request);
    _writer.selectScope(scopeKey);

    for (var path in request.paths) {
      var owner = collection.contextForOrNull(path);

      if (owner == null) {
        _host.send((request.reply, null));
        return;
      }
      owner.driver.produceSummary(path, _publishCycle);
    }

    _stats?.recordRequest(
      _writer,
      _contexts.length,
      hasOverlays: request.overlays.isNotEmpty,
    );
    _host.send((request.reply, _descriptor));
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
      await for (var request in inbox.cast<SummaryRequest?>()) {
        if (request == null) {
          break;
        }
        producer ??= _SummaryProducer(host, sdk, descriptor, clock);
        await producer._produce(request);
      }
      await producer?._diskStore?.flush();
    } catch (error, stack) {
      if (_traceDirectory != null) {
        _writeTrace('producer-error.txt', '$error\n$stack');
      }
    } finally {
      inbox.close();
      try {
        producer?._writer.close();
      } finally {
        // The exit notification lets the broker release all waiting readers.
        Isolate.exit();
      }
    }
  }
}
