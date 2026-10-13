; RTL8019AS registers and card detection, shared by the ROM and the DOS tools.
; 8086 code, no assumption about DS; tables are read through CS.

RTL_CR          equ 00h             ; command register, all pages
RTL_ID0         equ 0Ah             ; page 0: 'P'
RTL_ID1         equ 0Bh             ; page 0: 'p'
RTL_9346CR      equ 01h             ; page 3
RTL_BPAGE       equ 02h             ; page 3
RTL_CONFIG0     equ 03h             ; page 3
RTL_CONFIG1     equ 04h             ; page 3
RTL_CONFIG2     equ 05h             ; page 3
RTL_CONFIG3     equ 06h             ; page 3
RTL_FMWP        equ 0Ch             ; page 3, write only

CR_TXP          equ 04h
CR_PAGE3        equ 0C0h
CFG0_JP         equ 08h             ; jumper (DIP switch) mode
CFG3_PNP        equ 80h

; I/O base addresses in the order of the IOS3-0 bits of CONFIG1
rtl_bases:      dw 300h, 320h, 340h, 360h, 380h, 3A0h, 3C0h, 3E0h
                dw 200h, 220h, 240h, 260h, 280h, 2A0h, 2C0h, 2E0h
; ISA IRQ in the order of the IRQS2-0 bits of CONFIG1
rtl_irqs:       db 2, 3, 4, 5, 10, 11, 12, 15

; rtl_probe - find the next RTL8019AS
; in:  SI = first table index to try (0..15)
; out: CF=0 found: DX = I/O base, SI = index of the next candidate,
;              AL = CONFIG1, AH = CONFIG2, BL = CONFIG0, BH = CONFIG3
;      CF=1 nothing (more) found
; The probe only reads ports until the ID matches, so other cards in the
; scanned range (VGA at 3C0h, XT-IDE at 300h) are not written to.
rtl_probe:
        push    cx
.next:  cmp     si, 16
        jae     .none
        mov     bx, si
        shl     bx, 1
        mov     dx, [cs:rtl_bases+bx]
        inc     si
        in      al, dx              ; CR must show page 0 (also rejects a floating bus, FFh)
        test    al, 0C0h
        jnz     .next
        add     dx, RTL_ID0
        in      al, dx
        cmp     al, 'P'
        jne     .next
        inc     dx
        in      al, dx
        cmp     al, 'p'
        jne     .next
        sub     dx, RTL_ID1
        in      al, dx              ; switch to page 3, keep the other CR bits
        mov     cl, al
        and     al, 3Fh & ~CR_TXP
        or      al, CR_PAGE3
        out     dx, al
        add     dx, RTL_CONFIG0
        in      al, dx
        mov     bl, al
        inc     dx
        in      al, dx
        mov     ch, al              ; CONFIG1
        inc     dx
        in      al, dx
        mov     ah, al              ; CONFIG2
        inc     dx
        in      al, dx
        mov     bh, al              ; CONFIG3
        sub     dx, RTL_CONFIG3
        mov     al, cl              ; back to the previous page
        and     al, ~CR_TXP
        out     dx, al
        mov     al, ch
        ; IOS3-0 must point to the base we probed, otherwise it is a mirror
        push    bx
        mov     bl, al
        and     bx, 0Fh
        shl     bx, 1
        cmp     dx, [cs:rtl_bases+bx]
        pop     bx
        jne     .next
        clc
        pop     cx
        ret
.none:  stc
        pop     cx
        ret

; rtl_irq - AL = CONFIG1 -> AL = ISA IRQ number (clobbers CL)
rtl_irq:
        push    bx
        mov     bl, al
        mov     cl, 4
        shr     bl, cl
        and     bx, 7
        mov     al, [cs:rtl_irqs+bx]
        pop     bx
        ret

; rtl_romseg - AH = CONFIG2 -> AX = segment of the boot ROM in page mode,
;              AX = 0 if the boot ROM is disabled or not in page mode (clobbers CL)
rtl_romseg:
        mov     al, ah
        and     al, 18h
        cmp     al, 18h
        jne     .no
        test    ah, 20h             ; BSELB: boot ROM forced off
        jnz     .no
        mov     al, ah
        and     ax, 7
        mov     cl, 10
        shl     ax, cl              ; 400h per step
        add     ax, 0C000h
        ret
.no:    xor     ax, ax
        ret
