# nbidal18 Vanilla+ Hardcore — update channel

Packwiz update channel for the **nbidal18 Vanilla+ Hardcore** modpack: Minecraft **26.2**, Fabric.

**This repository is independent of `nbidal18-vanilla-plus`.** It shares no version file, no
manifest, no digest, no server and no publish sequence with it. The two packs were split on
2026-09-22 so they could take different updates; before that both servers ran one pack from one
channel.

**What it does share is its scripts, deliberately and byte-identically.** Every build and deploy
script is the same file as in the Vanilla+ repository; the only thing that differs is
`RELEASE-PREFIX.txt`, which `scripts/ReleaseLine.ps1` reads to find this line's release folders
(`hc.<version>` here, `v.<version>` there). A fix made to a script in either repository is copied to
the other verbatim. **Do not let them drift** — that was the whole reason for the prefix file.

| | |
| --- | --- |
| Minecraft | 26.2 |
| Loader | Fabric 0.19.3 |
| Server | `38.103.248.98:27037` |
| Channel | `https://nbidal18.github.io/nbidal18-vanilla-plus-hardcore/pack.toml` |
| Release folders | `hc.<version>`, beside this repository |
| Server mirror | `_server-payload-cache-hardcore`, beside this repository |

## Where things are

Everything else works exactly as the Vanilla+ repository does, and its README is the reference for
the release workflow, the four publish phases and the rules that have each cost a release. Nothing
in that document changes here except which folders and which server it names.
