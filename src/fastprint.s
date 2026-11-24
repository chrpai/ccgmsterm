; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; Fast screen output for received characters
;
; fast_chrout prints a character to the screen with the same result as
; KERNAL CHROUT, but takes shortcuts for the two things that cost the most
; while text streams in:
;
; * A printable character that doesn't end a screen line is written to
;   screen and color RAM directly, the way the KERNAL editor ($E716) does.
; * A RETURN on the bottom line, or a character in the last column of the
;   bottom line, first scrolls the screen up with an unrolled copy, then
;   lets the KERNAL print it, which no longer needs to scroll.
;
; Everything else (control codes, quote/insert mode, CTRL held to slow
; down scrolling, 80 column mode, output not going to the screen) goes
; straight through CHROUT.
;
; Clobbers X and Y (CHROUT preserves them).

; KERNAL screen editor variables
FP_CRSW		= $d0	; input from screen/keyboard flag
FP_PNT		= $d1	; pointer to the current logical line
FP_PNTR		= $d3	; cursor column in the logical line
FP_QTSW		= $d4	; quote mode
FP_LNMX		= $d5	; last column of the logical line (39 or 79)
FP_TBLX		= $d6	; cursor row
FP_DATA		= $d7	; last character printed
FP_INSRT	= $d8	; insert count
FP_LDTB1	= $d9	; line link table (25 rows)
FP_RVS		= $c7	; reverse mode
FP_LXSP		= $c9	; input cursor row
FP_BLNCT	= $cd	; cursor blink countdown
FP_USER		= $f3	; pointer to the color RAM of the current line
FP_COLOR	= $0286	; current text color
FP_HIBASE	= $0288	; screen page

FP_SCREEN	= $0400
FP_COLRAM	= $d800

fast_chrout:
	sta FP_DATA
	bit col80_active
	bmi @slow
	ldx DFLTO
	cpx #3
	bne @slow
	ldx FP_QTSW
	bne @slow
	ldx FP_INSRT
	bne @slow

	cmp #$20
	bcc @ctrl
	cmp #$80
	bcs @high
	cmp #'"'	; toggles quote mode
	beq @slow
	ldy FP_PNTR	; a character at the end of a screen line wraps
	cpy #39		; or links lines
	beq @wrap
	cpy FP_LNMX
	bcs @slow
	cmp #$60
	bcc :+
	and #$df	; $60-$7F -> screen codes $40-$5F
	bne @put	; always
:	and #$3f	; $20-$5F -> screen codes $20-$3F, $00-$1F
	bpl @put	; always

@high:	cmp #$a0
	bcc @ctrl	; $80-$9F: control codes
	ldy FP_PNTR
	cpy #39
	beq @wrap
	cpy FP_LNMX
	bcs @slow
	and #$7f
	cmp #$7f
	bne :+
	lda #$5e	; $FF -> pi
:	ora #$40	; $A0-$FE -> screen codes $60-$7F, $40-$7E

@put:	ldx FP_RVS
	beq :+
	ora #$80
:	sta (FP_PNT),y
	lda FP_PNT
	sta FP_USER
	lda FP_PNT+1
	and #$03
	ora #>FP_COLRAM
	sta FP_USER+1
	lda FP_COLOR
	sta (FP_USER),y
	inc FP_PNTR
	lda #2
	sta FP_BLNCT
	lda #0
	sta FP_CRSW
	lda FP_DATA
	clc
	cli
	rts

@ctrl:	and #$7f
	cmp #CR		; RETURN or shift-RETURN
	beq fast_return
@slow:	lda FP_DATA
	jmp chrout
@wrap:	jmp fast_wrap

;----------------------------------------------------------------------
; RETURN: if it will scroll the screen, scroll it here first
fast_return:
	jsr can_scroll
	bne @slow
	ldx FP_TBLX	; does the logical line end on the bottom row?
:	inx
	cpx #25
	beq @scroll
	lda FP_LDTB1,x
	bpl :-
@slow:	lda FP_DATA
	jmp chrout

@scroll:
	jsr scroll_up	; X = rows scrolled
	stx fp_rows
	lda FP_TBLX	; the cursor's line moved up with the screen
	sec
	sbc fp_rows
	sta FP_TBLX
	lda FP_LXSP	; the KERNAL does LSR, then DEC per row; it
	lsr		; will do the LSR when it handles the RETURN
	sec
	sbc fp_rows
	asl
	sta FP_LXSP
	lda FP_DATA
	jmp chrout	; RETURN moves to the (new) bottom line

;----------------------------------------------------------------------
; printable character in column 39 (Y = PNTR)
fast_wrap:
	cpy FP_LNMX	; last column of a one-row line...
	bne @slow
	ldx FP_TBLX	; ...on the bottom row: the KERNAL scrolls
	cpx #24
	bne @slow
	lda $0292	; AUTODN: inserts a line instead
	bne @slow
	jsr can_scroll
	beq @scroll
@slow:	lda FP_DATA
	jmp chrout

@scroll:
	jsr scroll_up	; X = rows scrolled
	stx fp_rows
	lda #24		; the line being printed moved up
	sec
	sbc fp_rows
	sta FP_TBLX
	tax
	lda LDTB2,x
	sta FP_PNT
	lda FP_LDTB1,x
	and #$03
	ora FP_HIBASE
	sta FP_PNT+1
	lda FP_LXSP
	sec
	sbc fp_rows
	sta FP_LXSP
	lda FP_DATA
	jmp chrout	; prints it and links the next row, no scroll

;----------------------------------------------------------------------
; Z=1 if scroll_up can stand in for the KERNAL's scroll
can_scroll:
	lda FP_HIBASE
	cmp #>FP_SCREEN
	bne :+
	lda SHFLAG	; CTRL held: the KERNAL slows the scroll down
	and #SHFLAG_CTRL
:	rts

;----------------------------------------------------------------------
; Scroll up like the KERNAL ($E8EA): one row, or two when the top logical
; line is two rows long. Returns the number of rows in X. The KERNAL
; decrements $02A5 once per row and increments it once at the end.
scroll_up:
	lda #0
	sta fp_rows
:	inc fp_rows
	jsr fast_scroll
	lda FP_LDTB1
	bpl :-
	ldx fp_rows
	dex
	beq :+
	dec $02a5
:	ldx fp_rows
	rts

fp_rows:
	.byte 0

;----------------------------------------------------------------------
; scroll the 40 column screen up by one row
fast_scroll:
	lda reu_enabled	; with an REU, let it move the rows (see below)
	beq :+
	lda modem_type
	cmp #MODEM_TYPE_ULTIMATE_NET
	bne :+
	jmp reu_scroll
:	ldy FP_COLOR	; the KERNAL fills the new row with the text color
	ldx #39
@loop:
.repeat 24, row
	lda FP_SCREEN+(row+1)*40,x
	sta FP_SCREEN+row*40,x
	lda FP_COLRAM+(row+1)*40,x
	sta FP_COLRAM+row*40,x
.endrepeat
	lda #' '
	sta FP_SCREEN+24*40,x
	tya
	sta FP_COLRAM+24*40,x
	dex
	bmi :+
	jmp @loop
:

	; shift the line link flags up, keeping each row's page bits
scroll_links:
	ldx #0
@link:	lda FP_LDTB1,x
	and #$7f
	ldy FP_LDTB1+1,x
	bpl :+
	ora #$80
:	sta FP_LDTB1,x
	inx
	cpx #24
	bne @link
	lda FP_LDTB1+24
	ora #$80
	sta FP_LDTB1+24
	rts

;----------------------------------------------------------------------
; Scroll with REU DMA: rows 1-24 of screen and color RAM go to REU bank 1
; and come back one row higher, about 1 cycle per byte instead of 10.
; The CPU stops during each 960 byte transfer, which an NMI driven modem
; (User Port, SwiftLink) could not take at high speed, so this is only
; used with Ultimate Net, which the terminal polls. The buffer uses bank 0.
REU_SCRATCH_BANK = 1

reu_scroll:
	lda #0
	sta $df0a	; both addresses count up
	sta $df04	; REU $10000
	sta $df05
	lda #REU_SCRATCH_BANK
	sta $df06
	lda #<(24*40)
	sta $df07
	lda #>(24*40)
	sta $df08
	lda #<(FP_SCREEN+40)
	sta $df02
	lda #>(FP_SCREEN+40)
	sta $df03
	lda #$b0	; stash, then reload the registers
	sta $df01
	lda #<FP_SCREEN
	sta $df02
	lda #>FP_SCREEN
	sta $df03
	lda #$b1	; fetch to row 0
	sta $df01

	lda #>(24*40)	; color RAM to REU $10400
	sta $df05
	lda #<(FP_COLRAM+40)
	sta $df02
	lda #>(FP_COLRAM+40)
	sta $df03
	lda #$b0
	sta $df01
	lda #<FP_COLRAM
	sta $df02
	lda #>FP_COLRAM
	sta $df03
	lda #$b1
	sta $df01

	ldy FP_COLOR	; clear the bottom row
	ldx #39
:	lda #' '
	sta FP_SCREEN+24*40,x
	tya
	sta FP_COLRAM+24*40,x
	dex
	bpl :-
	jmp scroll_links
