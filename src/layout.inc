; Layout of the flash image, shared by the ROM, the DOS tools and tools/mkimage.py
;
; Page 0 (16 KiB window, visible after reset):
;   0000h-2FFFh  option ROM code (checksum covers this range only)
;   3000h-3FFFh  settings sector (one 4 KiB flash sector, see SET_* below)
; Pages 1..n:    read-only ROM drive, 32 sectors (one cylinder) per page

ROM_CODE_SIZE   equ 3000h           ; bytes covered by the option ROM checksum
SET_OFFSET      equ 3000h           ; settings sector inside page 0
PAGE_SIZE       equ 4000h

; ROM header fields after the 55AAh signature (offsets inside page 0)
HDR_MAGIC       equ 0010h           ; 'ETHR'
HDR_VERSION     equ 0014h           ; major, minor, patch
HDR_CYLS        equ 0017h           ; ROM drive cylinders (= pages)
HDR_HEADS       equ 0018h
HDR_SPT         equ 0019h
HDR_FIRSTPAGE   equ 001Ah           ; first page of the ROM drive

; Settings record (64 bytes at SET_OFFSET)
SET_MAGIC       equ 0               ; 'NCFG'
SET_VERSION     equ 4               ; 1
SET_FLAGS       equ 5               ; bit 0: use DHCP
SET_IP          equ 6
SET_MASK        equ 10
SET_GATEWAY     equ 14
SET_DNS         equ 18
SET_HOSTNAME    equ 22              ; 16 bytes, zero terminated
SET_CHECKSUM    equ 63              ; sum of all 64 bytes is 0
SET_SIZE        equ 64
SETF_DHCP       equ 01h

PKT_INT         equ 60h             ; software interrupt of the packet driver
