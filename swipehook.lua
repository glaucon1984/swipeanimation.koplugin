--[[
    swipehook.lua -- runtime hooks for the Swipe Animation plugin.

    Everything here is installed at runtime on the live Screen, Device and
    ReaderPaging objects. No KOReader file is modified.

    Why this works without patching frontend/ui/uimanager.lua:

      * UIManager:_repaint() caches the public Screen.refresh*() functions
        when the module loads, but those functions dispatch dynamically to
        Screen.refresh*Imp(). Intercepting the Imp methods on the Screen
        instance therefore lets a plugin, loaded long after UIManager, take
        over the physical refresh of a repaint.

      * Screen:beforePaint() / Screen:afterPaint() bracket every repaint
        that painted a widget. The first beforePaint() of a page-turn
        repaint still has the previous page in the framebuffer, and
        afterPaint() is where per-repaint state is reset.

      * ReaderView:onPageChangeAnimation() calls Screen:setSwipeAnimations(true)
        and Screen:setSwipeDirection(forward) right before a page-turn
        repaint, guarded by Device:canDoSwipeAnimation() and the
        "swipe_animations" setting. Both Screen methods are empty stubs on
        non-MTK devices, so we wrap them to record the request, and we make
        canDoSwipeAnimation() answer true while the plugin is active.

    Two animation engines, chosen by display class (Hook.displayClass()):

      "eink"  E-ink screen on a Linux e-reader (Kobo, Kindle, PocketBook...).
              An e-ink panel keeps showing whatever it last displayed in any
              region that is not refreshed. So once KOReader has painted the
              new page into the framebuffer, the wipe is nothing more than
              refreshing vertical strips of it one after another. No
              snapshot, no compositing, no buffer copies.

      "lcd"   No e-ink screen (Android phones and tablets, the SDL desktop
              build). There every refresh call posts the *whole* window, so
              strips cannot work. Instead the old page is snapshotted, and
              for a fixed duration each frame composites old and new pages
              in the framebuffer (wipe or slide) and posts it.

      "inert" Android devices with an e-ink screen: window posts go through
              the Android display stack, which the plugin cannot control.
              The plugin stays completely passive there.

    Full-refresh decisions (periodic clearing refresh, chapter boundaries,
    image-heavy pages) are left to KOReader itself: on e-ink every one of
    them ends up as a *flashing* refresh in the refresh queue of that
    repaint. We recognise those and let them through without animating,
    optionally downgraded to a plain partial refresh by the "Mild global
    refresh" option. On LCD there is no flash to preserve, so every
    page-turn refresh animates.
]]

local Device = require("device")
local Event = require("ui/event")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local Screen = Device.screen

local Hook = {
    -- Shared tuning defaults, also displayed by the settings menu.
    defaults = {
        delay_ms = { landscape = 10, portrait = 20 },
        steps = { landscape = 6, portrait = 8 },
        lcd_duration_ms = 250,
        lcd_style = "slide",
    },
    MIN_STEPS = 2,
    MAX_STEPS = 32,
    MIN_LCD_DURATION_MS = 50,
    MAX_LCD_DURATION_MS = 2000,
}

local IMP_METHODS = {
    "refreshFullImp",
    "refreshPartialImp",
    "refreshNoMergePartialImp",
    "refreshFlashPartialImp",
    "refreshUIImp",
    "refreshNoMergeUIImp",
    "refreshFlashUIImp",
    "refreshFastImp",
    "refreshA2Imp",
}

-- Refresh types KOReader uses when it *wants* a flash (full refresh
-- promotion, chapter boundaries, pages with images, ...).
local FLASHING = {
    refreshFullImp = true,
    refreshFlashUIImp = true,
    refreshFlashPartialImp = true,
}

-- Only animate refreshes that cover at least this share of the screen.
local MIN_AREA_RATIO = 0.5

-- Safety net for the time-based LCD loop.
local MAX_LCD_FRAMES = 600

local function freeBuffer(bb)
    if bb then pcall(bb.free, bb) end
end

-- ==================== display class ====================

function Hook.displayClass()
    local eink = Device.hasEinkScreen and Device:hasEinkScreen()
    local android = Device.isAndroid and Device:isAndroid()
    if eink then
        if android then return "inert" end
        return "eink"
    end
    return "lcd"
end

function Hook.isEink() return Hook.displayClass() == "eink" end
function Hook.isLCD() return Hook.displayClass() == "lcd" end
function Hook.isSupported() return Hook.displayClass() ~= "inert" end

-- ==================== settings helpers (shared with the menu) ====================

function Hook.isLandscape()
    return Screen.bb:getWidth() > Screen.bb:getHeight()
end

function Hook.getDefaultDelayMs(landscape)
    if landscape == nil then landscape = Hook.isLandscape() end
    return landscape and Hook.defaults.delay_ms.landscape or Hook.defaults.delay_ms.portrait
end

function Hook.getDelaySettingKey(landscape)
    if landscape == nil then landscape = Hook.isLandscape() end
    return landscape and "swipe_animation_delay_ms_horizontal" or "swipe_animation_delay_ms_vertical"
end

-- Returns the user-configured delay for the orientation, or nil when unset
-- (a negative value counts as unset). 0 is a valid value: no pause at all.
function Hook.getConfiguredDelayMs(landscape)
    local delay_ms = tonumber(G_reader_settings:readSetting(Hook.getDelaySettingKey(landscape)))
    if delay_ms == nil then
        delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms"))
    end
    if delay_ms == nil or delay_ms < 0 then
        return nil
    end
    return delay_ms
end

function Hook.setConfiguredDelayMs(landscape, delay_ms)
    local key = Hook.getDelaySettingKey(landscape)
    if delay_ms == nil or delay_ms < 0 then
        G_reader_settings:delSetting(key)
    else
        G_reader_settings:saveSetting(key, delay_ms)
    end
end

function Hook.getDefaultSteps(landscape)
    if landscape == nil then landscape = Hook.isLandscape() end
    return landscape and Hook.defaults.steps.landscape or Hook.defaults.steps.portrait
end

function Hook.getStepsSettingKey(landscape)
    if landscape == nil then landscape = Hook.isLandscape() end
    return landscape and "swipe_animation_steps_horizontal" or "swipe_animation_steps_vertical"
end

-- Returns the user-configured strip count for the orientation, or nil when unset.
function Hook.getConfiguredSteps(landscape)
    local steps = tonumber(G_reader_settings:readSetting(Hook.getStepsSettingKey(landscape)))
    if steps == nil or steps < Hook.MIN_STEPS then
        return nil
    end
    return math.min(math.floor(steps), Hook.MAX_STEPS)
end

function Hook.setConfiguredSteps(landscape, steps)
    local key = Hook.getStepsSettingKey(landscape)
    if steps == nil or steps < Hook.MIN_STEPS then
        G_reader_settings:delSetting(key)
    else
        G_reader_settings:saveSetting(key, math.min(math.floor(steps), Hook.MAX_STEPS))
    end
end

function Hook.getRefreshMode()
    local mode = G_reader_settings:readSetting("swipe_animation_refresh_mode")
    if mode == "fast" then return "fast" end
    return "ui"
end

function Hook.setRefreshMode(mode)
    if mode == "fast" then
        G_reader_settings:saveSetting("swipe_animation_refresh_mode", "fast")
    else
        G_reader_settings:delSetting("swipe_animation_refresh_mode")
    end
end

function Hook.isMildGlobalRefresh()
    return G_reader_settings:isTrue("swipe_animation_mild_global_refresh")
end

function Hook.setMildGlobalRefresh(enabled)
    if enabled then
        G_reader_settings:saveSetting("swipe_animation_mild_global_refresh", true)
    else
        G_reader_settings:delSetting("swipe_animation_mild_global_refresh")
    end
end

function Hook.isKoboMTK()
    return Device:isKobo() and Device:isMTK()
end

-- Kobo MTK only: drain the HWTCON queue with a no-change full-screen AUTO
-- update before the strips start, so the first strip is not slower than
-- the rest. Legacy option inherited from the original patch (always on
-- there); off by default since 5.1.1.
function Hook.isMTKFenceEnabled()
    return G_reader_settings:isTrue("swipe_animation_mtk_fence")
end

function Hook.setMTKFenceEnabled(enabled)
    if enabled then
        G_reader_settings:saveSetting("swipe_animation_mtk_fence", true)
    else
        G_reader_settings:delSetting("swipe_animation_mtk_fence")
    end
end

-- LCD engine settings.
function Hook.getLCDStyle()
    local style = G_reader_settings:readSetting("swipe_animation_lcd_style")
    if style == "wipe" or style == "slide" then return style end
    return Hook.defaults.lcd_style
end

function Hook.setLCDStyle(style)
    if style == "wipe" or style == "slide" then
        G_reader_settings:saveSetting("swipe_animation_lcd_style", style)
    else
        G_reader_settings:delSetting("swipe_animation_lcd_style")
    end
end

function Hook.getConfiguredLCDDurationMs()
    local ms = tonumber(G_reader_settings:readSetting("swipe_animation_lcd_duration_ms"))
    if ms == nil or ms < Hook.MIN_LCD_DURATION_MS then return nil end
    return math.min(math.floor(ms), Hook.MAX_LCD_DURATION_MS)
end

function Hook.setConfiguredLCDDurationMs(ms)
    if ms == nil or ms < Hook.MIN_LCD_DURATION_MS then
        G_reader_settings:delSetting("swipe_animation_lcd_duration_ms")
    else
        G_reader_settings:saveSetting("swipe_animation_lcd_duration_ms", math.min(math.floor(ms), Hook.MAX_LCD_DURATION_MS))
    end
end

function Hook.getLCDDurationMs()
    return Hook.getConfiguredLCDDurationMs() or Hook.defaults.lcd_duration_ms
end

-- ==================== clock ====================

-- Milliseconds from a monotonic clock. Uses KOReader's ui/time when
-- available (fine-grained monotonic), os.clock otherwise.
local clock_ms
do
    local ok, time = pcall(require, "ui/time")
    if ok and type(time) == "table" and time.to_ms and (time.monotonic or time.now) then
        local now = time.monotonic or time.now
        clock_ms = function() return time.to_ms(now()) end
    else
        clock_ms = function() return os.clock() * 1000 end
    end
end
Hook._clock_ms = clock_ms -- tests replace this

-- ==================== e-ink engine: strip wipe ====================

-- Split [x0, x1) into `steps` strips. Interior cuts snap to `align`
-- (Screen.alignment_constraint, 16 on Kobo MTK) so getBoundedRect() does
-- not expand neighbouring strips into each other; the outer edges stay
-- exact. Kobo colour devices skip the alignment (align == nil) because
-- HWTCON drops 1px from 16-aligned partials, which shows as black CFA
-- seams; unaligned cuts overlap instead.
local function buildStripEdges(x0, x1, steps, align)
    local edges = { x0 }
    local width = x1 - x0
    local use_align = type(align) == "number" and align >= 2
    for i = 1, steps - 1 do
        local raw = x0 + width * i / steps
        local cut
        if use_align then
            cut = math.floor((raw + align / 2) / align) * align
        else
            cut = math.floor(raw)
        end
        if cut > edges[#edges] and cut < x1 then
            edges[#edges + 1] = cut
        end
    end
    edges[#edges + 1] = x1
    return edges
end
Hook._buildStripEdges = buildStripEdges -- exposed for tests

-- Reveal the new page (already in the framebuffer) strip by strip inside
-- the refresh region. Runs with state.bypass set, so nested refresh calls
-- go straight to the original framebuffer implementation.
local function runStripWipe(state, screen, x, y, w, h, dither, forward)
    local landscape = screen.bb:getWidth() > screen.bb:getHeight()

    local delay_ms = Hook.getConfiguredDelayMs(landscape) or Hook.getDefaultDelayMs(landscape)
    local steps = Hook.getConfiguredSteps(landscape) or Hook.getDefaultSteps(landscape)
    local strip_refresh = state.originals[Hook.getRefreshMode() == "fast" and "refreshFastImp" or "refreshUIImp"]
        or state.originals.refreshPartialImp

    local align = screen.alignment_constraint
    if Device:isKobo() and Device.hasColorScreen and Device:hasColorScreen() then
        align = nil
    end
    local edges = buildStripEdges(x, x + w, steps, align)
    local nslots = #edges - 1

    for i = 1, nslots do
        local idx = forward and (nslots - i + 1) or i
        local left, right = edges[idx], edges[idx + 1]
        local strip_w = right - left
        if strip_w > 0 then
            strip_refresh(screen, left, y, strip_w, h, dither)
        end
        if i < nslots and delay_ms > 0 then
            ffiUtil.usleep(delay_ms * 1000)
        end
    end
end

-- Kobo MTK fence, issued while the framebuffer still holds the previous
-- page (first beforePaint of the page-turn repaint): wait for the last
-- update, send a no-change full-screen AUTO update, wait for it. Same
-- panel-side sequence as the original patch, without a snapshot.
local function runMTKFence(state, screen)
    if not (Hook.isKoboMTK() and Hook.isMTKFenceEnabled()) then return end
    local fence_refresh = state.originals.refreshUIImp
    if not fence_refresh then return end
    state.bypass = true
    local ok, err = pcall(function()
        if screen.refreshWaitForLast then
            screen:refreshWaitForLast()
        end
        fence_refresh(screen, 0, 0, screen.bb:getWidth(), screen.bb:getHeight())
        if screen.refreshWaitForLast then
            screen:refreshWaitForLast()
        end
    end)
    state.bypass = false
    if not ok then
        logger.warn("SwipeAnimation: MTK fence failed:", err)
    end
end

-- ==================== LCD engine: time-based frames ====================

-- Ease-out: fast start, gentle landing.
local function easeOut(t)
    local u = 1 - t
    return 1 - u * u * u
end

-- Composite one frame of progress p (0..1) into screen.bb inside the region.
-- Returns the region that changed, for the post call.
local function compositeFrame(screen, style, forward, old_bb, new_bb, x, y, w, h, p)
    local amount = math.floor(w * p + 0.5)
    if amount > w then amount = w end
    if style == "wipe" then
        -- Reveal the new page from one edge; only the newly uncovered slice
        -- needs blitting, the rest is already in place.
        if forward then
            local left = x + w - amount
            screen.bb:blitFrom(new_bb, left, y, left, y, amount, h)
        else
            screen.bb:blitFrom(new_bb, x, y, x, y, amount, h)
        end
    else
        -- Slide: the old page moves out while the new one moves in.
        local keep = w - amount
        if forward then
            -- Content moves left: old page shifted left by `amount`, new page
            -- enters from the right edge.
            if keep > 0 then
                screen.bb:blitFrom(old_bb, x, y, x + amount, y, keep, h)
            end
            if amount > 0 then
                screen.bb:blitFrom(new_bb, x + keep, y, x, y, amount, h)
            end
        else
            -- Content moves right: old page shifted right, new page enters
            -- from the left edge.
            if keep > 0 then
                screen.bb:blitFrom(old_bb, x + amount, y, x, y, keep, h)
            end
            if amount > 0 then
                screen.bb:blitFrom(new_bb, x, y, x + keep, y, amount, h)
            end
        end
    end
end

-- Animate for a fixed duration; the frame count follows the device speed.
-- Runs with state.bypass set.
local function runFrameAnimation(state, screen, x, y, w, h, dither, forward, old_bb, new_bb)
    local style = Hook.getLCDStyle()
    local duration = Hook.getLCDDurationMs()
    local post = state.originals.refreshFastImp
        or state.originals.refreshPartialImp
        or state.originals.refreshFullImp

    local start = Hook._clock_ms()
    local frames = 0
    local t = 0
    -- Slide always needs the old page as the starting frame; wipe already
    -- has it on screen (the framebuffer still shows it, we only post
    -- composites), but the framebuffer holds the new page, so restore the
    -- old one first in both cases.
    screen.bb:blitFrom(old_bb, x, y, x, y, w, h)
    repeat
        local elapsed = Hook._clock_ms() - start
        t = elapsed / duration
        if t >= 1 or frames >= MAX_LCD_FRAMES then t = 1 end
        compositeFrame(screen, style, forward, old_bb, new_bb, x, y, w, h, easeOut(t))
        post(screen, x, y, w, h, dither)
        frames = frames + 1
    until t >= 1
    -- Belt and braces: the final framebuffer content must be the new page.
    screen.bb:blitFrom(new_bb, x, y, x, y, w, h)
    state.last_frame_count = frames
end

-- ==================== hook installation ====================

local function interceptRefreshImp(state, name, original)
    return function(screen, x, y, w, h, dither)
        if state.bypass then
            return original(screen, x, y, w, h, dither)
        end
        -- The first refresh of an animated repaint has been consumed; drop
        -- the rest of the queue of that repaint (the animation already
        -- covered the region).
        if state.suppress then
            return
        end
        if not state.armed then
            return original(screen, x, y, w, h, dither)
        end

        state.armed = false
        local old_bb = state.old_bb
        state.old_bb = nil
        -- Never let an MTK driver run its own animation on top of ours.
        screen.swipe_animations = false

        local lcd = state.display == "lcd"

        if not lcd and FLASHING[name] then
            -- KOReader asked for a flash (clearing refresh, chapter
            -- boundary, image page): no animation, honour it.
            if Hook.isMildGlobalRefresh() and state.originals.refreshPartialImp then
                logger.dbg("SwipeAnimation: mild global refresh instead of", name)
                return state.originals.refreshPartialImp(screen, x, y, w, h, dither)
            end
            logger.dbg("SwipeAnimation: flashing refresh, skipping animation:", name)
            return original(screen, x, y, w, h, dither)
        end

        local sw, sh = screen.bb:getWidth(), screen.bb:getHeight()
        x, y = x or 0, y or 0
        w, h = w or sw, h or sh
        if w * h < MIN_AREA_RATIO * sw * sh or (lcd and not old_bb) then
            freeBuffer(old_bb)
            return original(screen, x, y, w, h, dither)
        end

        local ok, err
        local new_bb
        state.bypass = true
        if lcd then
            new_bb = screen.bb:copy()
            ok, err = pcall(runFrameAnimation, state, screen, x, y, w, h, dither, state.forward, old_bb, new_bb)
        else
            ok, err = pcall(runStripWipe, state, screen, x, y, w, h, dither, state.forward)
        end
        state.bypass = false
        if not ok then
            logger.warn("SwipeAnimation: animation failed, falling back to a plain refresh:", err)
            if new_bb then
                -- Make sure the new page, not a half-composited one, is what gets shown.
                pcall(function() screen.bb:blitFrom(new_bb, x, y, x, y, w, h) end)
            end
            freeBuffer(old_bb)
            freeBuffer(new_bb)
            return original(screen, x, y, w, h, dither)
        end
        freeBuffer(old_bb)
        freeBuffer(new_bb)
        state.suppress = true
    end
end

local function installScreenHooks(state)
    state.original_beforePaint = Screen.beforePaint
    Screen.beforePaint = function(screen, ...)
        local result = state.original_beforePaint(screen, ...)
        -- beforePaint is called once per dirty widget; only the first call
        -- of a repaint still has the previous page in the framebuffer.
        if not state.painting then
            state.painting = true
            if state.pending then
                state.pending = false
                if state.active and not state.bypass and screen.bb then
                    state.armed = true
                    if state.display == "lcd" then
                        freeBuffer(state.old_bb)
                        state.old_bb = screen.bb:copy()
                    else
                        runMTKFence(state, screen)
                    end
                end
            end
        end
        return result
    end

    state.original_afterPaint = Screen.afterPaint
    Screen.afterPaint = function(screen, ...)
        local result = state.original_afterPaint(screen, ...)
        if not state.bypass then
            state.painting = false
            state.suppress = false
            if state.armed then
                -- Painted, but no eligible refresh came through: nothing
                -- to animate this time.
                state.armed = false
                freeBuffer(state.old_bb)
                state.old_bb = nil
                screen.swipe_animations = false
            end
        end
        return result
    end

    -- Stubs on non-MTK framebuffers, the real hardware setup on MTK ones.
    -- Chain to the original either way and record the request ourselves.
    state.original_setSwipeAnimations = Screen.setSwipeAnimations
    Screen.setSwipeAnimations = function(screen, enabled, ...)
        if state.original_setSwipeAnimations then
            state.original_setSwipeAnimations(screen, enabled, ...)
        end
        state.pending = enabled and true or false
    end

    state.original_setSwipeDirection = Screen.setSwipeDirection
    Screen.setSwipeDirection = function(screen, direction, ...)
        if state.original_setSwipeDirection then
            state.original_setSwipeDirection(screen, direction, ...)
        end
        state.forward = direction and true or false
    end

    for _, name in ipairs(IMP_METHODS) do
        local original = Screen[name]
        if type(original) == "function" then
            state.originals[name] = original
            Screen[name] = interceptRefreshImp(state, name, original)
        end
    end
end

-- Expose the "Page turn animations" toggle and keep the PageChangeAnimation
-- plumbing of ReaderView active on devices without hardware support.
local function installDeviceHook(state)
    state.original_canDoSwipeAnimation = Device.canDoSwipeAnimation
    Device.canDoSwipeAnimation = function(device, ...)
        if state.active then return true end
        if state.original_canDoSwipeAnimation then
            return state.original_canDoSwipeAnimation(device, ...)
        end
        return false
    end
end

-- Upstream only emits PageChangeAnimation from ReaderRolling; emit it for
-- paged documents (PDF, DjVu, CBZ, ...) too.
local function installPagingHook(state)
    local ok, ReaderPaging = pcall(require, "apps/reader/modules/readerpaging")
    if not ok or type(ReaderPaging) ~= "table" or type(ReaderPaging._gotoPage) ~= "function" then
        logger.warn("SwipeAnimation: ReaderPaging._gotoPage not found, paged documents will not animate")
        return
    end
    state.original_paging_gotoPage = ReaderPaging._gotoPage
    ReaderPaging._gotoPage = function(paging, number, orig_mode)
        if state.active and number and paging.current_page and paging.current_page > 0
            and number ~= paging.current_page
            and not (paging.view and paging.view.page_scroll)
            and G_reader_settings:isTrue("swipe_animations") then
            paging.ui:handleEvent(Event:new("PageChangeAnimation", number > paging.current_page))
        end
        return state.original_paging_gotoPage(paging, number, orig_mode)
    end
end

-- Install every hook once per KOReader process. Safe to call repeatedly.
-- On an unsupported display class nothing is installed at all.
function Hook.install()
    local state = Screen._swipeanimation_state
    if state then return state end
    if not Hook.isSupported() then
        logger.info("SwipeAnimation: unsupported display (Android e-ink), staying inert")
        return nil
    end

    state = {
        display = Hook.displayClass(), -- "eink" or "lcd"
        active = false,   -- a reader with this plugin is open
        pending = false,  -- ReaderView asked for an animation on the next repaint
        painting = false, -- between the first beforePaint and afterPaint of a repaint
        armed = false,    -- this repaint is a page turn: animate its first refresh
        suppress = false, -- animation done, drop the rest of the refreshes of this repaint
        bypass = false,   -- calls made by the animation itself
        forward = true,
        old_bb = nil,     -- LCD only: snapshot of the previous page
        originals = {},
        last_frame_count = nil,
    }
    Screen._swipeanimation_state = state

    installScreenHooks(state)
    installDeviceHook(state)
    installPagingHook(state)
    logger.info("SwipeAnimation: hooks installed, display class", state.display)
    return state
end

function Hook.setActive(active)
    local state = Screen._swipeanimation_state
    if not state then return end
    state.active = active and true or false
    if not state.active then
        state.pending = false
        state.armed = false
        freeBuffer(state.old_bb)
        state.old_bb = nil
    end
end

function Hook.getState()
    return Screen._swipeanimation_state
end

return Hook
