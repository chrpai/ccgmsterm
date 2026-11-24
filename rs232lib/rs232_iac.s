; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; Telnet IAC receive filter, shared by the drivers that talk to a raw
; TCP socket (the Ultimate's SwiftLink emulation and Ultimate Net)
;
; It also answers the server's option negotiation, so that a telnet
; server switches to 8-bit clean binary mode, without CR/NUL stuffing:
; BINARY and SGA are accepted both ways, ECHO from the server, and
; every other option is refused. iac_offer asks for BINARY and SGA.
;

.import sw_getraw, sw_put1

.export iac_setup, iac_setput, iac_offer, iac_get, iac_on, iac_state

IAC	= $ff
DONT	= $fe
DO	= $fd
WONT	= $fc
WILL	= $fb
SB	= $fa
SE	= $f0

OPT_BINARY	= 0
OPT_ECHO	= 1
OPT_SGA		= 3

; option bits in iac_we/iac_they
BIT_BINARY	= 1
BIT_SGA		= 2
BIT_ECHO	= 4
LOCAL_OK	= BIT_BINARY|BIT_SGA		; we agree to do these
REMOTE_OK	= BIT_BINARY|BIT_SGA|BIT_ECHO	; the server may do these

.segment "RS232"

;----------------------------------------------------------------------
; A: $80 = filter on, 0 = off
; X/Y: lo/hi of the driver's raw get routine (C=1: no data, else A = byte)
iac_setup:
	sta iac_on
	stx iac_raw+1
	sty iac_raw+2
	lda #0
	sta iac_state
	rts

;----------------------------------------------------------------------
; X/Y: lo/hi of the driver's raw put routine (A: byte, no $FF doubling)
iac_setput:
	stx iac_put+1
	sty iac_put+2
	rts

;----------------------------------------------------------------------
; on connect: offer BINARY and SGA both ways (if the filter is on)
iac_offer:
	lda #0
	sta iac_state
	sta iac_we
	sta iac_they
	bit iac_on
	bpl @rts
	lda #OPT_BINARY
	jsr @both
	lda #OPT_SGA
@both:	sta iac_opt
	jsr opt_bit
	pha
	ora iac_we
	sta iac_we
	pla
	ora iac_they
	sta iac_they
	lda #WILL
	jsr iac_send
	lda #DO
	jmp iac_send
@rts:	rts

;----------------------------------------------------------------------
; get byte, with telnet commands stripped from the input when on:
;   FF FF            -> one $FF data byte
;   FF FB..FE xx     -> (WILL/WONT/DO/DONT option) dropped
;   FF FA ... FF F0  -> (subnegotiation) dropped
;   FF xx            -> (any other command) dropped
iac_get:
	bit iac_on
	bmi @iac
	jmp iac_raw

@next:	sta iac_state
@iac:	jsr iac_raw
	bcs @rts	; no data
	ldx iac_state
	beq @s0
	dex
	beq @s1
	dex
	beq @s2
	dex
	beq @s3
; state 4: inside subnegotiation, after IAC
	cmp #$f0	; SE
	beq @to0
	lda #3		; anything else (incl. escaped $FF): still in SB
	bne @next
; state 3: inside subnegotiation
@s3:	cmp #$ff
	bne @iac
	lda #4
	bne @next
; state 2: option byte after WILL/WONT/DO/DONT
@s2:	sta iac_opt
	jsr iac_option
@to0:	lda #0
	beq @next
; state 1: after IAC
@s1:	cmp #$ff
	beq @data	; escaped $FF
	cmp #$fb
	bcs @opt	; WILL/WONT/DO/DONT
	cmp #$fa
	bne @to0	; other 2-byte command
	lda #3		; SB
	bne @next
@opt:	sta iac_cmd
	lda #2
	bne @next
; state 0: normal
@s0:	cmp #$ff
	bne @ok
	lda #1
	bne @next
@data:	ldx #0
	stx iac_state
@ok:	clc
@rts:	rts

; the driver's raw get
iac_raw:
	jmp sw_getraw	; patched by iac_setup

; the driver's raw put
iac_put:
	jmp sw_put1	; patched by iac_setput

;----------------------------------------------------------------------
; answer iac_cmd (DO/DONT/WILL/WONT) for option iac_opt
iac_option:
	jsr opt_bit
	sta iac_mask
	lda iac_cmd
	cmp #DO
	bne @nodo
; DO: server asks us to enable
	lda iac_mask
	and #LOCAL_OK
	beq @wont
	and iac_we
	bne @rts		; already on
	lda iac_mask
	ora iac_we
	sta iac_we
	lda #WILL
	bne iac_send
@wont:	lda #WONT
	bne iac_send
@nodo:	cmp #DONT
	bne @nodont
; DONT: server asks us to disable
	lda iac_mask
	and iac_we
	beq @rts		; already off
	eor iac_we
	sta iac_we
	lda #WONT
	bne iac_send
@nodont:
	cmp #WILL
	bne @wontc
; WILL: server offers to enable
	lda iac_mask
	and #REMOTE_OK
	beq @dont
	and iac_they
	bne @rts		; already on
	lda iac_mask
	ora iac_they
	sta iac_they
	lda #DO
	bne iac_send
@dont:	lda #DONT
	bne iac_send
; WONT: server disables
@wontc:	lda iac_mask
	and iac_they
	beq @rts		; already off
	eor iac_they
	sta iac_they
	lda #DONT
	bne iac_send
@rts:	rts

; send IAC, A, iac_opt
iac_send:
	pha
	lda #IAC
	jsr iac_put
	pla
	jsr iac_put
	lda iac_opt
	jmp iac_put

; A = option bit of iac_opt, 0 for any other option
opt_bit:
	lda iac_opt
	beq @bin
	cmp #OPT_SGA
	beq @sga
	cmp #OPT_ECHO
	beq @echo
	lda #0
	rts
@bin:	lda #BIT_BINARY
	rts
@sga:	lda #BIT_SGA
	rts
@echo:	lda #BIT_ECHO
	rts

;----------------------------------------------------------------------
; bit 7 set = active
iac_on:
	.byte 0
; receive state (0: data, 1: IAC, 2: option, 3: SB, 4: SB+IAC)
iac_state:
	.byte 0
iac_cmd:	.byte 0	; DO/DONT/WILL/WONT being received
iac_opt:	.byte 0
iac_mask:	.byte 0
iac_we:		.byte 0	; options we have on
iac_they:	.byte 0	; options the server has on
