"""Edit one or more values in a world's level.dat and write the result to another file.

    python Edit-LevelData.py <level.dat in> <level.dat out> key=value [key=value ...]

Keys are entries of the Data compound, dotted to reach nested compounds: 26.2 keeps the hardcore
flag at `difficulty_settings.hardcore` (it was a top-level `hardcore` before). The value is coerced
to the tag's existing type: a Byte takes 0/1 or false/true, an Int an integer, a String a string.
A key that is not present is an error, so a typo cannot create a stray tag, and the tag's type is
never changed.

The file is read and written as gzip-compressed NBT, every tag preserved byte for byte except the
ones named. Written for v1.0.72, when the world went from hardcore back to normal survival: the
`hardcore` flag lives in level.dat, not in server.properties, and nothing in this repository could
change it without a hand edit over SFTP. Test-ServerDeployment plans the edit with -SetLevelData;
Deploy-LiveServer applies it here to the copy it fetches after the shutdown, because the server
rewrites level.dat as it stops.
"""
import gzip
import io
import struct
import sys

END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, fmt):
        v = struct.unpack_from('>' + fmt, self.d, self.p)[0]
        self.p += struct.calcsize('>' + fmt)
        return v

    def name(self):
        n = self.take('H')
        s = self.d[self.p:self.p + n]
        self.p += n
        return s

    def payload(self, t):
        if t == BYTE:
            return self.take('b')
        if t == SHORT:
            return self.take('h')
        if t == INT:
            return self.take('i')
        if t == LONG:
            return self.take('q')
        if t == FLOAT:
            return self.take('f')
        if t == DOUBLE:
            return self.take('d')
        if t == BYTE_ARRAY:
            n = self.take('i')
            v = self.d[self.p:self.p + n]
            self.p += n
            return bytes(v)
        if t == STRING:
            return self.name()
        if t == LIST:
            et = self.take('b')
            n = self.take('i')
            return (et, [self.payload(et) for _ in range(n)])
        if t == COMPOUND:
            out = []
            while True:
                et = self.take('b')
                if et == END:
                    return out
                out.append((et, self.name(), self.payload(et)))
        if t == INT_ARRAY:
            n = self.take('i')
            return ('i', [self.take('i') for _ in range(n)])
        if t == LONG_ARRAY:
            n = self.take('i')
            return ('q', [self.take('q') for _ in range(n)])
        raise ValueError('unknown tag type %d at %d' % (t, self.p))


class Writer:
    def __init__(self):
        self.b = bytearray()

    def put(self, fmt, v):
        self.b += struct.pack('>' + fmt, v)

    def name(self, s):
        self.put('H', len(s))
        self.b += s

    def payload(self, t, v):
        if t == BYTE:
            self.put('b', v)
        elif t == SHORT:
            self.put('h', v)
        elif t == INT:
            self.put('i', v)
        elif t == LONG:
            self.put('q', v)
        elif t == FLOAT:
            self.put('f', v)
        elif t == DOUBLE:
            self.put('d', v)
        elif t == BYTE_ARRAY:
            self.put('i', len(v))
            self.b += v
        elif t == STRING:
            self.name(v)
        elif t == LIST:
            et, items = v
            self.put('b', et)
            self.put('i', len(items))
            for item in items:
                self.payload(et, item)
        elif t == COMPOUND:
            for et, n, item in v:
                self.put('b', et)
                self.name(n)
                self.payload(et, item)
            self.put('b', END)
        elif t in (INT_ARRAY, LONG_ARRAY):
            fmt, items = v
            self.put('i', len(items))
            for item in items:
                self.put(fmt, item)
        else:
            raise ValueError('unknown tag type %d' % t)


def coerce(t, text, key):
    if t == BYTE:
        low = text.lower()
        if low in ('true', '1'):
            return 1
        if low in ('false', '0'):
            return 0
        raise SystemExit('%s is a Byte; give true/false or 1/0, not %r' % (key, text))
    if t in (SHORT, INT, LONG):
        return int(text)
    if t in (FLOAT, DOUBLE):
        return float(text)
    if t == STRING:
        return text.encode('utf-8')
    raise SystemExit('%s is a tag of type %d, which this tool does not edit' % (key, t))


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    src, dst, edits = sys.argv[1], sys.argv[2], sys.argv[3:]
    raw = gzip.decompress(io.open(src, 'rb').read())
    r = Reader(raw)
    root_type = r.take('b')
    root_name = r.name()
    root = r.payload(root_type)
    if r.p != len(raw):
        raise SystemExit('trailing bytes after the root compound - not touching this file')
    data = None
    for et, n, item in root:
        if n == b'Data' and et == COMPOUND:
            data = item
    if data is None:
        raise SystemExit('no Data compound in ' + src)
    for edit in edits:
        key, _, value = edit.partition('=')
        # Dotted keys walk nested compounds: 26.2 keeps the flag at Data/difficulty_settings/hardcore.
        parts = key.split('.')
        holder = data
        for part in parts[:-1]:
            nxt = None
            for et, n, item in holder:
                if n == part.encode('utf-8') and et == COMPOUND:
                    nxt = item
            if nxt is None:
                raise SystemExit('Data has no compound %r on the way to %r - nothing written' % (part, key))
            holder = nxt
        leaf = parts[-1]
        found = False
        for i, (et, n, item) in enumerate(holder):
            if n == leaf.encode('utf-8'):
                new = coerce(et, value, key)
                print('%-32s %r -> %r' % (key, item, new))
                holder[i] = (et, n, new)
                found = True
        if not found:
            raise SystemExit('Data has no key %r - nothing written' % key)
    w = Writer()
    w.put('b', root_type)
    w.name(root_name)
    w.payload(root_type, root)
    # Re-read our own output before trusting it: the tree must round-trip to the same edited values.
    check = Reader(bytes(w.b))
    check.take('b')
    check.name()
    check.payload(root_type)
    if check.p != len(w.b):
        raise SystemExit('the rewritten NBT does not parse cleanly - nothing written')
    with gzip.open(dst, 'wb', compresslevel=6) as fh:
        fh.write(bytes(w.b))
    print('wrote     %s (%d bytes uncompressed)' % (dst, len(w.b)))


if __name__ == '__main__':
    main()
