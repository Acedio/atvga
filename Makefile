MCU_TARGET     = attiny85
OPTIMIZE       = -Os
CC             = avr-gcc

override AFLAGS        = -nostdlib -Wall -mmcu=$(MCU_TARGET)
override LDFLAGS       = -Wl,-Tdata,0x800180

all: atvga.hex

atvga.o: font.inc

%.o: %.S
	$(CC) -c $(AFLAGS) -o $@ $<

%.elf: %.o
	$(CC) $(LDFLAGS) -o $@ $^

%.hex: %.elf
	avr-objcopy -j .text -j .data -O ihex $< $@

font.pbm: font.png
	convert $< -compress none $@

font.inc: font.pbm
	tail -n +4 $< | paste -s | sed -E 's/\s//g' | sed -E 's/(........)/0b\1, /g' | sed 's/^/.byte /' | sed 's/, $$//' > $@

upload: atvga.hex
	avrdude -p t85 -c ftdifriend -b 19200 -u -U flash:w:$<

clean:
	rm -rf *.o
	rm -rf *.hex
	rm -rf *.elf
	rm -rf font.pbm font.inc
