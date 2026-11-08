"""Regression checks requiring neither Apple downloads nor a connected device."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load('build-native')
patches = load('patch-dependencies')
from toolchain import validate


class ToolchainTests(unittest.TestCase):
    def test_missing_sdk_is_actionable(self):
        with self.assertRaisesRegex(ValueError, 'Set IOS_SDK'):
            validate({})

    def test_sdk_validation_and_tools_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='sdk fixture ') as tmp:
            root = Path(tmp)
            header = root / 'usr/include/objc/NSObject.h'
            header.parent.mkdir(parents=True)
            header.write_text('@interface NSObject @end')
            (root / 'SDKSettings.plist').write_bytes(plistlib.dumps(
                {'Version': '27.1', 'CanonicalName': 'iphoneos27.1'}))
            runtime = root / 'libclang_rt.ios.a'
            runtime.touch()
            compiler = root / 'compiler stub'
            compiler.write_text('#!/bin/sh\nexit 0\n')
            compiler.chmod(0o755)
            env = {'IOS_SDK': str(root), 'IOS_AVAILABILITY_LIBRARY': str(runtime)}
            env.update({key: str(compiler) for key in ('CLANG', 'CLANGXX', 'LD64_LLD', 'LLVM_AR')})
            self.assertEqual(validate(env)['sdk_version'], '27.1')
            header.write_bytes(b'NULLcanary\0')
            with self.assertRaisesRegex(ValueError, 'placeholder'):
                validate(env)
            header.write_text('@interface NSObject @end')
            (root / 'SDKSettings.plist').write_bytes(plistlib.dumps(
                {'Version': '27.1', 'CanonicalName': 'iphonesimulator27.1'}))
            with self.assertRaisesRegex(ValueError, 'not a simulator'):
                validate(env)


class BuildTests(unittest.TestCase):
    def tearDown(self):
        build.stop.clear()
        build.commands.clear()

    def test_settings_and_per_file_arc_override(self):
        with tempfile.TemporaryDirectory(prefix='pod fixture ') as tmp:
            root = Path(tmp)
            config = root / 'target.xcconfig'
            config.write_text('HEADER_SEARCH_PATHS = "${PODS_TARGET_SRCROOT}/include"\n'
                              'GCC_PREPROCESSOR_DEFINITIONS = $(inherited) FOO=1\n')
            target = {'name': 'fixture', 'xcconfig': str(config),
                      'root': str(root), 'settings': {}}
            flags = build.flags_for(target, root / 'sample.mm', '$(inherited) -fno-objc-arc')
            self.assertIn(str(root / 'include'), flags)
            self.assertIn('-DFOO=1', flags)
            self.assertIn('-std=c++20', flags)
            self.assertGreater(flags.index('-fno-objc-arc'), flags.index('-fobjc-arc'))
            self.assertNotIn('$(inherited)', flags)

    def test_cache_invalidates_when_header_changes_and_failure_stops_build(self):
        with tempfile.TemporaryDirectory(prefix='build fixture ') as tmp:
            root = Path(tmp)
            source = root / 'source.c'
            header = root / 'header.h'
            obj = root / 'source.o'
            for path in (source, header):
                path.touch()
            command = ['/compiler', '-c', str(source)]
            task = (source, obj, command)

            def compile_ok(*args, **kwargs):
                obj.touch()
                escaped = [str(path).replace(' ', r'\ ') for path in (obj, source, header)]
                obj.with_suffix('.d').write_text(f'{escaped[0]}: {escaped[1]} {escaped[2]}\n')
                return subprocess.CompletedProcess(command, 0, '', '')

            with patch.object(build.subprocess, 'run', side_effect=compile_ok) as run:
                self.assertTrue(build.compile_one(task))
                self.assertTrue(build.compile_one(task))
                self.assertEqual(run.call_count, 1)
                os.utime(header, (obj.stat().st_mtime + 1, obj.stat().st_mtime + 1))
                self.assertTrue(build.compile_one(task))
                self.assertEqual(run.call_count, 2)
            with patch.object(build.subprocess, 'run', return_value=subprocess.CompletedProcess(command, 1, '', 'error')), patch('builtins.print'):
                self.assertFalse(build.compile_one(task))
            self.assertTrue(build.stop.is_set())
            self.assertFalse(build.compile_one(task))

    def test_patch_is_idempotent_preserves_hardlinked_cache_and_rejects_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.h'
            cache = Path(tmp) / 'cache.h'
            cache.write_text('before')
            source.hardlink_to(cache)
            patches.replace_once(source, 'before', 'after')
            patches.replace_once(source, 'before', 'after')
            self.assertEqual(cache.read_text(), 'before')
            self.assertEqual(source.read_text(), 'after')
            source.write_text('unexpected upstream update')
            with self.assertRaisesRegex(ValueError, 'Unexpected dependency'):
                patches.replace_once(source, 'before', 'after')

    def test_xcrun_rejects_unknown_queries(self):
        shim = SCRIPTS.parent / 'tools/bin/xcrun'
        result = subprocess.run([str(shim), '--version'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Unsupported', result.stderr)


if __name__ == '__main__':
    unittest.main()
