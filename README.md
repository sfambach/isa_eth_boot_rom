# ISA ETH Boot ROM

A boot ROM for the [ISA 8-Bit Ethernet card by Sergey Kiselev](https://github.com/skiselev/isa8_eth)
(Realtek RTL8019AS, NE2000 compatible). It turns the 512 KiB flash in the boot ROM
socket into a read-only drive that already holds the NE2000 packet driver and the
[mTCP](https://www.brutman.com/mTCP/) programs, so an XT or AT gets on the network
without floppy and without files on the hard disk.

> **Status: 0.0.1, first test build.** All parts run in the emulator tests of this
> repository (`make test`), which model the RTL8019AS, the flash and the EEPROM.
> **Nothing has been tested on real hardware yet.**

## How it works

```
Flash SST39SF040 (512 KiB), seen through a 16 KiB window in page mode
+-----------+---------------------------------------------------------+
| page 0    | 0000h-2FFFh option ROM | 3000h-3FFFh settings sector    |
| page 1-31 | ROM drive: MBR + FAT12 partition, 32 sectors per page   |
+-----------+---------------------------------------------------------+
```

1. The BIOS runs the option ROM in page 0.
2. The ROM looks for the RTL8019AS at the 16 possible I/O addresses (ID `Pp`), reads
   IRQ and boot ROM address from CONFIG1/CONFIG2 and checks that the card maps this ROM.
   Nobody has to enter I/O address or IRQ.
3. It takes 1 KiB at the top of conventional memory, copies its INT 13h handler there
   (switching the page swaps the whole window, including the running code) and adds the
   ROM drive as the next hard disk (80h, or 81h behind an XT-IDE disk).
4. DOS boots as usual from floppy or hard disk and gives the ROM drive a letter.
5. `NETSTART` from the ROM drive writes the network lines of `MTCP.CFG`, loads
   `NE2000.COM` with the detected IRQ and I/O address and runs `DHCP` if selected.

The flash is written in the card: the RTL8019AS passes `/SMEMW` to the flash once its
FMWP register is unlocked (57h, A8h), and `BPAGE` selects the page. `NETCFG` uses this
for settings and ROM updates, like XTIDECFG does for the XT-IDE BIOS.

## Requirements

* ISA 8-Bit Ethernet card with **RTL8019AS** (not the older RTL8019) and an
  SST39SF040 in socket U2 (39SF010A/020A work with a smaller image)
* Boot ROM in **page mode**, at an address free of other ROMs (XT-IDE often uses C800h):
  * DIP switch mode (SW1-1 on, SW1-2 off), e.g. D000h: SW4-1 off, SW4-2 off, SW4-3 on,
    SW4-4 on, SW4-5 on (see the table in the isa8_eth README)
  * jumperless mode (SW1 both off): `NETCFG PAGEMODE D000`, then power cycle
* Plug and Play mode is not supported (an XT has nobody to assign resources)
* DOS 3.0 or newer

## First installation

1. Put a blank or old SST39SF040 into U2 and set page mode (see above).
2. Boot DOS, then write the image into the card:
   ```
   NETCFG FLASH ETHBOOT.BIN
   ```
   An external programmer (TL866 etc.) works as well: burn `ethboot.bin` as is.
3. Restart. The ROM shows `RTL8019AS at I/O 300h, IRQ 3, ROM drive 81h`.

## Daily use

```
:: AUTOEXEC.BAT, D: is the ROM drive here
SET MTCPCFG=C:\MTCP.CFG
D:\NETSTART
```

`MTCPCFG` must point to a writable drive. NETSTART only replaces `PACKETINT`,
`HOSTNAME`, `IPADDR`, `NETMASK`, `GATEWAY`, `NAMESERVER` and the DHCP lines; all other
lines of the file are kept.

## Settings: NETCFG

| Command | Effect |
|---|---|
| `NETCFG` | show card, mode, flash and settings |
| `NETCFG DHCP` | get the address by DHCP (default) |
| `NETCFG STATIC ip mask gateway dns` | fixed address |
| `NETCFG NAME hostname` | host name (1-15 characters) |
| `NETCFG FLASH image.bin [/ALL]` | write a new image; only changed 4 KiB sectors are erased; the settings are kept unless `/ALL` |
| `NETCFG PAGEMODE seg` | jumperless mode only: write page mode at seg (C000-DC00) into the EEPROM |

Settings live in their own 4 KiB flash sector; the option ROM checksum does not cover it.

## Building

Needs NASM and Python 3 (and `unicorn` + `pyfatfs` from pip for the tests).

```
mkdir mtcp
# mTCP UPX build from https://www.brutman.com/mTCP/ unpacked into mtcp/
# NE2000.COM from skiselev/isa8_eth software/driver copied into mtcp/
# optional: RSET8019.EXE, PG8019.EXE (upx --best --8086) and 8019AS.CFG into mtcp/
make            # build/ethboot.bin, build/NETCFG.COM, build/NETSTART.COM
make test
```

`tools/mkimage.py` options: `--size 128|256|512`, `--hostname`, `--static IP MASK GW DNS`,
plus the list of files for the ROM drive. The default image holds NETSTART, NETCFG,
NE2000, DHCP, PING, HTGET, SNTP, FTP, TELNET, NETDRIVE and the Realtek tools RSET8019 and
PG8019 (about 410 of 486 KiB).

## Plans

1. Option ROM, ROM drive, NETSTART, NETCFG (this version)
2. Setup menu in the ROM at boot time, services at start (SNTP, NetDrive)
3. Diskless PCs: boot DOS from the ROM drive, MTCP.CFG on a RAM disk
4. Other NE2000 cards with a boot ROM socket

## Known limits

* Some AT BIOSes recount their hard disks after the option ROM scan; then the ROM drive
  may disappear from the drive count (not seen yet, the XT is the target).
* Very early IBM PC BIOS versions do not scan for option ROMs.
* Run `NETCFG FLASH` without the packet driver loaded and restart the PC afterwards:
  DOS caches the old ROM drive.

## License

The code in this repository: Copyright (C) 2026 Stefan Fambach (SteFam),
https://www.fambach.net, [PolyForm Noncommercial License 1.0.0](LICENSE.md): free for any
noncommercial purpose, commercial use only with prior written consent.

The image builder only *places* third-party programs on the ROM drive (mere aggregation);
they keep their own licenses and are not part of this repository:

* mTCP by Michael B. Brutman, GPLv3, source at https://www.brutman.com/mTCP/
* NE2000 packet driver (Crynwr, 8-bit patch by profdc9), GPLv2, source in
  https://github.com/skiselev/isa8_eth
* RSET8019 and PG8019, Realtek freeware utilities, as distributed in
  https://github.com/skiselev/isa8_eth (packed with UPX)

Images built with them must carry their license texts (the default image adds mTCP's
COPYING.TXT) and point to their sources (README.TXT on the ROM drive does).

Trademarks belong to their respective owners.

## AI disclosure

This project was designed and written with the help of an AI assistant (Claude by
Anthropic), working on Stefan Fambach's ideas and review. Code, tests and documentation
were generated by the AI and checked in the emulator tests; hardware tests are done by a
human.
