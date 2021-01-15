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
  ldi r16, 0
1:
  st X+, r16
  inc r16
  cpi r16, 16*12
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

loop:
  lpm r0, Z ; takes 3 cycles (does nothing, for testing interrupt timing)
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

  ; There should be 90 cycles between start of the hsync pulse and pixels.
  ; Ideally, the start of the pulse would be _now_, but there is a bit of lag
  ; introduced by the interrupt handling. This lag is at least 7 cycles, more if
  ; a greater than 1 cycle instruction is running.
  adiw SCANLINE_LREG, 1 ; 2
  movw r16, SCANLINE_LREG ; 1
  ; Line 479 is the last line of pixels. If we're on line 480, stop drawing.
  subi r16, lo8(VISIBLE_LINES) ; 1
  sbci r17, hi8(VISIBLE_LINES) ; 1
  brcs 1f ; 2
  rjmp vert_refresh
1:
; 14 + ~7 (for interrupt handling) cycles up to this point.

; == LOAD PIXEL DATA ==
;       53 cycles

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
  brlo 1f ; 2
  rjmp final_line ; 2. For the final pixel we'll see 4 ticks up to this point.
1:

; We can determine which of the two line buffers we're writing to based on the
; LSB of pixel.Y. When painting the lower buffer (0x00), write the upper buffer
; (0x10).
  mov YL, PIXELY_REG ; 1
  andi YL, 1 ; 1
  swap YL ; 1
; Store the offset of the line buffer being read so we can reset Y before paint.
  mov r4, YL ; 1
; Always write to the opposite buffer.
  eor YL, 0x10 ; 1

; Our tile.Y value is temporarily stored in r17 and is the least significant 3
; bits of PIXELY
  mov r17, PIXELY_REG ; 1
  andi r17, 0x07 ; 1

; X is our pointer into the tilemap memory. We can determine the row by looking
; at the top 5 bits of PIXELY, then offsetting it by the tiles we've already
; processed for this scanline.
  mov XL, PIXELY_REG ; 1
  lsr XL ; 1
  lsr XL ; 1
  lsr XL ; 1
; 4 tiles at a time, so multiply the scanline by 4 to get our initial tile.
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
; Add the vertical offset based on tile.Y.
  add ZL, r17 ; 1
  lpm r16, Z ; 3
  st Y+, r16 ; 2
.endr

; == BURN TIME ==
;    ?? cycles

#define HSYNC_WAIT_TICKS (HSYNC_TICKS * CLOCKS_PER_TICK + HSYNC_BPORCH - (14 + 7 + 53 + 8))
.if HSYNC_WAIT_TICKS < 0
.err ; Too much work during HSYNC!
.endif

.rept HSYNC_WAIT_TICKS
  nop
.endr

; == PAINT INIT ==
;     8 cycles
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
; Fetch the first value.
  ld r17, Y+ ; 2

; == PAINTING ==
;   400 cycles
.rept 16
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
  ld r17, Y+ ; 2
.endr
.rept 12
  nop
.endr
  ; Turn off serial so we can reclaim control of the color pin.
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

final_line: ; 5 clocks so far.
; Reset to the first of 5 lines.
  ldi PIXEL_SCANLINE_REG, 0 ; 1
  inc PIXELY_REG ; 1
.rept HSYNC_TICKS * CLOCKS_PER_TICK + HSYNC_BPORCH - (14 + 7 + 8 + 8)
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
  reti
1:

; ... and ends on line 492
  cpi SCANLINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
  cpi SCANLINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
; Line 492: vsync end
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  reti
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

  reti

.balign 256
TILE_DATA:
; Test pattern.
.rept 16
.byte 0xFF, 0x00
.endr
.rept 16
.byte 0x00, 0xFF
.endr
.rept 32
.byte 0xF0
.endr
.rept 32
.byte 0x0F
.endr
.rept 32
.byte 0xCC
.endr
.rept 32
.byte 0x33
.endr
.rept 32
.byte 0xAA
.endr
.rept 32
.byte 0x55
.endr
.rept 16
.byte 0xFF, 0x00
.endr
/*
.ascii "                "
.ascii "                "
.ascii "  # # ### # #   "
.ascii "  # # #   # #   "
.ascii "  ### ##   #    "
.ascii "  # # #    #    "
.ascii "  # # ###  #    "
.ascii "                "
.ascii "  ##  ### ##    "
.ascii "  # # #   # #   "
.ascii "  # # ##  ##    "
.ascii "  # # #   # #   "
.ascii "  ##  ### # #   "
.ascii "                "
.ascii "  ##  ##   #  # "
.ascii "  # # # # # # # "
.ascii "  ##  ##  # # # "
.ascii "  # # # # # #   "
.ascii "  ##  # #  #  # "
.ascii "                "
.ascii "                "
*/
/*
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
*/
/*
; EB
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b00000010, 0b00010110, 0b11111111, 0b11111101, 0b10100000, 0b00000011, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b00000010, 0b00010110, 0b00000000, 0b00000001, 0b10100000, 0b00000011, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b10111111, 0b11111111, 0b00100000
.endr
.rept 3
.byte 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b00100000, 0b00100000, 0b00110110, 0b00000000, 0b00000001, 0b10110000, 0b00100001, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11011011, 0b01111111, 0b11111111, 0b11111111, 0b11011011, 0b01111111, 0b11111111, 0b00100000, 0b00100000, 0b00110111, 0b11111111, 0b11111111, 0b10110001, 0b11100001, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11111011, 0b01111111, 0b11111111, 0b11111111, 0b11111011, 0b01111111, 0b11111111, 0b00100000, 0b00100000, 0b00110111, 0b11111111, 0b11111111, 0b10110001, 0b11100001, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11100000, 0b01111111, 0b11111111, 0b11111111, 0b11100000, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b00000011, 0b00000011, 0b10111111, 0b11111111, 0b00111100
.endr
.rept 3
.byte 0b11111111, 0b11101101, 0b11111111, 0b11111111, 0b11111111, 0b11101101, 0b11111111, 0b11111111, 0b00000010, 0b00000010, 0b00010111, 0b01111011, 0b01111011, 0b10100000, 0b00000011, 0b00111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b11111110, 0b00010111, 0b01001011, 0b01001011, 0b10100000, 0b00000011, 0b00000000
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b11111110, 0b00010111, 0b01001011, 0b01001011, 0b10100000, 0b00000011, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b01001011, 0b01001011, 0b10111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00100000, 0b00100000, 0b00111111, 0b01011011, 0b01101011, 0b11110000, 0b00100000, 0b00100000
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00100000, 0b00100001, 0b11100011, 0b01111011, 0b01111011, 0b00011110, 0b00100000, 0b00111000
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00100000, 0b00100001, 0b11000011, 0b01110111, 0b10111011, 0b00001110, 0b00100001, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11110111, 0b01111011, 0b01111011, 0b10111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b00000010, 0b10001011, 0b01001011, 0b01001011, 0b01000100, 0b00000111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b00000011, 0b11110011, 0b01001011, 0b01001011, 0b00111110, 0b00011111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000010, 0b00000011, 0b00100011, 0b01001011, 0b01001011, 0b00010010, 0b00111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00100011, 0b01111011, 0b01111011, 0b00010011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11000000, 0b00000000, 0b00000000, 0b00010000, 0b00100001, 0b11100011, 0b00000011, 0b00000011, 0b00011111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011111, 0b11111111, 0b11111111, 0b11111000, 0b00100001, 0b00100011, 0b11111111, 0b11111111, 0b00010011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011111, 0b11111111, 0b11111111, 0b11111000, 0b00100001, 0b00100010, 0b00000000, 0b00000001, 0b00010011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011000, 0b00000000, 0b00000000, 0b11111111, 0b11111111, 0b00100010, 0b00000000, 0b00000001, 0b00010011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011000, 0b00000000, 0b00000000, 0b11111010, 0b00000011, 0b00101100, 0b00000000, 0b00000000, 0b11010011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011010, 0b10111011, 0b10110100, 0b11111010, 0b00000011, 0b00110000, 0b00000000, 0b00000000, 0b00110011, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011010, 0b10101001, 0b00100100, 0b11111010, 0b00000011, 0b11110000, 0b00000000, 0b00000000, 0b00111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011011, 0b10101001, 0b00110100, 0b11111111, 0b11111110, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11011010, 0b10101001, 0b00100101, 0b11111111, 0b11111100, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10111010, 0b10111001, 0b00110111, 0b11111111, 0b11111100, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111100, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b10110001, 0b01100010, 0b00100011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b11111111, 0b10110001, 0b01001010, 0b01101111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11110111, 0b11111111, 0b11111111, 0b11111111, 0b10110000, 0b01000010, 0b00001011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11011011, 0b01111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111011, 0b01111111, 0b11111111, 0b11111111, 0b10110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b11000000, 0b00001111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11100000, 0b01111111, 0b11111111, 0b11111111, 0b01110000, 0b00000000, 0b00000001, 0b11111111, 0b11111111, 0b00000000, 0b00001111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11101101, 0b11111111, 0b11111111, 0b11111111, 0b01100000, 0b01111111, 0b10000001, 0b11111111, 0b11111110, 0b00000000, 0b00011111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01100000, 0b00000000, 0b00000011, 0b11111111, 0b11111110, 0b00000000, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01100000, 0b10110110, 0b10000011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01100000, 0b11111111, 0b10000011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01100000, 0b00000000, 0b00000011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111000, 0b00001111, 0b11111111, 0b00011111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11110000, 0b00000111, 0b11111100, 0b00000111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111101, 0b11000111, 0b11100000, 0b00000011, 0b10111000, 0b00000111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111000, 0b00000011, 0b11100000, 0b00000011, 0b10011000, 0b00001111, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b00000001, 0b01000000, 0b00000100, 0b10000000, 0b00000100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010000, 0b00001101, 0b01000011, 0b01111010, 0b11000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010001, 0b10000111, 0b01000010, 0b10001010, 0b10000000, 0b00101000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010001, 0b00000100, 0b10111110, 0b00000100, 0b10000000, 0b00101000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010000, 0b10000001, 0b00100001, 0b00000010, 0b10000100, 0b00000100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b00000001, 0b00010000, 0b00000100, 0b01000100, 0b11111110, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b00000010, 0b00001000, 0b00101000, 0b10000001, 0b10101101, 0b10000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b00111100, 0b00000000, 0b00000000, 0b00000000, 0b00000100, 0b00010100, 0b00000100, 0b00010000, 0b10001111, 0b11011111, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000000, 0b11000010, 0b00000000, 0b00000000, 0b00000000, 0b00000010, 0b00001000, 0b00000011, 0b01100000, 0b01111000, 0b01111111, 0b11100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00000011, 0b00101010, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00110000, 0b00000111, 0b00100000, 0b00001110, 0b00001111, 0b11100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00011100, 0b01010100, 0b00000000, 0b00000000, 0b00000000, 0b00000100, 0b10001000, 0b00001111, 0b11010000, 0b00010111, 0b01111001, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00100011, 0b10100010, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b10001000, 0b00010011, 0b11010000, 0b00101110, 0b00110001, 0b11100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01011101, 0b01011010, 0b00000000, 0b00000000, 0b00000000, 0b00001001, 0b00001000, 0b00010011, 0b11110000, 0b01001010, 0b01000100, 0b10100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b00101010, 0b10000010, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b11111000, 0b00001111, 0b11110000, 0b00101000, 0b01000100, 0b00100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001101, 0b10011010, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00010000, 0b00000111, 0b11100000, 0b00010100, 0b00000000, 0b01000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b11111111, 0b11010011, 0b10000011, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111110, 0b00000000, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b00000000, 0b01000010, 0b10010100, 0b00000000, 0b00000000, 0b00000000, 0b00111111, 0b10001111, 0b01111110, 0b00011110, 0b11111111, 0b00111001, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01010100, 0b01101000, 0b00000000, 0b00000000, 0b00000000, 0b00001111, 0b11111100, 0b00011111, 0b11111000, 0b00111111, 0b10000010, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b11111111, 0b11010111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b01101101, 0b11111111, 0b11111111, 0b11111111, 0b11111111
.endr
.rept 3
.byte 0b00000000, 0b01001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000010, 0b00000000, 0b10000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001000, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000100, 0b00000000, 0b01000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001011, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001001, 0b00000001, 0b00100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001100, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001001, 0b00000001, 0b01000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001011, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b00000011, 0b10000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01000111, 0b01110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000010, 0b00010100, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b10011011, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01011011, 0b01101000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11111011, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001110, 0b11111111, 0b11110000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001111, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11111111, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001011, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01001100, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01000011, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b01101010, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000000, 0b10000010, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 3
.byte 0b00000001, 0b01101010, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
*/

/*
; Saturn
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000111, 0b11000000, 0b00000011, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b11100000, 0b00000111, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001110, 0b10111000, 0b00000111, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001101, 0b01011100, 0b00001111, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011010, 0b10101110, 0b00001111, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010101, 0b01010111, 0b00011111, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110101, 0b01010101, 0b10011110, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110100, 0b10101010, 0b11111110, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110101, 0b00100101, 0b01111100, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110101, 0b01010101, 0b01111111, 0b11111111, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00111111, 0b01010101, 0b01010101, 0b01010101, 0b01010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11111110, 0b10101010, 0b10101010, 0b10110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001111, 0b11100100, 0b10010010, 0b01010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11111010, 0b10101010, 0b10110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111110, 0b10101010, 0b10110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11100111, 0b01010101, 0b01100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11100001, 0b11010010, 0b10100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11100000, 0b11101010, 0b11100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00111001, 0b01100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11000000, 0b00001110, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11000000, 0b00000111, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011111, 0b11111000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11111101, 0b01111111, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001111, 0b10000000, 0b00000001, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00111100, 0b00000000, 0b00000000, 0b00011100, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01110000, 0b00000000, 0b00000000, 0b00000111, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000001, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b11100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11000000, 0b00000000, 0b10000100, 0b00000000, 0b00000000, 0b00000001, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b00000000, 0b11111111, 0b00000000, 0b00100000, 0b01111111, 0b11000000, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00000011, 0b11111111, 0b10101101, 0b00000000, 0b11111111, 0b11100000, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b00000011, 0b11111111, 0b10100101, 0b00000000, 0b11111111, 0b11100000, 0b01100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b00000111, 0b11111111, 0b01010101, 0b01000000, 0b11111111, 0b11100000, 0b01100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b00000011, 0b11111111, 0b01010100, 0b10110000, 0b10111111, 0b11000000, 0b00100000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000100, 0b00000010, 0b10101010, 0b10101010, 0b10010100, 0b00000000, 0b00000000, 0b00110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000010, 0b00100100, 0b10101010, 0b10101010, 0b00000000, 0b00000000, 0b00010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b01010101, 0b00100101, 0b01010010, 0b00000000, 0b00000000, 0b00010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000001, 0b01010101, 0b01010101, 0b00101010, 0b10111000, 0b00000000, 0b00011000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b00001010, 0b10111010, 0b10101001, 0b01010101, 0b01111000, 0b00000000, 0b00011000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011100, 0b11000101, 0b00111110, 0b10101010, 0b10000000, 0b00111000, 0b00000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011010, 0b00010101, 0b01011101, 0b00100000, 0b00000000, 0b01010000, 0b00000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011010, 0b11010101, 0b01011100, 0b00000000, 0b00000000, 0b00011000, 0b00000000, 0b00001000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010101, 0b00100101, 0b01010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001000, 0b00000111, 0b11111100, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010101, 0b01010100, 0b10101000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001011, 0b11111111, 0b11111111, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010101, 0b01010101, 0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001111, 0b11111111, 0b11111111, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b11111111, 0b11111111, 0b10010101, 0b01010101, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b10000000, 0b00111111, 0b11111111, 0b11111111, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b11111111, 0b11111111, 0b11110100, 0b10010101, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11101111, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b11111111, 0b11111111, 0b11111010, 0b10101001, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b11111000, 0b00001111, 0b11110111, 0b01010100, 0b00000000, 0b00000000, 0b00000001, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00111010, 0b10010100, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00101010, 0b10101000, 0b00000000, 0b00000100, 0b00100000, 0b00000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00101001, 0b01010100, 0b00000100, 0b00010000, 0b10000000, 0b00010000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00110101, 0b01001000, 0b00000000, 0b11001010, 0b01011000, 0b00000000, 0b10000000, 0b11100111, 0b10000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000111, 0b11110101, 0b01010100, 0b00000010, 0b10101011, 0b01000110, 0b00000000, 0b00000000, 0b10111111, 0b11110000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b01111111, 0b11111110, 0b10101000, 0b00000100, 0b10101000, 0b10110010, 0b00000000, 0b00000000, 0b00100111, 0b11111110, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000011, 0b11111111, 0b11111010, 0b10100100, 0b00000101, 0b01010110, 0b10010101, 0b10000000, 0b00000000, 0b00000111, 0b11111111, 0b10000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00011111, 0b11111111, 0b10110100, 0b10101000, 0b00101010, 0b10010101, 0b01010101, 0b00000000, 0b00000000, 0b00000100, 0b01111111, 0b11100000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b01111111, 0b11111000, 0b00111010, 0b10101100, 0b00101010, 0b10101001, 0b01010101, 0b01000000, 0b00000000, 0b00000100, 0b00001111, 0b11110000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b01111111, 0b10000000, 0b00110101, 0b00100100, 0b00010100, 0b10100101, 0b01010010, 0b10100000, 0b00000000, 0b00000100, 0b00000011, 0b11111000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b01111100, 0b00000000, 0b00010101, 0b01010100, 0b00010101, 0b01010101, 0b00101010, 0b10100000, 0b00000000, 0b00000100, 0b00000000, 0b11111000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010101, 0b01010010, 0b00100101, 0b01010101, 0b01010101, 0b01000001, 0b00000000, 0b00000100, 0b00000000, 0b01111000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010100, 0b10101001, 0b00101010, 0b01010101, 0b01010100, 0b10100000, 0b00000000, 0b00000100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011010, 0b00010101, 0b00001010, 0b10100100, 0b10010010, 0b10100000, 0b00000000, 0b00000100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010000, 0b00010100, 0b10001010, 0b10101010, 0b10101010, 0b10000000, 0b00010000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011100, 0b00001010, 0b10000101, 0b00101010, 0b10101010, 0b10000000, 0b00000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011000, 0b00101010, 0b10100010, 0b10101010, 0b10101010, 0b10000011, 0b01000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011101, 0b00010101, 0b01010010, 0b10010100, 0b10010101, 0b00011010, 0b10000000, 0b00001100, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00011101, 0b01010010, 0b10101010, 0b10101010, 0b10101001, 0b00010101, 0b01000000, 0b00000110, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01110101, 0b01010101, 0b00101001, 0b01001010, 0b10100101, 0b01010010, 0b10110011, 0b01000011, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11110101, 0b01010101, 0b01010101, 0b01010101, 0b01010101, 0b01010101, 0b01001010, 0b10100001, 0b11000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b10101010, 0b01001010, 0b10101010, 0b10101001, 0b00101001, 0b00101010, 0b01010101, 0b00100000, 0b11100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b10100101, 0b01010010, 0b10010100, 0b10101010, 0b10101010, 0b10101010, 0b10101001, 0b01010000, 0b01110000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b10101010, 0b10101010, 0b01010101, 0b00101010, 0b10101010, 0b10010101, 0b01010101, 0b01000000, 0b00110000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b10010101, 0b01010101, 0b01010101, 0b11111111, 0b11111111, 0b11110010, 0b10010101, 0b01000000, 0b00010000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000101, 0b01010010, 0b10101010, 0b10100101, 0b00000000, 0b00000000, 0b01111010, 0b10101010, 0b01000000, 0b00011000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b10101010, 0b01001010, 0b01010111, 0b00000000, 0b00000000, 0b00111100, 0b10100101, 0b00100000, 0b00011000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000101, 0b01010101, 0b01010101, 0b01010110, 0b00000000, 0b00000000, 0b00011110, 0b10101010, 0b10101000, 0b00011000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000110, 0b01010010, 0b10100101, 0b01011100, 0b00000000, 0b00000000, 0b00001110, 0b10101010, 0b10101010, 0b00010000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000111, 0b01010101, 0b01010100, 0b10111000, 0b00000000, 0b00000000, 0b00000011, 0b10101010, 0b10101010, 0b11110000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000011, 0b10010100, 0b10101010, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b11111010, 0b01010101, 0b11100000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000001, 0b11101010, 0b10101111, 0b11000000, 0b00000000, 0b00000000, 0b00000000, 0b00011111, 0b11111111, 0b10000000, 0b00000000, 0b00000000, 0b00000000
.endr
.rept 2
.byte 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01111111, 0b11111110, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000
.endr
*/
