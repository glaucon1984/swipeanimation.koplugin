# Swipe Animation for KOReader

A software **page-turn animation** for KOReader, packaged as a **regular, self-contained
plugin**: drop one folder into `koreader/plugins/` and you are done. No `patches/` folder,
no KOReader file is overwritten, nothing to restore when you remove it.

On e-ink readers it is the strip **"wipe"** of the original patch. On Android phones and
tablets (and the desktop build) it is a frame-based **slide or wipe**, because those
displays work differently (see *How it works*). One plugin, one setting, the engine is
picked automatically.

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
| Kobo MTK pre-animation sync | Always on | Off by default, switchable in the menu |
| Full-refresh rules (clearing, chapters, images) | Re-implemented inside the patch | KOReader's own rules and settings apply |
| Strip count | Fixed (8 portrait / 6 landscape) | Configurable per orientation |
| Android phones / tablets | Not supported (strips, "performance not satisfactory") | Supported since 5.1.0 with a separate frame-based engine (slide or wipe) |

## Features

* Smooth strip-based page-turn animation in both directions, portrait and landscape
* Works on devices without hardware animation support (all Kobo, older Kindles, …)
* Android phones and tablets: time-based **slide** (default) or **wipe** with adjustable
  duration; frame count follows the speed of the device
* Also animates fixed-layout documents (PDF, DjVu, CBZ, …)
* Strip refresh mode: **UI** (default) or **Fast** (quicker, more ghosting)
* Separate frame delay (ms) and strip count for portrait and landscape; delay `0` means no
  extra pause
* **Mild global refresh**: replace the periodic full (flashing) refresh by a partial one
* Kobo MTK (Clara BW / Colour, Libra Colour, …) driver-aligned strips and an optional
  legacy refresh fence (off by default)
* English, Chinese and Brazilian Portuguese menu strings

## Requirements and tested devices

* KOReader **2026.07.1 or later** (the release that introduced the page-turn animation
  plumbing in `ReaderView`).
* **Tested on a Kobo Clara BW** (e-ink engine) and on an **Android phone** (frame engine).
  The e-ink code paths for other Kobo models, Kindles and other Linux e-ink devices are
  the same as in the original patch set, which was tested widely, but they have not been
  exercised with this plugin yet. Reports welcome.
* **Android devices with an e-ink screen** (Onyx and similar) are not supported: their
  screen updates go through the Android display stack, which the plugin cannot control.
  The plugin stays inert there and only shows a notice in its menu.

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
        └── ☐ Kobo MTK: sync panel before animation   (Kobo MTK devices only, legacy)
```

On Android phones and tablets (and the desktop build) the submenu is:

```
    └── Swipe animation settings
        ├── ☑ Page turn animations
        ├── Animation style
        │   ├── ○ Slide (new page pushes the old one)
        │   └── ○ Wipe (new page revealed edge to edge)
        └── Animation duration: … ms          (default 250)
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
previous page, so it needs no snapshot either. Since 5.1.1 it is a legacy option (*Kobo MTK:
sync panel before animation*, off by default): a week of reading on a Clara BW showed no
difference without it, and the first strip starts sooner. Turn it on only if your panel
paces the strips unevenly, with a first strip visibly slower than the rest.

The remaining knobs are the strip count and the frame delay. Fewer strips or a shorter
delay make the turn faster; *Fast refresh* (DU waveform) makes each strip cheaper on MTK
Kobos in particular, because the driver does not wait for the submission of DU updates, at
the cost of more ghosting.

### Android and other non-e-ink displays

On Android, every KOReader refresh call, whatever region it names, copies the *whole*
framebuffer into the app window and posts it. Nothing on the panel "stays" between
refreshes, so the strip wipe cannot work there: the first strip would post the entire
new page. The plugin therefore switches engine when the device reports no e-ink screen
(`Device:hasEinkScreen()`):

* the previous page is snapshotted in the first `beforePaint()` of the turn, the new page
  after painting;
* for a fixed duration (default 250 ms, ease-out), every frame composites old and new
  pages in the framebuffer, as a slide or a wipe, and posts it through the original
  refresh call;
* the number of frames follows the speed of the device, the duration does not.

It costs two full-frame copies at the start and one full-window post per frame, which a
phone handles comfortably. The loop runs synchronously, like the e-ink one, so the UI is
busy for the duration of the turn. The desktop (SDL) build takes the same path.

### Full refreshes

On e-ink, the plugin does **not** re-implement KOReader's full-refresh rules. The periodic clearing
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
