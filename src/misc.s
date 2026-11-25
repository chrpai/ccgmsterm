; CCGMS Terminal
;
; Copyright (c) 2016,2020, Craig Smith, alwyz. All rights reserved.
; This project is licensed under the BSD 3-Clause License.
;
; Miscellaneous 1
;

;----------------------------------------------------------------------
text_color_save:
	ldx textcl
	stx tmp04
;----------------------------------------------------------------------
text_color_set:
	ldx #TCOLOR
	stx textcl
	rts
;----------------------------------------------------------------------
text_color_restore:
	ldx tmp04
	stx textcl
	rts

;----------------------------------------------------------------------
handle_f6_directory:
	jsr col80_pause
	lda #1
	ldx #<dirfn
	ldy #>dirfn
dodir:
	jsr setnam
	jsr dir
	jsr rs232_on
	jsr col80_wait
	jmp term_mainloop

;----------------------------------------------------------------------
handle_f8_switch_term:
	ldx SHFLAG
	cpx #SHFLAG_CBM
	bne :+
	bit ansi80_active	; the ANSI screen has no text copy to read
	jpl cf7_screen_to_buffer
	jmp term_mainloop
:
; PETSCII 40 -> ASCII 40 -> PETSCII 80 -> ASCII 80 -> ANSI 80 -> PETSCII 40
	bit ansi80_active
	bpl @noansi
	jsr ansi80_leave	; ANSI 80 -> PETSCII 40
	lda #0
	sta ascii_mode
	jsr col80_set_charset
	jsr term80_toggle
	jmp @done
@noansi:
	lda ascii_mode
	beq @old
	bit col80_enabled
	bpl @old
	jsr ansi80_enter	; ASCII 80 -> ANSI 80
	jmp @done
@old:
	lda ascii_mode
	eor #1
	sta ascii_mode
	php
	jsr col80_set_charset
	plp
	bne :+
	jsr term80_toggle
:
@done:	jsr bell
	jmp term_entry

;----------------------------------------------------------------------
toggle_cursor:		; [XXX unused]
	jsr cursor_off
	lda cursor_flag
	eor #1
	sta cursor_flag
	jmp term_mainloop
