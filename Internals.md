# CCGMS Internals

Here are some details that will help with development.

## Memory Map

* Low

| Range       | Use                                      |
|-------------|------------------------------------------|
| $0380-$03FF | UP9600 byte reversal table               |
| $0400-$05FF | Punter buffers (screen RAM!); ZMODEM CRC-32 table bytes 0 and 1 (hidden by setting color RAM to the background color) |

* High

| Range       | Use                                      | Alt use               |
|-------------|------------------------------------------|-----------------------|
| $C800-$CAFF |                                          | XMODEM/ZMODEM buffer  |
| $CB00-$CBFF | Multi-Punter buffer (also ZMODEM batch upload list) | XMODEM/ZMODEM receive buffer (cont.) |
| $CC00-$CCFF | buffer to save return text from dialing  | CRC table lo; ZMODEM CRC-32 byte 2 |
| $CD00-$CDFF | Punter temporary vars                    | CRC table hi; ZMODEM CRC-32 byte 3 |
| $CE00-$CEFF | RS-232 input buffer                      |                       |
| $CF00-$CF2F | text input buffer                        |                       |
| $CF30-$CF5F | (text input buffer)                      | ZMODEM: drive status text |
| $CF60-$CFFF | (text input buffer)                      | ZMODEM variables (segment ZMBSS) |

ZMODEM receives into $C800-$CBFF (1 KB). It sends from $C800-$CAFF (768 bytes), because a batch upload keeps its file list at $CB00.

* 40 column mode:

| Range       | Use                                      |
|-------------|------------------------------------------|
| $D000-$DFFF | unused                                   |
| $E000-$FFCF | screen snapshots                         |

* 80 column mode:

| Range       | Use                                      |
|-------------|------------------------------------------|
| $D000-$D3FF | 4x8 charset                              |
| $D400-$D7E7 | 40x25 "screen memory" holding the colors |
| $D800-$DFCF | logical 80x25 screen RAM                 |
| $E000-$FE3F | bitmap                                   |

* 80 column ANSI mode: same bitmap at $E000 and colors at $D400, but each $D400 byte holds (foreground << 4) \| background for its two characters. $D800-$DBE7 holds the real colors of blinking cells and $DC00-$DFE7 their blink flags; $D000-$D3FF is not used, and the CP437 font lives in the program.

## Banking

CCGMS runs with $01 = $37. Whenever you want to turn off the KERNAL ROM, you need to store #$34 in $01. This is effectively the same as #$30, but allows the timing-critical UP9600 code to switch I/O on and off with `inc $01` and `dec $01`.
The ZMODEM code (segment `ZMODEM`, `src/zmodem.s`) is linked after the RS-232 drivers and reaches past $A000, under the BASIC ROM, so it runs with $01 = $36 (BASIC banked out, KERNAL and I/O in). Main code enters it only through the `zm_*_stub` routines in `CODE`, which bank BASIC out, and it leaves through `zm_leave`/`zm_leave_entry`, which bank BASIC back in. A linker assert makes sure `CODE` and `RS232` still end below $A000. The interrupt handlers save and restore $01, so they work in either state. The buffer after `endprg` now starts above $A000; it always reached past $A000, and the buffer code already banks BASIC out to use it.
