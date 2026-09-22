<#
    Rebuilds nbidal18-Immersive-Interfaces-26.2.zip from the published release plus our overlay.

      scripts\Build-ImmersiveInterfaces.ps1

    The pack is **the published Modrinth release, whole**, with a small overlay laid on top. It is
    built this way because building it any other way went wrong twice in one evening:

      - v1.0.33 shipped a build of the author's GitHub `main`. That repository is NOT a complete
        pack - it is missing every `lang/*.json`, and in this pack those are not translations. The
        container art is drawn as glyphs and the language files are what map each container to its
        art, so every storage block fell back to a bare grid with a literal title.
      - The first zip of it was written with backslash entry paths, which Windows PowerShell's
        ZipFile.CreateFromDirectory produces. Minecraft opened the pack, found no assets, and
        applied nothing. It read as "the pack is broken" when the packaging was.

    Hence: forward slashes, explicitly, and the release zip as the base.

    The overlay lives beside the release in `5. modpack source\custom packs\
    nbidal18-Immersive-Interfaces\overlay\`, mirroring the pack's own layout. Every file in it is
    either the author's 26.2 work, a port written here, or a deliberate retexture:

      _26.2_shaders/.../position_tex_color.vsh   the author's 26.2 port, from GitHub, in no release
      _26.2_shaders/.../text.vsh                 written here. 26.2 renamed `rendertype_text` to
                                                 `text`, so the pack's text shader was a dead file
                                                 and its glyph-drawn container art was positioned by
                                                 vanilla, landing offset from its panel
      assets/.../interfaces.glsl                 the author's, plus a fix: upstream corrects the quad
                                                 corner index for batched draws inside interfaces(),
                                                 but the three posCheck helpers still used the raw
                                                 gl_VertexID. Chest sizing is a chain of those, so it
                                                 never matched, `rows` stayed 0, and every chest,
                                                 barrel, ender and copper chest drew the one-row frame
      pack.mcmeta                                the author's, declaring the _26.2_shaders overlay
      assets/betterend|lootr/lang/en_us.json     38 fallback keys so modded containers use vanilla
                                                 art. Each is the mod's own display name plus the
                                                 marker glyphs. betterend's chest boats had no
                                                 translation at all, hence the raw keys on screen
      .../hotbar_selection.png                   vanilla's shape, tinted to the pack's wood and
      .../slot_highlight_front.png               thinned from a 4px border to 2px. Sampled from the
      .../slot_highlight_back.png                pack's own slot.png: wood #B38C58, lifted to #E8B672

    Note the pack's `slot_highlight_front.png.mcmeta` is deliberately NOT carried over: the pack's
    highlight was 24x48 with two animation frames and vanilla's is a static 24x24, so keeping the
    mcmeta would point an animation at frames that no longer exist.

    Re-run this whenever the overlay changes, or to move to a newer upstream release: drop the new
    zip in, and anything the author has since fixed can come out of the overlay.
#>
[CmdletBinding()]
param(
    [string] $ReleaseRoot,
    # The published Modrinth release this is built on. Downloaded if absent.
    [string] $Version = '0.8.2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = Split-Path -Parent $PSScriptRoot
$packVersion = (Get-Content -LiteralPath (Join-Path $repo 'PACK-VERSION.txt') -Raw).Trim()
$prefix = & (Join-Path $PSScriptRoot 'ReleaseLine.ps1')
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path (Split-Path -Parent $repo) "$prefix$packVersion" }
if (-not (Test-Path -LiteralPath $ReleaseRoot)) { throw "No release folder at $ReleaseRoot" }

$source = Join-Path $ReleaseRoot '5. modpack source\custom packs\nbidal18-Immersive-Interfaces'
$overlay = Join-Path $source 'overlay'
if (-not (Test-Path -LiteralPath $overlay)) { throw "No overlay at $overlay" }

# ---------------------------------------------------------------- the published release, as the base
$base = Join-Path $source ("upstream-$Version.zip")
if (-not (Test-Path -LiteralPath $base -PathType Leaf)) {
    Write-Host ("fetch     Immersive Interfaces {0} from Modrinth" -f $Version)
    $versions = Invoke-RestMethod -TimeoutSec 60 `
        -Uri 'https://api.modrinth.com/v2/project/shrimps-immersive-interfaces/version'
    $v = $versions | Where-Object { $_.version_number -eq $Version } | Select-Object -First 1
    if (-not $v) { throw "Modrinth has no Immersive Interfaces version $Version" }
    $file = $v.files | Where-Object { $_.primary } | Select-Object -First 1
    Invoke-WebRequest -Uri $file.url -OutFile $base -TimeoutSec 300
}
Write-Host ("base      {0} ({1:N0} B)" -f (Split-Path $base -Leaf), (Get-Item -LiteralPath $base).Length)

$overlayFiles = @{}
$overlayRoot = [IO.Path]::GetFullPath($overlay).TrimEnd([char]92) + [string][char]92
foreach ($f in (Get-ChildItem -LiteralPath $overlay -Recurse -File)) {
    $rel = [IO.Path]::GetFullPath($f.FullName).Substring($overlayRoot.Length).Replace([char]92, '/')
    $overlayFiles[$rel] = [IO.File]::ReadAllBytes($f.FullName)
}
Write-Host ("overlay   {0} files" -f $overlayFiles.Count)

# The pack's animated highlight has no counterpart in vanilla's static one - see the header.
$drop = @('assets/minecraft/textures/gui/sprites/container/slot_highlight_front.png.mcmeta')

$out = Join-Path $ReleaseRoot '3. modpack\client\resourcepacks\nbidal18-Immersive-Interfaces-26.2.zip'
$replaced = 0; $added = 0; $kept = 0; $dropped = 0
$in = [IO.Compression.ZipFile]::OpenRead($base)
$fs = [IO.File]::Create($out)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in ($in.Entries | Sort-Object FullName)) {
        if ($entry.FullName.EndsWith('/')) { continue }
        # macOS resource forks; they only produce "Non [a-z0-9_.-] character in namespace" warnings
        if ($entry.FullName -like '*__MACOSX*') { continue }
        if ($drop -contains $entry.FullName) { $dropped++; continue }

        # Entry names must use forward slashes. CreateFromDirectory does not, and a pack whose
        # paths contain backslashes loads with no assets at all.
        $written = $zip.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
        $stream = $written.Open()
        if ($overlayFiles.ContainsKey($entry.FullName)) {
            $bytes = $overlayFiles[$entry.FullName]; $overlayFiles.Remove($entry.FullName); $replaced++
        }
        else {
            $buffer = New-Object IO.MemoryStream; $entry.Open().CopyTo($buffer)
            $bytes = $buffer.ToArray(); $kept++
        }
        $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
    }
    # whatever is left in the overlay is new to the release - the 26.2 shaders, the fallback langs
    foreach ($name in @($overlayFiles.Keys | Sort-Object)) {
        $written = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $stream = $written.Open()
        $stream.Write($overlayFiles[$name], 0, $overlayFiles[$name].Length); $stream.Close()
        $added++
    }
}
finally { $zip.Dispose(); $fs.Close(); $in.Dispose() }

Write-Host ("built     {0}" -f (Split-Path $out -Leaf))
Write-Host ("          {0} kept from upstream, {1} replaced, {2} added, {3} dropped" -f $kept, $replaced, $added, $dropped)

# ---------------------------------------------------------------- prove it is loadable
$check = [IO.Compression.ZipFile]::OpenRead($out)
try {
    $backslash = @($check.Entries | Where-Object { $_.FullName.Contains([char]92) }).Count
    if ($backslash) { throw "$backslash entries have backslash paths - Minecraft would load no assets" }
    foreach ($required in @('pack.mcmeta', 'assets/minecraft/lang/en_us.json',
            '_26.2_shaders/assets/minecraft/shaders/core/position_tex_color.vsh',
            '_26.2_shaders/assets/minecraft/shaders/core/text.vsh')) {
        if (-not ($check.Entries | Where-Object { $_.FullName -eq $required })) {
            throw "missing from the built pack: $required"
        }
    }
    $langs = @($check.Entries | Where-Object { $_.FullName -like 'assets/minecraft/lang/*.json' }).Count
    if ($langs -lt 100) { throw "only $langs language files - the container art is drawn from these" }
    Write-Host ("verified  {0} entries, {1} language files, no backslash paths" -f $check.Entries.Count, $langs)
}
finally { $check.Dispose() }

Write-Host ''
Write-Host 'OK        run Build-Release.ps1 to fold this into the pack.'
