; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; 80 column ANSI terminal mode
;
; A fifth terminal mode next to 40/80 columns x PETSCII/ASCII. It shares the
; 80 column bitmap with 80columns.s (bitmap at $E000, 40x25 color cells at
; $D400) but draws on its own:
;
; * a 256 glyph CP437 font, 4x8 pixels (ansi80font.inc)
; * foreground and background color per 8x8 cell, so two neighboring
;   characters share their colors (a VIC-II limit)
; * a CSI parser: ESC [ params ; ... final
;
; The other four modes never run any of this code.
;
; Pixels: a set bit in the bitmap shows the high nibble color of its cell,
; a clear bit the low nibble. The font stores foreground pixels as 1, so a
; cell holds (fg << 4) | bg.

SET_ASCII

A80_BITMAP	= $e000
A80_COLOR	= $d400
; blinking, one byte per color cell, in RAM under I/O that the ANSI mode
; doesn't otherwise use (80columns.s keeps its text screen there)
A80_BLON	= $d800	; the cell's real colors
A80_BLFLAG	= $dc00	; $80 | background color: the cell blinks; 0: it doesn't
A80_COLS	= 80
A80_ROWS	= 25

; zero page: the 40 column line link table, unused in 80 column mode
; (80columns.s uses the same area the same way)
a80_bmp		= $dd	; 2 bytes: bitmap pointer
a80_col		= $df	; 2 bytes: color cell pointer
a80_src		= $e1	; 2 bytes
a80_dst		= $e3	; 2 bytes

.macro A80_RAM_ON
	lda $01
	pha
	lda #$34	; see Internals.md#Banking
	sta $01
.endmacro
.macro A80_RAM_OFF
	pla
	sta $01
.endmacro

;----------------------------------------------------------------------
; ANSI colors 0-15 -> C64 colors. Normal, then bright.
; Edit here to change the palette.
ansi80_colors:
	;     black red green brown blue purple cyan ltgray
	.byte 0,    2,  5,    9,    6,   4,     3,   15
	;     dkgray ltred ltgreen yellow ltblue purple cyan white
	.byte 11,    10,   13,     7,     14,    4,     3,   1

;----------------------------------------------------------------------
; state
ansi80_active:	.byte 0	; $80: ANSI mode is on
a80_x:		.byte 0	; cursor column 0-79
a80_y:		.byte 0	; cursor row 0-24
a80_wrap:	.byte 0	; 1: the last column was written, wrap before the next char
a80_fg:		.byte 7	; SGR state
a80_bg:		.byte 0
a80_bold:	.byte 0
a80_blink:	.byte 0
a80_rev:	.byte 0
a80_ul:		.byte 0	; underline
a80_ice:	.byte 0	; 1: blink means bright background (iCE colors) [no UI yet]
a80_anyblink:	.byte 0	; 1: some cell may blink
a80_phase:	.byte 0	; 1: blinking cells are hidden right now
a80_blink_t:	.byte 0	; jiffy clock at the last blink
a80_chg:	.byte 0
a80_oflag:	.byte 0
a80_petc:	.byte $ff	; C64 color set by a PETSCII color code, $ff: none
a80_fgc:	.byte 15	; effective C64 colors
a80_bgc:	.byte 0
a80_cell:	.byte $f0	; (fg << 4) | bg
a80_cellsw:	.byte $0f	; (bg << 4) | fg
a80_sx:		.byte 0	; ESC[s
a80_sy:		.byte 0
a80_csr:	.byte 0	; 1: cursor drawn
a80_state:	.byte 0	; parser: 0 text, 1 ESC, 2 CSI, 3 music, 4 ESC + intermediate
a80_pn:		.byte 0	; index of the current parameter
a80_priv:	.byte 0	; 1: private/intermediate sequence (ignored)
A80_MAXP	= 8
a80_par:	.res A80_MAXP
; drawing
a80_gx:		.byte 0
a80_gy:		.byte 0
a80_inv:	.byte 0
a80_old:	.byte 0
a80_gbuf:	.res 8
a80_t0:		.byte 0
a80_t1:		.byte 0
a80_cnt:	.byte 0

; whether the buffer holds raw ANSI bytes (see buffer.s)
buffer_ansi:	.byte 0

;----------------------------------------------------------------------
; switch the mode on: called with the 80 column bitmap active
ansi80_enter:
	lda #$80
	sta ansi80_active
	lda #1
	sta ascii_mode
ansi80_reset:
	lda #0
	sta a80_state
	sta a80_csr
	jsr a80_sgr_reset
	jmp a80_clear_home

; switch the mode off
ansi80_leave:
	jsr ansi80_csr_off
	lda #0
	sta ansi80_active
	rts

;----------------------------------------------------------------------
; cursor: invert the character cell
ansi80_csr_on:
	lda a80_csr
	bne a80_rts
	inc a80_csr
	bne a80_csr_xor	; always
ansi80_csr_off:
	lda a80_csr
	beq a80_rts
	dec a80_csr
a80_csr_xor:
	lda a80_x
	sta a80_gx
	lda a80_y
	sta a80_gy
	jsr a80_calc_bmp
	A80_RAM_ON
	lda #$f0
	bcc :+
	lda #$0f
:	sta a80_t0
	ldy #7
:	lda (a80_bmp),y
	eor a80_t0
	sta (a80_bmp),y
	dey
	bpl :-
	A80_RAM_OFF
a80_rts:
	rts

;----------------------------------------------------------------------
; a80_gx/a80_gy -> a80_bmp = top of the cell's bitmap, a80_col = color cell
; returns C = 1 for the right half of the cell
a80_calc_bmp:
	ldx a80_gy
	lda a80_gx
	lsr
	php
	clc
	adc row40_lo,x
	sta a80_col
	lda row40_hi,x
	adc #0
	sta a80_col+1
	lda a80_gx
	and #$fe	; (x / 2) * 8 = (x & $fe) * 4
	asl
	asl
	sta a80_bmp
	lda #0
	rol
	sta a80_bmp+1
	lda a80_bmp
	clc
	adc row320_lo,x
	sta a80_bmp
	lda a80_bmp+1
	adc row320_hi,x
	sta a80_bmp+1
	plp
	rts

;----------------------------------------------------------------------
; draw glyph A at a80_gx/a80_gy in the current colors
a80_draw:
	sta a80_t1
	jsr a80_calc_bmp
	php		; C: right half
	A80_RAM_ON
	ldy #0
	sty a80_inv
	sty a80_chg
	lda a80_col
	sta a80_src
	sta a80_dst
	lda a80_col+1
	clc
	adc #>(A80_BLON-A80_COLOR)
	sta a80_src+1
	adc #>(A80_BLFLAG-A80_BLON)
	sta a80_dst+1
	lda (a80_dst),y
	bpl :+
	lda (a80_src),y	; blinking cell: its real colors
	jmp :++
:	lda (a80_col),y
:	sta a80_old
	cmp a80_cell
	beq @colors_ok
	cmp a80_cellsw
	beq @invert
	; a blank glyph only needs the background somewhere in the cell,
	; a full block only the foreground
	lda a80_ul	; an underlined blank isn't blank
	bne @nonblank
	lda a80_t1
	beq @blank
	cmp #' '
	beq @blank
	cmp #$ff
	beq @blank
@nonblank:
	lda a80_t1
	cmp #$db
	bne @set
	lda a80_old	; full block
	lsr
	lsr
	lsr
	lsr
	cmp a80_fgc
	beq @colors_ok
	lda a80_old
	and #$0f
	cmp a80_fgc
	beq @invert
	bne @set	; always
@blank:	lda a80_old
	and #$0f
	cmp a80_bgc
	beq @colors_ok
	lda a80_old
	lsr
	lsr
	lsr
	lsr
	cmp a80_bgc
	beq @invert
@set:	lda a80_cell
	sta a80_old
	inc a80_chg
	jmp @colors_ok
@invert:
	dec a80_inv	; $ff
@colors_ok:
	; blinking: remember the real colors of a blinking cell
	ldy #0
	lda a80_blink
	beq @noblink
	lda a80_ice
	bne @noblink
	lda a80_bgc
	ora #$80
	sta (a80_dst),y
	lda a80_old
	sta (a80_src),y
	lda #1
	sta a80_anyblink
	bne @write	; always
@noblink:
	lda a80_chg	; new colors: the cell stops blinking
	bne @unblink
	lda a80_ul
	bne @unblink
	lda a80_t1	; a blank keeps the cell blinking
	beq @write
	cmp #' '
	beq @write
	cmp #$ff
	beq @write
@unblink:
	lda #0
	sta (a80_dst),y
@write:	lda (a80_dst),y
	bpl @shown
	ldx a80_phase
	beq @shown
	and #$0f	; hidden phase: background only
	tax
	lda a80_x17,x
	bne @put	; [not always: black]
	beq @put
@shown:	lda a80_old
@put:	sta (a80_col),y
	pla		; banking
	tay
	pla		; flags from a80_calc_bmp: C = right half
	and #1
	sta a80_t0
	tya
	pha
	; glyph rows into a80_gbuf, already shifted into the target nibble
	lda a80_t1
	lsr
	tax		; X = glyph / 2, C = odd glyph (low nibble)
	lda a80_t0
	jne @right
	bcs @l_from_lo
	; left half from the high nibble
	.repeat 8, r
	lda ansi80_font_0+r*128,x
	eor a80_inv
	and #$f0
	sta a80_gbuf+r
	.endrepeat
	jmp @merge_l
@l_from_lo:
	.repeat 8, r
	lda ansi80_font_0+r*128,x
	eor a80_inv
	asl
	asl
	asl
	asl
	sta a80_gbuf+r
	.endrepeat
@merge_l:
	lda a80_ul
	beq :+
	lda a80_inv	; underline: bottom row in the foreground
	eor #$ff
	and #$f0
	sta a80_gbuf+7
:	ldy #7
:	lda (a80_bmp),y
	and #$0f
	ora a80_gbuf,y
	sta (a80_bmp),y
	dey
	bpl :-
	A80_RAM_OFF
	rts
@right:
	bcc @r_from_hi
	; right half from the low nibble
	.repeat 8, r
	lda ansi80_font_0+r*128,x
	eor a80_inv
	and #$0f
	sta a80_gbuf+r
	.endrepeat
	jmp @merge_r
@r_from_hi:
	.repeat 8, r
	lda ansi80_font_0+r*128,x
	eor a80_inv
	lsr
	lsr
	lsr
	lsr
	sta a80_gbuf+r
	.endrepeat
@merge_r:
	lda a80_ul
	beq :+
	lda a80_inv
	eor #$ff
	and #$0f
	sta a80_gbuf+7
:	ldy #7
:	lda (a80_bmp),y
	and #$f0
	ora a80_gbuf,y
	sta (a80_bmp),y
	dey
	bpl :-
	A80_RAM_OFF
	rts

;----------------------------------------------------------------------
; erase whole cells A..X (inclusive, 0-39) on row Y in the current colors
a80_erase_cells:
	sta a80_t0
	stx a80_t1
	sty a80_gy
	asl
	sta a80_gx	; first column = 2 * cell
	jsr a80_calc_bmp
	A80_RAM_ON
	lda a80_t1
	sec
	sbc a80_t0
	tax		; cells - 1
	ldy #0
	lda a80_cell
:	sta (a80_col),y
	iny
	dex
	bpl :-
	lda a80_col	; erased cells don't blink
	sta a80_dst
	lda a80_col+1
	clc
	adc #>(A80_BLFLAG-A80_COLOR)
	sta a80_dst+1
	lda a80_t1
	sec
	sbc a80_t0
	tax
	ldy #0
	tya
:	sta (a80_dst),y
	iny
	dex
	bpl :-
	ldx a80_t1	; bytes = cells * 8
	inx
	txa
	sec
	sbc a80_t0
	sta a80_t0
	lda #0
	asl a80_t0
	rol
	asl a80_t0
	rol
	asl a80_t0
	rol
	tax		; X = full pages, a80_t0 = rest
	lda #0
	tay
	cpx #0
	beq @rest
:	sta (a80_bmp),y
	iny
	bne :-
	inc a80_bmp+1
	dex
	bne :-
@rest:	ldy a80_t0
	beq @done
:	dey
	sta (a80_bmp),y
	bne :-
@done:	A80_RAM_OFF
	rts

; erase columns A..X (inclusive, 0-79) on row Y
a80_erase:
	sta a80_lo
	stx a80_hi
	sty a80_row
	cpx a80_lo
	bcc @done
	lsr
	bcc @1		; starts on a left half: fine
	lda a80_lo	; right half of the first cell: draw a blank
	jsr @blank
	inc a80_lo
	lda a80_hi
	cmp a80_lo
	bcc @done
@1:	lda a80_hi
	lsr
	bcs @2		; ends on a right half: fine
	lda a80_hi	; left half of the last cell: draw a blank
	jsr @blank
	lda a80_hi
	beq @done
	dec a80_hi
	cmp a80_lo
	beq @done	; hi was lo
	bcc @done
@2:	lda a80_lo
	lsr
	pha
	lda a80_hi
	lsr
	tax
	pla
	ldy a80_row
	jmp a80_erase_cells
@done:	rts
@blank:	sta a80_gx
	lda a80_row
	sta a80_gy
	lda #' '
	jmp a80_draw

a80_lo:		.byte 0
a80_hi:		.byte 0
a80_row:	.byte 0

; erase rows A..X (inclusive)
a80_erase_rows:
	sta a80_rows_cur
	stx a80_rows_end
@loop:	lda a80_rows_cur
	cmp a80_rows_end
	beq :+
	bcs @done
:	tay
	lda #0
	ldx #39
	jsr a80_erase_cells
	inc a80_rows_cur
	bne @loop	; always
@done:	rts
a80_rows_cur:	.byte 0
a80_rows_end:	.byte 0

;----------------------------------------------------------------------
; scroll rows A..24 up by one; row 24 is cleared
a80_scroll_up:
	cmp #A80_ROWS-1
	bcs a80_clear_last
	sta a80_t0
	; bitmap: jump into the unrolled copy at half row 2 * A
	ldx #0
	asl
	asl		; * 12 bytes per row
	sta a80_t1
	asl
	adc a80_t1
	bcc :+
	inx
:	clc
	adc #<a80_bm_copy
	sta a80_bm_jmp+1
	txa
	adc #>a80_bm_copy
	sta a80_bm_jmp+2
	ldx #0		; color and blink: * 18 bytes per row
	lda a80_t0
	asl
	asl
	asl
	asl
	bcc :+
	inx
:	sta a80_t1
	lda a80_t0
	asl
	clc
	adc a80_t1
	bcc :+
	inx
:	clc
	adc #<a80_col_copy
	sta a80_col_jmp+1
	txa
	adc #>a80_col_copy
	sta a80_col_jmp+2
	A80_RAM_ON
	ldy #0
a80_bm_jmp:
	jmp a80_bm_copy
a80_bm_next:
	iny
	cpy #160
	beq :+
	jmp a80_bm_jmp
:	ldy #0
a80_col_jmp:
	jmp a80_col_copy
a80_col_next:
	iny
	cpy #40
	beq :+
	jmp a80_col_jmp
:	A80_RAM_OFF
a80_clear_last:
	lda #A80_ROWS-1
	tax
	jmp a80_erase_rows

a80_bm_copy:
	.repeat 48, i
	lda A80_BITMAP+(i+2)*160,y
	sta A80_BITMAP+i*160,y
	.endrepeat
	jmp a80_bm_next
a80_col_copy:
	.repeat 24, i
	lda A80_COLOR+(i+1)*40,y
	sta A80_COLOR+i*40,y
	lda A80_BLON+(i+1)*40,y
	sta A80_BLON+i*40,y
	lda A80_BLFLAG+(i+1)*40,y
	sta A80_BLFLAG+i*40,y
	.endrepeat
	jmp a80_col_next

; scroll rows A..24 down by one; row A is cleared
a80_scroll_down:
	sta a80_t0
	lda #A80_ROWS-2
	sta a80_row
@loop:	lda a80_row
	cmp a80_t0
	bcc @clear
	ldx a80_row
	A80_RAM_ON
	lda row320_lo,x
	sta a80_src
	lda row320_hi,x
	sta a80_src+1
	lda row320_lo+1,x
	sta a80_dst
	lda row320_hi+1,x
	sta a80_dst+1
	ldy #0
:	lda (a80_src),y
	sta (a80_dst),y
	iny
	bne :-
	inc a80_src+1
	inc a80_dst+1
	ldy #320-256-1
:	lda (a80_src),y
	sta (a80_dst),y
	dey
	bpl :-
	lda row40_lo,x
	sta a80_src
	lda row40_hi,x
	sta a80_src+1
	lda row40_lo+1,x
	sta a80_dst
	lda row40_hi+1,x
	sta a80_dst+1
	ldx #3		; colors, real colors, blink flags
@arr:	ldy #39
:	lda (a80_src),y
	sta (a80_dst),y
	dey
	bpl :-
	lda a80_src+1
	clc
	adc #>(A80_BLON-A80_COLOR)
	sta a80_src+1
	lda a80_dst+1
	clc
	adc #>(A80_BLON-A80_COLOR)
	sta a80_dst+1
	dex
	bne @arr
	A80_RAM_OFF
	lda a80_row
	beq @clear
	dec a80_row
	jmp @loop
@clear:	lda a80_t0
	tax
	jmp a80_erase_rows

;----------------------------------------------------------------------
row40_lo:
	.repeat A80_ROWS, i
	.byte <(A80_COLOR+i*40)
	.endrepeat
row40_hi:
	.repeat A80_ROWS, i
	.byte >(A80_COLOR+i*40)
	.endrepeat
row320_lo:
	.repeat A80_ROWS, i
	.byte <(A80_BITMAP+i*320)
	.endrepeat
row320_hi:
	.repeat A80_ROWS, i
	.byte >(A80_BITMAP+i*320)
	.endrepeat

;----------------------------------------------------------------------
; cursor movement
a80_clear_home:
	lda #0
	ldx #A80_ROWS-1
	jsr a80_erase_rows
	lda #0
	sta a80_anyblink
a80_home:
	lda #0
	sta a80_x
	sta a80_y
	sta a80_wrap
	rts

a80_cr:	lda #0
	sta a80_x
	sta a80_wrap
	rts

a80_lf:	lda #0
	sta a80_wrap
	lda a80_y
	cmp #A80_ROWS-1
	bcs :+
	inc a80_y
	rts
:	lda #0
	jmp a80_scroll_up

; reverse line feed (ESC M)
a80_rlf:
	lda #0
	sta a80_wrap
	lda a80_y
	beq :+
	dec a80_y
	rts
:	jmp a80_scroll_down

a80_bs:	lda #0
	sta a80_wrap
	lda a80_x
	beq :+
	dec a80_x
:	rts

a80_tab:
	lda #0
	sta a80_wrap
	lda a80_x
	and #$f8
	clc
	adc #8
	cmp #A80_COLS
	bcc :+
	lda #A80_COLS-1
:	sta a80_x
	rts

;----------------------------------------------------------------------
; print glyph A at the cursor, wrapping late at column 80
a80_print:
	ldx a80_wrap
	beq :+
	pha
	jsr a80_cr
	jsr a80_lf
	pla
:	ldx a80_x
	stx a80_gx
	ldx a80_y
	stx a80_gy
	jsr a80_draw
	lda a80_x
	cmp #A80_COLS-1
	bcs :+
	inc a80_x
	rts
:	lda #1
	sta a80_wrap
	rts

;----------------------------------------------------------------------
; SGR
a80_sgr_defaults:
	lda #7
	sta a80_fg
	lda #0
	sta a80_bg
	sta a80_bold
	sta a80_blink
	sta a80_rev
	sta a80_ul
	lda #$ff
	sta a80_petc
	rts
a80_sgr_reset:
	jsr a80_sgr_defaults
a80_sgr_apply:
	lda a80_bold
	beq :+
	lda #8
:	ora a80_fg
	tax
	lda ansi80_colors,x
	sta a80_fgc
	lda a80_ice	; iCE colors: blink -> bright background
	beq :+
	lda a80_blink
	beq :+
	lda #8
:	ora a80_bg
	tax
	lda ansi80_colors,x
	sta a80_bgc
	lda a80_petc	; CCGMS's own PETSCII messages
	bmi :+
	sta a80_fgc
	lda #0
	sta a80_bgc
:	lda a80_rev
	beq a80_cell_apply
	ldx a80_fgc
	lda a80_bgc
	sta a80_fgc
	stx a80_bgc
a80_cell_apply:
	lda a80_fgc
	asl
	asl
	asl
	asl
	ora a80_bgc
	sta a80_cell
	lda a80_bgc
	asl
	asl
	asl
	asl
	ora a80_fgc
	sta a80_cellsw
	rts

a80_sgr:
	lda #$ff
	sta a80_petc
	ldx #0
@loop:	lda a80_par,x
	bne :+
	jsr a80_sgr_defaults	; 0
	jmp @next
:	cmp #1
	bne :+
	sta a80_bold
	beq @next
:	cmp #22
	beq @nobold
	cmp #2
	bne :+
@nobold:
	lda #0
	sta a80_bold
	beq @next
:	cmp #5
	beq @blink
	cmp #6
	bne :+
@blink:	lda #1
	sta a80_blink
	bne @next
:	cmp #25
	bne :+
	lda #0
	sta a80_blink
	beq @next
:	cmp #7
	bne :+
	lda #1
	sta a80_rev
	bne @next
:	cmp #27
	bne :+
	lda #0
	sta a80_rev
	beq @next
:	cmp #4
	bne :+
	sta a80_ul	; non-zero
	beq @next	; [Z from cmp]
:	cmp #24
	bne :+
	lda #0
	sta a80_ul
	beq @next
:	cmp #39
	bne :+
	lda #7
	sta a80_fg
	bne @next
:	cmp #49
	bne :+
	lda #0
	sta a80_bg
	beq @next
:	sec
	sbc #30
	cmp #8
	bcs :+
	sta a80_fg
	bcc @next
:	sbc #10		; C = 1 here
	cmp #8
	bcs @next	; unknown: ignore
	sta a80_bg
@next:	inx
	cpx a80_pn
	jeq @loop
	jcc @loop
	jmp a80_sgr_apply

;----------------------------------------------------------------------
; parameter helpers
a80_par1:		; first parameter, 0 -> 1
	lda a80_par
	bne :+
	lda #1
:	rts
a80_par2:		; second parameter, 0 -> 1
	lda a80_par+1
	bne :+
	lda #1
:	rts

;----------------------------------------------------------------------
; Feed one received byte to the ANSI parser and the screen.
; Clobbers A, X, Y.
ansi80_putc:
	ldx a80_state
	bne a80_in_esc
	cmp #' '
	bcc a80_ctrl
	jmp a80_print

; control characters
a80_ctrl:
	cmp #CR
	bne :+
	jmp a80_cr
:	cmp #10		; LF
	bne :+
	jmp a80_lf
:	cmp #27		; ESC
	bne :+
	lda #1
	sta a80_state
	rts
:	cmp #8		; BS
	bne :+
	jmp a80_bs
:	cmp #9		; TAB
	bne :+
	jmp a80_tab
:	cmp #7		; BEL
	bne :+
	jmp bell
:	cmp #12		; FF
	bne :+
	jmp a80_clear_home
:	cmp #0
	beq :+
	jmp a80_print	; other control codes show their CP437 glyphs
:	rts

a80_in_esc:
	dex
	bne a80_not_esc
; state 1: after ESC
	cmp #'['
	bne :+
	lda #2
	sta a80_state
	lda #0
	sta a80_pn
	sta a80_priv
	ldx #A80_MAXP-1
@clr:	sta a80_par,x
	dex
	bpl @clr
	rts
:	cmp #27
	beq @stay
	ldx #0
	stx a80_state
	cmp #' '
	bcc a80_ctrl	; control code ends the sequence
	cmp #$30
	bcs :+
	lda #4		; ESC + intermediate (e.g. ESC ( B): skip one more byte
	sta a80_state
@stay:	rts
:	cmp #'7'
	bne :+
	jmp a80_save
:	cmp #'8'
	bne :+
	jmp a80_restore
:	cmp #'D'
	bne :+
	jmp a80_lf
:	cmp #'E'
	bne :+
	jsr a80_cr
	jmp a80_lf
:	cmp #'M'
	bne :+
	jmp a80_rlf
:	cmp #'c'
	bne :+
	jmp ansi80_reset
:	rts		; anything else: ignore

a80_not_esc:
	dex
	beq a80_csi
	dex
	beq a80_music
; state 4: ESC + intermediate: drop the final byte
	cmp #' '
	bcs :+
	ldx #0		; control code: abort, handle it
	stx a80_state
	jmp a80_ctrl
:	cmp #$30
	bcc :+		; more intermediates
	ldx #0
	stx a80_state
:	rts

; state 3: ANSI music, swallowed until ^N; a control code or a byte that
; can't be music ends it early and is handled normally
a80_music:
	cmp #$0e	; ^N: end of music
	beq @end
	cmp #' '
	bcc @ctrl
	cmp #$7f
	bcc @rts	; printable: part of the music string
@ctrl:	ldx #0
	stx a80_state
	jmp ansi80_putc
@end:	ldx #0
	stx a80_state
@rts:	rts

; state 2: CSI
a80_csi:
	cmp #' '
	bcs :+
	cmp #27
	jne a80_ctrl	; control codes inside a sequence still work
	lda #1
	sta a80_state	; ESC restarts
	rts
:	cmp #$40
	bcs a80_final
	cmp #$30
	bcc @priv	; intermediate
	cmp #':'
	bcc @digit
	cmp #';'
	beq @next
@priv:	lda #1		; ? < = > : and intermediates: a sequence we ignore
	sta a80_priv
	rts
@next:	ldx a80_pn
	cpx #A80_MAXP-1
	bcs :+
	inc a80_pn
:	rts
@digit:	and #$0f
	sta a80_t0
	ldx a80_pn
	lda a80_par,x
	cmp #26
	bcs @max
	sta a80_t1	; * 10
	asl
	asl
	adc a80_t1
	asl
	adc a80_t0
	bcs @max
	sta a80_par,x
	rts
@max:	lda #255
	sta a80_par,x
	rts

a80_final:
	ldx #0
	stx a80_state
	cmp #$7f
	bcs @ignore
	ldx a80_priv
	bne @ignore
	ldx #a80_cmd_end-a80_cmds-1
:	cmp a80_cmds,x
	beq @found
	dex
	bpl :-
@ignore:
	rts
@found:	lda a80_cmd_hi,x
	pha
	lda a80_cmd_lo,x
	pha
	rts

a80_cmds:
	.byte "ABCDEFGHJKdfmsunMN|LSTX@P"
a80_cmd_end:
a80_cmd_lo:
	.lobytes a80_cuu-1, a80_cud-1, a80_cuf-1, a80_cub-1, a80_cnl-1, a80_cpl-1, a80_cha-1, a80_cup-1, a80_ed-1, a80_el-1, a80_vpa-1, a80_cup-1
	.lobytes a80_sgr-1, a80_save-1, a80_restore-1, a80_dsr-1, a80_dl-1, a80_music_on-1, a80_music_on-1, a80_il-1, a80_su-1, a80_sd-1, a80_ech-1, a80_ich-1, a80_dch-1
a80_cmd_hi:
	.hibytes a80_cuu-1, a80_cud-1, a80_cuf-1, a80_cub-1, a80_cnl-1, a80_cpl-1, a80_cha-1, a80_cup-1, a80_ed-1, a80_el-1, a80_vpa-1, a80_cup-1
	.hibytes a80_sgr-1, a80_save-1, a80_restore-1, a80_dsr-1, a80_dl-1, a80_music_on-1, a80_music_on-1, a80_il-1, a80_su-1, a80_sd-1, a80_ech-1, a80_ich-1, a80_dch-1
.assert a80_cmd_hi-a80_cmd_lo = a80_cmd_end-a80_cmds, error, "ANSI command table"

; ESC[nA
a80_cuu:
	jsr a80_par1
	sta a80_t0
	lda a80_y
	sec
	sbc a80_t0
	bcs :+
	lda #0
:	sta a80_y
	lda #0
	sta a80_wrap
	rts

; ESC[nB
a80_cud:
	jsr a80_par1
	clc
	adc a80_y
	bcs :+
	cmp #A80_ROWS
	bcc :++
:	lda #A80_ROWS-1
:	sta a80_y
	lda #0
	sta a80_wrap
	rts

; ESC[nC
a80_cuf:
	jsr a80_par1
	clc
	adc a80_x
	bcs :+
	cmp #A80_COLS
	bcc :++
:	lda #A80_COLS-1
:	sta a80_x
	lda #0
	sta a80_wrap
	rts

; ESC[nD
a80_cub:
	jsr a80_par1
	sta a80_t0
	lda a80_x
	sec
	sbc a80_t0
	bcs :+
	lda #0
:	sta a80_x
	lda #0
	sta a80_wrap
	rts

; ESC[nE
a80_cnl:
	jsr a80_cud
	jmp a80_cr

; ESC[nF
a80_cpl:
	jsr a80_cuu
	jmp a80_cr

; ESC[nG
a80_cha:
	jsr a80_par1
	ldx #A80_COLS
	jsr a80_clamp
	sta a80_x
	lda #0
	sta a80_wrap
	rts

; ESC[nd
a80_vpa:
	jsr a80_par1
	ldx #A80_ROWS
	jsr a80_clamp
	sta a80_y
	lda #0
	sta a80_wrap
	rts

; ESC[row;colH, ESC[row;colf
a80_cup:
	jsr a80_par1
	ldx #A80_ROWS
	jsr a80_clamp
	sta a80_y
	jsr a80_par2
	ldx #A80_COLS
	jsr a80_clamp
	sta a80_x
	lda #0
	sta a80_wrap
	rts

; 1-based A, limit X -> 0-based, at most X-1
a80_clamp:
	sta a80_t0
	dex
	txa
	ldx a80_t0
	dex
	stx a80_t0
	cmp a80_t0
	bcc :+
	lda a80_t0
:	rts

; ESC[nJ
a80_ed:
	lda a80_par
	beq @below
	cmp #1
	beq @above
	cmp #2
	bne @rts
	jmp a80_clear_home	; like ANSI.SYS, which BBS art expects
@below:	jsr a80_el0
	ldx a80_y
	inx
	txa
	ldx #A80_ROWS-1
	jmp a80_erase_rows
@above:	jsr a80_el1
	ldx a80_y
	beq @rts
	dex
	lda #0
	jmp a80_erase_rows
@rts:	rts

; ESC[nK
a80_el:
	lda a80_par
	beq a80_el0
	cmp #1
	beq a80_el1
	cmp #2
	bne @rts
	lda #0
	ldx #A80_COLS-1
	ldy a80_y
	jmp a80_erase
@rts:	rts
a80_el0:
	lda a80_x
	ldx #A80_COLS-1
	ldy a80_y
	jmp a80_erase
a80_el1:
	lda #0
	ldx a80_x
	ldy a80_y
	jmp a80_erase

;----------------------------------------------------------------------
; ESC[n@: insert n blanks at the cursor, the rest of the line moves right
a80_ich:
	jsr a80_count
	lda #A80_COLS-1
	sta a80_cnt	; destination column
@loop:	lda a80_cnt
	sec
	sbc a80_n
	bcc @erase
	cmp a80_x
	bcc @erase
	tax		; source column
	lda a80_cnt
	jsr a80_move_char
	dec a80_cnt
	jmp @loop
@erase:	lda a80_x
	clc
	adc a80_n
	tax
	dex
	lda a80_x
	ldy a80_y
	jmp a80_erase

; ESC[nP: delete n characters at the cursor, the rest of the line moves left
a80_dch:
	jsr a80_count
	lda a80_x
	sta a80_cnt	; destination column
@loop:	lda a80_cnt
	clc
	adc a80_n
	cmp #A80_COLS
	bcs @erase
	tax		; source column
	lda a80_cnt
	jsr a80_move_char
	inc a80_cnt
	jmp @loop
@erase:	lda #A80_COLS
	sec
	sbc a80_n
	ldx #A80_COLS-1
	ldy a80_y
	jmp a80_erase

; a80_n = first parameter (0 -> 1), at most 80 - cursor column
a80_count:
	lda #0
	sta a80_wrap
	lda #A80_COLS
	sec
	sbc a80_x
	sta a80_t0
	jsr a80_par1
	cmp a80_t0
	bcc :+
	lda a80_t0
:	sta a80_n
	rts

; move the character in column X to column A on the cursor row.
; The cell colors move along; a character that lands in the right half
; of a cell keeps that cell's colors unless both halves come from the
; same source cell.
a80_move_char:
	sta a80_gx	; destination
	stx a80_mv_src
	lda a80_y
	sta a80_gy
	jsr a80_calc_bmp
	lda #0
	rol
	sta a80_mv_dhalf
	lda a80_bmp
	sta a80_dst
	lda a80_bmp+1
	sta a80_dst+1
	lda a80_col
	sta a80_mv_dcol
	lda a80_col+1
	sta a80_mv_dcol+1
	lda a80_mv_src
	sta a80_gx
	jsr a80_calc_bmp
	lda #0
	rol
	sta a80_mv_shalf
	A80_RAM_ON
	ldy #0
	lda (a80_col),y	; source colors
	ldx a80_mv_dhalf
	beq :+		; lands in a left half
	ldx a80_mv_shalf
	beq @pixels	; odd move into a right half: keep the cell colors
:	pha
	jsr a80_mv_blink
	pla
	sta (a80_col),y
@pixels:
	ldy #7
@row:	lda (a80_bmp),y
	ldx a80_mv_shalf
	bne @from_r
	and #$f0
	ldx a80_mv_dhalf
	beq @put
	lsr
	lsr
	lsr
	lsr
	jmp @put
@from_r:
	and #$0f
	ldx a80_mv_dhalf
	bne @put
	asl
	asl
	asl
	asl
@put:	sta a80_t0
	lda #$0f	; bits to keep in the destination byte
	ldx a80_mv_dhalf
	beq :+
	lda #$f0
:	and (a80_dst),y
	ora a80_t0
	sta (a80_dst),y
	dey
	bpl @row
	A80_RAM_OFF
	rts

; move_char helper: copy the blink state of cell a80_col to a80_mv_dcol,
; then point a80_col at the destination. Y = 0.
a80_mv_blink:
	lda a80_col
	sta a80_src
	lda a80_col+1
	clc
	adc #>(A80_BLON-A80_COLOR)
	sta a80_src+1
	lda (a80_src),y
	sta a80_t1
	lda a80_src+1
	adc #>(A80_BLFLAG-A80_BLON)
	sta a80_src+1
	lda (a80_src),y
	sta a80_oflag
	ldx a80_mv_dcol
	stx a80_col
	stx a80_src
	ldx a80_mv_dcol+1
	stx a80_col+1
	txa
	clc
	adc #>(A80_BLON-A80_COLOR)
	sta a80_src+1
	lda a80_t1
	sta (a80_src),y
	lda a80_src+1
	adc #>(A80_BLFLAG-A80_BLON)
	sta a80_src+1
	lda a80_oflag
	sta (a80_src),y
	rts

a80_n:		.byte 0
a80_mv_src:	.byte 0
a80_mv_shalf:	.byte 0
a80_mv_dhalf:	.byte 0
a80_mv_dcol:	.word 0

; ESC[nX: erase n characters
a80_ech:
	jsr a80_par1
	clc
	adc a80_x
	bcs :+
	cmp #A80_COLS+1
	bcc :++
:	lda #A80_COLS
:	tax
	dex
	lda a80_x
	ldy a80_y
	jmp a80_erase

; ESC[s, ESC 7
a80_save:
	lda a80_x
	sta a80_sx
	lda a80_y
	sta a80_sy
	rts

; ESC[u, ESC 8
a80_restore:
	lda a80_sx
	sta a80_x
	lda a80_sy
	sta a80_y
	lda #0
	sta a80_wrap
	rts

; ESC[6n: report the cursor position as ESC[row;colR; ESC[5n: ESC[0n
a80_dsr:
	lda a80_par
	cmp #5
	beq @ok
	cmp #6
	bne @rts
	jsr a80_send_csi
	ldx a80_y
	inx
	txa
	jsr a80_send_num
	lda #';'
	jsr a80_send
	ldx a80_x
	inx
	txa
	jsr a80_send_num
	lda #'R'
	jmp a80_send
@ok:	jsr a80_send_csi
	lda #'0'
	jsr a80_send
	lda #'n'
	jmp a80_send
@rts:	rts

a80_send_csi:
	lda #27
	jsr a80_send
	lda #'['
a80_send:
	sta a80_t1
	txa
	pha
	tya
	pha
	lda a80_t1
	jsr rs232_put
	pla
	tay
	pla
	tax
	rts

; send A (1-99) in decimal
a80_send_num:
	ldx #'0'-1
	sec
:	inx
	sbc #10
	bcs :-
	adc #10+'0'
	pha
	cpx #'0'
	beq :+
	txa
	jsr a80_send
:	pla
	jmp a80_send

; ESC[M without a parameter starts ANSI music; ESC[nM deletes lines
a80_dl:
	lda a80_par
	ora a80_pn
	beq a80_music_on
	jsr a80_par1
	sta a80_cnt
:	lda a80_y
	jsr a80_scroll_up
	dec a80_cnt
	bne :-
	jmp a80_cr
a80_music_on:
	lda #3
	sta a80_state
	rts

; ESC[nL: insert lines
a80_il:
	jsr a80_par1
	sta a80_cnt
:	lda a80_y
	jsr a80_scroll_down
	dec a80_cnt
	bne :-
	jmp a80_cr

; ESC[nS: scroll up
a80_su:
	jsr a80_par1
	sta a80_cnt
:	lda #0
	jsr a80_scroll_up
	dec a80_cnt
	bne :-
	rts

; ESC[nT: scroll down
a80_sd:
	jsr a80_par1
	sta a80_cnt
:	lda #0
	jsr a80_scroll_down
	dec a80_cnt
	bne :-
	rts

;----------------------------------------------------------------------
; Blink: called from the terminal loop. Every 20 jiffies (1/3 s), hide or
; show the foreground of every blinking cell.
ansi80_tick:
	lda a80_anyblink
	beq @rts
	lda JIFFIES
	sec
	sbc a80_blink_t
	cmp #20
	bcc @rts
	lda JIFFIES
	sta a80_blink_t
	lda a80_phase
	eor #1
	sta a80_phase
	A80_RAM_ON
	lda #<A80_COLOR
	sta a80_col
	sta a80_src
	sta a80_dst
	lda #>A80_COLOR
	sta a80_col+1
	lda #>A80_BLON
	sta a80_src+1
	lda #>A80_BLFLAG
	sta a80_dst+1
@page:	ldy #0
@cell:	lda (a80_dst),y
	bpl @next
	ldx a80_phase
	beq @show
	and #$0f
	tax
	lda a80_x17,x
	jmp @put
@show:	lda (a80_src),y
@put:	sta (a80_col),y
@next:	iny
	cpy @len
	bne @cell
	inc a80_col+1
	inc a80_src+1
	inc a80_dst+1
	dec @pages
	beq @done
	lda @pages
	cmp #1
	bne :+
	lda #<(A80_ROWS*40)	; last page: 1000 - 768 cells
	sta @len
:	jmp @page
@done:	lda #4
	sta @pages
	lda #0
	sta @len
	A80_RAM_OFF
@rts:	rts
@pages:	.byte 4
@len:	.byte 0		; 0: 256

a80_x17:
	.repeat 16, i
	.byte i*17
	.endrepeat

;----------------------------------------------------------------------
; Keyboard: send the key in A (PETSCII) to the modem.
; Returns the ASCII byte sent (for half duplex echo), or 0 (Z set).
ansi80_key:
	ldx #a80_key_end-a80_keys-1
:	cmp a80_keys,x
	beq @seq
	dex
	bpl :-
	jsr petscii_to_ascii
	beq @rts
	pha
	jsr rs232_put
	pla
@rts:	rts
@seq:	lda a80_key_final,x
	pha
	jsr a80_send_csi
	pla
	jsr a80_send
	lda #0
	rts

; cursor keys, HOME, CLR (shift-HOME) as End, INST (shift-DEL) as Insert
a80_keys:
	.byte CSR_UP, CSR_DOWN, CSR_RIGHT, CSR_LEFT, HOME, CLR, INST
a80_key_end:
a80_key_final:
	.byte 'A', 'B', 'C', 'D', 'H', 'K', '@'

;----------------------------------------------------------------------
; Local output (CHROUT in ANSI mode): CCGMS's own messages are PETSCII.
; Called from 80columns.s with A = the character. Preserves nothing.
ansi80_bsout:
	cmp #CR
	jeq @cr
	cmp #$8d	; shift-RETURN
	jeq @cr
	cmp #CLR
	bne :+
	jmp a80_clear_home
:	cmp #HOME
	bne :+
	jmp a80_home
:	cmp #CSR_DOWN
	bne :+
	jmp a80_lf
:	cmp #CSR_UP
	bne :+
	jmp a80_rlf
:	cmp #CSR_RIGHT
	bne :+
	lda a80_x
	cmp #A80_COLS-1
	bcs @rts
	inc a80_x
@rts:	rts
:	cmp #CSR_LEFT
	bne :+
	jmp a80_bs
:	cmp #DEL
	bne :+
	jsr a80_bs
	lda a80_x
	sta a80_gx
	lda a80_y
	sta a80_gy
	lda #' '
	jmp a80_draw
:	cmp #RVSON
	bne :+
	lda #1
	sta a80_rev
	jmp a80_sgr_apply
:	cmp #RVSOFF
	bne :+
	lda #0
	sta a80_rev
	jmp a80_sgr_apply
:	ldx #15		; color codes set the foreground directly
:	cmp COLTAB,x
	beq @color
	dex
	bpl :-
	tax
	and #$7f
	cmp #' '
	bcc @rts	; other control codes
	txa
	; PETSCII (lower case set) -> CP437
	cmp #$41
	bcc @print	; space, digits, punctuation
	cmp #$5b
	bcs :+
	ora #$20	; a-z
	bne @print
:	cmp #$60
	bcs :+
	tax		; [ £ ] ^ <-
	lda a80_pet5b-$5b,x
	bne @print
:	cmp #$c0
	bcc @lo
	cmp #$e0
	bcs @gfx
	and #$7f	; $C0-$DF -> $40-$5F: like $60-$7F
	ora #$20
@lo:	cmp #$80
	bcs @gfx	; $A0-$BF (and $80+: none left)
	; $60-$7F: shifted letters = A-Z
	cmp #$61
	bcc @hline
	cmp #$7b
	bcs @gfx
	and #$df
	bne @print
@hline:	lda #$c4	; horizontal line
	bne @print
@gfx:	and #$1f	; $A0-$BF, $E0-$FF: block graphics, approximated
	tax
	lda a80_petgfx,x
@print:	jmp a80_print
@cr:	jsr a80_cr
	jmp a80_lf
@color:	stx a80_petc	; PETSCII color code: C64 color X on black
	jmp a80_sgr_apply

a80_pet5b:
	.byte '[', $9c, ']', $18, $1b
; PETSCII $A0-$BF -> CP437
a80_petgfx:
	.byte $20,$dd,$dc,$c4,$5f,$b3,$b1,$b3	; A0-A7
	.byte $b1,$5c,$b3,$c3,$dc,$c0,$bf,$5f	; A8-AF
	.byte $da,$c1,$c2,$b4,$b3,$dd,$de,$df	; B0-B7
	.byte $dc,$dc,$d9,$dc,$dc,$d9,$df,$dc	; B8-BF

;----------------------------------------------------------------------
; buffer helpers

; buffer save: append ".ans" to the file name in inpbuf (length max) if
; the buffer holds ANSI and the name doesn't end in ".ans" yet
ansi80_fix_name:
	lda buffer_ansi
	beq @rts
	jsr ansi80_name_is_ans
	beq @rts
	ldx max
	cpx #16-4+1
	bcs @rts	; no room
	ldy #0
:	lda a80_dot_ans,y
	sta inpbuf,x
	inx
	iny
	cpy #4
	bne :-
	stx max
@rts:	rts

; Z = 1 if the file name in inpbuf (length max) ends in ".ans"
ansi80_name_is_ans:
	ldx max
	cpx #4
	bcc @no
	ldy #3
:	dex
	lda inpbuf,x
	and #$5f	; fold the three PETSCII letter cases
	cmp a80_dot_ans_fold,y
	bne @no
	dey
	bpl :-
	lda #0
	rts
@no:	lda #1
	rts

a80_dot_ans:
	.byte '.', $41, $4e, $53	; ".ans" in PETSCII lower case
a80_dot_ans_fold:
	.byte '.' & $5f, $41, $4e, $53

;----------------------------------------------------------------------
	.include "ansi80font.inc"
