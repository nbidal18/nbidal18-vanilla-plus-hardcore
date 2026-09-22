"""Remove one Fabric attachment from a player's .dat offline, byte-splice style.

    python Edit-PlayerAttachment.py <player.dat in> <player.dat out> <attachment key>

Fabric mods keep per-player state under the `fabric:attachments` compound, keyed by the mod's id
(`carryon:carry_on_data`, `travelersbackpack:travelers_backpack`, ...). This drops the one named
entry - the whole tag, name and payload - and copies every other byte of the decompressed NBT
through unchanged. If it was the last entry the now-empty `fabric:attachments` compound is left in
place, which is what the game writes for a player with no attachments.

Written 2026-09-10: a player picked up a horse with Carry On and his client crashed on every join
after that, while the carried horse was still stored in his file. The horse is not put back into
the world - it is gone with the tag; summon a replacement in game. The server must be stopped, as
for Edit-PlayerInventory.py.
"""
import gzip
import struct
import sys

if len(sys.argv) != 4:
    sys.exit(__doc__)
src, dst, key = sys.argv[1:4]

data = gzip.open(src, 'rb').read()
pos = 0
found = None  # (start of the entry's type byte, end of its payload)


def rd(fmt):
    global pos
    v = struct.unpack_from('>' + fmt, data, pos)
    pos += struct.calcsize('>' + fmt)
    return v[0]


def rstr():
    global pos
    n = rd('H')
    s = data[pos:pos + n].decode('utf-8', 'replace')
    pos += n
    return s


def payload(t, path):
    global pos, found
    if t == 1:
        return rd('b')
    if t == 2:
        return rd('h')
    if t == 3:
        return rd('i')
    if t == 4:
        return rd('q')
    if t == 5:
        return rd('f')
    if t == 6:
        return rd('d')
    if t == 7:
        n = rd('i')
        pos += n
        return None
    if t == 8:
        return rstr()
    if t == 9:
        et = rd('b')
        n = rd('i')
        return [payload(et, path + '[%d]' % i) for i in range(n)]
    if t == 10:
        out = {}
        while True:
            entry_start = pos
            et = rd('b')
            if et == 0:
                break
            k = rstr()
            v = payload(et, path + '/' + k)
            if path == '/fabric:attachments' and k == key:
                assert found is None, 'attachment listed twice'
                found = (entry_start, pos)
            out[k] = v
        return out
    if t == 11:
        n = rd('i')
        pos += 4 * n
        return None
    if t == 12:
        n = rd('i')
        pos += 8 * n
        return None
    raise Exception('tag %d' % t)


t = rd('b')
rstr()
root = payload(t, '')
assert pos == len(data), 'parser did not consume the whole file'
assert found, 'no attachment %s in this file' % key
start, end = found
out = data[:start] + data[end:]
print('removing  fabric:attachments/%s (%d bytes)' % (key, end - start))
print('bytes     %d -> %d decompressed' % (len(data), len(out)))
with gzip.open(dst, 'wb') as f:
    f.write(out)
print('wrote     %s' % dst)
