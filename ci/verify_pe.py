"""Read PE metadata without loading the DLL. Standard library only."""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect(path):
    data = Path(path).read_bytes()
    def u16(p): return struct.unpack_from('<H', data, p)[0]
    def u32(p): return struct.unpack_from('<I', data, p)[0]
    if data[:2] != b'MZ': raise ValueError('Not a PE file')
    h = u32(60)
    if data[h:h+4] != b'PE\0\0': raise ValueError('Invalid PE signature')
    o = h + 24
    if u16(o) != 0x20b: raise ValueError('PE32+ required')
    count = u16(h+6)
    sections = []
    for i in range(count):
        p = o + u16(h+20) + i*40
        vs, va, size, raw = struct.unpack_from('<IIII', data, p+8)
        sections.append((va, max(vs, size), raw, size))
    def offset(rva):
        if rva < u32(o+60): return rva
        for va, size, raw, disk in sections:
            if va <= rva < va+size and rva-va < disk: return raw+rva-va
        raise ValueError('Unmapped PE RVA')
    def string(rva):
        p = offset(rva)
        return data[p:data.index(0, p)].decode('ascii')
    def directory(index):
        if u32(o+108) <= index: return (0, 0)
        return struct.unpack_from('<II', data, o+112+8*index)
    exports = []
    rva, _ = directory(0)
    if rva:
        p = offset(rva)
        names = u32(p+32)
        exports = [string(u32(offset(names)+i*4)) for i in range(u32(p+24))]
    imports = []
    rva, size = directory(1)
    if rva:
        for i in range(size//20):
            p = offset(rva+i*20)
            if not any(data[p:p+20]): break
            imports.append(string(u32(p+12)).lower())
        else: raise ValueError('Unterminated import directory')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
            'machine': u16(h+4), 'dll': bool(u16(h+22) & 0x2000),
            'clr': bool(directory(14)[0]), 'delay_imports': bool(directory(13)[0]),
            'exports': sorted(exports), 'imports': sorted(imports),
            'probe_markers': [m for m in ('ShutdownProbe: static command cleanup entered',
                                         'ShutdownProbe: command valid_before=',
                                         'ShutdownProbe: command valid_after=') if m.encode('ascii') in data]}


def validate(info, lock, require_probe=False):
    if info['machine'] != 0x8664 or not info['dll'] or info['clr']:
        raise ValueError('Expected native AMD64 DLL without CLR')
    if info['delay_imports']: raise ValueError('Unexpected delay-load dependencies need review')
    if info['exports'] != sorted(lock['expected_exports']):
        raise ValueError('Export ABI differs from reviewed baseline')
    if info['imports'] != sorted(lock['expected_imports']):
        raise ValueError('Import dependencies differ from reviewed baseline')
    if require_probe and len(info['probe_markers']) != 3:
        raise ValueError('Diagnostic markers missing from candidate DLL')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('dll', type=Path)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--require-probe', action='store_true')
    args = parser.parse_args()
    info = inspect(args.dll)
    validate(info, json.loads(args.lock.read_text(encoding='utf-8')), args.require_probe)
    text = json.dumps(info, indent=2)
    if args.output: args.output.write_text(text+'\n', encoding='utf-8')
    print(text)


if __name__ == '__main__': main()
