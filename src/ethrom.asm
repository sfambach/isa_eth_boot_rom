; ISA ETH Boot ROM - option ROM for page 0 of the boot flash of an RTL8019AS card
;
; Finds the RTL8019AS that maps this ROM, then offers the rest of the flash
; as a read-only hard disk through INT 13h. The INT 13h handler runs from a
; copy in conventional memory, because switching the ROM page swaps the whole
; 16 KiB window including this code.
;
; Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
; PolyForm Noncommercial License 1.0.0, see LICENSE.md

        cpu     8086
        bits    16
        org     0

%include "src/version.inc"
%include "src/layout.inc"

        db      55h, 0AAh
        db      ROM_CODE_SIZE / 512
        jmp     init

        times HDR_MAGIC-($-$$) db 0
        db      'ETHR'
        db      VER_MAJOR, VER_MINOR, VER_PATCH
        db      0                   ; HDR_CYLS, filled in by tools/mkimage.py
        db      0                   ; HDR_HEADS
        db      0                   ; HDR_SPT
        db      1                   ; HDR_FIRSTPAGE

; ---------------------------------------------------------------------------
; Resident part, copied to the top of conventional memory.
; Addresses inside it are taken relative to res_start (macro R).
%define R(x) ((x) - res_start)

res_start:
r_old13:    dd  0
r_iobase:   dw  0
r_romseg:   dw  0
r_drive:    db  0
r_cyls:     db  0
r_heads:    db  0
r_spt:      db  0
r_first:    db  0

int13:
        cmp     dl, [cs:R(r_drive)]
        je      .ours
        cmp     ah, 08h
        jne     .chain
        test    dl, 80h
        jz      .chain
        ; The BIOS only counts its own disks in DL, DOS uses DL as drive count
        pushf
        call    far [cs:R(r_old13)]
        jc      .ret
        push    ds
        push    ax
        xor     ax, ax
        mov     ds, ax
        mov     dl, [0475h]
        pop     ax
        pop     ds
.ret:   retf    2
.chain: jmp     far [cs:R(r_old13)]

.ours:  cmp     ah, 02h
        je      .read
        cmp     ah, 08h
        je      .params
        cmp     ah, 15h
        je      .type
        cmp     ah, 03h
        je      .wprot
        cmp     ah, 05h
        jb      .ok                 ; 00h reset, 01h status, 04h verify
        cmp     ah, 07h
        jbe     .wprot              ; 05h-07h format
        cmp     ah, 0Bh
        je      .wprot              ; write long
        cmp     ah, 09h
        je      .ok
        cmp     ah, 0Ch
        jb      .bad
        cmp     ah, 0Dh
        jbe     .ok                 ; 0Ch seek, 0Dh reset
        cmp     ah, 10h
        jb      .bad
        cmp     ah, 11h
        jbe     .ok                 ; 10h ready, 11h recalibrate
        cmp     ah, 14h
        je      .ok
.bad:   mov     ah, 01h
        stc
        retf    2
.wprot: mov     ah, 03h
        stc
        retf    2
.ok:    xor     ah, ah
        clc
        retf    2

.params:
        mov     ch, [cs:R(r_cyls)]
        dec     ch
        mov     cl, [cs:R(r_spt)]
        mov     dh, [cs:R(r_heads)]
        dec     dh
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     dl, [0475h]
        pop     ds
        clc
        retf    2

.type:  push    ax
        mov     al, [cs:R(r_cyls)]
        mul     byte [cs:R(r_heads)]
        mov     dl, [cs:R(r_spt)]
        xor     dh, dh
        mul     dx
        mov     dx, ax
        xor     cx, cx
        pop     ax
        mov     ah, 03h
        clc
        retf    2

.read:  push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        mov     di, bx              ; ES:DI = buffer
        xor     ah, ah
        mov     bp, ax              ; BP = sectors to read
        or      ax, ax
        jz      .rerr
        mov     bl, cl              ; BL = sector
        and     bl, 3Fh
        jz      .rerr
        cmp     bl, [cs:R(r_spt)]
        ja      .rerr
        cmp     dh, [cs:R(r_heads)]
        jae     .rerr
        mov     al, cl              ; AX = cylinder
        mov     cl, 6
        shr     al, cl
        mov     ah, al
        mov     al, ch
        cmp     ax, 0FFh
        ja      .rerr
        cmp     al, [cs:R(r_cyls)]
        jae     .rerr
        mul     byte [cs:R(r_heads)]
        mov     cl, dh
        xor     ch, ch
        add     ax, cx
        mov     cl, [cs:R(r_spt)]
        xor     ch, ch
        mul     cx
        dec     bl
        xor     bh, bh
        add     ax, bx              ; AX = LBA
        mov     bx, ax
        add     ax, bp
        push    ax
        mov     al, [cs:R(r_cyls)]
        mul     byte [cs:R(r_heads)]
        mov     cl, [cs:R(r_spt)]
        xor     ch, ch
        mul     cx
        pop     cx
        cmp     cx, ax
        ja      .rerr               ; request runs past the end of the drive
        cld
.rloop: mov     ax, bx              ; page = first + LBA / 32
        mov     cl, 5
        shr     ax, cl
        add     al, [cs:R(r_first)]
        cli
        call    setpage
        sti
        mov     si, bx              ; offset = (LBA mod 32) * 512
        and     si, 1Fh
        mov     cl, 9
        shl     si, cl
        mov     ds, [cs:R(r_romseg)]
        mov     cx, 256
        rep     movsw
        inc     bx
        dec     bp
        jnz     .rloop
        xor     al, al
        cli
        call    setpage
        sti
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax                  ; AL = sectors read = sectors requested
        xor     ah, ah
        clc
        retf    2
.rerr:  pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        mov     ax, 0400h           ; sector not found, nothing read
        stc
        retf    2

; setpage - AL = ROM page; clobbers AX, DX. Call with interrupts disabled:
; the packet driver must not see the chip on page 3.
setpage:
        push    bx
        mov     bl, al
        mov     dx, [cs:R(r_iobase)]
        in      al, dx
        mov     bh, al
        and     al, 3Fh & ~04h
        or      al, 0C0h
        out     dx, al
        inc     dx
        inc     dx
        mov     al, bl
        out     dx, al
        dec     dx
        dec     dx
        mov     al, bh
        and     al, ~04h            ; never retrigger a transmit
        out     dx, al
        pop     bx
        ret

res_end:
RES_SIZE equ res_end - res_start

; ---------------------------------------------------------------------------
; Initialisation, called far by the BIOS during the option ROM scan
init:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        push    cs
        pop     ds
        cld
        mov     si, msg_banner
        call    puts

        xor     si, si
        xor     di, di              ; DI = 1: a card without page mode was seen
.scan:  call    rtl_probe
        jc      .none
        push    ax
        call    rtl_romseg
        mov     cx, ax
        pop     ax
        jcxz    .nopage
        mov     bp, cs
        cmp     cx, bp
        jne     .scan               ; another card, this ROM is not on it
        jmp     .found
.nopage:
        mov     di, 1
        jmp     .scan
.none:  mov     si, msg_nocard
        or      di, di
        jz      .msg
        mov     si, msg_nopage
.msg:   call    puts
        jmp     .exit

.found: ; DX = I/O base, AL = CONFIG1
        mov     bp, dx
        push    ax
        mov     si, msg_card
        call    puts
        mov     ax, bp
        call    puthex
        mov     si, msg_irq
        call    puts
        pop     ax
        call    rtl_irq
        xor     ah, ah
        call    putdec

        cmp     byte [HDR_CYLS], 0
        jne     .disk
        mov     si, msg_nodisk
        call    puts
        jmp     .exit

.disk:  ; take 1 KiB from the top of conventional memory
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:0413h]
        dec     ax
        mov     [es:0413h], ax
        mov     cl, 6
        shl     ax, cl
        mov     es, ax
        mov     si, res_start
        xor     di, di
        mov     cx, RES_SIZE
        rep     movsb
        mov     [es:R(r_iobase)], bp
        mov     [es:R(r_romseg)], cs
        mov     al, [HDR_CYLS]
        mov     [es:R(r_cyls)], al
        mov     al, [HDR_HEADS]
        mov     [es:R(r_heads)], al
        mov     al, [HDR_SPT]
        mov     [es:R(r_spt)], al
        mov     al, [HDR_FIRSTPAGE]
        mov     [es:R(r_first)], al

        xor     bx, bx
        mov     ds, bx
        mov     al, [0475h]
        mov     ah, al
        or      al, 80h
        mov     [es:R(r_drive)], al
        inc     ah
        mov     [0475h], ah
        cli
        mov     ax, [4Ch]
        mov     [es:R(r_old13)], ax
        mov     ax, [4Eh]
        mov     [es:R(r_old13)+2], ax
        mov     word [4Ch], R(int13)
        mov     [4Eh], es
        sti

        push    cs
        pop     ds
        mov     si, msg_drive
        call    puts
        mov     al, [es:R(r_drive)]
        xor     ah, ah
        call    puthex
        mov     si, msg_crlf
        call    puts

.exit:  pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        retf

%include "src/rtl8019.inc"

; puts - print zero terminated string DS:SI through the BIOS
puts:   push    ax
        push    bx
.l:     lodsb
        or      al, al
        jz      .e
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        jmp     .l
.e:     pop     bx
        pop     ax
        ret

; puthex - print AX as hex without leading zeros, followed by 'h'
puthex: push    ax
        push    bx
        push    cx
        push    dx
        mov     dx, ax
        mov     cx, 4
        xor     bx, bx              ; BX = 1 after the first digit
.d:     push    cx
        mov     cl, 4
        rol     dx, cl
        pop     cx
        mov     al, dl
        and     al, 0Fh
        jnz     .p
        or      bx, bx
        jnz     .p
        cmp     cx, 1
        jne     .n
.p:     mov     bx, 1
        add     al, '0'
        cmp     al, '9'
        jbe     .o
        add     al, 7
.o:     push    bx
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        pop     bx
.n:     loop    .d
        mov     ax, 0E00h + 'h'
        mov     bx, 0007h
        int     10h
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; putdec - print AX (< 100) in decimal
putdec: push    ax
        push    bx
        mov     bl, 10
        div     bl
        or      al, al
        jz      .one
        push    ax
        add     al, '0'
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        pop     ax
.one:   mov     al, ah
        add     al, '0'
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        pop     bx
        pop     ax
        ret

msg_banner: db  13, 10, 'ISA ETH Boot ROM ', VERSION_STR, ' (c) SteFam', 13, 10, 0
msg_nocard: db  '  No RTL8019AS found that maps this ROM.', 13, 10, 0
msg_nopage: db  '  RTL8019AS found, but its boot ROM is not in page mode.', 13, 10, 0
msg_card:   db  '  RTL8019AS at I/O ', 0
msg_irq:    db  ', IRQ ', 0
msg_nodisk: db  13, 10, '  No ROM drive in this image.', 13, 10, 0
msg_drive:  db  ', ROM drive ', 0
msg_crlf:   db  13, 10, 0

        times ROM_CODE_SIZE-($-$$) db 0FFh
