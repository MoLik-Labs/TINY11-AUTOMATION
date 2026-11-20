#!/usr/bin/env python3
"""Print a read-only, limited host capability report."""
import argparse
import json
from flow_core import inspect_host


def main() -> None:
    parser = argparse.ArgumentParser(description='Flow Lab read-only host inspection; presence is not compatibility.')
    parser.add_argument('--json', action='store_true', help='Output JSON for diagnostics')
    args = parser.parse_args()
    report = inspect_host()
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print('Flow Lab — read-only host report (not a compatibility certification)')
        print(f"Platform: {report['platform']} / {report['architecture']}")
        print(f"Firmware: {report['firmware']}")
        print(f"Memory: {str(report['memory_mib']) + ' MiB' if report['memory_mib'] is not None else 'unknown'}")
        print(f"Graphical session: {report['session']}")
        for runtime, present in report['runtimes'].items():
            print(f"{runtime.removesuffix('_found').title()}: {'found on PATH' if present else 'not found'}")
        print('Presence does not establish readiness, hardware support or application compatibility.')


if __name__ == '__main__':
    main()
