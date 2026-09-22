"""Undo a death on the hardcore server, offline: player file, scoreboard, statistics, graves, world.

    python Edit-PlayerRevive.py player  <in.dat> <out.dat> [--survival] [--pos X Y Z] [--offhand ITEM]
                                         [--remove-key KEY ...] [--remove-tag TAG ...]
    python Edit-PlayerRevive.py scores  <scoreboard.dat in> <out> <holder> OBJECTIVE=VALUE|OBJECTIVE=- [...]
    python Edit-PlayerRevive.py stats   <stats.json in> <out> STAT=VALUE | CATEGORY/STAT=VALUE [...]
    python Edit-PlayerRevive.py advancements <advancements.json in> <out> ADVANCEMENT_ID [...]
    python Edit-PlayerRevive.py history <gravestones/<uuid>/data.dat in> <out>
    python Edit-PlayerRevive.py remove  <any .dat in> <out> path/to/key
    python Edit-PlayerRevive.py entities <entities r.X.Z.mca in> <out> <x> <y> <z> <radius> <id[#tag]> [...]

player   - --survival sets playerGameType 0; --pos moves; --offhand puts one item into an EMPTY offhand
           (`equipment.offhand`); --remove-key drops a top-level tag (e.g. LastDeathLocation);
           --remove-tag drops one entry from Tags. Nothing else in the file changes.
scores   - sets a holder's score on each objective (adding the Score tag when a 0 score has none), or
           with `-` removes the holder's entry on that objective entirely - which is not the same as 0
           for anything that tests whether a score exists. Holder is a player name or an entity UUID.
           Refuses an objective the holder has no entry for.
stats    - sets `minecraft:custom` statistics, e.g. minecraft:deaths=0.
history  - empties Gravestones' list of a player's grave positions.
entities - removes the entities of the given id (optionally carrying a tag, `id#tag`) within the radius of
           x y z from an entity region file, rewriting only the chunks that change. Prints each removed
           entity's UUID, so a scoreboard entry held by it can be removed with `scores`.

Byte-splice: fixed-size values are overwritten in place, removed tags and list elements are cut out with
their list's count adjusted, new tags are inserted at the end of their compound, and every other byte is
copied through. Each subcommand re-parses its output and checks that exactly the intended values changed
before writing it.

Written 2026-09-15 when the owner starved to death on the hardcore server with the autopilot flying him
(see server.md, "Reviving a hardcore player"). The server must be stopped: it writes all of these at
logout, on autosave and at shutdown, over whatever was uploaded.
"""
import gzip
import json
import math
import re
import struct
import sys
import time
import zlib


# ------------------------------------------------------------------------------------------ parsing
class Node:
    __slots__ = ('type', 'name', 'start', 'payload', 'end', 'children', 'value')

    def __init__(self, type_, name, start, payload):
        self.type, self.name, self.start, self.payload = type_, name, start, payload
        self.end = None
        self.children = []
        self.value = None


def parse(data):
    pos = 0

    def u(fmt):
        nonlocal pos
        v = struct.unpack_from('>' + fmt, data, pos)[0]
        pos += struct.calcsize('>' + fmt)
        return v

    def s():
        nonlocal pos
        n = u('H')
        v = data[pos:pos + n].decode('utf-8')
        pos += n
        return v

    def body(node):
        nonlocal pos
        t = node.type
        sizes = {1: 'b', 2: 'h', 3: 'i', 4: 'q', 5: 'f', 6: 'd'}
        if t in sizes:
            node.value = u(sizes[t])
        elif t == 7:
            n = u('i'); pos += n
        elif t == 8:
            node.value = s()
        elif t == 9:
            et = u('b'); n = u('i')
            for i in range(n):
                c = Node(et, str(i), pos, pos)
                body(c)
                node.children.append(c)
        elif t == 10:
            while True:
                ct = data[pos]
                if ct == 0:
                    node.value = pos          # offset of this compound's TAG_End
                    pos += 1
                    break
                start = pos
                pos += 1
                name = s()
                c = Node(ct, name, start, pos)
                body(c)
                node.children.append(c)
        elif t == 11:
            n = u('i'); node.value = [u('i') for _ in range(n)]
        elif t == 12:
            n = u('i'); pos += 8 * n
        else:
            raise ValueError('unknown tag %d at %d' % (t, pos))
        node.end = pos

    root_type = u('b')
    s()
    root = Node(root_type, '', 0, pos)
    body(root)
    assert pos == len(data), 'trailing bytes after the root tag'
    return root


def child(node, name):
    for c in node.children:
        if c.name == name:
            return c
    return None


def plain(node):
    """The tree as Python values, for comparing a file before and after."""
    if node.type == 10:
        return {c.name: plain(c) for c in node.children}
    if node.type == 9:
        return [plain(c) for c in node.children]
    return node.value


# ------------------------------------------------------------------------------------------ writing
def w_str(v):
    b = v.encode('utf-8')
    return struct.pack('>H', len(b)) + b


def tag(type_, name, payload):
    return bytes([type_]) + w_str(name) + payload


def compound(*tags):
    return b''.join(tags) + b'\x00'


def read(path):
    raw = open(path, 'rb').read()
    return (gzip.decompress(raw), True) if raw[:2] == b'\x1f\x8b' else (raw, False)


def write(path, data, gz):
    open(path, 'wb').write(gzip.compress(data, mtime=0) if gz else data)


def splice(data, edits):
    """edits: (offset, length to replace, new bytes), applied from the back so offsets hold."""
    out = bytearray(data)
    for offset, length, new in sorted(edits, key=lambda e: e[0], reverse=True):
        out[offset:offset + length] = new
    return bytes(out)


def remove_elements(lst, doomed):
    """Edits cutting `doomed` children out of list node `lst` and correcting its count."""
    edits = [(c.start, c.end - c.start, b'') for c in doomed]
    edits.append((lst.payload + 1, 4, struct.pack('>i', len(lst.children) - len(doomed))))
    return edits


def uuid_of(ints):
    v = 0
    for i in ints:
        v = (v << 32) | (i & 0xFFFFFFFF)
    h = '%032x' % v
    return '%s-%s-%s-%s-%s' % (h[:8], h[8:12], h[12:16], h[16:20], h[20:])


# --------------------------------------------------------------------------------------- subcommands
def cmd_player(args):
    src, dst = args[0], args[1]
    opts = args[2:]
    survival = False
    pos = offhand = None
    remove_keys, remove_tags = [], []
    i = 0
    while i < len(opts):
        o = opts[i]
        if o == '--survival':
            survival = True; i += 1
        elif o == '--pos':
            pos = [float(v) for v in opts[i + 1:i + 4]]; i += 4
        elif o == '--offhand':
            offhand = opts[i + 1]; i += 2
        elif o == '--remove-key':
            remove_keys.append(opts[i + 1]); i += 2
        elif o == '--remove-tag':
            remove_tags.append(opts[i + 1]); i += 2
        else:
            sys.exit('unknown option %s' % o)

    data, gz = read(src)
    root = parse(data)
    before = plain(root)
    expected = json.loads(json.dumps(before))
    edits = []

    if survival:
        mode = child(root, 'playerGameType')
        assert mode is not None and mode.type == 3, 'no playerGameType'
        edits.append((mode.payload, 4, struct.pack('>i', 0)))
        expected['playerGameType'] = 0
    if pos:
        p = child(root, 'Pos')
        assert p is not None and p.type == 9 and len(p.children) == 3 and p.children[0].type == 6
        edits.append((p.children[0].payload, 24, struct.pack('>ddd', *pos)))
        expected['Pos'] = pos
    if offhand:
        equipment = child(root, 'equipment')
        assert equipment is None or child(equipment, 'offhand') is None, 'the offhand is not empty'
        item = compound(tag(8, 'id', w_str(offhand)), tag(3, 'count', struct.pack('>i', 1)))
        if equipment is None:
            edits.append((root.value, 0, tag(10, 'equipment', compound(tag(10, 'offhand', item)))))
            expected['equipment'] = {}
        else:
            edits.append((equipment.value, 0, tag(10, 'offhand', item)))
        expected['equipment']['offhand'] = {'id': offhand, 'count': 1}
    for key in remove_keys:
        node = child(root, key)
        assert node is not None, 'no %s to remove' % key
        edits.append((node.start, node.end - node.start, b''))
        del expected[key]
    if remove_tags:
        tags = child(root, 'Tags')
        doomed = [c for c in tags.children if c.value in remove_tags]
        assert len(doomed) == len(set(remove_tags)), 'not every tag named is on the player'
        edits.extend(remove_elements(tags, doomed))
        expected['Tags'] = [t for t in expected['Tags'] if t not in remove_tags]

    out = splice(data, edits)
    assert plain(parse(out)) == json.loads(json.dumps(expected)), \
        'the output differs from the input by more than the requested edits'
    write(dst, out, gz)
    done = (['survival'] if survival else []) + (['pos %s' % pos] if pos else []) + \
        (['offhand ' + offhand] if offhand else []) + ['removed ' + k for k in remove_keys] + \
        ['untagged ' + t for t in remove_tags]
    print('player    %s; every other value unchanged' % ', '.join(done))


def cmd_scores(args):
    src, dst, holder = args[0], args[1], args[2]
    wanted = {}
    for a in args[3:]:
        k, v = a.split('=', 1)
        wanted[k] = None if v == '-' else int(v)
    data, gz = read(src)
    root = parse(data)
    scores = child(child(root, 'data'), 'PlayerScores')
    assert scores is not None, 'no PlayerScores list'
    edits, found, doomed = [], {}, []
    for entry in scores.children:
        name, objective = child(entry, 'Name'), child(entry, 'Objective')
        if name is None or objective is None or name.value != holder or objective.value not in wanted:
            continue
        assert objective.value not in found, 'two entries for %s' % objective.value
        score = child(entry, 'Score')
        found[objective.value] = score.value if score is not None else 0
        target = wanted[objective.value]
        if target is None:
            doomed.append(entry)
        elif score is not None:
            edits.append((score.payload, 4, struct.pack('>i', target)))
        else:
            edits.append((entry.value, 0, tag(3, 'Score', struct.pack('>i', target))))
    missing = set(wanted) - set(found)
    assert not missing, 'no score entry for %s: %s' % (holder, sorted(missing))
    if doomed:
        edits.extend(remove_elements(scores, doomed))

    out = splice(data, edits)
    check = parse(out)
    before_entries = plain(scores)
    after_entries = plain(child(child(check, 'data'), 'PlayerScores'))
    kept = [e for e in before_entries
            if not (e.get('Name') == holder and wanted.get(e.get('Objective'), 0) is None)]
    assert len(after_entries) == len(kept), 'the wrong number of entries was removed'
    for b, a in zip(kept, after_entries):
        if b == a:
            continue
        assert b.get('Name') == holder and b.get('Objective') in wanted, 'an unrelated score changed'
        assert a.get('Score') == wanted[b['Objective']]
    rest_before = {k: v for k, v in plain(root)['data'].items() if k != 'PlayerScores'}
    rest_after = {k: v for k, v in plain(check)['data'].items() if k != 'PlayerScores'}
    assert rest_before == rest_after, 'something outside the scores changed'
    write(dst, out, gz)
    for k in sorted(wanted):
        print('score     %s %s: %d -> %s' % (holder, k, found[k], 'removed' if wanted[k] is None else wanted[k]))


def object_span(text, key, start=0):
    """(open brace, one past the close brace) of the first `"key": {` object at or after start."""
    m = re.compile(r'"%s"\s*:\s*\{' % re.escape(key)).search(text, start)
    assert m, 'no %s object in the file' % key
    depth, i = 0, m.end() - 1
    while True:
        ch = text[i]
        if ch == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return m.start(), m.end() - 1, i + 1
        i += 1


def cmd_stats(args):
    """STAT=VALUE sets a minecraft:custom statistic; CATEGORY/STAT=VALUE sets one in another category
    (e.g. minecraft:used/minecraft:totem_of_undying=0) - scoped to that category's object, since the
    same item id appears under several."""
    src, dst = args[0], args[1]
    text = open(src, 'r', encoding='utf-8', newline='').read()
    doc = json.loads(text)
    out = text
    for a in args[2:]:
        k, v = a.split('=', 1)
        category, _, stat = k.rpartition('/') if '/' in k else ('minecraft:custom', '', k)
        values = doc['stats'][category]
        assert stat in values, 'no %s statistic under %s' % (stat, category)
        _, lo, hi = object_span(out, category, out.index('"stats"'))
        block = out[lo:hi]
        # The number is replaced in the text, whatever the file's layout, so no other byte moves.
        pattern = re.compile(r'("%s"\s*:\s*)%d(?=\s*[,}])' % (re.escape(stat), values[stat]))
        assert len(pattern.findall(block)) == 1, '%s does not appear exactly once under %s' % (stat, category)
        out = out[:lo] + pattern.sub(lambda m: m.group(1) + str(int(v)), block) + out[hi:]
        print('stat      %s %s: %s -> %s' % (category, stat, values[stat], v))
        values[stat] = int(v)
    assert json.loads(out) == doc, 'the output differs from the input by more than the requested statistics'
    open(dst, 'w', encoding='utf-8', newline='').write(out)


def cmd_advancements(args):
    """Removes whole advancement entries from world/players/advancements/<uuid>.json - what
    `/advancement revoke` leaves behind is an entry with no criteria, and removing it is the same
    to the game. Text-level, so the rest of the file keeps its exact bytes."""
    src, dst = args[0], args[1]
    text = open(src, 'r', encoding='utf-8', newline='').read()
    doc = json.loads(text)
    out = text
    for adv in args[2:]:
        assert adv in doc, 'no %s advancement to remove' % adv
        key_start, _, close = object_span(out, adv)
        line_start = out.rfind('\n', 0, key_start) + 1
        rest = re.compile(r'\s*,[ \t]*\r?\n?').match(out, close)
        assert rest, '%s is the last entry; this expects DataVersion after it' % adv
        out = out[:line_start] + out[rest.end():]
        print('advanc.   removed %s (%s)' % (adv, json.dumps(doc[adv]['criteria'])))
        del doc[adv]
    assert json.loads(out) == doc, 'the output differs from the input by more than the removed advancements'
    open(dst, 'w', encoding='utf-8', newline='').write(out)


def cmd_remove(args):
    """Removes one compound entry by slash path from the root, e.g.
    data/contents/storage/last_player_death in a command storage file."""
    src, dst, path = args[0], args[1], args[2]
    data, gz = read(src)
    root = parse(data)
    node = root
    for part in path.split('/'):
        node = child(node, part)
        assert node is not None, 'no %s in the file' % path
    out = splice(data, [(node.start, node.end - node.start, b'')])
    expected = plain(root)
    holder = expected
    parts = path.split('/')
    for part in parts[:-1]:
        holder = holder[part]
    removed = holder.pop(parts[-1])
    assert plain(parse(out)) == expected, 'the output differs from the input by more than the removed entry'
    write(dst, out, gz)
    print('removed   %s (was %r)' % (path, removed))


def cmd_history(args):
    src, dst = args[0], args[1]
    data, gz = read(src)
    root = parse(data)
    lst = child(root, 'data')
    assert lst is not None and lst.type == 9, 'no data list'
    out = splice(data, remove_elements(lst, list(lst.children)))
    after = plain(parse(out))
    expected = plain(root)
    expected['data'] = []
    assert after == expected
    write(dst, out, gz)
    print('history   %d grave position(s) removed' % len(lst.children))


def cmd_entities(args):
    src, dst = args[0], args[1]
    x, y, z, radius = float(args[2]), float(args[3]), float(args[4]), float(args[5])
    wanted = []
    for spec in args[6:]:
        eid, _, etag = spec.partition('#')
        wanted.append((eid, etag or None))

    region = bytearray(open(src, 'rb').read())
    removed = 0
    cr = int(radius) // 16 + 1
    for cx in range((int(math.floor(x)) >> 4) - cr, (int(math.floor(x)) >> 4) + cr + 1):
        for cz in range((int(math.floor(z)) >> 4) - cr, (int(math.floor(z)) >> 4) + cr + 1):
            index = (cx & 31) + (cz & 31) * 32
            location = struct.unpack_from('>I', region, index * 4)[0]
            sector, count = location >> 8, location & 0xFF
            if sector == 0:
                continue
            length, comp = struct.unpack_from('>IB', region, sector * 4096)
            assert comp == 2, 'chunk %d,%d is not zlib-compressed in the region file' % (cx, cz)
            data = zlib.decompress(bytes(region[sector * 4096 + 5:sector * 4096 + 4 + length]))
            root = parse(data)
            position = child(root, 'Position')
            if position is None or position.value != [cx, cz]:
                continue                        # a chunk from another region file's range
            ents = child(root, 'Entities')
            doomed = []
            for e in (ents.children if ents else []):
                eid = child(e, 'id').value
                p = [c.value for c in child(e, 'Pos').children]
                tags = [c.value for c in child(e, 'Tags').children] if child(e, 'Tags') else []
                if max(abs(p[0] - x), abs(p[1] - y), abs(p[2] - z)) > radius:
                    continue
                if any(eid == w and (t is None or t in tags) for w, t in wanted):
                    doomed.append(e)
                    print('entity    removed %s at %.1f %.1f %.1f uuid %s tags %s'
                          % (eid, p[0], p[1], p[2], uuid_of(child(e, 'UUID').value), tags))
            if not doomed:
                continue
            out = splice(data, remove_elements(ents, doomed))
            expected = plain(root)
            gone = set(id(e) for e in doomed)
            expected['Entities'] = [plain(e) for e in ents.children if id(e) not in gone]
            assert plain(parse(out)) == expected, 'chunk %d,%d changed by more than the removals' % (cx, cz)

            packed = zlib.compress(out)
            body = struct.pack('>IB', len(packed) + 1, 2) + packed
            sectors = (len(body) + 4095) // 4096
            if sectors <= count:
                start = sector
                region[sector * 4096:(sector + count) * 4096] = body + bytes(count * 4096 - len(body))
            else:
                start = len(region) // 4096
                region += body + bytes(sectors * 4096 - len(body))
                count = sectors
            struct.pack_into('>I', region, index * 4, (start << 8) | count)
            struct.pack_into('>I', region, 4096 + index * 4, int(time.time()))
            removed += len(doomed)

    assert removed > 0, 'no matching entity found'
    assert len(region) % 4096 == 0
    open(dst, 'wb').write(bytes(region))
    print('entities  %d removed' % removed)


if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    {'player': cmd_player, 'scores': cmd_scores, 'stats': cmd_stats, 'history': cmd_history,
     'entities': cmd_entities, 'advancements': cmd_advancements, 'remove': cmd_remove}[sys.argv[1]](sys.argv[2:])
