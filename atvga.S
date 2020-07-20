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
nop
rjmp hsync_start
nop
nop
nop
nop

#define STACK_TOP 0x100

#define COLOR_PIN 1
#define HSYNC_PIN 3
#define VSYNC_PIN 4
#define LED_PIN 2

#define LINE_LREG 24

#define LINES 525

.global main
main:
  cli
  ; Intialize stack
  ; ldi r16, lo8(STACK_TOP)
  ; out _SFR_IO_ADDR(SPL), r16
  ; ldi r16, hi8(STACK_TOP)
  ; out _SFR_IO_ADDR(SPH), r16

  ; Output pins.
  ldi r16, _BV(COLOR_PIN) | _BV(HSYNC_PIN) | _BV(VSYNC_PIN) | _BV(LED_PIN)
  out _SFR_IO_ADDR(DDRB), r16

  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  ; Sync pins start high (pulse low)
  sbi _SFR_IO_ADDR(PORTB), HSYNC_PIN
  sbi _SFR_IO_ADDR(PORTB), VSYNC_PIN
  cbi _SFR_IO_ADDR(PORTB), LED_PIN

  ; Set up timer 0 to control hsync

  ; WGM[2:0] = 0b010 sets up CTC (clears counter on each match of OCRA)
  ; Setting COM0A and COM0B to 0 disconnects the counter from pins.
  ldi r16, _BV(WGM01)
  out _SFR_IO_ADDR(TCCR0A), r16

  ; CS[2:0] = 0b001 sets the clock source to use I/O clk with no prescaler
  ldi r16, _BV(CS00)
  out _SFR_IO_ADDR(TCCR0B), r16

  ; Fire an interrupt when the counter hits 253, i.e. once every 254 cycles.
  ldi r16, 253
  out _SFR_IO_ADDR(OCR0A), r16

  ; Enable interrupts for when OCR0A is hit.
  ldi r16, _BV(OCIE0A)
  out _SFR_IO_ADDR(TIMSK), r16

  ; Clear the interrupt flag just in case it's set.
  ldi r16, _BV(OCF0A)
  out _SFR_IO_ADDR(TIMSK), r16

  ; Clear TSM just in case.
  ldi r16, 0
  out _SFR_IO_ADDR(GTCCR), r16

  ; Start on line 0.
  ldi LINE_LREG, 0
  ldi LINE_LREG+1, 0

  ; Enable interrupts.
  sei

loop:
  rjmp loop

hsync_start:
  cbi _SFR_IO_ADDR(PORTB), HSYNC_PIN ; 2 clk
  ; wait 29 more clks for a 31 clk sync pulse
  .rept 29
  nop
  .endr
  sbi _SFR_IO_ADDR(PORTB), HSYNC_PIN ; 2 clk
  
  adiw LINE_LREG, 1 ; 2
  movw r26, LINE_LREG ; 1
  subi r26, lo8(480) ; 1
  sbci r27, hi8(480) ; 1
  brcs 1f; 2
  rjmp pixels_done
1:

  ; Wait 6 more cycles to make back porch = 15
  .rept 6
  nop
  .endr

  ; Painting starts.
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  sbi _SFR_IO_ADDR(PORTB), COLOR_PIN
  cbi _SFR_IO_ADDR(PORTB), COLOR_PIN
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
