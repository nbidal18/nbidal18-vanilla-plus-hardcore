"""Compare two generated worlds by BLOCK DATA, ignoring the fields that always differ.

A region file is not a fair comparison on its own. Every chunk carries `LastUpdate` and
`InhabitedTime`, which are tick counters, so two runs of the same seed produce different bytes even
when the terrain is identical. Test-WorldgenParity's first result - "1 of 4 region files differ" -
could have been nothing but that, and saying otherwise would have been a false alarm.

This decodes each chunk and digests only what worldgen decides:

    sections[].block_states.palette   which blocks exist in each 16-block section
    sections[].block_states.data      which block sits in each position
    Status                            how far generation got

    python Compare-Chunks.py <world A> <world B>

Ignored on purpose: LastUpdate, InhabitedTime, block entity contents, heightmaps and light, all of
which vary with when and how the chunk was saved rather than with what was generated.
"""
import collections, gzip, io, json, os, re, struct, sys, zlib, hashlib

END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)


class R:
    def __init__(self, b): self.b, self.p = b, 0
    def u(self, f):
        v = struct.unpack_from('>' + f, self.b, self.p)[0]
        self.p += struct.calcsize('>' + f); return v
    def s(self):
        n = self.u('H'); v = self.b[self.p:self.p + n].decode('utf-8', 'replace'); self.p += n; return v
    def payload(self, t):
        if t == BYTE: return self.u('b')
        if t == SHORT: return self.u('h')
        if t == INT: return self.u('i')
        if t == LONG: return self.u('q')
        if t == FLOAT: return self.u('f')
        if t == DOUBLE: return self.u('d')
        if t == BYTE_ARRAY:
            n = self.u('i'); v = self.b[self.p:self.p + n]; self.p += n; return v
        if t == STRING: return self.s()
        if t == LIST:
            it = self.u('b'); n = self.u('i')
            return [self.payload(it) for _ in range(n)]
        if t == COMPOUND:
            out = {}
            while True:
                tt = self.u('b')
                if tt == END: return out
                # The name MUST be read into a variable first. Written as
                # `out[self.s()] = self.payload(tt)` Python evaluates the right-hand side before
                # the subscript, so the payload is read before the name and the stream desyncs -
                # which silently dropped 217 of 228 chunks and made two comparisons meaningless.
                key = self.s()
                out[key] = self.payload(tt)
        if t == INT_ARRAY:
            n = self.u('i'); v = [self.u('i') for _ in range(n)]; return v
        if t == LONG_ARRAY:
            n = self.u('i'); v = [self.u('q') for _ in range(n)]; return v
        raise ValueError(f'tag {t}')


def read_nbt(raw):
    r = R(raw)
    t = r.u('b')
    if t == END: return {}
    r.s()
    return r.payload(t)


def chunks(path):
    """Yield (x, z, chunk compound) for every chunk stored in a region file."""
    # A region file with no chunks in it is zero bytes on disk, and the server writes several.
    if os.path.getsize(path) < 8192:
        return
    with open(path, 'rb') as fh:
        header = fh.read(4096)
        fh.read(4096)
        body = fh.read()
    for i in range(1024):
        off, count = struct.unpack_from('>I', header, i * 4)[0] >> 8, header[i * 4 + 3]
        if not off or not count: continue
        start = off * 4096 - 8192
        if start < 0 or start + 5 > len(body): continue
        length = struct.unpack_from('>I', body, start)[0]
        scheme = body[start + 4]
        data = body[start + 5:start + 4 + length]
        try:
            if scheme == 1: raw = gzip.decompress(data)
            elif scheme == 2: raw = zlib.decompress(data)
            elif scheme == 3: raw = data
            else: continue
            yield i % 32, i // 32, read_nbt(raw)
        except Exception:
            continue


def digest(chunk):
    """A hash of only what worldgen decides."""
    h = hashlib.sha256()
    h.update(str(chunk.get('Status', '')).encode())
    for section in chunk.get('sections', []) or []:
        bs = section.get('block_states') or {}
        palette = [p.get('Name', '') if isinstance(p, dict) else str(p)
                   for p in (bs.get('palette') or [])]
        h.update(('|'.join(palette)).encode())
        h.update(struct.pack('>i', section.get('Y', 0) if isinstance(section.get('Y'), int) else 0))
        for v in (bs.get('data') or []):
            h.update(struct.pack('>q', v))
    return h.hexdigest()


def load(world):
    out = {}
    for root, _dirs, files in os.walk(world):
        if not root.endswith('region'): continue
        for name in files:
            if not name.endswith('.mca'): continue
            dim = os.path.relpath(root, world).replace(os.sep, '/')
            for x, z, chunk in chunks(os.path.join(root, name)):
                out[f'{dim}/{name}#{x},{z}'] = digest(chunk)
    return out


def abs_chunk(key):
    """Absolute chunk coordinates from a `<dim>/r.X.Z.mca#lx,lz` key."""
    m = re.search(r'r\.(-?\d+)\.(-?\d+)\.mca#(\d+),(\d+)', key)
    rx, rz, lx, lz = (int(g) for g in m.groups())
    return rx * 32 + lx, rz * 32 + lz


def ring_table(same, diff):
    """Differences by distance from spawn.

    This is the check that overturned four earlier results. A server holds a ring of chunks loaded
    and TICKING after it generates them, and a ticking chunk keeps changing blocks - grass, water,
    fire, mobs - so two runs of an identical mod set diverge there no matter what worldgen did. The
    signature is unmistakable once plotted: heavy disagreement inside the loaded radius and a hard
    edge to zero outside it. A real worldgen difference has no such edge.
    """
    d = collections.Counter(max(abs(x), abs(z)) for x, z in map(abs_chunk, diff))
    s = collections.Counter(max(abs(x), abs(z)) for x, z in map(abs_chunk, same))
    rings = sorted(set(d) | set(s))
    print('  radius   differ   same')
    for r in rings:
        print(f'  {r:6d} {d.get(r, 0):8d} {s.get(r, 0):6d}')
    outer = [r for r in rings if d.get(r, 0)]
    if outer and max(outer) < max(rings):
        beyond = sum(s.get(r, 0) for r in rings if r > max(outer))
        print()
        print(f'  NOTE: every difference is within radius {max(outer)}; all {beyond}')
        print('  chunks beyond it are identical. That edge is the loaded/ticking ring, not worldgen.')


def main(a, b):
    A, B = load(a), load(b)
    keys = sorted(set(A) | set(B))
    same = [k for k in keys if A.get(k) == B.get(k) and k in A and k in B]
    diff = [k for k in keys if k in A and k in B and A[k] != B[k]]
    only = [k for k in keys if (k in A) != (k in B)]
    both = len(same) + len(diff)
    print(f'chunks in both runs : {both}')
    print(f'  identical         : {len(same)}')
    print(f'  DIFFERENT         : {len(diff)}')
    print(f'chunks in one run   : {len(only)}   (generation reached different distances - NOT evidence)')
    for k in diff[:15]: print('    differs:', k)
    for k in only[:8]: print('    only in one:', k)
    print()
    if diff and same:
        ring_table(same, diff)
        print()
    # A chunk present on one side only says nothing about worldgen: the runs are time-bounded, and a
    # faster run simply gets further before the save. Treating that as a difference is what made an
    # earlier run of this script report a change that was not there. Only chunks BOTH runs generated
    # are evidence either way.
    if diff:
        print(f'VERDICT: the withheld mod CHANGES generated block data - {len(diff)} of {both} shared chunks differ.')
    elif both == 0:
        print('VERDICT: INCONCLUSIVE - no chunk was generated by both runs. Nothing was compared.')
    else:
        print(f'VERDICT: no difference. All {both} chunks generated by BOTH runs are byte-identical')
        print('         in block data. Chunks present on only one side are a generation-distance')
        print('         artefact and are not counted.')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
