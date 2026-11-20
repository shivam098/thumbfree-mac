#!/usr/bin/env python3
"""Fails unless an engine's notice covers everything linked into its static library.

Every global symbol the library defines (nm -gjU) goes into a group by who wrote it: a C++ symbol's outermost namespace
or class (or the function, in the global namespace), read from its mangled name; a C symbol's prefix, up to its first
underscore. Each group must be claimed by a line of the engine's claims file (CSherpaOnnx.claims explains the columns),
and each claiming line's license files must be in the notice word for word. A group nobody claims fails the check, so a
library that's linked in but missing from the notice can't pass unnoticed.

    scripts/engines/check-notice.py <static library> <notice> <claims file>

License files are looked up from the current folder.
"""

import re
import subprocess
import sys


class Mangled:
    """The first component of an Itanium-mangled name (after its "_Z"): a namespace, class or function, "std",
    "(builtin)" for type information of a built-in type, or "(operator)" for an operator outside any namespace."""

    def __init__(self, text):
        self.s = text
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < len(self.s) else ''

    def source_name(self):
        j = self.i
        while j < len(self.s) and self.s[j].isdigit():
            j += 1
        length = int(self.s[self.i:j])
        name = self.s[j:j + length]
        self.i = j + length
        return name

    def skip_number(self):
        if self.peek() == 'n':
            self.i += 1
        while self.peek().isdigit():
            self.i += 1

    def skip_qualifiers(self):
        while self.peek() and self.peek() in 'rVKRO':
            self.i += 1

    def prefix_first(self):
        c = self.peek()
        if c.isdigit():
            return self.source_name()
        if c == 'S':
            d = self.peek(1)
            return 'std' if d and d in 'tabdios' else '(substitution)'
        if c == 'T':
            return '(template parameter)'
        if c == 'D':
            return '(decltype)'
        if c == 'Z':
            self.i += 1
            return self.encoding()
        if c == 'U':
            return '(unnamed)'
        if c == 'L':
            self.i += 1
            return self.prefix_first()
        return None

    def type_first(self):
        while True:
            c = self.peek()
            if c == 'N':
                self.i += 1
                self.skip_qualifiers()
                return self.prefix_first()
            if c and c in 'PROKVr':
                self.i += 1
                continue
            if c in ('F', 'A', 'M'):
                return '(builtin)'
            if c == 'D':
                return '(decltype)' if self.peek(1) in ('t', 'T') else '(builtin)'
            if 'a' <= c <= 'z':
                return '(builtin)'
            return self.prefix_first()

    def name_first(self):
        c = self.peek()
        if c == 'N':
            self.i += 1
            self.skip_qualifiers()
            return self.prefix_first()
        if c == 'L':
            self.i += 1
            return self.name_first()
        if 'a' <= c <= 'z':
            return '(operator)'
        return self.prefix_first()

    def encoding(self):
        two = self.s[self.i:self.i + 2]
        if two in ('TV', 'TT', 'TI', 'TS', 'TC'):
            self.i += 2
            return self.type_first()
        if two == 'Th':
            self.i += 2
            self.skip_number()
            self.i += 1
            return self.encoding()
        if two == 'Tv':
            self.i += 2
            self.skip_number()
            self.i += 1
            self.skip_number()
            self.i += 1
            return self.encoding()
        if two in ('GV', 'GR', 'TW', 'TH'):
            self.i += 2
            return self.name_first()
        return self.name_first()


MANGLED = re.compile(r'_{2,3}Z(.*)')
OBJC = re.compile(r'OBJC_(?:CLASS|METACLASS|IVAR|EHTYPE)_\$_([A-Za-z0-9_]+?)(?:\.|$)')
C_PREFIX = re.compile(r'_*[A-Za-z0-9]+')


def group_of(symbol):
    """The group of a Mach-O symbol (C names have a leading underscore, blocks a few more: "___ZN..._block_invoke")."""
    mangled = MANGLED.fullmatch(symbol)
    if mangled:
        try:
            owner = Mangled(mangled.group(1)).encoding()
        except (ValueError, RecursionError):
            owner = None
        if owner == '(operator)':
            return '(operator) ' + symbol
        return owner if owner else '(unparsed) ' + symbol

    name = symbol[1:] if symbol.startswith('_') else symbol
    objc = OBJC.match(name)
    if objc:
        return 'ObjC ' + objc.group(1)

    prefix = C_PREFIX.match(name)
    if prefix and len(prefix.group(0).lstrip('_')) >= 3:
        return 'C ' + prefix.group(0)
    return 'C ' + name


def defined_symbols(library):
    """The global symbols the library defines, in all its architectures (nm lists only the Mac's own by default)."""
    output = subprocess.run(['nm', '-gjU', '-arch', 'all', library], check=True, capture_output=True,
                            text=True).stdout
    return {line.strip() for line in output.splitlines() if line.strip() and not line.strip().endswith(':')}


def read_claims(path):
    claims = []
    with open(path, encoding='utf-8') as lines:
        for number, line in enumerate(lines, 1):
            line = line.rstrip('\r\n')
            if not line or line.startswith('#'):
                continue
            columns = line.split('\t')
            if len(columns) != 4:
                sys.exit(f'{path}:{number}: expected 4 tab-separated columns, found {len(columns)}')
            name, groups, files, section = columns
            claims.append({
                'name': name,
                'groups': re.compile(groups),
                'files': [] if files == '-' else files.split(),
                'line': None if section == '-' else section,
                'claimed': 0,
                'symbols': 0,
            })
    return claims


def read(path):
    with open(path, 'rb') as file:
        return file.read()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    library, notice_path, claims_path = sys.argv[1:]
    claims = read_claims(claims_path)
    notice = read(notice_path)
    problems = []

    for claim in claims:
        texts = []
        for path in claim['files']:
            text = read(path)
            texts.append(text)
            if text not in notice:
                problems.append(f"{claim['name']}: the notice doesn't have {path} word for word")
        if claim['line'] and not any(claim['line'].encode() in text for text in texts):
            problems.append(f"{claim['name']}: {' '.join(claim['files'])} has no line '{claim['line']}'")

    groups = {}
    for symbol in defined_symbols(library):
        groups.setdefault(group_of(symbol), []).append(symbol)

    unclaimed = []
    for group, symbols in groups.items():
        claim = next((c for c in claims if c['groups'].fullmatch(group)), None)
        if claim is None:
            unclaimed.append((group, symbols))
        else:
            claim['claimed'] += 1
            claim['symbols'] += len(symbols)

    count = sum(len(symbols) for symbols in groups.values())
    print(f'{library}: {count} symbols in {len(groups)} groups')
    for claim in claims:
        print(f"{claim['symbols']:7} symbols in {claim['claimed']:4} groups: {claim['name']}")

    unclaimed.sort(key=lambda item: -len(item[1]))
    for group, symbols in unclaimed:
        problems.append(f'{len(symbols)} symbols that no line of {claims_path} claims, in group {group}, such as '
                        f'{sorted(symbols)[0]}')

    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        sys.exit(1)
    print('Every group of symbols is claimed, and the notice has every claimed license file word for word.')


if __name__ == '__main__':
    main()
