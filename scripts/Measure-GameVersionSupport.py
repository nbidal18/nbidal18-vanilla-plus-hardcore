#!/usr/bin/env python3
"""Ask Modrinth which of a pack's jars have a build for a given Minecraft version.

    python Measure-GameVersionSupport.py --game-version 26.3 \
        --mods "../../hc.1.0.0/3. modpack/client/mods" \
        --mods "../../_server-payload-cache/mods"

Written 2026-09-23. `docs/archive/upgrade-26.3.md` was measured by hand on 2026-09-21 and says, in
its own opening, that its counts are a snapshot of that day and must be re-measured before anything
is decided on them. Six days after a Minecraft release the answer moves daily, so the measurement
is the thing that has to be cheap - hence a script rather than a second hand count.

**Jars are identified by hash, never by filename.** Modrinth's `version_files` endpoint maps a file
digest straight to the project that published it, so `Terrain Slabs v3.3.2-26.2.jar` resolves to
`countereds-terrain-slabs` without anyone guessing. A name match would have to cope with spaces,
`+26.2` suffixes, forks named after their target and our own `nbidal18-*` artefacts, and it would be
wrong quietly. Anything the hash does not resolve is reported as unidentified rather than assumed.

Two hash algorithms are tried because Modrinth indexes both and not every project has both recorded:
sha512 first, then sha1 for whatever is left.

A jar being absent from Modrinth is not a finding on its own - all 46 first-party artefacts are ours
and are moved by rebuilding them, and a few third-party jars came from elsewhere. Those are listed
separately so the blocker count means what it says.
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.modrinth.com/v2"
# Modrinth asks for a contact in the User-Agent and rate-limits anonymous traffic harder without one.
UA = "nbidal18-modpack/1.0 (github.com/nbidal18; pack tooling)"
BATCH = 100


def post(path, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        API + path, data=body, method="POST",
        headers={"User-Agent": UA, "Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get("X-Ratelimit-Reset", "10")) or 10
                print(f"    rate limited, waiting {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise
        except urllib.error.URLError:
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))
    raise RuntimeError("giving up after 5 attempts on " + path)


def digest(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def chunks(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods", action="append", required=True,
                    help="a folder of jars; repeat for client and server")
    ap.add_argument("--game-version", required=True)
    ap.add_argument("--loader", default="fabric")
    ap.add_argument("--exclude-list",
                    help="a text file of jar filenames to leave out, one per line, "
                         "# for comments - for asking the question about a pack you have "
                         "decided on but not yet built")
    ap.add_argument("--json", help="write the full result here as well")
    args = ap.parse_args()

    excluded = set()
    if args.exclude_list:
        with open(args.exclude_list, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line:
                    excluded.add(line)

    jars = {}
    skipped = []
    for folder in args.mods:
        if not os.path.isdir(folder):
            sys.exit("no such folder: " + folder)
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".jar"):
                continue
            if name in excluded:
                skipped.append(name)
                continue
            jars.setdefault(name, os.path.join(folder, name))

    print(f"{len(jars)} jars across {len(args.mods)} folder(s)"
          + (f", {len(skipped)} excluded" if skipped else ""))

    # Hash once, keep both digests, so the sha1 fallback costs no extra read.
    by_hash = {"sha512": {}, "sha1": {}}
    for name, path in jars.items():
        by_hash["sha512"][digest(path, "sha512")] = name
        by_hash["sha1"][digest(path, "sha1")] = name

    found = {}
    for algo in ("sha512", "sha1"):
        outstanding = [h for h, n in by_hash[algo].items() if n not in found]
        if not outstanding:
            continue
        print(f"  resolving {len(outstanding)} by {algo}")
        for part in chunks(outstanding, BATCH):
            result = post("/version_files", {"hashes": part, "algorithm": algo})
            for h, version in result.items():
                found[by_hash[algo][h]] = version

    unidentified = sorted(n for n in jars if n not in found)
    projects = sorted({v["project_id"] for v in found.values()})
    print(f"  {len(found)} identified across {len(projects)} projects, "
          f"{len(unidentified)} not on Modrinth")

    # One call per project rather than per jar: several jars can belong to one project, and the
    # question is about the project's publishing, not about the installed file.
    supported = {}
    print(f"  checking {args.game_version}/{args.loader} for {len(projects)} projects")
    for pid in projects:
        req = urllib.request.Request(
            f"{API}/project/{pid}/version"
            f"?loaders=%5B%22{args.loader}%22%5D"
            f"&game_versions=%5B%22{args.game_version}%22%5D",
            headers={"User-Agent": UA})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    supported[pid] = json.loads(r.read().decode("utf-8"))
                break
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    wait = int(e.headers.get("X-Ratelimit-Reset", "10")) or 10
                    time.sleep(wait)
                    continue
                if e.code == 404:
                    supported[pid] = []
                    break
                raise
            except urllib.error.URLError:
                if attempt == 4:
                    raise
                time.sleep(2 * (attempt + 1))

    have, lack = [], []
    for name in sorted(found):
        v = found[name]
        versions = supported.get(v["project_id"], [])
        if versions:
            # Newest first is Modrinth's order; a release beats a prerelease when both exist,
            # because "there is a build" and "there is a build you would ship" differ.
            best = next((x for x in versions if x["version_type"] == "release"), versions[0])
            have.append((name, v["project_id"], best["version_number"],
                         best["version_type"], best["date_published"][:10]))
        else:
            lack.append((name, v["project_id"], v["version_number"]))

    print()
    print(f"## {args.game_version} / {args.loader}")
    print()
    print(f"| | Count |")
    print(f"| --- | --- |")
    print(f"| Jars measured | **{len(jars)}** |")
    print(f"| Identified on Modrinth | **{len(found)}** |")
    print(f"| - have a {args.game_version} {args.loader} build | **{len(have)}** |")
    print(f"| - do not | **{len(lack)}** |")
    print(f"| Not on Modrinth (ours, or from elsewhere) | **{len(unidentified)}** |")

    print()
    print(f"### No {args.game_version} build ({len(lack)})")
    print()
    print("| Jar | Modrinth project | Installed |")
    print("| --- | --- | --- |")
    for name, pid, ver in lack:
        print(f"| {name} | `{pid}` | `{ver}` |")

    print()
    print(f"### Has a {args.game_version} build ({len(have)})")
    print()
    print("| Jar | Build | Channel | Published |")
    print("| --- | --- | --- | --- |")
    for name, pid, ver, kind, when in have:
        print(f"| {name} | `{ver}` | {kind} | {when} |")

    print()
    print(f"### Not on Modrinth ({len(unidentified)})")
    print()
    for name in unidentified:
        print(f"- {name}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"measured": sorted(jars), "excluded": sorted(skipped),
                       "have": have, "lack": lack, "unidentified": unidentified},
                      fh, indent=1)
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
