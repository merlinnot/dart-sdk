// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

/// Configuration shared by requests that can reuse one analysis context.
final class SummaryAnalysisScope(
  final String root, {
  final String? options,
  final String? packages,
  required final Map<String, String> variables,
}) {
  String get indexKey {
    var orderedVariables = variables.length < 2
        ? variables
        : SplayTreeMap.of(variables);

    return jsonEncode([root, options, packages, orderedVariables]);
  }
}

/// A request inside the broker's isolate group. Only its list encoding crosses
/// the plugin boundary.
final class SummaryRequest({
  required final SummaryAnalysisScope scope,
  required final List<String> paths,
  required final Map<String, String> overlays,
  required final List<String> changedFiles,
  required final SendPort reply,
  required final bool wantsProgress,
}) {
  List<Object?> toMessage() => [
    scope.root,
    paths,
    scope.options,
    scope.packages,
    scope.variables,
    wantsProgress,
    overlays,
    changedFiles,
    reply,
  ];

  /// Returns null if the wire message has an invalid field or collection entry.
  static SummaryRequest? tryDecode(List<Object?> message) {
    try {
      return switch (message) {
        [
          String root,
          List paths,
          String? options,
          String? packages,
          Map variables,
          bool wantsProgress,
          Map overlays,
          List changedFiles,
          SendPort reply,
        ] =>
          SummaryRequest(
            scope: SummaryAnalysisScope(
              root,
              options: options,
              packages: packages,
              variables: Map<String, String>.from(variables),
            ),
            paths: List<String>.from(paths),
            overlays: Map<String, String>.from(overlays),
            changedFiles: List<String>.from(changedFiles),
            reply: reply,
            wantsProgress: wantsProgress,
          ),
        _ => null,
      };
    } on TypeError {
      // A collection contained an entry of the wrong type.
      return null;
    }
  }
}
