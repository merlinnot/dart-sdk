// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/analysis_options/analysis_options.dart';
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/context_builder.dart';
import 'package:analyzer/src/dart/analysis/context_locator.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_content_cache.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/performance_logger.dart';
import 'package:analyzer/src/dart/analysis/unlinked_unit_store.dart';
import 'package:analyzer/src/util/sdk.dart';
import 'package:pub_semver/pub_semver.dart';

/// An implementation of [AnalysisContextCollection].
class AnalysisContextCollectionImpl implements AnalysisContextCollection {
  /// The resource provider used to access the file system.
  final ResourceProvider resourceProvider;

  /// The shared container into which drivers record files ownership.
  final OwnedFiles ownedFiles = OwnedFiles();

  /// The scheduler used for all analysis contexts.
  late final AnalysisDriverScheduler scheduler;

  /// The list of analysis contexts.
  @override
  final List<DriverBasedAnalysisContext> contexts = [];

  /// Initialize a newly created analysis context manager.
  ///
  /// Supply a fresh [analysisOptionsParseSession] to track the files that root
  /// discovery and driver creation attempt to read when parsing options.
  /// [onConfigurationDependency] also reports paths consulted when choosing
  /// the SDK or workspace, including configuration that does not yet exist.
  ///
  /// A newly created scheduler uses [linkedSummaryCoordinator]. A supplied
  /// [scheduler] already owns its coordinator.
  new({
    AnalysisOptionsParseSession? analysisOptionsParseSession,
    void Function(String path)? onConfigurationDependency,
    ByteStore? byteStore,
    Map<String, String>? declaredVariables,
    bool drainStreams = true,
    bool enableIndex = false,
    required List<String> includedPaths,
    List<String> excludedPaths = const [],
    Version? languageVersionOverride,
    List<String>? librarySummaryPaths,
    String? optionsFile,
    String? packageConfigFile,
    bool withFineDependencies = false,
    PerformanceLog? performanceLog,
    ResourceProvider? resourceProvider,
    bool retainDataForTesting = false,
    String? sdkPath,
    String? sdkSummaryPath,
    AnalysisDriverScheduler? scheduler,
    LinkedSummaryCoordinator? linkedSummaryCoordinator,
    FileContentCache? fileContentCache,
    UnlinkedUnitStore? unlinkedUnitStore,
    List<String> enabledExperiments = const [],
    void Function({required AnalysisOptionsBuilder analysisOptionsBuilder})?
    configureAnalysisOptionsBuilder,
    bool enableLintRuleTiming = false,
  }) : resourceProvider =
           resourceProvider ?? PhysicalResourceProvider.INSTANCE {
    sdkPath ??= getSdkPath();

    performanceLog ??= PerformanceLog(null);

    if (scheduler == null) {
      scheduler = AnalysisDriverScheduler(
        performanceLog,
        linkedSummaryCoordinator: linkedSummaryCoordinator,
      );
      if (drainStreams) {
        unawaited(scheduler.events.drain<void>());
      }
      scheduler.start();
    }
    this.scheduler = scheduler;

    _throwIfAnyNotAbsoluteNormalizedPath(includedPaths);
    _throwIfAnyNotAbsoluteNormalizedPath(excludedPaths);
    _throwIfNotAbsoluteNormalizedPath(sdkPath);

    var roots = locateContextRoots(
      onConfigurationDependency: onConfigurationDependency,
      analysisOptionsParseSession: analysisOptionsParseSession,
      includedPaths: includedPaths,
      excludedPaths: excludedPaths,
      resourceProvider: this.resourceProvider,
      optionsFile: optionsFile,
      packageConfigFile: packageConfigFile,
    );

    byteStore ??= MemoryByteStore();

    var contextBuilder = ContextBuilderImpl(
      onConfigurationDependency: onConfigurationDependency,
      resourceProvider: this.resourceProvider,
    );

    for (var root in roots) {
      var context = contextBuilder.createContext(
        analysisOptionsParseSession: analysisOptionsParseSession,
        byteStore: byteStore,
        contextRoot: root,
        optionsFileOverride: optionsFile,
        packageConfigOverride: packageConfigFile,
        declaredVariables: DeclaredVariables.fromMap(declaredVariables ?? {}),
        drainStreams: drainStreams,
        enableIndex: enableIndex,
        languageVersionOverride: languageVersionOverride,
        librarySummaryPaths: librarySummaryPaths,
        performanceLog: performanceLog,
        retainDataForTesting: retainDataForTesting,
        sdkPath: sdkPath,
        sdkSummaryPath: sdkSummaryPath,
        scheduler: scheduler,
        configureAnalysisOptionsBuilder: configureAnalysisOptionsBuilder,
        fileContentCache: fileContentCache,
        unlinkedUnitStore: unlinkedUnitStore ?? UnlinkedUnitStoreImpl(),
        ownedFiles: ownedFiles,
        enableLintRuleTiming: enableLintRuleTiming,
        withFineDependencies: withFineDependencies,
        enabledExperiments: enabledExperiments,
      );
      contexts.add(context);
    }
  }

  @override
  DriverBasedAnalysisContext contextFor(String path) =>
      contextForOrNull(path) ??
      (throw StateError('Unable to find the context to $path'));

  /// Returns the owning context, or null when no context analyzes [path].
  DriverBasedAnalysisContext? contextForOrNull(String path) {
    _throwIfNotAbsoluteNormalizedPath(path);

    for (var context in contexts) {
      if (context.contextRoot.isAnalyzed(path)) {
        return context;
      }
    }

    return null;
  }

  @override
  Future<void> dispose({bool forTesting = false}) async {
    for (var analysisContext in contexts) {
      await analysisContext.driver.dispose2();
    }
  }

  /// Check every element with [_throwIfNotAbsoluteNormalizedPath].
  void _throwIfAnyNotAbsoluteNormalizedPath(List<String> paths) {
    for (var path in paths) {
      _throwIfNotAbsoluteNormalizedPath(path);
    }
  }

  /// The driver supports only absolute normalized paths, this method is used
  /// to validate any input paths to prevent errors later.
  void _throwIfNotAbsoluteNormalizedPath(String path) {
    var pathContext = resourceProvider.pathContext;
    if (!pathContext.isAbsolute(path) || pathContext.normalize(path) != path) {
      throw ArgumentError(
        'Only absolute normalized paths are supported: $path',
      );
    }
  }
}
