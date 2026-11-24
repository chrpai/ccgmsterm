; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; Telnet IAC receive filter, shared by the drivers that talk to a raw
; TCP socket (the Ultimate's SwiftLink emulation and Ultimate Net)
;

.import sw_getraw

.export iac_setup, iac_get, iac_on, iac_state

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
@s2:
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
@opt:	lda #2
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

;----------------------------------------------------------------------
; bit 7 set = active
iac_on:
	.byte 0
; receive state (0: data, 1: IAC, 2: option, 3: SB, 4: SB+IAC)
iac_state:
	.byte 0
