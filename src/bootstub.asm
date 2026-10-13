; Boot stub for the MBR and the boot sector of the ROM drive.
; The ROM drive is a data drive; if a BIOS tries to boot from it, say so and
; hand over to INT 18h. Bytes 3-61 are left free for the FAT BPB, the
; partition table area is left free for tools/mkimage.py.
;
; Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
; PolyForm Noncommercial License 1.0.0, see LICENSE.md

        cpu     8086
        bits    16
        org     7C00h

        jmp     short start
        nop
        times   62-($-$$) db 0
start:  xor     ax, ax
        mov     ds, ax
        mov     si, msg
        cld
.l:     lodsb
        or      al, al
        jz      .e
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        jmp     .l
.e:     int     18h
.h:     hlt
        jmp     .h
msg:    db      'ISA ETH Boot ROM drive is not bootable.', 13, 10, 0
        times   510-($-$$) db 0
        dw      0AA55h
