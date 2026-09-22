"""Switch a world's End generator to BetterX, by copying the entry from a world that already works.

    python Set-EndGenerator.py <target wover-generator.nbt> <source wover-generator.nbt>
    python Set-EndGenerator.py <target> --show

**What decides a world's End generator.** Not `level-type`, and not the world type screen after the
world exists. WorldWeaver writes `<world>/data/wover-generator.nbt` when the world is created and
reads it back at every load: `WorldGeneratorConfigImpl.loadWorldDimensions` checks the tag for a
`dimensions` key and, when it is there, parses it with a Codec into the dimension -> ChunkGenerator
map. Only when it is absent does it fall back to `WorldPresetManager.getDefault()`. So that sub-tag
is a directive, not a record, and editing it is how an existing world changes its End.

**Why copy rather than construct.** The entry has to satisfy the LevelStem codec exactly. Rather than
hand-building one and hoping, this lifts `preset.dimensions["minecraft:the_end"]` wholesale out of a
world that is demonstrably generating Better End biomes - the live Vanilla+ server - and drops it into
the target. Known-good bytes beat a plausible guess.

**Only the End is touched.** The Nether entry is deliberately left alone: the hardcore world's Nether
is already generated and full of Incendium biomes, and switching its biome source would leave a
permanent seam at the edge of what players have already explored. The End is safe to switch only
because its region folder is being reset in the same outage.

`preset.world_presets` is also left alone. It is not what `loadWorldDimensions` reads - the `dimensions`
tag is - and rewriting one half of a record whose other half still describes the vanilla overworld and
Nether would make the file say something less true than it does now, not more.
"""
import gzip
import struct
import sys

END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)


class Tag:
    """An NBT value that remembers its type, so it can be written back unchanged."""

    __slots__ = ('type', 'value')

    def __init__(self, type_, value):
        self.type = type_
        self.value = value

    def __repr__(self):
        return 'Tag(%d, %r)' % (self.type, self.value)


class Reader:
    def __init__(self, data):
        self.b, self.p = data, 0

    def u(self, fmt):
        v = struct.unpack_from('>' + fmt, self.b, self.p)[0]
        self.p += struct.calcsize('>' + fmt)
        return v

    def string(self):
        n = self.u('H')
        v = self.b[self.p:self.p + n].decode('utf-8')
        self.p += n
        return v

    def payload(self, t):
        if t == BYTE:
            return self.u('b')
        if t == SHORT:
            return self.u('h')
        if t == INT:
            return self.u('i')
        if t == LONG:
            return self.u('q')
        if t == FLOAT:
            return self.u('f')
        if t == DOUBLE:
            return self.u('d')
        if t == BYTE_ARRAY:
            n = self.u('i')
            v = self.b[self.p:self.p + n]
            self.p += n
            return v
        if t == STRING:
            return self.string()
        if t == LIST:
            item = self.u('b')
            n = self.u('i')
            return (item, [self.payload(item) for _ in range(n)])
        if t == COMPOUND:
            out = {}
            while True:
                tt = self.u('b')
                if tt == END:
                    return out
                # Name first, into a variable. Written inline, Python evaluates the payload before
                # the subscript and the stream desyncs - the same trap that once silently dropped
                # 217 of 228 chunks in Compare-Chunks.py.
                key = self.string()
                out[key] = Tag(tt, self.payload(tt))
        if t == INT_ARRAY:
            return [self.u('i') for _ in range(self.u('i'))]
        if t == LONG_ARRAY:
            return [self.u('q') for _ in range(self.u('i'))]
        raise ValueError('unknown tag type %d' % t)


class Writer:
    def __init__(self):
        self.out = bytearray()

    def p(self, fmt, v):
        self.out += struct.pack('>' + fmt, v)

    def string(self, s):
        raw = s.encode('utf-8')
        self.p('H', len(raw))
        self.out += raw

    def payload(self, t, v):
        if t == BYTE:
            self.p('b', v)
        elif t == SHORT:
            self.p('h', v)
        elif t == INT:
            self.p('i', v)
        elif t == LONG:
            self.p('q', v)
        elif t == FLOAT:
            self.p('f', v)
        elif t == DOUBLE:
            self.p('d', v)
        elif t == BYTE_ARRAY:
            self.p('i', len(v))
            self.out += v
        elif t == STRING:
            self.string(v)
        elif t == LIST:
            item, items = v
            self.p('b', item)
            self.p('i', len(items))
            for x in items:
                self.payload(item, x)
        elif t == COMPOUND:
            for key, tag in v.items():
                self.p('b', tag.type)
                self.string(key)
                self.payload(tag.type, tag.value)
            self.p('b', END)
        elif t == INT_ARRAY:
            self.p('i', len(v))
            for x in v:
                self.p('i', x)
        elif t == LONG_ARRAY:
            self.p('i', len(v))
            for x in v:
                self.p('q', x)
        else:
            raise ValueError('unknown tag type %d' % t)


def read_file(path):
    raw = open(path, 'rb').read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    r = Reader(raw)
    t = r.u('b')
    name = r.string()
    return name, Tag(t, r.payload(t))


def write_file(path, name, root, compressed=True):
    w = Writer()
    w.p('b', root.type)
    w.string(name)
    w.payload(root.type, root.value)
    data = bytes(w.out)
    # mtime=0 so a rewrite of identical content is byte-identical, the way every build here pins
    # archive timestamps.
    open(path, 'wb').write(gzip.compress(data, mtime=0) if compressed else data)


def describe(root, label):
    preset = root.value.get('preset')
    if preset is None:
        return '%s: no "preset" tag' % label
    dims = preset.value.get('dimensions')
    if dims is None:
        return '%s: no "dimensions" tag - this world falls back to WorldPresetManager.getDefault()' % label
    lines = ['%s:' % label]
    for key in sorted(dims.value):
        # The dimension entry IS the generator - `type`, `biome_source` and `settings` sit directly
        # on it. There is no nested "generator" compound, unlike the dimension JSON a mod ships.
        gen = dims.value[key].value
        gtype = gen['type'].value if 'type' in gen else '?'
        settings = gen['settings'].value if 'settings' in gen else '?'
        bsrc = gen.get('biome_source')
        btype = bsrc.value['type'].value if bsrc and 'type' in bsrc.value else '?'
        bpreset = bsrc.value['preset'].value if bsrc and 'preset' in bsrc.value else ''
        lines.append('    %-22s %-16s %-30s %s' % (
            key, gtype, btype + (' (' + bpreset + ')' if bpreset else ''), settings))
    return '\n'.join(lines)


def main(argv):
    target = argv[1]
    name, root = read_file(target)

    if len(argv) > 2 and argv[2] == '--show':
        print(describe(root, target))
        return 0

    source = argv[2]
    _sname, sroot = read_file(source)

    print(describe(root, 'BEFORE  ' + target))
    print()
    print(describe(sroot, 'SOURCE  ' + source))
    print()

    sdims = sroot.value['preset'].value['dimensions'].value
    tdims = root.value['preset'].value['dimensions'].value
    key = 'minecraft:the_end'
    if key not in sdims:
        raise SystemExit('the source world has no %s entry' % key)
    if key not in tdims:
        raise SystemExit('the target world has no %s entry' % key)
    tdims[key] = sdims[key]

    write_file(target, name, root)

    # Read the file back off disk rather than trusting the in-memory object: this is the only
    # evidence that what was written parses.
    _rname, again = read_file(target)
    print(describe(again, 'AFTER   ' + target))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
