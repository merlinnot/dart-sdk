"""Package the source-built analyzer and the libraries used by its plugins."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urljoin, urlparse

import yaml


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / '.dart_tool/package_config.json'


def plugin_packages():
    paths = {p['name']: Path(unquote(urlparse(urljoin(CONFIG.as_uri(), p['rootUri'])).path))
             for p in json.loads(CONFIG.read_text())['packages']}
    pending = ['analysis_server_plugin']
    packages = {}
    while pending:
        name = pending.pop()
        if name in packages:
            continue
        source = paths[name]
        packages[name] = source
        spec = yaml.safe_load((source / 'pubspec.yaml').read_text())
        pending.extend(spec.get('dependencies') or {})
    return packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sdk', type=Path)
    sdk = parser.parse_args().sdk.resolve()
    plugin = plugin_packages()
    snapshot = sdk / 'bin/snapshots/analysis_server_aot.dart.snapshot'
    subprocess.run([sdk / 'bin/dart', 'compile', 'aot-snapshot', '-Dbuilt_as_aot=true',
                    '-Danalyzer.release.packages=' + ':'.join(sorted(plugin)),
                    '--packages=' + str(CONFIG), '-o', snapshot.with_suffix('.new'),
                    ROOT / 'pkg/analysis_server/bin/server.dart'], check=True)
    snapshot.with_suffix('.new').replace(snapshot)
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
