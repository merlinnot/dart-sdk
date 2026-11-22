// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_contexts.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:analyzer/src/workspace/blaze.dart';
import 'package:analyzer/src/workspace/pub.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File entry;
  late SummaryProducerContexts contexts;
  late ReceivePort reply;

  File file(String relativePath) =>
      File.fromUri(directory.uri.resolve(relativePath));

  Future<AnalysisContextCollectionImpl> prepare(
    String mode, {
    List<String> changed = const [],
    Map<String, String> overlays = const {},
    String? options,
    String? root,
  }) async {
    var result = await contexts.prepare(
      SummaryRequest(
        scope: SummaryAnalysisScope(
          root ?? directory.path,
          variables: {'mode': mode},
          options: options,
        ),
        paths: [entry.path],
        overlays: overlays,
        changedFiles: changed,
        reply: reply.sendPort,
        wantsProgress: false,
      ),
    );

    return result.collection;
  }

  bool includesEntry(AnalysisContextCollectionImpl collection) => collection
      .contexts
      .any((context) => context.contextRoot.isAnalyzed(entry.path));

  String parsedSource(AnalysisContextCollectionImpl collection) {
    var driver = collection.contextFor(entry.path).driver;
    var unit = driver.parseFileSync(entry.path) as ParsedUnitResult;

    return unit.content;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('producer-contexts-');
    entry = file('entry.dart')..writeAsStringSync('int disk = 0;');
    reply = ReceivePort();
    contexts = SummaryProducerContexts(
      File(Platform.resolvedExecutable).parent.parent.path,
      MemoryByteStore(),
    );
  });

  tearDown(() async {
    await contexts.dispose();
    reply.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'source overlays are isolated and removal reveals the latest disk edit',
    () async {
      var overlay = {entry.path: 'int unsaved = 1;'};
      var editor = await prepare('editor', overlays: overlay);
      var disk = await prepare('disk');
      expect(parsedSource(editor), 'int unsaved = 1;');
      expect(parsedSource(disk), 'int disk = 0;');

      entry.writeAsStringSync('int updatedOnDisk = 2;');
      // The editor reports the disk edit while it still has unsaved contents.
      expect(
        await prepare('editor', overlays: overlay, changed: [entry.path]),
        same(editor),
      );
      expect(parsedSource(editor), 'int unsaved = 1;');
      expect(parsedSource(disk), 'int updatedOnDisk = 2;');

      expect(
        await prepare('editor', overlays: {entry.path: 'int editedAgain = 3;'}),
        same(editor),
      );
      expect(parsedSource(editor), 'int editedAgain = 3;');
      expect(parsedSource(disk), 'int updatedOnDisk = 2;');

      expect(await prepare('editor'), same(editor));
      expect(parsedSource(editor), 'int updatedOnDisk = 2;');
      expect(await prepare('disk'), same(disk));
    },
  );

  test(
    'a disk edit rebuilds only scopes that see the edited options',
    () async {
      file('analysis_options.yaml').writeAsStringSync('include: shared.yaml');
      var shared = file('shared.yaml')..writeAsStringSync('analyzer: {}');
      var disk = await prepare('disk');
      var originalEditor = await prepare('editor');
      var overlay = {shared.path: 'analyzer:\n  exclude: [entry.dart]'};
      var editor = await prepare('editor', overlays: overlay);
      expect(editor, isNot(same(originalEditor)));
      expect(includesEntry(editor), isFalse);
      expect(includesEntry(disk), isTrue);

      shared.writeAsStringSync('# new disk options');
      var refreshed = await prepare('disk', changed: [shared.path]);
      expect(refreshed, isNot(same(disk)));
      expect(includesEntry(refreshed), isTrue);
      expect(await prepare('editor', overlays: overlay), same(editor));
      expect(includesEntry(editor), isFalse);

      expect(includesEntry(await prepare('editor')), isTrue);
      expect(await prepare('disk'), same(refreshed));
    },
  );

  test(
    'tracks missing includes and forgets includes that are no longer used',
    () async {
      var options = file('analysis_options.yaml')
        ..writeAsStringSync('include: missing.yaml');
      var missing = file('missing.yaml');
      expect(includesEntry(await prepare('editor')), isTrue);

      missing.writeAsStringSync('analyzer:\n  exclude: [entry.dart]');
      expect(
        includesEntry(await prepare('editor', changed: [missing.path])),
        isFalse,
      );
      options.writeAsStringSync('analyzer: {}');
      var current = await prepare('editor', changed: [options.path]);
      expect(includesEntry(current), isTrue);

      missing.deleteSync();
      expect(await prepare('editor', changed: [missing.path]), same(current));
    },
  );

  test(
    'an explicit options file takes precedence over a new default',
    () async {
      var custom = file('custom.yaml')..writeAsStringSync('analyzer: {}');
      var explicit = await prepare('explicit', options: custom.path);
      var automatic = await prepare('automatic');
      var options = file('analysis_options.yaml')
        ..writeAsStringSync('analyzer:\n  exclude: [entry.dart]');

      expect(
        await prepare(
          'explicit',
          options: custom.path,
          changed: [options.path],
        ),
        same(explicit),
      );
      expect(includesEntry(explicit), isTrue);
      var refreshed = await prepare('automatic');
      expect(refreshed, isNot(same(automatic)));
      expect(includesEntry(refreshed), isFalse);
    },
  );

  test(
    'discovering and removing a nested package config changes the file owner',
    () async {
      var nested = file('nested/entry.dart')..createSync(recursive: true);
      String rootFor(AnalysisContextCollectionImpl collection) =>
          collection.contextFor(nested.path).contextRoot.root.path;

      expect(rootFor(await prepare('disk')), directory.path);
      var config = file('nested/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}');
      expect(
        rootFor(await prepare('disk', changed: [config.path])),
        nested.parent.path,
      );

      config.deleteSync();
      expect(
        rootFor(await prepare('disk', changed: [config.path])),
        directory.path,
      );
    },
  );

  test(
    'adding a nested BUILD.gn creates a context for that directory',
    () async {
      var nested = file('nested/entry.dart')..createSync(recursive: true);
      var original = await prepare('disk');
      expect(
        original.contextFor(nested.path),
        same(original.contextFor(entry.path)),
      );

      var marker = file('nested/BUILD.gn')..createSync();
      var refreshed = await prepare('disk', changed: [marker.path]);
      expect(
        refreshed.contextFor(nested.path).contextRoot.root.path,
        nested.parent.path,
      );
    },
  );

  test(
    'a missing Blaze marker above the scope can appear and disappear',
    () async {
      entry = file('app/src/entry.dart')..createSync(recursive: true);
      var root = entry.parent.path;
      Future<bool> usesBlaze([List<String> changed = const []]) async {
        var collection = await prepare('disk', root: root, changed: changed);

        return collection.contextFor(entry.path).contextRoot.workspace
            is BlazeWorkspace;
      }

      expect(await usesBlaze(), isFalse);
      var marker = file('app/dart/config/ide/flutter.json')
        ..createSync(recursive: true);
      expect(await usesBlaze([marker.path]), isTrue);
      marker.deleteSync();
      expect(await usesBlaze([marker.path]), isFalse);
    },
  );

  test(
    'an external embedder mapping refreshes dart library resolution',
    () async {
      entry = file('app/entry.dart')..createSync(recursive: true);
      var sky = directory.uri.resolve('sky_engine/');
      file('app/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'sky_engine',
                'rootUri': sky.toString(),
                'packageUri': 'lib/',
                'languageVersion': '3.0',
              },
            ],
          }),
        );
      var first = file('sky_engine/lib/first.dart')
        ..createSync(recursive: true);
      var second = file('sky_engine/lib/second.dart')..createSync();
      var mapping = file('sky_engine/lib/_embedder.yaml');
      Future<String?> core([List<String> changed = const []]) async {
        var collection = await prepare(
          'disk',
          root: entry.parent.path,
          changed: changed,
        );

        return collection
            .contextFor(entry.path)
            .driver
            .sourceFactory
            .forUri('dart:core')
            ?.fullName;
      }

      var original = await core();
      mapping.writeAsStringSync('embedded_libs:\n  "dart:core": "first.dart"');
      expect(await core([mapping.path]), first.path);
      mapping.writeAsStringSync('embedded_libs:\n  "dart:core": "second.dart"');
      expect(await core([mapping.path]), second.path);
      mapping.deleteSync();
      expect(await core([mapping.path]), original);
    },
  );

  test(
    'invalidating a root discards its scopes and preserves other roots',
    () async {
      var root = file('project/entry.dart')..createSync(recursive: true);
      var first = await prepare('first', root: root.parent.path);
      var second = await prepare('second', root: root.parent.path);
      var other = await prepare('other');
      file('project/analysis_options.yaml')
          .writeAsStringSync('analyzer:\n  exclude: [entry.dart]');

      await contexts.invalidateRoot(root.parent.path);
      var refreshed = await prepare('first', root: root.parent.path);
      expect(refreshed, isNot(same(first)));
      expect(
        refreshed.contexts.any((c) => c.contextRoot.isAnalyzed(root.path)),
        isFalse,
      );
      expect(
        await prepare('second', root: root.parent.path),
        isNot(same(second)),
      );
      expect(await prepare('other'), same(other));
    },
  );

  test('changing the pubspec refreshes Pub workspace membership', () async {
    file('.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    var pubspec = file('pubspec.yaml')..writeAsStringSync('name: example');
    bool isWorkspace(AnalysisContextCollectionImpl collection) {
      var root = collection.contextFor(entry.path).contextRoot;

      return (root.workspace as PackageConfigWorkspace).isPubWorkspace;
    }

    expect(isWorkspace(await prepare('disk')), isFalse);

    pubspec.writeAsStringSync('name: example\nworkspace: [packages/member]');
    expect(isWorkspace(await prepare('disk', changed: [pubspec.path])), isTrue);
    pubspec.deleteSync();
    expect(
      isWorkspace(await prepare('disk', changed: [pubspec.path])),
      isFalse,
    );
  });
}
