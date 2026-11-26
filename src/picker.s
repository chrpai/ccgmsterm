; CCGMS Terminal
;
; Copyright (c) 2026, the CCGMS Terminal contributors. All rights reserved.
; This project is licensed under the BSD 3-Clause License.
;
; Upload file picker: "$" at the upload filename prompt lists the
; current drive's directory a screen at a time. CRSR up/down moves,
; CRSR right/left (or + and -) changes the page, RETURN picks, STOP or
; the left arrow cancels.
;
; Each page is read with its own OPEN "$" and CLOSE, straight through,
; so the directory channel never stays open across a pause (on the
; C64U a read after a pause can time out). Only one page is kept:
; PK_PAGE entries of 20 bytes at PK_BUF.
;
; Also the typed type suffix: "NAME,P" (or ,PRG ,S ,SEQ ,U ,USR) asks
; for that type only.

PK_BUF		= xmodem_buffer	; unused while the prompt is up
PK_PAGE		= 20		; entries per page
PK_TOP		= 3		; screen row of the first entry
PK_ESIZE	= 20		; +0/1 blocks, +2 name (16, $A0 padded),
				; +18 type (drtype index), +19 name length

SET_PETSCII
txt_pk_title:
	.byte CLR,WHITE,"Pick a file to upload:",CR
	.byte CYAN,"CRSR moves, +/- page, RETURN picks, STOP quits",CR,0
txt_pk_empty:
	.byte CR,"No files.",CR,0
txt_pk_more:
	.byte "more...",0
txt_pk_dir:
	.byte "$"
SET_ASCII

;----------------------------------------------------------------------
; inpbuf/max hold the typed name. "$" alone: run the picker.
; Sets pk_type: 0 = find the type (P, S, then U), else a drtype index
; (1 SEQ, 2 PRG, 3 USR). C=1: cancelled.
pk_filename:
	lda #0
	sta pk_type
	lda max
	cmp #1
	bne pk_suffix
	lda inpbuf
	cmp #'$'
	bne pk_suffix
	jmp pk_run

; "NAME,X..." with X = P, S or U: type X, and the name ends at the comma
pk_suffix:
	ldx max
@find:	dex
	bmi @no
	lda inpbuf,x
	cmp #','
	bne @find
	txa
	beq @no		; nothing before the comma
	lda inpbuf+1,x
	and #$7f	; shifted or not
	ldy #3
:	cmp drtype,y
	beq @type
	dey
	bne :-
	beq @no
@type:	sty pk_type
	stx max
	lda #0		; the name ends at the comma
	sta inpbuf,x
	sta inpbuf+1,x
@no:	clc
	rts

;----------------------------------------------------------------------
pk_run:
	jsr rs232_off
	lda #0
	sta pk_first
	sta pk_first+1
	sta pk_row
	sta QTSW
@page:	jsr pk_read
	lda pk_n
	bne @show
	lda pk_first	; an empty page after the first: go back one
	ora pk_first+1
	beq @none
	jsr pk_prev
	jmp @page
@none:	lda #<txt_pk_title
	ldy #>txt_pk_title
	jsr outstr
	lda #<txt_pk_empty
	ldy #>txt_pk_empty
	jsr outstr
	jsr pk_key
	jmp @quit
@show:	lda pk_row	; keep the cursor on the page
	cmp pk_n
	bcc :+
	ldx pk_n
	dex
	stx pk_row
:	jsr pk_draw
@key:	jsr pk_key
	cmp #CR
	beq @pick
	cmp #3		; STOP
	beq @quit
	cmp #$5f	; left arrow
	beq @quit
	cmp #CSR_DOWN
	beq @down
	cmp #CSR_UP
	beq @up
	cmp #CSR_RIGHT
	beq @next
	cmp #'+'
	beq @next
	cmp #CSR_LEFT
	beq @back
	cmp #'-'
	beq @back
	cmp #HOME
	bne @key
	lda #0
	sta pk_row
	sta pk_first
	sta pk_first+1
	jmp @page
@down:	ldx pk_row
	inx
	cpx pk_n
	bcc @move
	bit pk_more
	bpl @key
	lda #0
	sta pk_row
	jmp @nextp
@up:	ldx pk_row
	beq @upp
	dex
@move:	lda pk_row
	stx pk_row
	jsr pk_line	; old row without the cursor
	lda pk_row
	jsr pk_line
	jmp @key
@upp:	lda pk_first
	ora pk_first+1
	beq @key
	lda #PK_PAGE-1
	sta pk_row
	jsr pk_prev
	jmp @page
@next:	bit pk_more
	bpl @key
@nextp:	lda pk_first
	clc
	adc #PK_PAGE
	sta pk_first
	bcc :+
	inc pk_first+1
:	jmp @page
@back:	lda pk_first
	ora pk_first+1
	beq @key
	jsr pk_prev
	jmp @page
@pick:	jsr pk_entry	; ptr to the entry at pk_row
	ldy #18
	lda (pk_ptr),y
	beq @bad	; DEL, CBM, DIR, ...
	cmp #4
	bcs @bad	; REL
	sta pk_type
	ldy #19
	lda (pk_ptr),y
	sta max
	tax
	lda #0
	sta inpbuf,x
	sta inpbuf+1,x
	ldy #2
	ldx #0
:	lda (pk_ptr),y
	sta inpbuf,x
	iny
	inx
	cpx max
	bne :-
	lda #CLR
	jsr chrout
	clc
	rts
@bad:	jsr bell
	jmp @key
@quit:	lda #CLR
	jsr chrout
	sec
	rts

; pk_first -= PK_PAGE
pk_prev:
	lda pk_first
	sec
	sbc #PK_PAGE
	sta pk_first
	bcs :+
	dec pk_first+1
:	rts

; wait for a key
pk_key:
	jsr getin
	beq pk_key
	rts

;----------------------------------------------------------------------
; read the page at entry pk_first into PK_BUF: pk_n entries, pk_more
pk_read:
	lda #0
	sta pk_n
	sta pk_more
	lda pk_first
	sta pk_skip
	lda pk_first+1
	sta pk_skip+1
	jsr read_drive_msg	; a message still unread from before
	lda #1
	ldx #<txt_pk_dir
	ldy #>txt_pk_dir
	jsr setnam
	lda #LFN_DIR
	ldx device_disk
	ldy #0
	jsr setlfs
	jsr open
	bcs @end
	ldx #LFN_DIR
	jsr chkin
	bcs @end
	lda #0
	sta status
	jsr pk_get	; load address
	jsr pk_get
	jsr pk_line_in	; the header (disk name)
	bcs @end
@next:	jsr pk_line_in
	bcs @end
	bit pk_isent
	bpl @end	; "BLOCKS FREE."
	lda pk_skip
	ora pk_skip+1
	beq @keep
	lda pk_skip
	bne :+
	dec pk_skip+1
:	dec pk_skip
	jmp @next
@keep:	lda pk_n
	cmp #PK_PAGE
	bcc :+
	lda #$80	; one more after a full page
	sta pk_more
	bne @end
:	jsr pk_store
	inc pk_n
	jmp @next
@end:	jsr clrchn
	lda #LFN_DIR
	jsr close
	jmp read_drive_msg

; next byte; on EOF or an error, return from the caller with C=1
pk_get:
	lda status
	bne @eof
	jsr chrin
	pha
	jsr readst
	and #$ff-$40	; EOI: the byte is good
	bne @err
	pla
	clc
	rts
@err:	pla
@eof:	pla
	pla
	sec
	rts

; read one BASIC line of the listing into pk_e*; C=1 at the end
pk_line_in:
	jsr pk_get	; link
	sta pk_tmp
	jsr pk_get
	ora pk_tmp
	bne :+
	sec		; link 0: the end
	rts
:	jsr pk_get	; blocks
	sta pk_eblk
	jsr pk_get
	sta pk_eblk+1
	lda #0
	sta pk_isent
	sta pk_elen
	sta pk_etype
	ldx #15
	lda #$a0
:	sta pk_ename,x
	dex
	bpl :-
@q1:	jsr pk_get	; up to the opening quote
	beq @done
	cmp #'"'
	bne @q1
	lda #$80
	sta pk_isent
@nm:	jsr pk_get
	beq @done
	cmp #'"'
	beq @sp
	ldx pk_elen
	cpx #16
	bcs @nm
	sta pk_ename,x
	inc pk_elen
	bne @nm
@sp:	jsr pk_get	; spaces, a splat, then the type
	beq @done
	cmp #' '
	beq @sp
	cmp #'*'
	beq @sp
	ldx #4
:	cmp drtype,x
	beq :+
	dex
	bne :-
:	stx pk_etype	; (0: not found, or D for DEL/DIR)
@rest:	jsr pk_get	; the rest of the line
	bne @rest
@done:	clc
	rts

; append pk_e* to the page
pk_store:
	lda pk_n
	jsr pk_entry_a
	ldy #0
	lda pk_eblk
	sta (pk_ptr),y
	iny
	lda pk_eblk+1
	sta (pk_ptr),y
	ldx #0
:	iny
	lda pk_ename,x
	sta (pk_ptr),y
	inx
	cpx #16
	bne :-
	iny
	lda pk_etype
	sta (pk_ptr),y
	iny
	lda pk_elen
	sta (pk_ptr),y
	rts

; pk_ptr = entry pk_row (or A with pk_entry_a)
pk_entry:
	lda pk_row
pk_entry_a:
	ldx #<PK_BUF
	stx pk_ptr
	ldx #>PK_BUF
	stx pk_ptr+1
	tax
	beq @rts
:	lda pk_ptr
	clc
	adc #PK_ESIZE
	sta pk_ptr
	bcc :+
	inc pk_ptr+1
:	dex
	bne :--
@rts:	rts

;----------------------------------------------------------------------
; the whole page
pk_draw:
	lda #<txt_pk_title
	ldy #>txt_pk_title
	jsr outstr
	lda #0
	sta pk_i
:	lda pk_i
	jsr pk_line
	inc pk_i
	lda pk_i
	cmp pk_n
	bne :-
	bit pk_more
	bpl @rts
	ldx #PK_TOP+PK_PAGE
	ldy #7
	clc
	jsr plot
	lda #<txt_pk_more
	ldy #>txt_pk_more
	jmp outstr
@rts:	rts

; entry A on its row, reversed if it is pk_row
pk_line:
	sta pk_tmp
	clc
	adc #PK_TOP
	tax
	ldy #0
	clc
	jsr plot
	lda #WHITE
	jsr chrout
	lda pk_tmp
	cmp pk_row
	bne :+
	lda #RVSON
	jsr chrout
:	lda pk_tmp
	jsr pk_entry_a
	ldy #0		; blocks, 5 wide
	lda (pk_ptr),y
	sta pk_num
	iny
	lda (pk_ptr),y
	sta pk_num+1
	jsr pk_dec5
	lda #' '
	jsr chrout
	ldy #2
:	lda (pk_ptr),y
	cmp #$a0
	bne :+
	lda #' '
:	jsr chrout
	iny
	cpy #18
	bne :--
	lda #' '
	jsr chrout
	ldy #18
	lda (pk_ptr),y
	tax
	lda drtype,x
	jsr chrout
	lda drtyp2,x
	jsr chrout
	lda drtyp3,x
	jsr chrout
	lda #' '
	jsr chrout
	lda #RVSOFF
	jmp chrout

; pk_num as 5 digits, leading spaces
pk_dec5:
	lda #0
	sta pk_lead
	ldx #4
@dig:	ldy #'0'
@sub:	lda pk_num
	sec
	sbc pk_pow_lo,x
	pha
	lda pk_num+1
	sbc pk_pow_hi,x
	bcc @out
	sta pk_num+1
	pla
	sta pk_num
	iny
	bne @sub
@out:	pla
	tya
	cpx #0
	beq @put	; always the last digit
	cmp #'0'
	bne @put
	bit pk_lead
	bmi @put
	lda #' '
	bne @pr
@put:	pha
	lda #$80
	sta pk_lead
	pla
@pr:	jsr chrout
	dex
	bpl @dig
	rts
pk_pow_lo:
	.byte <1, <10, <100, <1000, <10000
pk_pow_hi:
	.byte >1, >10, >100, >1000, >10000

;----------------------------------------------------------------------
pk_type:	.byte 0
pk_first:	.word 0
pk_skip:	.word 0
pk_n:		.byte 0
pk_more:	.byte 0
pk_row:		.byte 0
pk_i:		.byte 0
pk_tmp:		.byte 0
pk_lead:	.byte 0
pk_num:		.word 0
pk_ptr:		.word 0	; (not zero page: used with (zp),y below)
pk_isent:	.byte 0
pk_eblk:	.word 0
pk_elen:	.byte 0
pk_etype:	.byte 0
pk_ename:	.res 16
