# Check that two CCGMS builds leave the same screen after the same input.
#   python3 test/perf/compare.py ROMDIR OLD.prg NEW.prg
# Runs printbench.py on random PETSCII streams (control codes, colors,
# cursor movement, long lines, any byte) in 40 and 80 columns, with and
# without an REU, and compares screen, color RAM and editor state.
import os, random, subprocess, sys, tempfile

romdir, old, new = sys.argv[1:4]
here = os.path.dirname(os.path.abspath(__file__))
ctrl = [0x0d, 0x8d, 0x11, 0x91, 0x1d, 0x9d, 0x12, 0x92, 0x13, 0x14, 0x94, 0x93, 0x05,
        0x1c, 0x9e, 0x9f, 0x81, 0x90, 0x22, 0x0e, 0x8e, 0x02, 0x0a, 0x0b, 0x07, 0x16]
printable = list(range(0x20, 0x80)) + list(range(0xa0, 0x100))

def stream(seed, n, mode):
    r = random.Random(seed)
    out = bytearray()
    while len(out) < n:
        x = r.random()
        if mode == 'any':
            out.append(r.randrange(1, 256))
        elif x < 0.12:
            out.append(r.choice(ctrl))
        elif x < 0.2:
            out += b'A' * r.randrange(30, 90)
        else:
            out.append(r.choice(printable))
    return bytes(out[:n])

tmp = tempfile.mkdtemp()
fails = runs = 0
for col80 in ('0', '1'):
    for seed in range(1, 5 if col80 == '1' else 9):
        for mode in ('mix', 'any'):
            sp = os.path.join(tmp, 's.bin')
            open(sp, 'wb').write(stream(seed, 2000, mode))
            for reu in ('0', '1'):
                dumps = []
                for prg in (old, new):
                    d = os.path.join(tmp, 'd%d.bin' % len(dumps))
                    env = dict(os.environ, STREAMFILE=sp, DUMP=d, REU=reu, MODEM='5', COL80=col80)
                    subprocess.run([sys.executable, os.path.join(here, 'printbench.py'), romdir, prg],
                                   env=env, check=True, stdout=subprocess.DEVNULL)
                    dumps.append(open(d, 'rb').read())
                runs += 1
                if dumps[0] != dumps[1]:
                    fails += 1
                    keep = os.path.join(tmp, 'fail-%s-%d-%s-%s' % (col80, seed, mode, reu))
                    os.mkdir(keep)
                    for i, d in enumerate(dumps):
                        open(os.path.join(keep, 'dump%d.bin' % i), 'wb').write(d)
                    open(os.path.join(keep, 'stream.bin'), 'wb').write(open(sp, 'rb').read())
                    print('DIFFERENT: col80=%s seed=%d mode=%s reu=%s (%s)' % (col80, seed, mode, reu, keep))
print('%d of %d runs differ' % (fails, runs))
sys.exit(1 if fails else 0)
