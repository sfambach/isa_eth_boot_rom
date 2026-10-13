; NETCFG - set up the ISA ETH Boot ROM from DOS
;
;   NETCFG                       show card, flash and settings
;   NETCFG DHCP                  get the address by DHCP
;   NETCFG STATIC ip mask gw dns use a fixed address
;   NETCFG NAME host             set the host name
;   NETCFG FLASH file [/ALL]     write a ROM image into the flash on the card
;   NETCFG PAGEMODE seg          jumperless mode: put the boot ROM into page
;                                mode at seg (C000-DC00) via the EEPROM
;
; The flash is written through the RTL8019AS: FMWP unlocks writes, BPAGE
; selects the 16 KiB page. SST39SF0x0 commands only decode A14-A0, so the
; unlock addresses 5555h/2AAAh are page 1 offset 1555h and page 0 offset 2AAAh.
;
; Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
; PolyForm Noncommercial License 1.0.0, see LICENSE.md

        cpu     8086
        bits    16
        org     100h

%include "src/version.inc"
%include "src/layout.inc"

SECTOR_SIZE equ 1000h               ; flash erase sector

start:  mov     sp, stack_top
        cld
        mov     si, msg_banner
        call    puts
        mov     word [tail_ptr], 81h
        call    next_word
        jc      cmd_show
        mov     bx, commands
.find:  mov     si, [bx]
        or      si, si
        jz      usage
        call    word_is
        je      .go
        add     bx, 4
        jmp     .find
.go:    jmp     [bx+2]

usage:  mov     si, msg_usage
        jmp     fail

; ---------------------------------------------------------------- commands
cmd_show:
        call    need_card
        mov     di, line_buf
        mov     si, msg_card
        call    copy_str
        mov     ax, [card_io]
        call    fmt_hex
        mov     si, msg_irq
        call    copy_str
        mov     al, [card_irq]
        xor     ah, ah
        call    fmt_dec
        mov     si, msg_crlf
        call    copy_str
        call    print_buf

        mov     si, msg_mode_pnp
        test    byte [card_cfg3], CFG3_PNP
        jnz     .mode
        mov     si, msg_mode_dip
        test    byte [card_cfg0], CFG0_JP
        jnz     .mode
        mov     si, msg_mode_sw
.mode:  call    puts

        mov     ax, [card_romseg]
        or      ax, ax
        jnz     .rom
        mov     si, msg_rom_nopage
        call    puts
        mov     si, msg_set_none
        jmp     fail_ok
.rom:   mov     di, line_buf
        mov     si, msg_rom_page
        call    copy_str
        mov     ax, [card_romseg]
        call    fmt_hex
        mov     si, msg_h_crlf
        call    copy_str
        call    print_buf
        call    flash_id
        jc      .noflash
        mov     di, line_buf
        mov     si, msg_flash
        call    copy_str
        mov     ax, [flash_kib]
        call    fmt_dec
        mov     si, msg_kib
        call    copy_str
        call    print_buf
        jmp     .set
.noflash:
        mov     si, msg_noflash
        call    puts
.set:   call    load_settings
        jnc     .valid
        mov     si, msg_set_def
        call    puts
.valid: call    show_settings
        jmp     done

cmd_dhcp:
        call    need_rom_settings
        or      byte [cur_set+SET_FLAGS], SETF_DHCP
        jmp     store_settings

cmd_static:
        call    need_rom_settings
        mov     di, new_ip
        mov     cx, 4
.ip:    push    cx
        call    next_word
        pop     cx
        jc      usage
        call    parse_ip
        jc      .bad
        add     di, 4
        loop    .ip
        mov     si, new_ip
        mov     di, cur_set+SET_IP
        mov     cx, 16
        rep     movsb
        and     byte [cur_set+SET_FLAGS], ~SETF_DHCP
        jmp     store_settings
.bad:   mov     si, msg_badip
        jmp     fail

cmd_name:
        call    need_rom_settings
        call    next_word
        jc      usage
        mov     si, word_buf
        mov     cx, [word_len]
        cmp     cx, 15
        ja      .bad
        mov     di, cur_set+SET_HOSTNAME
        push    cx
        push    di
        mov     cx, 16
        xor     al, al
        rep     stosb
        pop     di
        pop     cx
        rep     movsb
        jmp     store_settings
.bad:   mov     si, msg_badname
        jmp     fail

cmd_flash:
        call    need_flash
        call    next_word
        jc      usage
        mov     si, word_buf
        mov     di, file_name
        mov     cx, [word_len]
        rep     movsb
        mov     byte [di], 0
        mov     byte [keep_set], 1
        call    next_word
        jc      .open
        mov     si, opt_all
        call    word_is
        jne     usage
        mov     byte [keep_set], 0
.open:  mov     dx, file_name
        mov     ax, 3D00h
        int     21h
        jnc     .opened
        mov     si, msg_nofile
        jmp     fail
.opened:
        mov     [file_handle], ax
        mov     bx, ax
        mov     ax, 4202h           ; size
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     [file_sectors], ax  ; temporarily the low word
        push    dx
        mov     ax, 4200h
        xor     cx, cx
        xor     dx, dx
        int     21h
        pop     dx
        mov     ax, [file_sectors]
        test    ax, SECTOR_SIZE-1
        jnz     .badsize
        mov     cl, 12
        shr     ax, cl
        mov     cl, 4
        shl     dx, cl
        or      ax, dx              ; AX = file size / 4 KiB
        jz      .badsize
        mov     bx, [flash_kib]
        shr     bx, 1
        shr     bx, 1               ; flash size / 4 KiB
        cmp     ax, bx
        ja      .badsize
        mov     [file_sectors], ax

        ; settings are kept if the flash holds valid ones
        cmp     byte [keep_set], 0
        je      .go
        call    load_settings
        jnc     .go
        mov     byte [keep_set], 0
.go:    mov     si, msg_flashing
        call    puts
        call    flash_enable
        xor     bp, bp              ; BP = sector
.sec:   cmp     bp, [file_sectors]
        jae     .end
        mov     bx, [file_handle]
        mov     dx, sec_buf
        mov     cx, SECTOR_SIZE
        mov     ah, 3Fh
        int     21h
        jc      .rerr
        cmp     ax, SECTOR_SIZE
        jne     .rerr
        or      bp, bp
        jnz     .notfirst
        cmp     word [sec_buf], 0AA55h
        jne     .notimage
        cmp     word [sec_buf+HDR_MAGIC], 'ET'
        jne     .notimage
        cmp     word [sec_buf+HDR_MAGIC+2], 'HR'
        jne     .notimage
.notfirst:
        cmp     bp, SET_OFFSET / SECTOR_SIZE
        jne     .write
        cmp     byte [keep_set], 0
        je      .write
        mov     al, 's'
        call    putc
        jmp     .next
.write: call    flash_sector
        jc      .ferr
        call    putc
.next:  inc     bp
        jmp     .sec
.end:   call    flash_disable
        mov     bx, [file_handle]
        mov     ah, 3Eh
        int     21h
        mov     si, msg_flashed
        jmp     fail_ok
.notimage:
        mov     si, msg_notimage
        jmp     .abort
.badsize:
        mov     si, msg_badsize
        jmp     fail
.rerr:  mov     si, msg_readerr
        jmp     .abort
.ferr:  mov     si, msg_flasherr
.abort: call    flash_disable
        jmp     fail

cmd_pagemode:
        call    need_card
        call    next_word
        jc      usage
        call    parse_hex
        jc      .badseg
        sub     ax, 0C000h
        jb      .badseg
        test    ax, 03FFh
        jnz     .badseg
        mov     cl, 10
        shr     ax, cl
        cmp     ax, 7
        ja      .badseg
        mov     [new_bs], al
        mov     si, msg_dipmode
        test    byte [card_cfg0], CFG0_JP
        jnz     fail
        mov     si, msg_pnpmode
        test    byte [card_cfg3], CFG3_PNP
        jnz     fail

        call    ee_begin
        xor     bl, bl
        call    ee_read             ; word 0 holds CONFIG1 and CONFIG2
        mov     [ee_word], ax
        call    ee_end
        ; the byte that matches the CONFIG1 register is CONFIG1
        mov     cl, [card_cfg1]
        and     cl, 7Fh
        mov     bx, ee_word         ; BX -> CONFIG2 byte in ee_word
        mov     ch, ah
        and     ch, 7Fh
        cmp     ch, cl
        je      .have
        inc     bx
        mov     ch, al
        and     ch, 7Fh
        cmp     ch, cl
        jne     .layout
.have:  mov     al, [bx]
        mov     ah, al
        and     al, 0E0h
        or      al, 18h
        or      al, [new_bs]
        cmp     al, ah
        je      .same
        mov     [bx], al
        call    ee_begin
        call    ee_ewen
        xor     bl, bl
        mov     ax, [ee_word]
        call    ee_write
        pushf
        call    ee_ewds
        popf
        jc      .eerr
        xor     bl, bl
        call    ee_read
        cmp     ax, [ee_word]
        jne     .eerr
        call    ee_end
        mov     si, msg_pm_done
        jmp     fail_ok
.same:  mov     si, msg_pm_same
        jmp     fail_ok
.layout:
        mov     si, msg_eelayout
        jmp     fail
.eerr:  call    ee_end
        mov     si, msg_eeerr
        jmp     fail
.badseg:
        mov     si, msg_badseg
        jmp     fail

done:   mov     ax, 4C00h
        int     21h
fail_ok:
        call    puts
        jmp     done
fail:   call    puts
        mov     ax, 4C01h
        int     21h

; ---------------------------------------------------------------- helpers
need_card:
        call    find_card
        jnc     .ok
        mov     si, msg_nocard
        jmp     fail
.ok:    ret

need_flash:
        call    need_card
        cmp     word [card_romseg], 0
        jne     .rom
        mov     si, msg_needpage
        jmp     fail
.rom:   call    flash_id
        jnc     .ok
        mov     si, msg_noflash
        jmp     fail
.ok:    ret

need_rom_settings:
        call    need_flash
        call    load_settings
        mov     byte [cur_set+SET_HOSTNAME+15], 0
        ret

store_settings:
        mov     si, cur_set
        call    settings_seal
        call    flash_enable
        mov     ax, 0               ; page 0
        mov     di, SET_OFFSET
        call    flash_erase
        jc      .err
        mov     si, cur_set
        mov     cx, SET_SIZE
.p:     lodsb
        mov     ah, al
        xor     al, al
        call    flash_byte
        jc      .err
        inc     di
        loop    .p
        call    flash_disable
        call    load_settings
        jc      .err2
        mov     si, msg_saved
        call    puts
        call    show_settings
        jmp     done
.err:   call    flash_disable
.err2:  mov     si, msg_flasherr
        jmp     fail

show_settings:
        mov     di, line_buf
        mov     si, msg_host
        call    copy_str
        mov     si, cur_set+SET_HOSTNAME
        call    copy_str
        mov     si, msg_crlf
        call    copy_str
        call    print_buf
        test    byte [cur_set+SET_FLAGS], SETF_DHCP
        jz      .static
        mov     si, msg_set_dhcp
        jmp     puts
.static:
        mov     bx, ip_labels
        mov     dx, cur_set+SET_IP
.l:     mov     si, [bx]
        or      si, si
        jz      .e
        mov     di, line_buf
        call    copy_str
        mov     si, dx
        call    fmt_ip
        mov     si, msg_crlf
        call    copy_str
        call    print_buf
        add     dx, 4
        add     bx, 2
        jmp     .l
.e:     ret

copy_str:
        lodsb
        or      al, al
        jz      .e
        stosb
        jmp     copy_str
.e:     ret

; next_word - copy the next blank separated word of the command tail to
; word_buf (zero terminated, length in word_len); CF=1 if there is none
next_word:
        push    si
        push    di
        mov     si, [tail_ptr]
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 9
        je      .sk
        cmp     al, 13
        je      .none
        mov     di, word_buf
        xor     cx, cx
.c:     cmp     cx, 127
        jae     .s
        stosb
        inc     cx
.s:     lodsb
        cmp     al, ' '
        je      .end
        cmp     al, 9
        je      .end
        cmp     al, 13
        jne     .c
.end:   dec     si
        mov     [tail_ptr], si
        mov     byte [di], 0
        mov     [word_len], cx
        pop     di
        pop     si
        clc
        ret
.none:  dec     si
        mov     [tail_ptr], si
        pop     di
        pop     si
        stc
        ret

; word_is - ZF=1 if word_buf equals the upper case keyword DS:SI (any case)
word_is:
        push    si
        push    di
        mov     di, word_buf
.c:     mov     al, [di]
        cmp     al, 'a'
        jb      .u
        cmp     al, 'z'
        ja      .u
        sub     al, 20h
.u:     cmp     al, [si]
        jne     .e
        inc     si
        inc     di
        or      al, al
        jnz     .c
.e:     pop     di
        pop     si
        ret

; parse_ip - word_buf as dotted quad to the 4 bytes at DS:DI; CF=1 on error
parse_ip:
        push    cx
        push    di
        mov     si, word_buf
        mov     cx, 4
.oct:   xor     ax, ax
        xor     bx, bx              ; BX = digits seen
.dig:   mov     dl, [si]
        sub     dl, '0'
        cmp     dl, 9
        ja      .sep
        mov     dh, 10
        mul     dh
        add     al, dl
        adc     ah, 0
        cmp     ax, 255
        ja      .bad
        inc     si
        inc     bx
        jmp     .dig
.sep:   or      bx, bx
        jz      .bad
        mov     [di], al
        inc     di
        mov     al, [si]
        inc     si
        cmp     cx, 1
        je      .last
        cmp     al, '.'
        jne     .bad
        loop    .oct
.last:  or      al, al
        jnz     .bad
        pop     di
        pop     cx
        clc
        ret
.bad:   pop     di
        pop     cx
        stc
        ret

; parse_hex - word_buf as hex number (optional 0x prefix, h suffix) -> AX
parse_hex:
        mov     si, word_buf
        cmp     byte [si], '0'
        jne     .go
        mov     al, [si+1]
        or      al, 20h
        cmp     al, 'x'
        jne     .go
        add     si, 2
.go:    xor     dx, dx
        xor     bx, bx
.c:     mov     al, [si]
        or      al, al
        jz      .end
        or      al, 20h
        cmp     al, 'h'
        jne     .d
        cmp     byte [si+1], 0
        je      .end
        jmp     .bad
.d:     sub     al, '0'
        cmp     al, 9
        jbe     .v
        sub     al, 'a' - '0' - 10
        cmp     al, 10
        jb      .bad
        cmp     al, 15
        ja      .bad
.v:     test    dh, 0F0h
        jnz     .bad
        mov     cl, 4
        shl     dx, cl
        or      dl, al
        inc     bx
        inc     si
        jmp     .c
.end:   or      bx, bx
        jz      .bad
        mov     ax, dx
        clc
        ret
.bad:   stc
        ret

; ---------------------------------------------------------------- flash
; flash_page - AL = page; clobbers AX, DX
flash_page:
        push    bx
        mov     bl, al
        mov     dx, [card_io]
        cli
        in      al, dx
        mov     bh, al
        and     al, 3Fh & ~CR_TXP
        or      al, CR_PAGE3
        out     dx, al
        add     dx, RTL_BPAGE
        mov     al, bl
        out     dx, al
        sub     dx, RTL_BPAGE
        mov     al, bh
        and     al, ~CR_TXP
        out     dx, al
        sti
        pop     bx
        ret

; flash_reg3 - write AL to page 3 register at offset BL; clobbers AX, DX
flash_reg3:
        push    bx
        push    cx
        mov     cl, al
        mov     dx, [card_io]
        cli
        in      al, dx
        mov     ch, al
        and     al, 3Fh & ~CR_TXP
        or      al, CR_PAGE3
        out     dx, al
        xor     bh, bh
        add     dx, bx
        mov     al, cl
        out     dx, al
        sub     dx, bx
        mov     al, ch
        and     al, ~CR_TXP
        out     dx, al
        sti
        pop     cx
        pop     bx
        ret

flash_enable:
        push    bx
        mov     bl, RTL_9346CR
        mov     al, 0C0h            ; EEM = 11, needed for FMWP
        call    flash_reg3
        mov     bl, RTL_FMWP
        mov     al, 57h
        call    flash_reg3
        mov     al, 0A8h
        call    flash_reg3
        pop     bx
        ret

flash_disable:
        push    ax
        push    bx
        push    dx
        mov     bl, RTL_FMWP
        xor     al, al
        call    flash_reg3
        mov     bl, RTL_9346CR
        xor     al, al
        call    flash_reg3
        xor     al, al
        call    flash_page
        pop     dx
        pop     bx
        pop     ax
        ret

; flash_unlock - write AAh to 5555h and 55h to 2AAAh; ES = ROM segment after
flash_unlock:
        mov     es, [card_romseg]
        mov     al, 1
        call    flash_page
        mov     byte [es:1555h], 0AAh
        xor     al, al
        call    flash_page
        mov     byte [es:2AAAh], 55h
        ret

; flash_cmd - AL = command byte, written to 5555h after the unlock
flash_cmd:
        push    ax
        call    flash_unlock
        mov     al, 1
        call    flash_page
        pop     ax
        mov     [es:1555h], al
        ret

; flash_id - read the JEDEC ID; CF=1 if it is no SST39SF010A/020A/040
flash_id:
        push    es
        call    flash_enable
        mov     al, 90h
        call    flash_cmd
        xor     al, al
        call    flash_page
        mov     al, [es:0000h]
        mov     ah, [es:0001h]
        mov     byte [es:0000h], 0F0h
        push    ax
        call    flash_disable
        pop     ax
        pop     es
        cmp     al, 0BFh
        jne     .bad
        mov     bx, 128
        cmp     ah, 0B5h
        je      .ok
        mov     bx, 256
        cmp     ah, 0B6h
        je      .ok
        mov     bx, 512
        cmp     ah, 0B7h
        jne     .bad
.ok:    mov     [flash_kib], bx
        clc
        ret
.bad:   stc
        ret

; flash_erase - erase the 4 KiB sector at page AL, offset DI; CF=1 on timeout
flash_erase:
        push    es
        push    ax
        mov     al, 80h
        call    flash_cmd
        call    flash_unlock
        pop     ax
        push    ax
        call    flash_page
        mov     byte [es:di], 30h
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     dx, [046Ch]
        pop     ds
.w:     cmp     byte [es:di], 0FFh
        je      .ok
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, [046Ch]
        pop     ds
        sub     ax, dx
        cmp     ax, 10              ; about half a second, typical 18 ms
        jb      .w
        pop     ax
        pop     es
        stc
        ret
.ok:    pop     ax
        pop     es
        clc
        ret

; flash_byte - program AH at page AL, offset DI; CF=1 on timeout
flash_byte:
        push    es
        push    cx
        push    ax
        mov     al, 0A0h
        call    flash_cmd
        pop     ax
        push    ax
        call    flash_page
        pop     ax
        push    ax
        mov     [es:di], ah
        mov     cx, 0FFFFh
.w:     cmp     [es:di], ah
        je      .ok
        loop    .w
        pop     ax
        pop     cx
        pop     es
        stc
        ret
.ok:    pop     ax
        pop     cx
        pop     es
        clc
        ret

; flash_sector - bring flash sector BP in line with sec_buf
; out: CF=1 on error, else AL = '.' (unchanged) or 'w' (written)
flash_sector:
        push    bx
        push    cx
        push    si
        push    di
        push    es
        mov     ax, bp
        mov     cl, 2
        shr     ax, cl
        mov     bl, al              ; BL = page
        mov     di, bp
        and     di, 3
        mov     cl, 12
        shl     di, cl              ; DI = offset in the page
        call    .cmp
        mov     al, '.'
        je      .done
        mov     al, bl
        call    flash_erase
        jc      .err
        mov     si, sec_buf
        mov     cx, SECTOR_SIZE
        push    di
.b:     lodsb
        cmp     al, 0FFh            ; erased bytes need no programming
        je      .skip
        mov     ah, al
        mov     al, bl
        call    flash_byte
        jc      .err1
.skip:  inc     di
        loop    .b
        pop     di
        call    .cmp
        jne     .err
        mov     al, 'w'
.done:  clc
.out:   pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        ret
.err1:  pop     di
.err:   stc
        jmp     .out
; .cmp - ZF=1 if page BL, offset DI equals sec_buf
.cmp:   mov     al, bl
        call    flash_page
        mov     es, [card_romseg]
        push    di
        mov     si, sec_buf
        mov     cx, SECTOR_SIZE
        repe    cmpsb
        pop     di
        ret

; ---------------------------------------------------------------- 93C46
EE_MODE equ 80h                     ; 9346CR: EEM = 10, programming mode
EE_CS   equ 08h
EE_SK   equ 04h
EE_DI   equ 02h

; ee_begin - page 3, 9346 programming mode, interrupts off; DX = 9346CR
ee_begin:
        mov     dx, [card_io]
        cli
        in      al, dx
        mov     [ee_cr], al
        and     al, 3Fh & ~CR_TXP
        or      al, CR_PAGE3
        out     dx, al
        inc     dx
        mov     al, EE_MODE
        out     dx, al
        ret

ee_end: mov     dx, [card_io]
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        mov     al, [ee_cr]
        and     al, ~CR_TXP
        out     dx, al
        sti
        ret

ee_delay:
        push    ax
        in      al, dx
        in      al, dx
        in      al, dx
        in      al, dx
        pop     ax
        ret

; ee_send - send the top CL bits of SI, chip select stays high
ee_send:
        push    ax
.b:     mov     al, EE_MODE | EE_CS
        shl     si, 1
        jnc     .z
        or      al, EE_DI
.z:     out     dx, al
        call    ee_delay
        or      al, EE_SK
        out     dx, al
        call    ee_delay
        and     al, ~EE_SK
        out     dx, al
        call    ee_delay
        dec     cl
        jnz     .b
        pop     ax
        ret

; ee_recv - read 16 bits to AX
ee_recv:
        push    bx
        push    cx
        mov     cx, 16
        xor     bx, bx
.b:     mov     al, EE_MODE | EE_CS | EE_SK
        out     dx, al
        call    ee_delay
        in      al, dx
        shr     al, 1
        rcl     bx, 1
        mov     al, EE_MODE | EE_CS
        out     dx, al
        call    ee_delay
        loop    .b
        mov     ax, bx
        pop     cx
        pop     bx
        ret

ee_deselect:
        push    ax
        mov     al, EE_MODE
        out     dx, al
        call    ee_delay
        pop     ax
        ret

; ee_read - BL = word address -> AX
ee_read:
        push    cx
        push    si
        call    ee_deselect
        mov     al, bl
        and     ax, 3Fh
        or      ax, 180h            ; start bit, opcode 10
        mov     si, ax
        mov     cl, 7
        shl     si, cl
        mov     cl, 9
        call    ee_send
        call    ee_recv
        call    ee_deselect
        pop     si
        pop     cx
        ret

ee_ewen:
        push    si
        mov     si, 130h << 7
        jmp     ee_short
ee_ewds:
        push    si
        mov     si, 100h << 7
ee_short:
        push    cx
        call    ee_deselect
        mov     cl, 9
        call    ee_send
        call    ee_deselect
        pop     cx
        pop     si
        ret

; ee_write - write AX to word address BL; CF=1 on timeout
ee_write:
        push    cx
        push    si
        push    ax
        call    ee_deselect
        mov     al, bl
        and     ax, 3Fh
        or      ax, 140h            ; start bit, opcode 01
        mov     si, ax
        mov     cl, 7
        shl     si, cl
        mov     cl, 9
        call    ee_send
        pop     si
        push    si
        mov     cl, 16
        call    ee_send
        call    ee_deselect
        mov     al, EE_MODE | EE_CS ; busy until DO goes high
        out     dx, al
        mov     cx, 0FFFFh
.w:     in      al, dx
        test    al, 01h
        jnz     .ok
        loop    .w
        call    ee_deselect
        pop     ax
        pop     si
        pop     cx
        stc
        ret
.ok:    call    ee_deselect
        pop     ax
        pop     si
        pop     cx
        clc
        ret

%include "src/rtl8019.inc"
%include "src/dos.inc"

commands:       dw  kw_show, cmd_show, kw_dhcp, cmd_dhcp, kw_static, cmd_static
                dw  kw_name, cmd_name, kw_flash, cmd_flash, kw_pagemode, cmd_pagemode, 0
kw_show:        db  'SHOW', 0
kw_dhcp:        db  'DHCP', 0
kw_static:      db  'STATIC', 0
kw_name:        db  'NAME', 0
kw_flash:       db  'FLASH', 0
kw_pagemode:    db  'PAGEMODE', 0
opt_all:        db  '/ALL', 0

msg_banner:     db  'NETCFG ', VERSION_STR, ' - ISA ETH Boot ROM (c) SteFam', 13, 10, 0
msg_usage:      db  'Usage: NETCFG [SHOW]', 13, 10
                db  '       NETCFG DHCP', 13, 10
                db  '       NETCFG STATIC ip mask gateway dns', 13, 10
                db  '       NETCFG NAME hostname', 13, 10
                db  '       NETCFG FLASH image.bin [/ALL]', 13, 10
                db  '       NETCFG PAGEMODE segment   (C000-DC00, jumperless mode)', 13, 10, 0
msg_nocard:     db  'No RTL8019AS found.', 13, 10, 0
msg_card:       db  'Card:      RTL8019AS at I/O ', 0
msg_irq:        db  'h, IRQ ', 0
msg_crlf:       db  13, 10, 0
msg_h_crlf:     db  'h', 13, 10, 0
msg_mode_pnp:   db  'Mode:      Plug and Play', 13, 10, 0
msg_mode_dip:   db  'Mode:      DIP switches', 13, 10, 0
msg_mode_sw:    db  'Mode:      jumperless (EEPROM)', 13, 10, 0
msg_rom_nopage: db  'Boot ROM:  off or not in page mode', 13, 10, 0
msg_set_none:   db  'Settings:  need the boot ROM in page mode', 13, 10, 0
msg_rom_page:   db  'Boot ROM:  page mode at ', 0
msg_flash:      db  'Flash:     SST39SF, ', 0
msg_kib:        db  ' KiB', 13, 10, 0
msg_noflash:    db  'Flash:     no SST39SF010A/020A/040 found', 13, 10, 0
msg_set_def:    db  'Settings:  none stored, defaults:', 13, 10, 0
msg_host:       db  'Host name: ', 0
msg_set_dhcp:   db  'Address:   DHCP', 13, 10, 0
msg_ip:         db  'Address:   ', 0
msg_mask:       db  'Netmask:   ', 0
msg_gw:         db  'Gateway:   ', 0
msg_dns:        db  'DNS:       ', 0
ip_labels:      dw  msg_ip, msg_mask, msg_gw, msg_dns, 0
msg_saved:      db  'Settings saved.', 13, 10, 0
msg_badip:      db  'Invalid address.', 13, 10, 0
msg_badname:    db  'Host name: 1 to 15 characters.', 13, 10, 0
msg_needpage:   db  'The boot ROM is not in page mode, see NETCFG PAGEMODE.', 13, 10, 0
msg_nofile:     db  'Cannot open the image file.', 13, 10, 0
msg_badsize:    db  'Image size must be a multiple of 4 KiB and fit the flash.', 13, 10, 0
msg_notimage:   db  13, 10, 'Not an ISA ETH Boot ROM image.', 13, 10, 0
msg_readerr:    db  13, 10, 'Read error.', 13, 10, 0
msg_flashing:   db  'Writing (. same, w written, s settings kept): ', 0
msg_flashed:    db  13, 10, 'Done. Restart the PC to use the new ROM.', 13, 10, 0
msg_flasherr:   db  13, 10, 'Flash write failed.', 13, 10, 0
msg_badseg:     db  'Segment must be C000, C400, ... DC00.', 13, 10, 0
msg_dipmode:    db  'The card is in DIP switch mode: set page mode with SW4.', 13, 10, 0
msg_pnpmode:    db  'The card is in Plug and Play mode, not supported.', 13, 10, 0
msg_eelayout:   db  'Unexpected EEPROM content, nothing written.', 13, 10, 0
msg_eeerr:      db  'EEPROM write failed.', 13, 10, 0
msg_pm_done:    db  'EEPROM updated. Switch the PC off and on to apply.', 13, 10, 0
msg_pm_same:    db  'Page mode at this segment is already set.', 13, 10, 0

section .bss
card_io:        resw 1
card_romseg:    resw 1
card_irq:       resb 1
card_cfg0:      resb 1
card_cfg1:      resb 1
card_cfg2:      resb 1
card_cfg3:      resb 1
new_bs:         resb 1
keep_set:       resb 1
ee_cr:          resb 1
ee_word:        resw 1
flash_kib:      resw 1
tail_ptr:       resw 1
word_len:       resw 1
file_handle:    resw 1
file_sectors:   resw 1
cur_set:        resb SET_SIZE
new_ip:         resb 16
word_buf:       resb 128
file_name:      resb 128
line_buf:       resb 256
sec_buf:        resb SECTOR_SIZE
                resb 512
stack_top:
