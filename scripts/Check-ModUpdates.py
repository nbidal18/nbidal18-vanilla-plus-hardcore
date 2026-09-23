#!/usr/bin/env python3
"""Is every jar in a folder the newest build Modrinth has for our game version?

    python Check-ModUpdates.py --game-version 26.2 --mods <folder> [--mods <folder>] [--json out]

Written 2026-09-23, when the owner asked - mid-rebuild, one mod at a time - to "make sure we are on
the latest version available for each mod", forks and patched jars included. The jars in the rebuild
came from a release cut on 2026-09-22 out of a pack whose mods were last refreshed at various points
over a month; on a game version this young that is long enough for most of them to have moved.

**Identification is by hash, never by filename**, the same way as Measure-GameVersionSupport.py:
Modrinth's `version_files` endpoint maps a digest to the exact version that published it, so
"installed" is known precisely, not parsed out of a name. The newest build is then read from the
project's version list filtered to this game version and loader.

Two answers are given per jar, because they differ and both matter:

  newest release   - the newest build whose channel is `release`
  newest of any    - the newest build at all, which may be alpha or beta

A jar is *current* when the installed version is the newest of any. A jar on a beta whose newer
build is also a beta is still behind. A jar on a release with only a newer alpha above it is
reported, but flagged - moving onto prerelease is a decision, not an update.

**First-party jars are not on Modrinth and are listed separately.** For a companion pinned to an
exact upstream version, the upstream's row is the one that matters: if it moved, the companion has
to be re-pointed and rebuilt, and that is a task this script names rather than performs.

Nothing here downloads anything. It says what is behind; fetching is a separate, approved step.
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.modrinth.com/v2"
UA = "nbidal18-modpack/1.0 (github.com/nbidal18; pack tooling)"


def request(path, payload=None):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(API + path, data=body, method="POST" if body else "GET",
                                 headers={"User-Agent": UA, "Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(int(e.headers.get("X-Ratelimit-Reset", "10")) or 10)
                continue
            if e.code == 404:
                return None
            raise
        except urllib.error.URLError:
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))
    raise RuntimeError("giving up on " + path)


def digest(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods", action="append", required=True)
    ap.add_argument("--game-version", required=True)
    ap.add_argument("--loader", default="fabric")
    ap.add_argument("--json")
    args = ap.parse_args()

    jars = {}
    for folder in args.mods:
        for name in sorted(os.listdir(folder)):
            if name.endswith(".jar"):
                jars.setdefault(name, os.path.join(folder, name))
    ours = sorted(n for n in jars if n.startswith("nbidal18-"))
    third = {n: p for n, p in jars.items() if n not in ours}
    print(f"{len(jars)} jars: {len(third)} third-party to check, {len(ours)} first-party listed separately")

    by_hash = {"sha512": {}, "sha1": {}}
    for name, path in third.items():
        by_hash["sha512"][digest(path, "sha512")] = name
        by_hash["sha1"][digest(path, "sha1")] = name
    installed = {}
    for algo in ("sha512", "sha1"):
        outstanding = [h for h, n in by_hash[algo].items() if n not in installed]
        if not outstanding:
            continue
        result = request("/version_files", {"hashes": outstanding, "algorithm": algo}) or {}
        for h, version in result.items():
            installed[by_hash[algo][h]] = version

    q = f"?loaders={urllib.parse.quote(json.dumps([args.loader]))}&game_versions={urllib.parse.quote(json.dumps([args.game_version]))}"
    current, behind, prerelease_only, unidentified = [], [], [], sorted(n for n in third if n not in installed)
    cache = {}
    for name in sorted(installed):
        v = installed[name]
        pid = v["project_id"]
        if pid not in cache:
            cache[pid] = request(f"/project/{pid}/version{q}") or []
        versions = cache[pid]
        if not versions:
            behind.append((name, v["version_number"], "-", "-", "no build for this game version at all"))
            continue
        newest = versions[0]
        releases = [x for x in versions if x["version_type"] == "release"]
        newest_release = releases[0] if releases else None
        row = (name, v["version_number"],
               newest_release["version_number"] if newest_release else "(none)",
               f"{newest['version_number']} [{newest['version_type']}]",
               newest["date_published"][:10])
        if newest["id"] == v["id"]:
            current.append(row)
        elif v["version_type"] == "release" and newest["version_type"] != "release" and newest_release and newest_release["id"] == v["id"]:
            prerelease_only.append(row)
        else:
            behind.append(row)

    def table(rows, title):
        print(f"\n### {title} ({len(rows)})\n")
        print("| Jar | Installed | Newest release | Newest of any | Published |")
        print("| --- | --- | --- | --- | --- |")
        for r in rows:
            print("| " + " | ".join(f"`{x}`" if i in (1, 2, 3) else str(x) for i, x in enumerate(r)) + " |")

    print(f"\n## Updates against {args.game_version} / {args.loader}")
    table(behind, "Behind - a newer build exists")
    table(prerelease_only, "Current release, newer prerelease exists - a decision, not an update")
    table(current, "Current")
    print(f"\n### First-party, not on Modrinth ({len(ours)})\n")
    for n in ours:
        print(f"- {n}")
    if unidentified:
        print(f"\n### Third-party jars Modrinth does not know ({len(unidentified)})\n")
        for n in unidentified:
            print(f"- {n}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"behind": behind, "prerelease_only": prerelease_only, "current": current,
                       "ours": ours, "unidentified": unidentified,
                       "installed": {n: {"project_id": v["project_id"], "version": v["version_number"], "id": v["id"]}
                                     for n, v in installed.items()},
                       "newest": {pid: [{"id": x["id"], "version": x["version_number"], "type": x["version_type"],
                                         "date": x["date_published"], "files": [{"url": f["url"], "filename": f["filename"], "size": f["size"], "sha512": f["hashes"].get("sha512")} for f in x["files"]]}
                                        for x in vs[:3]] for pid, vs in cache.items()}},
                      fh, indent=1)
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
