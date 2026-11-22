"""Build the analyzer on a pinned, matching Dart AOT compiler and runtime."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[2]


def packages():
    """Resolve production dependencies from the same workspace and DEPS as the SDK."""
    workspace = yaml.safe_load((ROOT / 'pubspec.yaml').read_text())
    paths = {name: ROOT / override['path']
             for name, override in workspace['dependency_overrides'].items()}
    for directory in workspace['workspace']:
        manifest = ROOT / directory / 'pubspec.yaml'
        if manifest.is_file():
            paths[yaml.safe_load(manifest.read_text())['name']] = manifest.parent

    # DEPS is the SDK's executable Python manifest. Only fetch repositories
    # reached from the server or the plugin runtime, never VM build toolchains.
    deps = {}
    deps['Var'] = lambda key: deps['vars'][key]
    exec((ROOT / 'DEPS').read_text(), deps)
    repos = {ROOT / Path(path).relative_to('sdk'): value
             for path, value in deps['deps'].items()
             if path.startswith('sdk/third_party/pkg/') and isinstance(value, str)}

    def closure(root):
        pending, found = [root], {}
        while pending:
            name = pending.pop()
            if name in found:
                continue
            path = paths[name]
            if not path.exists():
                repo = next(repo for repo in repos if path == repo or repo in path.parents)
                url, revision = repos[repo].rsplit('@', 1)
                subprocess.run(['git', 'init', '-q', repo], check=True)
                subprocess.run(['git', '-C', repo, 'fetch', '-q', '--depth=1', url, revision], check=True)
                subprocess.run(['git', '-C', repo, 'checkout', '-q', 'FETCH_HEAD'], check=True)
            spec = yaml.safe_load((path / 'pubspec.yaml').read_text())
            found[name] = path
            pending.extend(spec.get('dependencies') or {})
        return found

    return closure('analysis_server'), closure('analysis_server_plugin')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sdk', type=Path, help='Extracted SDK to turn into the release')
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    dart = sdk / 'bin/dart'
    server, plugin = packages()
    # Pub supplies language versions, including the defaults for versionless
    # workspace packages. Overrides keep the compiler on exact source revisions.
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        build = Path(directory)
        spec = {'name': 'release_build', 'environment': {'sdk': '^3.15.0-0'},
                'dependencies': {'analysis_server': 'any'},
                'dependency_overrides': {n: {'path': str(p)} for n, p in server.items()}}
        (build / 'pubspec.yaml').write_text(json.dumps(spec))
        subprocess.run([dart, 'pub', 'get', '--offline'], cwd=build, check=True)
        subprocess.run([dart, 'compile', 'aot-snapshot', '-Dbuilt_as_aot=true',
                        '-Danalyzer.release.packages=' + ','.join(sorted(plugin)),
                        '--packages=' + str(build / '.dart_tool/package_config.json'),
                        '-o', sdk / 'bin/snapshots/analysis_server_aot.dart.snapshot',
                        ROOT / 'pkg/analysis_server/bin/server.dart'], check=True)

    for name, source in plugin.items():
        target = sdk / 'analyzer-packages' / name
        shutil.copytree(source / 'lib', target / 'lib')
        shutil.copy2(source / 'pubspec.yaml', target)
        for license in (source / 'LICENSE', source / 'LICENSE.md', ROOT / 'LICENSE'):
            if license.is_file():
                shutil.copy2(license, target / 'LICENSE')
                break


if __name__ == '__main__':
    main()
