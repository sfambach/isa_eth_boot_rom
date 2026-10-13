"""Minimal PC model for testing the ISA ETH Boot ROM without hardware.

Runs 8086 code under Unicorn and models what the ROM and the tools touch:
an RTL8019AS (page 0 ID, page 3 config, BPAGE, FMWP, 93C46 EEPROM), an
SST39SF040 behind the paged 16 KiB ROM window, a few BIOS services and the
DOS calls the tools use.

Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
PolyForm Noncommercial License 1.0.0, see LICENSE.md
"""
from unicorn import (Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN,
                     UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE)
from unicorn.x86_const import *

IOS_BASES = [0x300, 0x320, 0x340, 0x360, 0x380, 0x3A0, 0x3C0, 0x3E0,
             0x200, 0x220, 0x240, 0x260, 0x280, 0x2A0, 0x2C0, 0x2E0]
IRQS = [2, 3, 4, 5, 10, 11, 12, 15]
STUB_SEG = 0xF000


class Flash:
    """SST39SF040 command set as far as the tools use it."""

    def __init__(self, size=512 * 1024, dev_id=0xB7):
        self.mem = bytearray(b'\xFF' * size)
        self.dev_id = dev_id
        self.state = 0
        self.id_mode = False
        self.writes_enabled = lambda: True
        self.ops = []

    def read(self, addr):
        addr %= len(self.mem)
        if self.id_mode:
            return (0xBF, self.dev_id)[addr & 1]
        return self.mem[addr]

    def write(self, addr, value):
        if not self.writes_enabled():
            return
        addr %= len(self.mem)
        cmd = addr & 0x7FFF
        s = self.state
        if value == 0xF0 and s in (0, 1):
            self.id_mode = False
            self.state = 0
        elif s == 'program':
            self.mem[addr] &= value
            self.ops.append(('program', addr))
            self.state = 0
        elif s in (0, 3) and cmd == 0x5555 and value == 0xAA:
            self.state = 1 if s == 0 else 4
        elif s in (1, 4) and cmd == 0x2AAA and value == 0x55:
            self.state = 2 if s == 1 else 5
        elif s == 2 and cmd == 0x5555 and value == 0xA0:
            self.state = 'program'
        elif s == 2 and cmd == 0x5555 and value == 0x80:
            self.state = 3
        elif s == 2 and cmd == 0x5555 and value == 0x90:
            self.id_mode = True
            self.state = 0
        elif s == 5 and value == 0x30:
            base = addr & ~0xFFF
            self.mem[base:base + 0x1000] = b'\xFF' * 0x1000
            self.ops.append(('erase', base))
            self.state = 0
        else:
            self.state = 0


class Eeprom93C46:
    """93C46 in 16-bit organisation, driven through 9346CR bit-banging."""

    def __init__(self, words=None):
        self.words = list(words or [0xFFFF] * 64)
        self.cs = self.sk = self.di = 0
        self.do = 1
        self.reset()
        self.ewen = False

    def reset(self):
        self.bits = []
        self.mode = 'cmd'
        self.out = []

    def pins(self, cs, sk, di):
        if not cs:
            if self.cs and self.mode == 'data' and self.op == 'write':
                if len(self.bits) == 16 and self.ewen:
                    self.words[self.addr] = int(''.join(map(str, self.bits)), 2)
            self.reset()
            self.do = 1
        rising = cs and sk and not self.sk
        self.cs, self.sk, self.di = cs, sk, di
        if not rising:
            return
        if self.mode == 'cmd':
            if not self.bits and not di:
                return              # waiting for the start bit
            self.bits.append(di)
            if len(self.bits) == 9:
                op = self.bits[1] * 2 + self.bits[2]
                addr = int(''.join(map(str, self.bits[3:])), 2)
                self.bits = []
                self.addr = addr
                if op == 2:
                    self.op = 'read'
                    self.mode = 'data'
                    w = self.words[addr]
                    self.out = [(w >> (15 - i)) & 1 for i in range(16)]
                    self.do = 0
                elif op == 1:
                    self.op = 'write'
                    self.mode = 'data'
                elif op == 0:
                    sub = addr >> 4
                    if sub == 3:
                        self.ewen = True
                    elif sub == 0:
                        self.ewen = False
                    self.mode = 'done'
                    self.op = 'misc'
                else:
                    self.mode = 'done'
                    self.op = 'erase'
        elif self.mode == 'data':
            if self.op == 'read':
                self.do = self.out.pop(0) if self.out else 0
            else:
                self.bits.append(di)


class Rtl8019:
    def __init__(self, base=0x300, irq=3, romseg=0xD000, page_mode=True,
                 mode='jumperless', eeprom=None):
        self.base = base
        self.cr = 0x21
        self.bpage = 0
        self.eem = 0
        self.fmwp = 0                   # 0 off, 1 after 57h, 2 enabled
        ios = IOS_BASES.index(base)
        self.config1 = 0x80 | (IRQS.index(irq) << 4) | ios
        if romseg is None:
            bs = 0
        elif page_mode:
            bs = 0x18 | ((romseg - 0xC000) // 0x400)
        else:
            bs = 0x10 | ((romseg - 0xC000) // 0x400)
        self.config2 = bs
        self.config0 = 0x08 if mode == 'dip' else 0
        self.config3 = 0x80 if mode == 'pnp' else 0
        self.romseg = romseg
        self.page_mode = page_mode
        self.eeprom = Eeprom93C46(eeprom)
        self.writes = []
        self.on_bpage = lambda: None

    def page(self):
        return self.cr >> 6

    def io_read(self, off):
        if off == 0:
            return self.cr
        p = self.page()
        if p == 0:
            return {0x0A: 0x50, 0x0B: 0x70}.get(off, 0)
        if p == 3:
            if off == 1:
                v = self.eem << 6
                if self.eem == 2:
                    v |= (self.eeprom.cs << 3) | (self.eeprom.sk << 2) | (self.eeprom.di << 1) | self.eeprom.do
                return v
            return {2: self.bpage, 3: self.config0, 4: self.config1, 5: self.config2,
                    6: self.config3}.get(off, 0)
        return 0

    def io_write(self, off, value):
        self.writes.append((off, value, self.page()))
        if off == 0:
            if value & 0x04:
                raise AssertionError('TXP set by ROM code')
            self.cr = value
            return
        if self.page() != 3:
            return
        if off == 1:
            self.eem = value >> 6
            if self.eem == 2:
                self.eeprom.pins((value >> 3) & 1, (value >> 2) & 1, (value >> 1) & 1)
        elif off == 2:
            self.bpage = value
            self.on_bpage()
        elif off == 0x0C and self.eem == 3:
            if value == 0x57:
                self.fmwp = 1
            elif value == 0xA8 and self.fmwp == 1:
                self.fmwp = 2
            else:
                self.fmwp = 0


class PC:
    def __init__(self, card=None, flash=None, bios_disks=0, mem_kib=640, window_seg=None):
        self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.uc.mem_map(0, 0xC0000)
        self.uc.mem_map(0xC0000, 0x20000)
        self.uc.mem_map(0xF0000, 0x10000)
        self.card = card
        self.flash = flash
        self.screen = ''
        self.files = {}
        self.handles = {}
        self.execs = []
        self.exit_code = None
        self.last_child = 0
        self.ticks = 0
        # The ROM window is plain RAM refreshed from the flash model before
        # each read once BPAGE or the flash changed (code must stay fetchable).
        self.win = None
        if card and flash and card.romseg is not None:
            flash.writes_enabled = lambda: card.fmwp == 2
            self.win = (window_seg or card.romseg) << 4
            self.dirty = True
            card.on_bpage = self._mark
            self.uc.hook_add(UC_HOOK_MEM_READ, self._win_read, None, self.win, self.win + 0x3FFF)
            self.uc.hook_add(UC_HOOK_MEM_WRITE, self._win_write, None, self.win, self.win + 0x3FFF)
            self._refresh()
        self.w16(0x413, mem_kib)
        self.w8(0x475, bios_disks)
        self.bios_disks = bios_disks
        # every vector points to a stub "int F0h+? ; retf 2" so chained calls work
        stub = bytes((0xCD, 0xF3, 0xCA, 0x02, 0x00))
        self.uc.mem_write((STUB_SEG << 4) + 0x100, stub)
        for v in range(256):
            self.w16(v * 4, 0x100)
            self.w16(v * 4 + 2, STUB_SEG)
        self.uc.hook_add(UC_HOOK_INTR, self._intr)
        self.uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        self.uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)

    # memory helpers
    def w8(self, a, v): self.uc.mem_write(a, bytes((v & 0xFF,)))
    def w16(self, a, v): self.uc.mem_write(a, (v & 0xFFFF).to_bytes(2, 'little'))
    def r8(self, a): return self.uc.mem_read(a, 1)[0]
    def r16(self, a): return int.from_bytes(self.uc.mem_read(a, 2), 'little')
    def cstr(self, a):
        out = bytearray()
        while True:
            b = self.r8(a)
            if b == 0:
                return out.decode('latin-1')
            out.append(b)
            a += 1

    def reg(self, name, value=None):
        r = globals()['UC_X86_REG_' + name.upper()]
        if value is None:
            return self.uc.reg_read(r)
        self.uc.reg_write(r, value)

    def set_cf(self, on):
        f = self.reg('eflags')
        self.reg('eflags', (f | 1) if on else (f & ~1))

    def cf(self):
        return self.reg('eflags') & 1

    def _mark(self):
        self.dirty = True

    def _refresh(self):
        base = self.card.bpage * 0x4000
        if self.flash.id_mode:
            data = bytes(self.flash.read(base + i) for i in range(0x4000))
        else:
            data = bytes(self.flash.mem[base % len(self.flash.mem):][:0x4000])
        self.uc.mem_write(self.win, data)
        self.dirty = False

    def _win_read(self, uc, access, addr, size, value, user):
        if self.dirty:
            self._refresh()

    def _win_write(self, uc, access, addr, size, value, user):
        off = addr - self.win
        for i in range(size):
            self.flash.write(self.card.bpage * 0x4000 + off + i, (value >> (8 * i)) & 0xFF)
        self.dirty = True       # the RAM write that follows is overwritten on the next read

    def _in(self, uc, port, size, user):
        self.ticks += 1
        if self.ticks % 64 == 0:
            self.w16(0x46C, self.r16(0x46C) + 1)
        if self.card and self.card.base <= port < self.card.base + 0x20:
            return self.card.io_read(port - self.card.base)
        return 0xFF

    def _out(self, uc, port, size, value, user):
        if self.card and self.card.base <= port < self.card.base + 0x20:
            self.card.io_write(port - self.card.base, value & 0xFF)
        elif port >= 0x200:
            raise AssertionError(f'write to foreign port {port:#x}')

    # interrupts
    def _intr(self, uc, intno, user):
        ah = (self.reg('ax') >> 8) & 0xFF
        if intno == 0x10:
            if ah == 0x0E:
                self.screen += chr(self.reg('ax') & 0xFF)
        elif intno == 0xF3:              # BIOS INT 13h behind the ROM
            self.bios_int13(ah)
        elif intno == 0x21:
            self.dos(ah)
        elif intno == 0x18:
            uc.emu_stop()
        else:
            raise AssertionError(f'unexpected INT {intno:#x} AH={ah:#x}')

    def bios_int13(self, ah):
        dl = self.reg('dx') & 0xFF
        self.chained = getattr(self, 'chained', []) + [(ah, dl)]
        if ah == 0x08 and dl >= 0x80 and dl - 0x80 < self.bios_disks:
            self.reg('dx', (0 << 8) | self.bios_disks)
            self.set_cf(False)
        elif ah == 0x00:
            self.reg('ax', 0)
            self.set_cf(False)
        else:
            self.reg('ax', 0x0100)
            self.set_cf(True)

    # DOS
    def lin(self, seg, off):
        return (seg << 4) + off

    def dos_path(self, seg, off):
        return self.cstr(self.lin(seg, off)).upper()

    def dos(self, ah):
        ds = self.reg('ds')
        dx = self.reg('dx') & 0xFFFF
        bx = self.reg('bx') & 0xFFFF
        cx = self.reg('cx') & 0xFFFF
        self.set_cf(False)
        if ah == 0x02:
            self.screen += chr(dx & 0xFF)
        elif ah in (0x3C, 0x3D):
            name = self.dos_path(ds, dx)
            if ah == 0x3C:
                self.files[name] = bytearray()
            elif name not in self.files:
                self.reg('ax', 2)
                return self.set_cf(True)
            h = 5 + len(self.handles)
            while h in self.handles:
                h += 1
            self.handles[h] = [name, 0]
            self.reg('ax', h)
        elif ah == 0x3E:
            self.handles.pop(bx, None)
        elif ah == 0x3F:
            name, pos = self.handles[bx]
            data = bytes(self.files[name][pos:pos + cx])
            self.uc.mem_write(self.lin(ds, dx), data)
            self.handles[bx][1] += len(data)
            self.reg('ax', len(data))
        elif ah == 0x40:
            name, pos = self.handles[bx]
            data = self.uc.mem_read(self.lin(ds, dx), cx)
            f = self.files[name]
            f[pos:pos + cx] = data
            self.handles[bx][1] += cx
            self.reg('ax', cx)
        elif ah == 0x42:
            name, pos = self.handles[bx]
            off = (cx << 16) | dx
            al = self.reg('ax') & 0xFF
            new = [off, pos + off, len(self.files[name]) + off][al]
            self.handles[bx][1] = new
            self.reg('ax', new & 0xFFFF)
            self.reg('dx', new >> 16)
        elif ah == 0x4A:
            pass
        elif ah == 0x4B:
            path = self.dos_path(ds, dx)
            es = self.reg('es')
            blk = self.lin(es, bx)
            tseg, toff = self.r16(blk + 4), self.r16(blk + 2)
            n = self.r8(self.lin(tseg, toff))
            tail = bytes(self.uc.mem_read(self.lin(tseg, toff) + 1, n)).decode('latin-1')
            self.execs.append((path, tail))
            if path not in self.files:
                self.reg('ax', 2)
                return self.set_cf(True)
            if path.endswith('NE2000.COM'):
                self.uc.mem_write(0x90003, b'PKT DRVR')
                self.w16(0x60 * 4, 0)
                self.w16(0x60 * 4 + 2, 0x9000)
                self.last_child = 0x0300
            else:
                self.last_child = 0
            # trash registers like DOS 2 would
            for r in ('ss', 'sp', 'ds', 'es', 'bx', 'cx', 'dx', 'si', 'di', 'bp'):
                self.reg(r, 0x1234 if r != 'ss' else 0x0050)
        elif ah == 0x4C:
            self.exit_code = self.reg('ax') & 0xFF
            self.uc.emu_stop()
        elif ah == 0x4D:
            self.reg('ax', self.last_child)
        else:
            raise AssertionError(f'unexpected DOS call AH={ah:#x}')

    # runners
    def call_far(self, seg, off, regs=None, limit=50_000_000):
        code = bytes((0x9A, off & 0xFF, off >> 8, seg & 0xFF, seg >> 8, 0xF4))
        self.uc.mem_write(0x600, code)
        for k, v in (regs or {}).items():
            self.reg(k, v)
        self.reg('ss', 0)
        self.reg('sp', 0x7000)
        self.reg('cs', 0)
        self.uc.emu_start(0x600, 0x605, count=limit)

    def int13(self, **regs):
        """Call the current INT 13h vector like an INT instruction does."""
        code = bytes((0x9C, 0xFF, 0x1E, 0x4C, 0x00, 0xF4))   # pushf; call far [4Ch]; hlt
        self.uc.mem_write(0x600, code)
        self.reg('ds', 0)
        self.reg('es', regs.pop('es', 0x2000))
        for k, v in regs.items():
            self.reg(k, v)
        self.reg('ss', 0)
        self.reg('sp', 0x7000)
        self.reg('cs', 0)
        self.uc.emu_start(0x600, 0x605, count=10_000_000)
        return self.reg('ax'), self.cf()

    def run_com(self, image, args='', path='A:\\TOOL.COM', env=None, seg=0x1000, limit=200_000_000):
        base = seg << 4
        self.uc.mem_write(base, bytes(0x100))
        self.uc.mem_write(base, b'\xCD\x20')
        envseg = seg - 0x20
        blob = b''.join(f'{k}={v}'.encode() + b'\0' for k, v in (env or {}).items())
        blob += b'\0' + b'\x01\x00' + path.encode() + b'\0'
        self.uc.mem_write(envseg << 4, blob)
        self.w16(base + 0x2C, envseg)
        tail = (' ' + args if args else '').encode()
        self.uc.mem_write(base + 0x80, bytes((len(tail),)) + tail + b'\r')
        self.uc.mem_write(base + 0x100, image)
        for r in ('cs', 'ds', 'es', 'ss'):
            self.reg(r, seg)
        self.reg('sp', 0xFFFE)
        self.uc.emu_start(base + 0x100, 0, count=limit)
        return self.exit_code
