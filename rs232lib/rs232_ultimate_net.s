; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; Ultimate Net driver: TCP through the network stack of the Ultimate
; (1541 Ultimate-II/II+, Ultimate 64, C64 Ultimate), using the network
; target of the Ultimate Command Interface (UCI). There is no ACIA and
; no baud rate; the Ultimate does DNS, TCP and buffering.
;
; A small Hayes command emulator stands in for the modem, so the dialer
; and the phonebook work unchanged:
;   ATD[T|P]["]host[:port]	connect (port defaults to 23);
;				answers CONNECT or NO CARRIER
;   ATI				ULTIMATE-NET MODEM EMULATOR, MADE BY CHRIS PAINTER
;   ATE0 / ATE1			command echo off/on
;   ATH, ATZ, AT...		OK
; While connected, all bytes go to the socket. Hang up (drop DTR) closes
; it; when the remote side closes, NO CARRIER is sent to the terminal.
;
; See the "UCI Network Target" document in the 1541ultimate repository.
;

.include "rs232_kernal.inc"
.import ribuf			; external: 256 byte receive buffer
.import telnet_iac		; config: 1 = telnet IAC handling wanted
.import is_ultimate		; runtime: 1 = Ultimate (UCI) detected
.import iac_setup, iac_get, iac_on

.export net_funcs
.export net_detect, net_available

; UCI registers
UCI_CONTROL	= $df1c	; write: control
UCI_STATUS	= $df1c	; read: status
UCI_CMD		= $df1d	; write: command data
UCI_RESP	= $df1e	; read: response data
UCI_STATDATA	= $df1f	; read: status data ("00,OK")

UCI_PUSH_CMD	= %00000001
UCI_DATA_ACC	= %00000010
UCI_ABORT	= %00000100
UCI_CLR_ERR	= %00001000

UCI_ST_DATA_AV	= %10000000
UCI_ST_STAT_AV	= %01000000
UCI_ST_STATE	= %00110000	; 00 idle, 01 busy, 10 data last, 11 data more
UCI_ST_BUSY	= %00010000
UCI_ST_ERROR	= %00001000

; network target
NET_TARGET	= $03
NET_IDENTIFY	= $01
NET_OPEN_TCP	= $07
NET_CLOSE	= $09
NET_READ	= $10
NET_WRITE	= $11

STKEY		= $91	; $7F while STOP is pressed
NMINV		= $0318
KERNAL_NMI	= $fe47

CR		= $0d
LF		= $0a

TXBUF_SIZE	= 128
CMDBUF_SIZE	= 64
RESPBUF_SIZE	= 16
READ_MARGIN	= 16	; ribuf room kept free for NO CARRIER
READ_MAX	= 255-READ_MARGIN

.segment "RS232"

;----------------------------------------------------------------------
net_funcs:
	.word net_setup
	.word net_rts		; enable
	.word net_rts		; disable
	.word iac_get
	.word net_putxfer
	.word net_dropdtr

;----------------------------------------------------------------------
; A: modem_type, X: baud_rate, Y: is_pal_system (all unused)
; The connection is kept: the dialer and the F7 menu init the driver
; again while it may be online.
net_setup:
	sei
	lda #<KERNAL_NMI	; no NMIs from us; drop the SwiftLink handler
	sta NMINV
	lda #>KERNAL_NMI
	sta NMINV+1
	cli
	lda #0
	ldy telnet_iac
	beq :+
	lda #$80
:	ldx #<net_getraw
	ldy #>net_getraw
	jmp iac_setup

net_rts:
	rts

;----------------------------------------------------------------------
; Detect the UCI network target; sets net_available to 1 if present.
; Called once at startup, after ultimate_detect.
net_detect:
	lda #0
	sta net_available
	lda is_ultimate
	beq @rts
	jsr uci_begin
	lda #NET_IDENTIFY
	jsr uci_exec_cmd
	bne @rts
	lda #1
	sta net_available
@rts:	rts

;======================================================================
; receive

;----------------------------------------------------------------------
; raw get (the IAC filter calls this): C=1 no data, else A = byte
; The fast path only takes a byte from ribuf; the connection is serviced
; when ribuf is empty, and every 32 bytes so that typed bytes go out
; while a BBS keeps the buffer full.
net_getraw:
	ldx rhead
	cpx rtail
	beq @poll
	dec net_tick
	bne @have
@poll:	lda #32
	sta net_tick
	jsr net_poll
	ldx rhead
	cpx rtail
	beq @none
@have:	lda ribuf,x
	inc rhead
	dec rfree
	clc
	rts
@none:	sec
	rts

;----------------------------------------------------------------------
; Move the connection along without waiting: pick up a finished read,
; send what is queued, and start the next read.
net_poll:
	bit net_online
	bpl @rts
	lda net_pend
	beq @idle
	lda UCI_STATUS
	and #UCI_ST_STATE
	cmp #UCI_ST_BUSY
	beq @rts		; read still running
	jsr net_collect
	bit net_online
	bpl @rts
@idle:	lda txlen
	beq @read
	jsr net_flush
	bit net_online
	bpl @rts
@read:	lda #READ_MAX
	sec
	sbc rfree
	bcc @rts
	cmp #READ_MARGIN
	bcc @rts		; buffer (almost) full: TCP holds the remote back
	pha
	jsr uci_begin
	lda #NET_READ
	sta UCI_CMD
	lda net_sock
	sta UCI_CMD
	pla
	sta UCI_CMD		; length lo
	lda #0
	sta UCI_CMD		; length hi
	lda #UCI_PUSH_CMD
	sta UCI_CONTROL
	lda #1
	sta net_pend
@rts:	rts

;----------------------------------------------------------------------
; wait for a running read and pick it up
net_wait_read:
	lda net_pend
	beq @rts
:	lda UCI_STATUS
	and #UCI_ST_STATE
	cmp #UCI_ST_BUSY
	beq :-
	jmp net_collect
@rts:	rts

;----------------------------------------------------------------------
; read finished: copy its payload into ribuf
; reply: 2 byte count, then data; status 00 = data, 02 = no data,
; anything else (01 = closed by host) = connection lost
net_collect:
	lda #0
	sta net_pend
	ldx #2			; skip the 2 byte count
@hdr:	bit UCI_STATUS
	bpl @stat
	lda UCI_RESP
	dex
	bne @hdr
; the payload fits: the read asked for no more than ribuf has room for
	ldy rtail
@data:	bit UCI_STATUS
	bpl @end
	lda UCI_RESP
	sta ribuf,y
	iny
	inx
	bne @data
@end:	sty rtail
	txa
	clc
	adc rfree
	sta rfree
@stat:	jsr uci_finish
	beq @rts		; 00,OK
	lda uci_stat
	cmp #'0'
	bne @lost
	lda uci_stat+1
	cmp #'2'		; 02,NO DATA
	beq @rts
@lost:	jmp net_lost
@rts:	rts

;======================================================================
; send

;----------------------------------------------------------------------
; put byte; A, X and Y are preserved
net_putxfer:
	sta net_a
	txa
	pha
	tya
	pha
	lda net_a
	bit net_online
	bmi @data
	jsr at_char
	jmp @out
@data:	jsr tx_add
	cmp #$ff		; telnet: $FF data byte is sent as $FF $FF
	bne @out
	bit iac_on
	bpl @out
	jsr tx_add
@out:	pla
	tay
	pla
	tax
	lda net_a
	clc
	rts

; queue a byte; send the queue when full
tx_add:
	ldx txlen
	sta txbuf,x
	inx
	stx txlen
	cpx #TXBUF_SIZE
	bne @rts
	jsr net_flush
	lda net_a
@rts:	rts

;----------------------------------------------------------------------
; send the queue
net_flush:
	jsr net_wait_read
	bit net_online
	bpl @drop
	jsr uci_begin
	lda #NET_WRITE
	sta UCI_CMD
	lda net_sock
	sta UCI_CMD
	ldx #0
:	lda txbuf,x
	sta UCI_CMD
	inx
	cpx txlen
	bne :-
	jsr uci_exec
	beq @drop
	jsr net_lost
@drop:	lda #0
	sta txlen
	rts

;======================================================================
; connection

;----------------------------------------------------------------------
; hang up
net_dropdtr:
	bit net_online
	bpl @rts
	jsr net_wait_read
	bit net_online
	bpl @rts
	jmp net_lost
@rts:	rts

;----------------------------------------------------------------------
; close the socket, back to command mode, and tell the terminal
net_lost:
	lda #0
	sta net_online
	sta net_pend
	sta txlen
	jsr uci_begin
	lda #NET_CLOSE
	sta UCI_CMD
	lda net_sock
	sta UCI_CMD
	jsr uci_exec		; (a socket the host closed is gone already)
	ldx #txt_nocarrier-txt
	jmp emit

;----------------------------------------------------------------------
; open the connection to hostbuf:net_port
net_open:
	jsr uci_begin
	lda #NET_OPEN_TCP
	sta UCI_CMD
	lda net_port
	sta UCI_CMD
	lda net_port+1
	sta UCI_CMD
	ldx #0
:	lda hostbuf,x
	sta UCI_CMD
	beq :+
	inx
	bne :-
:	lda #$80		; DNS and connect can take a while: STOP aborts
	sta uci_stop
	jsr uci_exec
	bne @fail
	lda resplen
	beq @fail
	lda respbuf
	sta net_sock
	lda #0
	sta net_pend
	sta txlen
	lda #$80
	sta net_online
	ldx #txt_connect-txt
	jmp emit
@fail:	ldx #txt_nocarrier-txt
	jmp emit

;======================================================================
; Hayes command emulation (command mode)

;----------------------------------------------------------------------
; A: byte from the terminal
at_char:
	pha
	jsr at_upper
	cmp #CR
	beq @line
	cmp #$14		; PETSCII DEL
	beq @del
	cmp #$08		; ASCII BS
	beq @del
	cmp #' '
	bcc @nostore		; other control codes (LF etc.)
	ldx cmdlen
	cpx #CMDBUF_SIZE-1
	bcs @nostore
	sta cmdbuf,x
	inc cmdlen
	bne @nostore
@del:	lda cmdlen
	beq @nostore
	dec cmdlen
@nostore:
	pla
	bit at_echo
	bpl @rts
	jmp emit_byte
@rts:	rts

@line:	pla
	bit at_echo
	bpl :+
	jsr emit_byte
:	ldx cmdlen
	lda #0
	sta cmdbuf,x
	sta cmdlen
	sta at_info
	lda cmdbuf
	cmp #'A'
	bne @rts		; not a command
	lda cmdbuf+1
	cmp #'T'
	bne @rts
	ldx #2
@cmd:	lda cmdbuf,x
	beq @done
	inx
	cmp #'D'
	beq at_dial
	cmp #'I'
	bne :+
	lda #1
	sta at_info
	bne @cmd
:	cmp #'E'
	bne @cmd
	lda cmdbuf,x
	cmp #'0'
	beq @e0
	cmp #'1'
	bne @cmd
	lda #$80
	bne @e1
@e0:	lda #0
@e1:	sta at_echo
	inx
	bne @cmd
@done:	lda at_info
	beq :+
	jsr at_ident
:	ldx #txt_ok-txt
	jmp emit

;----------------------------------------------------------------------
; ATD: X points behind the "D"
at_dial:
; skip one dial modifier (T/P), and the quote ZiModem style dialing adds
	lda cmdbuf,x
	cmp #'T'
	beq @skip
	cmp #'P'
	bne @sp
@skip:	inx
@sp:	lda cmdbuf,x
	cmp #'"'
	beq :+
	cmp #' '
	bne @host
:	inx
	bne @sp
; copy the host name, in lower case
@host:	ldy #0
@hloop:	lda cmdbuf,x
	beq @hend
	cmp #'"'
	beq @hend
	cmp #':'
	beq @hend
	cmp #'A'
	bcc :+
	cmp #'Z'+1
	bcs :+
	ora #$20		; to lower case ASCII
:	sta hostbuf,y
	iny
	inx
	bne @hloop
@hend:
; trailing spaces off
:	dey
	bmi @nohost
	lda hostbuf,y
	cmp #' '
	beq :-
	iny
	lda #0
	sta hostbuf,y
; port: digits after ":", default 23
	lda #23
	sta net_port
	lda #0
	sta net_port+1
	lda cmdbuf,x
	cmp #':'
	bne @open
	inx
	lda cmdbuf,x
	jsr at_digit
	bcs @open		; no digits: default
	lda #0
	sta net_port
@ploop:	lda cmdbuf,x
	jsr at_digit
	bcs @open
	pha
	; port = port * 10 + digit
	lda net_port
	ldy net_port+1
	asl net_port
	rol net_port+1		; *2
	asl net_port
	rol net_port+1		; *4
	clc
	adc net_port
	sta net_port
	tya
	adc net_port+1
	sta net_port+1		; *5
	asl net_port
	rol net_port+1		; *10
	pla
	clc
	adc net_port
	sta net_port
	bcc :+
	inc net_port+1
:	inx
	bne @ploop
@open:	jmp net_open
@nohost:
	ldx #txt_nocarrier-txt
	jmp emit

; C=0 and A = value if A is a digit
at_digit:
	sec
	sbc #'0'
	cmp #10
	rts

; upper case, PETSCII or ASCII
at_upper:
	cmp #$c1		; PETSCII shifted letters
	bcc :+
	cmp #$db
	bcs @rts
	and #$7f
	rts
:	cmp #'a'		; ASCII lower case
	bcc @rts
	cmp #'z'+1
	bcs @rts
	and #$df
@rts:	rts

;----------------------------------------------------------------------
; ATI: identification
at_ident:
	ldx #txt_ident-txt
	jmp emit

;======================================================================
; UCI

;----------------------------------------------------------------------
; get the interface ready and send the target byte
; (a read of ours that is still running must have been picked up)
uci_begin:
	lda UCI_STATUS
	and #UCI_ST_ERROR
	beq :+
	lda #UCI_CLR_ERR
	sta UCI_CONTROL
:	lda UCI_STATUS
	and #UCI_ST_STATE
	beq @idle
	cmp #UCI_ST_BUSY
	beq :-
	lda #UCI_DATA_ACC	; a reply nobody took
	sta UCI_CONTROL
	bne :-
@idle:	lda #NET_TARGET
	sta UCI_CMD
	rts

;----------------------------------------------------------------------
; send command byte A, then as uci_exec
uci_exec_cmd:
	sta UCI_CMD
; push the command, wait for it, keep up to RESPBUF_SIZE reply bytes
; Z=1: status 00,OK
uci_exec:
	lda #UCI_PUSH_CMD
	sta UCI_CONTROL
@wait:	lda UCI_STATUS
	and #UCI_ST_STATE
	cmp #UCI_ST_BUSY
	bne @done
	bit uci_stop
	bpl @wait
	lda STKEY
	cmp #$7f
	bne @wait
	lda #UCI_ABORT
	sta UCI_CONTROL
	ldx #0
	ldy #0
:	lda UCI_STATUS		; wait for idle, with a timeout
	and #UCI_ST_STATE
	beq :+
	dex
	bne :-
	dey
	bne :-
:	lda #0
	sta uci_stop
	sta resplen
	lda #'9'		; not OK
	sta uci_stat
	rts
@done:	lda #0
	sta uci_stop
	ldx #0
@data:	bit UCI_STATUS
	bpl @end
	lda UCI_RESP
	cpx #RESPBUF_SIZE
	bcs @data
	sta respbuf,x
	inx
	bne @data
@end:	stx resplen
; read the status, acknowledge; Z=1: status 00,OK
uci_finish:
	lda #0
	sta uci_stat
	sta uci_stat+1
	ldx #0
@stat:	bit UCI_STATUS
	bvc @send
	lda UCI_STATDATA
	cpx #2
	bcs :+
	sta uci_stat,x
:	inx
	bne @stat
@send:	lda #UCI_DATA_ACC
	sta UCI_CONTROL
:	lda UCI_STATUS
	and #UCI_DATA_ACC
	bne :-
	lda uci_stat
	cmp #'0'
	bne :+
	lda uci_stat+1
	cmp #'0'
:	rts

;======================================================================
; responses into the receive buffer

; X: offset of a zero-terminated text in txt
emit:
	lda txt,x
	beq @rts
	jsr emit_byte
	inx
	bne emit
@rts:	rts

; A: byte; dropped if the buffer is full
emit_byte:
	ldy rfree
	cpy #$ff
	beq :+
	ldy rtail
	sta ribuf,y
	inc rtail
	inc rfree
:	rts

txt:
txt_ok:
	.byte CR,LF,"OK",CR,LF,0
txt_connect:
	.byte CR,LF,"CONNECT",CR,LF,0
txt_nocarrier:
	.byte CR,LF,"NO CARRIER",CR,LF,0
txt_ident:
	.byte CR,LF,"ULTIMATE-NET MODEM EMULATOR",CR,LF
	.byte "MADE BY CHRIS PAINTER",CR,LF,0

;----------------------------------------------------------------------
net_available:	.byte 0	; 1: the UCI network target answered
net_online:	.byte 0	; bit 7: connected
net_pend:	.byte 0	; 1: a READ is running
net_tick:	.byte 1	; bytes until the connection is serviced
net_sock:	.byte 0
net_port:	.word 0
net_a:		.byte 0
txlen:		.byte 0
cmdlen:		.byte 0
at_echo:	.byte $80	; bit 7: echo commands
at_info:	.byte 0
uci_stop:	.byte 0	; bit 7: STOP aborts the command
uci_stat:	.byte 0,0
resplen:	.byte 0
respbuf:	.res RESPBUF_SIZE
txbuf:		.res TXBUF_SIZE
cmdbuf:		.res CMDBUF_SIZE
hostbuf:	.res CMDBUF_SIZE
