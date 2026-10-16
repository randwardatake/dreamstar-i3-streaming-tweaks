#!/usr/bin/env python3
"""Rebuild a Module.symvers for a running GKI 5.4 kernel without its sources.

Pairs every exported symbol's ksymtab entry (addresses from /proc/kallsyms,
kptr_restrict=0) with the CRC stored at the same index in __kcrctab of the
uncompressed kernel Image pulled from the boot partition.

usage:
  adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
  adb shell 'grep -E " (_text|__(start|stop)___(ksymtab|kcrctab)(_gpl)?)$" /proc/kallsyms' > sections.txt
  adb shell 'grep " __ksymtab_" /proc/kallsyms' > ksymtab.txt
  extract_kcrctab.py Image sections.txt ksymtab.txt > Module.symvers
"""
import struct
import sys

# 5.4 arm64 without PREL32 relocations: {value, name, namespace} pointers
KSYMTAB_ENTRY = 24


def main(image_path, sections_path, ksymtab_path):
    img = open(image_path, 'rb').read()
    sym = {}
    for line in open(sections_path):
        addr, _, name = line.split()
        sym[name] = int(addr, 16)
    text = sym['_text']

    sections = [
        (sym['__start___ksymtab'], sym['__stop___ksymtab'], sym['__start___kcrctab'], 'EXPORT_SYMBOL'),
        (sym['__start___ksymtab_gpl'], sym['__stop___ksymtab_gpl'], sym['__start___kcrctab_gpl'], 'EXPORT_SYMBOL_GPL'),
    ]

    for line in open(ksymtab_path):
        parts = line.split()
        if len(parts) != 3:
            continue  # symbol owned by a loaded module
        addr = int(parts[0], 16)
        name = parts[2][len('__ksymtab_'):]
        for start, stop, crctab, export in sections:
            if start <= addr < stop and (addr - start) % KSYMTAB_ENTRY == 0:
                index = (addr - start) // KSYMTAB_ENTRY
                crc = struct.unpack_from('<I', img, crctab - text + 4 * index)[0]
                print(f"0x{crc:08x}\t{name}\tvmlinux\t{export}\t")


if __name__ == '__main__':
    main(*sys.argv[1:4])
