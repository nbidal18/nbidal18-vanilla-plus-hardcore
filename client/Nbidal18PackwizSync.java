import java.awt.BorderLayout;
import java.awt.Dimension;
import java.awt.GraphicsEnvironment;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.InputStreamReader;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Comparator;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import javax.swing.BorderFactory;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.SwingConstants;
import javax.swing.SwingUtilities;
import javax.swing.WindowConstants;

/** Cross-platform Prism pre-launch updater for nbidal18. */
public final class Nbidal18PackwizSync {
    private static final String DEFAULT_PACK_URL =
            "https://nbidal18.github.io/nbidal18-vanilla-plus/pack.toml";
    private static final String DEFAULT_MANIFEST_URL =
            "https://nbidal18.github.io/nbidal18-vanilla-plus/sync-manifest.json";
    /**
     * Lowest pack version this updater will accept from the channel. Raising it with each release
     * stops a rolled-back or spoofed channel downgrading an instance: once a client runs this
     * build, publishing anything below 4.4.5 would be refused rather than installed.
     */
    private static final int[] MINIMUM_PACK_VERSION = {1, 0, 0};
    private static final DateTimeFormatter MOVE_STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss");
    private static final Pattern FILE_ENTRY = Pattern.compile(
            "\\{\\s*\\\"path\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"sha256\\\"\\s*:\\s*\\\"([a-fA-F0-9]{64})\\\"\\s*}");
    private static final Pattern PROPERTY_RULE = Pattern.compile(
            "\\{\\s*\\\"path\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"key\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"value\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*}");
    private static final Pattern JSON_STRING = Pattern.compile("\\\"((?:\\\\.|[^\\\"])*)\\\"");

    /**
     * config/autohud.json5 is a first-install default that becomes player-owned, so a changed
     * default never reaches an existing instance. This release deliberately republishes it once:
     * the local copy is removed before the sync so packwiz restores the shipped file, the marker
     * below records that it happened, and the file is player-owned again from then on. Bump the
     * token only when a future release genuinely needs to reissue the defaults again.
     */
    private static final String AUTOHUD_DEFAULT_TOKEN = "autohud-place-break-v1";

    /**
     * One value inside a player-owned file that the pack wants to set once. A null {@code value}
     * removes the row instead of replacing it, which is only allowed at the top level.
     *
     * <p>{@code parents} is the chain of enclosing objects or sections the key sits in, outermost
     * first, and is empty for a flat {@code key=value} file. It is a list rather than a dotted
     * string on purpose: {@code options.txt} keys contain dots themselves
     * ({@code key_key.fieldguide.open}), so a dotted path could not be split back into segments
     * unambiguously.
     */
    private record SeedRow(List<String> parents, String key, String value, boolean addToList,
                           boolean atBottom) {

        SeedRow(List<String> parents, String key, String value) {
            this(parents, key, value, false, false);
        }

        /**
         * One element added to a JSON list held by a key in a flat file - options.txt's
         * resourcePacks above all - leaving every element already there, and their order, as the
         * player has them. Nothing is written when the element is already listed, or when the key is
         * not there to add to. Restating the whole list instead would switch back on every pack a
         * player had switched off. It goes above the last file pack, so it draws over all of them.
         */
        static SeedRow addToList(String key, String element) {
            return new SeedRow(List.of(), key, element, true, false);
        }

        /**
         * The same, but below the first file pack, so every pack already listed draws over it - for
         * a pack that should fill in what the others leave rather than replace what they draw.
         */
        static SeedRow addToListBottom(String key, String element) {
            return new SeedRow(List.of(), key, element, true, true);
        }

        /** A key in a flat file, or at the top level of a nested one. */
        static SeedRow of(String key, String value) {
            return new SeedRow(List.of(), key, value);
        }

        /** A key inside one enclosing object or section, e.g. {@code experience.onChange}. */
        static SeedRow in(String parent, String key, String value) {
            return new SeedRow(List.of(parent), key, value);
        }
    }

    /**
     * A declared, one-time change to specific rows of a player-owned file.
     *
     * <p>Some files are loaded once as a sensible default and then belong to the player forever —
     * {@code options.txt} above all. Until now that was all or nothing: a file was either published
     * and enforced, or seeded once and never touched again, with no way to say "this one row
     * changed, take the new value". That gap is why a new keybind had no home, and no keybind is
     * ever hardcoded in a mod here, because a player must always be able to rebind anything.
     *
     * <p>So: declare the rows, stamp them with a token, and the updater writes only those rows and
     * leaves every other line exactly as it found it. The token is the whole mechanism — once its
     * marker exists the rows are never written again, so the player owns them from that moment on.
     * <b>Bump the token only when a release genuinely needs to reissue those rows.</b>
     *
     * <p>Overwriting a row a player deliberately changed is accepted rather than detected. Shipping
     * one of these is rare and intentional, and the alternative is per-player bookkeeping for a
     * case that comes up about once a release.
     *
     * <p>If the file does not exist yet — a fresh install, before the game has ever run — it is
     * created holding only these rows. Minecraft fills in everything else it knows about on first
     * save, so a partial file is the correct way to seed one rather than a broken one. That is only
     * safe for a flat file: a partial JSON file would be invalid, so a seed with nested rows is
     * skipped rather than created when the file is missing.
     *
     * <p>Nested files are edited a value at a time, never reformatted. The line keeps its
     * indentation, its separator spacing, its trailing comma and any trailing comment; only the
     * value between them is replaced. Nothing here parses JSON, and deliberately so — several of
     * these files are JSON5 with comments the player can read, and a parse-and-rewrite would
     * silently discard them.
     */
    private record PlayerFileSeed(String relativePath, char separator, String token, List<SeedRow> rows) {
    }

        /**
     * The pack's declared player-file rows.
     *
     * <p>v1.0.2 added 3D Default and Actually 3D Blocks & Items, removed Fancy Crops, and reordered
     * the lot. options.txt is never published - it holds every keybind and video setting a player
     * has - so the new packs would otherwise arrive on disk switched off, and the order would reach
     * fresh installs only. Two rows are seeded instead, and the player owns their pack order again
     * the moment the marker is written.
     *
     * <p>The list is safe to set wholesale because resourcepacks is an exact-match root: a player
     * cannot have added a pack of their own for this to discard.
     *
     * <p>incompatibleResourcePacks goes with it. 26.2 is resource format 88 and Actually 3D
     * declares support only to 84, so without its entry there Minecraft treats it as unacknowledged
     * and drops it from the selection on the first launch that reads the row.
     */
    private static final List<PlayerFileSeed> PLAYER_FILE_SEEDS = List.of(
            // 2026-09-26, hardcore: nine seeds inherited from Vanilla+ were cut here because their targets
            // are not in this pack. Four restated the WHOLE resourcePacks row with a Vanilla+ list (v1010,
            // v1034, v1046, v1073) - on a fresh hardcore install they overwrote the master's row with packs
            // this pack has never shipped, and the game silently dropped the missing ones, which is why it
            // looked right. Two warned on every launch because their file never exists on a hardcore
            // client (jade.json, the client-side nbidal18-vanillarefresh.json - our companion is server-only
            // here). One CREATED a stray config/immersive_aircraft.json on every instance. Two added
            // resource packs that do not exist here (Cactus Zombies, AVPBR). A seed named for a target the
            // pack cut leaves with it. Instances that already ran them keep their markers; nothing reverts.
            // load_new_chunks was pinned to false from v1.0.0 to v1.0.7 in the belief that it
            // revealed terrain the player had not visited. It does not: it is read inside
            // MapWriter and is the switch that records chunks onto the map at all, so the world
            // map stayed black for ever. The property rule is gone; this puts it back once on the
            // instances that had it forced off, and the player owns it from then on.
            new PlayerFileSeed("config/xaero/world-map/profiles/default.cfg", '=', "xaero-load-chunks-v1010", List.of(
                    SeedRow.of("load_new_chunks", "true"))),
            // Waypoints were rendering in the world as floating markers as well as on the map.
            // WaypointWorldRenderer is what reads this, so it turns off the in-world markers only
            // and leaves the map alone. Xaero binds a "Toggle In-World Waypoints" key, so a player
            // who wants them back has one already.
            new PlayerFileSeed("config/xaero/minimap/profiles/default.cfg", '=', "xaero-world-waypoints-v1010", List.of(
                    SeedRow.of("waypoints_in_world", "false"))),
            // Auto HUD's global on/off already exists - Hud.toggleHud() flips the whole mod off and
            // the HUD goes back to drawing vanilla, permanently, until it is flipped back. It just
            // ships bound to nothing, so nobody finds it and the only visible way to stop an element
            // hiding is to turn that element off one at a time. H is free in this pack, and F3+H is
            // a chord rather than a binding, so it does not collide.
            new PlayerFileSeed("options.txt", ':', "defaults-v1016", List.of(
                    // Auto HUD's global on/off already exists - Hud.toggleHud() flips the whole mod
                    // off and the HUD goes back to drawing vanilla until it is flipped back. It just
                    // ships bound to nothing, so nobody finds it and the only visible way to stop an
                    // element hiding is to turn that element off one at a time. H is free here, and
                    // F3+H is a chord rather than a binding, so it does not collide.
                    SeedRow.of("key_identifier.autohud.toggle-hud", "key.keyboard.h"),
                    // Simple Voice Chat registers mute on GLFW 77 - M - and Xaero's world map opens
                    // on M too, so a fresh install has both on one key and muting also opens the map.
                    // Neither mod knows about the other; only the pack can break the tie.
                    SeedRow.of("key_key.mute_microphone", "key.keyboard.l"),
                    // The owner's own mix, shipped as the pack's.
                    SeedRow.of("soundCategory_master", "0.2"),
                    SeedRow.of("soundCategory_weather", "0.5"))),
            // The mount's health bar is one of the five the first-party Auto HUD jar groups, so it
            // cannot simply be dropped from the group - alwaysHidden is what stops it drawing, and
            // it is enforced when the element is drawn rather than when it is revealed.
            new PlayerFileSeed("config/autohud.json5", ':', "autohud-mount-health-v1016", List.of(
                    new SeedRow(List.of("elements", "minecraft:mount_health_bar"), "alwaysHidden", "true"))),
            // The crosshair stops being hidden. It was a personal preference that reached everybody:
            // Auto HUD fades the crosshair with the rest of the HUD, and hiding it outright leaves
            // players aiming at nothing whenever the HUD is idle. A separate token from the mount
            // health bar above, because that one has already fired on every instance and a seed
            // never runs twice under the same token.
            new PlayerFileSeed("config/autohud.json5", ':', "autohud-crosshair-v1044", List.of(
                    new SeedRow(List.of("elements", "minecraft:crosshair"), "alwaysHidden", "false"))),
            // Hardcore v1.0.2: Complementary Unbound is the only shader pack. Eclipse, Photon,
            // Rethinking Voxels and E-LITE are gone from shaderpacks/, and with them the two Eclipse
            // settings seeds that used to sit here (eclipse-tuning-v1044, eclipse-clouds-v1074): a
            // seed on a flat file CREATES the file when it is missing, so on a fresh install they
            // would have written an Eclipse sidecar into an exact-match root with no shader behind it.
            //
            // iris.properties is player-class and still names Eclipse in the master, which is left
            // alone on purpose - changing the master re-delivers the whole file over every player's
            // own (enableShaders, colour space, shadow distance). One row instead: the selected pack
            // becomes the one that still exists. A player who later picks something else keeps it.
            // The master row is stale by design, as voxy-config.json's `enabled` is.
            new PlayerFileSeed("config/iris.properties", '=', "shaders-complementary-only-v102", List.of(
                    SeedRow.of("shaderPack", "nbidal18-ComplementaryUnbound_r5.9.3.zip"))),
            // Hardcore v1.0.2: the pack's defaults, seeded onto the instances that predate them. The
            // master options.txt became the owner's own Vanilla+ file on 2026-09-24 (v1.0.0's third
            // build), but options.txt ships only in the setup ZIP, so an instance imported before that
            // kept the rebuild-era file: exclusive fullscreen, vsync off, 260 fps, clouds on, the
            // narrator hotkey, vanilla's own bindings where the pack unbinds (pick block, hotbar 1,
            // voice-chat toggle, hide icons, new waypoint - H is Auto HUD's toggle here) and a mix
            // with music, records, hostile and ambient at full. Owner: "just seed it again".
            //
            // Every row is the master's value, read from the file rather than typed, so a fresh
            // install - where the master has just been written - is left byte-identical.
            new PlayerFileSeed("options.txt", ':', "owner-defaults-v102", List.of(
                    SeedRow.of("enableVsync", "true"),
                    SeedRow.of("exclusiveFullscreen", "false"),
                    SeedRow.of("maxFps", "180"),
                    SeedRow.of("renderClouds", "\"false\""),
                    SeedRow.of("narratorHotkey", "false"),
                    SeedRow.of("key_key.pickItem", "key.keyboard.unknown"),
                    SeedRow.of("key_key.hotbar.1", "key.keyboard.left.bracket"),
                    SeedRow.of("key_key.disable_voice_chat", "key.keyboard.unknown"),
                    SeedRow.of("key_key.hide_icons", "key.keyboard.unknown"),
                    SeedRow.of("key_gui.xaero_new_waypoint", "key.keyboard.unknown"),
                    SeedRow.of("key_identifier.autohud.toggle-hud", "key.keyboard.h"),
                    SeedRow.of("soundCategory_master", "0.20033112582781457"),
                    SeedRow.of("soundCategory_music", "0.0"),
                    SeedRow.of("soundCategory_record", "0.3028169014084507"),
                    SeedRow.of("soundCategory_weather", "0.15845070422535212"),
                    SeedRow.of("soundCategory_hostile", "0.10915492957746478"),
                    SeedRow.of("soundCategory_ambient", "0.2535211267605634"))),
            // Hardcore v1.0.4: the player-animation half of the set-aside comes back - Fresh
            // Animations: Player Extension, drawn by Entity Model Features. The pack has to be selected
            // to do anything, and resourcePacks is a player row, so it is added once here; the master
            // carries it for fresh installs, and an instance that already lists it is left alone. Its
            // place in the order does not matter: it holds only the player's model, which no other
            // pack here touches.
            new PlayerFileSeed("options.txt", ':', "resourcepacks-fa-player-v104", List.of(
                    SeedRow.addToList("resourcePacks", "\"file/FA+Player-v1.1.zip\""))),
            // v1.0.4 (hardcore), the mobs half of the same set-aside, once the player half had been
            // checked in the throwaway: Fresh Animations and its All Extensions pack, the versions
            // Vanilla+ ships (byte-identical to Modrinth's). Both hold only mob models and textures;
            // measured 2026-09-26, they share no file with any other pack here, so their place in the
            // order does not matter either.
            new PlayerFileSeed("options.txt", ':', "resourcepacks-fa-mobs-v104", List.of(
                    SeedRow.addToList("resourcePacks", "\"file/FreshAnimations_v1.10.5.zip\""),
                    SeedRow.addToList("resourcePacks", "\"file/FA+All_Extensions-v1.9.2.zip\""))),
            // v1.0.4 (hardcore), from Incy PLUS. Owner, 2026-09-26: "do fancy crops and recolorful containers".
            // Fancy Crops: crop models and textures, shares no file with any pack here. Recolourful
            // Containers: recoloured GUIs, 462 vanilla GUI textures plus OptiGUI rules (the OptiGUI mod
            // ships with it); it shares one file with FA+All_Extensions - font/default.json - and must
            // draw over it, which addToList's "above the last file pack" does. Both declare formats that
            // cover 26.2, so no incompatibleResourcePacks row.
            new PlayerFileSeed("options.txt", ':', "resourcepacks-crops-containers-v104", List.of(
                    SeedRow.addToList("resourcePacks", "\"file/Fancy Crops v1.3.zip\""),
                    SeedRow.addToList("resourcePacks", "\"file/Recolourful Containers 3.1.3 (1.19.4+).zip\""))),
            // v1.0.76: Sound Physics skips the whole records category unless this is on (read in its
            // processSound), so a jukebox had no occlusion and no reverb. One row, seeded, because the
            // file is preserved for the player and a changed master would replace every copy.
            new PlayerFileSeed("config/sound_physics_remastered/soundphysics.properties", '=', "soundphysics-records-v1076", List.of(
                    SeedRow.of("update_moving_sounds", "true"))),
            // Voxy off by default: its far terrain is the single heaviest thing in the pack on a weak
            // machine.
            //
            // section_render_distance goes back to 1.0, which is what the pack shipped before
            // v1.0.16 raised it to 32.0. That was a mistake: the field is not a chunk count, and at
            // 32.0 the owner's client reported a render distance of 1024. A fresh token, because
            // v1.0.16's marker has already been written on every instance that updated and a seed
            // never fires twice under the same one.
            new PlayerFileSeed("config/voxy-config.json", ':', "voxy-default-off-v1017", List.of(
                    SeedRow.of("enabled", "false"),
                    SeedRow.of("section_render_distance", "1.0"))),
            // v1.0.72: TreeChop binds N to its settings screen. The 4.5.2 pack shipped it unbound - N is
            // a key players use for other things, and the screen is reachable from Mod Menu - so the
            // port ships it the same way. Its other two keys (toggle chopping, cycle sneak behaviour)
            // are unbound upstream already.
            new PlayerFileSeed("options.txt", ':', "treechop-key-v1072", List.of(
                    SeedRow.of("key_treechop.key.open_settings_overlay", "key.keyboard.unknown"))),
            // First Person Model body offsets, pushed to everyone as the owner plays them. Owner,
            // 2026-09-12: "for first person model, u need to push to everyone the default config as how
            // i have it on my instance". His file differs from the pack master in exactly these three
            // keys, 15 against 0; every other key already matched. config/firstperson.json is player
            // class - the F6 toggle writes it, and a player who prefers vanilla first person keeps that
            // choice - so the master cannot carry the new values without re-delivering the whole file
            // over every player. Three rows are seeded instead, once per instance, and a player who then
            // changes an offset keeps the change. The master stays at 0 on purpose.
            new PlayerFileSeed("config/firstperson.json", ':', "firstperson-offsets-v1097", List.of(
                    SeedRow.of("xOffset", "15"),
                    SeedRow.of("sneakXOffset", "15"),
                    SeedRow.of("sitXOffset", "15"))),
            // v1.0.102: Not Enough Animations' own bow draw, the 1.21.1 pack's look, for everyone once.
            // Offered with the Fresh Animations fix (nbidal18-emf), which hands the arms back to NEA
            // while a bow is drawn; owner, 2026-09-19: "Yes". The file is preserved once delivered, so
            // a master change would re-deliver it whole over every player's; this sets the one key.
            // Anyone who sets it back to VANILLA afterwards keeps that. The master stays VANILLA.
            new PlayerFileSeed("config/notenoughanimations.json", ':', "nea-bow-custom-v1102", List.of(
                    SeedRow.of("bowAnimation", "\"CUSTOM_V1\""))),
            // v1.0.4 (hardcore): Sodium Extra's coordinates overlay was shipping on. Owner, 2026-09-26:
            // "we are shipping the default settings with sodium extra show coordinates enabled, disable
            // it". The file is rewritten by the mod and so preserved; the master keeps the form the mod
            // writes and this sets the one key, once. Anyone who turns it back on afterwards keeps that.
            new PlayerFileSeed("config/sodium-extra-options.json", ':', "sodium-extra-coords-off-v104", List.of(
                    SeedRow.in("extra_settings", "show_coords", "false"))));

        /**
     * Empty on purpose, and it must stay that way until a mod is actually retired from THIS
     * pack. The 1.21.1 list named config/voxy-config.json, which this pack publishes: carried
     * over unchanged it would have deleted a shipped file on first launch.
     */
    private static final List<String> RETIRED_LOCAL_FILES = List.of();

    /**
     * Whole directories to remove once, listed separately from the files above.
     *
     * <p>Separate on purpose: deleting a tree is not a mistake anyone should be able to make with a
     * typo in a list of file names. A path here is walked and removed; a path there is a single
     * {@code deleteIfExists}, which throws on a non-empty directory rather than doing something
     * surprising.
     *
     * <p>Both entries are pure render caches of terrain that v1.0.20 changes. Deleting the server's
     * chunks makes every cached image and LOD wrong, and neither mod notices on its own - Voxy
     * keeps showing the old far terrain and Xaero keeps drawing the old map. Voxy's is 6.8 GB on
     * the owner's instance, so this is also the only sane way to reclaim it.
     *
     * <p><b>{@code xaero/minimap} is deliberately absent.</b> That folder is two kilobytes and holds
     * the waypoints - the one Xaero feature this pack kept. The map images live in
     * {@code xaero/world-map}, and taking {@code xaero/} wholesale would throw the pins away with
     * the cache.
     */
    private static final List<String> RETIRED_LOCAL_DIRECTORIES = List.of(
            "xaero/world-map/Multiplayer_194.54.88.14/DIM1",
            "xaero/world-map/Multiplayer_38.103.248.98/DIM1");

    /**
     * Bumped whenever an entry is added above, because the marker below records that the sweep has
     * already run. Without a new token, an instance that applied the previous list would skip the
     * new entries permanently.
     *
     * <p><b>Also bumped whenever the world is regenerated, with the list unchanged.</b> Both entries
     * above are caches describing terrain, so they go stale every time that terrain is replaced, not
     * only when this list grows. v1.0.20 swept them for the first chunk wipe; the world was then
     * cleared a second time for v1.0.23's structure spacing and the sweep did not run, because every
     * instance already held the v1.0.20 marker. That leaves Voxy drawing far terrain, and Xaero
     * drawing map tiles, for a world that no longer exists.
     *
     * <p>v1.0.30 sweeps for a third reason: not a chunk wipe but a stale LOD reset. Voxy World Gen
     * generated nothing for the whole time EasyAuth was installed, so every client's store held far
     * terrain from before that gap and nothing after it - visible in game as flat water planes
     * hanging over the ocean. The server's own record is cleared in the same pass; clearing only one
     * side leaves the two disagreeing about what exists.
     *
     * <p>v1.0.61 sweeps for an eighth, again at the owner's request. nbidal18-voxyworldgen 3.1.0
     * changes what the ledger inside {@code .voxy} means - a chunk is recorded once Voxy has stored
     * it, not once it was handed over - and a ledger written under the old rule can hold chunks
     * Voxy discarded at a logout. Rather than carry those entries into the reading of the new
     * rule, both stores start empty; the server's generation record is deleted in the same deploy,
     * through the deployment plan this time rather than by hand.
     *
     * <p>v1.0.60 sweeps for a seventh, at the owner's request rather than for a fault. v1.0.59 put
     * far terrain under a new pacing and delivery layer (nbidal18-voxyworldgen 3.0.0), and its
     * client-side ledger of received chunks lives inside {@code .voxy} so that the two are always
     * wiped together. The stores filled under stock were not wrong - the new layer re-streams
     * everything on a first join anyway - but a clean sheet means the first readings of the new
     * layer describe only it. The server's generation record is removed in the same pass, as in
     * v1.0.30 and v1.0.55.
     *
     * <p>v1.0.56 sweeps for a sixth. The add-on that paced far terrain is gone and Voxy World Gen
     * runs stock again, so every store filled while it was installed was filled under rules that no
     * longer apply. Clearing both sides means the next reading describes the stock mod rather than
     * the residue of six releases of ours.
     *
     * <p>v1.0.55 sweeps for a fifth, and this one is a reset rather than a fix. Four releases of
     * changing how far terrain is paced ended with the pacing rolled back to its v1.0.52 form, and a
     * store filled during those four releases holds whatever those versions did or did not deliver.
     * Clearing it means the next reading is of the rolled-back build alone, rather than of the
     * rolled-back build plus a store nobody can account for. The server's generation cache is
     * cleared in the same pass, for the reason v1.0.30 gives: clearing one side leaves the two
     * disagreeing about what exists.
     *
     * <p>v1.0.43 sweeps for a fourth: the caches are worth rebuilding now that rebuilding them
     * works. The v1.0.30 sweep was suspected of never having run, because a player holding its
     * marker still had a holed world. It had run - the marker was there and the directory had been
     * deleted - and the store had simply refilled just as holed, because Voxy World Gen was dropping
     * incoming chunks on the floor and never asking for them again. That is fixed in v1.0.42, so a
     * sweep now refills cleanly, which a sweep before it could not.
     *
     * <p>v1.0.63 sweeps again, at the owner's request, so the first reading of the nearest-first
     * order rule and the generator readout describes only them: the server's generation record is
     * removed in the same deploy, and a client ledger that might claim chunks its Voxy store no
     * longer holds goes with the store.
     */
    private static final String RETIRED_LOCAL_FILES_TOKEN = "retired-files-v1109";

    /*
     * v1.0.109 replaces the list above rather than adding to it, and that is deliberate.
     *
     * It used to hold `.voxy` and `xaero/world-map` whole. Both have already run on every instance
     * that exists - the v1.0.63 marker says so - and bumping the token with them still listed would
     * delete them again. Xaero's images are 195 MB, but the owner's Voxy store is 40 GB, and one of
     * this pack's players is on a connection poor enough that re-streaming it was the reason the far
     * terrain work happened at all. A sweep that costs him 40 GB to fix a stale End is the wrong
     * trade by a wide margin.
     *
     * Only the End was regenerated (2026-09-22, twice: the void fix in v1.0.107, then the
     * crashed-ship changes in v1.0.108), so only the End's caches are stale. Xaero stores per
     * dimension - `DIM1` is the End - so both servers' End map images can go while the overworld
     * and Nether images, and every other server's, stay.
     *
     * Voxy is NOT here, and cannot be: its store is keyed by a hash of the biome seed and the
     * dimension, so from out here there is no telling which of five folders is the End. That half is
     * handled inside the game instead, by nbidal18-voxyworldgen 3.8.0's declared ledger resets,
     * which know the mapping and cost only the End's re-stream. See ClientLedger.LEDGER_RESETS.
     *
     * A fresh install has none of these folders and the sweep does nothing, which is why dropping
     * the two historical entries loses nothing.
     */

    private final Path minecraftRoot;
    private final Path stateRoot;
    private final Path lastManifestPath;
    private final Path autoHudConfigPath;
    private final Path autoHudRestorePath;
    private final Path autoHudDefaultMarker;
    private final Path bootstrapPath;
    private final Path installerPath;
    private final String packUrl;
    private final String manifestUrl;
    /** Packwiz prints "(848/857) Downloaded x" for every file it touches. */
    private static final Pattern INSTALLER_PROGRESS =
            Pattern.compile("\\((\\d+)\\s*/\\s*(\\d+)\\)");

    private JFrame updaterWindow;
    private JLabel updaterLabel;
    private JProgressBar updaterProgress;
    private int lastProgressPercent = -1;

    private Nbidal18PackwizSync() {
        String prismMinecraft = System.getenv("INST_MC_DIR");
        minecraftRoot = Path.of(
                prismMinecraft == null || prismMinecraft.isBlank() ? "." : prismMinecraft)
                .toAbsolutePath().normalize();
        stateRoot = minecraftRoot.resolve(".nbidal18-packwiz");
        lastManifestPath = stateRoot.resolve("last-successful-manifest.json");
        autoHudConfigPath = minecraftRoot.resolve("config").resolve("autohud.json5");
        autoHudRestorePath = stateRoot.resolve("autohud.json5.restore");
        autoHudDefaultMarker = stateRoot.resolve("applied-" + AUTOHUD_DEFAULT_TOKEN);
        bootstrapPath = minecraftRoot.resolve("packwiz-installer-bootstrap.jar");
        installerPath = minecraftRoot.resolve("packwiz-installer.jar");
        packUrl = envOrDefault("NBIDAL18_PACK_URL", DEFAULT_PACK_URL);
        manifestUrl = envOrDefault("NBIDAL18_MANIFEST_URL", DEFAULT_MANIFEST_URL);
    }

    public static void main(String[] args) {
        Nbidal18PackwizSync updater = new Nbidal18PackwizSync();
        if (args.length == 1 && "--seed-only".equals(args[0])) {
            System.exit(updater.runSeedsOnly());
        }
        int exitCode = updater.run();
        updater.closeUpdaterWindow();
        System.exit(exitCode);
    }

    /**
     * Applies this release's declared player-file changes to {@code INST_MC_DIR} and stops: no
     * window, no network, no packwiz. For the test tooling, which stages the shipped files straight
     * from the source and so never runs the updater - a throwaway built that way showed every
     * seeded default still at its shipped value (owner, 2026-09-26: "the sodium extra show
     * coordinates is still there"). Running the seeds through this same code, rather than a second
     * implementation in PowerShell, keeps the throwaway an exact copy of what a player gets on Play.
     * Markers are written under the throwaway's own state folder, so nothing here reaches an instance.
     */
    private int runSeedsOnly() {
        try {
            Files.createDirectories(stateRoot);
        } catch (IOException error) {
            warning("Could not create " + stateRoot + ": " + messageOf(error));
            return 1;
        }
        applyPlayerFileChanges();
        status("Seeds applied to " + minecraftRoot + " (--seed-only; nothing else was touched).");
        return 0;
    }

    private int run() {
        Path downloadedManifest = null;
        showUpdaterWindow();
        try {
            Files.createDirectories(stateRoot);
            downloadedManifest = Files.createTempFile(stateRoot, "manifest-", ".tmp");
            boolean updateSucceeded = false;
            boolean autoHudStaged = stageForcedAutoHudDefault();

            try {
                int installerResult = invokePackwizInstaller();
                if (installerResult != 0) {
                    status("The first update check failed; retrying once...");
                    installerResult = invokePackwizInstaller();
                }
                updateSucceeded = installerResult == 0;
                if (updateSucceeded) {
                    downloadCurrentManifest(downloadedManifest);
                }
            } catch (Exception error) {
                warning("The online update check failed: " + messageOf(error));
                updateSucceeded = false;
            }
            finishForcedAutoHudDefault(autoHudStaged, updateSucceeded);

            if (updateSucceeded) {
                SyncManifest current = readSyncManifest(downloadedManifest);
                repairPropertyRules(current);
                status("Verifying installed files...");
                List<String> repairProblems = findSyncProblems(current, true, true);
                boolean needsRepair = repairProblems.stream()
                        .anyMatch(problem -> !problem.startsWith("extra:"));
                if (needsRepair) {
                    status("Repairing missing or modified official files...");
                    if (invokePackwizInstaller() != 0) {
                        throw new IOException("Packwiz could not repair the official files.");
                    }
                }

                if (needsRepair) {
                    status("Confirming the instance is complete...");
                }
                List<String> remaining = findSyncProblems(current, true, false);
                if (!remaining.isEmpty()) {
                    throw new IOException("The instance could not be synchronized: "
                            + String.join(", ", remaining));
                }

                applyPlayerFileChanges();
                Files.move(downloadedManifest, lastManifestPath,
                        StandardCopyOption.REPLACE_EXISTING);
                downloadedManifest = null;
                status("The instance matches v" + current.packVersion + ".");
                return 0;
            }

            if (!Files.isRegularFile(lastManifestPath)) {
                throw new IOException(
                        "The online update could not complete and this instance has never completed its first installation.");
            }

            SyncManifest lastKnown = readSyncManifest(lastManifestPath);
            repairPropertyRules(lastKnown);
            List<String> offlineProblems = findSyncProblems(lastKnown, true, false);
            if (!offlineProblems.isEmpty()) {
                throw new IOException(
                        "The online update could not complete and the last installed release is incomplete: "
                                + String.join(", ", offlineProblems));
            }

            applyPlayerFileChanges();
            warning("The online update could not complete. Starting the last complete installed release; "
                    + "the server will apply its current compatibility policy.");
            return 0;
        } catch (Exception error) {
            System.err.println("[nbidal18 packwiz] " + messageOf(error));
            return 1;
        } finally {
            if (downloadedManifest != null) {
                try {
                    Files.deleteIfExists(downloadedManifest);
                } catch (IOException ignored) {
                    // A stale temporary manifest is harmless and remains outside the load path.
                }
            }
        }
    }

    private int invokePackwizInstaller() throws IOException, InterruptedException {
        if (!Files.isRegularFile(bootstrapPath)) {
            throw new IOException("Packwiz bootstrap is missing: " + bootstrapPath);
        }
        if (!Files.isRegularFile(installerPath)) {
            throw new IOException("Bundled Packwiz installer is missing: " + installerPath);
        }

        // Prism substitutes INST_JAVA in the pre-launch command, but some Prism
        // builds do not export it to the child process. Reuse the Java runtime
        // that is already running this updater instead.
        String currentCommand = ProcessHandle.current().info().command().orElse("");
        Path javaPath;
        if (!currentCommand.isBlank()) {
            javaPath = Path.of(currentCommand).toAbsolutePath().normalize();
        } else {
            boolean windows = System.getProperty("os.name", "")
                    .toLowerCase(Locale.ROOT).contains("win");
            javaPath = Path.of(System.getProperty("java.home"), "bin",
                    windows ? "java.exe" : "java").toAbsolutePath().normalize();
        }
        if (!Files.isRegularFile(javaPath)) {
            throw new IOException("The updater could not locate its running Java runtime: " + javaPath);
        }
        if (javaPath.getFileName().toString().equalsIgnoreCase("javaw.exe")) {
            Path consoleJava = javaPath.resolveSibling("java.exe");
            if (Files.isRegularFile(consoleJava)) {
                javaPath = consoleJava;
            }
        }

        status("Checking GitHub for pack updates...");
        List<String> command = new ArrayList<>();
        command.add(javaPath.toString());
        command.add("-jar");
        command.add(bootstrapPath.toString());
        command.add("--bootstrap-no-update");
        command.add("-g");
        command.add(packUrl);
        ProcessBuilder processBuilder = new ProcessBuilder(command);
        processBuilder.directory(minecraftRoot.toFile());
        // Read the installer's output instead of inheriting it, so the window can show real
        // progress. Packwiz already counts every file it handles - "(848/857) Downloaded x" - and
        // that counter is the only honest source of a percentage the updater has.
        //
        // Every line is echoed to stdout unchanged. Prism's log and this pack's own test harness
        // both read that output, so swallowing it here would break them silently.
        processBuilder.redirectErrorStream(true);
        Process process = processBuilder.start();
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                System.out.println(line);
                applyInstallerProgress(line);
            }
        }
        int exitCode = process.waitFor();
        progressIndeterminate();
        return exitCode;
    }

    /**
     * Drives the progress bar from Packwiz's own "(current/total)" counter.
     *
     * <p>Deliberately forgiving: an unrecognised line simply leaves the bar alone. The installer's
     * output format is not a contract, and a cosmetic bar is never worth failing an update over.
     */
    private void applyInstallerProgress(String line) {
        Matcher matcher = INSTALLER_PROGRESS.matcher(line);
        if (!matcher.find()) {
            return;
        }
        try {
            int current = Integer.parseInt(matcher.group(1));
            int total = Integer.parseInt(matcher.group(2));
            if (total > 0 && current >= 0 && current <= total) {
                progressTo(current, total);
            }
        } catch (NumberFormatException ignored) {
            // A counter too large to parse is not worth reacting to.
        }
    }

    private void downloadCurrentManifest(Path destination)
            throws IOException, InterruptedException {
        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(30))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        HttpRequest request = HttpRequest.newBuilder(URI.create(manifestUrl))
                .timeout(Duration.ofSeconds(30))
                // No version. This used to say 1.0.0 on every release, which made it the one place
                // in this line that spelled a version out instead of reading PACK-VERSION.txt - and
                // it had been wrong since v1.0.1.
                //
                // It is not stamped at build time either, which was the obvious fix. This request
                // is what fetches the manifest, so the only version available here is the updater's
                // own, and stamping it would rebuild these jars on every release: they are published
                // files, so Test-Release would see them change every time and never skip a test
                // again. A true header on a request nobody reads is not worth the test tiering.
                .header("User-Agent", "nbidal18-vanilla-plus")
                .GET()
                .build();
        HttpResponse<byte[]> response = client.send(
                request, HttpResponse.BodyHandlers.ofByteArray());
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Manifest download returned HTTP " + response.statusCode());
        }
        Files.write(destination, response.body());
        readSyncManifest(destination);
    }

    private SyncManifest readSyncManifest(Path path) throws IOException {
        String json = Files.readString(path, StandardCharsets.UTF_8);
        Matcher schema = Pattern.compile("\\\"schema\\\"\\s*:\\s*(\\d+)").matcher(json);
        Matcher version = Pattern.compile(
                "\\\"packVersion\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"")
                .matcher(json);
        String packVersion = version.find() ? jsonUnescape(version.group(1)) : "";
        if (!schema.find() || !"1".equals(schema.group(1))
                || !isSupportedPackVersion(packVersion)) {
            throw new IOException("Unsupported sync manifest in " + path);
        }

        List<String> exactRoots = parseStringArray(json, "exactRoots");
        // Optional: this also parses the manifest the player already had, which predates the field.
        // A manifest without it tolerates nothing, which is exactly the previous behaviour.
        List<String> extraTolerantRoots = new ArrayList<>();
        if (json.contains("\"extraTolerantRoots\"")) {
            for (String tolerant : parseStringArray(json, "extraTolerantRoots")) {
                extraTolerantRoots.add(validateRelative(tolerant));
            }
        }
        Set<String> localAllowed = new HashSet<>();
        for (String allowed : parseStringArray(json, "localAllowed")) {
            localAllowed.add(pathKey(validateRelative(allowed)));
        }

        String filesArray = extractArray(json, "files");
        Matcher fileMatcher = FILE_ENTRY.matcher(filesArray);
        Map<String, FileEntry> files = new LinkedHashMap<>();
        while (fileMatcher.find()) {
            String relative = validateRelative(jsonUnescape(fileMatcher.group(1)));
            FileEntry entry = new FileEntry(relative, fileMatcher.group(2).toLowerCase(Locale.ROOT));
            if (files.put(pathKey(relative), entry) != null) {
                throw new IOException("Duplicate manifest path: " + relative);
            }
        }
        if (files.isEmpty()) {
            throw new IOException("The sync manifest contains no files: " + path);
        }

        String propertyRulesArray = extractArray(json, "propertyRules");
        Matcher propertyRuleMatcher = PROPERTY_RULE.matcher(propertyRulesArray);
        List<PropertyRule> propertyRules = new ArrayList<>();
        Set<String> propertyRuleKeys = new HashSet<>();
        while (propertyRuleMatcher.find()) {
            String relative = validateRelative(jsonUnescape(propertyRuleMatcher.group(1)));
            String key = jsonUnescape(propertyRuleMatcher.group(2));
            String value = jsonUnescape(propertyRuleMatcher.group(3));
            if (!key.matches("[A-Za-z0-9_.-]+") || value.contains("\n") || value.contains("\r")) {
                throw new IOException("Invalid property rule for " + relative);
            }
            String relativeKey = pathKey(relative);
            if (!files.containsKey(relativeKey) || !localAllowed.contains(relativeKey)) {
                throw new IOException("Property rule path must be a preserved managed file: " + relative);
            }
            if (!propertyRuleKeys.add(relativeKey + "\u0000" + key)) {
                throw new IOException("Duplicate property rule: " + relative + "#" + key);
            }
            propertyRules.add(new PropertyRule(relative, key, value));
        }
        if (propertyRules.isEmpty()) {
            throw new IOException("The sync manifest contains no property rules: " + path);
        }
        return new SyncManifest(
                packVersion, exactRoots, extraTolerantRoots, localAllowed, files, propertyRules);
    }

    /**
     * Accepts both {@code 4.2.3-packwiz} and the bare {@code 4.3.0}.
     *
     * <p>The suffix is being retired: packwiz is a known part of the pack, so the number alone says
     * everything. It cannot be dropped in one release, because whichever updater a player already
     * has is the one that validates the next manifest — an updater that demanded the suffix would
     * reject the first suffix-less release outright, abandon the update and silently leave that
     * player on their installed build forever. This release teaches the updater both forms so a
     * later one can stop writing the suffix. Keep accepting both: some client will always be a
     * release or two behind.
     */
    private static boolean isSupportedPackVersion(String value) {
        Matcher matcher = Pattern.compile("(\\d+)\\.(\\d+)\\.(\\d+)(?:-packwiz)?").matcher(value);
        if (!matcher.matches()) {
            return false;
        }
        try {
            int[] candidate = {
                    Integer.parseInt(matcher.group(1)),
                    Integer.parseInt(matcher.group(2)),
                    Integer.parseInt(matcher.group(3))
            };
            for (int index = 0; index < candidate.length; index++) {
                if (candidate[index] != MINIMUM_PACK_VERSION[index]) {
                    return candidate[index] > MINIMUM_PACK_VERSION[index];
                }
            }
            return true;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private List<String> findSyncProblems(
            SyncManifest manifest, boolean cleanExtras, boolean prepareRepair) throws Exception {
        List<String> problems = new ArrayList<>();
        // Hashing every managed file is the second long stretch of an update, and on a slow disk
        // it is the one that looks most like a hang. It has an exact total, so it gets a real
        // percentage too rather than sitting on whatever the installer left behind.
        int checked = 0;
        int toCheck = manifest.files.size();
        for (FileEntry entry : manifest.files.values()) {
            progressTo(checked++, toCheck);
            if (manifest.localAllowed.contains(pathKey(entry.path))) {
                continue;
            }
            Path target = resolveRelative(entry.path);
            if (!Files.isRegularFile(target)) {
                problems.add("missing:" + entry.path);
                continue;
            }
            String actual = sha256(target);
            if (!actual.equals(entry.sha256)) {
                problems.add("modified:" + entry.path);
                if (prepareRepair) {
                    moveOutOfLoadPath(target, "modified managed file");
                }
            }
        }

        // Nothing below counts anything, and it is quick. Back to a moving bar.
        progressIndeterminate();

        for (PropertyRule rule : manifest.propertyRules) {
            Path target = resolveRelative(rule.path);
            if (!Files.isRegularFile(target)
                    || !rule.value.equals(readPropertyValue(target, rule.key))) {
                problems.add("property:" + rule.path + "#" + rule.key);
            }
        }

        for (String rootName : manifest.exactRoots) {
            String relativeRoot = validateRelative(rootName);
            Path rootPath = resolveRelative(relativeRoot);
            if (!Files.isDirectory(rootPath)) {
                continue;
            }
            try (Stream<Path> paths = Files.walk(rootPath)) {
                for (Path file : paths.filter(Files::isRegularFile).toList()) {
                    String relative = getRelativePath(file);
                    String key = pathKey(relative);
                    if (manifest.files.containsKey(key) || manifest.localAllowed.contains(key)
                            || manifest.isExtraTolerant(relative)) {
                        continue;
                    }
                    problems.add("extra:" + relative);
                    if (cleanExtras) {
                        moveOutOfLoadPath(file, "not present in the official pack");
                    }
                }
            }
        }
        return problems;
    }

    private void repairPropertyRules(SyncManifest manifest) throws IOException {
        for (PropertyRule rule : manifest.propertyRules) {
            Path target = resolveRelative(rule.path);
            if (!Files.isRegularFile(target)
                    || rule.value.equals(readPropertyValue(target, rule.key))) {
                continue;
            }
            List<String> original = Files.readAllLines(target, StandardCharsets.UTF_8);
            Pattern propertyLine = Pattern.compile(
                    "^\\s*" + Pattern.quote(rule.key) + "\\s*[:=].*$");
            List<String> repaired = new ArrayList<>();
            for (String line : original) {
                if (!propertyLine.matcher(line).matches()) {
                    repaired.add(line);
                }
            }
            repaired.add(rule.key + "=" + rule.value);
            Files.write(target, repaired, StandardCharsets.UTF_8);
            status("Reset protected shader option " + rule.key + " while preserving other settings.");
        }
    }

    private static String readPropertyValue(Path path, String key) throws IOException {
        Pattern propertyLine = Pattern.compile(
                "^\\s*" + Pattern.quote(key) + "\\s*[:=]\\s*(.*?)\\s*$");
        String value = null;
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            Matcher matcher = propertyLine.matcher(line);
            if (matcher.matches()) {
                value = matcher.group(1);
            }
        }
        return value;
    }

    /**
     * Removes the player's Auto HUD config once so the sync restores this release's defaults.
     * The old file is kept aside and put back if the update does not complete, so a failed or
     * offline launch never leaves the instance without it. Returns true when a copy was staged.
     */
    private boolean stageForcedAutoHudDefault() {
        try {
            if (Files.exists(autoHudDefaultMarker) || !Files.isRegularFile(autoHudConfigPath)) {
                return false;
            }
            Files.copy(autoHudConfigPath, autoHudRestorePath, StandardCopyOption.REPLACE_EXISTING);
            Files.delete(autoHudConfigPath);
            // Say plainly that this file is going back to the shipped defaults. The older wording,
            // "other personal settings are untouched", read as though the rest of this file
            // survived; only other files do. The seeding mechanism is the one that changes named
            // values and leaves the rest of a file alone, and it should not be confused with this.
            status("Resetting the Auto HUD settings to this release's defaults once;"
                    + " any personal changes in that file are replaced, and no other file is touched.");
            return true;
        } catch (IOException error) {
            warning("Could not reissue the Auto HUD defaults; the existing settings were kept: "
                    + messageOf(error));
            return false;
        }
    }

    private void finishForcedAutoHudDefault(boolean staged, boolean updateSucceeded) {
        try {
            if (updateSucceeded) {
                // Marked even when nothing was staged, so a fresh install does not reissue later.
                Files.deleteIfExists(autoHudRestorePath);
                Files.writeString(autoHudDefaultMarker, AUTOHUD_DEFAULT_TOKEN + System.lineSeparator(),
                        StandardCharsets.UTF_8);
            } else if (staged && Files.isRegularFile(autoHudRestorePath)) {
                Files.createDirectories(autoHudConfigPath.getParent());
                Files.move(autoHudRestorePath, autoHudConfigPath, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException error) {
            warning("Could not finish reissuing the Auto HUD defaults: " + messageOf(error));
        }
    }

    /**
     * Applies this release's declared changes to player-owned files.
     *
     * <p>There is no resource-pack migration here, and there should not be one. The 1.21.1 updater
     * carries one because that pack replaced several packs in place; this line's first release was
     * v1.0.0, so nothing predates it. Carried over unchanged it added a pack this pack has never
     * shipped to every player's options.txt on every launch.
     */
    private void applyPlayerFileChanges() {
        applyPlayerFileSeeds();
        applyServerListSeeds();
        removeRetiredLocalFiles();
    }

    /**
     * A server the pack adds to the player's multiplayer list, once.
     *
     * <p>servers.dat ships in the client ZIP as a first-install default and is never published,
     * because the updater would otherwise reset every player's own server list on each update.
     * So an entry added later - the hardcore server of 2026-09-10 - reaches an existing instance
     * only through this: the entry is appended if no entry with its address is there yet, the
     * marker is written, and the list is the player's again. Nothing is ever removed or reordered.
     */
    private record ServerListSeed(String token, String name, String ip, String movedFrom, String renamedFrom) {
        static ServerListSeed added(String token, String name, String ip) {
            return new ServerListSeed(token, name, ip, null, null);
        }

        static ServerListSeed moved(String token, String name, String ip, String movedFrom) {
            return new ServerListSeed(token, name, ip, movedFrom, null);
        }

        /**
         * The pack's own entry gets a new display name - the address is unchanged. Only an entry
         * still carrying the old name is renamed: a player who already renamed it keeps theirs.
         */
        static ServerListSeed renamed(String token, String name, String ip, String renamedFrom) {
            return new ServerListSeed(token, name, ip, null, renamedFrom);
        }
    }

    private static final String SERVER_LIST = "servers.dat";
    // Hardcore v1.0.2: BOTH servers in the list, on purpose. Owner, 2026-09-24: "we will keep both
    // the vanilla+ and vanilla+ hardcore server entries in multiplayer, so players know that there
    // is another server they could join, but need a different modpack." A hardcore client cannot
    // log in there - the two packs have different manifest digests - and Better Compatibility
    // Checker draws the entry red with the other pack's name, which is exactly the hint intended.
    //
    // The shipped servers.dat carries both again (it was trimmed to the hardcore server alone on
    // 2026-09-23, under v1.0.0). This seed reaches the instances imported between the two: appended
    // once, only if no entry with that address is there, and the list is the player's again.
    private static final List<ServerListSeed> SERVER_LIST_SEEDS = List.of(
            ServerListSeed.added("servers-vanilla-plus-v102", "nbidal18 Vanilla+", "194.54.88.14:27107"),
            // v1.0.5: the line is Vanilla++ - normal survival on the old hardcore world. Owner,
            // 2026-09-26: "so this becomes a second vanilla plus, more vanilla than the other". Same
            // address, new name; an entry a player renamed themselves is left as it is.
            ServerListSeed.renamed("servers-vanilla-plus-plus-v105", "nbidal18 Vanilla++",
                    "38.103.248.98:27037", "nbidal18 Vanilla+ Hardcore"));

    private void applyServerListSeeds() {
        for (ServerListSeed seed : SERVER_LIST_SEEDS) {
            try {
                if (applyServerListSeed(seed)) {
                    status("Added " + seed.name() + " to the multiplayer server list; every other entry was left alone.");
                }
            } catch (Exception error) {
                warning("Could not add " + seed.name() + " to the multiplayer server list; it was left unchanged: "
                        + messageOf(error));
            }
        }
    }

    @SuppressWarnings("unchecked")
    private boolean applyServerListSeed(ServerListSeed seed) throws IOException {
        Path marker = stateRoot.resolve("applied-" + seed.token());
        if (Files.exists(marker)) {
            return false;
        }
        Path target = minecraftRoot.resolve(SERVER_LIST).normalize();
        if (!target.startsWith(minecraftRoot)) {
            throw new IOException("The declared path escapes the instance: " + SERVER_LIST);
        }
        if (Files.isSymbolicLink(target)) {
            throw new IOException(SERVER_LIST + " is a symbolic link");
        }

        Map<String, Object> root;
        if (Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) {
            if (Files.size(target) > 4L * 1024L * 1024L) {
                throw new IOException(SERVER_LIST + " is unexpectedly large");
            }
            byte[] bytes = Files.readAllBytes(target);
            if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0x1F && (bytes[1] & 0xFF) == 0x8B) {
                throw new IOException(SERVER_LIST + " is compressed, which the game never writes");
            }
            root = Nbt.read(bytes);
        } else {
            root = new LinkedHashMap<>();
        }

        Object listObject = root.get("servers");
        Nbt.ListTag servers;
        if (listObject == null) {
            servers = new Nbt.ListTag((byte) Nbt.COMPOUND, new ArrayList<>());
        } else if (listObject instanceof Nbt.ListTag list && (list.type() == Nbt.COMPOUND || list.items().isEmpty())) {
            servers = new Nbt.ListTag((byte) Nbt.COMPOUND, new ArrayList<>(list.items()));
        } else {
            throw new IOException("servers is not a list of servers");
        }

        Map<String, Object> first = null;
        Map<String, Object> moveTarget = null;
        for (Object item : servers.items()) {
            if (!(item instanceof Map<?, ?> entry)) {
                continue;
            }
            if (first == null) {
                first = (Map<String, Object>) entry;
            }
            if (seed.ip().equalsIgnoreCase(String.valueOf(entry.get("ip")))) {
                if (seed.renamedFrom() != null
                        && seed.renamedFrom().equals(String.valueOf(entry.get("name")))) {
                    // The rename: one field, and only while the entry still says what the pack
                    // used to call itself. Anything the player renamed stays theirs.
                    ((Map<String, Object>) entry).put("name", seed.name());
                    root.put("servers", servers);
                    writeServerList(target, root);
                    Files.createDirectories(stateRoot);
                    writeSeedMarker(marker, seed.token(), SERVER_LIST, true);
                    status("The pack's server entry is now called " + seed.name()
                            + "; nothing else in the multiplayer list was touched.");
                    return false;
                }
                // Already on the new address - a fresh install, or this seed has run before under
                // another token. Mark and leave the list alone.
                Files.createDirectories(stateRoot);
                writeSeedMarker(marker, seed.token(), SERVER_LIST, false);
                return false;
            }
            if (seed.movedFrom() != null && moveTarget == null
                    && seed.movedFrom().equalsIgnoreCase(String.valueOf(entry.get("ip")))) {
                moveTarget = (Map<String, Object>) entry;
            }
        }

        // A move rewrites the one field that changed. The player may have renamed the entry or
        // dragged it up the list, and both are theirs to keep - only `ip` is ours.
        if (moveTarget != null) {
            moveTarget.put("ip", seed.ip());
            root.put("servers", servers);
            writeServerList(target, root);
            Files.createDirectories(stateRoot);
            writeSeedMarker(marker, seed.token(), SERVER_LIST, true);
            status(seed.name() + " has moved to " + seed.ip()
                    + "; its entry in the multiplayer list was updated and nothing else was touched.");
            return false;
        }

        Map<String, Object> entry = new LinkedHashMap<>();
        // The pack's own icon, which the first entry carries; a list with no entries gets none.
        if (first != null && first.get("icon") instanceof String icon) {
            entry.put("icon", icon);
        }
        entry.put("name", seed.name());
        entry.put("ip", seed.ip());
        entry.put("acceptTextures", (byte) 1);
        entry.put("hidden", (byte) 0);
        servers.items().add(entry);
        root.put("servers", servers);

        writeServerList(target, root);
        Files.createDirectories(stateRoot);
        writeSeedMarker(marker, seed.token(), SERVER_LIST, true);
        return true;
    }

    /** Writes servers.dat through a temporary file, so an interrupted run cannot leave a torn list. */
    private void writeServerList(Path target, Map<String, Object> root) throws IOException {
        byte[] written = Nbt.write(root);
        Path temporary = target.resolveSibling(
                target.getFileName() + ".nbidal18-" + UUID.randomUUID() + ".tmp");
        try {
            Files.createDirectories(target.getParent());
            Files.write(temporary, written);
            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    /**
     * Deletes the files listed in {@link #RETIRED_LOCAL_FILES}, once per instance.
     *
     * <p>Guarded the same way as everything else that writes into a player's instance: the path is
     * resolved against the instance root and rejected if it escapes it or turns out to be a
     * symbolic link, so a declaration can only ever delete inside the pack's own folder.
     */
    private void removeRetiredLocalFiles() {
        Path marker = stateRoot.resolve("applied-" + RETIRED_LOCAL_FILES_TOKEN);
        try {
            if (Files.exists(marker)) {
                return;
            }
            int removed = 0;
            for (String relative : RETIRED_LOCAL_FILES) {
                Path target = minecraftRoot.resolve(relative).normalize();
                if (!target.startsWith(minecraftRoot) || Files.isSymbolicLink(target)) {
                    warning("Refusing to remove the retired file " + relative
                            + ": it does not resolve inside this instance.");
                    continue;
                }
                if (Files.deleteIfExists(target)) {
                    removed++;
                }
            }
            for (String relative : RETIRED_LOCAL_DIRECTORIES) {
                Path target = minecraftRoot.resolve(relative).normalize();
                if (!target.startsWith(minecraftRoot) || target.equals(minecraftRoot)
                        || Files.isSymbolicLink(target)) {
                    warning("Refusing to remove the retired directory " + relative
                            + ": it does not resolve inside this instance.");
                    continue;
                }
                if (deleteTree(target, describeCache(relative))) {
                    removed++;
                }
            }
            // Prove it before recording it. The marker means "this sweep is done", and writing one
            // for a sweep that did not finish retires the job silently - the next launch skips it and
            // nobody ever finds out. A locked file throws out of the delete and is caught below, so
            // the marker is not written and the sweep runs again next launch; this catches the
            // quieter case where nothing threw and something is still there anyway.
            List<String> survivors = new ArrayList<>();
            for (String relative : RETIRED_LOCAL_DIRECTORIES) {
                Path target = minecraftRoot.resolve(relative).normalize();
                if (target.startsWith(minecraftRoot) && Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
                    survivors.add(relative);
                }
            }
            if (!survivors.isEmpty()) {
                warning("Could not fully clear " + String.join(", ", survivors)
                        + " - it will be tried again on the next launch."
                        + " Close Minecraft fully if this keeps happening.");
                return;
            }

            Files.createDirectories(stateRoot);
            Files.writeString(marker, RETIRED_LOCAL_FILES_TOKEN + System.lineSeparator(),
                    StandardCharsets.UTF_8);
            if (removed != 0) {
                status("Removed " + removed + " configuration file(s) left behind by a retired mod.");
            }
        } catch (Exception error) {
            warning("Could not remove the configuration left behind by a retired mod: "
                    + messageOf(error));
        }
    }

    /**
     * Removes a directory and everything under it, refusing to follow a symbolic link out.
     *
     * <p>Every path is re-checked against the instance root as the walk proceeds rather than only
     * at the top. A link planted inside the tree is the one way a contained-looking delete reaches
     * outside it, and this runs unattended on someone else's machine.
     *
     * @return whether anything was there to remove
     */
    private boolean deleteTree(Path root, String label) throws IOException {
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) {
            return false;
        }
        List<Path> doomed = new ArrayList<>();
        long bytes = 0L;
        // Files.walk does not follow symbolic links unless asked to, which is the behaviour wanted.
        try (Stream<Path> walk = Files.walk(root)) {
            for (Path path : (Iterable<Path>) walk::iterator) {
                doomed.add(path);
                if (Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
                    bytes += Files.size(path);
                }
            }
        }
        // Deepest first, so a directory is only removed once it is empty.
        doomed.sort(Comparator.comparingInt(Path::getNameCount).reversed());

        // Voxy's cache runs to several gigabytes across tens of thousands of files. Deleting that
        // silently looks like the updater has hung, so it reports like any other step - named, sized
        // and on the bar - rather than happening behind a stale "Checking files" label.
        status("Clearing " + label + " (" + describeSize(bytes) + ")");
        int done = 0;
        int total = doomed.size();
        for (Path path : doomed) {
            Path normalized = path.normalize();
            if (!normalized.startsWith(minecraftRoot) || normalized.equals(minecraftRoot)) {
                warning("Refusing to remove " + path + ": it escapes this instance.");
                return false;
            }
            Files.deleteIfExists(path);
            done++;
            // Every 250 entries: often enough to move visibly, rarely enough not to spend the whole
            // delete repainting a label.
            if (done % 250 == 0 || done == total) {
                progressTo(done, total);
            }
        }
        status("Cleared " + label + ", " + describeSize(bytes) + " freed");
        return true;
    }

    /**
     * A player-facing name for a retired cache directory.
     *
     * <p>The label on screen should say what is being cleared, not print a relative path at someone
     * mid-launch. Anything unlisted falls back to the path, which is still better than nothing.
     */
    private static String describeCache(String relative) {
        if (relative.startsWith("xaero/world-map/") && relative.endsWith("/DIM1")) {
            return "Xaero's map images for the End";
        }
        return switch (relative) {
            case ".voxy" -> "Voxy's far-terrain cache";
            case "xaero/world-map" -> "Xaero's map images";
            default -> relative;
        };
    }

    /** Bytes as something a player reads at a glance, rather than a ten-digit number. */
    private static String describeSize(long bytes) {
        if (bytes >= 1024L * 1024L * 1024L) {
            return String.format(Locale.ROOT, "%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0));
        }
        if (bytes >= 1024L * 1024L) {
            return String.format(Locale.ROOT, "%.0f MB", bytes / (1024.0 * 1024.0));
        }
        return String.format(Locale.ROOT, "%.0f KB", Math.max(1.0, bytes / 1024.0));
    }

    /**
     * Applies every declared player-file seed that has not been applied on this instance yet.
     *
     * <p>Failures are warnings rather than errors on purpose: these are conveniences, and a player
     * whose {@code options.txt} is unreadable should still get their update. The marker is only
     * written when the rows actually landed, so a failure retries on the next launch.
     */
    private void applyPlayerFileSeeds() {
        for (PlayerFileSeed seed : PLAYER_FILE_SEEDS) {
            try {
                if (applyPlayerFileSeed(seed)) {
                    status("Applied this release's defaults to " + seed.relativePath()
                            + "; every other personal setting was left alone.");
                }
            } catch (Exception error) {
                warning("Could not apply this release's defaults to " + seed.relativePath()
                        + "; it was left unchanged: " + messageOf(error));
            }
        }
    }

    private boolean applyPlayerFileSeed(PlayerFileSeed seed) throws IOException {
        Path marker = stateRoot.resolve("applied-" + seed.token());
        if (Files.exists(marker)) {
            return false;
        }

        Path target = minecraftRoot.resolve(seed.relativePath()).normalize();
        if (!target.startsWith(minecraftRoot)) {
            throw new IOException("The declared path escapes the instance: " + seed.relativePath());
        }
        if (Files.isSymbolicLink(target)) {
            throw new IOException(seed.relativePath() + " is a symbolic link");
        }

        List<String> lines = new ArrayList<>();
        boolean existed = Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS);
        if (existed) {
            if (Files.size(target) > 16L * 1024L * 1024L) {
                throw new IOException(seed.relativePath() + " is unexpectedly large");
            }
            lines.addAll(Files.readAllLines(target, StandardCharsets.UTF_8));
        }

        boolean nested = seed.rows().stream().anyMatch(row -> !row.parents().isEmpty());
        if (!existed && nested) {
            // Creating a flat file from scratch is fine; creating a structured one is not. Writing
            // two keys and no enclosing braces would leave a file the mod cannot read.
            throw new IOException(seed.relativePath()
                    + " does not exist yet, and a seed with nested rows cannot create one");
        }

        boolean structured = isStructured(lines);

        boolean changed = false;
        for (SeedRow row : seed.rows()) {
            // Recomputed per row: a flat file can gain or lose a line, and stale contexts would no
            // longer line up with it.
            changed |= applySeedRow(lines, lineContexts(lines), structured, seed, row);
        }

        if (!changed) {
            // Still mark it: the rows already say what we wanted, and leaving the marker off would
            // re-check them on every launch forever.
            Files.createDirectories(stateRoot);
            writeSeedMarker(marker, seed, false);
            return false;
        }

        Path temporary = target.resolveSibling(
                target.getFileName() + ".nbidal18-" + UUID.randomUUID() + ".tmp");
        try {
            Files.createDirectories(target.getParent());
            Files.writeString(temporary, String.join(System.lineSeparator(), lines)
                    + System.lineSeparator(), StandardCharsets.UTF_8);
            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }

        Files.createDirectories(stateRoot);
        writeSeedMarker(marker, seed, true);
        return true;
    }

    /**
     * The marker records the token, the file the seed named and whether it actually changed it.
     * Test-LocalSync reads the last two: a player-class file that a seed changed on a fresh install
     * is allowed to differ from the published copy, because the published copy must not carry the
     * seeded value (changing it would re-deliver the file over every player's own edits), so the
     * seed is the only place that value lives. Older markers held the token alone; the reader
     * treats a marker without a third line as "unchanged".
     */
    private static void writeSeedMarker(Path marker, PlayerFileSeed seed, boolean changed) throws IOException {
        writeSeedMarker(marker, seed.token(), seed.relativePath(), changed);
    }

    private static void writeSeedMarker(Path marker, String token, String relativePath, boolean changed) throws IOException {
        Files.writeString(marker, token + System.lineSeparator()
                + relativePath + System.lineSeparator()
                + (changed ? "changed" : "unchanged") + System.lineSeparator(), StandardCharsets.UTF_8);
    }

    /**
     * Sets one declared row, matching on its full path rather than its key alone.
     *
     * <p>A flat file behaves exactly as it did before paths existed: the last occurrence of a key
     * wins, earlier duplicates are dropped, and a key that is not there is appended.
     *
     * <p>A structured file is never appended to and never has a line removed. Appending would put
     * the key outside the braces it belongs in, and removing a line can leave the comma on the line
     * above dangling. Both are refused rather than attempted, so a declaration that does not match
     * reality fails loudly at the warning level and leaves the file exactly as it was.
     */
    private static boolean applySeedRow(List<String> lines, List<List<String>> contexts,
            boolean structured, PlayerFileSeed seed, SeedRow row) throws IOException {
        List<Integer> matches = new ArrayList<>();
        for (int index = 0; index < lines.size(); index++) {
            List<String> context = contexts.get(index);
            if (context == null || !context.equals(row.parents())) {
                continue;
            }
            if (row.key().equals(keyOf(lines.get(index)))) {
                matches.add(index);
            }
        }

        if (row.addToList()) {
            if (structured || !row.parents().isEmpty()) {
                throw new IOException("Adding to " + describe(row) + " in " + seed.relativePath()
                        + " is only supported for a bare key in a flat file");
            }
            if (matches.isEmpty()) {
                return false;
            }
            int last = matches.get(matches.size() - 1);
            String line = lines.get(last);
            int separator = separatorIndex(line);
            String current = line.substring(separator + 1).strip();
            String updated = addToJsonList(current, row.value(), row.atBottom());
            if (updated == null) {
                throw new IOException(describe(row) + " in " + seed.relativePath() + " is not a list");
            }
            if (updated.equals(current)) {
                return false;
            }
            lines.set(last, line.substring(0, separator + 1) + updated);
            return true;
        }

        if (row.value() == null) {
            if (structured) {
                throw new IOException("Removing " + describe(row) + " from " + seed.relativePath()
                        + " is not supported in a structured file");
            }
            boolean removed = false;
            for (int index = matches.size() - 1; index >= 0; index--) {
                lines.remove((int) matches.get(index));
                removed = true;
            }
            return removed;
        }

        if (matches.isEmpty()) {
            // Appending is only ever right for a bare key in a flat file. A row that declares
            // parents describes a place inside a structure, and appending it at the end would put
            // the key somewhere it does not belong while looking like it worked.
            if (structured || !row.parents().isEmpty()) {
                throw new IOException(describe(row) + " was not found in " + seed.relativePath());
            }
            lines.add(row.key() + seed.separator() + row.value());
            return true;
        }

        boolean changed = false;
        // The last occurrence is the one the game reads, so that is the one to set.
        int last = matches.get(matches.size() - 1);
        String updated = replaceValue(lines.get(last), row.value());
        if (!updated.equals(lines.get(last))) {
            lines.set(last, updated);
            changed = true;
        }
        if (!structured) {
            for (int index = matches.size() - 2; index >= 0; index--) {
                lines.remove((int) matches.get(index));
                changed = true;
            }
        }
        return changed;
    }

    /**
     * Whether this file has structure worth protecting — braces, arrays or section headers.
     *
     * <p>A flat file may be appended to and may have lines removed. A structured one may not: a key
     * appended after the closing brace is outside the document, and a removed line can leave the
     * comma above it dangling. The opening brace is checked directly as well as the nesting,
     * because a JSON file that happens to hold no nested object would otherwise look flat.
     */
    private static boolean isStructured(List<String> lines) {
        for (String line : lines) {
            String trimmed = line.strip();
            if (trimmed.isEmpty()) {
                continue;
            }
            if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
                return true;
            }
            break;
        }
        return lineContexts(lines).stream()
                .anyMatch(context -> context == null || !context.isEmpty());
    }

    private static String describe(SeedRow row) {
        return String.join(".", row.parents()) + (row.parents().isEmpty() ? "" : ".") + row.key();
    }

    /**
     * The chain of named objects or sections each line sits inside, one entry per line, or
     * {@code null} for a line inside an array.
     *
     * <p>A flat {@code key=value} file never nests, so every entry is empty and matching a row with
     * no declared parents behaves exactly as a bare key match did. The unnamed object a JSON file
     * opens with does not count as a level, so a top-level JSON key is also reached with no
     * parents.
     *
     * <p>Lines inside an array are deliberately unreachable. Array elements have no stable name to
     * address them by, and a seed that matched one would be matching a position rather than a key.
     */
    private static List<List<String>> lineContexts(List<String> lines) {
        List<List<String>> contexts = new ArrayList<>(lines.size());
        List<String> stack = new ArrayList<>();
        List<String> section = new ArrayList<>();
        int arrayDepth = 0;

        for (String line : lines) {
            String trimmed = line.strip();
            // A TOML or INI header replaces the section context rather than nesting inside it.
            if (arrayDepth == 0 && stack.isEmpty() && trimmed.length() > 2
                    && trimmed.startsWith("[") && trimmed.endsWith("]")
                    && separatorIndex(trimmed) < 0) {
                section = new ArrayList<>();
                for (String part : trimmed.substring(1, trimmed.length() - 1).split("\\.")) {
                    section.add(unquote(part.strip()));
                }
                contexts.add(null);
                continue;
            }

            if (arrayDepth > 0) {
                contexts.add(null);
            } else {
                List<String> here = new ArrayList<>(section);
                for (String enclosing : stack) {
                    if (enclosing != null) {
                        here.add(enclosing);
                    }
                }
                contexts.add(List.copyOf(here));
            }

            // Advance the structure only after recording it, so the key written on a line that
            // opens an object is judged by the context it was written in, not the one it opens.
            String opening = keyOf(line);
            for (int index = 0; index < line.length(); index++) {
                char character = line.charAt(index);
                if (character == '"') {
                    index = endOfString(line, index);
                } else if (character == '[') {
                    arrayDepth++;
                } else if (character == ']') {
                    arrayDepth = Math.max(0, arrayDepth - 1);
                } else if (character == '{' && arrayDepth == 0) {
                    // A null entry keeps the stack balanced for the closing brace without adding a
                    // level, which is how the unnamed outermost brace of a JSON document is
                    // skipped: a top-level key is reached with no declared parents, exactly as in
                    // a flat file.
                    stack.add(opening);
                    opening = null;
                } else if (character == '}' && arrayDepth == 0 && !stack.isEmpty()) {
                    stack.remove(stack.size() - 1);
                }
            }
        }
        return contexts;
    }

    /**
     * The key a line declares, unquoted, or null if it declares none. The comparison against a
     * declared row is made on the unquoted form so a seed reads the same whether the file quotes
     * its keys or not.
     */
    private static String keyOf(String line) {
        int separator = separatorIndex(line);
        if (separator < 0) {
            return null;
        }
        String key = line.substring(0, separator).strip();
        return key.isEmpty() ? null : unquote(key);
    }

    /** The first {@code :} or {@code =} outside a quoted string, or -1. */
    private static int separatorIndex(String line) {
        for (int index = 0; index < line.length(); index++) {
            char character = line.charAt(index);
            if (character == '"') {
                index = endOfString(line, index);
            } else if (character == ':' || character == '=') {
                return index;
            }
        }
        return -1;
    }

    /** The index of the closing quote of the string starting at {@code start}, escapes honoured. */
    private static int endOfString(String line, int start) {
        for (int index = start + 1; index < line.length(); index++) {
            char character = line.charAt(index);
            if (character == '\\') {
                index++;
            } else if (character == '"') {
                return index;
            }
        }
        return line.length();
    }

    private static String unquote(String text) {
        return text.length() >= 2 && text.startsWith("\"") && text.endsWith("\"")
                ? text.substring(1, text.length() - 1)
                : text;
    }

    /**
     * Replaces only the value on a {@code key: value} line.
     *
     * <p>Indentation, the separator and the spacing around it, any trailing comma and any trailing
     * comment all survive untouched. That is what makes this safe on a JSON file: the line is the
     * same line afterwards, with one token different.
     */
    private static String replaceValue(String line, String value) {
        int separator = separatorIndex(line);
        String head = line.substring(0, separator + 1);
        String tail = line.substring(separator + 1);

        // A trailing comment is part of the line, not part of the value, and several of these files
        // are JSON5 whose comments are the only explanation a player has of what a setting does.
        int comment = commentIndex(tail);
        String trailingComment = comment < 0 ? "" : tail.substring(comment);
        String body = comment < 0 ? tail : tail.substring(0, comment);

        int start = 0;
        while (start < body.length() && (body.charAt(start) == ' ' || body.charAt(start) == '\t')) {
            start++;
        }
        String spacing = body.substring(0, start);
        String rest = body.substring(start);

        int end = rest.length();
        while (end > 0 && Character.isWhitespace(rest.charAt(end - 1))) {
            end--;
        }
        if (end > 0 && rest.charAt(end - 1) == ',') {
            end--;
        }
        return head + spacing + value + rest.substring(end) + trailingComment;
    }

    /**
     * {@code list} with {@code element} added after its last {@code "file/..."} entry - a pack later
     * in resourcePacks draws over the ones before it, and the built-in packs listed after the files
     * stay where they are - or at the end when there is no such entry. With {@code atBottom} it goes
     * before the first {@code "file/..."} entry instead, under every file pack and above
     * {@code "vanilla"}. Returned unchanged when the element is already there, and null when
     * {@code list} is not a JSON list.
     */
    private static String addToJsonList(String list, String element, boolean atBottom) {
        if (list.length() < 2 || list.charAt(0) != '[' || list.charAt(list.length() - 1) != ']') {
            return null;
        }
        List<String> elements = new ArrayList<>();
        int end = list.length() - 1;
        int index = 1;
        while (index < end) {
            char character = list.charAt(index);
            if (character == ',' || Character.isWhitespace(character)) {
                index++;
                continue;
            }
            int start = index;
            if (character == '"') {
                index = endOfString(list, index) + 1;
            } else {
                while (index < end && list.charAt(index) != ',') {
                    index++;
                }
            }
            elements.add(list.substring(start, Math.min(index, end)).strip());
        }
        if (elements.contains(element)) {
            return list;
        }
        int insertAt = elements.size();
        if (atBottom) {
            for (int position = 0; position < elements.size(); position++) {
                if (elements.get(position).startsWith("\"file/")) {
                    insertAt = position;
                    break;
                }
            }
        } else {
            for (int position = elements.size() - 1; position >= 0; position--) {
                if (elements.get(position).startsWith("\"file/")) {
                    insertAt = position + 1;
                    break;
                }
            }
        }
        elements.add(insertAt, element);
        return "[" + String.join(",", elements) + "]";
    }

    /** Where a trailing {@code //} or {@code #} comment starts, outside strings, or -1. */
    private static int commentIndex(String text) {
        for (int index = 0; index < text.length(); index++) {
            char character = text.charAt(index);
            if (character == '"') {
                index = endOfString(text, index);
            } else if (character == '#'
                    || (character == '/' && index + 1 < text.length() && text.charAt(index + 1) == '/')) {
                return index;
            }
        }
        return -1;
    }

    private void moveOutOfLoadPath(Path path, String reason) throws IOException {
        if (!Files.isRegularFile(path)) {
            return;
        }
        String relative = getRelativePath(path);
        String stamp = LocalDateTime.now().format(MOVE_STAMP);
        Path destination = stateRoot.resolve("removed-local-files")
                .resolve(stamp).resolve(relative.replace('/', java.io.File.separatorChar))
                .normalize();
        Path removalRoot = stateRoot.resolve("removed-local-files").normalize();
        if (!destination.startsWith(removalRoot)) {
            throw new IOException("Removal destination escaped the updater state directory: " + destination);
        }
        Files.createDirectories(destination.getParent());
        if (Files.exists(destination)) {
            destination = destination.resolveSibling(
                    destination.getFileName() + "." + UUID.randomUUID().toString().replace("-", ""));
        }
        Files.move(path, destination);
        status("Moved " + relative + " out of the load path (" + reason + ").");
    }

    private String getRelativePath(Path path) throws IOException {
        Path full = path.toAbsolutePath().normalize();
        if (!full.startsWith(minecraftRoot)) {
            throw new IOException("Path escapes the Minecraft directory: " + full);
        }
        return minecraftRoot.relativize(full).toString()
                .replace(java.io.File.separatorChar, '/');
    }

    private Path resolveRelative(String relative) throws IOException {
        Path resolved = minecraftRoot.resolve(relative.replace('/', java.io.File.separatorChar))
                .normalize();
        if (!resolved.startsWith(minecraftRoot)) {
            throw new IOException("Path escapes the Minecraft directory: " + relative);
        }
        return resolved;
    }

    private static String validateRelative(String value) throws IOException {
        String relative = value.replace('\\', '/');
        while (relative.startsWith("/")) {
            relative = relative.substring(1);
        }
        if (relative.isBlank() || relative.contains(":")
                || relative.equals("..") || relative.startsWith("../")
                || relative.endsWith("/..") || relative.contains("/../")) {
            throw new IOException("Invalid manifest path: " + value);
        }
        return relative;
    }

    private static String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] buffer = new byte[1024 * 128];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (count > 0) {
                    digest.update(buffer, 0, count);
                }
            }
        }
        StringBuilder result = new StringBuilder(64);
        for (byte value : digest.digest()) {
            result.append(String.format("%02x", value & 0xff));
        }
        return result.toString();
    }

    private static List<String> parseStringArray(String json, String property) throws IOException {
        String array = extractArray(json, property);
        List<String> values = new ArrayList<>();
        Matcher matcher = JSON_STRING.matcher(array);
        while (matcher.find()) {
            values.add(jsonUnescape(matcher.group(1)));
        }
        return values;
    }

    private static String extractArray(String json, String property) throws IOException {
        Matcher propertyMatcher = Pattern.compile(
                "\\\"" + Pattern.quote(property) + "\\\"\\s*:").matcher(json);
        if (!propertyMatcher.find()) {
            throw new IOException("Missing manifest property: " + property);
        }
        int start = json.indexOf('[', propertyMatcher.end());
        if (start < 0) {
            throw new IOException("Manifest property is not an array: " + property);
        }
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        for (int index = start; index < json.length(); index++) {
            char current = json.charAt(index);
            if (inString) {
                if (escaped) {
                    escaped = false;
                } else if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    inString = false;
                }
                continue;
            }
            if (current == '"') {
                inString = true;
            } else if (current == '[') {
                depth++;
            } else if (current == ']' && --depth == 0) {
                return json.substring(start + 1, index);
            }
        }
        throw new IOException("Unterminated manifest array: " + property);
    }

    private static String jsonUnescape(String value) throws IOException {
        StringBuilder output = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char current = value.charAt(index);
            if (current != '\\') {
                output.append(current);
                continue;
            }
            if (++index >= value.length()) {
                throw new IOException("Invalid JSON escape");
            }
            char escaped = value.charAt(index);
            switch (escaped) {
                case '"', '\\', '/' -> output.append(escaped);
                case 'b' -> output.append('\b');
                case 'f' -> output.append('\f');
                case 'n' -> output.append('\n');
                case 'r' -> output.append('\r');
                case 't' -> output.append('\t');
                case 'u' -> {
                    if (index + 4 >= value.length()) {
                        throw new IOException("Invalid JSON unicode escape");
                    }
                    try {
                        output.append((char) Integer.parseInt(
                                value.substring(index + 1, index + 5), 16));
                    } catch (NumberFormatException error) {
                        throw new IOException("Invalid JSON unicode escape", error);
                    }
                    index += 4;
                }
                default -> throw new IOException("Invalid JSON escape: \\" + escaped);
            }
        }
        return output.toString();
    }

    private void showUpdaterWindow() {
        if ("1".equals(System.getenv("NBIDAL18_HEADLESS_TEST"))
                || GraphicsEnvironment.isHeadless()) {
            return;
        }
        try {
            SwingUtilities.invokeAndWait(() -> {
                updaterWindow = new JFrame("nbidal18 updater");
                updaterWindow.setDefaultCloseOperation(WindowConstants.DO_NOTHING_ON_CLOSE);
                updaterWindow.setAlwaysOnTop(true);
                updaterWindow.setResizable(false);

                JPanel content = new JPanel(new BorderLayout(0, 12));
                content.setBorder(BorderFactory.createEmptyBorder(18, 18, 18, 18));
                updaterLabel = new JLabel("Preparing the modpack update...", SwingConstants.CENTER);
                updaterProgress = new JProgressBar(0, 100);
                updaterProgress.setIndeterminate(true);
                // The percentage is painted on the bar itself rather than added as another label,
                // so the window does not change size when progress starts or stops being known.
                updaterProgress.setStringPainted(true);
                updaterProgress.setString("");
                updaterProgress.setPreferredSize(new Dimension(424, 22));
                content.add(updaterLabel, BorderLayout.CENTER);
                content.add(updaterProgress, BorderLayout.SOUTH);
                updaterWindow.setContentPane(content);
                updaterWindow.pack();
                updaterWindow.setLocationRelativeTo(null);
                updaterWindow.setVisible(true);
            });
        } catch (Exception error) {
            updaterWindow = null;
            updaterLabel = null;
            updaterProgress = null;
        }
    }

    /**
     * Shows a real percentage. Called from the installer's output thread, so it hops to Swing.
     */
    private void progressTo(int current, int total) {
        JProgressBar bar = updaterProgress;
        if (bar == null) {
            return;
        }
        int percent = (int) Math.round((current * 100.0) / total);
        // Only when the number actually changes. Verifying 857 files would otherwise queue 857
        // repaints to draw about a hundred distinct states.
        if (percent == lastProgressPercent) {
            return;
        }
        lastProgressPercent = percent;
        SwingUtilities.invokeLater(() -> {
            bar.setIndeterminate(false);
            bar.setValue(percent);
            bar.setString(percent + "%");
        });
    }

    /**
     * Back to a moving bar with no number, for the stretches where nothing counts anything —
     * contacting GitHub, verifying the manifest, staging the next updater.
     */
    private void progressIndeterminate() {
        JProgressBar bar = updaterProgress;
        if (bar == null) {
            return;
        }
        lastProgressPercent = -1;
        SwingUtilities.invokeLater(() -> {
            bar.setIndeterminate(true);
            bar.setString("");
        });
    }

    private void closeUpdaterWindow() {
        if (updaterWindow == null) {
            return;
        }
        try {
            SwingUtilities.invokeAndWait(() -> updaterWindow.dispose());
        } catch (Exception ignored) {
            // The updater has already finished; an unavailable window is harmless.
        }
    }

    private void status(String message) {
        System.out.println("[nbidal18 packwiz] " + message);
        JLabel label = updaterLabel;
        if (label != null) {
            SwingUtilities.invokeLater(() -> label.setText(message));
        }
    }

    private static void warning(String message) {
        System.err.println("[nbidal18 packwiz] WARNING: " + message);
    }

    private static String envOrDefault(String name, String defaultValue) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? defaultValue : value;
    }

    private static String pathKey(String path) {
        return path.replace('\\', '/').toLowerCase(Locale.ROOT);
    }

    private static String messageOf(Throwable error) {
        String message = error.getMessage();
        return message == null || message.isBlank() ? error.getClass().getSimpleName() : message;
    }

    private static final class FileEntry {
        private final String path;
        private final String sha256;

        private FileEntry(String path, String sha256) {
            this.path = path;
            this.sha256 = sha256;
        }
    }

    private static final class PropertyRule {
        private final String path;
        private final String key;
        private final String value;

        private PropertyRule(String path, String key, String value) {
            this.path = path;
            this.key = key;
            this.value = value;
        }
    }

    private static final class SyncManifest {
        private final String packVersion;
        private final List<String> exactRoots;
        private final List<String> extraTolerantRoots;
        private final Set<String> localAllowed;
        private final Map<String, FileEntry> files;
        private final List<PropertyRule> propertyRules;

        private SyncManifest(
                String packVersion,
                List<String> exactRoots,
                List<String> extraTolerantRoots,
                Set<String> localAllowed,
                Map<String, FileEntry> files,
                List<PropertyRule> propertyRules) {
            this.packVersion = packVersion;
            this.exactRoots = List.copyOf(exactRoots);
            this.extraTolerantRoots = List.copyOf(extraTolerantRoots);
            this.localAllowed = Set.copyOf(localAllowed);
            this.files = Map.copyOf(files);
            this.propertyRules = List.copyOf(propertyRules);
        }

        /**
         * Whether an unmanaged file at this path may simply be left alone. Config libraries write
         * their own files while Minecraft starts, so cleaning one here achieves nothing: the game
         * recreates it during mod init and the integrity check then refuses the login, every
         * launch, with no way for the player to clear it.
         */
        private boolean isExtraTolerant(String relative) {
            String key = pathKey(relative);
            for (String root : extraTolerantRoots) {
                String rootKey = pathKey(root);
                if (key.equals(rootKey) || key.startsWith(rootKey + "/")) {
                    return true;
                }
            }
            return false;
        }
    }

    /**
     * Uncompressed NBT, complete enough to read a servers.dat and write it back unchanged but for
     * the entry added. Every tag type is carried, so a file the game later extends round-trips.
     * Strings use {@code DataInput.readUTF}'s modified UTF-8, which is what the game writes.
     * Compounds are {@link LinkedHashMap}s (order kept), lists are {@link ListTag}s, numbers are
     * their boxed Java types, arrays are Java arrays.
     */
    static final class Nbt {
        static final int BYTE = 1;
        static final int SHORT = 2;
        static final int INT = 3;
        static final int LONG = 4;
        static final int FLOAT = 5;
        static final int DOUBLE = 6;
        static final int BYTE_ARRAY = 7;
        static final int STRING = 8;
        static final int LIST = 9;
        static final int COMPOUND = 10;
        static final int INT_ARRAY = 11;
        static final int LONG_ARRAY = 12;

        record ListTag(byte type, List<Object> items) {
        }

        private Nbt() {
        }

        static Map<String, Object> read(byte[] bytes) throws IOException {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
            int type = in.readByte();
            if (type != COMPOUND) {
                throw new IOException("root is not a compound");
            }
            in.readUTF();
            Map<String, Object> root = readCompound(in);
            if (in.available() != 0) {
                throw new IOException("trailing bytes after the root compound");
            }
            return root;
        }

        static byte[] write(Map<String, Object> root) throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bytes);
            out.writeByte(COMPOUND);
            out.writeUTF("");
            writeCompound(out, root);
            out.flush();
            return bytes.toByteArray();
        }

        private static Map<String, Object> readCompound(DataInputStream in) throws IOException {
            Map<String, Object> map = new LinkedHashMap<>();
            while (true) {
                int type = in.readByte();
                if (type == 0) {
                    return map;
                }
                String name = in.readUTF();
                map.put(name, readPayload(in, type));
            }
        }

        private static int count(DataInputStream in) throws IOException {
            int n = in.readInt();
            if (n < 0) {
                throw new IOException("negative length");
            }
            return n;
        }

        private static Object readPayload(DataInputStream in, int type) throws IOException {
            switch (type) {
                case BYTE:
                    return in.readByte();
                case SHORT:
                    return in.readShort();
                case INT:
                    return in.readInt();
                case LONG:
                    return in.readLong();
                case FLOAT:
                    return in.readFloat();
                case DOUBLE:
                    return in.readDouble();
                case BYTE_ARRAY: {
                    byte[] array = new byte[count(in)];
                    in.readFully(array);
                    return array;
                }
                case STRING:
                    return in.readUTF();
                case LIST: {
                    byte elementType = in.readByte();
                    int n = count(in);
                    List<Object> items = new ArrayList<>(Math.min(n, 1024));
                    for (int i = 0; i < n; i++) {
                        items.add(readPayload(in, elementType));
                    }
                    return new ListTag(elementType, items);
                }
                case COMPOUND:
                    return readCompound(in);
                case INT_ARRAY: {
                    int[] array = new int[count(in)];
                    for (int i = 0; i < array.length; i++) {
                        array[i] = in.readInt();
                    }
                    return array;
                }
                case LONG_ARRAY: {
                    long[] array = new long[count(in)];
                    for (int i = 0; i < array.length; i++) {
                        array[i] = in.readLong();
                    }
                    return array;
                }
                default:
                    throw new IOException("unknown tag type " + type);
            }
        }

        private static int typeOf(Object value) throws IOException {
            if (value instanceof Byte) {
                return BYTE;
            }
            if (value instanceof Short) {
                return SHORT;
            }
            if (value instanceof Integer) {
                return INT;
            }
            if (value instanceof Long) {
                return LONG;
            }
            if (value instanceof Float) {
                return FLOAT;
            }
            if (value instanceof Double) {
                return DOUBLE;
            }
            if (value instanceof byte[]) {
                return BYTE_ARRAY;
            }
            if (value instanceof String) {
                return STRING;
            }
            if (value instanceof ListTag) {
                return LIST;
            }
            if (value instanceof Map) {
                return COMPOUND;
            }
            if (value instanceof int[]) {
                return INT_ARRAY;
            }
            if (value instanceof long[]) {
                return LONG_ARRAY;
            }
            throw new IOException("cannot write a " + (value == null ? "null" : value.getClass().getSimpleName()));
        }

        @SuppressWarnings("unchecked")
        private static void writeCompound(DataOutputStream out, Map<String, Object> map) throws IOException {
            for (Map.Entry<String, Object> entry : map.entrySet()) {
                int type = typeOf(entry.getValue());
                out.writeByte(type);
                out.writeUTF(entry.getKey());
                writePayload(out, type, entry.getValue());
            }
            out.writeByte(0);
        }

        @SuppressWarnings("unchecked")
        private static void writePayload(DataOutputStream out, int type, Object value) throws IOException {
            switch (type) {
                case BYTE:
                    out.writeByte((Byte) value);
                    break;
                case SHORT:
                    out.writeShort((Short) value);
                    break;
                case INT:
                    out.writeInt((Integer) value);
                    break;
                case LONG:
                    out.writeLong((Long) value);
                    break;
                case FLOAT:
                    out.writeFloat((Float) value);
                    break;
                case DOUBLE:
                    out.writeDouble((Double) value);
                    break;
                case BYTE_ARRAY: {
                    byte[] array = (byte[]) value;
                    out.writeInt(array.length);
                    out.write(array);
                    break;
                }
                case STRING:
                    out.writeUTF((String) value);
                    break;
                case LIST: {
                    ListTag list = (ListTag) value;
                    out.writeByte(list.type());
                    out.writeInt(list.items().size());
                    for (Object item : list.items()) {
                        writePayload(out, list.type(), item);
                    }
                    break;
                }
                case COMPOUND:
                    writeCompound(out, (Map<String, Object>) value);
                    break;
                case INT_ARRAY: {
                    int[] array = (int[]) value;
                    out.writeInt(array.length);
                    for (int item : array) {
                        out.writeInt(item);
                    }
                    break;
                }
                case LONG_ARRAY: {
                    long[] array = (long[]) value;
                    out.writeInt(array.length);
                    for (long item : array) {
                        out.writeLong(item);
                    }
                    break;
                }
                default:
                    throw new IOException("unknown tag type " + type);
            }
        }
    }
}
