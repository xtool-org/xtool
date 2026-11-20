"""Validate explicit Linux tools and an externally supplied Apple iOS SDK."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys


def validate(environ=None):
    env = os.environ if environ is None else environ
    result = {}
    for key in ('IOS_SDK', 'IOS_AVAILABILITY_LIBRARY'):
        value = env.get(key)
        if not value:
            raise ValueError(f'Set {key}; see README.md prerequisites')
        path = Path(value).expanduser().resolve()
        if not path.exists():
            raise ValueError(f'{key} does not exist: {path}')
        result[key] = str(path)
    sdk = Path(result['IOS_SDK'])
    try:
        info = plistlib.loads((sdk / 'SDKSettings.plist').read_bytes())
        result['sdk_version'] = str(info['Version'])
    except (OSError, KeyError, plistlib.InvalidFileException) as error:
        raise ValueError('IOS_SDK must contain a valid SDKSettings.plist') from error
    if not str(info.get('CanonicalName', '')).startswith('iphoneos'):
        raise ValueError('IOS_SDK must be an iPhoneOS device SDK, not a simulator SDK')
    header = sdk / 'usr/include/objc/NSObject.h'
    if not header.is_file() or b'NULLcanary' in header.read_bytes():
        raise ValueError('Incomplete SDK extraction: missing or placeholder NSObject.h; preserve Xcode archive hardlinks')
    if not Path(result['IOS_AVAILABILITY_LIBRARY']).is_file():
        raise ValueError('IOS_AVAILABILITY_LIBRARY must be the Apple libclang_rt.ios.a file')
    for key, default in (('CLANG', 'clang'), ('CLANGXX', 'clang++'),
                         ('LD64_LLD', 'ld64.lld'), ('LLVM_AR', 'llvm-ar')):
        requested = env.get(key, default)
        tool = shutil.which(requested, path=env.get('PATH'))
        if not tool:
            raise ValueError(f'{key}: executable not found: {requested}')
        result[key] = str(Path(tool).absolute())
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(validate(), indent=2))
    except ValueError as error:
        print(f'Toolchain: {error}', file=sys.stderr)
        sys.exit(1)
