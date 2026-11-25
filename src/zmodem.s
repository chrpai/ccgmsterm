; CCGMS Terminal
;
; This project is licensed under the BSD 3-Clause License.
;
; ZMODEM send and receive
;
; Written from Chuck Forsberg's protocol description ("The ZMODEM Inter
; Application File Transfer Protocol", 1988).
;
; * batch receive and send, file names from the sender
; * CRC-16 and CRC-32 data, the sender picks (we always offer CRC-32)
; * crash recovery: a download whose file already exists and is shorter
;   than the offered size is continued where it stopped
; * streaming: no per-block waits where the modem driver can hold the
;   sender back while we write to disk (Ultimate Net: TCP, SwiftLink:
;   RTS); otherwise we ask for an ACK every buffer (ZCRCW/ZCRCQ)
; * auto-start: "**",ZDLE,"B00" (ZRQINIT) received in terminal mode
;
; Memory, while a transfer runs:
;   $C800-$CBFF	data buffer (receive: 1 KB, send: 768 bytes below mulfil)
;   $0400-$05FF	CRC-32 table bytes 0 and 1 (screen rows 0-12, hidden)
;   $CC00-$CDFF	CRC-32 table bytes 2 and 3, or the CRC-16 table
;		(crclo/crchi); rebuilt when the sender switches CRCs
; Header CRCs are computed bit by bit and need no table.
;

; frame format
ZPAD	= '*'
ZDLE	= $18
ZBIN	= 'A'
ZHEX	= 'B'
ZBIN32	= 'C'

; frame types
ZRQINIT	= 0
ZRINIT	= 1
ZSINIT	= 2
ZACK	= 3
ZFILE	= 4
ZSKIP	= 5
ZNAK	= 6
ZABORT	= 7
ZFIN	= 8
ZRPOS	= 9
ZDATA	= 10
ZEOF	= 11
ZFERR	= 12
ZCRC	= 13
ZCHALLENGE = 14
ZCOMPL	= 15
ZCAN	= 16
ZFREECNT = 17
ZCOMMAND = 18

; ZDLE sequences
ZCRCE	= 'h'	; end of frame, header follows
ZCRCG	= 'i'	; frame continues, no reply
ZCRCQ	= 'j'	; frame continues, ZACK expected
ZCRCW	= 'k'	; end of frame, ZACK expected
ZRUB0	= 'l'	; $7F
ZRUB1	= 'm'	; $FF

; ZRINIT flags (ZF0)
CANFDX	= $01
CANOVIO	= $02
CANFC32	= $20
ESCCTL	= $40

; ZFILE conversion option (ZF0)
ZCBIN	= 1

XON	= $11
ZM_BS	= $08

ZM_BUF		= xmodem_buffer	; $C800
ZM_BUF_END	= ZM_BUF+1024	; receive: one 1 KB subpacket
ZM_TXBLK	= 768		; send: subpacket size (mulfil is at $CB00)
ZM_T0		= $0400		; CRC-32 table, byte 0 (LSB)
ZM_T1		= $0500
ZM_T2		= crclo
ZM_T3		= crchi

ZM_TRIES	= 10		; failed headers in a row before giving up
ZM_TIMEOUT	= 10*60		; jiffies
ZM_GARBAGE	= 16384		; bytes without a header before we ask again

zm_ptr	= $fb	; (locat, saved and restored)
ZM_ERRMSG	= inpbuf+$30	; drive status text

; screen rows
ZM_ROW_TITLE	= 14
ZM_ROW_FILE	= 16
ZM_ROW_BYTES	= 17
ZM_ROW_ERRORS	= 18
ZM_ROW_MSG	= 20
ZM_ROW_ABORT	= 22

; ZRINIT buffer size with flow control (SwiftLink, Ultimate Net), in
; bytes, a multiple of 256; 0: the sender may stream the whole file
.ifndef ZM_RXWIN
ZM_RXWIN	= 0
.endif
; ZM_DEBUG=1: log the last 38 headers at $033C-$03FB (the tape buffer
; and the UP9600 table: not for UP9600) and show them on exit
.ifndef ZM_DEBUG
ZM_DEBUG	= 0
.endif
ZM_PROBE	= 7
.ifndef ZM_SA_RD
ZM_SA_RD	= 2	; secondary address for reading a file to send
.endif	; mulfil type byte: find the type when opening
ST_RDTMO	= $02	; STATUS: read timeout
ZM_RDTRY	= 8	; zs_read: give up after this many timeouts in a row
.ifndef ZM_TEST_TMO
ZM_TEST_TMO	= 0	; 1: fake a timeout at the start of every read but the
.endif			; first, before any byte moves (tests the retry);
			; 2: on every try (tests giving up)

.segment "ZMODEM"	; runs with the BASIC ROM banked out (see below)

;======================================================================
; entry points

;----------------------------------------------------------------------
; ZRQINIT seen in terminal mode (terminal.s); A, X free
zm_auto:
	lda rx_burst	; cursor still drawn?
	bne :+
	jsr cursor_off
:	jsr col80_pause
	jsr text_color_save
	jsr supercpu_off
;----------------------------------------------------------------------
; F3 / C= F3 (the caller has paused 80 columns and saved the color)
zm_download:
	lda #$80
	jsr zm_begin
	tsx
	stx zm_sp
	jmp zr_start

;----------------------------------------------------------------------
; F1: inpbuf/max hold the name the user typed. The type is found when
; the file is opened (F1's own test of ",P"/",S"/",U" with secondary
; address 0 fails on the Ultimate's software IEC).
zm_upload_single:
	jsr zm_dsk_on
	lda #LFN_FILE
	jsr close
	jsr clrchn
	ldx #0
	txa
:	sta mulfil,x	; one entry in the multi-send format
	inx
	bne :-
	ldx #15
	lda #$a0
:	sta mulfil+2,x
	dex
	bpl :-
	ldx max
	cpx #17
	bcc @cp
	ldx #16
@cp:	dex
	bmi @type
	lda inpbuf,x
	sta mulfil+2,x
	jmp @cp
@type:	lda #ZM_PROBE	; type unknown: zs_open finds it
	sta mulfil+18
	lda #$80
	sta mulfil+19
	lda #1
	sta mulfln
;----------------------------------------------------------------------
; C= F1: mulfil holds the files picked by select_files_from_disk,
; mulfln their number
zm_upload_multi:
	lda mulfln
	bne :+
	jmp zm_leave_entry
:	lda #0
	jsr zm_begin
	tsx
	stx zm_sp
	jmp zs_start


;----------------------------------------------------------------------
; A: 0 upload, $80 download
zm_begin:
	sta zm_dir
	lda zm_ptr
	sta zm_zpsave
	lda zm_ptr+1
	sta zm_zpsave+1
	ldx #zm_vars_end-zm_vars
	lda #0
:	sta zm_vars-1,x
	dex
	bne :-
	lda #2
	sta zm_sa
	lda #<ZM_TIMEOUT
	sta zm_tmo
	lda #>ZM_TIMEOUT
	sta zm_tmo+1

	; Can the driver hold the sender back while we write to disk?
	; SwiftLink: RTS (the NMI keeps receiving), Ultimate Net: TCP.
	lda modem_type
	cmp #MODEM_TYPE_SWIFTLINK_DE
	ror zm_ovio	; bit 7: yes

	jsr zm_dsk_on
.if ZM_DEBUG
	jsr zm_dclr
.endif
	jsr zm_screen
	jsr zm_mktab32	; usual case first, before data arrives
	lda #2
	sta zm_tabs
	jsr ercopn	; command channel
	jsr clrchn
	jmp rs232_on

;----------------------------------------------------------------------
zm_screen:
	lda #CLR
	jsr chrout
	lda backgr	; rows 0-12 hold the CRC table: hide it
	ldx #0
:	sta $d800,x
	sta $d900,x
	inx
	bne :-
	ldx #13
	ldy #0
	jsr zm_at
	lda #6
	sta textcl
	ldx #40
	lda #192	; "─"
:	jsr chrout
	dex
	bne :-
	ldx #ZM_ROW_TITLE
	ldy #2
	jsr zm_at
	lda #<zt_title_up
	ldy #>zt_title_up
	ldx zm_dir
	beq :+
	lda #<zt_title_down
	ldy #>zt_title_down
:	jsr outstr
	ldx #ZM_ROW_FILE
	ldy #2
	jsr zm_at
	lda #<zt_labels
	ldy #>zt_labels
	jsr outstr
	ldx #ZM_ROW_ABORT
	ldy #2
	jsr zm_at
	lda #<zt_abort
	ldy #>zt_abort
	jsr outstr
	jsr zm_show_bytes
	jmp zm_show_errors

;======================================================================
; RECEIVE

zr_start:
	lda #<zt_waiting
	ldy #>zt_waiting
	jsr zm_msg
zr_init:
	jsr zm_send_zrinit
zr_hdr:
	jsr zm_gethdr
	bcc zr_got
	; timeout or too much garbage
	jsr zm_try
	lda zm_fopen
	beq zr_init
	jsr zm_send_zrpos
	jmp zr_hdr

zr_got:
	cmp #ZRQINIT
	beq zr_init
	cmp #ZFILE
	jeq zr_file
	cmp #ZDATA
	jeq zr_data
	cmp #ZEOF
	jeq zr_eof
	cmp #ZSINIT
	beq zr_sinit
	cmp #ZFIN
	beq zr_fin
	cmp #ZFREECNT
	beq zr_freecnt
	cmp #ZCOMMAND
	beq zr_command
	cmp #ZABORT
	beq :+
	cmp #ZCAN
	beq :+
	cmp #ZFERR
	bne zr_hdr
:	jmp zm_remote_cancel

;----------------------------------------------------------------------
zr_sinit:
	jsr zm_rx_begin
	jsr zm_rdsub	; the attention string; we have no use for it
	bcs zr_nak
	jsr zm_clrtxh
	inc zm_txh+1	; ZACK 1
	lda #ZACK
	jsr zm_shex
	jmp zr_hdr

zr_nak:
	jsr zm_count_error
	jsr zm_clrtxh
	lda #ZNAK
	jsr zm_shex
	jmp zr_hdr

;----------------------------------------------------------------------
zr_freecnt:
	ldx #3
	lda #$ff	; no idea how much is free: say "a lot"
:	sta zm_txh+1,x
	dex
	bpl :-
	lda #ZACK
	jsr zm_shex
	jmp zr_hdr

;----------------------------------------------------------------------
; we don't run commands
zr_command:
	jsr zm_rx_begin
	jsr zm_rdsub
	bcs zr_nak
	jsr zm_clrtxh
	inc zm_txh+1	; exit status 1
	lda #ZCOMPL
	jsr zm_shex
	jmp zr_hdr

;----------------------------------------------------------------------
; end of session
zr_fin:
	jsr zm_fclose
	jsr zm_clrtxh
	lda #ZFIN
	jsr zm_shex
	lda #60		; "OO" from the sender, if it comes
	sta zm_tmo
	lda #0
	sta zm_tmo+1
	jsr zm_getb
	bcs :+
	jsr zm_getb
:	jmp zm_ok

;----------------------------------------------------------------------
zr_file:
	jsr zm_fclose	; (a file left open by a broken transfer)
	jsr zm_rx_begin
	jsr zm_rdsub
	bcs zr_nak
	ldx zm_ptr+1	; a NUL behind the data, for the parser
	cpx #>ZM_BUF_END
	beq :+
	ldy #0
	tya
	sta (zm_ptr),y
:	jsr zm_parse_info
	jsr zm_show_name
	jsr zm_open_rx
	bcs @skip
	inc zm_files
	lda #<zt_receiving
	ldy #>zt_receiving
	ldx zm_resumed
	beq :+
	lda #<zt_resuming
	ldy #>zt_resuming
:	jsr zm_msg
	jsr zm_show_bytes
	lda #0
	sta zm_tries
	jsr zm_send_zrpos
	jmp zr_hdr
@skip:	lda #<zt_cant_create
	ldy #>zt_cant_create
	jsr zm_msg
	jsr zm_clrtxh
	lda #ZSKIP
	jsr zm_shex
	jmp zr_hdr

;----------------------------------------------------------------------
zr_eof:
	lda zm_fopen
	beq @next
	jsr zm_hdr_is_pos	; all data there?
	jne zr_hdr	; no: ignore it, the sender will go on
	jsr zm_flush
	jsr zm_dsk_on
	jsr zm_dskchk	; disk full?
	jcs zm_disk_fail
	jsr zm_fclose
	lda #<zt_file_done
	ldy #>zt_file_done
	jsr zm_msg
@next:	jmp zr_init

;----------------------------------------------------------------------
zr_data:
	lda zm_fopen
	jeq zr_hdr
	jsr zm_hdr_is_pos
	beq :+
	jsr zm_count_error	; not where we are: ask again
	jsr zm_send_zrpos
	jmp zr_hdr
:	jsr zm_rx_begin
zr_sub:
	jsr zm_rdsub
	bcs zr_suberr
	pha
	; commit the subpacket
	lda zm_fill
	clc
	adc zm_n
	sta zm_fill
	lda zm_fill+1
	adc zm_n+1
	sta zm_fill+1
	lda zm_pos
	clc
	adc zm_n
	sta zm_pos
	lda zm_pos+1
	adc zm_n+1
	sta zm_pos+1
	bcc :+
	inc zm_pos+2
	bne :+
	inc zm_pos+3
:	lda #0
	sta zm_tries
	jsr zm_show_bytes
	jsr zm_check_abort
	pla
	cmp #ZCRCG
	bne @notg
	bit zm_ovio	; no flow control: keep it, the sender won't wait
	bpl zr_sub
	jsr zm_flush
	jmp zr_sub
@notg:	cmp #ZCRCE
	beq @e
	; ZCRCQ/ZCRCW: with flow control, answer first, so the sender's
	; turnaround overlaps our disk write (flow control holds what comes
	; meanwhile). Without it, nothing may come in while we write.
	bit zm_ovio
	bpl @late
	pha
	jsr zm_send_zack
	jsr zm_flush
	pla
	jmp @next
@late:	pha
	jsr zm_flush
	jsr zm_send_zack
	pla
@next:	cmp #ZCRCQ
	jeq zr_sub
	jmp zr_hdr	; ZCRCW
@e:	jsr zm_flush
	jmp zr_hdr

zr_suberr:
	jsr zm_count_error
	jsr zm_flush	; keep the good part
	jsr zm_send_zrpos
	jmp zr_hdr

;----------------------------------------------------------------------
zm_send_zrinit:
	jsr zm_clrtxh
	; Buffer size: ZCRCW after every KB, please. Without flow control
	; we can't receive while writing. With flow control, a sender that
	; streams can run far ahead (TCP buffers), and while a slow drive
	; catches up, it times out waiting for our answer to ZEOF.
	lda #CANFDX | CANFC32
	ldx #>1024
	bit zm_ovio
	bpl :+
	ora #CANOVIO
	ldx #>ZM_RXWIN
:	stx zm_txh+2
	sta zm_txh+4	; ZF0
	lda #ZRINIT
	jmp zm_shex

zm_send_zrpos:
	jsr zm_pos2txh
	lda #ZRPOS
	jmp zm_shex

zm_send_zack:
	jsr zm_pos2txh
	lda #ZACK
	jmp zm_shex

;----------------------------------------------------------------------
; Z=1 if the position in the received header is zm_pos
zm_hdr_is_pos:
	ldx #3
:	lda zm_hdr+1,x
	cmp zm_pos,x
	bne :+
	dex
	bpl :-
	lda #0
:	rts

;----------------------------------------------------------------------
; start reading data subpackets for the header just received
zm_rx_begin:
	lda #0
	sta zm_fill
	sta zm_fill+1
	jmp zm_setcrc

;----------------------------------------------------------------------
; Read a data subpacket into the buffer behind the zm_fill bytes kept.
; out: C=0: A = frame end (ZCRCE/G/Q/W), zm_n = data length
;      C=1: bad CRC, timeout, overflow or bad escape
zm_rdsub:
	lda #<ZM_BUF
	clc
	adc zm_fill
	sta zm_ptr
	sta zm_start
	lda #>ZM_BUF
	adc zm_fill+1
	sta zm_ptr+1
	sta zm_start+1
	jsr zm_dcrc_init
@loop:	jsr zdl_get
	bcs @end
	ldx zm_ptr+1
	cpx #>ZM_BUF_END
	beq @err	; overflow
	ldy #0
	sta (zm_ptr),y
	jsr zm_dcrc
	inc zm_ptr
	bne @loop
	inc zm_ptr+1
	bne @loop
@end:	cpx #0
	bne @err	; timeout or bad escape
	sta zm_fend
	jsr zm_dcrc
	lda #2
	bit zm_d32
	bpl :+
	lda #4
:	sta zm_cnt
:	jsr zdl_get
	bcs @err
	jsr zm_dcrc
	dec zm_cnt
	bne :-
	jsr zm_dcrc_check
	bne @err
	lda zm_ptr
	sec
	sbc zm_start
	sta zm_n
	lda zm_ptr+1
	sbc zm_start+1
	sta zm_n+1
	lda zm_fend
	clc
	rts
@err:	sec
	rts

;----------------------------------------------------------------------
; write the buffer to the file
zm_flush:
	lda zm_fill
	ora zm_fill+1
	beq @rts
	jsr zm_dsk_on
	ldx #LFN_FILE
	jsr chkout
	lda #<ZM_BUF
	sta zm_ptr
	lda #>ZM_BUF
	sta zm_ptr+1
	ldx zm_fill+1	; full pages
	ldy #0
	cpx #0
	beq @last
:	lda (zm_ptr),y
	jsr chrout
	iny
	bne :-
	inc zm_ptr+1
	dex
	bne :-
@last:	cpy zm_fill
	beq :+
	lda (zm_ptr),y
	jsr chrout
	iny
	bne @last
:	jsr clrchn
	jsr zm_is_swift	; (reading the drive while bytes stream in
	bcs :+		; could miss bits: SwiftLink checks at the end)
	jsr zm_dskchk
	jcs zm_disk_fail
:	jsr zm_dsk_off
	lda #0
	sta zm_fill
	sta zm_fill+1
@rts:	rts

; Disk access while receiving. Ultimate Net must have no read running,
; so the driver is disabled. A SwiftLink stays on: its NMI keeps
; receiving and the driver drops RTS when the buffer fills, so data
; streams on while we write. (A 6551 whose receive interrupt was off
; while bytes came in holds a stale byte, and the byte after it can get
; lost.) Writing is safe with NMIs, because the C64 clocks the bits;
; reads from the drive happen only while the sender waits for us.
; Sending reads the file with the driver off (see zs_read).
zm_dsk_on:
	jsr zm_is_swift
	bcc :+
	rts
:	jmp rs232_off

zm_dsk_off:
	jsr zm_is_swift
	bcc :+
	rts
:	jmp rs232_on

; C=1 for the SwiftLink types
zm_is_swift:
	lda modem_type
	cmp #MODEM_TYPE_SWIFTLINK_DE
	bcc :+
	cmp #MODEM_TYPE_ULTIMATE_NET
	bcs :+
	sec
	rts
:	clc
	rts

;----------------------------------------------------------------------
zm_fclose:
	lda zm_fopen
	beq @rts
	jsr zm_flush
	jsr zm_dsk_on
	lda #LFN_FILE
	jsr close
	jsr clrchn
	lda #0
	sta zm_fopen
	jsr zm_dsk_off
@rts:	rts

;----------------------------------------------------------------------
; parse the ZFILE subpacket: "name",0,"size ..."
zm_parse_info:
	ldy #0
	sty zm_nstart
	sty zm_ftype	; 0: SEQ
	ldx #3
	lda #0
:	sta zm_size,x
	dex
	bpl :-
@scan:	lda ZM_BUF,y
	beq @end
	cmp #'/'	; strip directories
	beq :+
	cmp #'\'
	bne @next
:	iny
	sty zm_nstart
	dey
@next:	iny
	cpy #200
	bne @scan
@end:	sty zm_nend
	; .prg and .d64 are saved as PRG, everything else as SEQ
	tya
	sec
	sbc zm_nstart
	cmp #4
	bcc @conv
	ldx #0
	jsr @ext
	beq @isprg
	ldx #4
	jsr @ext
	bne @conv
@isprg:	lda #1
	sta zm_ftype
	bne @conv
; Z=1 if the name ends in the extension at zm_exts+X
@ext:	lda zm_nend
	sec
	sbc #4
	tay
	lda #4
	sta zm_cnt
:	lda ZM_BUF,y
	ora #$20
	cmp zm_exts,x
	bne :+
	iny
	inx
	dec zm_cnt
	bne :-
:	rts
@conv:	; ASCII to PETSCII, 16 characters at most
	ldy zm_nstart
	ldx #0
@cl:	cpy zm_nend
	beq @cend
	lda ZM_BUF,y
	stx zm_tmpx
	jsr zm_a2p
	ldx zm_tmpx
	sta zm_name,x
	iny
	inx
	cpx #16
	bne @cl
@cend:	cpx #0
	bne :+
	ldx #3		; no name at all
	lda #'F'
	sta zm_name
	lda #'I'
	sta zm_name+1
	lda #'L'
	sta zm_name+2
	lda #'E'
	sta zm_name+3
:	stx zm_nlen
	stx zm_blen	; zm_base: the name before any numbering
:	lda zm_name,x
	sta zm_base,x
	dex
	bpl :-
	; size
	ldy zm_nend
	cpy #200
	beq @rts
@sz:	iny
	lda ZM_BUF,y
	cmp #' '
	beq @sz		; leading blanks
@dig:	sec
	sbc #'0'
	cmp #10
	bcs @rts
	pha
	jsr zm_size_x10
	pla
	clc
	adc zm_size
	sta zm_size
	bcc :+
	inc zm_size+1
	bne :+
	inc zm_size+2
	bne :+
	inc zm_size+3
:	iny
	lda ZM_BUF,y
	jmp @dig
@rts:	rts

zm_exts:
	.byte ".prg.d64"

zm_size_x10:
	ldx #3
:	lda zm_size,x
	sta zm_tmp,x
	dex
	bpl :-
	jsr @x2		; x4
	jsr @x2
	ldx #0
	clc
:	lda zm_size,x	; x5 (keeps Y)
	adc zm_tmp,x
	sta zm_size,x
	inx
	txa
	eor #4
	bne :-
@x2:	asl zm_size
	rol zm_size+1
	rol zm_size+2
	rol zm_size+3
	rts

;----------------------------------------------------------------------
; ASCII to PETSCII for a file name
zm_a2p:
	cmp #'a'
	bcc @1
	cmp #'z'+1
	bcs @bad
	sbc #$1f	; (C=0) a-z -> $41-$5A
	rts
@1:	cmp #'A'
	bcc @2
	cmp #'Z'+1
	bcs @3
	ora #$80	; A-Z -> $C1-$DA
	rts
@3:	cmp #'_'
	bne @bad
	lda #UNDERLINE
	rts
@2:	cmp #' '
	bcc @bad
	ldx #zm_badch_end-zm_badch-1
:	cmp zm_badch,x
	beq @bad
	dex
	bpl :-
	rts
@bad:	lda #'-'
	rts

zm_badch:
	.byte ",:*?=",'"',"@"
zm_badch_end:

;----------------------------------------------------------------------
; Open the file for a download. Continue an existing shorter file if the
; sender told us the size, else pick a free name by adding "-1", "-2"...
; C=1: no file
zm_open_rx:
	lda #0
	sta zm_resumed
	ldx #3
:	sta zm_pos,x
	dex
	bpl :-
	jsr zm_dsk_on
	jsr zm_exists
	bcs @new
	; it exists: continue it?
	lda zm_size
	ora zm_size+1
	ora zm_size+2
	ora zm_size+3
	beq @number	; size unknown
	lda #<zt_checking
	ldy #>zt_checking
	jsr zm_msg
	jsr zm_length	; zm_have
	jsr zm_dsk_on
	lda zm_have	; have < size?
	cmp zm_size
	lda zm_have+1
	sbc zm_size+1
	lda zm_have+2
	sbc zm_size+2
	lda zm_have+3
	sbc zm_size+3
	bcs @number
	lda #'A'
	jsr zm_open
	bcs @number
	ldx #3
:	lda zm_have,x
	sta zm_pos,x
	dex
	bpl :-
	inc zm_resumed
	bne @ok
@number:
	lda #0
	sta zm_numb
@nloop:	inc zm_numb
	lda zm_numb
	cmp #100
	bcs @fail
	jsr zm_numbered
	jsr zm_exists
	bcc @nloop
@new:	lda #'W'
	jsr zm_open
	bcs @fail
@ok:	jsr zm_show_name
	jsr zm_dsk_off
	clc
	rts
@fail:	jsr zm_dsk_off
	sec
	rts

; zm_name = zm_base, cut to fit, + "-" + zm_numb
zm_numbered:
	ldx #2		; length of "-n"
	lda zm_numb
	cmp #10
	bcc :+
	inx
:	stx zm_tmp
	lda #16
	sec
	sbc zm_tmp
	cmp zm_blen
	bcc :+
	lda zm_blen
:	tax
	lda #'-'
	sta zm_name,x
	inx
	lda zm_numb
	ldy #'0'-1
	sec
:	iny
	sbc #10
	bcs :-
	adc #10+'0'
	cpy #'0'
	beq :+
	pha
	tya
	sta zm_name,x
	inx
	pla
:	sta zm_name,x
	inx
	stx zm_nlen
	rts

; zm_name in inpbuf, X = its length
zm_name2inp:
	ldx #0
:	cpx zm_nlen
	beq :+
	lda zm_name,x
	sta inpbuf,x
	inx
	bne :-
:	rts

; C=0 if a file called zm_name exists (any type; anything but
; "62 FILE NOT FOUND" counts, so an unclosed file is never overwritten)
zm_exists:
	jsr zm_name2inp
	jsr zm_openinp
	php
	jsr zm_closef
	plp
	beq @yes
	lda ZM_ERRMSG
	cmp #'6'
	bne @yes
	lda ZM_ERRMSG+1
	cmp #'2'
	bne @yes
	sec
	rts
@yes:	clc
	rts

zm_closef:
	lda #LFN_FILE
	jmp close

; open inpbuf (X chars) as LFN_FILE and read the drive status;
; Z=1 if it is "00". The file stays open either way.
zm_openinp:
	txa
	ldx #<inpbuf
	ldy #>inpbuf
	jsr setnam
	lda #LFN_FILE
	ldx device_disk
	ldy zm_sa
	jsr setlfs
	jsr open
; read the whole drive status into ZM_ERRMSG; Z=1 if it is "00"
zm_readerr:
	ldx #LFN_DISK_CMD
	jsr chkin
	lda #0		; STATUS may be stale (rs232_get sets it)
	sta status
	lda #0
	sta zm_i
@l:	jsr getin
	cmp #CR
	beq @end
	ldx zm_i
	sta ZM_ERRMSG,x
	inc zm_i
	lda status
	bne @end
	cpx #38
	bcc @l
@end:	ldx zm_i
	lda #0
	sta ZM_ERRMSG,x
	jsr clrchn
	lda ZM_ERRMSG
	cmp #'0'
	bne :+
	lda ZM_ERRMSG+1
	cmp #'0'
:	rts

; C=1 if the drive reports an error (code 20 and up)
zm_dskchk:
	jsr zm_readerr
	lda ZM_ERRMSG
	cmp #'2'
	rts

; a write failed: tell the sender and stop
zm_disk_fail:
	jsr rs232_on
	jsr zm_clrtxh
	lda #ZFERR
	jsr zm_shex
	jsr zm_canit
	lda #<ZM_ERRMSG
	ldy #>ZM_ERRMSG
	jmp zm_fail

; zm_have = length of the existing file zm_name
zm_length:
	ldx #3
	lda #0
:	sta zm_have,x
	dex
	bpl :-
	jsr zm_name2inp
	jsr zm_openinp
	bne @done
	ldx #LFN_FILE
	jsr chkin
	lda #0		; STATUS may be stale (rs232_get sets it)
	sta status
@loop:	jsr getin
	inc zm_have
	bne :+
	inc zm_have+1
	bne :+
	inc zm_have+2
	bne :+
	inc zm_have+3
:	lda status
	beq @loop
@done:	jsr clrchn
	lda #LFN_FILE
	jmp close

; open zm_name for writing; A: 'W' write or 'A' append; C=1 on error
zm_open:
	pha
	jsr zm_name2inp
	lda #','
	sta inpbuf,x
	inx
	lda #'S'
	ldy zm_ftype
	beq :+
	lda #'P'
:	sta inpbuf,x
	inx
	lda #','
	sta inpbuf,x
	inx
	pla
	sta inpbuf,x
	inx
	jsr zm_openinp
	bne @err
	lda #1
	sta zm_fopen
	clc
	rts
@err:	jsr zm_closef
	sec
	rts

;======================================================================
; SEND

zs_start:
	lda #<zt_waiting_rx
	ldy #>zt_waiting_rx
	jsr zm_msg
@rq:	jsr zm_clrtxh
	lda #ZRQINIT
	jsr zm_shex
@wait:	jsr zm_gethdr
	bcc :+
	jsr zm_try
	jmp @rq
:	cmp #ZRINIT
	beq @init
	cmp #ZCHALLENGE
	bne :+
	ldx #3
@ch:	lda zm_hdr+1,x
	sta zm_txh+1,x
	dex
	bpl @ch
	lda #ZACK
	jsr zm_shex
	jmp @wait
:	cmp #ZABORT
	beq :+
	cmp #ZCAN
	bne @wait
:	jmp zm_remote_cancel

@init:	lda #0
	sta zm_tries
	jsr zs_rinit
	; files
	lda #<mulfil
	sta zm_entry
	lda #>mulfil
	sta zm_entry+1
@file:	lda zm_files
	cmp mulfln
	beq @fin
	lda zm_entry+1
	cmp #>endmulfil
	bcs @fin
	jsr zs_file
	inc zm_files
	lda zm_entry
	clc
	adc #20
	sta zm_entry
	bcc @file
	inc zm_entry+1
	bne @file

@fin:	lda #<zt_finishing
	ldy #>zt_finishing
	jsr zm_msg
	lda #0
	sta zm_tries
@zfin:	jsr zm_clrtxh
	lda #ZFIN
	jsr zm_shex
	jsr zm_gethdr
	bcc :+
	inc zm_tries	; no answer: we're done anyway
	lda zm_tries
	cmp #3
	bcc @zfin
	bcs @oo
:	cmp #ZFIN
	bne @zfin
@oo:	lda #'O'
	jsr rs232_put
	lda #'O'
	jsr rs232_put
	jmp zm_ok

;----------------------------------------------------------------------
; the receiver's ZRINIT
zs_rinit:
	lda zm_hdr+4	; ZF0
	sta zm_rflags
	and #ESCCTL
	beq :+
	lda #$80
:	sta zm_escctl
	lda zm_rflags
	and #CANFC32
	beq :+
	lda #ZBIN32
	sta zm_fmt
	lda #$80
	sta zm_t32
	bne :++
:	lda #ZBIN
	sta zm_fmt
	lda #0
	sta zm_t32
:	jsr zm_setcrc
	; receive buffer size
	lda zm_hdr+1
	sta zm_rbl
	lda zm_hdr+2
	sta zm_rbl+1
	lda #<ZM_TXBLK
	sta zm_blk
	lda #>ZM_TXBLK
	sta zm_blk+1
	lda zm_rbl
	ora zm_rbl+1
	beq :+
	lda zm_rbl	; buffer smaller than our subpackets?
	cmp #<ZM_TXBLK
	lda zm_rbl+1
	sbc #>ZM_TXBLK
	bcs :+
	lda zm_rbl
	sta zm_blk
	lda zm_rbl+1
	sta zm_blk+1
:	rts

;----------------------------------------------------------------------
; send the file of the mulfil entry at zm_entry
zs_file:
	lda zm_entry
	sta zm_ptr
	lda zm_entry+1
	sta zm_ptr+1
	ldy #18
	lda (zm_ptr),y
	and #7
	sta zm_ftype	; directory type: 1 SEQ, 2 PRG, 3 USR
	beq @rts
	cmp #ZM_PROBE
	beq @ok
	cmp #4
	bcs @rts	; no DEL or REL files
@ok:	ldy #17
@trim:	lda (zm_ptr),y	; name without the $A0 padding
	cmp #$a0
	bne @len
	dey
	cpy #1
	bne @trim
@rts:	rts
@len:	dey		; Y: 2..17 -> length 1..16
	sty zm_nlen
	ldx #0
	ldy #2
@cp:	lda (zm_ptr),y
	sta zm_name,x
	iny
	inx
	cpx zm_nlen
	bne @cp
	jsr zm_show_name
	ldx #3
	lda #0
:	sta zm_pos,x
	dex
	bpl :-
	jsr zm_show_bytes
	jsr zs_open
	bcc :+
	jmp zm_cant_open
:	jsr zs_info
	lda #<zt_offering
	ldy #>zt_offering
	jsr zm_msg
	lda #0
	sta zm_tries
@zfile:	jsr zm_clrtxh
	lda #ZCBIN
	sta zm_txh+4	; ZF0: binary
	lda #ZFILE
	jsr zm_sbin
	lda #<ZM_BUF
	sta zm_ptr
	lda #>ZM_BUF
	sta zm_ptr+1
	lda zm_info
	sta zm_n
	lda #0
	sta zm_n+1
	lda #ZCRCW
	jsr zm_sdata
@wait:	jsr zm_gethdr
	bcc :+
	jsr zm_try
	jmp @zfile
:	cmp #ZRPOS
	beq @data
	cmp #ZRINIT
	beq @again
	cmp #ZNAK
	beq @again
	cmp #ZSKIP
	beq @skip
	cmp #ZABORT
	beq :+
	cmp #ZFERR
	beq :+
	cmp #ZCAN
	bne @wait
:	jmp zm_remote_cancel
@again:	jsr zm_try
	jmp @zfile
@skip:	lda #<zt_skipped
	ldy #>zt_skipped
	jsr zm_msg
	jmp zs_close
@data:	jsr zm_hdr2pos
	lda #0		; nothing buffered yet
	sta zm_blen
	sta zm_blen+1
	ldx #3
:	sta zm_bpos,x
	dex
	bpl :-
	lda #<zt_sending
	ldy #>zt_sending
	ldx zm_pos
	beq :+
	lda #<zt_sending_from
	ldy #>zt_sending_from
:	jsr zm_msg
	jmp zs_data

;----------------------------------------------------------------------
; The ZFILE subpacket in ZM_BUF: the name in ASCII, NUL, NUL.
; PRG files without an extension get ".prg", so that they come back as
; PRG files.
zs_info:
	ldx #0
	stx zm_tmp	; 1: name has a "."
@l:	lda zm_name,x
	cmp #'.'
	bne :+
	inc zm_tmp
:	jsr zm_p2a
	sta ZM_BUF,x
	inx
	cpx zm_nlen
	bne @l
	lda zm_ftype
	cmp #2		; PRG
	bne @nul
	lda zm_tmp
	bne @nul
	ldy #0
:	lda zm_dot_prg,y
	sta ZM_BUF,x
	inx
	iny
	cpy #4
	bne :-
@nul:	lda #0
	sta ZM_BUF,x
	inx
	sta ZM_BUF,x
	inx
	stx zm_info
	rts

zm_dot_prg:
	.byte ".prg"

; PETSCII to ASCII for a file name
zm_p2a:
	cmp #$41
	bcc @1
	cmp #$5b
	bcs @2
	ora #$20	; $41-$5A -> a-z
	rts
@2:	cmp #$c1
	bcc @bad
	cmp #$db
	bcs @bad
	and #$7f	; $C1-$DA -> A-Z
	rts
@1:	cmp #$21
	bcs @rts	; ! to @ stay
@bad:	lda #'_'
@rts:	rts

;----------------------------------------------------------------------
; open zm_name for reading as LFN_FILE; C=1 on error
; zm_ftype ZM_PROBE: try PRG, SEQ, USR, then the name alone (sent as
; SEQ); zm_ftype is then the type found
zs_open:
	lda zm_ftype
	cmp #ZM_PROBE
	bne zs_open1
	ldx #3
@try:	lda @types,x
	sta zm_ftype
	stx zm_tmpx
	jsr zs_open1
	bcc @rts
	ldx zm_tmpx
	dex
	bpl @try
@rts:	rts
@types:	.byte $81,3,1,2	; (reversed) $81: no type in the name

zs_open1:
	lda #ZM_SA_RD
	sta zm_sa
	jsr rs232_off	; reading: see zs_read
	jsr zm_name2inp
	ldy zm_ftype
	bmi :+
	lda #','
	sta inpbuf,x
	inx
	lda drtype,y
	sta inpbuf,x
	inx
:		; "NAME,T" reads, like F1's own test; the
	jsr zm_openinp	; ("NAME,T,R" may fail on some drives)
	php
	ldx #2
	stx zm_sa
	plp
	php
	beq :+
	jsr zm_closef
	jmp :++
:	inc zm_fopen
:
	jsr rs232_on
	lda #0
	sta zm_eof
	plp
	beq :+
	sec
	rts
:	clc
	rts

zs_close:
	lda zm_fopen
	beq :+
	jsr rs232_off	; reading: see zs_read
	lda #LFN_FILE
	jsr close
	jsr clrchn
	lda #0
	sta zm_fopen
	jsr rs232_on
:	rts

;----------------------------------------------------------------------
; send from zm_pos on
zs_data:
	jsr zs_seek
	jsr zm_pos2txh
	lda #ZDATA
	jsr zm_sbin
	lda #0
	sta zm_since
	sta zm_since+1
@sub:	jsr zs_fill	; zm_ptr/zm_n: the next subpacket
	lda #ZCRCE
	bit zm_last	; the end of the file
	bmi @send
	lda zm_rflags	; receiver can't overlap disk and serial I/O?
	and #CANOVIO
	beq @w
	lda zm_rbl
	ora zm_rbl+1
	beq @g		; no buffer limit: stream
	lda zm_since	; since + n >= receiver buffer?
	clc
	adc zm_n
	tax
	lda zm_since+1
	adc zm_n+1
	cpx zm_rbl
	sbc zm_rbl+1
	bcs @w
@g:	lda #ZCRCG
	.byte $2c
@w:	lda #ZCRCW
@send:	sta zm_fend2
	jsr zm_sdata
	lda zm_since
	clc
	adc zm_n
	sta zm_since
	lda zm_since+1
	adc zm_n+1
	sta zm_since+1
	lda zm_pos
	clc
	adc zm_n
	sta zm_pos
	lda zm_pos+1
	adc zm_n+1
	sta zm_pos+1
	bcc :+
	inc zm_pos+2
	bne :+
	inc zm_pos+3
:	jsr zm_show_bytes
	jsr zm_check_abort
	lda zm_fend2
	cmp #ZCRCE
	beq zs_eof
	cmp #ZCRCW
	beq @ack
	; streaming: anything from the receiver? (Ultimate Net: not after
	; every subpacket, a read may hold the next write for 40 ms)
	inc zm_chk
	lda modem_type
	cmp #MODEM_TYPE_ULTIMATE_NET
	bne :+
	lda zm_chk
	and #7
	bne @sub2
:	jsr rs232_get
	bcs @sub2
	cmp #ZPAD
	beq :+
	cmp #CAN
	bne @sub2
:	jsr zm_gethdr_a
	bcs @sub2
	cmp #ZACK
	bne zs_reply
@sub2:	jmp @sub

@ack:	jsr zm_gethdr
	bcc :+
	jsr zm_try	; no ACK: send again from there
	jmp zs_data
:	cmp #ZACK
	bne zs_reply
	lda #0
	sta zm_tries
	jmp zs_data	; ZCRCW ended the frame: a new ZDATA header

; a header from the receiver while sending
zs_reply:
	cmp #ZRPOS
	beq @rpos
	cmp #ZSKIP
	beq @skip
	cmp #ZRINIT	; it has the file (ZEOF lost?)
	beq @done
	cmp #ZABORT
	beq :+
	cmp #ZFERR
	beq :+
	cmp #ZCAN
	beq :+
	jmp zs_data	; ? -> start over from where we are
:	jmp zm_remote_cancel
@rpos:	jsr zm_count_error
	jsr zm_hdr2pos
	jmp zs_data
@skip:	lda #<zt_skipped
	ldy #>zt_skipped
	jsr zm_msg
@done:	jmp zs_close

zs_eof:
	lda #0
	sta zm_tries
@e1:	jsr zm_pos2txh
	lda #ZEOF
	jsr zm_sbin
@e2:	jsr zm_gethdr
	bcc :+
	jsr zm_try
	jmp @e1
:	cmp #ZRINIT
	beq @done
	cmp #ZACK
	beq @e2
	cmp #ZRPOS
	bne zs_reply
	jsr zm_hdr2pos
	jmp zs_data
@done:	lda #<zt_file_done
	ldy #>zt_file_done
	jsr zm_msg
	jmp zs_close

;----------------------------------------------------------------------
; Make the buffer hold zm_pos: [zm_bpos, zm_bpos+zm_blen)
zs_seek:
	; zm_pos < zm_bpos: open the file again
	lda zm_pos
	cmp zm_bpos
	lda zm_pos+1
	sbc zm_bpos+1
	lda zm_pos+2
	sbc zm_bpos+2
	lda zm_pos+3
	sbc zm_bpos+3
	bcs @fwd
	jsr zs_close
	jsr zs_open
	bcc :+
	jsr zm_dosline
	jsr zm_canit
	lda #<zt_cant_open
	ldy #>zt_cant_open
	jmp zm_fail
:	lda #0
	sta zm_blen
	sta zm_blen+1
	ldx #3
:	sta zm_bpos,x
	dex
	bpl :-
@fwd:	; d = zm_pos - zm_bpos; within the buffer?
	jsr zs_dist
	lda zm_tmp+2
	ora zm_tmp+3
	bne @skip
	lda zm_blen
	cmp zm_tmp
	lda zm_blen+1
	sbc zm_tmp+1
	bcs @rts	; d <= blen
@skip:	; read and drop up to zm_pos
	jsr zs_drop
	jsr zs_dist
	lda zm_tmp
	ora zm_tmp+1
	ora zm_tmp+2
	ora zm_tmp+3
	beq @rts
	bit zm_eof
	bmi @short
	; read min(d, ZM_TXBLK)
	lda zm_tmp+2
	ora zm_tmp+3
	bne @full
	lda zm_tmp
	cmp #<ZM_TXBLK
	lda zm_tmp+1
	sbc #>ZM_TXBLK
	bcs @full
	lda zm_tmp
	ldx zm_tmp+1
	jsr zs_read
	jmp @skip
@full:	lda #<ZM_TXBLK
	ldx #>ZM_TXBLK
	jsr zs_read
	jmp @skip
@short:	ldx #3		; asked for more than the file has
:	lda zm_bpos,x
	sta zm_pos,x
	dex
	bpl :-
@rts:	rts

; zm_tmp = zm_pos - zm_bpos (32 bit)
zs_dist:
	ldx #0
	ldy #4
	sec
:	lda zm_pos,x
	sbc zm_bpos,x
	sta zm_tmp,x
	inx
	dey
	bne :-
	rts

; drop the buffer: zm_bpos += zm_blen, zm_blen = 0
zs_drop:
	lda zm_bpos
	clc
	adc zm_blen
	sta zm_bpos
	lda zm_bpos+1
	adc zm_blen+1
	sta zm_bpos+1
	bcc :+
	inc zm_bpos+2
	bne :+
	inc zm_bpos+3
:	lda #0
	sta zm_blen
	sta zm_blen+1
	rts

; read up to A/X bytes into the empty buffer
; Reading from the drive, the drive clocks the bits and an NMI can make
; the KERNAL miss one, so the driver is off for every driver, SwiftLink
; too. Only the receiver's rare headers come in while sending; one that
; gets lost is sent again.
zs_read:
	sta zm_lim
	stx zm_lim+1
	lda #0
	sta zm_rtry
	jsr rs232_off
	lda #<ZM_BUF
	sta zm_ptr
	lda #>ZM_BUF
	sta zm_ptr+1
@open:	ldx #LFN_FILE
	jsr chkin
	lda #0		; STATUS may be stale (rs232_get sets it)
	sta status
@loop:
.if ZM_TEST_TMO
	lda zm_blen
	ora zm_blen+1
.if ZM_TEST_TMO = 1
	ora zm_rtry
.endif
	bne @real
	lda zm_bpos
	ora zm_bpos+1
	ora zm_bpos+2
	beq @real
	lda #$42	; what the C64U returned
	sta status
	bne @tmo
@real:
.endif
	jsr getin
	ldy #0
	sta (zm_ptr),y
	lda status
	and #ST_RDTMO	; the drive didn't send the byte in time
	bne @tmo	; (seen on the C64U's software IEC)
	inc zm_ptr
	bne :+
	inc zm_ptr+1
:	inc zm_blen
	bne :+
	inc zm_blen+1
:	lda status
	bne @eof
	lda zm_blen
	cmp zm_lim
	bne @loop
	lda zm_blen+1
	cmp zm_lim+1
	bne @loop
	beq @done
	; No byte moved, so the drive still holds it: untalk, wait a moment
	; and talk again. EOI set with the timeout is not the end of the file.
@tmo:
.if ZM_DEBUG
	lda status
	sta zm_dbuf+3
	lda zm_blen
	sta zm_dbuf+1
	lda zm_blen+1
	sta zm_dbuf+2
	lda zm_rtry
	sta zm_dbuf+4
	lda #'T'	; timeout: bytes lo, hi, ST, try
	ldx #<zm_dbuf
	jsr zm_dlog
.endif
	jsr clrchn
	inc zm_rtry
	lda zm_rtry
	cmp #ZM_RDTRY
	bcs @fail
	lda $a2		; 2-3 jiffies
	clc
	adc #3
:	cmp $a2
	bne :-
	jmp @open
@fail:	jsr rs232_on	; a short file must not go out as complete
	jsr zm_canit
	lda #<zt_read_err
	ldy #>zt_read_err
	jmp zm_fail
@eof:	lda #$80
	sta zm_eof
@done:
.if ZM_DEBUG
	lda status
	sta zm_dbuf+3
	lda zm_blen
	sta zm_dbuf+1
	lda zm_blen+1
	sta zm_dbuf+2
	lda zm_lim
	sta zm_dbuf+4
	lda #'R'	; read: bytes lo, hi, ST, limit lo
	ldx #<zm_dbuf
	jsr zm_dlog
.endif
	jsr clrchn
	jmp rs232_on

; zm_ptr/zm_n = the next subpacket at zm_pos; reads the file as needed
zs_fill:
	jsr zs_dist	; offset into the buffer (< 64K after zs_seek)
	lda zm_tmp
	cmp zm_blen
	bne @have
	lda zm_tmp+1
	cmp zm_blen+1
	bne @have
	; all sent: read on
	jsr zs_drop
	lda #0
	sta zm_tmp
	sta zm_tmp+1
	bit zm_eof
	bmi @have	; nothing left (n = 0)
	lda #<ZM_TXBLK
	ldx #>ZM_TXBLK
	jsr zs_read
@have:	lda #<ZM_BUF
	clc
	adc zm_tmp
	sta zm_ptr
	lda #>ZM_BUF
	adc zm_tmp+1
	sta zm_ptr+1
	; n = min(blen - offset, blk)
	lda zm_blen
	sec
	sbc zm_tmp
	sta zm_n
	lda zm_blen+1
	sbc zm_tmp+1
	sta zm_n+1
	lda zm_n
	cmp zm_blk
	lda zm_n+1
	sbc zm_blk+1
	bcc :+
	lda zm_blk
	sta zm_n
	lda zm_blk+1
	sta zm_n+1
:	lda #0		; last subpacket: end of file and of the buffer
	sta zm_last
	bit zm_eof
	bpl @rts
	lda zm_tmp
	clc
	adc zm_n
	tax
	lda zm_tmp+1
	adc zm_n+1
	cpx zm_blen
	bne @rts
	cmp zm_blen+1
	bne @rts
	lda #$80
	sta zm_last
@rts:	rts

;----------------------------------------------------------------------
; send zm_n bytes at zm_ptr as a data subpacket ending with frame end A
zm_sdata:
	sta zm_fend
	lda zm_n
	sta zm_left
	lda zm_n+1
	sta zm_left+1
	jsr zm_dcrc_init
@loop:	lda zm_left
	ora zm_left+1
	beq @end
	ldy #0
	lda (zm_ptr),y
	pha
	jsr zm_dcrc
	pla
	jsr zm_putesc
	inc zm_ptr
	bne :+
	inc zm_ptr+1
:	lda zm_left
	bne :+
	dec zm_left+1
:	dec zm_left
	jmp @loop
@end:	lda #ZDLE
	jsr rs232_put
	lda zm_fend
	jsr rs232_put
	lda zm_fend
	jsr zm_dcrc
	jsr zm_put_crc
	lda zm_fend
	cmp #ZCRCW
	bne :+
	lda #XON
	jsr rs232_put
:	rts

; send the data CRC (CRC-16 high byte first, CRC-32 low byte first)
zm_put_crc:
	bit zm_d32
	bmi @32
	lda zm_c+1
	jsr zm_putesc
	lda zm_c
	jmp zm_putesc
@32:	ldx #0
:	stx zm_cnt
	lda zm_c,x
	eor #$ff
	jsr zm_putesc
	ldx zm_cnt
	inx
	cpx #4
	bne :-
	rts

;======================================================================
; HEADERS

;----------------------------------------------------------------------
; Wait for a header. C=0: A = type, zm_hdr = type and 4 bytes,
; zm_fmt = format; C=1: timeout, bad CRC or too much garbage.
zm_gethdr:
	jsr zm_getb
	bcs zm_gh_fail
zm_gethdr_a:	; A: first byte, already read
	ldx #<ZM_GARBAGE
	stx zm_gcnt
	ldx #>ZM_GARBAGE
	stx zm_gcnt+1
	ldx #0
	stx zm_cancnt
	beq @chk
@seek:	jsr zm_getb
	bcs zm_gh_fail
@chk:	and #$7f
	cmp #ZPAD
	beq @pad
	cmp #CAN
	bne :+
	inc zm_cancnt	; 5 CANs: the other side gave up
	lda zm_cancnt
	cmp #5
	bcc @g
	jmp zm_remote_cancel
:	lda #0
	sta zm_cancnt
@g:	lda zm_gcnt
	bne :+
	dec zm_gcnt+1
	beq zm_gh_fail
:	dec zm_gcnt
	jmp @seek
@pad:	jsr zm_getb
	bcs zm_gh_fail
	and #$7f
	cmp #ZPAD
	beq @pad
	cmp #ZDLE
	bne @chk
	jsr zm_getb
	bcs zm_gh_fail
	and #$7f
	sta zm_fmt
	cmp #ZHEX
	beq zm_gh_hex
	cmp #ZBIN
	beq zm_gh_bin16
	cmp #ZBIN32
	beq zm_gh_bin32
	bne @chk
zm_gh_fail:
.if ZM_DEBUG
	lda #$7f
	ldx #<zm_hdr
	jsr zm_dlog
.endif
	sec
	rts

zm_gh_hex:
	jsr zm_c16init
	lda #0
	sta zm_i
:	jsr zm_gethex
	bcs zm_gh_fail
	ldx zm_i
	sta zm_hdr,x
	jsr zm_crc16b
	inc zm_i
	lda zm_i
	cmp #7		; 5 bytes and the CRC
	bne :-
zm_gh_c16:
	lda zm_c
	ora zm_c+1
	bne zm_gh_fail
zm_gh_ok:
.if ZM_DEBUG
	lda zm_hdr
	ldx #<zm_hdr
	jsr zm_dlog
.endif
	lda zm_hdr
	clc
	rts

zm_gh_bin16:
	jsr zm_c16init
	lda #0
	sta zm_i
:	jsr zdl_get
	bcs zm_gh_fail
	ldx zm_i
	sta zm_hdr,x
	jsr zm_crc16b
	inc zm_i
	lda zm_i
	cmp #7
	bne :-
	beq zm_gh_c16

zm_gh_bin32:
	jsr zm_c32init
	lda #0
	sta zm_i
:	jsr zdl_get
	bcs zm_gh_fail
	ldx zm_i
	sta zm_hdr,x
	jsr zm_crc32b
	inc zm_i
	lda zm_i
	cmp #9		; 5 bytes and the CRC
	bne :-
	jsr zm_c32check
	jne zm_gh_fail
	jmp zm_gh_ok

; two hex digits; C=1 on error
zm_gethex:
	jsr @dig
	bcs @rts
	asl
	asl
	asl
	asl
	sta zm_e
	jsr @dig
	bcs @rts
	ora zm_e
	clc
@rts:	rts
@dig:	jsr zm_getb
	bcs @rts
	and #$7f
	cmp #'a'
	bcc :+
	sbc #$20	; (C=1) to upper case
:	sec
	sbc #'0'
	bcc @bad
	cmp #10
	bcc @ok
	sbc #'A'-'0'-10	; (C=1)
	cmp #10
	bcc @bad
	cmp #16
	bcs @bad
@ok:	clc
	rts
@bad:	sec
	rts

;----------------------------------------------------------------------
; send a hex header: type A, zm_txh+1..4
zm_shex:
	sta zm_txh
.if ZM_DEBUG
	ora #$80
	ldx #<zm_txh
	jsr zm_dlog
.endif
	lda #ZPAD
	jsr rs232_put
	lda #ZPAD
	jsr rs232_put
	lda #ZDLE
	jsr rs232_put
	lda #ZHEX
	jsr rs232_put
	jsr zm_c16init
	lda #0
	sta zm_i
:	ldx zm_i
	lda zm_txh,x
	pha
	jsr zm_crc16b
	pla
	jsr zm_puthex
	inc zm_i
	lda zm_i
	cmp #5
	bne :-
	lda zm_c+1
	jsr zm_puthex
	lda zm_c
	jsr zm_puthex
	lda #CR
	jsr rs232_put
	lda #$8a	; LF | $80
	jsr rs232_put
	lda zm_txh
	cmp #ZFIN
	beq :+
	cmp #ZACK
	beq :+
	lda #XON
	jsr rs232_put
:	rts

zm_puthex:
	pha
	lsr
	lsr
	lsr
	lsr
	tax
	lda zm_hexdig,x
	jsr rs232_put
	pla
	and #$0f
	tax
	lda zm_hexdig,x
	jmp rs232_put

zm_hexdig:
	.byte "0123456789abcdef"

;----------------------------------------------------------------------
; send a binary header (CRC-16 or CRC-32, as zm_t32): type A, zm_txh+1..4
zm_sbin:
	sta zm_txh
.if ZM_DEBUG
	ora #$c0
	ldx #<zm_txh
	jsr zm_dlog
.endif
	lda #ZPAD
	jsr rs232_put
	lda #ZDLE
	jsr rs232_put
	bit zm_t32
	bmi @32
	lda #ZBIN
	jsr rs232_put
	jsr zm_c16init
	jsr @body16
	lda zm_c+1
	jsr zm_putesc
	lda zm_c
	jmp zm_putesc
@32:	lda #ZBIN32
	jsr rs232_put
	jsr zm_c32init
	lda #0
	sta zm_i
:	ldx zm_i
	lda zm_txh,x
	pha
	jsr zm_crc32b
	pla
	jsr zm_putesc
	inc zm_i
	lda zm_i
	cmp #5
	bne :-
	ldx #0
:	stx zm_cnt
	lda zm_c,x
	eor #$ff
	jsr zm_putesc
	ldx zm_cnt
	inx
	cpx #4
	bne :-
	rts
@body16:
	lda #0
	sta zm_i
:	ldx zm_i
	lda zm_txh,x
	pha
	jsr zm_crc16b
	pla
	jsr zm_putesc
	inc zm_i
	lda zm_i
	cmp #5
	bne :-
	rts

;----------------------------------------------------------------------
; send a byte, ZDLE escaped
zm_putesc:
	sta zm_e
	and #$7f
	cmp #$20
	bcs @plain
	cmp #ZDLE
	beq @esc
	cmp #$10
	beq @esc
	cmp #XON
	beq @esc
	cmp #$13	; XOFF
	beq @esc
	bit zm_escctl
	bmi @esc
@plain:	lda zm_e
	jmp rs232_put
@esc:	lda #ZDLE
	jsr rs232_put
	lda zm_e
	eor #$40
	jmp rs232_put

;----------------------------------------------------------------------
; Get a byte and undo ZDLE escaping.
; C=0: A = data byte
; C=1: X=0: A = frame end (ZCRCE/G/Q/W); X=1: timeout; X=2: bad escape
; Five CANs in a row abort the transfer.
zdl_get:
	jsr zm_getb
	bcs @to
	cmp #ZDLE
	beq @esc
	tax
	and #$7d	; XON/XOFF (with or without bit 7) are flow
	cmp #XON	; control, not data
	beq zdl_get
	txa
	clc
	rts
@esc:	jsr zm_getb
	bcs @to
	cmp #ZDLE	; (ZDLE is CAN)
	beq @can
	tax
	and #$7d
	cmp #XON
	beq @esc
	txa
	cmp #ZCRCE
	bcc @lit
	cmp #ZRUB1+1
	bcs @lit
	cmp #ZRUB0
	bcs @rub
	ldx #0		; frame end
	sec
	rts
@rub:	cmp #ZRUB1
	lda #$7f
	bcc :+
	lda #$ff
:	clc
	rts
@lit:	tax
	and #$60
	cmp #$40
	bne @bad
	txa
	eor #$40
	clc
	rts
@can:	lda #3
	sta zm_cancnt
:	jsr zm_getb
	bcs @to
	cmp #CAN
	bne @bad
	dec zm_cancnt
	bne :-
	jmp zm_remote_cancel
@bad:	ldx #2
	sec
	rts
@to:	ldx #1
	sec
	rts

;----------------------------------------------------------------------
; Get a byte from the modem. C=0: A = byte; C=1: nothing for zm_tmo
; jiffies. C= aborts.
zm_getb:
	jsr rs232_get
	bcs @wait
	ldx #0
	stx zm_wflag
	rts
@wait:	lda SHFLAG
	cmp #SHFLAG_CBM
	bne :+
	jmp zm_user_abort
:	sei
	lda JIFFIES
	ldx JIFFIES-1
	cli
	bit zm_wflag
	bmi @chk
	sta zm_t0
	stx zm_t0+1
	lda #$80
	sta zm_wflag
	bne zm_getb
@chk:	sec
	sbc zm_t0
	sta zm_e2
	txa
	sbc zm_t0+1
	cmp zm_tmo+1
	bcc zm_getb
	bne @out
	lda zm_e2
	cmp zm_tmo
	bcc zm_getb
@out:	lda #0
	sta zm_wflag
	sec
	rts

;======================================================================
; CRC

zm_c16init:
	lda #0
	sta zm_c
	sta zm_c+1
	rts

zm_c32init:
	lda #$ff
	sta zm_c
	sta zm_c+1
	sta zm_c+2
	sta zm_c+3
	rts

; Z=1 if a CRC-32 run over data and CRC came out right
zm_c32check:
	ldx #3
:	lda zm_c,x
	cmp zm_c32res,x
	bne :+
	dex
	bpl :-
	lda #0
:	rts

zm_c32res:
	.byte $e3,$20,$bb,$de	; $DEBB20E3

; bit by bit CRC-16 (XMODEM), A: byte; keeps Y
zm_crc16b:
	eor zm_c+1
	sta zm_c+1
	ldx #8
@l:	asl zm_c
	rol zm_c+1
	bcc :+
	lda zm_c+1
	eor #$10
	sta zm_c+1
	lda zm_c
	eor #$21
	sta zm_c
:	dex
	bne @l
	rts

; bit by bit CRC-32, A: byte; keeps Y
zm_crc32b:
	eor zm_c
	sta zm_c
zm_c32step:
	ldx #8
@l:	lsr zm_c+3
	ror zm_c+2
	ror zm_c+1
	ror zm_c
	bcc :+
	lda zm_c+3
	eor #$ed
	sta zm_c+3
	lda zm_c+2
	eor #$b8
	sta zm_c+2
	lda zm_c+1
	eor #$83
	sta zm_c+1
	lda zm_c
	eor #$20
	sta zm_c
:	dex
	bne @l
	rts

; CRC-32 table
zm_mktab32:
	ldy #0
:	sty zm_c
	lda #0
	sta zm_c+1
	sta zm_c+2
	sta zm_c+3
	jsr zm_c32step
	lda zm_c
	sta ZM_T0,y
	lda zm_c+1
	sta ZM_T1,y
	lda zm_c+2
	sta ZM_T2,y
	lda zm_c+3
	sta ZM_T3,y
	iny
	bne :-
	rts

; data CRC for the frame format in zm_fmt; builds the table it needs
zm_setcrc:
	lda zm_fmt
	cmp #ZBIN32
	beq @32
	lda #0
	sta zm_d32
	lda zm_tabs
	cmp #1
	beq :+
	jsr crctable
	lda #1
	sta zm_tabs
:	lda #<zm_crc16t
	ldx #>zm_crc16t
	bne @set
@32:	lda #$80
	sta zm_d32
	lda zm_tabs
	cmp #2
	beq :+
	jsr zm_mktab32
	lda #2
	sta zm_tabs
:	lda #<zm_crc32t
	ldx #>zm_crc32t
@set:	sta zm_dcrc+1
	stx zm_dcrc+2
	rts

zm_dcrc_init:
	bit zm_d32
	bpl :+
	jmp zm_c32init
:	jmp zm_c16init

; Z=1 if the data CRC is right
zm_dcrc_check:
	bit zm_d32
	bpl :+
	jmp zm_c32check
:	lda zm_c
	ora zm_c+1
	rts

; data CRC with a table, A: byte
zm_dcrc:
	jmp zm_crc32t

zm_crc16t:
	eor zm_c+1
	tax
	lda zm_c
	eor crchi,x
	sta zm_c+1
	lda crclo,x
	sta zm_c
	rts

zm_crc32t:
	eor zm_c
	tax
	lda zm_c+1
	eor ZM_T0,x
	sta zm_c
	lda zm_c+2
	eor ZM_T1,x
	sta zm_c+1
	lda zm_c+3
	eor ZM_T2,x
	sta zm_c+2
	lda ZM_T3,x
	sta zm_c+3
	rts

;======================================================================
; misc

zm_clrtxh:
	lda #0
	ldx #3
:	sta zm_txh+1,x
	dex
	bpl :-
	rts

zm_pos2txh:
	ldx #3
:	lda zm_pos,x
	sta zm_txh+1,x
	dex
	bpl :-
	rts

zm_hdr2pos:
	ldx #3
:	lda zm_hdr+1,x
	sta zm_pos,x
	dex
	bpl :-
	rts

; one more failed exchange; give up after ZM_TRIES in a row
zm_try:
	inc zm_tries
	lda zm_tries
	cmp #ZM_TRIES
	bcs :+
	rts
:	lda #<zt_timeout
	ldy #>zt_timeout
	jmp zm_fail

zm_count_error:
	inc zm_errors
	bne :+
	inc zm_errors+1
:	jmp zm_show_errors

zm_check_abort:
	lda SHFLAG
	cmp #SHFLAG_CBM
	beq zm_user_abort
	rts

;----------------------------------------------------------------------
; the end

zm_user_abort:
	ldx zm_sp
	txs
	jsr rs232_on
	jsr zm_canit
	lda #<zt_aborted
	ldy #>zt_aborted
	bne zm_fail

zm_canit:
	lda #16
	sta zm_cnt
:	lda #CAN	; 8 CAN, 8 backspace
	ldx zm_cnt
	cpx #9
	bcs :+
	lda #ZM_BS
:	jsr rs232_put
	dec zm_cnt
	bne :--
	rts

zm_remote_cancel:
	lda #<zt_cancelled
	ldy #>zt_cancelled
; A/Y: message
zm_fail:
	ldx zm_sp
	txs
	jsr zm_msg
	jsr zm_close_any	; a partial download stays, for a resume
	jmp zm_exit

zm_ok:
	jsr zm_close_any
	ldx #ZM_ROW_MSG
	ldy #2
	jsr zm_at
	lda #<zt_done
	ldy #>zt_done
	jsr outstr
	lda zm_files
	sta zm_num
	lda #0
	sta zm_num+1
	sta zm_num+2
	sta zm_num+3
	jsr zm_pnum
	lda #<zt_files
	ldy #>zt_files
	jsr outstr
	jsr zm_eol
zm_exit:
	ldx #0		; hide the CRC table rows again
	lda #' '
:	sta ZM_T0,x
	sta ZM_T1,x
	inx
	bne :-
	ldx #ZM_ROW_ABORT
	ldy #0
	jsr zm_at
	jsr zm_eol
.if ZM_DEBUG
	jsr zm_dshow
.endif
	lda zm_zpsave
	sta zm_ptr
	lda zm_zpsave+1
	sta zm_ptr+1
	jsr text_color_restore
	jsr clrchn
	ldx #24
	ldy #0
	jsr zm_at
	jsr reset	; driver on, buffer cleared
	jsr gong
	jmp zm_leave

zm_close_any:
	bit zm_dir
	bpl :+
	jmp zm_fclose
:	jmp zs_close

;======================================================================
; screen

; X: row, Y: column
zm_at:
	clc
	jmp plot

.if ZM_DEBUG
ZM_DLOG	= $033c
ZM_DN	= 38
; log entry: A = type (bit 7: sent, bit 6: binary; $7F: bad header),
; then the 4 bytes at zm_hdr+1 or zm_txh+1 (X: low byte of that)
zm_dlog:
	pha
	stx zm_dsrc
	lda zm_dpos
	asl
	asl
	clc
	adc zm_dpos
	tay		; Y = pos * 5
	pla
	sta ZM_DLOG,y
	ldx #1
:	stx zm_dtmp
	txa
	clc
	adc zm_dsrc
	sta @src+1
@src:	lda zm_hdr	; (low byte patched; zm_hdr and zm_txh share a page?)
	iny
	sta ZM_DLOG,y
	ldx zm_dtmp
	inx
	cpx #5
	bne :-
	ldx zm_dpos
	inx
	cpx #ZM_DN
	bcc :+
	ldx #0
:	stx zm_dpos
	rts

; show the log, oldest first, 3 entries a row, on rows 0-12
zm_dshow:
	ldx #0
	lda #1		; white
:	sta $d800,x
	sta $d900,x
	inx
	bne :-
	ldx #0
	ldy #0
	jsr zm_at
	lda #WHITE
	jsr chrout
	lda #0
	sta zm_dcnt
	lda zm_dpos
	sta zm_dcur
@e:	lda zm_dcur
	asl
	asl
	clc
	adc zm_dcur
	tay
	ldx #5
@b:	lda ZM_DLOG,y
	jsr zm_dhex
	iny
	dex
	bne @b
	lda #' '
	jsr chrout
	inc zm_dcur
	lda zm_dcur
	cmp #ZM_DN
	bcc :+
	lda #0
	sta zm_dcur
:	inc zm_dcnt
	lda zm_dcnt
	cmp #ZM_DN
	bne @e
.if !AUTOMATION
	ldx #ZM_ROW_ABORT
	ldy #2
	jsr zm_at
	lda #<zt_dkey
	ldy #>zt_dkey
	jsr outstr
	jsr clrchn
:	jsr getin	; wait for a key (the BBS's text would scroll
	beq :-		; the log away)
.endif
	rts
SET_PETSCII
zt_dkey:	.byte "Debug log above. Press a key.",0
SET_ASCII

zm_dhex:
	pha
	lsr
	lsr
	lsr
	lsr
	jsr @d
	pla
	and #$0f
@d:	cmp #10
	bcc :+
	adc #6
:	adc #'0'
	jmp chrout

; clear the log (zm_begin)
zm_dclr:
	lda #0
	ldx #ZM_DN*5-1
:	sta ZM_DLOG,x
	dex
	bne :-
	sta ZM_DLOG
	sta zm_dpos
	rts
.endif

; "Can't open" and the drive's message below it
zm_cant_open:
	lda #<zt_cant_open
	ldy #>zt_cant_open
	jsr zm_msg
; the drive's message below the status line
zm_dosline:
	ldx #ZM_ROW_MSG+1
	ldy #2
	jsr zm_at
	lda #<ZM_ERRMSG
	ldy #>ZM_ERRMSG
	jsr outstr
	jmp zm_eol

; status line message A/Y
zm_msg:
	pha
	tya
	pha
	ldx #ZM_ROW_MSG
	ldy #2
	jsr zm_at
	lda #WHITE
	jsr chrout
	pla
	tay
	pla
	jsr outstr
; clear to the end of the line
zm_eol:
	ldx COLUMN
	cpx #39
	bcs :+
	lda #' '
	jsr chrout
	jmp zm_eol
:	rts

zm_show_name:
	ldx #ZM_ROW_FILE
	ldy #10
	jsr zm_at
	lda #CYAN
	jsr chrout
	ldx #0
:	cpx zm_nlen
	beq :+
	lda zm_name,x
	jsr chrout
	inx
	bne :-
:	lda #RVSOFF
	jsr chrout
	jmp zm_eol

zm_show_bytes:
	ldx #ZM_ROW_BYTES
	ldy #10
	jsr zm_at
	lda #CYAN
	jsr chrout
	ldx #3
:	lda zm_pos,x
	sta zm_num,x
	dex
	bpl :-
	jsr zm_pnum
	bit zm_dir	; download: "of size"
	bpl @eol
	lda zm_size
	ora zm_size+1
	ora zm_size+2
	ora zm_size+3
	beq @eol
	lda #<zt_of
	ldy #>zt_of
	jsr outstr
	ldx #3
:	lda zm_size,x
	sta zm_num,x
	dex
	bpl :-
	jsr zm_pnum
@eol:	jmp zm_eol

zm_show_errors:
	ldx #ZM_ROW_ERRORS
	ldy #10
	jsr zm_at
	lda #CYAN
	jsr chrout
	lda zm_errors
	sta zm_num
	lda zm_errors+1
	sta zm_num+1
	lda #0
	sta zm_num+2
	sta zm_num+3
	jsr zm_pnum
	jmp zm_eol

; print zm_num (32 bit) in decimal
zm_pnum:
	lda #0
	sta zm_lead
	tay
@dig:	lda #0
	sta zm_cnt
@sub:	sec
	lda zm_num
	sbc zm_p10,y
	sta zm_tmp
	lda zm_num+1
	sbc zm_p10+1,y
	sta zm_tmp+1
	lda zm_num+2
	sbc zm_p10+2,y
	sta zm_tmp+2
	lda zm_num+3
	sbc zm_p10+3,y
	bcc @out
	sta zm_num+3
	lda zm_tmp
	sta zm_num
	lda zm_tmp+1
	sta zm_num+1
	lda zm_tmp+2
	sta zm_num+2
	inc zm_cnt
	bne @sub
@out:	lda zm_cnt
	ora zm_lead
	cpy #9*4
	beq :+
	cmp #0
	beq @next
:	sta zm_lead
	lda zm_cnt
	ora #'0'
	jsr chrout
@next:	iny
	iny
	iny
	iny
	cpy #10*4
	bne @dig
	rts

zm_p10:
	.dword 1000000000,100000000,10000000,1000000,100000
	.dword 10000,1000,100,10,1


;----------------------------------------------------------------------
SET_PETSCII
zt_title_up:
	.byte YELLOW,"ZMODEM Upload",0
zt_title_down:
	.byte YELLOW,"ZMODEM Download",0
zt_labels:
	.byte LTGREEN,"File:",CR
	.byte "  Bytes:",CR
	.byte "  Errors:",0
zt_abort:
	.byte WHITE,"(Press C= to abort.)",0
zt_waiting:
	.byte "Waiting for sender...",0
zt_waiting_rx:
	.byte "Waiting for receiver...",0
zt_receiving:
	.byte "Receiving",0
zt_resuming:
	.byte "Resuming",0
zt_checking:
	.byte "Checking existing file...",0
zt_cant_create:
	.byte "Can't create file, skipped",0
zt_cant_open:
	.byte "Can't open file",0
zt_read_err:
	.byte "Disk read error",0
zt_file_done:
	.byte "File complete",0
zt_offering:
	.byte "Offering file...",0
zt_sending:
	.byte "Sending",0
zt_sending_from:
	.byte "Sending (resumed)",0
zt_skipped:
	.byte "Skipped by receiver",0
zt_finishing:
	.byte "Finishing...",0
zt_done:
	.byte "Done: ",0
zt_files:
	.byte " file(s)",0
zt_of:
	.byte " of ",0
zt_timeout:
	.byte "Timed out",0
zt_aborted:
	.byte "Aborted",0
zt_cancelled:
	.byte "Cancelled by the other side",0
SET_ASCII

;----------------------------------------------------------------------
; variables (zm_begin clears zm_vars..zm_vars_end)
.segment "ZMBSS"	; $CF60-$CFFF (inpbuf+$60), not saved in the PRG
zm_sp:		.res 1
zm_zpsave:	.res 2
zm_dir:		.res 1	; bit 7 (1): download, 0: upload
zm_vars:
zm_hdr:		.res 5	; received header: type, ZP0..ZP3 (ZF3..ZF0)
zm_txh:		.res 5	; header to send
zm_fmt:		.res 1	; format of the last header (ZBIN/ZHEX/ZBIN32)
zm_c:		.res 4	; CRC
zm_d32:		.res 1	; bit 7: data CRC is CRC-32
zm_t32:		.res 1	; bit 7: send CRC-32 binary headers
zm_tabs:	.res 1	; table built: 1 CRC-16, 2 CRC-32
zm_pos:		.res 4	; file position
zm_fill:	.res 2	; receive: good bytes in the buffer
zm_n:		.res 2	; subpacket length
zm_start:	.res 2
zm_left:	.res 2
zm_last:	.res 1
zm_fend:	.res 1
zm_fend2:	.res 1
zm_cnt:		.res 1
zm_i:		.res 1
zm_e:		.res 1
zm_e2:		.res 1
zm_tmpx:	.res 1
zm_tmp:		.res 4
zm_num:		.res 4
zm_lead:	.res 1
zm_tries:	.res 1
zm_errors:	.res 2
zm_files:	.res 1
zm_fopen:	.res 1
zm_ovio:	.res 1	; bit 7: driver has flow control
zm_escctl:	.res 1	; bit 7: escape all control characters
zm_wflag:	.res 1
zm_t0:		.res 2
zm_tmo:		.res 2
zm_gcnt:	.res 2
zm_cancnt:	.res 1
zm_size:	.res 4	; size the sender told us (0: unknown)
zm_have:	.res 4	; length of an existing file
zm_resumed:	.res 1
zm_numb:	.res 1
zm_nstart:	.res 1
zm_nend:	.res 1
zm_ftype:	.res 1	; receive: 0 SEQ, 1 PRG; send: directory type
zm_name:	.res 17
zm_nlen:	.res 1
zm_base:	.res 17
zm_blen:	.res 2	; receive: length of zm_base; send: bytes buffered
zm_rflags:	.res 1	; receiver's ZRINIT flags
zm_rbl:		.res 2	; receiver's buffer size
zm_blk:		.res 2	; subpacket size
zm_since:	.res 2	; bytes since the last ACK
zm_chk:		.res 1
zm_entry:	.res 2
zm_info:	.res 1
zm_bpos:	.res 4	; send: file position of the buffer
zm_lim:		.res 2
zm_eof:		.res 1
zm_sa:		.res 1
zm_rtry:	.res 1	; zs_read: timeouts in a row	; secondary address for zm_openinp
.if ZM_DEBUG
zm_dpos:	.res 1
zm_dsrc:	.res 1
zm_dtmp:	.res 1
zm_dcnt:	.res 1
zm_dcur:	.res 1
zm_dbuf:	.res 5
.endif	; bit 7: the file has been read to the end
zm_vars_end:
.assert zm_vars_end-zm_vars <= 256, error, "zm_vars too big"
;======================================================================
; The ZMODEM code above lies beyond $A000, under the BASIC ROM. Main
; code enters it through these stubs, which bank BASIC out ($01 = $36;
; the KERNAL and I/O stay), and it leaves through zm_leave. Nothing it
; calls needs BASIC. The interrupt handlers save and restore $01.

.segment "CODE"

.import __ZMODEM_LOAD__
.assert __ZMODEM_LOAD__ <= $a000, lderror, "main code must end below $A000"

zm_auto_stub:
	jsr zm_basic_off
	jmp zm_auto
zm_download_stub:
	jsr zm_basic_off
	jmp zm_download
zm_upload_single_stub:
	jsr zm_basic_off
	jmp zm_upload_single
zm_upload_multi_stub:
	jsr zm_basic_off
	jmp zm_upload_multi

zm_basic_off:
	lda #$36
	sta $01
	rts

zm_leave:
	lda #$37
	sta $01
	jmp term_mainloop
zm_leave_entry:
	lda #$37
	sta $01
	jmp term_entry

;----------------------------------------------------------------------
; ZRQINIT detector for terminal mode; keeps A, uses X
zm_detect:
	ldx zm_det
	cmp zm_det_seq,x
	bne @miss
	inx
	cpx #6
	beq @go
	stx zm_det
	rts
@miss:	cmp #ZPAD
	bne @zero
	cpx #2		; "***": still "**"
	beq @rts
	ldx #1
	.byte $2c
@zero:	ldx #0
	stx zm_det
@rts:	rts
@go:	ldx #0
	stx zm_det
	jmp zm_auto_stub

zm_det_seq:
	.byte ZPAD,ZPAD,ZDLE,ZHEX,"00"
zm_det:
	.byte 0

SET_PETSCII
txt_zmodem:
	.byte "ZMODEM",0
SET_ASCII
