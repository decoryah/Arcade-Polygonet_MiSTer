# bench-only patches to the program image (img/prog.hex), to reach the later tests sooner:
#  0x45a: the power-on delay loop (move.w #$60,D1) shortened to one pass
#  0x44b06: the ROM checksum routine sums nothing (asr.l #8,D3 -> moveq #0,D3); the ROMs then
#           report BAD, which also makes the game show its result screen
# With "pass" (python3 patch.py pass), to get past the power-on check instead:
#  0x44610: the ROM check reports no failures (move.l D0,D4 -> moveq #0,D4)
#  0x44620: the wait for the sound CPU's RAM test (~440 frames) is skipped and reported OK
#           (bsr $44bb2 -> moveq #0,D0 / addq.l #4,A7, dropping its argument)
# With "demo" as well (python3 patch.py pass demo), to reach the attract demo sooner:
#  0x11289a: the length of the warning and FBI screens, 216 ticks of 30 Hz each (read at $51376
#            and $51638), cut to 8, which saves about 830 frames
# With "garage" as well: 0x516f6, the garage scene's test for the end of its animation (beq $51704 -> nop),
#  so the demo (scene $b) starts on the scene's first tick; about 450 frames saved (MAME: demo from frame 476)
import sys
p = 'img/prog.hex'
l = open(p).read().split('\n')
def put(a, old, new):
    for i, (o, n) in enumerate(zip(old.split(), new.split())):
        w = (a >> 1) + i
        assert l[w] in (o, n), (hex(a + 2 * i), l[w])
        l[w] = n
put(0x45a, '0060', '0000')
put(0x44b06, 'e083', '7600')
if 'pass' in sys.argv[1:]:
    put(0x44610, "2800", "7800")
    put(0x44620, '6100 0590', '7000 588f')
if 'demo' in sys.argv[1:]:
    put(0x11289a, '00d8', '0008')
if 'garage' in sys.argv[1:]:
    put(0x516f6, '670c', '4e71')
open(p, 'w').write('\n'.join(l))
print('patched')
