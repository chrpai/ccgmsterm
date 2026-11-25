# CCGMS Future Documentation

## Terminal Mode

| Shortcut                | Description                      |
|-------------------------|----------------------------------|
| `F1`                    | [Upload file](#upload-file)      |
| `F2`                    | [Send/Read file](#sendread-file) |
| `F3`                    | [Download file](#download-file)  |
| `F4`                    | [Buffer commands](#buffer-commands) |
| `F5`                    | [Disk command](#disk-command)    |
| `F6`                    | [Directory](#directory)          |
| `F7`                    | [Settings/Dialer](#settingsdialer) |
| `F8`                    | [Cycle terminal mode](#cycle-terminal-mode) |
| `C=` `F1`               | [Multi-Upload](#multi-upload)|
| `C=` `F3`               | [Multi-Download](#multi-download)|
| `C=` `F5`               | [Send directory](#send-directory)|
| `C=` `F7`               | [Screen to buffer](#screen-to-buffer)|
| `CTRL` `F1`/`F3`        | [Send Macro Text](#macros)                |
| `CTRL` `F5`/`F7`        | [Send User ID/Password](#send-user-idpassword)|
| `C=` `CTRL` [`1`-`4`]   | [Take screen snapshot](#screen-snapshot)|
| `SHFT` `CTRL` [`1`-`4`] | [Recall screen snapshot](#screen-snapshot)|
| `C=` `STOP`             | [Disconnect](#disconnect)        |

## Upload File

`F1` will upload a single file from current drive to the BBS. It will ask for the source filename. With ZMODEM, the name is sent along.

## Send/Read File

`F2` will ask whether you want to send (`S`) or read (`R`) a file.

* "Send" reads a file from the current drive and sends it to the BBS, byte by byte, as if it has been typed in. This is meant for text-only data, and does not do any error detection/correction.
* "Read" reads a file from the current drive and prints it to the screen. No data is sent to the BBS.

## Download File

`F3` will download a single file from the BBS to the current drive. First, it will ask for the destination filename.  If the [protocol](#protocol) is XMODEM, it will also ask what file type the new file should be: PRG, SEQ or USR. With [ZMODEM](#zmodem), it doesn't ask for a name; the BBS sends the names.

## Buffer Commands

`F4` will show the buffer menu with following options:

        Open  Close  Erase  Transfer
        Load  Save   Print  View

* **Open**: Open the buffer. If the buffer is open, all text received from the BBS in terminal mode will be appended to the buffer.
* **Close**: Close the buffer. This stops appending text to the buffer.
* **Erase**: Erase the buffer. This clears the buffer.
* **Load**: This loads an SEQ file from the current drive into the buffer.
* **Save**: This saves the buffer into an SEQ file on the current drive.
* **Print**: This sends the buffer to the printer. It will ask for the device number and the secondary address. By convention, secondary address 0 will pick the upper/graphics character set, and 7 will pick the upper/lower character set.
* **View**: This prints the buffer contents to the screen. During printing, STOP cancels, and any other key pauses/unpauses.

In addition, `<` and `>` will move the buffer pointer.

The RETURN key will exit the buffer menu.

## Disk Command

`F5` allows sending a command to the current drive, like `S:FOO,S` or `CD/FOO`/`CD:←` (sd2iec).

* `#8`, `#9` etc. changes the current drive globally.
* An empty command will print the drive status.

## Directory

`F6` will show the directory of the current drive. STOP cancels, and any other key pauses/unpauses.

## Settings/Dialer

`F7` will show the following menu:

        Auto-Dialer/Phonebook
        Baud Rate   - 2400
        Duplex      - Full IAC Escape: N/A
        Modem Type  - User Port 300-2400
        Firmware    - Standard
        Protocol    - XMODEM
        Theme       - Classic CCGMS v5.5
        Edit Macros
        Load/Save Phone Book and Config.
        View Instructions

The first character of each option will invoke it.

### Auto-Dialer/Phonebook

CCGMS can auto-dial phonebook entries. It will send the `ATDT` command and parse the status returned by the modem (e.g. `CONNECT` or `NO ANSWER`). After connecting to the BBS, the key combinations Ctrl+F5 and Ctrl+F7 will send the username and password of the current phonebook entry.

The phonebook has 30 entries, consisting of

* **name**: name in the phone book
* **ip**: DNS name or IP address
* **port**: IP port
* **id**: username
* **pw**: password

Use the cursor keys to navigate the entries. SPACE or RETURN selects/deselects an entry, which allows any subset of the entries to be selected.

#### Dial Unlisted # (`D`)

This allows connecting to a BBS that is not listed in the phonebook. CCGMS will ask for the DNS name or IP and the port.

#### Edit Current # (`E`)

This allows editing the currently highlighted entry.

#### Call Current # (`C`)

This dials the currently highlighted entry.

#### Dial Selected (`A`)

This dials the currently selected entries, one by one, until one answers.

#### Reverse Call (`R`)

Invert the current selection of entries.

#### Return To Menu (`X`)

This will return to the settings menu.


### Baud Rate

This will cycle through the legal baud rates for the current [modem type](#modem-type).

| Driver                  | 300 | 1200 | 2400 | 4800 | 9600 | 19200 | 38400 | 57600 |
|-------------------------|-----|------|------|------|------|-------|-------|-------|
| User Port               | ✅  |  ✅  |  ✅  | ❌  | ❌   | ❌   | ❌    | ❌    |
| UP9600                  | ✅  |  ✅  |  ✅  | ✅  | ✅   | ❌   | ❌    | ❌    |
| SwiftLink/Turbo232      | ✅  |  ✅  |  ✅  | ✅  | ✅   | ✅   | ✅    | ❌    |
| SwiftLink on an Ultimate | ✅  |  ✅  |  ✅  | ✅  | ✅   | ✅   | ✅    | ✅    |

57600 is only offered on an Ultimate (detected at startup, see [IAC Escape](#iac-escape)) with a SwiftLink modem type. It sets the 6551 rate bits to `0000`, which a real 6551 treats as an external clock, so a real SwiftLink can't do it. The Ultimate's modem emulation runs at its fastest pace instead. How fast that actually is depends on the Ultimate's modem "Loop Delay" setting: with "10 ms", a C64 Ultimate measured about 51,000 baud.

A config saved with 57600 drops back to 38400 when it's loaded on other hardware or with another modem type.

### Duplex

Switches between half and full duplex.

### Modem Type

Cycles through the RS-232 drivers:

* User Port: This uses is the original Commodore RS-232 specification for modems on the user port. This can be used with classic modems like the Commodore 1670 (Modem/1200), or when connecting any TTL RS-232 device to the user port's RX and TX pins.
* The [UP9600](https://www.pagetable.com/?p=1656) driver requires an alternate wiring on the user port. It allows higher speeds, and is backwards compatible with the original user port wiring. UP9600 does not work with the C128.
* SwiftLink/Turbo232: This requires cartridge with an external 6551 ACIA, like SwiftLink, Turbo232 or GLINK232T. The cart has to be configured to use NMI (not IRQ) and to be located at either $DE00 (setting `DE`), $DF00 (`DF`) or $D700 (`D7`).
* Ultimate Net: Only offered on an Ultimate (1541 Ultimate-II/II+, Ultimate 64, C64 Ultimate) whose Ultimate Command Interface answers for the network target. CCGMS then talks TCP through the Ultimate's own network stack instead of its SwiftLink emulation, so the emulation's speed limit (its "Loop Delay") does not apply, and the baud rate setting is ignored. The driver behaves like a modem:
	* `ATDT host:port` connects (the port defaults to 23) and answers `CONNECT`, or `NO CARRIER` if the host can't be found or reached. STOP aborts a slow dial. Auto-dialing from the phonebook works as with any modem, with either [firmware](#firmware) setting.
	* `ATI` answers `ULTIMATE-NET MODEM EMULATOR` and `MADE BY CHRIS PAINTER`.
	* `ATE0`/`ATE1` turns the command echo off or on; other `AT` commands answer `OK`.
	* Hanging up (C= STOP) closes the connection. When the BBS hangs up, CCGMS shows `NO CARRIER`.
	* There is no answer mode: the Ultimate's network interface for programs can't accept incoming connections.

	If a saved configuration selects Ultimate Net and CCGMS runs on a machine without it, CCGMS falls back to User Port at 2400 baud.

### Firmware

This configures the syntax used by the auto-dialer. The ZiModem firmware requires the address after `ATDT` in quotes, standard firmwares (WiModem, StrikeLink, ...) do not accept quotes.

### IAC Escape

Only available on an Ultimate (1541 Ultimate-II/II+, Ultimate 64, C64 Ultimate) with a SwiftLink or Ultimate Net [modem type](#modem-type); otherwise it shows `N/A`. The Ultimate is detected at startup through the Ultimate Command Interface, which has to be enabled in the Ultimate menu ("Command Interface").

The Ultimate's modem emulation, like Ultimate Net, passes data straight to a TCP socket. Telnet BBSes treat $FF as the start of a telnet command (IAC), so a lone $FF gets swallowed. With this option on, CCGMS:

* sends every $FF data byte as $FF $FF, and
* on receive, turns $FF $FF back into one $FF and drops telnet commands (WILL/WONT/DO/DONT, subnegotiation).

Turn it off for BBSes that use raw TCP instead of telnet. The setting is saved with the config.

### Protocol

This configures the protocol to be used for file transmissions. It cycles between Punter, three variants of XMODEM, and ZMODEM.

* Punter: This is the "NEW" Punter a.k.a. Punter C1 protocol, which is the standard on many BBSes with a Commodore background.
* XMODEM: This is a family of protocols mostly used on PC BBSes.
	* XMODEM:
		* Upload: force 128B blocks, accept checksum or CRC
		* Download: force checksum, accept 128B or 1K blocks
	* XMODEM-CRC:
		* Upload: force 128B blocks, accept checksum or CRC
		* Download: force CRC, accept 128B or 1K blocks
	* XMODEM-1K:
		* Upload: force 1K blocks, accept checksum or CRC
		* Download: force CRC, accept 128B or 1K blocks
* ZMODEM: see [ZMODEM](#zmodem). A ZMODEM download starts by itself whatever protocol is selected.

### Theme

This cycles through several color themes in the menus.

### Edit Macros

This allows editing the two macros that can be invoked with Ctrl+F1 and Ctrl+F3.

### Load/Save Phone Book and Configuration

This allows loading or saving the configuration and the phonebook contents. The EasyFlash version saves it in the EasyFlash ROM, the regular version saves it to disk. The file on disk is compatible between CCGMS versions.

### View Instructions

Prints some additional keyboard commands as well as the license of the software.

## Cycle Terminal Mode

`F8` cycles through the terminal modes: PETSCII 40, ASCII 40, PETSCII 80, ASCII 80, ANSI 80, and back to PETSCII 40.

Saving the config (`F7`, `S`) also saves the current terminal mode, and CCGMS starts in that mode. Config files from older versions start in PETSCII 40 as before.

### Columns

* 40 columns mode uses the VIC-II hardware text mode and the built-in character set.
* 80 columns mode uses a software library to emulate 80 characters in bitmap mode. A limitation of this mode is that every two adjacent characters have to share a foreground color. In PETSCII mode, the character set is equivalent to the C64 built-in one, and in 80 columns mode, the charset is changed to be identical to ASCII (<tt>\^_`{|}~</tt>)

### Encoding

* PETSCII (a.k.a "C/G") mode uses the Commodore character encoding and supports all [PETSCII control characters](https://www.pagetable.com/c64ref/charset/). It adds the following control codes, which can be sent by the BBS (or typed in by the user if the BBS has remote echo):

| Keyboard            | Code | Description                          |
|---------------------|------|--------------------------------------|
| CTRL B <color-code> | $02  | Change background color              |
| CTRL N              | $0e  | Set background to black              |
| CTRL G              | $07  | Bell sound                           |
| CTRL V              | $17  | Gong sound                           |
| CTRL J              | $0a  | Cursor on                            |
| CTRL K              | $0b  | Cursor off                           |

* ASCII mode uses the standard-ASCII character encoding and supports *some* ANSI control sequences.

### ANSI 80

ANSI 80 is meant for PC-style ANSI BBSes. It uses 80 columns with the full 256 character PC (CP437) font, and every 8x8 cell (two characters) has its own foreground and background color. Two neighboring characters share their colors, which is a VIC-II limit; blank characters and full blocks only need one of the two colors, so they mix with their neighbor more often.

Supported sequences (`ESC [` ...):

| Sequence | Description |
|----------|-------------|
| `H` `f`  | cursor position (row;col) |
| `A` `B` `C` `D` | cursor up/down/right/left |
| `E` `F` `G` `d` | next/previous line, column, row |
| `s` `u`, `ESC 7` `ESC 8` | save/restore cursor |
| `6n` | report the cursor position (`ESC [ row ; col R`), `5n` answers `ESC [ 0 n` |
| `J` | erase below (0), above (1), screen and home (2) |
| `K` | erase to end (0), to start (1), whole line (2) |
| `X` | erase characters |
| `L` `M` | insert/delete lines; `ESC [ M` without a number starts ANSI music |
| `S` `T` | scroll up/down |
| `@` `P` | insert/delete characters |
| `m` | 0 reset, 1 bright, 4 underline, 5/6 blink, 7 reverse, 22/24/25/27 off, 30-37, 39, 40-47, 49 |

Private and unknown sequences (`ESC [ ? 7 h`, `ESC [ ? 25 l`, ...) and ANSI music (`ESC [ M`, `ESC [ N`, `ESC [ |` up to CTRL-N) are ignored without printing anything. Lines wrap after column 80 only when the next character arrives, and CR and LF are separate (LF alone keeps the column).

Keys: the cursor keys send `ESC [ A`-`D`, HOME sends `ESC [ H`, CLR (`SHIFT` `HOME`) sends `ESC [ K` (End), INST sends `ESC [ @`, DEL sends backspace (8), and `CTRL` `:` sends ESC. The function keys stay CCGMS commands.

With telnet IAC handling on (Ultimate), ANSI 80 accepts the telnet TERMINAL-TYPE option and reports `ANSI`, so BBSes that ask can detect ANSI without a prompt. The other modes refuse the option, as before.

The buffer stores the raw bytes in this mode. Saving such a buffer adds `.ans` to the file name, loading a `.ans` file marks the buffer as ANSI, and viewing an ANSI buffer switches to ANSI 80 and plays it through the ANSI parser.

Blinking text blinks about three times a second while the terminal waits for input. Like the colors, blinking is per cell, so a blinking character can make its neighbor blink too. (`a80_ice` in `src/ansi80.s` switches blink to a bright background instead, for "iCE color" art; there is no menu option for it yet.)

The colors are one table, `ansi80_colors` in `src/ansi80.s`.

## ZMODEM

ZMODEM is the streaming protocol most PC-style and Amiga BBSes offer. CCGMS supports:

* Download and upload, one file or a batch, with the file names sent by the other side.
* Auto-start: when the BBS starts a ZMODEM download (it sends `**`, CAN, `B00`), CCGMS switches to a 40 column status screen and starts receiving by itself, in any terminal mode and whatever protocol is selected. `F3` with ZMODEM selected also waits for the BBS to start.
* CRC-16 and CRC-32. The sender chooses; CCGMS offers CRC-32.
* Streaming. The sender streams without waiting for a reply after each block, but CCGMS asks it to wait for an acknowledgment every 1 KB. With SwiftLink and Ultimate Net, RS-232 flow control also holds the sender while CCGMS writes to disk. The 1 KB limit matters with a slow drive: a sender that streams the whole file fills the network buffers, runs far ahead of the drive, and can give up waiting for CCGMS to finish the file. Some senders ignore the limit; with `sz` from lrzsz, use `sz -w 2048` on slow drives. The user port drivers can't receive while CCGMS writes to disk; a sender that ignores the limit still works there, but more slowly, because CCGMS has it resend what was missed.
* Error recovery: a bad block makes CCGMS ask the sender to go back to the last good byte.
* Resume: if a file with the same name exists and is shorter than the file offered, CCGMS appends the rest (crash recovery). If it is the same size or larger, CCGMS saves the new file under a numbered name such as `NAME-1`. It never overwrites a file.

Received names are converted to PETSCII and cut to 16 characters. Files ending in `.prg` or `.d64` are saved as PRG, everything else as SEQ. Files are saved to the current drive.

When uploading, CCGMS sends the file name in lower case, and adds `.prg` to PRG files whose name has no extension, so a PC can tell what they are. It does not send the file size, which it doesn't know without reading the whole file.

`C=` cancels a transfer. If the disk is full or the drive reports an error, CCGMS cancels the transfer and shows the drive's message.

ZMODEM uses the 1 KB XMODEM buffer at $C800, so it is not affected by the size of the terminal buffer.

## Multi-Upload

`C=` `F1` uploads one or more file using the Multi-Punter procotol, or ZMODEM if it is the selected protocol. It will print the directory of the current drive entry by entry and ask for one of the following:

* **Yes**: Upload this file.
* **No**: Do not upload this file.
* **Quit**: Stop uploading.
* **Skip8**: Do not upload the next 8 files.
* **Done**: Stop uploading.
* **All**: Upload all files from here on.

Multi-Punter will also send the name and type of each file. ZMODEM sends all files you picked in one batch.

## Multi-Download

`C=` `F3`  downloads one or more files with Multi-Punter, or ZMODEM if it is the selected protocol. For each file, the BBS will send the name, type and file contents, and CCGMS will write the data to the current drive.

## Send directory

`C=` `F5` will read the current drive's directory listing and send it to the BBS.

## Screen to buffer

`C=` `F7` will convert the contents of the screen to a (minimal) sequence of PETSCII characters and codes and store it in the buffer.

If the `SHIFT` key is pressed in addition, the contents of the buffer will be cleared first.

> Note that in 80 columns mode, every two adjacent characters share a foreground color, so having the BBS show PETSCII graphics in 80 columns mode and saving the screen contents is lossy. For this use case, open the buffer before having the graphics printed instead.

## Screen Snapshots

* `C=` `CTRL` and the keys `1`-`4` will copy the current screen contents into one of the four buffers.
* `SHFT` `CTRL` and `1`-`4` will swap the current screen with one of the four buffers.

Note that this feature is disabled in 80 columns mode, and switching into 80 columns mode will clear all four buffers.

## Macros

`CTRL` `F1` and `CTRL` `F3` will send the contents of one of the two macros.

## Send User ID/Password

`CTRL` `F5` will send the username and `CTRL` `F7` the password of the current phonebook entry, as if it were typed in.

## Disconnect

This will drop the DTR line, which signals the modem that it should disconnect.
