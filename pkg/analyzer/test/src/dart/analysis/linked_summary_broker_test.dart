// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/library_context.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:test/test.dart';

void main() {
  group('linked summary broker', () {
    late LinkedSummaryBroker broker;
    late LinkedSummaryCoordinator plugin;

    setUp(() {
      var sdk = File(Platform.resolvedExecutable).parent.parent.path;
      broker = LinkedSummaryBroker(sdk);
      plugin = LinkedSummaryCoordinator(broker.sendPort);
    });

    tearDown(() async {
      plugin.close();
      await broker.shutdown();
    });

    test('concurrent shutdowns during startup share completion', () async {
      var first = broker.shutdown();
      expect(broker.shutdown(), same(first));
      await first;
    });

    test(
      'producer failure wakes waiting readers and rejects later requests',
      () async {
        // An invalid context root fails inside the producer. Both readers must
        // receive the failure before their normal idle timeout.
        Future<SummaryPreparationResult> invalidRequest(
          LinkedSummaryCoordinator reader,
        ) => reader.prepare(root: 'relative', paths: []);

        var results = await Future.wait([
          invalidRequest(broker),
          invalidRequest(plugin),
        ]).timeout(const Duration(seconds: 5));
        expect(results, everyElement(SummaryPreparationResult.unavailable));
        expect(
          await invalidRequest(plugin).timeout(const Duration(seconds: 5)),
          SummaryPreparationResult.unavailable,
        );
      },
    );

    if (!Platform.isMacOS) {
      return;
    }

    group('publication', () {
      late Directory directory;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'analyzer-summary-test-',
        );
      });

      tearDown(() async {
        await directory.delete(recursive: true);
      });

      String writeLibrary(String name, String content) {
        var file = File('${directory.path}/$name.dart')
          ..writeAsStringSync(content);

        return file.path;
      }

      Future<List<String>> prepare(
        String path, {
        Map<String, String> overlays = const {},
        Map<String, String> variables = const {},
        List<String> changedFiles = const [],
        String? packages,
      }) async {
        var published = <String>[];
        var result = await plugin.prepare(
          root: directory.path,
          paths: [path],
          changedFiles: changedFiles,
          packages: packages,
          overlays: overlays,
          variables: variables,
          onAvailable: (cycles) => published.addAll(cycles.takePaths()),
        );
        expect(result, SummaryPreparationResult.prepared);

        return published;
      }

      test(
        'publishes dependencies first and reuses them on later requests',
        () async {
          var a = writeLibrary('a', "import 'b.dart'; B? a;");
          var b = writeLibrary('b', "import 'c.dart'; class B { C? c; }");
          var c = writeLibrary('c', "import 'b.dart'; class C { B? b; }");
          var published = await prepare(a);

          var local = published.where({a, b, c}.contains).toList();
          expect(local, hasLength(3));
          expect(local.take(2), unorderedEquals([b, c]));
          expect(local.last, a);

          var later = writeLibrary(
            'later',
            "import 'a.dart'; var nested = a?.c;",
          );
          expect(await prepare(later), [later]);
        },
      );

      test(
        'a replacement reader sees configuration changed during a host rebuild',
        () async {
          var entry = writeLibrary('entry', 'class Entry {}');
          var options = File('${directory.path}/analysis_options.yaml')
            ..writeAsStringSync('analyzer: {}');
          Future<SummaryPreparationResult> request(
            LinkedSummaryCoordinator reader,
          ) => reader.prepare(root: directory.path, paths: [entry]);

          expect(await request(plugin), SummaryPreparationResult.prepared);
          options.writeAsStringSync('analyzer:\n  exclude: [entry.dart]');
          broker.invalidateRoot(directory.path);
          expect(await request(plugin), SummaryPreparationResult.declined);

          options.writeAsStringSync('analyzer: {}');
          plugin.invalidateRoot(directory.path);
          expect(await request(broker), SummaryPreparationResult.prepared);
        },
      );

      for (var source in ['discovered', 'explicit', 'included']) {
        test('editing $source analysis options updates exclusions', () async {
          var entry = writeLibrary('entry', 'class Entry {}');
          var rootOptions = File('${directory.path}/analysis_options.yaml');
          var options = source == 'discovered'
              ? rootOptions
              : File('${directory.path}/shared.config');

          if (source == 'included') {
            rootOptions.writeAsStringSync('include: common.yaml');
            File('${directory.path}/common.yaml')
                .writeAsStringSync('include: shared.config');
          }

          const excludeEntry = 'analyzer:\n  exclude: [entry.dart]';
          options.writeAsStringSync('analyzer: {}');

          Future<SummaryPreparationResult> request({
            List<String> changed = const [],
            Map<String, String> overlays = const {},
          }) => plugin.prepare(
            root: directory.path,
            paths: [entry],
            options: source == 'explicit' ? options.path : null,
            changedFiles: changed,
            overlays: overlays,
          );

          expect(await request(), SummaryPreparationResult.prepared);
          options.writeAsStringSync(excludeEntry);
          expect(
            await request(changed: [options.path]),
            SummaryPreparationResult.declined,
          );
          expect(
            await request(overlays: {options.path: 'analyzer: {}'}),
            SummaryPreparationResult.prepared,
          );
          expect(await request(), SummaryPreparationResult.declined);
          options.deleteSync();
          expect(
            await request(changed: [options.path]),
            SummaryPreparationResult.prepared,
          );
          options.writeAsStringSync(excludeEntry);
          expect(
            await request(changed: [options.path]),
            SummaryPreparationResult.declined,
          );
        });
      }

      test('an excluded path declines only its own request', () async {
        var excluded = writeLibrary('excluded', 'class Excluded {}');
        var included = writeLibrary('included', 'class Included {}');
        File('${directory.path}/analysis_options.yaml')
            .writeAsStringSync('analyzer:\n  exclude: [excluded.dart]');

        var declined = plugin.prepare(root: directory.path, paths: [excluded]);
        var queued = broker.prepare(root: directory.path, paths: [included]);

        expect(await declined, SummaryPreparationResult.declined);
        expect(await queued, SummaryPreparationResult.prepared);
        expect(
          await plugin.prepare(root: directory.path, paths: [included]),
          SummaryPreparationResult.prepared,
        );
      });

      test('declared variable order does not create another scope', () async {
        var entry = writeLibrary('entry', 'class Entry {}');
        expect(
          await prepare(entry, variables: {'a': '1', 'b': '2'}),
          contains(entry),
        );
        expect(await prepare(entry, variables: {'b': '2', 'a': '1'}), isEmpty);
      });

      for (var explicit in [false, true]) {
        var source = explicit ? 'explicit' : 'discovered';
        test(
          'remapping the $source package config refreshes cached scopes',
          () async {
            var config = File(
              explicit
                  ? '${directory.path}/custom.json'
                  : '${directory.path}/.dart_tool/package_config.json',
            )..createSync(recursive: true);

            String configFor(String name) => jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'dep',
                  'rootUri': directory.uri.resolve('$name/').toString(),
                  'packageUri': 'lib/',
                  'languageVersion': '3.10',
                },
              ],
            });

            String dependency(String name) {
              var file = File('${directory.path}/$name/lib/dep.dart')
                ..createSync(recursive: true)
                ..writeAsStringSync('class Dependency {}');

              return file.path;
            }

            var first = dependency('first');
            var second = dependency('second');
            var entry = writeLibrary('entry', "export 'package:dep/dep.dart';");

            Future<Iterable<String>> dependencies(
              String mode, {
              List<String> changed = const [],
              Map<String, String> overlays = const {},
            }) async {
              var published = await prepare(
                entry,
                packages: explicit ? config.path : null,
                variables: {'mode': mode},
                changedFiles: changed,
                overlays: overlays,
              );

              return published.where({first, second}.contains);
            }

            config.writeAsStringSync(configFor('first'));
            expect(await dependencies('a'), [first]);
            expect(await dependencies('b'), [first]);

            config.writeAsStringSync(configFor('second'));
            expect(await dependencies('a', changed: [config.path]), [second]);
            expect(await dependencies('b'), [second]);

            var overlay = {config.path: configFor('first')};
            expect(await dependencies('a', overlays: overlay), [first]);
            expect(await dependencies('b'), isEmpty);
            expect(await dependencies('a'), [second]);
          },
        );
      }

      test(
        'standalone shutdown releases the arena and persists every cycle',
        () async {
          var entry = writeLibrary(
            'entry',
            [for (var i = 0; i < 32; i++) "export 'dep$i.dart';"].join('\n'),
          );
          for (var i = 0; i < 32; i++) {
            writeLibrary('dep$i', 'class C$i {}');
          }
          var temp = Directory('${directory.path}/temp')..createSync();
          var state = Directory('${directory.path}/state')..createSync();
          var analyzerLib = (await Isolate.resolvePackageUri(
            Uri.parse('package:analyzer/'),
          ))!;
          var script = analyzerLib.resolve(
            '../test/src/dart/analysis/fixtures/linked_summary_shutdown.dart',
          );
          var child = await Process.run(
            Platform.resolvedExecutable,
            [
              '--packages=${(await Isolate.packageConfig)!}',
              script.toFilePath(),
              entry,
            ],
            environment: {
              'TMPDIR': temp.path,
              'ANALYZER_STATE_LOCATION_OVERRIDE': state.path,
            },
          );

          expect(child.exitCode, 0, reason: '${child.stderr}');
          expect(child.stdout.toString().trim(), 'shutdown complete');
          expect(temp.listSync(), isEmpty);

          // A new driver must be able to resolve the whole graph from disk.
          var cache = FileByteStore('${state.path}/.analysis-driver');
          var collection = AnalysisContextCollectionImpl(
            includedPaths: [directory.path],
            byteStore: cache,
            withFineDependencies: true,
            sdkPath: File(Platform.resolvedExecutable).parent.parent.path,
          );
          try {
            var driver = collection.contextFor(entry).driver;
            var target = driver.fsState.getFileForPath(entry).kind.library!;
            expect(
              driver.libraryContext.loadForResolution(
                targetLibrary: target,
                performance: OperationPerformanceImpl('warm load'),
                allowLink: false,
              ),
              LibraryLoadResult.loaded,
            );
          } finally {
            await collection.dispose();
            await cache.flush();
          }
        },
      );

      test('returning to a scope reuses its collection and overlays', () async {
        var first = writeLibrary('first', 'class First {}');
        var second = writeLibrary('second', 'class Second {}');
        var entry = writeLibrary('entry', '');

        Future<List<String>> select(String name) => prepare(
          entry,
          variables: {'mode': name},
          overlays: {entry: "export '$name.dart';"},
        );

        expect(await select('first'), containsAllInOrder([first, entry]));
        expect(await select('second'), containsAllInOrder([second, entry]));
        expect(await select('first'), isEmpty);
      });

      test('overlay changes select which dependencies are published', () async {
        var onDisk = writeLibrary('on_disk', 'class OnDisk {}');
        var first = writeLibrary('first', 'class First {}');
        var second = writeLibrary('second', 'class Second {}');
        var entry = writeLibrary('entry', "export 'on_disk.dart';");
        var dependencies = {onDisk, first, second};

        Future<Iterable<String>> dependenciesFor(
          Map<String, String> overlays,
        ) async {
          var published = await prepare(entry, overlays: overlays);

          return published.where(dependencies.contains);
        }

        expect(await dependenciesFor({entry: "export 'first.dart';"}), [first]);
        expect(await dependenciesFor({entry: "export 'second.dart';"}), [
          second,
        ]);
        expect(await dependenciesFor({}), [onDisk]);
      });

      test(
        'queued overlay edits and removal republish the dependency',
        () async {
          var importer = writeLibrary(
            'a',
            "import 'b.dart'; var value = fromB;",
          );
          var dependency = writeLibrary('b', 'const fromB = 0;');
          await prepare(importer);

          var first = prepare(
            importer,
            overlays: {dependency: 'const fromB = "a";'},
          );
          var second = prepare(
            importer,
            overlays: {dependency: 'const fromB = false;'},
          );
          expect(await first, contains(dependency));
          expect(await second, contains(dependency));

          expect(await prepare(importer), contains(dependency));
          expect(File(dependency).readAsStringSync(), 'const fromB = 0;');
        },
      );
    });
  });
}
