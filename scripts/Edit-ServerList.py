"""Add or remove one server in a servers.dat, the multiplayer server list.

    python Edit-ServerList.py <servers.dat in> <servers.dat out> add "<name>" <ip:port>
    python Edit-ServerList.py <servers.dat in> <servers.dat out> remove <ip:port>

servers.dat is uncompressed NBT: a root compound holding `servers`, a list of compounds with
`name`, `ip`, an optional base64 `icon`, `acceptTextures` and `hidden`. `add` appends one entry
carrying the first entry's icon (the pack's own), or nothing is changed when the ip is already
listed. `remove` drops every entry with that ip. Every other byte is written back as read.

Written for v1.0.88, when the pack gained a second server (Vanilla+ Hardcore): the shipped list
in `3. modpack\\client\\servers.dat` gets the entry with `add`, and Test-LocalSync uses `remove` to
give its fresh instance the old one-server list so the updater's own seed is what puts the entry
back. The updater's seed does the same thing in Java (ServerListSeed in Nbidal18PackwizSync.java).
"""
import io
import struct
import sys

END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, fmt):
        value = struct.unpack_from('>' + fmt, self.data, self.pos)[0]
        self.pos += struct.calcsize('>' + fmt)
        return value

    def string(self):
        n = self.take('H')
        s = self.data[self.pos:self.pos + n]
        self.pos += n
        return s  # kept as bytes: Java's modified UTF-8 must round-trip untouched

    def payload(self, t):
        if t == BYTE: return ('b', self.take('b'))
        if t == SHORT: return ('h', self.take('h'))
        if t == INT: return ('i', self.take('i'))
        if t == LONG: return ('q', self.take('q'))
        if t == FLOAT: return ('f', self.take('f'))
        if t == DOUBLE: return ('d', self.take('d'))
        if t == BYTE_ARRAY:
            n = self.take('i'); v = self.data[self.pos:self.pos + n]; self.pos += n; return ('ba', v)
        if t == STRING: return ('s', self.string())
        if t == LIST:
            et = self.take('b'); n = self.take('i')
            return ('list', et, [self.payload(et) for _ in range(n)])
        if t == COMPOUND:
            out = []
            while True:
                et = self.take('b')
                if et == END:
                    return ('compound', out)
                name = self.string()
                out.append((name, self.payload(et)))
        if t == INT_ARRAY:
            n = self.take('i'); v = list(struct.unpack_from('>%di' % n, self.data, self.pos)); self.pos += 4 * n; return ('ia', v)
        if t == LONG_ARRAY:
            n = self.take('i'); v = list(struct.unpack_from('>%dq' % n, self.data, self.pos)); self.pos += 8 * n; return ('la', v)
        raise SystemExit('unknown tag %d' % t)


TYPE_OF = {'b': BYTE, 'h': SHORT, 'i': INT, 'q': LONG, 'f': FLOAT, 'd': DOUBLE, 'ba': BYTE_ARRAY, 's': STRING,
           'list': LIST, 'compound': COMPOUND, 'ia': INT_ARRAY, 'la': LONG_ARRAY}


def write_payload(out, value):
    kind = value[0]
    if kind in ('b', 'h', 'i', 'q', 'f', 'd'):
        out.write(struct.pack('>' + kind, value[1]))
    elif kind == 'ba':
        out.write(struct.pack('>i', len(value[1]))); out.write(value[1])
    elif kind == 's':
        out.write(struct.pack('>H', len(value[1]))); out.write(value[1])
    elif kind == 'list':
        out.write(struct.pack('>bi', value[1], len(value[2])))
        for item in value[2]:
            write_payload(out, item)
    elif kind == 'compound':
        for name, item in value[1]:
            out.write(struct.pack('>b', TYPE_OF[item[0]])); out.write(struct.pack('>H', len(name))); out.write(name)
            write_payload(out, item)
        out.write(b'\x00')
    elif kind == 'ia':
        out.write(struct.pack('>i', len(value[1]))); out.write(struct.pack('>%di' % len(value[1]), *value[1]))
    elif kind == 'la':
        out.write(struct.pack('>i', len(value[1]))); out.write(struct.pack('>%dq' % len(value[1]), *value[1]))


def utf(s):
    return s.encode('utf-8')


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    src, dst, verb = sys.argv[1:4]
    data = io.open(src, 'rb').read()
    if data[:2] == b'\x1f\x8b':
        raise SystemExit('servers.dat is gzip-compressed, which vanilla never writes')
    reader = Reader(data)
    assert reader.take('b') == COMPOUND, 'root is not a compound'
    reader.string()
    root = reader.payload(COMPOUND)
    assert reader.pos == len(data), 'trailing bytes'
    entries = dict(root[1])
    servers = entries.get(utf('servers'))
    if servers is None:
        servers = ('list', COMPOUND, [])
        root[1].append((utf('servers'), servers))
    assert servers[0] == 'list' and (servers[1] == COMPOUND or not servers[2]), 'servers is not a list of servers'
    items = servers[2]

    def ip_of(entry):
        return dict(entry[1]).get(utf('ip'), ('s', b''))[1].decode('utf-8', 'replace')

    if verb == 'add':
        name, ip = sys.argv[4], sys.argv[5]
        if any(ip_of(e) == ip for e in items):
            print('unchanged %s already listed' % ip)
        else:
            entry = []
            first = dict(items[0][1]) if items else {}
            if utf('icon') in first:
                entry.append((utf('icon'), first[utf('icon')]))
            entry += [(utf('name'), ('s', utf(name))), (utf('ip'), ('s', utf(ip))),
                      (utf('acceptTextures'), ('b', 1)), (utf('hidden'), ('b', 0))]
            items.append(('compound', entry))
            servers = ('list', COMPOUND, items)
            root[1][[i for i, (n, _) in enumerate(root[1]) if n == utf('servers')][0]] = (utf('servers'), servers)
            print('added     %s (%s)%s' % (name, ip, ', with the first entry\'s icon' if entry[0][0] == utf('icon') else ''))
    elif verb == 'remove':
        ip = sys.argv[4]
        before = len(items)
        items[:] = [e for e in items if ip_of(e) != ip]
        print('removed   %d entries with ip %s' % (before - len(items), ip))
    else:
        raise SystemExit('verb must be add or remove')

    out = io.BytesIO()
    out.write(struct.pack('>bH', COMPOUND, 0))
    write_payload(out, root)
    io.open(dst, 'wb').write(out.getvalue())
    print('wrote     %s (%d bytes, %d servers)' % (dst, len(out.getvalue()), len(items)))


if __name__ == '__main__':
    main()
