#!/usr/bin/env python3
"""Compile CocoaPods' resolved source graph with native Linux Clang/LLD."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shlex
import subprocess
import threading

ROOT = Path(__file__).resolve().parent.parent
SDK = Path(os.environ.get('IOS_SDK', '/missing-sdk'))
PODS = ROOT / 'ios/Pods'
BUILD = ROOT / 'build'
APP = BUILD / 'OmarchyReactNative.app'
stop = threading.Event()
commands = []

def settings(target):
    values = {}
    for line in Path(target['xcconfig']).read_text().splitlines():
        if ' = ' in line:
            key, value = line.split(' = ', 1)
            values[key] = value
    values.update(target['settings'])
    values.update({'PODS_ROOT': str(PODS), 'SRCROOT': str(PODS),
                   'PODS_TARGET_SRCROOT': target['root'], 'inherited': '',
                   'PODS_CONFIGURATION_BUILD_DIR': str(BUILD / 'Pods'),
                   'RCT_METRO_PORT': '8081', 'CONFIGURATION': 'Release',
                   'EFFECTIVE_PLATFORM_NAME': '-iphoneos', 'BUILD_DIR': str(BUILD)})
    def expand(value):
        if isinstance(value, list):
            value = ' '.join(value)
        for _ in range(12):
            new = re.sub(r'\$\(([^)]+)\)|\$\{([^}]+)\}',
                         lambda match: str(values.get(match[1] or match[2], '')), str(value))
            if new == value:
                return new
            value = new
        return value
    return {key: expand(value) for key, value in values.items()}

def flags_for(target, source, extra):
    config = settings(target)
    cpp = source.suffix in ('.mm', '.cpp', '.cc', '.cxx')
    objc = source.suffix in ('.m', '.mm')
    flags = ['-target', 'arm64-apple-ios15.1', '-isysroot', str(SDK),
             '-O1', '-DNDEBUG=1', '-DRCT_DEV=0', '-DRCT_DEBUG=0', '-DCOCOAPODS=1',
             '-fblocks', '-fvisibility=hidden', '-fno-common',
             '-Wno-deprecated-declarations', '-Wno-nullability-completeness']
    if cpp:
        flags += ['-std=c++20', '-stdlib=libc++', '-nostdinc++',
                  '-isystem', str(SDK / 'usr/include/c++/v1')]
    if objc:
        flags += ['-fobjc-arc', '-fobjc-weak', '-fobjc-exceptions']
    headers = shlex.split(config.get('HEADER_SEARCH_PATHS', ''))
    headers += [target['root'], str(PODS / 'Headers/Public'), str(PODS / 'Headers/Private'),
                str(ROOT / 'node_modules/react-native/ReactCommon')]
    # CocoaPods' Xcode header maps also resolve bare headers inside header_dir.
    for header in list(headers):
        directory = Path(header)
        if str(directory).startswith(str(PODS / 'Headers')) and directory.is_dir():
            headers += [str(child) for child in directory.iterdir() if child.is_dir()]
    for path in dict.fromkeys(headers):
        flags += ['-I', path]
    for definition in shlex.split(config.get('GCC_PREPROCESSOR_DEFINITIONS', '')):
        flags += ['-D' + definition]
    prefix = config.get('GCC_PREFIX_HEADER')
    if prefix:
        path = Path(prefix)
        if not path.is_absolute():
            path = PODS / path
        flags += ['-include', str(path)]
    flags += shlex.split((extra or '').replace('$(inherited)', '').replace('${inherited}', ''))
    if source.name == 'RCTCxxBridge.mm':
        # Xcode module/header-map imports supply this protocol definition.
        # Textual Linux compilation must include it explicitly.
        flags += ['-include', str(ROOT / 'node_modules/react-native/ReactCommon/react/nativemodule/core/platform/ios/ReactCommon/RCTTurboModule.h')]
    return flags

def task_for(target, source, extra=None):
    source = Path(source)
    name = hashlib.sha256(str(source).encode()).hexdigest()[:16]
    directory = BUILD / 'objects' / target['name']
    directory.mkdir(parents=True, exist_ok=True)
    obj = directory / (name + '.o')
    command = [os.environ.get('CLANGXX', 'clang++') if source.suffix in ('.mm', '.cpp', '.cc', '.cxx') else os.environ.get('CLANG', 'clang')]
    command += flags_for(target, source, extra)
    command += ['-MD', '-MF', str(obj.with_suffix('.d')), '-c', str(source), '-o', str(obj)]
    commands.append({'directory': str(ROOT), 'file': str(source), 'arguments': command})
    return source, obj, command

def compile_one(task):
    source, obj, command = task
    if stop.is_set():
        return False
    stamp = obj.with_suffix('.command')
    compiler = Path(command[0])
    identity = str(compiler.stat().st_mtime_ns) if compiler.exists() else ''
    digest = hashlib.sha256((json.dumps(command) + identity).encode()).hexdigest()
    dependency = obj.with_suffix('.d')
    if obj.exists() and stamp.exists() and stamp.read_text() == digest and dependency.exists():
        text = dependency.read_text().replace('\\\n', '')
        paths = shlex.split(text.split(':', 1)[1])
        if all(Path(p).exists() and Path(p).stat().st_mtime <= obj.stat().st_mtime for p in paths):
            return True
    process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    obj.with_suffix('.log').write_text(process.stdout + process.stderr)
    if process.returncode:
        stop.set()
        print('\nFAILED: ' + str(source) + '\n' + process.stderr, flush=True)
        return False
    stamp.write_text(digest)
    return True

def main():
    from toolchain import validate
    global SDK
    toolchain = validate()
    SDK = Path(toolchain['IOS_SDK'])
    os.environ.update({key: value for key, value in toolchain.items() if key != 'sdk_version'})
    BUILD.mkdir(exist_ok=True)
    APP.mkdir(exist_ok=True)
    targets = json.loads((ROOT / 'native-build-manifest.json').read_text())
    # Each invocation owns fresh scheduling state, including after a failed build.
    stop.clear()
    commands.clear()
    tasks = []
    objects = {}
    for target in targets:
        objects[target['name']] = []
        for item in target['files']:
            task = task_for(target, item['path'], item['flags'])
            tasks.append(task)
            objects[target['name']].append(task[1])
    app_target = next(target for target in targets if target['name'] == 'React-Core')
    app_task = task_for(app_target, ROOT / 'ios/Main.mm')
    tasks.append(app_task)
    (BUILD / 'compile_commands.json').write_text(json.dumps(commands, indent=2))
    print(f'Compiling {len(tasks)} native files on Linux (3 workers)', flush=True)
    done = 0
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = [executor.submit(compile_one, task) for task in tasks]
        for future in as_completed(futures):
            if future.result():
                done += 1
                if done % 10 == 0:
                    print(f'Compiled/cached {done}/{len(tasks)}', flush=True)
    if stop.is_set():
        raise SystemExit(1)

    archives = []
    for name, paths in objects.items():
        if not paths:
            continue
        archive = BUILD / ('lib' + name + '.a')
        if archive.exists():
            archive.unlink()
        subprocess.run([toolchain['LLVM_AR'], '--format=darwin', 'rcs', str(archive)] + list(map(str, paths)), check=True)
        archives.append(str(archive))
    frameworks = sorted({'Foundation', 'UIKit', 'CoreFoundation', 'JavaScriptCore', 'QuartzCore', 'CoreGraphics', 'CoreText'} |
                        {value for target in targets for value in target['frameworks']})
    libraries = sorted({'objc', 'c++', 'System'} | {value for target in targets for value in target['libraries']})
    link = [toolchain['LD64_LLD'], '-arch', 'arm64',
            '-platform_version', 'ios', '15.1', toolchain['sdk_version'], '-syslibroot', str(SDK),
            '-e', '_main', '-ObjC', '-dead_strip', str(app_task[1])] + archives
    link += [toolchain['IOS_AVAILABILITY_LIBRARY']]
    for framework in frameworks:
        link += ['-framework', framework]
    for framework in sorted({value for target in targets for value in target['weak_frameworks']} - set(frameworks)):
        link += ['-weak_framework', framework]
    for library in libraries:
        link += ['-l' + library]
    link += ['-o', str(APP / 'OmarchyReactNative'), '-map', str(BUILD / 'link.map')]
    (BUILD / 'link-command.json').write_text(json.dumps(link, indent=2))
    print('Linking native React Native application', flush=True)
    subprocess.run(link, check=True)
    info = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleDisplayName': 'React Native Linux',
        'CFBundleExecutable': 'OmarchyReactNative', 'CFBundleIdentifier': 'com.example.omarchy.reactnativedemo',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'OmarchyReactNative',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '2',
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '15.1',
        'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2], 'UIRequiredDeviceCapabilities': ['arm64'],
        'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
                {'UISceneConfigurationName': 'React Native', 'UISceneDelegateClassName': 'ReactSceneDelegate'}]}}
    }
    (APP / 'Info.plist').write_bytes(plistlib.dumps(info))
    assert (APP / 'main.jsbundle').exists(), 'Run node scripts/bundle.js first'
    subprocess.run(['file', str(APP / 'OmarchyReactNative')], check=True)
    print('Built unsigned React Native application: ' + str(APP), flush=True)


if __name__ == "__main__":
    main()
