#!/usr/bin/env python3
"""Gives every object in a universal static library MH_SUBSECTIONS_VIA_SYMBOLS, without letting the linker split any.

Xcode's build system prelinks each Swift package target, with the static libraries it uses, into one object (ld -r).
If one of the objects pulled in lacks MH_SUBSECTIONS_VIA_SYMBOLS, the merged object lacks it too, and the final link
can't read the Swift classes' metadata in it: "null objc class data". Hand-written assembly lacks the flag, here ONNX
Runtime's MLAS kernels. For each such object this sets the flag and marks every symbol after the first in each section
as an alternate entry (N_ALT_ENTRY), so the linker still keeps each section in one piece: nothing is split off,
reordered or dropped, and no byte or address changes. It refuses an object where that can't hold: a section with bytes
before its first symbol, or a symbol at the very end of a section.

    scripts/engines/subsections.py [--check] <static library>

With --check it changes nothing and fails if any object lacks the flag.
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_SUBSECTIONS_VIA_SYMBOLS = 0x2000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
N_STAB = 0xE0
N_TYPE = 0x0E
N_SECT = 0x0E
N_ALT_ENTRY = 0x0200
CPU_NAMES = {0x0100000C: 'arm64', 0x01000007: 'x86_64'}


def slices(data):
    """(architecture, offset, size) of each archive in a universal file, or of the file itself."""
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic == 0xCAFEBABE:
        count = struct.unpack_from('>I', data, 4)[0]
        for k in range(count):
            cpu, _, offset, size, _ = struct.unpack_from('>iiIII', data, 8 + k * 20)
            yield CPU_NAMES.get(cpu & 0xFFFFFFFF, hex(cpu & 0xFFFFFFFF)), offset, size
    elif magic == 0xCAFEBABF:
        count = struct.unpack_from('>I', data, 4)[0]
        for k in range(count):
            cpu, _, offset, size, _, _ = struct.unpack_from('>iiQQII', data, 8 + k * 32)
            yield CPU_NAMES.get(cpu & 0xFFFFFFFF, hex(cpu & 0xFFFFFFFF)), offset, size
    else:
        yield 'thin', 0, len(data)


def members(data, start, size):
    """(name, offset of the member's data) of each object in an ar archive."""
    if data[start:start + 8] != b'!<arch>\n':
        raise ValueError('not an archive')
    position = start + 8
    end = start + size
    while position + 60 <= end:
        header = data[position:position + 60]
        name = header[0:16].decode('ascii').strip()
        length = int(header[48:58].decode('ascii').strip())
        body = position + 60
        if name.startswith('#1/'):
            name_length = int(name[3:])
            name = data[body:body + name_length].rstrip(b'\0').decode('utf-8')
            body += name_length
        if not name.startswith('__.SYMDEF'):
            yield name, body
        position += 60 + length
        if position % 2:
            position += 1


def patch_object(data, base, name, check_only):
    """Returns how many symbols became alternate entries, or None if the object already has the flag."""
    magic, _, _, _, ncmds, _, flags, _ = struct.unpack_from('<IiiIIIII', data, base)
    if magic != MH_MAGIC_64:
        return None
    if flags & MH_SUBSECTIONS_VIA_SYMBOLS:
        return None
    if check_only:
        raise ValueError(f'{name} lacks MH_SUBSECTIONS_VIA_SYMBOLS')

    sections = []
    symtab = None
    command = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, command)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', data, command + 64)[0]
            for k in range(nsects):
                section = command + 72 + k * 80
                address, size = struct.unpack_from('<QQ', data, section + 32)
                sections.append((address, size))
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from('<II', data, command + 8)
        command += cmdsize

    by_section = {}
    if symtab:
        offset, count = symtab
        for k in range(count):
            entry = base + offset + k * 16
            _, n_type, n_sect, _, value = struct.unpack_from('<IBBHQ', data, entry)
            if n_type & N_STAB or n_type & N_TYPE != N_SECT:
                continue
            by_section.setdefault(n_sect, []).append((value, entry))

    marked = 0
    for index, symbols in by_section.items():
        address, size = sections[index - 1]
        if min(value for value, _ in symbols) != address:
            raise ValueError(f'{name}: section {index} has bytes before its first symbol')
        for value, entry in symbols:
            if size and value == address + size:
                raise ValueError(f'{name}: section {index} has a symbol at its end')
            if value > address:
                desc = struct.unpack_from('<H', data, entry + 6)[0]
                struct.pack_into('<H', data, entry + 6, desc | N_ALT_ENTRY)
                marked += 1

    struct.pack_into('<I', data, base + 24, flags | MH_SUBSECTIONS_VIA_SYMBOLS)
    return marked


def main():
    arguments = sys.argv[1:]
    check_only = arguments[:1] == ['--check']
    if check_only:
        arguments = arguments[1:]
    if len(arguments) != 1:
        sys.exit(__doc__)
    path = arguments[0]
    with open(path, 'rb') as file:
        data = bytearray(file.read())

    changed = False
    try:
        for architecture, start, size in slices(data):
            objects = patched = marked = 0
            for name, body in members(data, start, size):
                objects += 1
                result = patch_object(data, body, f'{architecture} {name}', check_only)
                if result is not None:
                    patched += 1
                    marked += result
            changed = changed or patched > 0
            if check_only:
                print(f'{path} ({architecture}): all {objects} objects have MH_SUBSECTIONS_VIA_SYMBOLS')
            else:
                print(f'{path} ({architecture}): {objects} objects, {patched} given MH_SUBSECTIONS_VIA_SYMBOLS, '
                      f'{marked} symbols made alternate entries')
    except ValueError as error:
        print(f'::error::{path}: {error}')
        sys.exit(1)

    if changed:
        with open(path, 'wb') as file:
            file.write(data)


if __name__ == '__main__':
    main()
