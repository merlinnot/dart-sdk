"""Exercise the installed CLI and its separately compiled external plugin."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(dart, root, require_shared):
    plugin = root / 'plugin'
    (plugin / 'lib').mkdir(parents=True)
    (plugin / 'pubspec.yaml').write_text(
        'name: release_fixture\nenvironment:\n  sdk: ^3.13.0\n'
        'dependencies:\n  analysis_server_plugin: any\n  analyzer: any\n')
    (plugin / 'lib/main.dart').write_text("""
import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

final plugin = Fixture();
class Fixture extends Plugin {
  String get name => 'release_fixture';
  void register(PluginRegistry registry) => registry.registerWarningRule(Rule());
}
class Rule extends AnalysisRule {
  Rule() : super(name: 'release_probe', description: 'Release probe');
  LintCode get diagnosticCode => const LintCode('release_probe', 'Release probe');
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    registry.addCompilationUnit(this, Visitor(this));
  }
}
class Visitor extends SimpleAstVisitor<void> {
  final Rule rule;
  Visitor(this.rule);
  void visitCompilationUnit(CompilationUnit node) => rule.reportAtOffset(0, 0);
}
""")
    app = root / 'app'
    (app / 'lib').mkdir(parents=True)
    (app / 'pubspec.yaml').write_text('name: probe\nenvironment:\n  sdk: ^3.13.0\n')
    (app / 'lib/probe.dart').write_text("import 'dart:async';\nFutureOr<int> f() => 1;\n")
    (app / 'analysis_options.yaml').write_text(
        'plugins:\n  release_fixture:\n    path: ' + json.dumps(str(plugin)) + '\n')
    trace = root / 'trace'
    trace.mkdir()
    env = dict(os.environ, DART_ANALYZER_LINKED_SUMMARY_COORDINATOR='1',
               DART_ANALYZER_SUMMARY_TRACE_DIR=str(trace),
               ANALYZER_STATE_LOCATION_OVERRIDE=str(root / 'state'))
    subprocess.run([dart, 'pub', 'get', '--offline'], cwd=app, env=env, check=True)
    result = subprocess.run([dart, 'analyze', '--plugins', '--trust-plugins', '--format=machine'],
                            cwd=app, env=env, text=True, capture_output=True, timeout=300)
    print(result.stdout, result.stderr, flush=True)
    if result.returncode != 0 or '|RELEASE_PROBE|' not in result.stdout.upper():
        raise ValueError('The bundled plugin failed to report its diagnostic')
    if require_shared:
        for role in ('server', 'plugin'):
            stats = json.loads((trace / f'reader-{role}.json').read_text())
            if stats['linked'] < 1:
                raise ValueError(f'{role} consumed no shared library summaries')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as temp:
        check(Path(sys.argv[1]).resolve(), Path(temp).resolve(), '--shared' in sys.argv[2:])
