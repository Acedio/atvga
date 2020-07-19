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
nop
nop
nop
nop
nop
nop

#define STACK_TOP 0x100

#define LED_PIN 3

.global main
main:
  cli
  ; Intialize stack
  ldi r16, lo8(STACK_TOP)
  out _SFR_IO_ADDR(SPL), r16
  ldi r16, hi8(STACK_TOP)
  out _SFR_IO_ADDR(SPH), r16

  ldi r16, _BV(LED_PIN)
  out _SFR_IO_ADDR(DDRB), r16
  sbi _SFR_IO_ADDR(PORTB), LED_PIN
loop:
  rjmp loop
