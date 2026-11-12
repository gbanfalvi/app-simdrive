#!/usr/bin/env python3
"""Runs simdrive's commands on one booted simulator and checks their effect.

On iPhones the probe app (Evaluation/Probe) logs what it receives; Apple TVs get the checks that need no probe.
Settings are restored to their values at the start. Pasteboard writes reach a syncing host's Mac clipboard, so they
run only with --pasteboard.
"""
import argparse, json, os, re, statistics, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIMDRIVE = os.environ.get('SIMDRIVE', os.path.join(REPO, '.build', 'release', 'simdrive'))
OUTPUT = os.path.join(REPO, '.build', 'evaluation')
PROBE_APP = os.path.join(REPO, '.build', 'probe', 'AXProbe.app')
BUILD_PROBE = os.path.join(REPO, 'Evaluation', 'build-probe.sh')
BUNDLE = 'com.simdrive.axprobe'
TV_SETTINGS_BUNDLE = 'com.apple.TVSettings'
COMMAND_TIMEOUT = 180
# `launch` returns when the process starts; on iOS 27 the app finishes launching about 1.6 s later, and keys sent
# before then reach SpringBoard.
LAUNCH_SETTLE = 3
LAUNCH_SETTLE_MILLISECONDS = LAUNCH_SETTLE * 1000
TREE_ATTEMPTS = 5

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('udid')
parser.add_argument('--only', help='comma-separated sections, such as tree,tap')
parser.add_argument('--pasteboard', action='store_true', help="also write the simulator's pasteboard")
parser.add_argument('--timing', action='store_true', help='time common commands instead of checking them')
parser.add_argument('--runs', type=int, default=10, help='runs per timed command')
parser.add_argument('--label', default='current', help="names the timing file, such as 'baseline'")
args = parser.parse_args()
udid = args.udid
only = set(args.only.split(',')) if args.only else None

_devices = json.loads(subprocess.run(['xcrun', 'simctl', 'list', 'devices', '-j'], capture_output=True, text=True).stdout)['devices']
_runtime = next(runtime for runtime, devices in _devices.items() for device in devices if device['udid'] == udid)
_platform, _major, _minor = re.search(r'(iOS|tvOS)-(\d+)-(\d+)', _runtime).groups()
OS = (int(_major), int(_minor))
IS_TV = _platform == 'tvOS'
os.makedirs(OUTPUT, exist_ok=True)
results = []


def sd(*arguments, daemon=True, stdin=None):
    command = [SIMDRIVE, udid, *arguments] + ([] if daemon else ['--no-daemon'])
    process = subprocess.run(command, capture_output=True, text=True, timeout=COMMAND_TIMEOUT, input=stdin)
    try:
        return json.loads(process.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {'ok': False, 'code': 'unparsed', 'error': (process.stdout + process.stderr)[-400:]}


def simctl(*arguments):
    return subprocess.run(['xcrun', 'simctl', *arguments], capture_output=True, text=True)


def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail else ''), flush=True)


def brief(response):
    return json.dumps(response)[:300]


def output_path(name):
    return os.path.join(OUTPUT, f'{name}-{udid[:8]}.png')


class ProbeLog:
    path = None

    def locate(self):
        self.path = simctl('get_app_container', udid, BUNDLE, 'data').stdout.strip() + '/Documents/probe.log'

    def lines(self):
        try:
            return open(self.path).read().splitlines()
        except FileNotFoundError:
            return []

    def mark(self):
        return len(self.lines())

    def wait(self, mark, pattern, timeout=3.0, count=1):
        deadline = time.time() + timeout
        while True:
            found = [line for line in self.lines()[mark:] if re.search(pattern, line)]
            if len(found) >= count or time.time() > deadline:
                return found
            time.sleep(0.2)


log = ProbeLog()


def nodes(root):
    yield root
    for child in root.get('children', []):
        yield from nodes(child)


def voice_over(tree):
    return [node for node in nodes(tree['result']['root']) if node.get('voiceOver')]


def element(tree, label):
    return next((node for node in voice_over(tree) if node.get('label') == label), None)


def text_field(tree):
    return next((node for node in voice_over(tree) if node.get('type') == 'textField'), None)


def touch_near(lines, phase, x, y, tolerance=0.03):
    for line in lines:
        match = re.search(rf'TOUCH {phase} ([0-9.]+) ([0-9.]+)', line)
        if match and abs(float(match.group(1)) - x) <= tolerance and abs(float(match.group(2)) - y) <= tolerance:
            return True
    return False


def tap_point(node):
    return str(node['point']['x']), str(node['point']['y'])


def launch_probe():
    response = sd('launch', BUNDLE)
    time.sleep(LAUNCH_SETTLE)
    return response


def install_probe():
    if not os.path.exists(PROBE_APP):
        subprocess.run([BUILD_PROBE], check=True, capture_output=True)
    simctl('install', udid, PROBE_APP)
    simctl('terminate', udid, BUNDLE)
    log.locate()
    mark = log.mark()
    response = sd('launch', BUNDLE, '-probeArg', 'matrix')
    check('launch', response.get('ok') and log.wait(mark, r'ARGS .*-probeArg matrix', 6), brief(response))
    time.sleep(LAUNCH_SETTLE)


# MARK: Every device

def basics(doctor):
    process = subprocess.run([SIMDRIVE, 'list'], capture_output=True, text=True)
    check('list', udid in process.stdout and '"ok":true' in process.stdout)
    result = doctor.get('result', {})
    appearances = ('unsupported',) if IS_TV else ('light', 'dark')
    check('doctor', doctor.get('ok') and isinstance(result.get('accessibility'), dict) and result.get('appearance') in appearances,
          json.dumps({key: result.get(key) for key in ('orientation', 'pasteboard', 'keyboard', 'displays', 'accessibility', 'appearance', 'posture')})[:400])
    response = sd('screenshot', output_path('shot'), '--max-dim', '600')
    result = response.get('result', {})
    width, height = result.get('fullWidth', 0), result.get('fullHeight', 0)
    expected = width > height if IS_TV else height > width if not result.get('display') else width > 0
    check('screenshot', response.get('ok') and os.path.exists(result.get('path', '')) and expected,
          f"{width}x{height} -> {result.get('width')}x{result.get('height')}")


def setting_snapshot():
    return sd('setting').get('result', {}).get('settings', {})


def setting_argument(value):
    if isinstance(value, bool):
        return 'on' if value else 'off'
    return str(value)


def restore_settings(initial):
    for name, value in setting_snapshot().items():
        if name in initial and value != initial[name] and initial[name] != 'unsupported':
            sd('setting', name, setting_argument(initial[name]))
    wrong = {name: value for name, value in setting_snapshot().items() if initial.get(name) != value}
    check('settings restored', not wrong, str(wrong))


def stop():
    response = sd('stop')
    check('stop', response.get('ok') and response['result'].get('stopped') is True, brief(response))


# MARK: iPhones, with the probe app

def tree_checks():
    full = sd('tree', '--full')
    check('tree', full.get('ok') and full['result']['app'].get('name') == 'AXProbe',
          brief(full) if not full.get('ok') else str(full['result']['app']))
    if not full.get('ok'):
        return None
    expectations = {
        'Probe': {'traits': ['header'], 'type': 'staticText'},
        'Play': {'type': 'button', 'traits': ['button'], 'hint': 'Plays the video', 'identifier': 'play-button',
                 'inputLabels': ['Play', 'Start'], 'language': 'en-US', 'customActions': ['Delete', 'Share']},
        'Card, 2 lines': {'containerType': 'semanticGroup', 'identifier': 'card'},
        'Volume': {'type': 'slider', 'traits': ['adjustable'], 'value': '25%', 'range': {'max': 1, 'min': 0, 'value': 0.25}},
        'Wi-Fi': {'type': 'switch', 'value': '1'},
        'Dog': {'customContent': [{'label': 'Age', 'value': '3 years'}, {'important': True, 'label': 'Breed', 'value': 'Corgi'}]},
        'Details': {'type': 'button', 'expanded': True if OS >= (18, 0) else None},
        'Disabled': {'traits': ['button', 'notEnabled']},
        'Section': {'headingLevel': 2, 'type': 'staticText'},
        'Glass': {'type': 'button'},
    }
    for label, fields in expectations.items():
        node = element(full, label)
        if node is None:
            check(f'tree element {label}', False, 'missing')
            continue
        wrong = {key: node.get(key) for key, value in fields.items() if node.get(key) != value}
        check(f'tree element {label}', not wrong, f'got {wrong}' if wrong else '')
    email = text_field(full)
    check('tree element text field', email is not None and email.get('placeholder') == 'Email',
          str(email and {key: email.get(key) for key in ('placeholder', 'value', 'label')}))
    dog = element(full, 'Dog')
    if dog:
        inside = dog['frame']['x'] <= dog['point']['x'] <= dog['frame']['x'] + dog['frame']['width']
        check('tree point inside frame', inside, f"point {dog['point']} frame {dog['frame']}")
    rows = [node for node in voice_over(full) if (node.get('label') or '').startswith('Row ')]
    offscreen = [node['label'] for node in rows if node.get('offscreen')]
    check('tree offscreen rows', rows and offscreen, f'{len(offscreen)}/{len(rows)} offscreen')
    keys = [(node.get('label'), json.dumps(node['frame'])) for node in voice_over(full)]
    check('tree no duplicates', len(keys) == len(set(keys)), f'{len(keys)} VoiceOver elements')
    light_checks(full)
    play = element(full, 'Play')
    hit = sd('tree', *tap_point(play))
    check('tree hit test', hit.get('ok') and hit['result']['element'].get('label') == 'Play',
          brief(hit) if not hit.get('ok') else hit['result']['element'].get('label'))
    hit = sd('tree', '0.5', '0.5', daemon=False)
    check('tree hit test --no-daemon', hit.get('ok'), brief(hit) if not hit.get('ok') else '')
    one_shot = sd('tree', '--full', daemon=False)
    check('tree --no-daemon', one_shot.get('ok'), '' if one_shot.get('ok') else brief(one_shot))
    return full


def light_checks(full):
    light = sd('tree')
    elements = light.get('result', {}).get('elements', [])
    same = [(e.get('label'), e['point'], e.get('offscreen')) for e in elements] == \
           [(n.get('label'), n['point'], n.get('offscreen')) for n in voice_over(full)]
    sizes = len(json.dumps(light, separators=(',', ':'))), len(json.dumps(full, separators=(',', ':')))
    check('tree light = full VoiceOver elements', light.get('ok') and same and not any('children' in e or 'frame' in e for e in elements),
          f'{len(elements)} elements, {sizes[0]} vs {sizes[1]} bytes')
    if IS_TV:
        return
    play = next((e for e in elements if e.get('label') == 'Play'), {})
    check('tree light Play fields', play.get('identifier') == 'play-button' and play.get('type') == 'button'
          and 'traits' not in play and 'hint' not in play, json.dumps(play))
    email = next((e for e in elements if e.get('type') == 'textField'), {})
    check('tree light empty field has no value', email.get('placeholder') == 'Email' and 'value' not in email, json.dumps(email))


def tap_checks(full):
    x, y = tap_point(element(full, 'Play'))
    mark = log.mark()
    response = sd('tap', x, y)
    lines = log.wait(mark, r'TAP play')
    check('tap', response.get('ok') and lines and touch_near(log.lines()[mark:], 'began', float(x), float(y)),
          brief(response) if not response.get('ok') else f'at {x},{y}')
    mark = log.mark()
    response = sd('tap', x, y, daemon=False)
    check('tap --no-daemon', response.get('ok') and log.wait(mark, r'TAP play'), '' if response.get('ok') else brief(response))
    # Left of the centered buttons, since a drag that starts on a control does not scroll.
    mark = log.mark()
    response = sd('swipe', '0.15', '0.8', '0.15', '0.3', '--duration', '300')
    log.wait(mark, r'TOUCH ended')
    lines = log.lines()[mark:]
    check('swipe', response.get('ok') and touch_near(lines, 'began', 0.15, 0.8) and touch_near(lines, 'ended', 0.15, 0.3, 0.05),
          '; '.join(line.split(' ', 1)[1] for line in lines if 'TOUCH' in line)[:200])
    time.sleep(1)
    after = sd('tree', '--full')
    before = [n for n in voice_over(full) if (n.get('label') or '').startswith('Row ') and n.get('offscreen')]
    now = [n for n in voice_over(after) if (n.get('label') or '').startswith('Row ') and n.get('offscreen')] if after.get('ok') else before
    check('swipe scrolls (tree offscreen)', after.get('ok') and len(now) < len(before), f'{len(before)} -> {len(now)} offscreen rows')
    sd('swipe', '0.15', '0.3', '0.15', '0.9', '--duration', '200')
    time.sleep(1)


KEYS = [
    (('key', 'a'), r'KEY code=4 chars=97 mods=$', 1),
    (('key', 'f', '--mods', 'cmd,shift'), r'KEY code=9 .*mods=shift,cmd', 1),
    (('key', 'left'), r'KEY code=80 ', 1),
    (('key', 'tab'), r'KEY code=43 ', 1),
    (('key', 'return'), r'KEY code=40 ', 1),
    (('key', 'f5'), r'KEY code=62 ', 1),
    (('key', 'page-down'), r'KEY code=78 ', 1),
    (('key', 'x', '--repeat', '3'), r'KEY code=27 ', 3),
]


def clear_field():
    sd('key', 'a', '--mods', 'cmd')
    sd('key', 'delete')


def key_checks(full):
    for arguments, pattern, count in KEYS:
        mark = log.mark()
        response = sd(*arguments)
        lines = log.wait(mark, pattern, count=count)
        check(' '.join(arguments), response.get('ok') and len(lines) >= count,
              brief(response) if not response.get('ok') else f'{len(lines)} matching presses')
    sd('tap', *tap_point(text_field(full)))
    time.sleep(1)
    mark = log.mark()
    response = sd('type', 'hello, world')
    lines = log.wait(mark, r'TEXT hello, world$', 4)
    texts = [line.split('TEXT ', 1)[1] for line in log.lines()[mark:] if 'TEXT ' in line]
    check('type', response.get('ok') and lines, f'last text {texts[-1:]!r}')
    response = sd('type', 'Grüße')
    check('type non-US (expect unsupported-character)', response.get('code') == 'unsupported-character', brief(response))
    clear_field()


def orientation_checks():
    response = sd('orientation')
    check('orientation read', response.get('ok') and response['result'].get('orientation') == 'portrait', brief(response))
    for name, interface in (('landscape-left', 3), ('landscape-right', 4), ('portrait', 1)):
        mark = log.mark()
        response = sd('orientation', name)
        lines = log.wait(mark, rf'ORIENT interface={interface}', 4)
        check(f'orientation {name}', response.get('ok') and lines,
              brief(response) if not response.get('ok') else (lines[-1].split(' ', 1)[1] if lines else 'probe saw no rotation'))
        if name == 'portrait':
            continue
        time.sleep(1)
        full = sd('tree', '--full')
        play = element(full, 'Play') if full.get('ok') else None
        if not play:
            check(f'tree {name}', False, brief(full))
            continue
        hit = sd('tree', *tap_point(play))
        check(f'tree hit test {name}', hit.get('ok') and hit['result']['element'].get('label') == 'Play', brief(hit)[:160])
        mark = log.mark()
        sd('tap', *tap_point(play))
        check(f'tap {name}', log.wait(mark, r'TAP play'))
    time.sleep(1)


def button_checks():
    up = sd('button', 'volume-up')
    shot = output_path('volume')
    sd('screenshot', shot, '--max-dim', '500')
    time.sleep(2)
    down = sd('button', 'volume-down', '--repeat', '2')
    check('button volume-up/down', up.get('ok') and down.get('ok'), f'HUD screenshot {shot}')
    mark = log.mark()
    response = sd('button', 'home')
    check('button home', response.get('ok') and log.wait(mark, r'SCENE background', 4), brief(response))
    time.sleep(1)
    home = sd('tree', '--full')
    check('tree home screen', home.get('ok') and home['result']['app'].get('name') != 'AXProbe' and voice_over(home),
          brief(home) if not home.get('ok') else f"app {home['result']['app']}, {len(voice_over(home))} VoiceOver elements")
    mark = log.mark()
    launch_probe()
    check('launch from home', log.wait(mark, r'SCENE active', 4))
    mark = log.mark()
    response = sd('swipe', '0.5', '0.999', '0.5', '0.5', '--edge', 'bottom')
    check('swipe --edge bottom (go home)', response.get('ok') and log.wait(mark, r'SCENE background', 4), brief(response))
    launch_probe()
    mark = log.mark()
    response = sd('button', 'lock')
    check('button lock', response.get('ok') and log.wait(mark, r'SCENE (inactive|background)', 4), brief(response))
    time.sleep(1.5)
    mark = log.mark()
    sd('button', 'lock')
    time.sleep(1.5)
    sd('swipe', '0.5', '0.999', '0.5', '0.3', '--edge', 'bottom')
    unlocked = log.wait(mark, r'SCENE active', 5)
    check('unlock (lock, edge swipe)', unlocked)
    if not unlocked:
        launch_probe()
    mark = log.mark()
    response = sd('button', 'siri')
    inactive = log.wait(mark, r'SCENE inactive', 4)
    check('button siri', response.get('ok'), brief(response) + (' probe went inactive' if inactive else ' probe stayed active'))
    time.sleep(1)
    sd('button', 'home')
    time.sleep(1)
    mark = log.mark()
    launch_probe()
    log.wait(mark, r'SCENE active', 4)


def misc_checks(is_foldable):
    shot = output_path('run')
    steps = json.dumps([f'launch {BUNDLE}', f'wait {LAUNCH_SETTLE_MILLISECONDS}', 'key b', f'screenshot {shot}'])
    mark = log.mark()
    response = sd('run', '-', stdin=steps)
    check('run', response.get('ok') and log.wait(mark, r'KEY code=5 ') and os.path.exists(shot), brief(response)[:200])
    response = sd('run', '-', stdin=json.dumps(['wait 10', 'bogus']))
    check('run rejects an invalid step (expect step-invalid)', response.get('code') == 'step-invalid', brief(response))
    response = sd('pasteboard')
    items = response.get('result', {}).get('items')
    check('pasteboard read', response.get('ok') and isinstance(items, list), brief(response)[:120])
    if not is_foldable:
        response = sd('posture')
        check('posture (expect posture-unsupported)', response.get('code') == 'posture-unsupported', brief(response))


SETTINGS = [
    ('appearance', 'dark', 'light', r'style=2', r'style=1'),
    ('text-size', 'accessibility-large', 'large', r'size=UICTContentSizeCategoryAccessibilityL ', r'size=UICTContentSizeCategoryL '),
    ('increase-contrast', 'on', 'off', r'darkerColors=1 .*contrast=1', r'darkerColors=0 .*contrast=0'),
    ('bold-text', 'on', 'off', r'boldText=1 .*weight=1', r'boldText=0 .*weight=0'),
    ('reduce-motion', 'on', 'off', r'reduceMotion=1', r'reduceMotion=0'),
    ('reduce-transparency', 'on', 'off', r'reduceTransparency=1', r'reduceTransparency=0'),
    ('show-borders', 'on', 'off', r'buttonShapes=1' + (r'.*showBorders=1' if OS >= (26, 1) else ''),
     r'buttonShapes=0' + (r'.*showBorders=0' if OS >= (26, 1) else '')),
    ('on-off-labels', 'on', 'off', r'onOffLabels=1', r'onOffLabels=0'),
    ('differentiate-without-color', 'on', 'off', r'differentiateWithoutColor=1', r'differentiateWithoutColor=0'),
    ('prefer-horizontal-text', 'on', 'off', r'horizontalText=1', r'horizontalText=0'),
    ('smart-invert', 'on', 'off', r'invertColors=1', r'invertColors=0'),
    ('grayscale', 'on', 'off', r'grayscale=1', r'grayscale=0'),
    ('autoplay-video-previews', 'off', 'on', r'videoAutoplay=0', r'videoAutoplay=1'),
    ('autoplay-animated-images', 'off', 'on', r'animatedImages=0', r'animatedImages=1'),
    ('non-blinking-cursor', 'on', 'off', r'nonBlinkingCursor=1', r'nonBlinkingCursor=0'),
]
MINIMUM_OS = {'non-blinking-cursor': 18, 'glass-tint': 26}


def status_wait(mark, pattern, timeout=4):
    return log.wait(mark, r'STATUS .*' + pattern, timeout)


def setting_checks():
    response = sd('setting')
    check('setting (list)', response.get('ok'), json.dumps(response.get('result', response))[:400])
    for name, value, default, on, off in SETTINGS:
        if name in MINIMUM_OS and OS[0] < MINIMUM_OS[name]:
            response = sd('setting', name, value)
            check(f'setting {name} (expect setting-unsupported)', response.get('code') == 'setting-unsupported', brief(response))
            continue
        for target, pattern, daemon in ((value, on, True), (default, off, False)):
            mark = log.mark()
            response = sd('setting', name, target, daemon=daemon)
            seen = status_wait(mark, pattern)
            check(f'setting {name} {target}', response.get('ok') and seen,
                  brief(response) if not response.get('ok') else ('app saw it' if seen else 'app did not see it'))
    sd('setting', 'reduce-motion', 'on')
    mark = log.mark()
    response = sd('setting', 'prefer-cross-fade', 'on')
    seen = status_wait(mark, r'crossFade=1')
    check('setting prefer-cross-fade on (with reduce-motion)', response.get('ok') and seen, 'app saw it' if seen else 'app did not see it')
    sd('setting', 'prefer-cross-fade', 'off')
    sd('setting', 'reduce-motion', 'off')
    response = sd('setting', 'glass-tint', '0.8')
    if OS[0] < MINIMUM_OS['glass-tint']:
        check('setting glass-tint (expect setting-unsupported)', response.get('code') == 'setting-unsupported', brief(response))
    else:
        check('setting glass-tint 0.8 (read back)', response.get('ok') and response['result'].get('value') == 0.8, brief(response))


def pasteboard_write_checks(full):
    token = f'simdrive pasteboard {OS[0]}.{OS[1]}'
    response = sd('pasteboard', token)
    check('pasteboard write', response.get('ok'), brief(response) if not response.get('ok') else '')
    response = sd('pasteboard')
    check('pasteboard read back', response.get('ok') and token in json.dumps(response.get('result')), brief(response)[:160])
    sd('tap', *tap_point(text_field(full)))
    time.sleep(1)
    clear_field()
    mark = log.mark()
    response = sd('key', 'v', '--mods', 'cmd')
    lines = log.wait(mark, rf'TEXT {re.escape(token)}$', 4)
    check('pasteboard pasted in app (cmd-v)', response.get('ok') and lines, 'app saw it' if lines else 'app did not see it')
    clear_field()


# MARK: Foldables

def posture_checks(doctor):
    displays = {display['role']: display['index'] for display in doctor['result'].get('displays', [])}
    original = sd('posture')
    check('posture read', original.get('ok') and original['result'].get('posture') in ('closed', 'half', 'open'), brief(original))
    for posture in ('closed', 'half', 'open'):
        response = sd('posture', posture)
        check(f'posture {posture}', response.get('ok') and response['result'].get('posture') == posture, brief(response))
        shot = sd('screenshot', output_path(f'posture-{posture}'), '--max-dim', '400')
        expected = displays.get('primary') if posture == 'closed' else displays.get('primary-1')
        check(f'screenshot follows {posture}', shot.get('ok') and shot['result'].get('display') == expected,
              f"display {shot.get('result', {}).get('display')}, expected {expected}")
        tree = sd('tree')
        check(f'tree {posture}', tree.get('ok') and tree['result'].get('display') == expected, brief(tree)[:160])
    if original.get('ok'):
        sd('posture', original['result']['posture'])


# MARK: Apple TV

def tv_checks():
    # The home screen may have one focusable app; Settings has a list.
    sd('launch', TV_SETTINGS_BUNDLE)
    time.sleep(LAUNCH_SETTLE)
    for _ in range(TREE_ATTEMPTS):
        light = sd('tree')
        if light.get('code') != 'accessibility-translation':
            break
        time.sleep(1)
    elements = light.get('result', {}).get('elements', [])
    check('tree', light.get('ok') and elements, brief(light) if not light.get('ok') else f'{len(elements)} elements')
    full = sd('tree', '--full')
    if full.get('ok'):
        light_checks(full)
    # Settings focuses its list on the first remote press.
    def focused_after(button):
        sd('button', button)
        time.sleep(1)
        return [e.get('label') for e in sd('tree').get('result', {}).get('elements', []) if e.get('focused')]

    focused = focused_after('down')
    check('tree focus', len(focused) == 1, str(focused))
    moved = focused_after('down')
    check('button down moves focus', moved and moved != focused, f'{focused} -> {moved}')
    hit = sd('tree', '0.5', '0.5')
    check('tree hit test', hit.get('ok'), brief(hit)[:160])
    response = sd('tap', '0.5', '0.5')
    check('tap (expect no-touchscreen)', response.get('code') == 'no-touchscreen', brief(response))
    response = sd('orientation', 'landscape-left')
    check('orientation (expect orientation-unsupported)', response.get('code') == 'orientation-unsupported', brief(response))
    response = sd('setting', 'appearance', 'dark')
    check('setting appearance (expect setting-unsupported)', response.get('code') == 'setting-unsupported', brief(response))
    for value, expected in (('on', True), ('off', False)):
        response = sd('setting', 'reduce-motion', value)
        check(f'setting reduce-motion {value}', response.get('ok') and response['result'].get('value') is expected, brief(response))
    sd('button', 'home')


# MARK: Timing

def timed(name, command, runs, before=None):
    durations, failures = [], 0
    for _ in range(runs):
        if before:
            before()
        start = time.perf_counter()
        ok = command().get('ok')
        durations.append(time.perf_counter() - start)
        failures += 0 if ok else 1
    median = statistics.median(durations)
    print(f'{name:28} median {median * 1000:6.0f} ms  min {min(durations) * 1000:6.0f}  max {max(durations) * 1000:6.0f}'
          + (f'  {failures} failed' if failures else ''), flush=True)
    return name, {'median': round(median, 3), 'min': round(min(durations), 3), 'max': round(max(durations), 3), 'failures': failures}


def timing(is_touch):
    runs, cold_runs = args.runs, max(1, args.runs // 3)
    app = TV_SETTINGS_BUNDLE if IS_TV else BUNDLE

    def relaunch():
        sd('launch', app)
        time.sleep(LAUNCH_SETTLE)

    sd('doctor')
    cases = [
        timed('tree', lambda: sd('tree'), runs),
        timed('tree --full', lambda: sd('tree', '--full'), runs),
        timed('tree 0.5 0.5', lambda: sd('tree', '0.5', '0.5'), runs),
        timed('tree after launch', lambda: sd('tree'), runs, before=relaunch),
        timed('doctor', lambda: sd('doctor'), runs),
        timed('doctor cold', lambda: sd('doctor'), cold_runs, before=lambda: sd('stop')),
    ]
    if is_touch:
        header = element(sd('tree', '--full'), 'Probe') if not IS_TV else None
        point = tap_point(header) if header else ('0.5', '0.02')
        cases += [timed('tap', lambda: sd('tap', *point), runs), timed('tap --no-daemon', lambda: sd('tap', *point, daemon=False), runs)]
        cases.append(timed('tree --no-daemon', lambda: sd('tree', daemon=False), runs))
    path = os.path.join(OUTPUT, f'timing-{udid[:8]}-{args.label}.json')
    with open(path, 'w') as file:
        json.dump(dict(cases), file, indent=2)
    print(f'wrote {path}')


# MARK: Main

def want(section):
    return only is None or section in only


def main():
    print(f'{_platform} {OS[0]}.{OS[1]}', flush=True)
    doctor = sd('doctor')
    if not doctor.get('ok'):
        sys.exit(f'doctor failed: {brief(doctor)}')
    is_foldable = doctor['result'].get('posture') not in ('unsupported', None)
    if not IS_TV:
        install_probe()
        sd('orientation', 'portrait')
    if args.timing:
        timing(is_touch=not IS_TV)
        sd('stop')
        return
    initial = setting_snapshot()
    if want('basics'):
        basics(doctor)
    if IS_TV:
        if want('tv'):
            tv_checks()
    else:
        full = tree_checks() if want('tree') or want('tap') or want('keys') or args.pasteboard else None
        if full and args.pasteboard:
            pasteboard_write_checks(full)
        if full and want('tap'):
            tap_checks(full)
        if full and want('keys'):
            key_checks(full)
        if want('misc'):
            misc_checks(is_foldable)
        if is_foldable and want('posture'):
            posture_checks(doctor)
        if not is_foldable and want('orientation'):
            orientation_checks()
        if not is_foldable and want('buttons'):
            button_checks()
        if want('settings'):
            setting_checks()
    restore_settings(initial)
    stop()
    failed = [result for result in results if not result[1]]
    print(f'\n{len(results) - len(failed)}/{len(results)} passed')
    sys.exit(1 if failed else 0)


main()
