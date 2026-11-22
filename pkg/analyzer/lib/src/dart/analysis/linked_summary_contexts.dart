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

  /// Applies scope-local overlays and refreshes disk changes across all scopes.
  Future<({AnalysisContextCollectionImpl collection, String scopeKey})> prepare(
    SummaryRequest request,
  ) async {
    var scopeKey = request.scope.indexKey;
    var context = _contexts.putIfAbsent(
      scopeKey,
      () => _ProducerContext(request.scope, _sdk, _store),
    );
    var changedHere = context.updateOverlays(request.overlays)
      ..addAll(request.changedFiles);

    if (changedHere.isNotEmpty) {
      // Disk edits are visible to every scope. Overlays belong to this one.
      for (var cached in _contexts.values) {
        var changed = cached == context ? changedHere : request.changedFiles;

        if (changed.isNotEmpty) {
          await cached.changeFiles(changed);
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
  Set<String> _optionsFiles = {};

  /// Creates drivers from the current overlays when configuration changes.
  AnalysisContextCollectionImpl get collection =>
      _collection ??= _createCollection();

  Future<void> changeFiles(Iterable<String> changed) async {
    var collection = _collection;

    if (collection == null) {
      return;
    }

    // Both package resolution and analysis options are fixed at creation.
    if (changed.any(_affectsConfiguration)) {
      _collection = null;
      await collection.dispose();
      return;
    }

    for (var path in changed) {
      for (var context in collection.contexts) {
        context.driver.changeFile(path);
      }
    }
  }

  Set<String> updateOverlays(Map<String, String> overlays) {
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
        _optionsFiles.contains(file)) {
      return true;
    }

    // A newly created configuration can change which files the scope owns.
    var paths = _files.pathContext;
    String directory;

    if (file_paths.isAnalysisOptionsYaml(paths, file)) {
      directory = paths.dirname(file);
    } else if (file_paths.isPackageConfigJson(paths, file)) {
      directory = paths.dirname(paths.dirname(file));
    } else {
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
    _optionsFiles = {for (var file in options.attemptedFiles) file.path};

    return collection;
  }
}
