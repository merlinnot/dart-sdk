// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/util/uri.dart';
import 'package:package_config/package_config_types.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

/// Find [Packages] starting from the given [start] resource.
///
/// Looks for `.dart_tool/package_config.json` in the given and parent
/// directories.
Packages findPackagesFrom(ResourceProvider provider, Resource start) {
  var startFolder = start is Folder ? start : start.parent;
  for (var current in startFolder.withAncestors) {
    var jsonFile = current
        .getFolder('.dart_tool')
        .getFile('package_config.json');
    if (jsonFile.exists) {
      return parsePackageConfigJsonFile(provider, jsonFile);
    }
  }
  return Packages.empty;
}

/// Parse the [file] as a `package_config.json` file.
Packages parsePackageConfigJsonFile(ResourceProvider provider, File file) {
  PackageConfig jsonConfig;
  try {
    var uri = file.toUri();
    var content = file.readAsStringSync();
    jsonConfig = PackageConfig.parseString(content, uri);
  } catch (e) {
    return Packages.empty;
  }

  var map = <String, Package>{};
  for (var jsonPackage in jsonConfig.packages) {
    var name = jsonPackage.name;

    var rootPath = fileUriToNormalizedPath(
      provider.pathContext,
      jsonPackage.root,
    );

    var libPath = fileUriToNormalizedPath(
      provider.pathContext,
      jsonPackage.packageUriRoot,
    );

    Version? languageVersion;
    var jsonLanguageVersion = jsonPackage.languageVersion;
    if (jsonLanguageVersion != null) {
      languageVersion = Version(
        jsonLanguageVersion.major,
        jsonLanguageVersion.minor,
        0,
      );
    }

    map[name] = Package(
      name: name,
      rootFolder: provider.getFolder(rootPath),
      libFolder: provider.getFolder(libPath),
      languageVersion: languageVersion,
    );
  }

  return Packages(map);
}

class Package {
  final String name;
  final Folder rootFolder;
  final Folder libFolder;

  /// The language version for this package, `null` not specified explicitly.
  final Version? languageVersion;

  new({
    required this.name,
    required this.rootFolder,
    required this.libFolder,
    required this.languageVersion,
  });
}

/// A snapshot of the packages configured for one file system.
class Packages {
  static final empty = Packages({});

  final Map<String, Package> _byName;
  late final _pathContext = packages.first.rootFolder.provider.pathContext;
  late final _byRoot = _indexByRoot();

  new(Map<String, Package> byName) : _byName = Map.unmodifiable(byName);

  Iterable<Package> get packages => _byName.values;

  /// Return the [Package] with the given [name], or `null`.
  Package? operator [](String name) => _byName[name];

  /// Returns the innermost package containing [path], or `null` if none.
  ///
  /// The path must be absolute and normalized. A root does not contain itself.
  Package? packageForPath(String path) {
    switch (_byName.length) {
      case 0:
        return null;
      case 1:
        var package = packages.first;
        return package.rootFolder.contains(path) ? package : null;
    }

    while (true) {
      var parent = _pathContext.dirname(path);
      if (parent == path) return null;
      var package = _byRoot[parent];
      if (package != null) return package;
      path = parent;
    }
  }

  path.PathMap<Package> _indexByRoot() {
    var byRoot = path.PathMap<Package>(context: _pathContext);
    for (var package in packages) {
      // When two names share a root, keep the first package in config order.
      byRoot.putIfAbsent(package.rootFolder.path, () => package);
    }
    return byRoot;
  }
}
