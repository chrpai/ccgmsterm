; CCGMS Terminal
;
; Copyright (c) 2016,2020, Craig Smith, alwyz. All rights reserved.
; This project is licensed under the BSD 3-Clause License.
;
; Configuration data & phone book
;

;----------------------------------------------------------------------
;----------------------------------------------------------------------
;  This data gets saved to disk/EasyFlash
config_data:

baud_rate:
; DEFAULT_BAUDRATE: defined by build system
.if DEFAULT_BAUDRATE = 2400
	.byte BAUD_2400
.elseif DEFAULT_BAUDRATE = 9600
	.byte BAUD_9600
.else
.error
.endif

; indicates whether dialing should use ATD, followed by a quote
firmware_zimmers:
	.byte 0

mopo2:
	.byte $20	; unused, but needs to stay for bin compat

modem_type:
	.byte DEFAULT_DRIVER; defined by build system

;----------------------------------------------------------------------
; Phone book
phbmem:
	; | len | contents |
	; |-----|----------|
	; |   2 | ?        |
	; |  18 | name     |
	; |  33 | address  |
	; |   6 | port?    |
	; |  12 | user     |
	; |  12 | password |
	; total: 83 bytes

SET_PETSCII
	;.byte 0,6
	;.byte "Afterlife         "
	;.byte "192.168.0.8     ",0,"               ",0
	;.byte "6401 ",0
	;.byte "MYUSERID   ",0
	;.byte "MYPASSWORD1",0

	;.byte 0,6
	;.byte "Afterlife         "
	;.byte "192.168.0.8:6401                ",0
	;.byte "6400 ",0
	;.byte "ANOTHERUSER",0
	;.byte "MYPASSWORD1",0

	;.byte 0,6
	;.byte "Afterlife         "
	;.byte "192.168.0.8:6401                ",0
	;.byte "23   ",0
	;.byte "MYID       ",0
	;.byte "MYPASSWORD1",0

	.repeat 29
	.res 83,0	; empty entry
	.endrep

	.byte 0,6
	.byte "Commodoreserver   "
	.byte "commodoreserver.com",0,CR,0,0,0,0,0,0,0,0,0,0,0,0
	.byte "1541",0,13
	.byte "id         ",0
	.byte "pin        ",0
	.byte 0,0

;----------------------------------------------------------------------
; Macros
macmem:
macmm1:
	.byte "Hello World"
	.res 64,0	; [XXX too many 0s]
macmm2:
	.res 64,0
macmm3:
	.res 64,0
macmm4:
	.res 64,0

;----------------------------------------------------------------------
; file transmission protocol
protoc:
	.byte PROTOCOL_PUNTER

; current theme; see theme.s
theme:
	.byte 0

; save config to disk even though we have an EasyFlash
easyflash_use_disk:
	.byte 0

; telnet IAC handling ($FF doubling) for the Ultimate's modem emulation;
; only used on an Ultimate with a SwiftLink modem type.
; (appended last, so older, shorter config files still load)
telnet_iac:
	.byte 0

; terminal mode at the time the config was saved, restored at startup:
; 0: PETSCII 40, 1: ASCII 40, 2: PETSCII 80, 3: ASCII 80, 4: ANSI 80
; (appended last, so older config files still load and start in PETSCII 40)
term_mode:
	.byte 0

config_data_end:
;----------------------------------------------------------------------

	.byte 0		; [XXX unused; not part of config file]

