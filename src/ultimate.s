; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; Ultimate (1541U-II/II+, Ultimate 64, C64 Ultimate) detection
; through the Ultimate Command Interface (UCI)
;
; The Command Interface has to be enabled in the Ultimate menu.
; See https://1541u-documentation.readthedocs.io/en/latest/uci/core_uci_architecture.html
;

UCI_CONTROL	= $df1c	; write: control, read: status
UCI_STATUS	= $df1c
UCI_CMD		= $df1d	; write: command data, read: identification
UCI_IDENT	= $df1d
UCI_RESP	= $df1e	; response data
UCI_STATDATA	= $df1f	; status data ("00,OK")

UCI_ID		= $c9	; $49 if the IRQ bit is active (fw 3.15+)

UCI_PUSH_CMD	= %00000001
UCI_DATA_ACC	= %00000010
UCI_ABORT	= %00000100
UCI_CLR_ERR	= %00001000

UCI_ST_DATA_AV	= %10000000
UCI_ST_STAT_AV	= %01000000
UCI_ST_STATE	= %00110000	; 00 idle, 01 busy, 10 data last, 11 data more

UCI_TARGET_CTRL	= $04
CTRL_CMD_GET_HWINFO = $28

;----------------------------------------------------------------------
; Detect an Ultimate and read its model name.
; Sets is_ultimate to 1 and fills ultimate_model (zero-terminated ASCII)
; if the device answers CTRL_CMD_GET_HWINFO with an OK status.
ultimate_detect:
	lda #0
	sta is_ultimate
	sta ultimate_model

	lda UCI_IDENT
	and #$7f
	cmp #UCI_ID & $7f
	beq :+
	rts		; no UCI
:

	; if the interface is not idle, abort whatever is going on
	lda UCI_STATUS
	and #UCI_ST_STATE
	beq @idle
	lda #UCI_ABORT|UCI_CLR_ERR
	sta UCI_CONTROL
	jsr uci_wait_idle
	bcs @rts	; still busy: give up
@idle:

	; send CTRL_CMD_GET_HWINFO, sub-command 0 (model name)
	lda #UCI_TARGET_CTRL
	sta UCI_CMD
	lda #CTRL_CMD_GET_HWINFO
	sta UCI_CMD
	lda #0
	sta UCI_CMD
	lda #UCI_PUSH_CMD
	sta UCI_CONTROL

	; wait for "data last"/"data more"
	ldx #0
	ldy #0
@wait:	lda UCI_STATUS
	and #UCI_ST_STATE
	cmp #%00100000
	bcs @done
	dex
	bne @wait
	dey
	bne @wait
	beq @rts	; timeout
@done:

	; read the model name
	ldx #0
@data:	lda UCI_STATUS
	bpl @data_end	; no more data
	lda UCI_RESP
	cpx #ULTIMATE_MODEL_LEN-1
	bcs @data
	sta ultimate_model,x
	inx
	bne @data
@data_end:
	lda #0
	sta ultimate_model,x

	; read the status: "00,OK" means success
	ldx #0
@stat:	bit UCI_STATUS
	bvc @stat_end
	lda UCI_STATDATA
	cpx #2
	bcs :+
	sta uci_status,x
:	inx
	bne @stat
@stat_end:

	lda #UCI_DATA_ACC
	sta UCI_CONTROL

	cpx #2
	bcc @rts	; no status
	lda uci_status
	ora uci_status+1
	cmp #'0'	; both '0' ($30)?
	bne @rts
	lda uci_status
	and uci_status+1
	cmp #'0'
	bne @rts
	lda #1
	sta is_ultimate
@rts:	rts

;----------------------------------------------------------------------
; wait until the UCI state machine is idle
; C=1: timeout
uci_wait_idle:
	ldx #0
	ldy #0
:	lda UCI_STATUS
	and #UCI_ST_STATE
	beq :+
	dex
	bne :-
	dey
	bne :-
	sec
	rts
:	clc
	rts

;----------------------------------------------------------------------
; 1: running on an Ultimate with the Command Interface enabled
is_ultimate:
	.byte 0

uci_status:
	.byte 0,0

; model name as reported by the Ultimate, e.g. "ULTIMATE 64" (ASCII)
ULTIMATE_MODEL_LEN = 32
ultimate_model:
	.res ULTIMATE_MODEL_LEN,0
