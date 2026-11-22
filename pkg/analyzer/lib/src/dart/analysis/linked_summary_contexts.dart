// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;

/// Owns the analysis contexts reused by a summary producer across requests.
final class SummaryProducerContexts(final String _sdk, final ByteStore _store) {
  final _contexts = <String, _ProducerContext>{};

  int get length => _contexts.length;

  /// Releases the drivers owned by all cached scopes.
  Future<void> dispose() async {
    for (var context in _contexts.values) {
      await context.discardCollection();
    }
    _contexts.clear();
  }

  /// Replaces the requesting scope's overlays with the complete snapshot in
  /// [request]. Each scope sees disk edits to files it hasn't overlaid.
  Future<({AnalysisContextCollectionImpl collection, String scopeKey})> prepare(
    SummaryRequest request,
  ) async {
    var scopeKey = request.scope.indexKey;
    var context = _contexts.putIfAbsent(
      scopeKey,
      () => _ProducerContext(request.scope, _sdk, _store),
    );
    var overlayChanges = context.replaceOverlays(request.overlays);
    var diskChanges = request.changedFiles;

    if (overlayChanges.isNotEmpty || diskChanges.isNotEmpty) {
      await context.applyChanges(diskChanges, overlayChanges: overlayChanges);
    }

    if (diskChanges.isNotEmpty) {
      for (var other in _contexts.values) {
        if (other != context) {
          await other.applyChanges(diskChanges);
        }
      }
    }

    return (collection: context.collection, scopeKey: scopeKey);
  }
}

/// Keeps the file overlays and the drivers that read them together for one scope.
final class _ProducerContext(
  final SummaryAnalysisScope scope,
  final String sdk,
  final ByteStore store,
) {
  // Contexts in this isolate share a byte store and may cover the same file.
  static int _modificationStamp = 0;

  final _files = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);

  AnalysisContextCollectionImpl? _collection;
  Set<String> _optionsDependencies = {};

  /// Builds drivers lazily from this scope's current view of the file system.
  AnalysisContextCollectionImpl get collection =>
      _collection ??= _createCollection();

  Future<void> applyChanges(
    List<String> diskChanges, {
    Set<String> overlayChanges = const {},
  }) async {
    var collection = _collection;

    if (collection == null) {
      return;
    }

    var changed = {
      ...overlayChanges,
      for (var path in diskChanges)
        if (!_files.hasOverlay(path)) path,
    };

    // Drivers can refresh source files, but the collection owns configuration.
    if (changed.any(_affectsConfiguration)) {
      await discardCollection();
      return;
    }

    for (var path in changed) {
      for (var context in collection.contexts) {
        context.driver.changeFile(path);
      }
    }
  }

  Future<void> discardCollection() async {
    var collection = _collection;
    _collection = null;
    await collection?.dispose();
  }

  /// Returns paths whose overlay was added, edited, or removed.
  Set<String> replaceOverlays(Map<String, String> overlays) {
    var changed = <String>{};
    var previous = _files.overlayContents;

    for (var path in previous.keys) {
      if (!overlays.containsKey(path)) {
        _files.removeOverlay(path);
        changed.add(path);
      }
    }

    for (var MapEntry(key: path, value: content) in overlays.entries) {
      if (previous[path] != content) {
        _files.setOverlay(
          path,
          content: content,
          modificationStamp: ++_modificationStamp,
        );
        changed.add(path);
      }
    }

    return changed;
  }

  bool _affectsConfiguration(String file) {
    if (file == scope.packages ||
        file == scope.options ||
        _optionsDependencies.contains(file)) {
      return true;
    }

    // A newly created configuration can change which files the scope owns.
    var paths = _files.pathContext;
    var directory = switch (paths.basename(file)) {
      file_paths.analysisOptionsYaml when scope.options == null =>
        paths.dirname(file),
      file_paths.pubspecYaml || file_paths.buildGn => paths.dirname(file),
      file_paths.packageConfigJson
          when file_paths.isPackageConfigJson(paths, file) =>
        paths.dirname(paths.dirname(file)),
      _ => null,
    };

    if (directory == null) {
      return false;
    }

    return paths.equals(directory, scope.root) ||
        paths.isWithin(directory, scope.root) ||
        paths.isWithin(scope.root, directory);
  }

  AnalysisContextCollectionImpl _createCollection() {
    var options = AnalysisOptionsParseSession();
    var collection = AnalysisContextCollectionImpl(
      analysisOptionsParseSession: options,
      includedPaths: [scope.root],
      resourceProvider: _files,
      sdkPath: sdk,
      byteStore: store,
      optionsFile: scope.options,
      packageConfigFile: scope.packages,
      declaredVariables: scope.variables,
      withFineDependencies: true,
    );
    _optionsDependencies = {for (var file in options.attemptedFiles) file.path};

    return collection;
  }
}
