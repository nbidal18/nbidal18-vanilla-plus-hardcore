"""Swap one stack in a player's inventory for another item, and optionally add more, offline.

    python Edit-PlayerInventory.py <player.dat in> <player.dat out> <remove id> <replace-with id> [extra id ...]
    python Edit-PlayerInventory.py <player.dat in> <player.dat out> - - <extra id> [extra id ...]

The player file is `world/players/data/<offline uuid>.dat` on the 26.2 layout (there is no
`playerdata/` folder any more). The stack whose item id is <remove id> - there must be exactly
one in the main inventory - is replaced in the same slot by one <replace-with id>, and each
<extra id> becomes one more plain stack in the lowest free main-inventory slot (0-35). With `- -`
in place of the two ids nothing is removed and the extras are only added. Ender chest, armour,
offhand and backpack contents are read only to find free slots and are never written.

Byte-splice, not a round trip: the replaced element's bytes and the Inventory list's length are
the only bytes that change; everything else in the decompressed NBT is copied through as it was,
so nothing else about the player can drift. Read the result back with a parser before uploading.

Written 2026-09-09 to take the one Resonance hammer out of the world after v1.0.86 stopped the
enchantment from being offered (see server.md, "Editing a player's inventory"). The server must be
stopped: a running server writes the file at logout and on its autosave, over whatever was uploaded.
"""
import gzip
import struct
import sys

if len(sys.argv) < 5:
    sys.exit(__doc__)
src, dst, remove_id, replace_id = sys.argv[1:5]
extra_ids = sys.argv[5:]

data = gzip.open(src, 'rb').read()
pos = 0
spans = []          # (start, end, parsed) of every Inventory element
inv_header = None   # (offset of the list's element-type byte, element type, count, end of list)


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
    global pos, inv_header
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
        hdr = pos
        et = rd('b')
        n = rd('i')
        out = []
        if path == '/Inventory':
            inv_header = (hdr, et, n)
        for i in range(n):
            start = pos
            v = payload(et, path + '[%d]' % i)
            if path == '/Inventory':
                spans.append((start, pos, v))
            out.append(v)
        if path == '/Inventory':
            inv_header = inv_header + (pos,)
        return out
    if t == 10:
        out = {}
        while True:
            et = rd('b')
            if et == 0:
                break
            k = rstr()
            out[k] = payload(et, path + '/' + k)
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
assert inv_header, 'no Inventory list in this file'
hdr, et, n, list_end = inv_header
assert et == 10 and n == len(spans)

if remove_id == '-':
    assert replace_id == '-' and extra_ids, 'add-only mode is "- -" followed by at least one item id'
    start = end = list_end   # an empty splice at the end of the list: nothing replaced
    slot = None
else:
    hits = [s for s in spans if isinstance(s[2], dict) and s[2].get('id') == remove_id]
    assert len(hits) == 1, 'expected exactly one %s in Inventory, found %d' % (remove_id, len(hits))
    start, end, old = hits[0]
    slot = old['Slot']
    print('removing  slot %d %s components=%s' % (slot, old['id'], old.get('components')))

used = {s[2]['Slot'] for s in spans}
free = [i for i in range(36) if i not in used]
assert len(free) >= len(extra_ids), 'not enough free main-inventory slots'


def tag_byte(name, v):
    return b'\x01' + struct.pack('>H', len(name)) + name.encode() + struct.pack('>b', v)


def tag_int(name, v):
    return b'\x03' + struct.pack('>H', len(name)) + name.encode() + struct.pack('>i', v)


def tag_str(name, v):
    return b'\x08' + struct.pack('>H', len(name)) + name.encode() + struct.pack('>H', len(v)) + v.encode()


def stack(slot, item):
    return tag_byte('Slot', slot) + tag_str('id', item) + tag_int('count', 1) + b'\x00'


replacement = b''
if slot is not None:
    replacement = stack(slot, replace_id)
    print('giving    slot %d %s x1' % (slot, replace_id))
appended = b''
for item, s in zip(extra_ids, free):
    appended += stack(s, item)
    print('giving    slot %d %s x1' % (s, item))

out = (data[:hdr] + b'\x0a' + struct.pack('>i', n + len(extra_ids))
       + data[hdr + 5:start] + replacement + data[end:list_end] + appended + data[list_end:])
print('bytes     %d -> %d decompressed; Inventory %d -> %d stacks' % (len(data), len(out), n, n + len(extra_ids)))

with gzip.open(dst, 'wb') as f:
    f.write(out)
print('wrote     %s' % dst)
