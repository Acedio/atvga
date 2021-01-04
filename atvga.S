#include <avr/io.h>

.text
; Interrupt vectors.
rjmp main ; RESET
nop
nop
nop
nop
nop
nop
nop
nop
rjmp hsync_start ; Timer 1 compare match B.
nop
nop
nop
nop
nop

#define COLOR_PIN 1
#define HSYNC_PIN 4
#define VSYNC_PIN 3
#define LED_PIN 2

#define LINE_LREG 24

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

  ; Trim the clock so we're close to an easily divisible clock freq (such that
  ; 250 clocks is a line and 30 is the hsync length).
  in r16, _SFR_IO_ADDR(OSCCAL)
  subi r16, 3
  out _SFR_IO_ADDR(OSCCAL), r16
  subi r16, 3
  out _SFR_IO_ADDR(OSCCAL), r16
  subi r16, 3
  out _SFR_IO_ADDR(OSCCAL), r16

  ; Output pins.
  ldi r16, _BV(COLOR_PIN) | _BV(HSYNC_PIN) | _BV(VSYNC_PIN) | _BV(LED_PIN)
  out _SFR_IO_ADDR(DDRB), r16

  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  ; Sync pins start high (pulse low)
  sbi _SFR_IO_ADDR(PORTB), HSYNC_PIN
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  cbi _SFR_IO_ADDR(PORTB), LED_PIN

  ; Set up timer 1 to control hsync

  ; CS1[3:0] = 0b010 scales CK/2 for the timer input.
  ldi r16, _BV(CS11)
  out _SFR_IO_ADDR(TCCR1), r16

  ; PWM1B enables PWM with OCR1B.
  ; COM1B[1:0] = 0b11 causes OC1B to set on compare match and clear at 0.
  ldi r16, _BV(PWM1B) | _BV(COM1B1) ;| _BV(COM1B0)
  out _SFR_IO_ADDR(GTCCR), r16

  ; OCR1C is the top value of timer1. Interrupt TOV1 is fired after the match.
  ; When the counter hits 253, i.e. once every 254 cycles, it resets to 0 and
  ; sets OC1B.
  ldi r16, TICKS_PER_LINE-1
  out _SFR_IO_ADDR(OCR1C), r16

  ; When OCR1B is matched, OC1B is cleared.
  ldi r16, TICKS_PER_LINE - HSYNC_TICKS
  out _SFR_IO_ADDR(OCR1B), r16

  ; Enable interrupts for when OCR1B is hit.
  ldi r16, _BV(OCIE1B)
  out _SFR_IO_ADDR(TIMSK), r16

  ; Clear the interrupt flag just in case it's set.
  ldi r16, _BV(OCF1B)
  out _SFR_IO_ADDR(TIFR), r16

  ; Start on line -1.
  ldi LINE_LREG, lo8(-1)
  ldi LINE_LREG+1, hi8(-1)

  ; Enable interrupts.
  sei

loop:
  lpm r3, Z ; takes 3 cycles (does nothing, for testing)
  rjmp loop

hsync_start:
  ; Depending on the instruction that was executing when the interrupt happened,
  ; we may be off by as many as two cycles.
  in r16, _SFR_IO_ADDR(TCNT1) ; 1
  cpi r16, 0xE1 ; 1
  brlt 1f ; 1 (technically 1 or 2, but if it's 2 then we're correcting to make it seem like 1)
1:

  ; There should be 90 cycles between start of the hsync pulse and pixels.
  ; Ideally, the start of the pulse would be _now_, but there is a bit of lag
  ; introduced by the interrupt handling. This lag is at least 7 cycles, but in
  ; testing it seems like ~10 is the usual.
  adiw LINE_LREG, 1 ; 2
  movw r26, LINE_LREG ; 1
  ; Line 479 is the last line of pixels. If we're on line 480, stop drawing.
  subi r26, lo8(VISIBLE_LINES) ; 1
  sbci r27, hi8(VISIBLE_LINES) ; 1
  brcs 1f ; 2
  rjmp vert_refresh
1:
  ; 11 + ~10 (for interrupt handling) cycles up til now.

  ldi r16, _BV(USIWM0) | _BV(USICLK) ; 1

  .rept HSYNC_TICKS * CLOCKS_PER_TICK + HSYNC_BPORCH - (11 + 10 + 1)
  nop
  .endr

  ; Painting starts. 400 ticks.
.rept 50
  out _SFR_IO_ADDR(USIDR), LINE_LREG ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
.endr
  ; We need to turn off serial so we can reclaim the color pin.
  ldi r16, 0 ; 1
  out _SFR_IO_ADDR(USICR), r16 ; 1
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN ; 2

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

  reti

vert_refresh:
; vsync starts on line 490...
  cpi LINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH)
  brne 1f
  cpi LINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH)
  brne 1f
; Line 490: vsync start
  cbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  reti
1:

; ... and ends on line 492
  cpi LINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
  cpi LINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH)
  brne 1f
; Line 492: vsync end
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  reti
1:

; Line $TOTAL_LINES-1 is the last line (0 indexed). Reset to -1, which will
; increment to 0 during the next hsync.
  cpi LINE_LREG+1, hi8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH + VSYNC_BPORCH - 1)
  brne 1f
  cpi LINE_LREG, lo8(VISIBLE_LINES + VSYNC_FPORCH + VSYNC_LENGTH + VSYNC_BPORCH - 1)
  brne 1f
  ldi LINE_LREG, lo8(-1)
  ldi LINE_LREG+1, hi8(-1)
1:

  reti
