; Small DOS helpers shared by the DOS tools (DS = CS = program segment)

; puts - print zero terminated string DS:SI
puts:   push    ax
        push    dx
.l:     lodsb
        or      al, al
        jz      .e
        mov     dl, al
        mov     ah, 02h
        int     21h
        jmp     .l
.e:     pop     dx
        pop     ax
        ret

; putc - print character AL
putc:   push    ax
        push    dx
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     dx
        pop     ax
        ret

; fmt_dec - write AX as decimal to ES:DI, DI advances
fmt_dec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.o:     pop     ax
        add     al, '0'
        stosb
        loop    .o
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; fmt_hex - write AX as hex without leading zeros to ES:DI, DI advances
fmt_hex:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dx, ax
        mov     bx, 4
        xor     ah, ah              ; AH = 1 after the first digit
.d:     mov     cl, 4
        rol     dx, cl
        mov     al, dl
        and     al, 0Fh
        jnz     .p
        or      ah, ah
        jnz     .p
        cmp     bx, 1
        jne     .n
.p:     mov     ah, 1
        add     al, '0'
        cmp     al, '9'
        jbe     .s
        add     al, 7
.s:     stosb
.n:     dec     bx
        jnz     .d
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; fmt_ip - write the IPv4 address at DS:SI as dotted decimal to ES:DI
fmt_ip: push    ax
        push    cx
        push    si
        mov     cx, 4
.b:     lodsb
        xor     ah, ah
        call    fmt_dec
        dec     cx
        jz      .e
        mov     al, '.'
        stosb
        jmp     .b
.e:     pop     si
        pop     cx
        pop     ax
        ret

; print_buf - print ES:DI-terminated text that starts at line_buf, reset DI
print_buf:
        xor     al, al
        stosb
        mov     si, line_buf
        call    puts
        mov     di, line_buf
        ret

; settings_valid - CF=0 if the 64-byte settings record at DS:SI is valid
settings_valid:
        push    ax
        push    cx
        push    si
        cmp     word [si+SET_MAGIC], 'NC'
        jne     .bad
        cmp     word [si+SET_MAGIC+2], 'FG'
        jne     .bad
        cmp     byte [si+SET_VERSION], 1
        jne     .bad
        mov     cx, SET_SIZE
        xor     ah, ah
.s:     lodsb
        add     ah, al
        loop    .s
        or      ah, ah
        jnz     .bad
        clc
        jmp     .e
.bad:   stc
.e:     pop     si
        pop     cx
        pop     ax
        ret

; settings_seal - fix the checksum of the settings record at DS:SI
settings_seal:
        push    ax
        push    cx
        push    si
        mov     byte [si+SET_CHECKSUM], 0
        mov     cx, SET_SIZE
        xor     ah, ah
.s:     lodsb
        add     ah, al
        loop    .s
        neg     ah
        pop     si
        mov     [si+SET_CHECKSUM], ah
        pop     cx
        pop     ax
        ret

; settings_default - fill the record at ES:DI with DHCP and host name RETROPC
settings_default:
        push    cx
        push    di
        push    si
        mov     cx, SET_SIZE
        xor     al, al
        push    di
        rep     stosb
        pop     di
        mov     word [es:di+SET_MAGIC], 'NC'
        mov     word [es:di+SET_MAGIC+2], 'FG'
        mov     byte [es:di+SET_VERSION], 1
        mov     byte [es:di+SET_FLAGS], SETF_DHCP
        push    di
        add     di, SET_HOSTNAME
        mov     si, default_host
.c:     lodsb
        stosb
        or      al, al
        jnz     .c
        pop     si
        push    ds
        push    es
        pop     ds
        call    settings_seal
        pop     ds
        pop     si
        pop     di
        pop     cx
        ret

default_host:   db  'RETROPC', 0

; find_card - probe for the first RTL8019AS and fill the card_* variables
; out: CF=1 if no card was found
find_card:
        xor     si, si
        call    rtl_probe
        jc      .e
        mov     [card_io], dx
        mov     [card_cfg0], bl
        mov     [card_cfg1], al
        mov     [card_cfg2], ah
        mov     [card_cfg3], bh
        push    ax
        call    rtl_irq
        mov     [card_irq], al
        pop     ax
        call    rtl_romseg
        mov     [card_romseg], ax
        clc
.e:     ret

; load_settings - copy the settings from the ROM (or defaults) to cur_set
; out: CF=1 if the defaults were used
load_settings:
        push    ds
        push    es
        push    cs
        pop     es
        mov     ax, [card_romseg]
        or      ax, ax
        jz      .def
        mov     ds, ax
        mov     si, SET_OFFSET
        call    settings_valid
        jc      .def
        mov     di, cur_set
        mov     cx, SET_SIZE
        rep     movsb
        pop     es
        pop     ds
        clc
        ret
.def:   pop     es
        pop     ds
        mov     di, cur_set
        call    settings_default
        stc
        ret
