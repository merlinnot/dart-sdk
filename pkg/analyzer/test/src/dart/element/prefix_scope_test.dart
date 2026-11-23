// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/scope.dart';
import 'package:analyzer/src/fine/requirements.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../resolution/context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PrefixScopeTest);
  });
}

@reflectiveTest
class PrefixScopeTest extends PubPackageResolutionTest {
  test_conflictingImports() async {
    newFile('$testPackageLibPath/a.dart', 'class C {}');
    newFile('$testPackageLibPath/b.dart', 'class C {}');
    newFile(testFile.path, '''
import 'a.dart' as p;
import 'b.dart' as p;
import 'b.dart' as q;
import 'a.dart' as q;
''');
    var library = await libraryElementForFile(testFile);
    for (var prefix in library.firstFragment.prefixes) {
      var conflict = prefix.scope.lookup('C').getter as MultiplyDefinedElement;
      expect(conflict.conflictingElements, [
        for (var import in prefix.imports)
          import.importedLibrary!.getClass('C'),
      ]);
    }
  }

  test_deprecatedReExport() async {
    newFile('$testPackageLibPath/a.dart', 'int foo = 0;');
    newFile('$testPackageLibPath/barrel.dart', '''
@deprecated
export 'a.dart';
''');
    newFile(testFile.path, '''
import 'barrel.dart' as deprecatedOnly;
import 'barrel.dart' as deprecatedFirst;
import 'a.dart' as deprecatedFirst;
import 'a.dart' as deprecatedLast;
import 'barrel.dart' as deprecatedLast;
''');
    var library = await libraryElementForFile(testFile);
    for (var prefix in library.firstFragment.prefixes) {
      var result = prefix.scope.lookup('foo') as PrefixScopeLookupResult;
      expect(result.getter, isA<GetterElement>());
      expect(result.setter, isA<SetterElement>());
      var deprecated = prefix.name == 'deprecatedOnly';
      expect(result.getterIsFromDeprecatedExport, deprecated);
      expect(result.setterIsFromDeprecatedExport, deprecated);
    }
  }

  test_exportEntriesReassigned() async {
    newFile('$testPackageLibPath/a.dart', 'class A {} class B {}');
    newFile(testFile.path, "import 'a.dart' as p;");
    var library = await libraryElementForFile(testFile);
    var prefix = library.firstFragment.prefixes.single;
    var imported = prefix.imports.single.importedLibrary!;
    expect(prefix.scope.lookup('A').getter, same(imported.getClass('A')!));

    imported.exportEntries = [
      for (var entry in imported.exportEntries)
        if (entry.name == 'B') entry,
    ];
    // A new importing scope must see the replacement index.
    library.resetScope();
    expect(prefix.scope.lookup('A').getter, isNull);
    expect(prefix.scope.lookup('B').getter, same(imported.getClass('B')!));
  }

  test_getterAndSetter_combinators() async {
    newFile('$testPackageLibPath/a.dart', '''
int get foo => 0;
set foo(int value) {}
''');
    newFile(testFile.path, '''
import 'a.dart' as shown show foo;
import 'a.dart' as hidden hide foo;
''');
    var library = await libraryElementForFile(testFile);
    var prefixes = library.firstFragment.prefixes;
    var imported = prefixes.first.imports.single.importedLibrary!;
    var entries = imported.exportEntries;
    expect(entries.map((e) => e.name), unorderedEquals(['foo', 'foo=']));
    for (var order in [entries, entries.reversed.toList()]) {
      imported.exportEntries = order;
      expect(imported.sharedExportIndex.entriesForTesting('foo'), order);
      library.resetScope();
      var shown = prefixes.first.scope.lookup('foo');
      expect(shown.getter, same(imported.getters.single));
      expect(shown.setter, same(imported.setters.single));
      var hidden = prefixes.last.scope.lookup('foo');
      expect(hidden.getter, isNull);
      expect(hidden.setter, isNull);
    }
  }

  test_lazyReExport_hide() async {
    var (:library, :bUri) = await _linkImporter(
      'hide B, E',
      extension: 'extension E on int {}',
    );
    var factory = library.internal.elementFactory;
    expect(library.getClass('C')!.supertype!.element.name, 'A');
    expect(factory.uriListWithLibraryElements, isNot(contains(bUri)));

    var prefix = library.firstFragment.prefixes.single;
    expect(prefix.scope.lookup('B').getter, isNull);
    expect(
      library.firstFragment.scope.accessibleExtensions.map((e) => e.name),
      isNot(contains('E')),
    );
    expect(factory.uriListWithLibraryElements, isNot(contains(bUri)));
  }

  test_lazyReExport_show() async {
    var (:library, :bUri) = await _linkImporter(
      'show A',
      extension: 'extension E on int {}',
    );
    var factory = library.internal.elementFactory;
    expect(library.getClass('C')!.supertype!.element.name, 'A');
    expect(factory.uriListWithLibraryElements, isNot(contains(bUri)));

    var prefix = library.firstFragment.prefixes.single;
    expect(prefix.scope.lookup('B').getter, isNull);
    expect(
      library.firstFragment.scope.accessibleExtensions.map((e) => e.name),
      isNot(contains('E')),
    );
    expect(factory.uriListWithLibraryElements, isNot(contains(bUri)));
  }

  test_lazyReExport_shownExtension() async {
    var extensions = newFile('$testPackageLibPath/extensions.dart', '''
extension Visible on int { int get doubled => this * 2; }
extension Hidden on int { int get doubled => 0; }
''');
    newFile('$testPackageLibPath/barrel.dart', "export 'extensions.dart';");
    await libraryElementForFile(extensions);
    await disposeAnalysisContextCollection();
    await resolveTestCodeWithDiagnostics('''
import 'barrel.dart' show Visible;
int f() => 1.doubled;
''');
  }

  test_lazyReExport_unfiltered() async {
    var (:library, :bUri) = await _linkImporter('');
    var factory = library.internal.elementFactory;
    expect(library.getClass('C')!.supertype!.element.name, 'A');
    expect(factory.uriListWithLibraryElements, isNot(contains(bUri)));

    var prefix = library.firstFragment.prefixes.single;
    expect(prefix.scope.lookup('B').getter?.library?.uri, bUri);
    expect(factory.uriListWithLibraryElements, contains(bUri));
  }

  test_partPrefix_shadowedByUnprefixedImport() async {
    newFile('$testPackageLibPath/a.dart', 'class A {}');
    newFile('$testPackageLibPath/b.dart', 'class p {}');
    newFile(testFile.path, '''
import 'a.dart' as p;
part 'mid.dart';
''');
    newFile('$testPackageLibPath/mid.dart', '''
part of 'test.dart';
import 'b.dart';
part 'child.dart';
''');
    newFile('$testPackageLibPath/child.dart', '''
part of 'mid.dart';
import 'dart:math' as p;
''');
    var library = await libraryElementForFile(testFile);
    library.resetScope();
    var middle = library.fragments[1];
    var child = library.fragments[2].prefixes.single;
    var tracking = middle.scope.importsTrackingInit();
    var requirements = _PrefixLookupRecorder();
    var previous = globalResultRequirements;
    try {
      globalResultRequirements = requirements;
      // Constructing the child's scope probes the middle file for 'p'.
      var scope = child.scope;
      expect(requirements.prefixLookups, isEmpty);
      var import = middle.libraryImports.firstWhere((i) => !i.isSynthetic);
      expect(tracking.elementsOf(import), isEmpty);
      expect(scope.parent, isNull);
      expect(requirements.prefixLookups, contains('p'));
      expect(scope.lookup('A').getter, isNull);

      // An actual lookup of the same name is a use of the middle import.
      var element = middle.scope.lookup('p').getter!;
      expect(tracking.elementsOf(import), {element});
    } finally {
      globalResultRequirements = previous;
      middle.scope.importsTrackingDestroy();
    }
  }

  test_sdkShadowedByNonSdk() async {
    newFile('$testPackageLibPath/a.dart', 'class String {}');
    newFile(testFile.path, '''
import 'dart:core' as p;
import 'a.dart' as p;
import 'a.dart' as q;
import 'dart:core' as q;
''');
    var library = await libraryElementForFile(testFile);
    var imported = library.firstFragment.libraryImports
        .firstWhere((i) => i.importedLibrary?.uri.scheme == 'package')
        .importedLibrary!;
    for (var prefix in library.firstFragment.prefixes) {
      expect(
        prefix.scope.lookup('String').getter,
        same(imported.getClass('String')!),
      );
    }
  }

  Future<({LibraryElementImpl library, Uri bUri})> _linkImporter(
    String combinators, {
    String extension = '',
  }) async {
    newFile('$testPackageLibPath/a.dart', 'class A {}');
    newFile('$testPackageLibPath/b.dart', '''
class B {}
$extension
''');
    newFile('$testPackageLibPath/mid.dart', "export 'b.dart';");
    var barrel = newFile('$testPackageLibPath/barrel.dart', '''
export 'a.dart';
export 'mid.dart';
''');
    // Start linking the importer with cached summaries and fresh readers.
    await libraryElementForFile(barrel);
    await disposeAnalysisContextCollection();
    newFile(testFile.path, '''
import 'barrel.dart' as p $combinators;
class C extends p.A {}
''');
    var library = await libraryElementForFile(testFile);
    return (library: library, bUri: Uri.parse('package:test/b.dart'));
  }
}

class _PrefixLookupRecorder extends RequirementsManifest {
  final prefixLookups = <String>[];

  @override
  void record_importPrefixScope_lookup({
    required PrefixScopeRequirementState state,
    required List<LibraryElementImpl> importedLibraries,
    required String id,
  }) {
    prefixLookups.add(id);
  }
}
