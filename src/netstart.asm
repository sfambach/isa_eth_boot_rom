; NETSTART - bring the network up from the ISA ETH Boot ROM drive
;
; Finds the RTL8019AS, writes the network part of the file named by MTCPCFG
; from the ROM settings (other lines are kept), loads NE2000.COM with the
; detected IRQ and I/O base and runs DHCP.EXE when DHCP is selected.
; NE2000.COM and DHCP.EXE are taken from the directory NETSTART runs from.
;
; Copyright (C) 2026 Stefan Fambach (SteFam), https://www.fambach.net
; PolyForm Noncommercial License 1.0.0, see LICENSE.md

        cpu     8086
        bits    16
        org     100h

%include "src/version.inc"
%include "src/layout.inc"

CFG_MAX equ 6000                    ; largest MTCP.CFG that is kept

start:  mov     sp, stack_top
        mov     si, msg_banner
        call    puts

        call    find_card
        jnc     .card
        mov     si, msg_nocard
        jmp     fail
.card:  mov     di, line_buf
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

        call    load_settings
        mov     byte [cur_set+SET_HOSTNAME+15], 0
        jnc     .set
        mov     si, msg_defaults
        call    puts
.set:   call    find_env_cfg
        jnc     .cfg
        mov     si, msg_noenv
        jmp     fail
.cfg:   call    write_cfg
        jnc     .own
        mov     si, msg_cfgerr
        jmp     fail

.own:   call    own_dir             ; prog_path = directory of NETSTART

        ; release the memory above the program for the children
        mov     bx, prog_end + 15
        mov     cl, 4
        shr     bx, cl
        mov     ah, 4Ah
        int     21h

        call    pkt_present
        jnc     .dhcp
        mov     si, name_driver
        call    set_prog
        mov     di, tail_buf+1      ; " 0x60 <irq> 0x<io>"
        mov     si, txt_drvarg
        call    copy_str
        mov     al, [card_irq]
        xor     ah, ah
        call    fmt_dec
        mov     si, txt_space0x
        call    copy_str
        mov     ax, [card_io]
        call    fmt_hex
        call    run
        jc      .exfail
        call    pkt_present
        jnc     .dhcp
        mov     si, msg_drvfail
        jmp     fail

.dhcp:  test    byte [cur_set+SET_FLAGS], SETF_DHCP
        jz      .done
        mov     si, name_dhcp
        call    set_prog
        mov     di, tail_buf+1
        call    run
        jc      .exfail
        mov     ah, 4Dh
        int     21h
        mov     ah, 4Ch
        int     21h
.done:  mov     si, msg_static
        call    puts
        mov     ax, 4C00h
        int     21h
.exfail:
        mov     si, msg_execerr
        call    puts
        mov     si, prog_path
        call    puts
        mov     si, msg_crlf
fail:   call    puts
        mov     ax, 4C01h
        int     21h

; copy_str - copy zero terminated DS:SI to ES:DI without the terminator
copy_str:
        lodsb
        or      al, al
        jz      .e
        stosb
        jmp     copy_str
.e:     ret

; pkt_present - CF=1 if no packet driver answers at PKT_INT
pkt_present:
        push    es
        xor     ax, ax
        mov     es, ax
        les     di, [es:PKT_INT*4]
        add     di, 3
        mov     si, pkt_sig
        mov     cx, 8
        repe    cmpsb
        pop     es
        je      .yes
        stc
        ret
.yes:   clc
        ret

; find_env_cfg - copy the value of MTCPCFG to cfg_name, CF=1 if not set
find_env_cfg:
        push    ds
        mov     ds, [2Ch]
        xor     si, si
.var:   cmp     byte [si], 0
        je      .none
        mov     di, env_key
        mov     cx, env_key_len
        push    si
        repe    cmpsb
        je      .hit
        pop     si
.skip:  lodsb
        or      al, al
        jnz     .skip
        jmp     .var
.hit:   add     sp, 2
        mov     di, cfg_name
        mov     cx, 127
.c:     lodsb
        stosb
        or      al, al
        jz      .ok
        loop    .c
        mov     byte [es:di], 0
.ok:    pop     ds
        clc
        ret
.none:  pop     ds
        stc
        ret

; own_dir - copy the directory of this program (from the environment) to
; prog_path and set prog_name to the position after it
own_dir:
        push    ds
        mov     ds, [2Ch]
        xor     si, si
.v:     lodsb                       ; skip the variables up to the double zero
        or      al, al
        jnz     .v
        lodsb
        or      al, al
        jnz     .v
        lodsw                       ; string count (DOS 3+)
        mov     di, prog_path
        mov     bx, di              ; BX = after the last '\' or ':'
.c:     lodsb
        stosb
        cmp     al, '\'
        je      .sep
        cmp     al, ':'
        je      .sep
        or      al, al
        jnz     .c
        jmp     .e
.sep:   mov     bx, di
        jmp     .c
.e:     pop     ds
        mov     [prog_name], bx
        ret

; set_prog - append file name DS:SI to the directory in prog_path
set_prog:
        mov     di, [prog_name]
.c:     lodsb
        stosb
        or      al, al
        jnz     .c
        ret

; run - execute prog_path with the tail text from tail_buf+1 up to DI
; out: CF=1 if DOS could not start it
run:    mov     ax, di
        sub     ax, tail_buf+1
        mov     [tail_buf], al
        mov     al, 13
        stosb
        mov     word [exec_blk], 0
        mov     word [exec_blk+2], tail_buf
        mov     [exec_blk+4], cs
        mov     word [exec_blk+6], 5Ch
        mov     [exec_blk+8], cs
        mov     word [exec_blk+10], 6Ch
        mov     [exec_blk+12], cs
        mov     [save_sp], sp
        mov     dx, prog_path
        mov     bx, exec_blk
        mov     ax, 4B00h
        int     21h
        cli                         ; DOS 2 does not keep SS:SP
        mov     bx, cs
        mov     ss, bx
        mov     sp, [cs:save_sp]
        sti
        mov     ds, bx
        mov     es, bx
        cld
        ret

; write_cfg - rewrite cfg_name: keep foreign lines, add ours
; out: CF=1 on a file error
write_cfg:
        mov     word [cfg_len], 0
        mov     dx, cfg_name
        mov     ax, 3D00h
        int     21h
        jc      .new
        mov     bx, ax
        mov     dx, cfg_buf
        mov     cx, CFG_MAX
        mov     ah, 3Fh
        int     21h
        jc      .close
        mov     [cfg_len], ax
.close: mov     ah, 3Eh
        int     21h
.new:   mov     dx, cfg_name
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jc      .err
        mov     [cfg_handle], ax

        ; copy every line whose keyword we do not manage
        mov     si, cfg_buf
        mov     bp, si
        add     bp, [cfg_len]
.line:  cmp     si, bp
        jae     .ours
        mov     dx, si              ; DX = start of the line
.eol:   cmp     si, bp
        jae     .got
        lodsb
        cmp     al, 10
        jne     .eol
.got:   call    managed_line
        jnc     .line
        push    si
        mov     cx, si
        sub     cx, dx
        mov     bx, [cfg_handle]
        mov     ah, 40h
        int     21h
        pop     si
        jc      .werr
        ; a last line without newline gets one
        mov     bx, si
        cmp     byte [bx-1], 10
        je      .line
        mov     dx, msg_crlf
        mov     cx, 2
        mov     bx, [cfg_handle]
        mov     ah, 40h
        int     21h
        jmp     .line

.ours:  mov     di, line_buf
        mov     si, key_packetint
        call    copy_str
        mov     si, txt_pktint
        call    copy_str
        mov     si, key_hostname
        call    copy_str
        mov     al, ' '
        stosb
        mov     si, cur_set+SET_HOSTNAME
        call    copy_str
        mov     si, msg_crlf
        call    copy_str
        test    byte [cur_set+SET_FLAGS], SETF_DHCP
        jnz     .write
        mov     bx, ip_keys
        mov     dx, cur_set+SET_IP
.ip:    mov     si, [bx]
        or      si, si
        jz      .write
        call    copy_str
        mov     al, ' '
        stosb
        mov     si, dx
        call    fmt_ip
        mov     si, msg_crlf
        call    copy_str
        add     dx, 4
        add     bx, 2
        jmp     .ip
.write: mov     cx, di
        sub     cx, line_buf
        mov     dx, line_buf
        mov     bx, [cfg_handle]
        mov     ah, 40h
        int     21h
        jc      .werr
        mov     ah, 3Eh
        int     21h
        clc
        ret
.werr:  mov     bx, [cfg_handle]
        mov     ah, 3Eh
        int     21h
.err:   stc
        ret

; managed_line - CF=0 if the line at DX starts with one of our keywords
; (followed by a blank or the line end); keeps SI, BP
managed_line:
        push    si
        mov     bx, managed_keys
.k:     mov     di, [bx]
        or      di, di
        jz      .no
        mov     si, dx
.c:     mov     al, [di]
        or      al, al
        jz      .end
        mov     ah, [si]
        cmp     ah, 'a'
        jb      .u
        cmp     ah, 'z'
        ja      .u
        sub     ah, 20h
.u:     cmp     al, ah
        jne     .nx
        inc     si
        inc     di
        jmp     .c
.end:   mov     al, [si]
        cmp     al, ' '
        je      .yes
        cmp     al, 9
        je      .yes
        cmp     al, 13
        je      .yes
        cmp     al, 10
        je      .yes
.nx:    add     bx, 2
        jmp     .k
.yes:   pop     si
        clc
        ret
.no:    pop     si
        stc
        ret

%include "src/rtl8019.inc"
%include "src/dos.inc"

msg_banner:     db  'NETSTART ', VERSION_STR, ' - ISA ETH Boot ROM (c) SteFam', 13, 10, 0
msg_nocard:     db  'No RTL8019AS found.', 13, 10, 0
msg_card:       db  'RTL8019AS at I/O ', 0
msg_irq:        db  'h, IRQ ', 0
msg_crlf:       db  13, 10, 0
msg_defaults:   db  'No settings in the ROM, using DHCP.', 13, 10, 0
msg_noenv:      db  'MTCPCFG is not set, e.g. SET MTCPCFG=C:\MTCP.CFG', 13, 10, 0
msg_cfgerr:     db  'Cannot write the file named by MTCPCFG.', 13, 10, 0
msg_execerr:    db  'Cannot run ', 0
msg_drvfail:    db  'The packet driver did not install.', 13, 10, 0
msg_static:     db  'Network is up with a fixed address.', 13, 10, 0
name_driver:    db  'NE2000.COM', 0
name_dhcp:      db  'DHCP.EXE', 0
txt_drvarg:     db  ' 0x60 ', 0
txt_space0x:    db  ' 0x', 0
txt_pktint:     db  ' 0x60', 13, 10, 0
pkt_sig:        db  'PKT DRVR'
env_key:        db  'MTCPCFG='
env_key_len     equ $ - env_key

key_packetint:  db  'PACKETINT', 0
key_hostname:   db  'HOSTNAME', 0
key_ipaddr:     db  'IPADDR', 0
key_netmask:    db  'NETMASK', 0
key_gateway:    db  'GATEWAY', 0
key_nameserver: db  'NAMESERVER', 0
key_dhcpver:    db  'DHCPVER', 0
key_timestamp:  db  'TIMESTAMP', 0
key_lease:      db  'LEASE_TIME', 0
managed_keys:   dw  key_packetint, key_hostname, key_ipaddr, key_netmask
                dw  key_gateway, key_nameserver, key_dhcpver, key_timestamp, key_lease, 0
ip_keys:        dw  key_ipaddr, key_netmask, key_gateway, key_nameserver, 0

        align   2
section .bss
card_io:        resw 1
card_romseg:    resw 1
card_irq:       resb 1
card_cfg0:      resb 1
card_cfg1:      resb 1
card_cfg2:      resb 1
card_cfg3:      resb 1
                resb 1
cur_set:        resb SET_SIZE
cfg_name:       resb 128
prog_path:      resb 160
prog_name:      resw 1
tail_buf:       resb 128
exec_blk:       resw 7
save_sp:        resw 1
cfg_len:        resw 1
cfg_handle:     resw 1
line_buf:       resb 256
cfg_buf:        resb CFG_MAX
                resb 512
stack_top:
prog_end:
