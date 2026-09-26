# Changelog

One entry per **published** release. An entry means this reached players — never write one for a
build that was not published.

---

## v1.0.5 — 2026-09-26

**The pack is `nbidal18 Vanilla++` now: normal survival, on the original world.** Manifest digest
`bbf03e2451638709…`, replacing `47b260eee9f0bbcb…` (v1.0.4). 232 managed files become 231.

* **Hardcore is over.** The server loads `world2` - the world everyone played until 2026-09-25 - with its
  hardcore flag cleared, so death is ordinary survival death and Gravestones keeps your items. The fresh
  world from this morning is retired.
* **Hardcore Revive+ is removed** from client and server. No more lives, ghosts or revival charm.
* **The name.** Prism shows `nbidal18 Vanilla++`; the server appears as `nbidal18 Vanilla++` in your
  multiplayer list (renamed once, unless you had renamed it yourself); the motd reads `v1.0.5 Vanilla++`.
  Your instance folder keeps whatever name it has - nothing is re-imported. New installs use
  `nbidal18-vanilla-plus-plus-client.zip`.
* Integrity helper 1.0.5. Every other first-party jar rebuilt byte-identical.
* **Later the same evening, on the maintainer's disk only:** the line's folder became `vanilla_plus_plus\`, the
  repository folder `nbidal18-vanilla-plus-plus\`, releases `vpp.<version>`. The GitHub repository and this
  channel's URL keep `nbidal18-vanilla-plus-hardcore`, because the URL is what every updater has compiled in.

**Players click Play.** One "close and reopen" notice while the updater fetches the new helper.

## v1.0.4 — 2026-09-26

**Animations are back, GUIs and crops got a look, and the updater stopped carrying Vanilla+'s
history.** Manifest digest `47b260eee9f0bbcb…`, replacing `a93d4c4e94b7d5bd…` (v1.0.3). 215 managed
files become 232.

* **The whole animation set-aside returns**, checked pose by pose in a throwaway by the owner. Entity
  Model Features 3.3.8 and Entity Texture Features 7.2.4, NotEnoughAnimations 1.12.5, Player Animation
  Library 1.2.6, EMF Compat Core 2.0.0 and EMF Compat NEA 1.2.0, our `nbidal18-emf` rebuilt against
  the new EMF; Fresh Animations 1.10.5, its All Extensions 1.9.2 and FA+Player 1.1 as resource packs,
  selected for everyone once. Baby animals stay vanilla-shaped: EMF stopped letting babies borrow the
  adult model on this game version and the pack author removed its baby models, so that is upstream's
  choice, not a fault here.
* **Fancy Crops 1.3 and Recolourful Containers 3.1.3**, from Incy PLUS, with **OptiGUI 2.3.0** as the
  mod Recolourful's per-container rules need. Prettier crops at every growth stage; every container
  GUI coloured to match its block.
* **Sodium Extra's coordinates overlay is off.** One seeded key; whoever turns it back on keeps that.
* **Nine seeds written for Vanilla+ are gone from this updater** - four that overwrote the resource
  pack list with a Vanilla+ list on first Play, two warning on every launch for files that never
  exist here, one creating a stray Immersive Aircraft config, two adding packs this pack never had.
  Nothing on an existing instance reverts; a fresh install now gets exactly the shipped list.
* **Server:** Preferred Gamerules 2.0.1, so every world created from now on starts with
  `reduced_debug_info` on and the locator bar off. The world already generated keeps its saved rules.
* Integrity helper 1.0.4. The updater gains `--seed-only`, used by the launch test so a throwaway gets
  the same one-time defaults a player does. Every other first-party jar rebuilt byte-identical.

**Players click Play.** One "close and reopen" notice while the updater fetches the new helper; the
resource packs and OptiGUI download on that same launch.

## v1.0.3 — 2026-09-24

**The game exits when you close it.** Since the rebuild, quitting from inside a world (or after a
server session) closed the window but left the Java process running - two cores at 100 %, no window,
until killed by hand. Two bugs, stacked, both fixed. Manifest digest `a93d4c4e94b7d5bd…`, replacing
`f3905636674cce7d…` (v1.0.2).

* **`nbidal18-soundsbegone` 1.1.0.** Sounds Be Gone 1.6.0 calls its telemetry `shutdown()` on quit,
  which dereferenced the analytics client our companion deliberately never builds. Every quit became a
  "Game shutdown" crash report and a crash-path exit that never finished. One more call dropped.
* **`nbidal18-ixeris` 1.0.0, new.** A window that has carried Ixeris's buffered raw mouse input cannot
  be destroyed without wedging Windows' `DestroyWindow`, which is where the main thread sat for ever.
  At quit, while Ixeris is enabled, the window and GLFW are left to the OS to reclaim with the process.
  Proved by closing a throwaway client inside a world and after a server session: gone in seconds.
* Integrity helper 1.0.3. Every other first-party jar rebuilt byte-identical.

**Players click Play.** One "close and reopen" notice while the updater fetches the new helper - and
that reopen is the last time the old client has to be killed by hand.

## v1.0.2 — 2026-09-24

**One shader pack, a key for the far-terrain readout, both servers in the list, and the pack's
defaults pushed to the instance that predates them.** Manifest digest `f3905636674cce7d…`,
replacing `99fd6e9ee1c3ac12…` (v1.0.1).

* **Complementary Unbound is the only shader pack.** Eclipse, Photon, Rethinking Voxels and E-LITE
  are removed with their settings files - 222 managed files become 214. The updater moves the four
  zips aside (`.nbidal18-packwiz/removed-local-files`), and a one-row seed points Iris at
  Complementary; whether shaders are on stays yours.
* **X shows and hides the `/voxysync` overlay.** A real key binding, under Controls as *Voxy sync
  overlay (show / hide)*, rebindable. Companion `nbidal18-voxyworldgen` 3.8.0 → 3.9.0 on both sides.
* **The multiplayer list carries Vanilla+ as well as Hardcore again**, by decision: a hardcore
  client cannot join Vanilla+ - the two packs have different manifest digests - and Better
  Compatibility Checker draws that entry red with the other pack's name, which is the point: it
  tells a player the other server exists and needs the other pack. Added to existing instances
  once by seed; nothing else in the list is touched.
* **Seventeen `options.txt` rows seeded once** - the pack's own defaults, for an instance imported
  before the master became the owner's file: vsync on, exclusive fullscreen off, 180 fps, clouds
  off, narrator hotkey off, the five bindings the pack unbinds (pick block, hotbar 1 on `[`,
  voice-chat toggle, hide icons, new waypoint), Auto HUD's toggle on H, and the sound mix. A fresh
  install already has these and is left byte-identical.
* Integrity helper 1.0.2. Every other first-party jar rebuilt byte-identical.

**Players click Play.** One "close and reopen" notice while the updater fetches the new helper, as
every release. Nothing to re-import.

## v1.0.1 — 2026-09-24

**Better Third Person is back, Variants & Ventures is gone, and the settings you get on a first
install are the owner's.** The first two of those had already reached the channel under the v1.0.0
number - v1.0.0 was published three times in a day, which is what the one-publish-per-version rule
exists to prevent - so this is the version that makes the current pack a release of its own.

Manifest digest `99fd6e9ee1c3ac12…`, replacing `fd2f1cbf3be5bea3…` (the third v1.0.0 build the
channel was serving) and, before it, `61810e0d67ffc34a…` (the first).

**What changed since the v1.0.0 that was written up below**

* **Better Third Person (our 26.2 port, `1.9.0-nbidal18.1`) is in the client again.** It had been
  set aside with the animation-conflict group by mistake: its mixins are camera and input, none
  touch the player model. `skipThirdPersonFrontView` is on, as on Vanilla+, so the front view is
  gone again. **112 client jars.**
* **Variants & Ventures is removed from both sides, with Resourceful Lib.** It adds four mobs of its
  own with spawn eggs, which is content, not variants. **69 server jars.**
* **`options.txt` in the setup ZIP is the owner's Vanilla+ file** - same keybinds, fullscreen,
  video, sound and accessibility values - with this line's nine resource packs selected and no
  remembered server. It is a first-install default only: an instance imported before this keeps
  the file it has, and gets these settings only by re-importing the ZIP.
* Every other first-party jar rebuilt **byte-identical** to the one it replaces; only the integrity
  helper moved, to `1.0.1`.

**Players do nothing beyond clicking Play.** The game closes once with a "close and reopen" notice
while the updater fetches the new helper and the removed mod's files are moved aside - the same
as every release. Anyone who wants the new default settings re-imports
`nbidal18-hardcore-client.zip`; nothing about the update requires it.

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

* **The Prism instance is `nbidal18-vanilla-plus-plus`**, derived from `PACK-NAME.txt`. The two
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
