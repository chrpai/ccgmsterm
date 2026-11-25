; CCGMS Terminal
;
; Copyright (c) 2016,2020, Craig Smith, alwyz. All rights reserved.
; This project is licensed under the BSD 3-Clause License.
;
; CCGMS Main Terminal Code
;

; enter here on program start
term_entry_first:
	jsr rs232_init
	jsr bell
	jsr themeroutine
	jsr term_mode_set	; terminal mode saved with the config

; enter here to print banner again
term_entry:
	bit col80_enabled
	bpl :+
	jsr col80_resume
:	jsr print_banner; title screen/CCGMS!
	jsr print_instr	; display commands f1 etc to terminal ready

; enter here to just return into terminal mode
term_mainloop:
	; turn on 80 col mode again (if requested)
	bit col80_active
	bmi :+		; screen model already enabled
	jsr col80_resume
:

	lda supercpu
	beq term_loop1
	cmp #2		; already printed once
	beq :+
	lda #<txt_supercpu_enabled
	ldy #>txt_supercpu_enabled
	jsr outstr
	lda #2
	sta supercpu
:	; supercpu = turn on 20mhz mode - for after all file transfer situations.
	; already on? turn on again. no biggie. save code.
	jsr supercpu_on

term_loop1:
; print tempbuf unless empty (see phonebook.s)
	lda bustemp
	beq term_skip
	ldy #1
:	lda tempbuf,y
	jsr chrout
	iny
	cpy bustemp
	bne :-
	ldy #0
	sty bustemp
term_skip:

	ldx #$ff
	txs

	; set keyboard matrix routine
	lda #<$eb48	; [XXX this is the KERNAL default; it is never changed]
	sta KEYLOG
	lda #>$eb48
	sta KEYLOG+1

	jsr clrchn
	lda #0
	sta rx_burst	; the cursor is shown from here on
	jsr cursor_show

;----------------------------------------------------------------------
; modem output
term_loop2:
	bit ansi80_active
	bpl :+
	jsr ansi80_tick	; ANSI 80: blinking text
:	lda buffer_ptr
	sta newbuf
	lda buffer_ptr+1
	sta newbuf+1

	jsr clrchn
	jsr getin	; get character from keyboard
	cmp #0
	jeq term_input_loop	; skip output code

.if 0	; [XXX I don't think this makes sense any more]
; cbm-ctrl-f: reset/init user port RS-232
	cmp #6		; ctrl-f
	bne term_no1
	ldx SHFLAG
	cpx #SHFLAG_CBM | SHFLAG_CTRL
	bne term_no1
	; cia2ddrb and cia2pb need to be here
	; for user port modem to function
	ldx #16
	stx cia2ddrb
	ldx #0
	stx cia2pb
	jmp term_loop2
term_no1
.endif

;	cmp #UNDERLINE
;	bne term_no2
;	ldx SHFLAG	; shift <- toggles
;	beq term_no4	; n/d cursor
;	cpx #SHFLAG_SHIFT
;	beq :+
;	lda allcap
;	eor #1
;	sta allcap
;	jmp term_loop2
;:	jmp toggle_cursor
;term_no2:

; shift-ctrl-[1..4]: swap screen
	ldx SHFLAG
	cpx #SHFLAG_SHIFT | SHFLAG_CTRL
	bcc term_no3
	ldx #3
:	cmp COLTAB,x	; PETSCII codes for ctrl-[1..4]
	beq :+
	dex
	bpl :-
	jmp term_input_loop
:	bit col80_active; unsupported in 80col mode
	bpl :+		; (screen storage already used by bitmap)
	jmp term_mainloop
:	jmp swap_screen	; x holds pos 0-3
term_no3:

; shift-stop: hang up
	cmp #$83
	bne term_no4
	ldx SHFLAG
	cpx #SHFLAG_CBM
	bne :+	; not C= Stop
	jsr cursor_off
	lda #<txt_disconnecting
	ldy #>txt_disconnecting
	jsr outstr
	jsr rs232_dropdtr
:	jmp term_mainloop
term_no4:

; f1..f8: functions
	cmp #133	; <= F1
	bcc term_no5
	cmp #140+1	; > F8
	bcs term_no5
	pha
	jsr set_bgcolor_0
	jsr cursor_off
	pla
	sec
	sbc #133	; F1
	sta tmp03
	asl tmp03
	clc
	adc tmp03
	sta term_bbcarg
	clc
term_bbcarg=*+1
	bcc *+2
	jmp handle_f1_upload
	jmp handle_f3_download
	jmp handle_f5_diskcommand
	jmp handle_f7_config
	jmp handle_f2_send_read
	jmp handle_f4_buffer
	jmp handle_f6_directory
	jmp handle_f8_switch_term
term_no5:

;	ldx allcap
;	beq term_upplow
;	ldx $d018
;	cpx #23
;	bne term_upplow
;	cmp #$41
;	bcc term_upplow
;	cmp #$5b  ;'z'+1
;	bcs term_upplow
;	ora #$80
;term_upplow:

; 80 column ANSI mode: keys go out as ASCII and ANSI sequences
	bit ansi80_active
	bpl :+
	jmp term_key_ansi
:

; ASCII conversion
	sta tmp03
	ldx ascii_mode
	beq :+
	jsr petscii_to_ascii
	bne :+
term_loop2b:
	jmp term_loop2
:

; send to modem
	jsr rs232_put

; convert back to PETSCII
	ldx ascii_mode
	beq :+
	jsr ascii_to_petscii
	sta tmp03
	jeq term_loop2
:

; half-duplex
	ldx half_duplex
	beq term_nohd
	jsr clrchn
	lda tmp03	; char
	ldx ascii_mode
	beq :+
	cmp #UNDERLINE	; [XXX no-op]
	bne :+			; [XXX no-op]
	lda #UNDERLINE
	sta tmp03	; _ in ascii/half dup
:	jmp term_bufchk	; skip modem input
term_nohd:

;----------------------------------------------------------------------
; modem input
term_input_loop:
	jsr clrchn

; macro printing
	ldx SHFLAG
	cpx #SHFLAG_CTRL; ctrl pressed
	bne :+
	ldx LSTX	; last keyboard scancode
	cpx #3		; 3-6 are F7/F1/F3/F5
	bcc :+		; [XXX this branches into code that checks X
	cpx #7		; [XXX thinking it's SHFLAG; it works by accident]
	bcs :+
	lda #0
	sta macro_dry_run_mode
	jsr print_macro
	jmp term_loop1
:

.if 0	; charset switching [XXX this has no effect ever]
	cpx #SHFLAG_SHIFT | SHFLAG_CBM
	bne :+
	ldx MODE	; charset switching allowed?
	bpl :+		; no
	ldx #$17
	stx $d018	; set lowercase charset
:
.endif

; modem input
	jsr rs232_get
	cmp #0
	beq term_loop2b	; = term_loop2
	ldx status
	bne term_loop2b	; = term_loop2
term_rx_char:	; contn2 comes back here with the next byte

.if AUTOMATION	; only enabled for automated tests
	cmp #3		; code 3 (STOP)
	bne term_nauto
	ldy #0
:	jsr rs232_get
	ldx status
	bne :-
	sta KEYD,y	; keyboard buffer
	iny
	cmp #3		; code 3 (STOP)
	bne :-
	sty NDX		; buffer count
	jmp term_rx_skip
term_nauto:
.endif

; 80 column ANSI mode: raw bytes go to the buffer and the ANSI parser
	bit ansi80_active
	bpl :+
	jmp term_rx_ansi
:

; ASCII conversion
	ldx ascii_mode
	beq :+
	jsr ascii_to_petscii
	beq term_rx_skip
:	cmp #DEL
	bne term_bufchk	; [XXX no-op]
	lda #$14	; [XXX no-op; was: $5F in Craig Smith source]
term_bufchk:
	jsr buffer_put
	jmp contn

; a received byte that doesn't get printed
term_rx_skip:
	lda rx_burst
	jeq term_input_loop	; cursor is shown, carry on as usual
	jmp term_mainloop; cursor is hidden: show it again

; [XXX this code is at a very awkward location, could be integrated better]
;<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
; store modem byte into buffer
buffer_put:
	; skip if closed
	ldx buffer_open
	beq @4
	; skip if full
	ldx buffer_ptr
	cpx bufend
	bne @1
	ldx buffer_ptr+1
	cpx bufend+1
	beq @4

@1:	ldy reu_enabled
	beq @2
	jsr reuwrite
	jmp @3

@2:	ldy #0
	sta (buffer_ptr),y
@3:	inc buffer_ptr
	bne @4
	inc buffer_ptr+1
@4:	rts
;>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

contn:
	jsr handle_control_codes
	bcc contn2
	jmp term_mainloop

; [XXX this code is at a very awkward location, could be integrated better]
;<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
; handle control codes sent from the BBS
handle_control_codes:
	cmp #$16+1	; nothing below needs a printable char
	bcs @8
	cmp #$0a	; ctrl-j: cursor on
	beq @1
	cmp #$0b	; ctrl-k: cursor off
	bne @2

@1:
	ldx ascii_mode
	bne @2
	pha
	lda rx_burst	; cursor hidden while printing a burst
	bne :+
	jsr cursor_off
:	pla
	and #1		; form to ch flag
	eor #1
	sta cursor_flag
	sec
	rts

@2:
	cmp #$0e	; ctrl-n: reset background to black
	bne @3

	pha
	jsr set_bgcolor_0
	pla

@3:
	cmp #$07	; ctrl-g: bell sound from bbs side
	bne @4

	jsr bell

@4:
	cmp #$16	; ctrl-v: end of file transfer or boomy sound
	bne @5

	jsr gong

@5:
;	cmp #$15	; ctrl-u: uppercase from bbs side
;	bne @6

;	ldx #$15
;	stx $d018
;	bne ctrlex

;@6:
;	cmp #$0c	; ctrl-l: lowercase from bbs side
;	bne @7

;	ldx #$17
;	stx $d018
;	bne ctrlex

;@7:
;	cmp #$5f	; false del
;	bne @8		; (buff and 1/2 duplx)

;	lda #DEL
;	bne ctrlex

@8:
	ldx prev_char
	cpx #$02	; ctrl-b: set background color
	bne @9

	ldx #15
:	cmp COLTAB,x	; check ctrl+[1-8], cbm+[1-8]
	beq :+
	dex
	bpl :-
	bmi @9
:	txa
	jsr set_bgcolor
	lda #$10	; ctrl-p: non printable
@9:
	sta prev_char
	clc
	rts
;>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

contn2:
	pha
	lda rx_burst	; cursor already hidden?
	bne :+
	jsr cursor_off
:	pla
	jsr fast_chrout	; print input byte to screen
contn3:
	lda #0		; kill modes the char might have enabled
	sta qmode	; (quote_insert_off)
	sta imode

; While more bytes are waiting, print them without going through the main
; loop: drawing and erasing the cursor, CLRCHN and GETIN for every byte cost
; more than printing it. The cursor comes back when the data pauses, a key
; is pressed or a modifier key is held. The destructive cursor (ctrl-k)
; keeps the old path, since erasing it also blanks the character under it.
	lda cursor_flag
	beq @show
	lda NDX		; keys waiting?
	ora SHFLAG	; shift/C=/ctrl held (macros, hangup, screen swap)?
	bne @show
	jsr rs232_get
	cmp #0
	beq @show
	ldx status
	bne @show	; same as the main loop: drop it
	ldx #1
	stx rx_burst
	jmp term_rx_char
@show:	jmp term_mainloop

rx_burst:
	.byte 0		; 1: printing a burst, cursor not drawn

;----------------------------------------------------------------------
; 80 column ANSI mode (ansi80.s)

; received byte
term_rx_ansi:
	ldx buffer_open
	beq :+
	stx buffer_ansi	; the buffer now holds raw ANSI
	jsr ansi_buffer_put
:	pha
	lda rx_burst	; cursor already hidden?
	bne :+
	jsr cursor_off
:	pla
	jsr ansi80_putc
	jmp contn3

; key pressed
term_key_ansi:
	jsr ansi80_key	; returns the byte to echo, if any
	beq :+
	ldx half_duplex
	beq :+
	pha
	jsr cursor_off
	pla
	ldx buffer_open
	beq @1
	stx buffer_ansi
	jsr ansi_buffer_put
@1:	jsr ansi80_putc
	jmp term_mainloop
:	jmp term_loop2

ansi_buffer_put:
	sta tmp03
	jsr buffer_put
	lda tmp03
	rts

