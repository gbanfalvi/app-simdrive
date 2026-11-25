#!/usr/bin/env python3
"""Runs the matrix on a simulator created for the run, booted cold, and deletes it once every check passes.

A new simulator has first-boot state an old one lost long ago (alerts, slow accessibility, an unstarted screen), so
changes to opening, booting or the first call need it. A failing run keeps the simulator for investigation and says how
to delete it. Arguments after the options go to matrix.py, such as --only tree,tap.

    Evaluation/fresh.py                                  # the newest iOS runtime's iPhone 17
    Evaluation/fresh.py --device 'iPhone Duo' --only posture
    Evaluation/fresh.py --device 'Apple TV 4K (3rd generation)' --runtime 17.0
"""
import argparse, json, os, subprocess, sys, time

MATRIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'matrix.py')

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--device', default='iPhone 17', help="a device type's name, as simctl list devicetypes shows it")
parser.add_argument('--runtime', help='a runtime version such as 27.2; defaults to the newest that runs the device')
parser.add_argument('--keep', action='store_true', help='keep the simulator even when every check passes')
args, matrix_arguments = parser.parse_known_args()


def simctl(*arguments):
    process = subprocess.run(['xcrun', 'simctl', *arguments], capture_output=True, text=True)
    if process.returncode != 0:
        sys.exit(f"simctl {' '.join(arguments)} failed: {process.stderr.strip()}")
    return process.stdout


def version(runtime):
    return tuple(int(part) for part in runtime['version'].split('.'))


def pick_runtime(device_type):
    runtimes = [runtime for runtime in json.loads(simctl('list', 'runtimes', '-j'))['runtimes']
                if runtime['isAvailable'] and any(t['identifier'] == device_type['identifier'] for t in runtime['supportedDeviceTypes'])]
    if args.runtime:
        runtimes = [runtime for runtime in runtimes if runtime['version'] == args.runtime or runtime['version'].startswith(args.runtime + '.')]
    if not runtimes:
        sys.exit(f"No available runtime{' ' + args.runtime if args.runtime else ''} runs {device_type['name']}.")
    return max(runtimes, key=version)


def main():
    device_types = json.loads(simctl('list', 'devicetypes', '-j'))['devicetypes']
    device_type = next((t for t in device_types if t['name'] == args.device), None)
    if device_type is None:
        sys.exit(f'No device type is named {args.device!r}.')
    runtime = pick_runtime(device_type)
    name = f"simdrive fresh {device_type['name']} {runtime['version']}"
    udid = simctl('create', name, device_type['identifier'], runtime['identifier']).strip()
    print(f'Created {name}: {udid}', flush=True)
    passed = False
    try:
        started = time.monotonic()
        simctl('bootstatus', udid, '-b')
        print(f'Booted in {time.monotonic() - started:.0f} s', flush=True)
        passed = subprocess.run([sys.executable, MATRIX, udid, *matrix_arguments]).returncode == 0
    finally:
        if passed and not args.keep:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
            simctl('delete', udid)
            print(f'Deleted {udid}')
        else:
            print(f'Kept {udid}; once done with it: xcrun simctl shutdown {udid}; xcrun simctl delete {udid}')
    sys.exit(0 if passed else 1)


main()
