# Swipe Animation for KOReader

A software page-turn **"wipe" animation** for KOReader on e-ink devices, packaged as a
**regular, self-contained plugin**: drop one folder into `koreader/plugins/` and you are
done. No `patches/` folder, no KOReader file is overwritten, nothing to restore when you
remove it.

This is a fork of
[koplugin-swipe-animation/Swipe_Animation.koplugin](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin)
(GPLv3). The animation, its tuning, the settings keys and the menu come from there and
existing settings carry over. What changed:

| | Original patch set (v4.x) | This plugin (v5.x) |
|---|---|---|
| Install | Copy three files into `koreader/patches/` **and overwrite** `koreader/frontend/ui/uimanager.lua` with a bundled copy | Copy the `swipeanimation.koplugin` folder into `koreader/plugins/` |
| Uninstall | Delete the patches and restore the original `uimanager.lua` from a backup | Delete the folder |
| KOReader updates | The bundled `uimanager.lua` has to be re-merged on every KOReader release | Nothing to do |
| Framebuffer work per turn | Four full-frame copies/blits (eight on colour devices) and two large allocations | None |
| Kobo MTK pre-animation sync | Always on | Switchable in the menu |
| Full-refresh rules (clearing, chapters, images) | Re-implemented inside the patch | KOReader's own rules and settings apply |
| Strip count | Fixed (8 portrait / 6 landscape) | Configurable per orientation |

## Features

* Smooth strip-based page-turn animation in both directions, portrait and landscape
* Works on devices without hardware animation support (all Kobo, older Kindles, …)
* Also animates fixed-layout documents (PDF, DjVu, CBZ, …)
* Strip refresh mode: **UI** (default) or **Fast** (quicker, more ghosting)
* Separate frame delay (ms) and strip count for portrait and landscape; delay `0` means no
  extra pause
* **Mild global refresh**: replace the periodic full (flashing) refresh by a partial one
* Kobo MTK (Clara BW / Colour, Libra Colour, …) refresh fence (switchable) and
  driver-aligned strips
* English, Chinese and Brazilian Portuguese menu strings

## Requirements and tested devices

* KOReader **2026.07.1 or later** (the release that introduced the page-turn animation
  plumbing in `ReaderView`).
* **Tested only on a Kobo Clara BW** so far. The code paths for other Kobo models, Kindles
  and other Linux e-ink devices are the same as in the original patch set, which was
  tested widely, but they have not been exercised with this plugin yet. Reports welcome.
* Not recommended on Android, for the same reason as upstream: the software animation does
  not look good there.

## Installation

1. Download `swipeanimation.koplugin.zip` from the
   [latest release](https://github.com/glaucon1984/swipeanimation.koplugin/releases/latest)
   and unzip it. You get a folder named `swipeanimation.koplugin`.
2. Copy that folder into `koreader/plugins/` on the device (for example
   `.adds/koreader/plugins/` on Kobo, `koreader/plugins/` on Kindle).
3. Restart KOReader.
4. Open a book. The animation is enabled by default the first time the plugin runs. It can
   be toggled under **Settings (⚙) → Taps and gestures → Page turns → Page turn
   animations** (or at the top of the settings menu below).

If you clone this repository instead of using the release zip, make sure the folder ends
up named exactly `swipeanimation.koplugin`.

### Migrating from the original patch set

Remove the patch version first; running both would animate twice. Follow the
[uninstallation steps in the original README](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin/blob/main/README_en.md#uninstallation):
delete the three `2-*.lua` files from `koreader/patches/` and restore the stock
`koreader/frontend/ui/uimanager.lua` (from the original repository's `restore-files`
folder, or by reinstalling KOReader over itself). Then install this plugin as above. Your
delay, refresh-mode and mild-refresh settings are kept.

## Uninstallation

Delete `koreader/plugins/swipeanimation.koplugin` and restart KOReader. Nothing else was
touched.

## Settings

```
Settings (⚙)
└── Taps and gestures
    ├── Page turns
    │   └── ☑ Page turn animations
    └── Swipe animation settings
        ├── ☑ Page turn animations        (same setting as above)
        ├── Swipe animation refresh mode
        │   ├── ○ UI refresh (default, recommended)
        │   └── ○ Fast refresh (fastest, more ghosting)
        ├── Portrait / Landscape animation frame delay: … ms
        ├── Portrait / Landscape animation steps: …
        ├── ☑ Mild global refresh
        └── ☑ Kobo MTK: sync panel before animation   (Kobo MTK devices only)
```

Long-press an entry for its description.

### Chapter-boundary flashes

The plugin follows KOReader's own refresh rules, so KOReader's chapter option behaves
exactly as documented: with **Always flash on chapter boundaries** on, KOReader flashes on
the first page of a chapter *and* when leaving it (the second page going forward, the
previous chapter's last page going backward). To flash only once, on the chapter's first
page, enable **Settings (⚙) → Screen → E-ink settings → Full refresh rate → Always flash
on chapter boundaries → except on the second page of a new chapter**. The original patch
flashed only once because its re-implementation of this rule never saw the previous page
number.

## How it works without patching KOReader

The original had to edit `UIManager:_repaint()` because the animation must run *after*
the new page is painted into the framebuffer and *instead of* the queued screen refresh.
The plugin gets the same seam at runtime:

* `UIManager` caches `Screen.refreshPartial()` and friends when it loads, but those
  functions dispatch dynamically to `Screen.refreshPartialImp()` etc. The plugin wraps the
  `*Imp` methods on the live `Screen` object, so it sees every physical refresh.
* `Screen:beforePaint()` / `Screen:afterPaint()` bracket each repaint and give the plugin
  a place to arm itself for a page turn and to reset afterwards.
* `ReaderView:onPageChangeAnimation()` already calls `Screen:setSwipeAnimations(true)` and
  `Screen:setSwipeDirection(forward)` before a page turn. On non-MTK devices those are
  empty stubs, so the plugin wraps them to record the request, and it makes
  `Device:canDoSwipeAnimation()` answer `true` while a book is open so KOReader shows the
  toggle and fires the event.
* For paged documents, `ReaderPaging._gotoPage()` is wrapped to emit the same event
  (upstream only emits it from `ReaderRolling`).

### Performance

An e-ink panel keeps showing whatever it last displayed in any region that is not
refreshed. So once KOReader has painted the new page into the framebuffer, the wipe is
simply a sequence of strip refreshes of the framebuffer as it is. The plugin therefore does
**no framebuffer copies and no blits at all**; the only work per turn is the strip refresh
calls and the optional pause between them. (The original snapshotted the framebuffer
before the page was painted, copied the new page, blitted the old page back and then
blitted each strip.)

On Kobo MTK devices the original always issued a "fence" before the strips: wait for the
previous update, send one no-change full-screen AUTO update, wait for it. The plugin does
the same from the first `beforePaint()` of the turn, while the framebuffer still holds the
previous page, so it needs no snapshot either. It is a switch (*Kobo MTK: sync panel before
animation*, on by default); if page turns look just as even with it off, leave it off and
the first strip starts sooner.

The remaining knobs are the strip count and the frame delay. Fewer strips or a shorter
delay make the turn faster; *Fast refresh* (DU waveform) makes each strip cheaper on MTK
Kobos in particular, because the driver does not wait for the submission of DU updates, at
the cost of more ghosting.

### Full refreshes

The plugin does **not** re-implement KOReader's full-refresh rules. The periodic clearing
refresh ("Full refresh rate"), chapter-boundary flashes and image-page flashes all arrive as
a *flashing* refresh in the repaint queue, so the plugin lets those through unanimated (or
downgrades them to a partial refresh when *Mild global refresh* is on). Behaviour follows
KOReader's own settings exactly.

## Development

The plugin is plain Lua with no build step. A syntax check is enough to catch most
mistakes:

```bash
luajit -bl main.lua > /dev/null && luajit -bl swipehook.lua > /dev/null && luajit -bl swipemenu.lua > /dev/null
```

Files:

* `main.lua` — plugin entry point (installs the hooks on first use, registers the menu)
* `swipehook.lua` — runtime hooks and the animation itself
* `swipemenu.lua` — settings menu and translations
* `_meta.lua` — plugin metadata

## Credits

* Original patch set: `xhs:5699990012` (original author), **nuku**, **Echoes**,
  **小红薯6809667F**, **斯普特尼克的漫游** and the other
  [Swipe_Animation contributors](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin/graphs/contributors)
* Plugin re-packaging, runtime hooks and performance work: this repository

## License

GPLv3, same as KOReader and the original patch set. See `LICENSE`.
