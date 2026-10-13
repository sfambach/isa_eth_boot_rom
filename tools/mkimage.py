#!/usr/bin/env python3
"""Build the flash image of the ISA ETH Boot ROM.

Page 0 holds the option ROM and the settings sector, pages 1..n hold a
read-only hard disk (MBR + one FAT12 partition) with the given files.
Layout constants mirror src/layout.inc.

Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
PolyForm Noncommercial License 1.0.0, see LICENSE.md
"""
import argparse
import ipaddress
import os
import struct
import sys
import time

PAGE_SIZE = 0x4000
ROM_CODE_SIZE = 0x3000
SET_OFFSET = 0x3000
SET_SIZE = 64
SETF_DHCP = 0x01
HDR_MAGIC, HDR_CYLS, HDR_HEADS, HDR_SPT, HDR_FIRSTPAGE = 0x10, 0x17, 0x18, 0x19, 0x1A

HEADS = 4
SPT = 8
SECTOR = 512
SECTORS_PER_PAGE = PAGE_SIZE // SECTOR      # one cylinder per page
PART_START = SPT                            # cylinder 0, head 1, sector 1
ROOT_ENTRIES = 64
FLASH_SIZES_KIB = (128, 256, 512)


def settings_record(hostname, static):
    rec = bytearray(SET_SIZE)
    rec[0:4] = b'NCFG'
    rec[4] = 1
    if static:
        rec[5] = 0
        for off, text in zip((6, 10, 14, 18), static):
            rec[off:off + 4] = ipaddress.IPv4Address(text).packed
    else:
        rec[5] = SETF_DHCP
    name = hostname.encode('ascii')
    if not 0 < len(name) <= 15:
        raise SystemExit('hostname must be 1-15 characters')
    rec[22:22 + len(name)] = name
    rec[63] = (-sum(rec[:63])) & 0xFF
    return bytes(rec)


def dos_name(path):
    base = os.path.basename(path).upper()
    stem, _, ext = base.partition('.')
    if not stem or len(stem) > 8 or len(ext) > 3 or '.' in ext:
        raise SystemExit(f'{path}: not an 8.3 file name')
    return stem.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')


def dos_datetime(stamp):
    t = time.localtime(stamp)
    date = ((max(t.tm_year, 1980) - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    tod = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    return date, tod


def chs(lba):
    cyl, rest = divmod(lba, HEADS * SPT)
    head, sec = divmod(rest, SPT)
    return bytes((head, ((cyl >> 2) & 0xC0) | (sec + 1), cyl & 0xFF))


def fat12_partition(total, files, label, stub):
    """Return a FAT12 file system of `total` sectors holding `files`."""
    root_secs = ROOT_ENTRIES * 32 // SECTOR
    fat_secs = 1
    while True:
        clusters = total - 1 - 2 * fat_secs - root_secs
        if (clusters + 2) * 3 // 2 + 1 <= fat_secs * SECTOR:
            break
        fat_secs += 1
    data_start = 1 + 2 * fat_secs + root_secs

    boot = bytearray(stub)
    boot[3:11] = b'ETHROM  '
    boot[11:36] = struct.pack('<HBHBHHBHHHI', SECTOR, 1, 1, 2, ROOT_ENTRIES, total,
                              0xF8, fat_secs, SPT, HEADS, PART_START)
    boot[36:62] = struct.pack('<IBBBI11s8s', 0, 0x80, 0, 0x29, 0x45544842,
                              label.upper().ljust(11)[:11].encode('ascii'), b'FAT12   ')

    fat = [0xFF8, 0xFFF] + [0] * clusters
    root = bytearray(ROOT_ENTRIES * 32)
    data = bytearray()
    root[0:11] = label.upper().ljust(11)[:11].encode('ascii')
    root[11] = 0x08                         # volume label
    entry = 1
    cluster = 2
    seen = set()
    for path in files:
        name = dos_name(path)
        if name in seen:
            raise SystemExit(f'{path}: duplicate file name')
        seen.add(name)
        if entry >= ROOT_ENTRIES:
            raise SystemExit('too many files for the root directory')
        content = open(path, 'rb').read()
        count = (len(content) + SECTOR - 1) // SECTOR
        if cluster - 2 + count > clusters:
            raise SystemExit(f'ROM drive full while adding {path}')
        first = cluster if count else 0
        for i in range(count):
            fat[cluster + i] = cluster + i + 1 if i < count - 1 else 0xFFF
        cluster += count
        data += content + bytes(-len(content) % SECTOR)
        date, tod = dos_datetime(os.path.getmtime(path))
        root[entry * 32:entry * 32 + 32] = struct.pack(
            '<11sB10sHHHI', name, 0x01, bytes(10), tod, date, first, len(content))
        entry += 1

    fat_bytes = bytearray(fat_secs * SECTOR)
    for i in range(0, len(fat), 2):
        a = fat[i]
        b = fat[i + 1] if i + 1 < len(fat) else 0
        o = i * 3 // 2
        fat_bytes[o:o + 3] = bytes((a & 0xFF, ((a >> 8) & 0x0F) | ((b & 0x0F) << 4), b >> 4))
    image = bytes(boot) + bytes(fat_bytes) * 2 + bytes(root) + bytes(data)
    image += bytes(total * SECTOR - len(image))
    used = cluster - 2
    return image, used, clusters


def build(args):
    rom = bytearray(open(args.rom, 'rb').read())
    if len(rom) != ROM_CODE_SIZE or rom[0:2] != b'\x55\xAA' or rom[HDR_MAGIC:HDR_MAGIC + 4] != b'ETHR':
        raise SystemExit(f'{args.rom}: not an ISA ETH Boot ROM binary')
    stub = open(args.boot, 'rb').read()
    pages = args.size * 1024 // PAGE_SIZE
    cyls = pages - 1
    rom[HDR_CYLS], rom[HDR_HEADS], rom[HDR_SPT], rom[HDR_FIRSTPAGE] = cyls, HEADS, SPT, 1
    rom[-1] = 0
    rom[-1] = (-sum(rom)) & 0xFF

    total = cyls * HEADS * SPT
    part, used, clusters = fat12_partition(total - PART_START, args.files, args.label, stub)
    mbr = bytearray(stub)
    mbr[446:462] = (bytes((0x00,)) + chs(PART_START) + bytes((0x01,)) + chs(total - 1)
                    + struct.pack('<II', PART_START, total - PART_START))
    disk = bytes(mbr) + bytes((PART_START - 1) * SECTOR) + part

    settings = settings_record(args.hostname, args.static)
    page0 = bytes(rom) + settings + b'\xFF' * (PAGE_SIZE - ROM_CODE_SIZE - SET_SIZE)
    image = page0 + disk
    assert len(image) == args.size * 1024
    with open(args.out, 'wb') as f:
        f.write(image)
    print(f'{args.out}: {args.size} KiB flash, ROM drive {used // 2} of {clusters // 2} KiB used, '
          f'{len(args.files)} files', file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--rom', default='build/ethrom.bin')
    p.add_argument('--boot', default='build/bootstub.bin')
    p.add_argument('--size', type=int, default=512, choices=FLASH_SIZES_KIB, help='flash size in KiB')
    p.add_argument('--hostname', default='RETROPC')
    p.add_argument('--static', nargs=4, metavar=('IP', 'MASK', 'GATEWAY', 'DNS'),
                   help='fixed address instead of DHCP')
    p.add_argument('--label', default='ETHBOOTROM')
    p.add_argument('-o', '--out', default='build/ethboot.bin')
    p.add_argument('files', nargs='*', help='files for the ROM drive (8.3 names)')
    build(p.parse_args())


if __name__ == '__main__':
    main()
