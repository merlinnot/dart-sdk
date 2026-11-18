// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/src/context/packages.dart';
import 'package:analyzer_testing/resource_provider_mixin.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PackagesTest);
  });
}

@reflectiveTest
class PackagesTest with ResourceProviderMixin {
  void setUp() {
    newFile('/test/lib/test.dart', '');
  }

  void test_findPackagesFrom_missing() {
    var packages = findPackagesFrom(
      resourceProvider,
      getFile('/test/lib/a.dart'),
    );

    expect(packages.packages, isEmpty);
  }

  test_packageForPath() {
    var packages = _packagesWithRoots({
      'aaa': getFolder('/home/aaa'),
      'bbb': getFolder('/home/aaa/bbb'),
      'ccc': getFolder('/home/ccc'),
    });

    void check(String posixPath, String? expectedPackageName) {
      var path = convertPath(posixPath);
      var package = packages.packageForPath(path);
      expect(package?.name, expectedPackageName);
    }

    check('/home/aaa/lib/a.dart', 'aaa');
    check('/home/aaa/bbb/lib/b.dart', 'bbb');
    check('/home/ccc/lib/c.dart', 'ccc');
    check('/home/ddd/lib/d.dart', null);
    check('/home/aaa/bbb', 'aaa');
    check('/home/aaa', null);
    check('/home/aaa2/file.dart', null);
    check(
      '/home/AAA/file.dart',
      pathContext.style == path.Style.windows ? 'aaa' : null,
    );
  }

  void test_packageForPath_empty() {
    expect(Packages.empty.packageForPath(convertPath('/a.dart')), isNull);
  }

  void test_packageForPath_fileSystemRoot() {
    var root = pathContext.rootPrefix(convertPath('/a.dart'));
    var packages = _packagesWithRoots({
      'root': resourceProvider.getFolder(root),
      'nested': getFolder('/nested'),
    });
    expect(packages.packageForPath(convertPath('/a.dart')), packages['root']);
    expect(packages.packageForPath(root), isNull);
  }

  void test_packageForPath_sharedRoot() {
    var root = getFolder('/shared');
    var packages = _packagesWithRoots({'first': root, 'second': root});
    expect(
      packages.packageForPath(convertPath('/shared/a.dart')),
      packages['first'],
    );
  }

  void test_packageForPath_singlePackage() {
    var packages = _packagesWithRoots({'aaa': getFolder('/aaa')});
    expect(
      packages.packageForPath(convertPath('/aaa/lib/a.dart')),
      packages['aaa'],
    );
    expect(packages.packageForPath(convertPath('/aaa')), isNull);
    expect(packages.packageForPath(convertPath('/aaa2/a.dart')), isNull);
  }

  void test_packageForPath_windows() {
    var provider = MemoryResourceProvider(context: path.windows);
    var packages = _packagesWithRoots({
      'local': provider.getFolder(r'C:\Code\App'),
      'share': provider.getFolder(r'\\server\share\pkg'),
    });
    expect(packages.packageForPath(r'c:\code\app\a.dart'), packages['local']);
    expect(packages.packageForPath(r'D:\Code\App\a.dart'), isNull);
    expect(
      packages.packageForPath(r'\\SERVER\Share\PKG\a.dart'),
      packages['share'],
    );
    expect(packages.packageForPath(r'\\server\other\pkg\a.dart'), isNull);
  }

  test_parsePackageConfigJsonFile() {
    var file = newFile('/test/.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "test",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "2.6"
    },
    {
      "name": "aaa",
      "rootUri": "${toUriStr('/packages/aaa')}",
      "packageUri": "lib/",
      "languageVersion": "2.3"
    },
    {
      "name": "bbb",
      "rootUri": "${toUriStr('/packages/bbb')}",
      "packageUri": "lib/"
    }
  ]
}
''');
    var packages = parsePackageConfigJsonFile(resourceProvider, file);

    _assertPackage(
      packages,
      name: 'test',
      expectedLibPath: '/test/lib',
      expectedVersion: Version(2, 6, 0),
    );

    _assertPackage(
      packages,
      name: 'aaa',
      expectedLibPath: '/packages/aaa/lib',
      expectedVersion: Version(2, 3, 0),
    );

    _assertPackage(
      packages,
      name: 'bbb',
      expectedLibPath: '/packages/bbb/lib',
      expectedVersion: null,
    );
  }

  test_parsePackagesFile_packageConfig() {
    var file = newFile('/test/.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "aaa",
      "rootUri": "${toUriStr('/packages/aaa')}",
      "packageUri": "lib/",
      "languageVersion": "2.3"
    }
  ]
}
''');

    var packages = parsePackageConfigJsonFile(resourceProvider, file);

    _assertPackage(
      packages,
      name: 'aaa',
      expectedLibPath: '/packages/aaa/lib',
      expectedVersion: Version(2, 3, 0),
    );
  }

  void _assertPackage(
    Packages packages, {
    required String name,
    required String expectedLibPath,
    required Version? expectedVersion,
  }) {
    var package = packages[name]!;
    expect(package.name, name);
    expect(package.libFolder.path, convertPath(expectedLibPath));
    expect(package.languageVersion, expectedVersion);
  }

  Packages _packagesWithRoots(Map<String, Folder> roots) {
    return Packages({
      for (var MapEntry(key: name, value: root) in roots.entries)
        name: Package(
          name: name,
          rootFolder: root,
          libFolder: root.getFolder('lib'),
          languageVersion: null,
        ),
    });
  }
}
