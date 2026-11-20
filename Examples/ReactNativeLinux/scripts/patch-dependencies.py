"""Apply the two version-specific patches without modifying CocoaPods' cache."""
import json
from pathlib import Path


def replace_once(source, old, new):
    text = source.read_text()
    if text.count(old) == 1 and new not in text:
        # CocoaPods may hardlink read-only source files into its shared cache.
        replacement = source.with_suffix('.linux-tmp')
        replacement.write_text(text.replace(old, new, 1))
        replacement.replace(source)
    elif old in text or text.count(new) != 1:
        raise ValueError(f'Unexpected dependency source: {source}; review the compatibility patch')


def main():
    root = Path(__file__).resolve().parent.parent
    package = root / 'node_modules/react-native/package.json'
    if json.loads(package.read_text())['version'] != '0.77.3':
        raise ValueError('These patches require React Native 0.77.3')
    if '  - fmt (11.0.2)' not in (root / 'ios/Podfile.lock').read_text():
        raise ValueError('These patches require fmt 11.0.2')
    source = root / 'node_modules/react-native/React/CoreModules/RCTWebSocketModule.mm'
    old = '- (void)setContentHandler:(id<RCTWebSocketContentHandler>)handler forSocketID:(NSString *)socketID'
    replace_once(source, old, old.replace('(NSString *)socketID', '(NSNumber *)socketID'))
    # fmt #4177: parse and validate the same stored view, preserving constexpr checks.
    replace_once(root / 'ios/Pods/fmt/include/fmt/base.h',
                 'detail::parse_format_string<true>(str_, checker(s));',
                 'detail::parse_format_string<true>(str_, checker(str_));')


if __name__ == '__main__':
    main()
