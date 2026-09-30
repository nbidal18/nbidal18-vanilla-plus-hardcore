"""Put a Gravestones death file's contents back into an offline player's .dat.

    python Restore-GraveContents.py grave <player.dat in> <death.dat> <player.dat out>
    python Restore-GraveContents.py carry <player.dat in> <player.dat_old> <out> <what> ...

`grave` puts a death file's contents back. `carry` copies named things from an earlier save of the
same player over the current one - a top-level tag such as `XpLevel`, or `equipment.legs` - for the
losses a death file never holds. Both refuse to overwrite anything that is already there.

Fetch both with `Sync-ServerMirror.ps1 -Get`, run this, upload the result with `-Put`:

    /world/players/data/<offline uuid>.dat
    /world/gravestones/<offline uuid>/<DD-MM-YYYY>_<HH-MM-SS>.dat   (UTC, one per death)

**The server does not have to be stopped - the player has to be offline.** A running server writes
a player's file at logout and on each autosave, and only for players who are connected: on
2026-09-29 the one online player's file was rewritten at 19:17 and 19:22 while the offline player's
sat untouched at 19:11 across both autosaves. Ping for the player list before and after (a Server
List Ping names who is on) and the write is safe. If they log in mid-edit the server holds their
inventory in memory and will save over this.

The player's inventory must be empty - it refuses to overwrite anything already there. Slots 0-35
become `Inventory` entries, 36-40 the `equipment` compound, and every other byte of the player file
is copied through unchanged. Item compounds are lifted from the death file whole, so enchantments,
damage and every other component survive exactly; the result is re-read and compared stack by stack
against the death file before it is written.

**This does not clear the grave**, which would otherwise hand the same items out a second time. That
is one console command, `setblock <x> <y> <z> air`, and it does not need the player online. The grave
positions are listed in `world/gravestones/<uuid>/data.dat`. See server.md, "Undoing a death while
the server runs", for the whole procedure and for what `gravestones deaths recover` does instead when
the player is online.

**XP and Vanishing-cursed items are not in a death file.** `config/gravestones.json` has
`store_experience: false`, and vanilla destroys a Curse of Vanishing item before Gravestones sees it.
A player's `.dat_old` is their previous autosave and is worth fetching to see what either was.

Written 2026-09-29, when a lightning strike run from the console killed aestanom by accident.
"""

import gzip
import os
import struct
import sys


END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)

_SCALAR = {BYTE: 'b', SHORT: 'h', INT: 'i', LONG: 'q', FLOAT: 'f', DOUBLE: 'd'}


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, n):
        v = self.d[self.p:self.p + n]
        if len(v) != n:
            raise EOFError('ran off the end of the tag')
        self.p += n
        return v

    def num(self, fmt):
        return struct.unpack('>' + fmt, self.take(struct.calcsize('>' + fmt)))[0]

    def string(self):
        return self.take(self.num('H')).decode('utf-8', 'surrogatepass')

    def payload(self, t):
        if t in _SCALAR:
            return self.num(_SCALAR[t])
        if t == STRING:
            return self.string()
        if t == BYTE_ARRAY:
            return self.take(self.num('i'))
        if t == INT_ARRAY:
            return ('int_array', [self.num('i') for _ in range(self.num('i'))])
        if t == LONG_ARRAY:
            return ('long_array', [self.num('q') for _ in range(self.num('i'))])
        if t == LIST:
            et = self.num('b')
            n = self.num('i')
            return ('list', et, [self.payload(et) for _ in range(n)])
        if t == COMPOUND:
            fields = []
            while True:
                ft = self.num('b')
                if ft == END:
                    return ('compound', fields)
                name = self.string()
                fields.append((name, ft, self.payload(ft)))
        raise ValueError('unknown tag type %r' % t)


def write_payload(out, t, v):
    if t in _SCALAR:
        out.append(struct.pack('>' + _SCALAR[t], v))
    elif t == STRING:
        b = v.encode('utf-8', 'surrogatepass')
        out.append(struct.pack('>H', len(b)))
        out.append(b)
    elif t == BYTE_ARRAY:
        out.append(struct.pack('>i', len(v)))
        out.append(bytes(v))
    elif t == INT_ARRAY:
        out.append(struct.pack('>i', len(v[1])))
        out.extend(struct.pack('>i', x) for x in v[1])
    elif t == LONG_ARRAY:
        out.append(struct.pack('>i', len(v[1])))
        out.extend(struct.pack('>q', x) for x in v[1])
    elif t == LIST:
        _, et, items = v
        out.append(struct.pack('>bi', et, len(items)))
        for item in items:
            write_payload(out, et, item)
    elif t == COMPOUND:
        for name, ft, fv in v[1]:
            b = name.encode('utf-8', 'surrogatepass')
            out.append(struct.pack('>b', ft))
            out.append(struct.pack('>H', len(b)))
            out.append(b)
            write_payload(out, ft, fv)
        out.append(b'\x00')
    else:
        raise ValueError('unknown tag type %r' % t)


def read_file(path):
    """Return (root_name, compound payload, the decompressed bytes it came from)."""
    raw = open(path, 'rb').read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    r = Reader(raw)
    t = r.num('b')
    if t != COMPOUND:
        raise ValueError('root tag is not a compound')
    return r.string(), r.payload(COMPOUND), raw


def to_bytes(root_name, root):
    out = [struct.pack('>b', COMPOUND)]
    b = root_name.encode('utf-8', 'surrogatepass')
    out.append(struct.pack('>H', len(b)))
    out.append(b)
    write_payload(out, COMPOUND, root)
    return b''.join(out)


def get(compound, name):
    for n, t, v in compound[1]:
        if n == name:
            return t, v
    return None, None


ARMOUR = {36: 'feet', 37: 'legs', 38: 'chest', 39: 'head', 40: 'offhand'}
# Vanilla's flat inventory indexing: 0-35 main, then feet/legs/chest/head, then offhand.
# Corroborated by the death file itself - slot 36 is boots, 38 an elytra, 39 a helmet.


def save(path, root_name, fields):
    out = to_bytes(root_name, ('compound', fields))
    with open(path, 'wb') as raw:
        # The server writes these gzipped. No embedded filename or mtime, so the same inputs
        # always produce the same bytes and a rerun can be hash-compared against what went up.
        with gzip.GzipFile(fileobj=raw, mode='wb', mtime=0, filename='') as fh:
            fh.write(out)
    return out


def changed_tags(before, after):
    a = {n: (t, v) for n, t, v in before[1]}
    b = {n: (t, v) for n, t, v in after[1]}
    return sorted(set(a) ^ set(b)) + sorted(k for k in set(a) & set(b) if a[k] != b[k])


def do_grave(src, death_path, dst):
    root_name, player, player_raw = read_file(src)
    _, death, _ = read_file(death_path)

    contents = get(death, 'contents')[1]
    stacks = get(get(contents, 'gravestones:inventory')[1], 'inventory')[1][2]

    inv_type, inv = get(player, 'Inventory')
    if inv_type != LIST:
        sys.exit('Inventory is not a list')
    if inv[2]:
        sys.exit('refusing to run: the player already has %d stacks in their inventory' % len(inv[2]))
    if get(player, 'equipment')[0] is not None:
        sys.exit('refusing to run: the player already has equipment')

    main, equipment = [], []
    for entry in stacks:
        slot = get(entry, 'slot')[1]
        item = get(entry, 'item')[1]
        if slot in ARMOUR:
            equipment.append((ARMOUR[slot], COMPOUND, item))
        elif 0 <= slot <= 35:
            main.append(('compound', [('Slot', BYTE, slot)] + item[1]))
        else:
            sys.exit('slot %d is outside the player inventory' % slot)

    fields = []
    for name, t, v in player[1]:
        if name == 'Inventory':
            fields.append((name, LIST, ('list', COMPOUND, main)))
            if equipment:
                fields.append(('equipment', COMPOUND, ('compound', equipment)))
        else:
            fields.append((name, t, v))

    out = save(dst, root_name, fields)

    # Read the result back and prove that only the two tags intended to change have changed.
    _, check, _ = read_file(dst)
    changed = changed_tags(player, check)
    if changed != ['equipment', 'Inventory']:
        sys.exit('unexpected changes: %r' % (changed,))
    new_inv = get(check, 'Inventory')[1][2]
    new_eq = get(check, 'equipment')[1][1]
    if len(new_inv) + len(new_eq) != len(stacks):
        sys.exit('lost stacks: %d + %d != %d' % (len(new_inv), len(new_eq), len(stacks)))
    for entry in stacks:
        slot = get(entry, 'slot')[1]
        item = get(entry, 'item')[1]
        got = get(('compound', new_eq), ARMOUR[slot])[1] if slot in ARMOUR else next(
            (e for e in new_inv if get(e, 'Slot')[1] == slot), None)
        if got is None:
            sys.exit('slot %d did not come back' % slot)
        if slot not in ARMOUR:
            got = ('compound', got[1][1:])
        if got != item:
            sys.exit('slot %d does not match the death file' % slot)

    print('NBT %d -> %d bytes, file %d -> %d bytes' % (len(player_raw), len(out), os.path.getsize(src), os.path.getsize(dst)))
    print('%d stacks in slots 0-35, %d worn: %s' % (len(new_inv), len(new_eq), ', '.join(n for n, _, _ in new_eq)))
    print('every other tag copied through unchanged')


def do_carry(src, older_path, dst, wanted):
    root_name, player, player_raw = read_file(src)
    _, older, _ = read_file(older_path)

    tags, slots = [], []
    for what in wanted:
        if what.startswith('equipment.'):
            slot = what.split('.', 1)[1]
            if slot not in ARMOUR.values():
                sys.exit('%s is not an equipment slot' % what)
            eq_type, eq = get(older, 'equipment')
            if eq_type is None or get(eq, slot)[0] is None:
                sys.exit('the older file has nothing in %s' % what)
            if get(get(player, 'equipment')[1] or ('compound', []), slot)[0] is not None:
                sys.exit('refusing to run: the player already has something in %s' % what)
            slots.append((slot, get(eq, slot)[1]))
        else:
            t, v = get(older, what)
            if t is None:
                sys.exit('the older file has no tag %s' % what)
            tags.append((what, t, v))

    carried = dict((n, (t, v)) for n, t, v in tags)
    fields = []
    for name, t, v in player[1]:
        if name in carried:
            fields.append((name, carried[name][0], carried[name][1]))
        elif name == 'equipment' and slots:
            order = list(ARMOUR.values())
            merged = list(v[1]) + [(s, COMPOUND, item) for s, item in slots]
            merged.sort(key=lambda f: order.index(f[0]))
            fields.append((name, t, ('compound', merged)))
        else:
            fields.append((name, t, v))
    present = set(n for n, _, _ in fields)
    for name, t, v in tags:
        if name not in present:
            fields.append((name, t, v))

    out = save(dst, root_name, fields)

    _, check, _ = read_file(dst)
    expected = sorted(set([n for n, _, _ in tags] + (['equipment'] if slots else [])))
    changed = sorted(changed_tags(player, check))
    if changed != expected:
        sys.exit('unexpected changes: %r, wanted %r' % (changed, expected))
    for name, t, v in tags:
        if get(check, name) != (t, v):
            sys.exit('%s did not carry over' % name)
    for slot, item in slots:
        if get(get(check, 'equipment')[1], slot)[1] != item:
            sys.exit('%s did not carry over' % slot)

    print('NBT %d -> %d bytes, file %d -> %d bytes' % (len(player_raw), len(out), os.path.getsize(src), os.path.getsize(dst)))
    print('carried from the older file: %s' % ', '.join(expected))
    print('every other tag copied through unchanged')


if len(sys.argv) >= 2 and sys.argv[1] == 'carry':
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    do_carry(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
else:
    argv = sys.argv[2:] if len(sys.argv) >= 2 and sys.argv[1] == 'grave' else sys.argv[1:]
    if len(argv) < 3:
        sys.exit(__doc__)
    do_grave(argv[0], argv[1], argv[2])
