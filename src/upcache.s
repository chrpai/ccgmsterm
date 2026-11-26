; CCGMS Terminal
;
; Upload cache: with an REU, a Punter upload reads the whole file into
; REU banks 1 and up before the transfer starts, and then takes its
; blocks from there.
;
; Why: on the C64U (hyperkernal, Ultimate Net at 64 MHz) a disk read that
; follows network traffic, with a pause, times out (ST 66). Reading the
; file straight through works. Without an REU, or if the file doesn't
; fit, the upload reads the disk as before.

UPC_BOUNCE	= xmodem_buffer	; 256 bytes, unused by a Punter upload

;----------------------------------------------------------------------
; LFN_FILE is open for reading. C=0: the file is in the REU (upc_on)
upc_fill:
	lda #0
	sta upc_on
	lda reu_enabled
	beq @no
	jsr upc_size
	lda upc_banks
	beq @no
	jsr rs232_off
	lda #0
	sta upc_len
	sta upc_len+1
	sta upc_len+2
	ldx #LFN_FILE
	jsr chkin
	bcs @fail
	lda #0
	sta status
@blk:	ldy #0
@byte:	jsr chrin
	sta UPC_BOUNCE,y
	iny
	jsr readst
	bne @last
	tya
	bne @byte
	jsr @stash	; Y = 0: 256 bytes
	bcc @blk
	bcs @fail	; too big for the REU
@last:	and #$ff-$40	; anything but EOI: a read error
	bne @fail
	jsr @stash
	bcs @fail
	jsr clrchn
	lda #0
	sta upc_pos
	sta upc_pos+1
	sta upc_pos+2
	sta upc_st
	lda #$80
	sta upc_on
	clc
	rts
@fail:	jsr clrchn
	lda #LFN_FILE	; open it again: the disk path reads it from the start
	jsr close
	jsr filtes
@no:	sec
	rts

; stash Y bytes (0: 256) at upc_len, add them; C=1: no room
@stash:	lda upc_len+2
	cmp upc_banks	; bank = 1 + upc_len+2 must be <= upc_banks
	bcs @full
	lda #<UPC_BOUNCE
	sta upc_c
	lda #>UPC_BOUNCE
	sta upc_c+1
	lda upc_len
	sta upc_r
	lda upc_len+1
	sta upc_r+1
	ldx upc_len+2
	inx
	stx upc_r+2
	sty upc_l	; 0 -> 256
	lda #0
	cpy #0
	bne :+
	lda #1
:	sta upc_l+1
	lda #$b0	; C64 -> REU
	jsr upc_dma
	lda upc_len	; len += count
	clc
	adc upc_l
	sta upc_len
	lda upc_len+1
	adc upc_l+1
	sta upc_len+1
	bcc :+
	inc upc_len+2
:	clc
	rts
@full:	sec
	rts

;----------------------------------------------------------------------
; drop-in for CHKIN/CHRIN/READST on LFN_FILE in the upload
upc_chkin:
	bit upc_on
	bmi :+
	ldx #LFN_FILE
	jmp chkin
:	clc
	rts

upc_chrin:
	bit upc_on
	bpl @disk
	lda upc_pos	; at the end: like the KERNAL, CR and an error
	cmp upc_len
	bne @get
	lda upc_pos+1
	cmp upc_len+1
	bne @get
	lda upc_pos+2
	cmp upc_len+2
	bne @get
	lda #$42
	sta upc_st
	lda #CR
	rts
@disk:	jmp chrin
@get:	tya
	pha
	txa
	pha
	lda #<upc_byte
	sta upc_c
	lda #>upc_byte
	sta upc_c+1
	lda upc_pos
	sta upc_r
	lda upc_pos+1
	sta upc_r+1
	ldx upc_pos+2
	inx
	stx upc_r+2
	lda #1
	sta upc_l
	lda #0
	sta upc_l+1
	lda #$b1	; REU -> C64
	jsr upc_dma
	inc upc_pos
	bne :+
	inc upc_pos+1
	bne :+
	inc upc_pos+2
:	lda #0		; EOI with the last byte
	ldx upc_pos
	cpx upc_len
	bne :+
	ldx upc_pos+1
	cpx upc_len+1
	bne :+
	ldx upc_pos+2
	cpx upc_len+2
	bne :+
	lda #$40
:	sta upc_st
	pla
	tax
	pla
	tay
	lda upc_byte
	rts

upc_readst:
	bit upc_on
	bmi :+
	jmp readst
:	lda upc_st
	rts

;----------------------------------------------------------------------
; REU DMA: C64 upc_c, REU upc_r (3 bytes), length upc_l; A = command
upc_dma:
	pha
	lda upc_c
	sta $df02
	lda upc_c+1
	sta $df03
	lda upc_r
	sta $df04
	lda upc_r+1
	sta $df05
	lda upc_r+2
	sta $df06
	lda upc_l
	sta $df07
	lda upc_l+1
	sta $df08
	lda #0
	sta $df0a
	pla
	sta $df01
	rts

; upc_banks = REU banks after bank 0 (the size is a power of 2; a
; write to bank "size" wraps to bank 0)
upc_size:
	lda #$ff
	sta upc_r
	sta upc_r+1
	lda #0
	sta upc_r+2
	lda #<upc_save
	sta upc_c
	lda #>upc_save
	sta upc_c+1
	lda #1
	sta upc_l
	lda #0
	sta upc_l+1
	lda #$b1	; keep bank 0's $FFFF (the buffer may use it)
	jsr upc_dma
	lda #<upc_byte
	sta upc_c
	lda #>upc_byte
	sta upc_c+1
	lda #1
	sta upc_p
@try:	lda #$55	; bank 0 := $55
	sta upc_byte
	lda #0
	sta upc_r+2
	lda #$b0
	jsr upc_dma
	lda #$aa	; bank p := $AA
	sta upc_byte
	lda upc_p
	sta upc_r+2
	lda #$b0
	jsr upc_dma
	lda #0		; bank 0 still $55?
	sta upc_r+2
	lda #$b1
	jsr upc_dma
	lda upc_byte
	cmp #$aa
	beq @wrap
	asl upc_p
	bne @try
	lda #255	; 16 MB
	bne @set
@wrap:	ldx upc_p	; size: p banks
	dex
	txa
@set:	sta upc_banks
	lda #<upc_save	; bank 0's $FFFF back
	sta upc_c
	lda #>upc_save
	sta upc_c+1
	lda #0
	sta upc_r+2
	lda #$b0
	jmp upc_dma

upc_on:		.byte 0	; bit 7: reading from the REU
upc_banks:	.byte 0
upc_len:	.res 3
upc_pos:	.res 3
upc_st:		.byte 0
upc_byte:	.byte 0
upc_save:	.byte 0
upc_p:		.byte 0
upc_c:		.res 2
upc_r:		.res 3
upc_l:		.res 2
