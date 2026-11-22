// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'linked_summary_coordinator.dart';

/// Owns one summary producer and relays its publications to analyzer clients.
///
/// Plugins send ordinary Dart lists to [sendPort] across isolate groups. The
/// broker and its producer share an isolate group and exchange typed messages.
final class LinkedSummaryBroker extends LinkedSummaryCoordinator {
  final RawReceivePort _readers;
  final _producerPort = Completer<SendPort?>();
  late final Future<void> _producerLifetime;

  /// Maps each pending reply port to whether its reader requested progress.
  final _pendingReaders = <SendPort, bool>{};

  List<Object>? _latestProgress;
  bool _acceptingRequests = true;
  late final _shutdown = _stop();

  factory(String sdk) =>
      LinkedSummaryBroker._(RawReceivePort()..keepIsolateAlive = false, sdk);

  new _(this._readers, String sdk) : super._(_readers.sendPort, 'server') {
    _readers.handler = _onReaderMessage;
    _producerLifetime = _runProducer(sdk);
  }

  /// The port passed to plugins during startup.
  SendPort get sendPort => _readers.sendPort;

  /// Starts shutdown. Await [shutdown] to wait for cleanup.
  @override
  void close() => unawaited(shutdown());

  /// Stops accepting new requests and waits for the producer to exit.
  ///
  /// Repeated calls share a future that completes after cleanup. Mapped bytes
  /// held by readers remain valid after shutdown.
  Future<void> shutdown() => _shutdown;

  /// Keeps the last notification so readers joining mid-request can catch up.
  void _broadcastProgress(_ArenaDescriptor descriptor) {
    var progress = [_progressMessage, descriptor.toMessage()];
    _latestProgress = progress;

    for (var MapEntry(key: reader, value: wantsProgress)
        in _pendingReaders.entries) {
      if (wantsProgress) {
        reader.send(progress);
      }
    }
  }

  /// Releases waiting readers when the producer exits or fails to start.
  void _disconnectReaders() {
    _acceptingRequests = false;

    if (!_producerPort.isCompleted) {
      _producerPort.complete();
    }

    for (var reader in _pendingReaders.keys) {
      reader.send(null);
    }
    _pendingReaders.clear();
  }

  Future<void> _forward(SummaryRequest request) async {
    var reader = request.reply;

    if (!_acceptingRequests) {
      reader.send(null);
      return;
    }

    // Register before waiting for startup so an unsubscribe can cancel a
    // queued request and a failed spawn can wake all waiting readers.
    _pendingReaders[reader] = request.wantsProgress;
    var producer = await _producerPort.future;

    if (!_acceptingRequests ||
        producer == null ||
        !_pendingReaders.containsKey(reader)) {
      return;
    }

    var progress = _latestProgress;

    if (request.wantsProgress && progress != null) {
      reader.send(progress);
    }

    producer.send(request);
  }

  Future<void> _invalidateRoot(String root) async {
    var producer = await _producerPort.future;

    if (_acceptingRequests) {
      producer?.send((invalidatedRoot: root));
    }
  }

  void _onProducerEvent(Object? event) {
    switch (event) {
      case SendPort producer:
        _producerPort.complete(producer);
      case _ArenaDescriptor descriptor:
        _broadcastProgress(descriptor);
      case (:SendPort reader, :_ArenaDescriptor? arena):
        if (_pendingReaders.remove(reader) != null) {
          reader.send(arena?.toMessage());
        }
    }
  }

  void _onReaderMessage(Object? message) {
    switch (message) {
      case [_invalidateRootMessage, String root]:
        unawaited(_invalidateRoot(root));
      case [SendPort reader]:
        _pendingReaders.remove(reader);
      case [..., SendPort reader]:
        var request = SummaryRequest.tryDecode(message);

        if (request == null) {
          reader.send(null);
          return;
        }

        unawaited(_forward(request));
    }
  }

  /// Owns the temporary directory until the producer exits.
  Future<void> _runProducer(String sdk) async {
    var events = ReceivePort.fromRawReceivePort(
      RawReceivePort()..keepIsolateAlive = false,
    );
    Directory? directory;
    try {
      directory = await Directory.systemTemp.createTemp('dart-summary-');

      if (!_acceptingRequests) {
        return;
      }

      await Isolate.spawn(
        _SummaryProducer.start,
        (host: events.sendPort, sdk: sdk, directory: directory.path),
        onExit: events.sendPort,
        debugName: 'analyzer summary producer',
      );

      // The VM sends null on this port after the producer's last message.
      await for (var event in events) {
        if (event == null) {
          break;
        }

        _onProducerEvent(event);
      }
    } catch (error, stack) {
      if (_traceDirectory != null) {
        _writeTrace('broker-error.txt', '$error\n$stack');
      }
    } finally {
      events.close();
      _disconnectReaders();
      try {
        await directory?.delete(recursive: true);
      } on FileSystemException {
        // The host may already have removed its temporary directory.
      }
    }
  }

  Future<void> _stop() async {
    _acceptingRequests = false;
    // An awaiting CLI may have no other live ports during cleanup.
    _readers.keepIsolateAlive = true;
    try {
      var producer = await _producerPort.future;
      producer?.send(null);
      await _producerLifetime;
    } finally {
      _readers.close();
      super.close();
    }
  }
}

extension on _ArenaDescriptor {
  List<Object> toMessage() => [directory, length, epoch];
}
