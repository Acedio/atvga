PROJECT        = atvga
MCU_TARGET     = attiny85
OPTIMIZE       = -Os
CC             = avr-gcc

override AFLAGS        = -nostdlib -Wall -mmcu=$(MCU_TARGET)
override LDFLAGS       = -Wl,-Tdata,0x800180

all: $(PROJECT).hex

%.o: %.S
	$(CC) -c $(AFLAGS) -o $@ $<

%.elf: %.o
	$(CC) $(LDFLAGS) -o $@ $^

%.hex: %.elf
	avr-objcopy -j .text -j .data -O ihex $< $@

upload: $(PROJECT).hex
	avrdude -p t85 -c ftdifriend -b 19200 -u -U flash:w:$<

clean:
	rm -rf *.o
	rm -rf *.hex
	rm -rf *.elf
