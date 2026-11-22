// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// @docImport 'package:analyzer/src/generated/engine.dart';
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/binary/binary_reader.dart';
import 'package:analyzer/src/binary/binary_writer.dart';
import 'package:analyzer/src/context/context.dart';
import 'package:analyzer/src/dart/analysis/analysis_options_map.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_event.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/library_graph.dart';
import 'package:analyzer/src/dart/analysis/performance_logger.dart';
import 'package:analyzer/src/dart/analysis/session.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/exception/exception.dart';
import 'package:analyzer/src/fine/library_manifest.dart';
import 'package:analyzer/src/fine/manifest_id.dart';
import 'package:analyzer/src/fine/requirements.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:analyzer/src/summary2/bundle_reader.dart';
import 'package:analyzer/src/summary2/link.dart';
import 'package:analyzer/src/summary2/linked_element_factory.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:analyzer/src/utilities/extensions/collection.dart';
import 'package:collection/collection.dart';

/// Context information necessary to analyze one or more libraries within an
/// [AnalysisDriver].
///
/// Currently this is implemented as a wrapper around [AnalysisContext].
class LibraryContext {
  final LibraryContextTestData? testData;
  final PerformanceLog logger;
  final ByteStore byteStore;
  final StreamController<Object>? eventsController;
  final FileSystemState fileSystemState;
  final File? packagesFile;
  final bool withFineDependencies;

  late final AnalysisContextImpl analysisContext;
  late final LinkedElementFactory elementFactory;

  Set<LibraryCycle> loadedBundles = Set.identity();

  new({
    required this.testData,
    required AnalysisSessionImpl analysisSession,
    required this.logger,
    required this.byteStore,
    required this.eventsController,
    required this.fileSystemState,
    required AnalysisOptionsMap analysisOptionsMap,
    required DeclaredVariables declaredVariables,
    required SourceFactory sourceFactory,
    required this.packagesFile,
    required this.withFineDependencies,
    required SummaryDataStore? externalSummaries,
  }) {
    testData?.instance = this;

    analysisContext = AnalysisContextImpl(
      analysisOptionsMap: analysisOptionsMap,
      declaredVariables: declaredVariables,
      sourceFactory: sourceFactory,
    );

    elementFactory = LinkedElementFactory(
      analysisContext,
      analysisSession,
      RootReference(),
    );
    if (externalSummaries != null) {
      for (var bundle in externalSummaries.bundles) {
        elementFactory.addBundle(
          BundleReader(
            elementFactory: elementFactory,
            resolutionBytes: bundle.resolutionBytes,
            unitsInformativeBytes: {},
            libraryManifests: {},
          ),
        );
      }
    }
  }

  /// Computes a [LibraryFragmentImpl] for the given library/unit pair.
  LibraryFragmentImpl computeUnitElement(
    LibraryFileKind library,
    FileState unit,
  ) {
    var libraryElement = elementFactory.libraryOfUri2(library.file.uri);
    return libraryElement.fragments.singleWhere(
      (fragment) => fragment.source.uri == unit.uri,
    );
  }

  /// Notifies this object that it is about to be discarded.
  ///
  /// Returns the keys of the artifacts that are no longer used.
  Set<String> dispose() {
    var keys = unloadAll();
    elementFactory.dispose();
    testData?.instance = null;
    return keys;
  }

  /// Get the [LibraryElementImpl] for the given library.
  LibraryElementImpl getLibraryElement(Uri uri) {
    _createElementFactoryTypeProvider();
    return elementFactory.libraryOfUri2(uri);
  }

  /// Load data required to access elements of the given [targetLibrary].
  ///
  /// Returns [LibraryLoadResult.loaded] when the target and its dependencies
  /// are loaded. By default, missing or stale bundles are linked. If
  /// [allowLink] is false, stops at the first cycle that needs linking and
  /// returns [LibraryLoadResult.cacheMiss]. Previously loaded cycles remain
  /// available for a later attempt. [onCycle] is called after each newly
  /// loaded cycle, in dependency order.
  LibraryLoadResult load({
    required LibraryFileKind targetLibrary,
    required OperationPerformanceImpl performance,
    bool allowLink = true,
    void Function(LibraryCycle)? onCycle,
  }) {
    return fileSystemState.withParsedUnitsForLinking(() {
      LibraryLoadResult loadCycle(LibraryCycle cycle) =>
          _loadCycleWithDependencies(
            cycle: cycle,
            allowLink: allowLink,
            onCycle: onCycle,
            performance: performance,
          );

      var libraryCycle = performance.run('libraryCycle', (performance) {
        fileSystemState.newFileOperationPerformance = performance;
        try {
          // Link completed components while discovering the graph. Their
          // parsed units can then be reclaimed before exploring the next branch.
          return targetLibrary.computeLibraryCycle(
            onComputed: onCycle != null && allowLink ? loadCycle : null,
          );
        } finally {
          fileSystemState.newFileOperationPerformance = null;
        }
      });

      var result = loadCycle(libraryCycle);

      if (result == .loaded) {
        // External summaries can already contain the target. Even when no
        // bundles needed loading, the element factory needs its type provider.
        _createElementFactoryTypeProvider();
      }

      return result;
    });
  }

  /// Load data required to resolve the given [targetLibrary].
  ///
  /// Returns [LibraryLoadResult.loaded] once both the target and its
  /// `@docImport` libraries are loaded. With [allowLink] set to false,
  /// returns [LibraryLoadResult.cacheMiss] as soon as any of them or their
  /// dependencies need linking. By default, [load] links missing bundles.
  /// [onCycle] receives newly loaded cycles for the target and its doc imports.
  LibraryLoadResult loadForResolution({
    required LibraryFileKind targetLibrary,
    required OperationPerformanceImpl performance,
    bool allowLink = true,
    void Function(LibraryCycle)? onCycle,
  }) {
    var targetResult = load(
      targetLibrary: targetLibrary,
      performance: performance,
      allowLink: allowLink,
      onCycle: onCycle,
    );

    if (targetResult == .cacheMiss) {
      return targetResult;
    }

    return performance.run('docImportedLibraries', (performance) {
      for (var library in targetLibrary.docImportedLibraries) {
        var result = load(
          targetLibrary: library,
          performance: performance,
          allowLink: allowLink,
          onCycle: onCycle,
        );

        if (result == .cacheMiss) {
          return result;
        }
      }

      return .loaded;
    });
  }

  /// Remove libraries represented by the [removed] files.
  /// If we need these libraries later, we will relink and reattach them.
  void remove(Set<FileState> removed, Set<String> removedKeys) {
    if (removed.isEmpty) return;

    elementFactory.removeLibraries(removed.map((e) => e.uri).toSet());

    var removedCycles = removed
        .map((file) => file.kind.library?.internal_libraryCycle)
        .nonNulls
        .where(loadedBundles.contains)
        .toSet();
    loadedBundles.removeAll(removedCycles);
    removedKeys.addAll(removedCycles.map((cycle) => cycle.linkedKey));
  }

  /// Unloads all loaded bundles.
  ///
  /// Returns the keys of the artifacts that are no longer used.
  Set<String> unloadAll() {
    var keySet = <String>{};
    var uriSet = <Uri>{};

    for (var cycle in loadedBundles) {
      keySet.add(cycle.linkedKey);
      uriSet.addAll(cycle.libraries.map((e) => e.file.uri));
    }

    elementFactory.removeLibraries(uriSet);
    loadedBundles.clear();

    return keySet;
  }

  /// Attaches [resolutionBytes] for lazy loading and releases parsed units
  /// retained for linking [cycle].
  void _attachBundle({
    required LibraryCycle cycle,
    required Uint8List resolutionBytes,
    required Map<Uri, LibraryManifestHandle> manifests,
    required OperationPerformanceImpl performance,
  }) {
    var unitsInformativeBytes = <Uri, Uint8List>{};
    for (var library in cycle.libraries) {
      for (var file in library.files) {
        file.takeParsedUnitForLinking();
        unitsInformativeBytes[file.uri] = file.unlinked2.informativeBytes;
      }
    }

    var bundleReader = performance.run('bundleReader', (performance) {
      return BundleReader(
        elementFactory: elementFactory,
        unitsInformativeBytes: unitsInformativeBytes,
        resolutionBytes: resolutionBytes,
        libraryManifests: manifests,
      );
    });
    elementFactory.addBundle(bundleReader);
    elementFactory.libraryManifests.addAll(manifests);
  }

  /// Returns not yet loaded cycles starting from [root] in post-order, so
  /// each cycle comes after all cycles it directly depends on.
  List<LibraryCycle> _collectCyclesToLoad(LibraryCycle root) {
    var cyclesToLoad = <LibraryCycle>[];
    var scheduled = <LibraryCycle>{};
    var stack = <(LibraryCycle, Iterator<LibraryCycle>)>[];

    void push(LibraryCycle cycle) {
      if (scheduled.add(cycle)) {
        stack.add((cycle, cycle.directDependencies.iterator));
      }
    }

    push(root);

    while (stack.isNotEmpty) {
      var (cycle, dependencyIterator) = stack.last;

      if (loadedBundles.contains(cycle)) {
        stack.removeLast();
        continue;
      }

      if (dependencyIterator.moveNext()) {
        push(dependencyIterator.current);
      } else {
        stack.removeLast();
        cyclesToLoad.add(cycle);
      }
    }

    // The same cycle must be loaded only once.
    // We only return cycles that are not loaded.
    assert(() {
      var uniqueCycles = cyclesToLoad.toSet();
      return uniqueCycles.length == cyclesToLoad.length &&
          uniqueCycles.intersection(loadedBundles).isEmpty;
    }());

    return cyclesToLoad;
  }

  /// Ensure that type provider is created.
  void _createElementFactoryTypeProvider() {
    if (!analysisContext.hasTypeProvider) {
      elementFactory.createTypeProviders(
        elementFactory.dartCoreElement,
        elementFactory.dartAsyncElement,
      );
    }
  }

  /// Links [cycle] and writes its reusable bundle. With fine dependencies,
  /// also returns the requirements recorded while linking.
  (_LinkedBundleCacheEntry, RequirementsManifest?) _linkAndCacheBundle({
    required LibraryCycle cycle,
    required Map<Uri, LibraryManifestHandle> previousManifests,
    required OperationPerformanceImpl performance,
  }) {
    Uint8List linkLibraries() => performance.run(
      'link',
      (performance) => link(
        elementFactory: elementFactory,
        apiSignature: cycle.nonTransitiveApiSignature,
        performance: performance,
        inputLibraries: cycle.libraries,
      ).resolutionBytes,
    );

    var requirements = RequirementsManifest();
    Map<Uri, LibraryManifestHandle> manifests = const {};
    Uint8List resolutionBytes;

    if (withFineDependencies) {
      globalResultRequirements = requirements;
      try {
        resolutionBytes = linkLibraries();
        manifests = performance.run('computeManifests', (performance) {
          var inputManifests = performance.run('inputManifests', (_) {
            return previousManifests.mapValue((handle) => handle.instance);
          });

          return LibraryManifestBuilder(
            elementFactory: elementFactory,
            inputLibraries: cycle.libraries,
            inputManifests: inputManifests,
          ).computeManifests(performance: performance);
        });
        elementFactory.libraryManifests.addAll(manifests);
        requirements.addExports(
          elementFactory: elementFactory,
          libraryUriSet: cycle.libraryUris,
        );
      } finally {
        try {
          requirements.stopRecording();
        } finally {
          globalResultRequirements = null;
        }
      }

      requirements.removeReqForLibs(cycle.libraryUris);
      assert(requirements.assertSerialization());
    } else {
      resolutionBytes = linkLibraries();
    }

    var entry = _LinkedBundleCacheEntry(
      nonTransitiveApiSignature: cycle.nonTransitiveApiSignature,
      id: ManifestItemId.generate(),
      requirementsBytes: requirements.toBytes(),
      libraryManifests: manifests,
      linkedBytes: resolutionBytes,
    );
    performance.run('writeCacheEntry', (performance) {
      entry.write(
        byteStore: byteStore,
        key: cycle.linkedKey,
        performance: performance,
      );

      if (withFineDependencies) {
        _LinkedBundleCacheEntry.writeDigest(
          byteStore: byteStore,
          elementFactory: elementFactory,
          bundleKey: cycle.linkedKey,
          bundleId: entry.id,
          requirements: requirements,
        );
      } else {
        testData?.forCycle(cycle).putKeys.add(cycle.linkedKey);
      }
    });

    return (entry, withFineDependencies ? requirements : null);
  }

  /// Load the linked bundle for [cycle], or link it if not available.
  ///
  /// The cycle must be new to this context and its direct dependencies loaded.
  LibraryLoadResult _loadBundle({
    required LibraryCycle cycle,
    required bool allowLink,
    required void Function(LibraryCycle)? onCycle,
    required OperationPerformanceImpl performance,
  }) {
    assert(!loadedBundles.contains(cycle));
    addToLogRing('[load][cycle: $cycle]');

    performance.getDataInt('cycleCount').increment();
    performance.getDataInt('libraryCount').add(cycle.libraries.length);

    var probe = _probeLinkedBundle(cycle: cycle, performance: performance);
    var linkedBytes = probe.linkedBytes;

    if (linkedBytes == null) {
      if (!allowLink) {
        return .cacheMiss;
      }

      testData?.linkedCycles.add(
        cycle.libraries.map((e) => e.file.path).toSet(),
      );

      try {
        var (entry, requirements) = _linkAndCacheBundle(
          cycle: cycle,
          previousManifests: probe.libraryManifests,
          performance: performance,
        );

        // The producer can release the freshly linked elements. Subsequent
        // cycles read what they need from the serialized bundle.
        if (onCycle != null) {
          elementFactory.removeBundle(cycle.libraryUris);
          _attachBundle(
            cycle: cycle,
            resolutionBytes: entry.linkedBytes,
            manifests: entry.libraryManifests,
            performance: performance,
          );
        }

        eventsController?.add(
          LinkLibraryCycle(
            elementFactory: elementFactory,
            cycle: cycle,
            requirements: requirements,
          ),
        );
      } catch (exception, stackTrace) {
        _throwLibraryCycleLinkException(cycle, exception, stackTrace);
      }
    } else {
      testData?.forCycle(cycle).getKeys.add(cycle.linkedKey);
      performance.getDataInt('libraryLoadCount').add(cycle.libraries.length);
      eventsController?.add(ReuseLinkedBundle(cycle: cycle));
      _attachBundle(
        cycle: cycle,
        resolutionBytes: linkedBytes,
        manifests: probe.libraryManifests,
        performance: performance,
      );
      addToLogRing('[load][addedBundle][cycle: $cycle]');
    }

    loadedBundles.add(cycle);
    onCycle?.call(cycle);

    return .loaded;
  }

  /// Loads [cycle] and any dependencies still missing from this context.
  LibraryLoadResult _loadCycleWithDependencies({
    required LibraryCycle cycle,
    required bool allowLink,
    required void Function(LibraryCycle)? onCycle,
    required OperationPerformanceImpl performance,
  }) {
    if (loadedBundles.contains(cycle)) {
      return .loaded;
    }

    return performance.run('loadBundle', (performance) {
      LibraryLoadResult loadCycle(LibraryCycle cycle) => _loadBundle(
        cycle: cycle,
        performance: performance,
        allowLink: allowLink,
        onCycle: onCycle,
      );

      // During discovery the walker has already visited every dependency.
      // A previously computed graph can still contain unloaded cycles.
      if (cycle.directDependencies.every(loadedBundles.contains)) {
        return loadCycle(cycle);
      }

      for (var pendingCycle in _collectCyclesToLoad(cycle)) {
        var result = loadCycle(pendingCycle);

        if (result == .cacheMiss) {
          return result;
        }
      }

      return .loaded;
    });
  }

  /// Returns a previously linked bundle entry for [cycle] if present and
  /// reusable; otherwise returns `null`. Always returns the last known
  /// [LibraryManifest]s from the stored entry (if any) so they can be reused
  /// to preserve item versions during relinking.
  _LinkedBundleProbeResult _probeLinkedBundle({
    required LibraryCycle cycle,
    required OperationPerformanceImpl performance,
  }) {
    return performance.run('probeLinkedBundle', (performance) {
      var entry = performance.run('readCacheEntry', (performance) {
        return _LinkedBundleCacheEntry.read(
          byteStore: byteStore,
          key: cycle.linkedKey,
          performance: performance,
        );
      });

      // Nothing cached at all.
      if (entry == null) {
        return _LinkedBundleProbeResult(
          libraryManifests: {},
          linkedBytes: null,
        );
      }

      // If we don't track fine dependencies, any hit is good enough.
      // The key already depends on the transitive API signature.
      if (!withFineDependencies) {
        return _LinkedBundleProbeResult(
          libraryManifests: entry.libraryManifests,
          linkedBytes: entry.linkedBytes,
        );
      }

      // If anything changed in the API signature, relink the cycle.
      // But keep previous manifests to reuse item IDs.
      if (entry.nonTransitiveApiSignature != cycle.nonTransitiveApiSignature) {
        return _LinkedBundleProbeResult(
          libraryManifests: entry.libraryManifests,
          linkedBytes: null,
        );
      }

      // Fast-path: if the stored digest matches current manifests, reuse.
      var digestSatisfied = performance.run('checkDigest', (performance) {
        return entry.isDigestSatisfied(
          byteStore: byteStore,
          elementFactory: elementFactory,
          bundleKey: cycle.linkedKey,
        );
      });

      if (digestSatisfied) {
        return _LinkedBundleProbeResult(
          libraryManifests: entry.libraryManifests,
          linkedBytes: entry.linkedBytes,
        );
      }

      var failure = performance.run('checkRequirements', (performance) {
        return entry.requirements.isSatisfied(
          elementFactory: elementFactory,
          performance: performance,
        );
      });

      eventsController?.add(
        CheckLinkedBundleRequirements(cycle: cycle, failure: failure),
      );

      if (failure != null) {
        return _LinkedBundleProbeResult(
          libraryManifests: entry.libraryManifests,
          linkedBytes: null,
        );
      }

      // Requirements satisfied; refresh the fast-path digest entry.
      _LinkedBundleCacheEntry.writeDigest(
        byteStore: byteStore,
        elementFactory: elementFactory,
        bundleKey: cycle.linkedKey,
        bundleId: entry.id,
        requirements: entry.requirements,
      );

      return _LinkedBundleProbeResult(
        libraryManifests: entry.libraryManifests,
        linkedBytes: entry.linkedBytes,
      );
    });
  }

  /// The [exception] was caught during the [cycle] linking.
  ///
  /// Throw another exception that wraps the given one, with more information.
  Never _throwLibraryCycleLinkException(
    LibraryCycle cycle,
    Object exception,
    StackTrace stackTrace,
  ) {
    var fileContentMap = <String, String>{};
    for (var library in cycle.libraries) {
      for (var file in library.files) {
        fileContentMap[file.path] = file.content;
      }
    }
    throw CaughtExceptionWithFiles(exception, stackTrace, fileContentMap);
  }
}

class LibraryContextTestData {
  final FileSystemTestData fileSystemTestData;

  // TODO(scheglov): Use [libraryCycles] and textual dumps for the driver too.
  final List<Set<String>> linkedCycles = [];

  /// Keys: the sorted list of library files.
  final Map<List<FileTestData>, LibraryCycleTestData> libraryCycles =
      LinkedHashMap(
        hashCode: Object.hashAll,
        equals: const ListEquality<FileTestData>().equals,
      );

  /// The current instance of [LibraryContext].
  LibraryContext? instance;

  new({required this.fileSystemTestData});

  LibraryCycleTestData forCycle(LibraryCycle cycle) {
    var files = cycle.libraries.map((library) {
      var file = library.file;
      return fileSystemTestData.forFile(file.resource, file.uri);
    }).toList();
    files.sortBy((fileData) => fileData.file.path);

    return libraryCycles[files] ??= LibraryCycleTestData();
  }
}

class LibraryCycleTestData {
  final List<String> getKeys = [];
  final List<String> putKeys = [];
}

/// The outcome of loading library cycles into a [LibraryContext].
enum LibraryLoadResult {
  /// All requested cycles are available in the element factory.
  loaded,

  /// A required cycle has no reusable bundle and linking was disabled.
  cacheMiss,
}

/// A bundle of linked libraries.
class _LinkedBundleCacheEntry {
  /// See [LibraryCycle.nonTransitiveApiSignature].
  final String nonTransitiveApiSignature;

  /// Unique ID of this bundle to pair digests with bundles.
  final ManifestItemId id;

  /// Serialized requirements; parsed lazily if needed.
  final Uint8List requirementsBytes;

  RequirementsManifest? _requirements;

  /// The manifests of libraries in [linkedBytes].
  ///
  /// If we have to relink libraries, we will match new elements against
  /// these old manifests, and reuse IDs for not affected elements.
  final Map<Uri, LibraryManifestHandle> libraryManifests;

  /// The serialized libraries, for [BundleReader].
  final Uint8List linkedBytes;

  new({
    required this.nonTransitiveApiSignature,
    required this.id,
    required this.requirementsBytes,
    required this.libraryManifests,
    required this.linkedBytes,
  });

  RequirementsManifest get requirements {
    return _requirements ??= RequirementsManifest.fromBytes(requirementsBytes);
  }

  bool isDigestSatisfied({
    required ByteStore byteStore,
    required LinkedElementFactory elementFactory,
    required String bundleKey,
  }) {
    var digestKey = _getDigestKey(bundleKey);
    var digestBytes = byteStore.get(digestKey);
    if (digestBytes == null) {
      return false;
    }
    var digest = RequirementsManifestDigest.fromBytes(digestBytes);
    return digest.bundleId == id && digest.isSatisfied(elementFactory);
  }

  void write({
    required ByteStore byteStore,
    required String key,
    required OperationPerformanceImpl performance,
  }) {
    var writer = BinaryWriter();

    writer.writeStringUtf8(nonTransitiveApiSignature);
    id.write(writer);
    writer.writeUint8List(requirementsBytes);
    writer.writeMap(
      libraryManifests,
      writeKey: (uri) => writer.writeUri(uri),
      writeValue: (manifest) => manifest.write(writer),
    );
    writer.writeUint8List(linkedBytes);

    writer.writeTableTrailer();
    var bytes = writer.takeBytes();

    byteStore.putGet(key, bytes);
    performance.getDataInt('bytes').add(bytes.length);
  }

  static _LinkedBundleCacheEntry? read({
    required ByteStore byteStore,
    required String key,
    required OperationPerformanceImpl performance,
  }) {
    var bytes = byteStore.get(key);
    if (bytes == null) {
      return null;
    }

    performance.getDataInt('bytesLength').add(bytes.length);
    var reader = BinaryReader(bytes);
    reader.initFromTableTrailer();

    var result = _LinkedBundleCacheEntry(
      nonTransitiveApiSignature: reader.readStringUtf8(),
      id: ManifestItemId.read(reader),
      requirementsBytes: reader.readUint8List(),
      libraryManifests: reader.readMap(
        readKey: () => reader.readUri(),
        readValue: () => LibraryManifestHandle.read(reader),
      ),
      linkedBytes: reader.readUint8List(),
    );

    // We have copies of all data.
    byteStore.release([key]);

    return result;
  }

  /// Writes the digest of [requirements] under a separate key.
  static void writeDigest({
    required ByteStore byteStore,
    required LinkedElementFactory elementFactory,
    required String bundleKey,
    required ManifestItemId bundleId,
    required RequirementsManifest requirements,
  }) {
    byteStore.putGet(
      _getDigestKey(bundleKey),
      requirements
          .toDigest(elementFactory: elementFactory, bundleId: bundleId)
          .toBytes(),
    );
  }

  static String _getDigestKey(String bundleKey) {
    return '$bundleKey.digest';
  }
}

class _LinkedBundleProbeResult {
  final Map<Uri, LibraryManifestHandle> libraryManifests;
  final Uint8List? linkedBytes;

  new({required this.libraryManifests, required this.linkedBytes});
}
