# Changelog

One entry per **published** release. An entry means this reached players — never write one for a
build that was not published.

---

## v1.0.0 — 2026-09-23

**The first hardcore release, and the first thing this channel has ever served that is actually
this pack.** The repository was forked out of Vanilla+ on 2026-09-22 and its `site/` came with it,
so until now the channel published Vanilla+'s 176 jars under a hardcore name. Nobody could install
it — no client pointed here — so nothing reached a player and nothing broke.

Manifest digest `61810e0d67ffc34a…`; there is no replaced digest, because no client has ever
accepted one from this channel.

**What the pack is.** Built one mod at a time against a clean 26.2 instance, every mod read before
the next went in, both halves launch-tested at every step:

* **113 client jars, 69 server jars** — 68 client-only, 45 shared, 24 server-only. The client no
  longer carries server-effect mods, which the Vanilla+ line still does; `nbidal18-strike`,
  `nbidal18-afk`, `nbidal18-saferejoin`, `nbidal18-theend`, `nbidal18-coppergolem`,
  `nbidal18-reduceddebug` and the Vanilla Refresh companion are server-side only here.
* **23 jars removed** to make it "truly vanilla" — Incendium, Nullscape, Better End with BCLib and
  WorldWeaver, Farmer's Delight with More Delight, Traveler's Backpack, Reliable Gliders, Carry On,
  Boids, Diagonal Fences, and the first-party artefacts that existed only for them.
* **Overworld terrain is kept** — Terralith, Tectonic and Terrain Slabs, with our Tectonic datapack.
  Structures are kept and are entirely server-side: Structory, Structory Towers, Towns and Towers,
  Sparse Structures.
* **Mouse Wheelie is replaced by Client Sort**, which brings no new library. Jade is out.
* **Nine resource packs** enabled; Fresh Animations and its two extensions are held back with the
  player-render set-aside, pending an animation check.

**Player-facing differences from Vanilla+**

* **The Prism instance is `nbidal18-vanilla-plus-hardcore`**, derived from `PACK-NAME.txt`. The two
  packs are separate installs and no longer collide on one machine.
* **The multiplayer list ships the hardcore server only.** It had been carrying both; the Vanilla+
  address is gone, and the updater seeds nothing — every install of this pack is a first install.
* **The Soul Charm costs more**: 4 gold blocks, 2 emerald blocks, 2 diamond blocks and a totem,
  where upstream asks 2 copper, 2 bone and 4 redstone.
* **A held compass shows X, Y and Z again.** The Y-only readout existed for the "forever world"
  respawn, which was designed, costed and parked.

**A Vanilla+ client cannot join this server, and the reverse is also true.** Not because of Better
Compatibility Checker — that mod only draws a red icon in the server list and never disconnects
anyone — but because the two channels have different manifest digests and the integrity helper
refuses a login that does not match, with `require-helper=true` so the helper cannot simply be
deleted.

**Players do nothing beyond importing the setup ZIP once.** There is no previous hardcore install to
update from.
