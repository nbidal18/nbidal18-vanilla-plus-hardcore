"""Retarget the 1.21.1 Prism updater at the vanilla_plus channel.

Neither file imports Minecraft or Fabric - they are plain Java that Prism runs before the game
starts - so this is a retarget, not a port. The machinery is left intact and only the pack-specific
data is emptied, because those hooks are how a future release migrates an existing instance.

Two of them would actively misfire if carried over unchanged:
  * RETIRED_LOCAL_FILES lists config/voxy-config.json, which THIS pack ships. Left alone, the
    updater would delete a published file on first launch.
  * PLAYER_FILE_SEEDS seeds keybinds around mod collisions that existed in the 1.21.1 pack.
A v1.0.0 has nothing to migrate from, so both start empty.
"""
import io
import os
import re
import shutil

BS = chr(92)
ROOT = "C:" + BS + os.path.join("Users", "nizar", "Documents", "modpack")
SRC = os.path.join(ROOT, "nbidal18-packwiz-github", "client")
DST = os.path.join(ROOT, "vanilla_plus", "nbidal18-vanilla-plus", "client")
os.makedirs(DST, exist_ok=True)

for name in ("Nbidal18PackwizSync.java", "Nbidal18PackwizSupervisor.java"):
    shutil.copyfile(os.path.join(SRC, name), os.path.join(DST, name))

p = os.path.join(DST, "Nbidal18PackwizSync.java")
t = io.open(p, encoding="utf-8").read()
edits = 0


def sub(old, new, why):
    global t, edits
    assert t.count(old) == 1, (why, t.count(old))
    t = t.replace(old, new, 1)
    edits += 1
    print("  %-46s %s" % (why, "ok"))


sub('"https://nbidal18.github.io/nbidal18-packwiz/pack.toml"',
    '"https://nbidal18.github.io/nbidal18-vanilla-plus/pack.toml"', "pack url")
sub('"https://nbidal18.github.io/nbidal18-packwiz/sync-manifest.json"',
    '"https://nbidal18.github.io/nbidal18-vanilla-plus/sync-manifest.json"', "manifest url")
sub("private static final int[] MINIMUM_PACK_VERSION = {4, 4, 5};",
    "private static final int[] MINIMUM_PACK_VERSION = {1, 0, 0};", "minimum pack version")
sub('.header("User-Agent", "nbidal18-packwiz/4.1.3")',
    '.header("User-Agent", "nbidal18-vanilla-plus/1.0.0")', "user agent")

# Empty the two migration data sets. The methods and their marker files stay.
def block(text, decl):
    """Span of a `... = List.of( ... );` declaration, found by balancing parentheses.

    The span starts at the declaration's own javadoc when it has one, so replacing it does not
    leave the old comment dangling above the new declaration.
    """
    start = text.index(decl)
    head = text.rfind("/**", 0, start)
    if head != -1 and "*/" in text[head:start] and text[text.index("*/", head) + 2:start].strip() == "":
        start = head
    i = text.index("(", start)
    depth = 0
    while True:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = text.index("\n", text.index(";", i)) + 1
    return start, end


class _M:
    def __init__(self, s, e):
        self._s, self._e = s, e

    def start(self):
        return self._s

    def end(self):
        return self._e


m = _M(*block(t, "private static final List<PlayerFileSeed> PLAYER_FILE_SEEDS"))
t = t[:m.start()] + (
    "    /**\n"
    "     * Empty on purpose. A v1.0.0 has no earlier install to migrate, so there is nothing to\n"
    "     * seed. Add rows here when a release needs to set one value inside a player-owned file.\n"
    "     */\n"
    "    private static final List<PlayerFileSeed> PLAYER_FILE_SEEDS = List.of();\n") + t[m.end():]
edits += 1
print("  %-46s ok" % "PLAYER_FILE_SEEDS emptied")

m = _M(*block(t, "private static final List<String> RETIRED_LOCAL_FILES"))
t = t[:m.start()] + (
    "    /**\n"
    "     * Empty on purpose, and it must stay that way until a mod is actually retired from THIS\n"
    "     * pack. The 1.21.1 list named config/voxy-config.json, which this pack publishes: carried\n"
    "     * over unchanged it would have deleted a shipped file on first launch.\n"
    "     */\n"
    "    private static final List<String> RETIRED_LOCAL_FILES = List.of();\n") + t[m.end():]
edits += 1
print("  %-46s ok" % "RETIRED_LOCAL_FILES emptied")

io.open(p, "w", encoding="utf-8", newline="\n").write(t)
print("\n%d edits written to %s" % (edits, os.path.relpath(p, ROOT)))

# sanity: nothing from the old channel survives
leftover = [l.strip() for l in t.splitlines()
            if "nbidal18-packwiz/" in l or "voxy-config.json" in l]
print("references to the old channel or the voxy file left: %d" % len(leftover))
for l in leftover:
    print("   ", l[:100])
