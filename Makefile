# ISA ETH Boot ROM - build with NASM and Python 3
#
#   make                 ROM, tools and build/ethboot.bin
#   make MTCP=dir        take the mTCP programs from dir (default: mtcp/)
#   make test            run the emulator tests
#
# NE2000.COM is the 8-bit packet driver from skiselev/isa8_eth; mTCP comes
# from https://www.brutman.com/mTCP/ (use the UPX packed build to save space).

NASM    ?= nasm
PYTHON  ?= python3
MTCP    ?= mtcp
DRIVER  ?= $(MTCP)/NE2000.COM
SIZE    ?= 512
MTCP_PROGS ?= DHCP.EXE PING.EXE HTGET.EXE SNTP.EXE FTP.EXE TELNET.EXE NETDRIVE.EXE NETDRIVE.SYS COPYING.TXT
# Realtek card tools from skiselev/isa8_eth (optional, packed with UPX --8086 to fit)
CARD_TOOLS ?= $(wildcard $(MTCP)/RSET8019.EXE $(MTCP)/PG8019.EXE $(MTCP)/8019AS.CFG)

B = build
INC = src/version.inc src/layout.inc src/rtl8019.inc src/dos.inc

all: $(B)/ethboot.bin

$(B):
	mkdir -p $(B)

$(B)/ethrom.bin: src/ethrom.asm $(INC) | $(B)
	$(NASM) -f bin -o $@ $<

$(B)/bootstub.bin: src/bootstub.asm | $(B)
	$(NASM) -f bin -o $@ $<

$(B)/NETSTART.COM: src/netstart.asm $(INC) | $(B)
	$(NASM) -f bin -o $@ $<

$(B)/NETCFG.COM: src/netcfg.asm $(INC) | $(B)
	$(NASM) -f bin -o $@ $<

$(B)/README.TXT: docs/ROMDRIVE.TXT | $(B)
	cp $< $@

TOOLS = $(B)/NETSTART.COM $(B)/NETCFG.COM $(B)/README.TXT

$(B)/ethboot.bin: $(B)/ethrom.bin $(B)/bootstub.bin $(TOOLS) tools/mkimage.py
	$(PYTHON) tools/mkimage.py --size $(SIZE) -o $@ $(TOOLS) $(DRIVER) $(CARD_TOOLS) \
		$(foreach p,$(MTCP_PROGS),$(firstword $(wildcard $(MTCP)/$(p) $(MTCP)/$(shell echo $(p) | tr A-Z a-z))))

test: $(B)/ethrom.bin $(B)/bootstub.bin $(TOOLS)
	$(PYTHON) -m unittest discover -s tests -v

clean:
	rm -rf $(B)

.PHONY: all test clean
