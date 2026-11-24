# CCGMS Testing

## Transfer Test

The commands

        make testup # User Port
        make testsw # SwiftLink/DE

will build CCGMS with automation support and run an automated test in VICE for all file transfer protocols and their combinations.

It should print

        ***** TEST_XFER: PUNTER OK
        ***** TEST_XFER: XMODEM; client: XMODEM, server: 512B/CHKSUM: OK
        ***** TEST_XFER: XMODEM; client: XMODEM, server: 1KB/CRC16:   OK
        ***** TEST_XFER: XMODEM; client: XMODEM-CRC, server: 512B/CHKSUM: OK
        ***** TEST_XFER: XMODEM; client: XMODEM-CRC, server: 1KB/CRC16:   OK
        ***** TEST_XFER: XMODEM; client: XMODEM-1K, server: 512B/CHKSUM: OK
        ***** TEST_XFER: XMODEM; client: XMODEM-1K, server: 1KB/CRC16:   OK
        ***** TEST_XFER: Succeeded!

You will have to quit VICE manually after the test has finished.

The tests uses the respective driver at 2400 baud and takes about 5 minutes. You can speed it up using warp mode. UP9600 has to be tested on real hardware. Refer to the Makefile on how to run the `xfer.sh` server.

## Echo

This test echos all input. Run the server like this:

        cd test
        sh echo.sh

 Running any of these

        make runup     # User Port
        make runup9600 # UP9600
        make runsw     # SwiftLink/DE

will connect to the server.

## Slowout

This test server prints characters slowly.

        cd test
        sh slowout.sh

## Fastout

This test server prints characters at the full data rate.

        cd test
        sh fastout.sh

It can easily overflow the 256 byte CCGMS input buffer if printing cannot keep up. The pattern printed makes it easy to see when characters are dropped.

## Ultimate / telnet IAC

These unit tests run pieces of `build/ccgmsterm.prg` in the [py65](https://github.com/mnaberez/py65) 6502 emulator (`pip install py65`), after a plain `make`:

        python3 test/ultimate/test_uci.py    # UCI detection against an emulated Command Interface
        python3 test/ultimate/test_setup.py  # IAC handling turns on only with option + Ultimate
        python3 test/ultimate/test_put.py    # $FF is sent as $FF $FF
        python3 test/ultimate/test_iac.py    # telnet commands are stripped on receive

Each prints one `OK` line per case and exits non-zero on failure.

## Print Speed

`test/perf/printbench.py` runs CCGMS on a simulated C64 (py65) and counts the cycles the terminal spends per received byte, with the modem driver stubbed out. `test/perf/compare.py` feeds two builds the same random input and checks that they leave the same screen, color RAM and editor state. Both need the C64 KERNAL (901227-03) and BASIC ROMs as `kernal.bin` and `basic.bin` in a directory you pass as the first argument:

        pip install py65
        python3 test/perf/printbench.py ROMDIR
        REU=1 MODEM=5 STREAM=plain python3 test/perf/printbench.py ROMDIR
        python3 test/perf/compare.py ROMDIR old.prg build/ccgmsterm.prg
