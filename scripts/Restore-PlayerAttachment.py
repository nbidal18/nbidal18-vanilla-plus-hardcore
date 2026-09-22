"""Copy one Fabric attachment from an older copy of a player's .dat into the current one, offline.

    python Restore-PlayerAttachment.py <player.dat with the attachment> <current player.dat> <out.dat> <attachment key>

The reverse of Edit-PlayerAttachment.py: the named entry is cut out of the first file byte for byte
and put into the current file's `fabric:attachments` compound - in place of the entry already there
under that key (Carry On writes an idle one for every player), or at the end if there is none. Every
other byte of the current file is copied through unchanged, so what the player did since -
inventory, position, the other attachments - is kept.

Written 2026-09-10, the same day as the removal: the owner wanted the crashing Carry On horse put back
into a player's hands. The server must be stopped, as for the other player-file scripts.
"""
import gzip
import struct
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
old_path, cur_path, dst, key = sys.argv[1:5]


def parse(data, key):
    """Walk the NBT; return (span of fabric:attachments/<key> or None, offset of the attachments
    compound's TAG_End, keys present)."""
    state = {'pos': 0, 'found': None, 'end_of_attachments': None, 'keys': []}

    def rd(fmt):
        v = struct.unpack_from('>' + fmt, data, state['pos'])
        state['pos'] += struct.calcsize('>' + fmt)
        return v[0]

    def rstr():
        n = rd('H')
        s = data[state['pos']:state['pos'] + n].decode('utf-8', 'replace')
        state['pos'] += n
        return s

    def payload(t, path):
        if t in (1, 2, 3, 4, 5, 6):
            return rd({1: 'b', 2: 'h', 3: 'i', 4: 'q', 5: 'f', 6: 'd'}[t])
        if t == 7:
            n = rd('i'); state['pos'] += n; return None
        if t == 8:
            return rstr()
        if t == 9:
            et = rd('b'); n = rd('i')
            return [payload(et, path + '[%d]' % i) for i in range(n)]
        if t == 10:
            while True:
                entry_start = state['pos']
                et = rd('b')
                if et == 0:
                    if path == '/fabric:attachments':
                        state['end_of_attachments'] = entry_start
                    break
                k = rstr()
                payload(et, path + '/' + k)
                if path == '/fabric:attachments':
                    state['keys'].append(k)
                    if k == key:
                        state['found'] = (entry_start, state['pos'])
            return None
        if t == 11:
            n = rd('i'); state['pos'] += 4 * n; return None
        if t == 12:
            n = rd('i'); state['pos'] += 8 * n; return None
        raise Exception('tag %d' % t)

    t = rd('b'); rstr(); payload(t, '')
    assert state['pos'] == len(data), 'parser did not consume the whole file'
    return state['found'], state['end_of_attachments'], state['keys']


old = gzip.open(old_path, 'rb').read()
cur = gzip.open(cur_path, 'rb').read()

span, _, _ = parse(old, key)
assert span, 'no %s in %s' % (key, old_path)
entry = old[span[0]:span[1]]
found, tag_end, keys = parse(cur, key)
assert tag_end is not None, 'the current file has no fabric:attachments compound'

if found:
    # Carry On writes an idle entry (tick, keyPressed, selected - no entity) for every player once
    # it has run, so the restore replaces whatever the current file holds under the key.
    out = cur[:found[0]] + entry + cur[found[1]:]
    print('replacing fabric:attachments/%s (%d bytes idle entry -> %d bytes) beside %s'
          % (key, found[1] - found[0], len(entry), [k for k in keys if k != key]))
else:
    out = cur[:tag_end] + entry + cur[tag_end:]
    print('restoring fabric:attachments/%s (%d bytes) beside %s' % (key, len(entry), keys))
print('bytes     %d -> %d decompressed' % (len(cur), len(out)))
with gzip.open(dst, 'wb') as f:
    f.write(out)
print('wrote     %s' % dst)
