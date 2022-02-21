#include <avr/io.h>

; Fuse bytes for ATTiny85
; EFUSE and HFUSE at default
; LFUSE = 0xCF
; (No clk div, no clk out, slow rising power, ceramic resonator >8MHz)
; XTAL1 and XTAL2 have a 16MHz ceramic resonator connected.

.text
; Interrupt vectors.
rjmp main ; RESET
nop
nop
nop
rjmp hsync_start ; Timer 1 overflow.
nop
nop
nop
nop
nop
nop
nop
nop
nop
nop

; PB1 is the data output for three-wire mode SPI.
#define COLOR_PIN 1
; PB0 is the inverted OC1A (~OC1A) output.
#define HSYNC_PIN 0
#define VSYNC_PIN 2

#define SCANLINE_LREG 24
#define PIXEL_SCANLINE_REG 18
#define PIXELY_REG 19

; Number of system clock ticks per timer tick. This needs to match what is set
; in TCCRx.
#define CLOCKS_PER_TICK 2
; 250 is a nice base in that it's under 256 (fits in a TCNTx) and all the HSYNC
; timings we need are divisors of it. This is in timer ticks (/2), not clock
; ticks.
#define TICKS_PER_LINE 250
; Amount of TCNTx ticks the HSYNC pin should be held low during the sync pulse.
; Note that this is halved relative to the system clock because of the timer
; prescaler (it's really 60 clock ticks).
#define HSYNC_TICKS 30
; In system clock ticks.
#define HSYNC_BPORCH 30

#define VISIBLE_LINES 480
#define VSYNC_FPORCH 10
#define VSYNC_LENGTH 2
#define VSYNC_BPORCH 33

.global main
main:
  cli

; Wait for a second before starting to make it easier to program :P
  clr ZH
  clr ZL
  clr r0
1:
2:
  adiw ZL, 1
  brne 2b
  inc r0
  brne 1b

  ; Set up the stack.
  ldi r16, 0x5E
  out _SFR_IO_ADDR(SPL), r16
  ldi r16, 0x02
  out _SFR_IO_ADDR(SPH), r16

  ; Set up output pins.
  ; The color pin (PB1) is OC1A, which would be toggled as a timer output if we
  ; didn't set it as an input here. It will be set as an output only when we're
  ; outputting video.
  ldi r16, _BV(HSYNC_PIN) | _BV(VSYNC_PIN)
  out _SFR_IO_ADDR(DDRB), r16

  ; Disable the pullup on the color pin because we have a pull-down setup there.
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN

  ; Sync pins start high (pulse low)
  sbi _SFR_IO_ADDR(PORTB), HSYNC_PIN
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN

; Set up the two timers. Timer 1 is used to control the HSYNC pin and uses a
; prescaler, while timer 0 has the same phase but no prescaler.

; Pause both timers so we can initialize them. This also disables OC1B output.
  ldi r16, _BV(TSM) | _BV(PSR1) | _BV(PSR0)
  out _SFR_IO_ADDR(GTCCR), r16

; Set up timer 1 to control hsync.

; PWM1A enables PWM with OCR1A.
; COM1A[1:0] = 0b01 causes ~OC1A (inverted) to set on compare match and clear
; at 0. This means the HSYNC pulse starts at 0.
; CS1[3:0] = 0b010 scales CK/2 for the timer input.
  ldi r16, _BV(PWM1A) | _BV(COM1A0) | _BV(CS11)
  out _SFR_IO_ADDR(TCCR1), r16

; OCR1C is the top value of timer1. Interrupt TOV1 is fired after the match.
; When the counter hits 253, i.e. once every 254 cycles, it resets to 0 and
; clears OC1A.
  ldi r16, TICKS_PER_LINE-1
  out _SFR_IO_ADDR(OCR1C), r16

; When OCR1A is matched, ~OC1A (inverted) is set (end of the HSYNC pulse).
  ldi r16, HSYNC_TICKS
  out _SFR_IO_ADDR(OCR1A), r16

; Enable interrupts for when the counter overflows (the sync pulse starts).
  ldi r16, _BV(TOIE1)
  out _SFR_IO_ADDR(TIMSK), r16

; Clear the interrupt flag just in case it's set.
  ldi r16, _BV(TOV1)
  out _SFR_IO_ADDR(TIFR), r16

; Set up timer0 to be in the same phase as timer1, but at the system clock
; speed. This is used to correct for delays in interrupt handling (since the
; time it takes to serve an interrupt depends on how many cycles the currently
; running instruction takes).

; No compare match output, CTC mode.
  ldi r16, _BV(WGM01)
  out _SFR_IO_ADDR(TCCR0A), r16
; No prescaling.
  ldi r16, _BV(CS00)
  out _SFR_IO_ADDR(TCCR0B), r16
; Same number of ticks as timer1 (no prescaler so twice as fast).
  ldi r16, TICKS_PER_LINE-1
  out _SFR_IO_ADDR(OCR0A), r16

  ; Start on line -1.
  ldi SCANLINE_LREG, lo8(-1)
  ldi SCANLINE_LREG+1, hi8(-1)

; Initialize the tilemap to something interesting.
  ldi XL, 0x20
  ldi XH, 1
  ldi ZL, lo8(INITIAL_TILEMAP)
  ldi ZH, hi8(INITIAL_TILEMAP)
1:
  lpm r16, Z+
  subi r16, 32
  andi r16, 0x3F ; 64 tiles
  st X+, r16
  cpi XL, 0x20 + 16*12
  brlo 1b

  ; Clear the memory read/write registers.
  ldi XL, 0
  ldi XH, 1
  ldi YL, 0
  ldi YH, 1
  ldi ZL, 0
  ldi ZH, hi8(TILE_DATA)
  ldi PIXEL_SCANLINE_REG, 0
  ldi PIXELY_REG, 0

; Clear both counters so they start at the same value.
  ldi r16, 0
  out _SFR_IO_ADDR(TCNT0), r16
  out _SFR_IO_ADDR(TCNT1), r16

; Unleash the timers! This resets both and initiates counting.
  ldi r16, _BV(PSR1) | _BV(PSR0)
  out _SFR_IO_ADDR(GTCCR), r16

; Enable interrupts.
  sei

  ldi XH, 1
  ldi XL, 0x20
loop:

; "Randomly" mutate characters by adding the scanline reg to them.
  ldi r23, 0
1:
  inc r23
  brne 1b

  ld r23, X
  add r23, PIXEL_SCANLINE_REG
  andi r23, 0x3F
  st X+, r23
  cpi XL, 0x20 + 16*12
  brlo loop
  ldi XL, 0x20
  rjmp loop

hsync_start:
; Depending on the instruction that was executing when the interrupt happened,
; we may be off by as many as two cycles. Add delays here so we always start
; painting on the same cycle.
  in r16, _SFR_IO_ADDR(TCNT0) ; 1
  cpi r16, 0x0A ; 1
  brlt 1f ; 1 (technically 1 or 2, but if it's 2 then we're correcting to make it seem like 1)
1:
  cpi r16, 0x09 ; 1
  brlt 1f ; 1 (technically 1 or 2, but if it's 2 then we're correcting to make it seem like 1)
1:

; Save registers.
; TODO: Document which registers are mutated in this interrupt routine.
  push XL ; 2
  push XH ; 2
  in r22, _SFR_IO_ADDR(SREG) ; 1

; There should be 90 cycles between start of the hsync pulse and pixels.
; Ideally, the start of the pulse would be _now_, but there is a bit of lag
; introduced by the interrupt handling. This lag is at least 7 cycles, more if a
; greater than 1 cycle instruction is running.
  adiw SCANLINE_LREG, 1 ; 2
  movw r16, SCANLINE_LREG ; 1
; Line 479 is the last line of pixels. If we're on line 480, stop drawing.
  subi r16, lo8(VISIBLE_LINES) ; 1
  sbci r17, hi8(VISIBLE_LINES) ; 1
  brcs 1f ; 2
  rjmp vert_refresh
1:
; 17 + ~7 (for interrupt handling) cycles up to this point.

; == LOAD PIXEL DATA ==
;       59 cycles

; Memory layout:
; 0x00 - 0x1F : Two line buffers. One is being written to while the
;               other is output.
; 0x20 - 0xDF : Tilemap (16x12)
; 0xE0 - 0xFF : Sprites?

; X scrolls through the tilemap (16x12) and starts at 0x20.
; Z is always used for reading bitmap data.

; PIXEL_SCANLINE_REG contains which scanline of the current row of pixels we're
; on (each pixel is actually 5 scanlines tall).
  cpi PIXEL_SCANLINE_REG, 4 ; 1

#define BEFORE_FINAL_LINE_BRANCH_TICKS (17 + 7 + 1)

  brlo 1f ; 2 or 1 if no jump
  rjmp final_line ; 2. For the final pixel we'll see 4 ticks up to this point.
1:

; We can determine which of the two line buffers we're writing to based on the
; LSB of pixel.Y. When painting the lower buffer (0x00), write the upper buffer
; (0x10).
  mov YL, PIXELY_REG ; 1
  andi YL, 1 ; 1
; A swap multiplies by 16 if you know the upper nibble is empty.
  swap YL ; 1
; Store the offset of the line buffer being read so we can reset Y before paint.
  mov r4, YL ; 1
; Always write to the opposite buffer.
  ldi r16, 0x10 ; 1
  eor YL, r16 ; 1

; Calculate which row of tile pixels we're painting and use it to determine our
; base offset in TILE_DATA. The row of tile pixels can be grabbed from the least
; significant 3 bits of PIXELY. Tiles in TILE_DATA are stored row-major so this
; offset is identical for the whole line. TILE_DATA is 256-aligned and 64 tiles
; long, so only the bottom 6 bits of Z will change. ZH remains constant, the
; offset for ZL is stored in r17.
  mov r17, PIXELY_REG ; 1
; Shift right three times, third bit will be in C and two LSBs will now be MSBs.
  ror r17 ; 1
  ror r17 ; 1
  ror r17 ; 1
  andi r17, 0xC0 ; 1, just the top two bits
; Add the carry to ZH.
  ldi ZH, hi8(TILE_DATA) ; 1
  clr r16 ; 1
  adc ZH, r16 ; 1

; X is our pointer into the tilemap memory. The tile row is the top 5 bits of
; PIXELY. We can multiply that by 16 to get the offset into the tilemap.
  ldi XH, 1 ; 1
  mov XL, PIXELY_REG ; 1
  andi XL, 0xF8 ; 1
  lsl XL ; 1
; We grab 4 tiles during each HSYNC, so offset XL by the tiles we've already
; processed for this row of pixels.
; 4 tiles at a time, so multiply the scanline index by 4 to get the tile index.
  mov r16, PIXEL_SCANLINE_REG ; 1
  lsl r16 ; 1
  lsl r16 ; 1
  add XL, r16 ; 1
; Y should also be offset by the same amount.
  add YL, r16 ; 1
; Offset by 0x20.
  subi XL, -0x20 ; 1

; Increment PIXEL_SCANLINE_REG now that we've used it for indexing.
  inc PIXEL_SCANLINE_REG ; 1

.rept 4
  ld ZL, X+ ; 2
; Include the TILE_DATA offset for the current line of pixels.
  or ZL, r17 ; 1
  lpm r16, Z ; 3
  st Y+, r16 ; 2
.endr

; == BURN TIME ==
;    ?? cycles

#define HSYNC_PLUS_BACK_PORCH_TICKS (HSYNC_TICKS * CLOCKS_PER_TICK + HSYNC_BPORCH)
; TODO: The -2 here is cheating because we're one cycle over where we need to
;       be. We should be able to save some cycles by reading/writing values to
;       memory (like the tile row offset) rather than recalculating them every
;       HSYNC.
#define POST_WAIT_TICKS (6 + 2    - 2)
#define WHEN_COPY_TICKS (BEFORE_FINAL_LINE_BRANCH_TICKS + 59 + POST_WAIT_TICKS)
#define HSYNC_WAIT_TICKS (HSYNC_PLUS_BACK_PORCH_TICKS - WHEN_COPY_TICKS)
.if HSYNC_WAIT_TICKS < 0
.err ; Too much work during HSYNC!
.endif

.rept HSYNC_WAIT_TICKS
  nop
.endr

; == PAINT INIT ==
;     6 cycles + 2 cycles (before the first pixel data is actually output)
paint_start:
; Turn off the compare outputs for timer1 so they don't override our color pin.
; NOTE: This doesn't seem to actually matter when using PB1 as SPI out. Can
; probably remove this to save a few cycles.
  ldi r16, _BV(PWM1A) | _BV(CS11) ; 1
  out _SFR_IO_ADDR(TCCR1), r16 ; 1
  sbi _SFR_IO_ADDR(DDRB), COLOR_PIN ; 2
  ldi r16, _BV(USIWM0) | _BV(USICLK) ; 1
; Reset Y to the beginning of the line buffer being read.
  mov YL, r4 ; 1

; TODO: It looks like the first pixel of each line isn't painted.

; == PAINTING ==
;   400 cycles
.rept 16
; Fetch the character data from the line buffer.
  ld r17, Y+ ; 2
; It looks like the MSB of USIDR is immediately visible on the color pin.
  out _SFR_IO_ADDR(USIDR), r17 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
  nop
  nop
  out _SFR_IO_ADDR(USICR), r16 ; 1
.endr
  ; Turn off serial so we can reclaim control of the color pin.
  ; Ensure two cycles so the last pixel is full width.
  nop ; 1
  ldi r16, 0 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  ; Bring the color pin low so the line is in a consistant state at end.
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2

; Color pin as input so it doesn't output the inverse HSYNC pulses.
  cbi _SFR_IO_ADDR(DDRB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2. Disable pullup.
; Turn the compare outputs back on.
  ldi r16, _BV(PWM1A) | _BV(COM1A0) | _BV(CS11)
  out _SFR_IO_ADDR(TCCR1), r16

clean:
  out _SFR_IO_ADDR(SREG), r22 ; 1
  pop XH ; 2
  pop XL ; 2
  reti

/*
; Output r16 on the color pin.
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
.rept 8
  lsl r16 ; 1
  brcs 1f ; 1/2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  rjmp 2f ; 2
1:
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  nop ; 1
2:
.endr
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2
*/

final_line: ; 3 clocks since BEFORE_FINAL_LINE_BRANCH_TICKS
; Reset to the first of 5 lines.
  ldi PIXEL_SCANLINE_REG, 0 ; 1
  inc PIXELY_REG ; 1
#define WHEN_NO_COPY_TICKS (BEFORE_FINAL_LINE_BRANCH_TICKS + 7 + POST_WAIT_TICKS)
.rept HSYNC_PLUS_BACK_PORCH_TICKS - WHEN_NO_COPY_TICKS
  nop
.endr
  rjmp paint_start ; 2

vert_refresh:
; vsync starts on line 490...
  cpi SCANLINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH)
  brne 1f
  cpi SCANLINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH)
  brne 1f
; Line 490: vsync start
  cbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  rjmp clean
1:

; ... and ends on line 492
  cpi SCANLINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
  cpi SCANLINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
; Line 492: vsync end
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  rjmp clean
1:

; Line $TOTAL_LINES-1 is the last line (0 indexed). Reset to -1, which will
; increment to 0 during the next hsync.
  cpi SCANLINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH + VSYNC_BPORCH - 1)
  brne 1f
  cpi SCANLINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH + VSYNC_BPORCH - 1)
  brne 1f
  ldi SCANLINE_LREG, lo8(-1)
  ldi SCANLINE_LREG+1, hi8(-1)
  ldi PIXEL_SCANLINE_REG, 0
  ldi PIXELY_REG, 0
  ldi XL, 0
  ldi XH, 1
  ldi YL, 0
  ldi YH, 1
  ldi ZL, 0
  ldi ZH, hi8(TILE_DATA)
1:

  rjmp clean

.balign 256
INITIAL_TILEMAP:
.ascii "/\\/\\/\\/\\/\\/\\/\\/\\"
.ascii "\\/\\/           /"
.ascii "/\\/          ! \\"
.ascii "\\/    @VGA     /"
.ascii "/              \\"
.ascii "\\      BY      /"
.ascii "/              \\"
.ascii "\\    ACEDIO    /"
.ascii "/     2022    /\\"
.ascii "\\ ?          /\\/"
.ascii "/           /\\/\\"
.ascii "\\/\\/\\/\\/\\/\\/\\/\\/"

.balign 256
TILE_DATA:
#include "font.inc"
