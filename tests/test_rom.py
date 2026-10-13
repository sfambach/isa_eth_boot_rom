"""Emulator tests for the option ROM, the ROM drive and the DOS tools."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from emu import PC, Rtl8019, Flash   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')


def build_image(files=None, extra=(), size=512):
    out = tempfile.NamedTemporaryFile(suffix='.bin', delete=False).name
    if files is None:
        files = []
        for name in ('HELLO.TXT', 'BIG.BIN'):
            path = os.path.join(tempfile.gettempdir(), name)
            with open(path, 'wb') as f:
                f.write(b'hello rom drive\r\n' if name == 'HELLO.TXT' else bytes(range(256)) * 600)
            files.append(path)
    subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'mkimage.py'),
                    '--rom', os.path.join(BUILD, 'ethrom.bin'),
                    '--boot', os.path.join(BUILD, 'bootstub.bin'),
                    '--size', str(size), '-o', out, *extra, *files],
                   check=True, capture_output=True)
    data = open(out, 'rb').read()
    os.unlink(out)
    return data


def make_pc(image, base=0x300, irq=3, romseg=0xD000, card_romseg=None, page_mode=True,
            mode='jumperless', bios_disks=0, eeprom=None):
    """romseg: where the image is mapped, card_romseg: what CONFIG2 reports."""
    flash = Flash()
    flash.mem[:len(image)] = image
    card = Rtl8019(base=base, irq=irq, romseg=card_romseg or romseg, page_mode=page_mode,
                   mode=mode, eeprom=eeprom)
    return PC(card=card, flash=flash, bios_disks=bios_disks, window_seg=romseg)


def tool(name):
    return open(os.path.join(BUILD, name), 'rb').read()


class RomInit(unittest.TestCase):
    def test_checksum_and_header(self):
        img = build_image()
        self.assertEqual(img[:2], b'\x55\xAA')
        self.assertEqual(sum(img[:img[2] * 512]) & 0xFF, 0)
        self.assertEqual(img[0x10:0x14], b'ETHR')
        self.assertEqual(img[0x17], 31)

    def test_init_installs_drive(self):
        pc = make_pc(build_image(), base=0x340, irq=5)
        pc.call_far(0xD000, 3)
        self.assertIn('RTL8019AS at I/O 340h, IRQ 5', pc.screen)
        self.assertIn('ROM drive 80h', pc.screen)
        self.assertEqual(pc.r16(0x413), 639)
        self.assertEqual(pc.r8(0x475), 1)
        self.assertEqual(pc.r16(0x4E), 639 * 64)

    def test_second_disk_after_bios_disk(self):
        pc = make_pc(build_image(), bios_disks=1)
        pc.call_far(0xD000, 3)
        self.assertIn('ROM drive 81h', pc.screen)
        ax, cf = pc.int13(ax=0x0800, dx=0x0080)
        self.assertFalse(cf)
        self.assertEqual(pc.reg('dx') & 0xFF, 2, 'drive count must include the ROM drive')

    def test_other_segment_is_ignored(self):
        pc = make_pc(build_image(), romseg=0xD000, card_romseg=0xD400)
        pc.call_far(0xD000, 3)
        self.assertIn('No RTL8019AS found', pc.screen)
        self.assertEqual(pc.r8(0x475), 0)

    def test_no_page_mode(self):
        pc = make_pc(build_image(), page_mode=False)
        pc.call_far(0xD000, 3)
        self.assertIn('not in page mode', pc.screen)


class RomDrive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = build_image()
        cls.disk = cls.image[0x4000:]

    def setUp(self):
        self.pc = make_pc(self.image)
        self.pc.call_far(0xD000, 3)

    def read(self, c, h, s, n=1):
        ax, cf = self.pc.int13(ax=0x0200 | n, cx=((c & 0xFF) << 8) | ((c >> 2) & 0xC0) | s,
                               dx=(h << 8) | 0x80, bx=0, es=0x2000)
        return ax, cf, bytes(self.pc.uc.mem_read(0x20000, n * 512))

    def test_geometry(self):
        ax, cf = self.pc.int13(ax=0x0800, dx=0x0080)
        self.assertFalse(cf)
        cx, dx = self.pc.reg('cx'), self.pc.reg('dx')
        self.assertEqual(cx >> 8, 30)
        self.assertEqual(cx & 0x3F, 8)
        self.assertEqual(dx >> 8, 3)
        self.assertEqual(dx & 0xFF, 1)

    def test_every_sector(self):
        for lba in range(0, 31 * 32, 7):
            c, rest = divmod(lba, 32)
            h, s = divmod(rest, 8)
            n = min(5, 31 * 32 - lba)
            ax, cf, data = self.read(c, h, s + 1, n)
            self.assertFalse(cf, lba)
            self.assertEqual(ax & 0xFF, n)
            self.assertEqual(data, self.disk[lba * 512:(lba + n) * 512], lba)
        self.assertEqual(self.pc.card.bpage, 0, 'page 0 must be restored')

    def test_errors(self):
        ax, cf, _ = self.read(31, 0, 1)
        self.assertTrue(cf)
        self.assertEqual(ax >> 8, 4)
        ax, cf, _ = self.read(30, 3, 8, 2)
        self.assertTrue(cf)
        ax, cf = self.pc.int13(ax=0x0301, cx=0x0001, dx=0x0080, bx=0)
        self.assertTrue(cf)
        self.assertEqual(ax >> 8, 3)

    def test_other_drives_are_chained(self):
        self.pc.chained = []
        ax, cf = self.pc.int13(ax=0x0201, cx=1, dx=0x0000, bx=0)
        self.assertEqual(self.pc.chained, [(2, 0)])

    def test_fat_file_system(self):
        from pyfatfs.PyFatFS import PyFatFS
        start = struct.unpack_from('<I', self.disk, 446 + 8)[0]
        with tempfile.NamedTemporaryFile(suffix='.img', delete=False) as f:
            f.write(self.disk[start * 512:])
            path = f.name
        try:
            fs = PyFatFS(path, read_only=True)
            self.assertEqual(sorted(fs.listdir('/')), ['BIG.BIN', 'HELLO.TXT'])
            self.assertEqual(fs.readbytes('/HELLO.TXT'), b'hello rom drive\r\n')
            self.assertEqual(fs.readbytes('/BIG.BIN'), bytes(range(256)) * 600)
            fs.close()
        finally:
            os.unlink(path)


class NetCfg(unittest.TestCase):
    def setUp(self):
        self.image = build_image()
        self.pc = make_pc(self.image)

    def run_cfg(self, args, pc=None):
        pc = pc or self.pc
        pc.screen = ''
        code = pc.run_com(tool('NETCFG.COM'), args)
        return code, pc.screen

    def settings(self):
        return bytes(self.pc.flash.mem[0x3000:0x3040])

    def test_show(self):
        code, out = self.run_cfg('')
        self.assertEqual(code, 0, out)
        self.assertIn('I/O 300h, IRQ 3', out)
        self.assertIn('jumperless', out)
        self.assertIn('page mode at D000h', out)
        self.assertIn('512 KiB', out)
        self.assertIn('Address:   DHCP', out)
        self.assertIn('RETROPC', out)

    def test_static_and_back(self):
        code, out = self.run_cfg('static 192.168.1.50 255.255.255.0 192.168.1.1 192.168.1.2')
        self.assertEqual(code, 0, out)
        s = self.settings()
        self.assertEqual(s[:4], b'NCFG')
        self.assertEqual(s[5], 0)
        self.assertEqual(list(s[6:22]), [192, 168, 1, 50, 255, 255, 255, 0, 192, 168, 1, 1, 192, 168, 1, 2])
        self.assertEqual(sum(s) & 0xFF, 0)
        self.assertEqual(self.image[:0x3000], bytes(self.pc.flash.mem[:0x3000]), 'ROM code untouched')
        self.assertEqual(self.pc.card.fmwp, 0, 'flash writes locked again')
        code, out = self.run_cfg('dhcp')
        self.assertEqual(self.settings()[5], 1)
        code, out = self.run_cfg('name XT-OFFICE')
        self.assertEqual(self.settings()[22:32], b'XT-OFFICE\0')
        self.assertIn('Host name: XT-OFFICE', out)

    def test_bad_input(self):
        for args in ('static 1.2.3 255.0.0.0 1.1.1.1 2.2.2.2', 'static 1.2.3.400 1.1.1.1 1.1.1.1 1.1.1.1',
                     'name 1234567890123456', 'pagemode E000', 'bogus'):
            code, out = self.run_cfg(args)
            self.assertEqual(code, 1, args)

    def test_flash_keeps_settings(self):
        self.run_cfg('name KEEPME')
        new = bytearray(build_image(extra=['--hostname', 'OTHER']))
        new[0x5000:0x5004] = b'ABCD'                # change one ROM drive sector
        self.pc.files['NEW.BIN'] = bytearray(new)
        self.pc.flash.ops = []
        code, out = self.run_cfg('flash new.bin')
        self.assertEqual(code, 0, out)
        mem = bytes(self.pc.flash.mem)
        self.assertEqual(mem[0x5000:0x5004], b'ABCD')
        self.assertEqual(mem[0x3000 + 22:0x3000 + 29], b'KEEPME\0')
        erased = [a for op, a in self.pc.flash.ops if op == 'erase']
        self.assertEqual(erased, [0x5000], 'only the changed sector is rewritten')
        self.assertEqual(mem[:0x3000], bytes(new[:0x3000]))
        self.assertEqual(mem[0x4000:], bytes(new[0x4000:]))
        code, out = self.run_cfg('flash new.bin /all')
        self.assertEqual(bytes(self.pc.flash.mem), bytes(new))

    def test_flash_rejects_foreign_file(self):
        self.pc.files['JUNK.BIN'] = bytearray(0x10000)
        code, out = self.run_cfg('flash junk.bin')
        self.assertEqual(code, 1)
        self.assertIn('Not an ISA ETH Boot ROM image', out)
        self.assertEqual(bytes(self.pc.flash.mem), self.image)

    def test_pagemode_writes_eeprom(self):
        cfg1 = 0x13                                   # IRQ 3, I/O 360h in the EEPROM
        words = [0xFFFF] * 64
        words[0] = (cfg1 << 8) | 0x00                 # CONFIG2: boot ROM disabled
        pc = make_pc(self.image, base=0x360, eeprom=words)
        code, out = self.run_cfg('pagemode D400', pc)
        self.assertEqual(code, 0, out)
        self.assertEqual(pc.card.eeprom.words[0], (cfg1 << 8) | 0x1D)
        self.assertEqual(pc.card.eeprom.words[1:], [0xFFFF] * 63)
        code, out = self.run_cfg('pagemode 0xD400', pc)
        self.assertIn('already set', out)

    def test_pagemode_refused_in_dip_mode(self):
        pc = make_pc(self.image, mode='dip')
        code, out = self.run_cfg('pagemode D000', pc)
        self.assertEqual(code, 1)
        self.assertIn('SW4', out)


class NetStart(unittest.TestCase):
    def run_start(self, pc, cfg=None):
        if cfg is not None:
            pc.files['C:\\MTCP.CFG'] = bytearray(cfg)
        for name in ('D:\\NE2000.COM', 'D:\\DHCP.EXE'):
            pc.files[name] = bytearray(b'x')
        return pc.run_com(tool('NETSTART.COM'), '', path='D:\\NETSTART.COM',
                          env={'PATH': 'C:\\DOS', 'MTCPCFG': 'C:\\MTCP.CFG'})

    def test_dhcp(self):
        pc = make_pc(build_image(), base=0x320, irq=5)
        code = self.run_start(pc, b'IRCJR_NICK stefam\r\nIPADDR 1.2.3.4\r\nhostname old\r\nFTP_MSS 1460')
        self.assertEqual(code, 0, pc.screen)
        self.assertEqual(pc.execs[0], ('D:\\NE2000.COM', ' 0x60 5 0x320'))
        self.assertEqual(pc.execs[1][0], 'D:\\DHCP.EXE')
        cfg = pc.files['C:\\MTCP.CFG'].decode()
        self.assertEqual(cfg, 'IRCJR_NICK stefam\r\nFTP_MSS 1460\r\nPACKETINT 0x60\r\nHOSTNAME RETROPC\r\n')

    def test_static(self):
        pc = make_pc(build_image(extra=['--static', '10.0.0.9', '255.0.0.0', '10.0.0.1', '10.0.0.2',
                                        '--hostname', 'XT']))
        code = self.run_start(pc)
        self.assertEqual(code, 0, pc.screen)
        self.assertEqual(len(pc.execs), 1)
        cfg = pc.files['C:\\MTCP.CFG'].decode()
        self.assertEqual(cfg, 'PACKETINT 0x60\r\nHOSTNAME XT\r\nIPADDR 10.0.0.9\r\nNETMASK 255.0.0.0\r\n'
                              'GATEWAY 10.0.0.1\r\nNAMESERVER 10.0.0.2\r\n')

    def test_no_env(self):
        pc = make_pc(build_image())
        code = pc.run_com(tool('NETSTART.COM'), '', path='D:\\NETSTART.COM', env={'PATH': 'C:\\'})
        self.assertEqual(code, 1)
        self.assertIn('MTCPCFG is not set', pc.screen)

    def test_no_card(self):
        pc = PC()
        code = pc.run_com(tool('NETSTART.COM'), '', env={'MTCPCFG': 'C:\\MTCP.CFG'})
        self.assertEqual(code, 1)
        self.assertIn('No RTL8019AS', pc.screen)


if __name__ == '__main__':
    unittest.main()
