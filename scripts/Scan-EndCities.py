"""Find every End City the generator placed, and check whether its blocks are actually there.

Written 2026-09-22 for the malformed End City ships: ships with blocks missing, no elytra, and
empty non-Lootr chests.

Why this and not a two-world diff. A chunk stores the structures that start in it under
`structures.starts`, and each start lists its CHILDREN - one entry per template the generator
decided to place, with the template's name and its bounding box:

    structures.starts["minecraft:end_city"].Children[] -> { id/template: "end_city/ship", BB: [...] }

That is the generator's own record of intent. Comparing it against the blocks that ended up in the
world answers the question directly: **the generator says a ship is here - is it?** A ship whose
bounding box is mostly air was decided on and then lost, which is exactly the reported symptom, and
no second world is needed to see it.

    python Scan-EndCities.py <world dir> [--dim the_end] [--verbose]

Reads only. Safe against a live server's files.
"""
import argparse
import collections
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from importlib.machinery import SourceFileLoader

# Compare-Chunks.py already has a validated NBT reader and region walker. Its name is not a legal
# module name, so it is loaded by path rather than duplicated - a second copy of an NBT parser is
# how the first version of this investigation produced two different wrong answers.
_cc = SourceFileLoader(
    'compare_chunks', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Compare-Chunks.py')
).load_module()

AIR = {'minecraft:air', 'minecraft:cave_air', 'minecraft:void_air'}


def section_lookup(chunk):
    """Return f(x, y, z) -> block name, for absolute world coordinates."""
    sections = {}
    for section in chunk.get('sections', []) or []:
        y = section.get('Y')
        if not isinstance(y, int):
            continue
        bs = section.get('block_states') or {}
        palette = [p.get('Name', '') if isinstance(p, dict) else str(p) for p in (bs.get('palette') or [])]
        if not palette:
            continue
        sections[y] = (palette, bs.get('data') or [])

    def at(x, y, z):
        sec = sections.get(y >> 4)
        if sec is None:
            return None
        palette, data = sec
        if len(palette) == 1:
            # A section with a single palette entry stores no data array at all.
            return palette[0]
        bits = max(4, (len(palette) - 1).bit_length())
        per_long = 64 // bits
        index = (y & 15) * 256 + (z & 15) * 16 + (x & 15)
        which, offset = divmod(index, per_long)
        if which >= len(data):
            return None
        # Entries do not span longs (1.16+), so the high bits of each long are simply unused.
        value = (data[which] >> (offset * bits)) & ((1 << bits) - 1)
        return palette[value] if value < len(palette) else None

    return at


def starts(chunk):
    """Yield (structure id, children list) for structures starting in this chunk."""
    st = chunk.get('structures') or chunk.get('Structures') or {}
    for sid, start in (st.get('starts') or st.get('Starts') or {}).items():
        if not isinstance(start, dict):
            continue
        children = start.get('Children') or start.get('children') or []
        if children:
            yield sid, children


def piece_name(child):
    for key in ('template', 'Template', 'id', 'ID'):
        v = child.get(key)
        if isinstance(v, str):
            return v
    return '?'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('world')
    ap.add_argument('--dim', default='the_end')
    ap.add_argument('--structure', default='minecraft:end_city')
    ap.add_argument('--samples', type=int, default=400,
                    help='blocks sampled per piece bounding box')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    region_root = None
    for root, _dirs, _files in os.walk(args.world):
        if root.replace(os.sep, '/').endswith(f'{args.dim}/region'):
            region_root = root
            break
    if region_root is None:
        print(f'no {args.dim}/region folder under {args.world} - that dimension was never generated')
        return 2

    # Blocks are read from whichever chunk holds them, so every chunk is indexed first. A piece
    # bounding box routinely crosses chunks, and a scan that only looked inside the start chunk
    # would report every large piece as missing.
    grid = {}
    found = []
    for name in sorted(os.listdir(region_root)):
        if not name.endswith('.mca'):
            continue
        for _lx, _lz, chunk in _cc.chunks(os.path.join(region_root, name)):
            pos = chunk.get('xPos'), chunk.get('zPos')
            if isinstance(pos[0], int) and isinstance(pos[1], int):
                grid[pos] = chunk
            for sid, children in starts(chunk):
                if sid == args.structure:
                    found.append((pos, children))

    lookups = {}

    def block_at(x, y, z):
        key = (x >> 4, z >> 4)
        if key not in lookups:
            chunk = grid.get(key)
            lookups[key] = section_lookup(chunk) if chunk is not None else (lambda *_a: None)
        return lookups[key](x, y, z)

    print(f'world      {args.world}')
    print(f'dimension  {args.dim}')
    print(f'chunks     {len(grid)}')
    print(f'{args.structure} starts: {len(found)}')
    print()

    if not found:
        print('Nothing to check. Generate further out - End Cities only exist on the outer islands.')
        return 0

    per_template = collections.Counter()
    damaged = []
    for pos, children in sorted(found):
        rows = []
        for child in children:
            if not isinstance(child, dict):
                continue
            bb = child.get('BB') or child.get('bb')
            name = piece_name(child)
            per_template[name] += 1
            if not (isinstance(bb, list) and len(bb) == 6):
                rows.append((name, None, None))
                continue
            x0, y0, z0, x1, y1, z1 = bb
            span = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
            step = max(1, int(round((span / max(1, args.samples)) ** (1 / 3))))
            solid = total = missing_chunks = 0
            for x in range(x0, x1 + 1, step):
                for y in range(y0, y1 + 1, step):
                    for z in range(z0, z1 + 1, step):
                        b = block_at(x, y, z)
                        total += 1
                        if b is None:
                            missing_chunks += 1
                        elif b not in AIR:
                            solid += 1
            # A bounding box that is entirely outside the generated area tells us nothing; only a
            # box whose chunks EXIST and are empty is evidence of a piece that went missing.
            ungenerated = total and missing_chunks / total > 0.5
            rows.append((name, None if ungenerated else (solid / total if total else 0.0), span))

        ship = [r for r in rows if 'ship' in r[0]]
        known = [r for r in rows if r[1] is not None]
        label = f'city at chunk {pos[0]},{pos[1]}  pieces={len(rows)}'
        flag = ''
        if ship:
            fill = ship[0][1]
            if fill is None:
                flag = '  ship: NOT GENERATED YET (outside the loaded area)'
            elif fill < 0.05:
                flag = f'  ship: MISSING - bounding box is {100 * (1 - fill):.0f}% air'
                damaged.append((pos, 'ship absent', fill))
            elif fill < 0.25:
                flag = f'  ship: PARTIAL - only {100 * fill:.0f}% of its box is solid'
                damaged.append((pos, 'ship partial', fill))
            else:
                flag = f'  ship: present ({100 * fill:.0f}% solid)'
        else:
            flag = '  no ship piece was placed (normal - not every city has one)'
        print(label + flag)
        if args.verbose:
            for name, fill, span in rows:
                shown = 'ungenerated' if fill is None else f'{100 * fill:5.1f}% solid'
                print(f'    {name:38s} {shown}  volume={span}')
        # An empty-but-generated piece anywhere in the city is the same fault as an empty ship, so
        # it is counted even when the ship itself is fine.
        for name, fill, _span in rows:
            if fill is not None and fill < 0.02 and 'ship' not in name:
                damaged.append((pos, f'{name} empty', fill))

    print()
    print('pieces placed by template')
    for name, count in per_template.most_common():
        print(f'  {count:4d}  {name}')
    print()
    if damaged:
        print(f'VERDICT: {len(damaged)} piece(s) the generator placed are not in the world.')
        for pos, why, fill in damaged[:20]:
            print(f'  chunk {pos[0]},{pos[1]}  {why}  ({100 * fill:.1f}% solid)')
    else:
        print('VERDICT: every piece the generator recorded is present in the world.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
