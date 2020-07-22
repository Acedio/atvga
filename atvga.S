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

#define LINES 525

.global main
main:
  cli

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
  ; ldi r16, _BV(CS13) | _BV(CS12) | _BV(CS11) | _BV(CS10)
  out _SFR_IO_ADDR(TCCR1), r16

  ; PWM1B enables PWM with OCR1B.
  ; COM1B[1:0] = 0b11 causes OC1B to set on compare match and clear at 0.
  ldi r16, _BV(PWM1B) | _BV(COM1B1) ;| _BV(COM1B0)
  out _SFR_IO_ADDR(GTCCR), r16

  ; OCR1C is the top value of timer1. Interrupt TOV1 is fired after the match.
  ; When the counter hits 253, i.e. once every 254 cycles, it resets to 0 and
  ; sets OC1B.
  ldi r16, 253
  out _SFR_IO_ADDR(OCR1C), r16

  ; When OCR1B is matched, OC1B is cleared.
  ldi r16, 253-30
  out _SFR_IO_ADDR(OCR1B), r16

  ; Enable interrupts for when OCR1B is hit.
  ldi r16, _BV(OCIE1B)
  out _SFR_IO_ADDR(TIMSK), r16

  ; Clear the interrupt flag just in case it's set.
  ldi r16, _BV(OCF1B)
  out _SFR_IO_ADDR(TIFR), r16

  ; Start on line 0.
  ldi LINE_LREG, 0
  ldi LINE_LREG+1, 0

  ; Enable interrupts.
  sei

loop:
  rjmp loop

hsync_start:
  ; There should be 76 cycles between start of the hsync pulse and pixels.
  adiw LINE_LREG, 1 ; 2
  movw r26, LINE_LREG ; 1
  ; Line 480 is the last line of pixels.
  subi r26, lo8(480) ; 1
  sbci r27, hi8(480) ; 1
  brcs 1f; 2
  rjmp pixels_done
1:

  ; 7 cycles up til now, wait the rest until 76 have been taken total.
  .rept 76-7
  nop
  .endr

  ; Painting starts.
  .rept 30
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  nop
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  nop
  .endr
  reti

pixels_done:
  ; vsync starts on line 490...
  cpi LINE_LREG, lo8(490)
  brne 1f
  cpi LINE_LREG+1, hi8(490)
  brne 1f
  ; Line 490: vsync start
  cbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  reti
1:

  ; ... and ends on line 492
  cpi LINE_LREG, lo8(492)
  brne 1f
  cpi LINE_LREG+1, hi8(492)
  brne 1f
  ; Line 492: vsync end
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  reti
1:

  cpi LINE_LREG+1, hi8(LINES)
  brlo 1f
  brne 2f ; if somehow greater, reset immediately
  cpi LINE_LREG, lo8(LINES)
  brlo 1f
  ; Line $LINES is the last line (1 indexed). Reset to 0.
2:
  ldi LINE_LREG, 0
  ldi LINE_LREG+1, 0

; blink LED at a fraction of the Vrefresh
  inc r0 
  mov r16, r0
  andi r16, 64
  breq 2f
  sbi _SFR_IO_ADDR(PORTB), LED_PIN
  rjmp 1f
2:
  cbi _SFR_IO_ADDR(PORTB), LED_PIN

1:

  reti
