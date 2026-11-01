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
    Pacing (e-ink only): the panel controller executes partial updates
    asynchronously, a wipe queues one per strip, and a page painted into
    the framebuffer while earlier strips are still pending is read half
    old, half new (strips of two pages mixed on the panel). No wait helps
    on PocketBook, where WaitForUpdateComplete() returns at once, so page
    turns are paced by time instead: a minimum gap since the last refresh,
    slept out before the new page is painted, and a cap on how many quick
    turns in a row still get a wipe (see paceTurn()). Turns in one direction
    are the easy case: each strip lands where the panel finished long ago.
    After a full refresh, or when the direction changes, the next page lands
    on an update the panel may still be drawing, so those get a longer gap.

    Direct strips (black-and-white Kobo MTK panels, see
    directStripRefresh()): the strips are sent straight to the HWTCON driver
    with the reading waveform in partial mode, as Kobalt and NickelDissolve
    do. KOReader's own refresh path cannot do that: it promotes REAGL to a
    full update that blocks until the panel is done, so through it a strip
    has to use the AUTO waveform. The panel is also woken at touch-down, as
    Nickel does, instead of right before the first strip.
]]

local Device = require("device")
local Event = require("ui/event")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local Screen = Device.screen

local Hook = {
    -- Shared tuning defaults, also displayed by the settings menu.
    defaults = {
        -- PocketBook: what felt best on the Era Lite without tearing. Both
        -- orientations use one value, so a wipe takes as long in landscape.
        delay_ms = { landscape = 10, portrait = 20, pocketbook = 16 },
        steps = { landscape = 6, portrait = 8, pocketbook = 8 },
        refresh_mode = { pocketbook = "fast", other = "ui" },
        lcd_duration_ms = 250,
        lcd_style = "slide",
        -- Pacing (see the header): PocketBook needs it, the Kobo Clara BW
        -- has not shown the tearing, so other devices default to off.
        min_gap_ms = { pocketbook = 250, other = 0 },
        burst_wipes = { pocketbook = 0, other = 0 }, -- 0 = no limit
        -- The Era Lite's GC16 takes 388 ms: 350 tears, 400 tore now and then.
        full_gap_ms = { pocketbook = 430, other = 0 },
    },
    MIN_STEPS = 2,
    MAX_STEPS = 32,
    MIN_LCD_DURATION_MS = 50,
    MAX_LCD_DURATION_MS = 2000,
    MAX_MIN_GAP_MS = 2000,
    MAX_BURST_WIPES = 100,
    -- Turns closer than this to the previous refresh count as a burst.
    BURST_WINDOW_MS = 700,
    -- Nickel wakes the panel on touch, at most this often.
    MTK_WAKE_INTERVAL_MS = 1500,
    -- A touch lift older than this did not cause the page turn being timed.
    TIMING_TAP_WINDOW_MS = 1000,
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
    -- The submission wait of a direct strip already paces the wipe.
    if Hook.usesDirectStrips() then return 0 end
    if Hook.isPocketBook() then return Hook.defaults.delay_ms.pocketbook end
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
    if Hook.usesDirectStrips() then
        return math.max(Screen.bb:getWidth(), Screen.bb:getHeight()) >= 1600 and 12 or 10
    end
    if Hook.isPocketBook() then return Hook.defaults.steps.pocketbook end
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

function Hook.getDefaultRefreshMode()
    return Hook.isPocketBook() and Hook.defaults.refresh_mode.pocketbook or Hook.defaults.refresh_mode.other
end

function Hook.getRefreshMode()
    local mode = G_reader_settings:readSetting("swipe_animation_refresh_mode")
    if mode == "fast" or mode == "ui" then return mode end
    return Hook.getDefaultRefreshMode()
end

function Hook.setRefreshMode(mode)
    if mode == Hook.getDefaultRefreshMode() then
        G_reader_settings:delSetting("swipe_animation_refresh_mode")
    else
        G_reader_settings:saveSetting("swipe_animation_refresh_mode", mode)
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

-- Black-and-white Kobo MTK panels only: colour panels need their own
-- waveforms, and the Elipsa 2E drives REAGL differently.
local direct_strips_supported
function Hook.canUseDirectStrips()
    if direct_strips_supported == nil then
        direct_strips_supported = Hook.isKoboMTK()
            and Device.model ~= "Kobo_condor"
            and not Device:hasColorScreen()
            and Screen.fd and Screen._get_next_marker and Screen.mech_wait_update_submission
            and pcall(function()
                require("ffi/posix_h")
                require("ffi/mxcfb_kobo_h")
                return ffi.C.HWTCON_SEND_UPDATE
            end)
            or false
    end
    return direct_strips_supported
end

function Hook.isDirectStripsEnabled()
    return G_reader_settings:nilOrTrue("swipe_animation_direct_strips")
end

function Hook.setDirectStripsEnabled(enabled)
    if enabled then
        G_reader_settings:delSetting("swipe_animation_direct_strips")
    else
        G_reader_settings:saveSetting("swipe_animation_direct_strips", false)
    end
end

-- The Fast refresh mode keeps its DU strips.
function Hook.usesDirectStrips()
    return Hook.canUseDirectStrips() and Hook.isDirectStripsEnabled() and Hook.getRefreshMode() ~= "fast"
end

function Hook.canWakeOnTouch()
    return Hook.isKoboMTK() and Screen.mech_poweron ~= nil
end

function Hook.isTouchWakeEnabled()
    return G_reader_settings:nilOrTrue("swipe_animation_touch_wake")
end

function Hook.setTouchWakeEnabled(enabled)
    if enabled then
        G_reader_settings:delSetting("swipe_animation_touch_wake")
    else
        G_reader_settings:saveSetting("swipe_animation_touch_wake", false)
    end
end

function Hook.isTimingEnabled()
    return G_reader_settings:isTrue("swipe_animation_log_timing")
end

function Hook.setTimingEnabled(enabled)
    if enabled then
        G_reader_settings:saveSetting("swipe_animation_log_timing", true)
    else
        G_reader_settings:delSetting("swipe_animation_log_timing")
    end
end

-- Pacing settings (e-ink). Unset means the device default; a negative
-- value counts as unset.
function Hook.isPocketBook()
    return (Device.isPocketBook and Device:isPocketBook()) and true or false
end

function Hook.getDefaultMinGapMs()
    return Hook.isPocketBook() and Hook.defaults.min_gap_ms.pocketbook or Hook.defaults.min_gap_ms.other
end

function Hook.getDefaultFullGapMs()
    return Hook.isPocketBook() and Hook.defaults.full_gap_ms.pocketbook or Hook.defaults.full_gap_ms.other
end

-- 0 is a valid value: no gap.
function Hook.getConfiguredFullGapMs()
    local ms = tonumber(G_reader_settings:readSetting("swipe_animation_full_gap_ms"))
    if ms == nil or ms < 0 then return nil end
    return math.min(math.floor(ms), Hook.MAX_MIN_GAP_MS)
end

function Hook.setConfiguredFullGapMs(ms)
    if ms == nil or ms < 0 then
        G_reader_settings:delSetting("swipe_animation_full_gap_ms")
    else
        G_reader_settings:saveSetting("swipe_animation_full_gap_ms", math.min(math.floor(ms), Hook.MAX_MIN_GAP_MS))
    end
end

function Hook.getFullGapMs()
    return Hook.getConfiguredFullGapMs() or Hook.getDefaultFullGapMs()
end

-- 0 is a valid value: no gap.
function Hook.getConfiguredMinGapMs()
    local ms = tonumber(G_reader_settings:readSetting("swipe_animation_min_gap_ms"))
    if ms == nil or ms < 0 then return nil end
    return math.min(math.floor(ms), Hook.MAX_MIN_GAP_MS)
end

function Hook.setConfiguredMinGapMs(ms)
    if ms == nil or ms < 0 then
        G_reader_settings:delSetting("swipe_animation_min_gap_ms")
    else
        G_reader_settings:saveSetting("swipe_animation_min_gap_ms", math.min(math.floor(ms), Hook.MAX_MIN_GAP_MS))
    end
end

function Hook.getMinGapMs()
    return Hook.getConfiguredMinGapMs() or Hook.getDefaultMinGapMs()
end

function Hook.getDefaultBurstWipes()
    return Hook.isPocketBook() and Hook.defaults.burst_wipes.pocketbook or Hook.defaults.burst_wipes.other
end

-- 0 is a valid value: no limit.
function Hook.getConfiguredBurstWipes()
    local n = tonumber(G_reader_settings:readSetting("swipe_animation_burst_wipes"))
    if n == nil or n < 0 then return nil end
    return math.min(math.floor(n), Hook.MAX_BURST_WIPES)
end

function Hook.setConfiguredBurstWipes(n)
    if n == nil or n < 0 then
        G_reader_settings:delSetting("swipe_animation_burst_wipes")
    else
        G_reader_settings:saveSetting("swipe_animation_burst_wipes", math.min(math.floor(n), Hook.MAX_BURST_WIPES))
    end
end

function Hook.getBurstWipes()
    return Hook.getConfiguredBurstWipes() or Hook.getDefaultBurstWipes()
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
local time
do
    local ok, ui_time = pcall(require, "ui/time")
    if ok and type(ui_time) == "table" and ui_time.to_ms and (ui_time.monotonic or ui_time.now) then
        time = ui_time
        local now = time.monotonic or time.now
        clock_ms = function() return time.to_ms(now()) end
    else
        clock_ms = function() return os.clock() * 1000 end
    end
end
Hook._clock_ms = clock_ms -- tests replace this

-- ==================== page-turn timing log (e-ink) ====================

-- Stamp a stage of the page turn being timed.
local function mark(state, stage)
    local t = state.t
    if t then t[stage] = Hook._clock_ms() end
end

local function setTimingMode(state, mode)
    if state.t then state.t.mode = mode end
end

-- How long ago, in ms, the kernel stamped this input event.
local function inputAgeMs(detector, timev)
    local C = ffi.C
    local id = detector:getClockSource()
    local now
    if id == C.CLOCK_REALTIME then
        now = time.realtime()
    elseif id == C.CLOCK_MONOTONIC then
        now = time.monotonic()
    elseif id == C.CLOCK_BOOTTIME then
        now = time.boottime()
    end
    return now and time.to_ms(now - timev)
end

local function span(from, to)
    return (from and to) and string.format("%.0f", to - from) or "-"
end

-- One line per page turn in crash.log, all in ms. first_strip ends when the
-- driver has taken the strip, about when the panel starts to change.
local function logTurn(state)
    local t = state.t
    state.t = nil
    local lift = state.lift_ms
    state.lift_ms = nil
    if lift and not (t.turn >= lift and t.turn - lift < Hook.TIMING_TAP_WINDOW_MS) then
        lift = nil -- not a tap: a page-turn key, or an old touch
    end
    local start = t.wake1 or t.refresh
    local tap = lift and (lift - (state.lift_age_ms or 0))
    logger.info(string.format(
        "SwipeAnimation timing: mode=%s tap_to_input=%s input_to_turn=%s turn_to_paint=%s paint=%s wake=%s first_strip=%s wipe=%s tap_to_first_strip=%s touch_wake=%s",
        t.mode or "plain",
        span(tap, lift), span(lift, t.turn), span(t.turn, t.paint), span(t.paint, t.refresh),
        span(t.wake0, t.wake1), span(start, t.first), span(t.first, t.done), span(tap, t.first),
        state.touch_wake_cost_ms and string.format("%.0f", state.touch_wake_cost_ms) or "-"))
    state.touch_wake_cost_ms = nil
end

-- ==================== panel wake (Kobo MTK) ====================

-- Returns how long the wake took, or nil if the panel was woken recently.
local function wakePanel(state, screen)
    local start = Hook._clock_ms()
    if state.last_wake_ms and start - state.last_wake_ms < Hook.MTK_WAKE_INTERVAL_MS then
        return nil
    end
    screen:mech_poweron()
    state.last_wake_ms = Hook._clock_ms()
    return state.last_wake_ms - start
end

-- Sees every input frame before the gesture detector does.
local function noteTouch(state, detector, tevs)
    for _, tev in ipairs(tevs) do
        if tev.id == -1 then
            if Hook.isTimingEnabled() then
                state.lift_ms = Hook._clock_ms()
                local ok, age = pcall(inputAgeMs, detector, tev.timev)
                state.lift_age_ms = ok and age or nil
            end
        elseif not detector:getContact(tev.slot) then
            -- A new finger on the screen.
            if Hook.canWakeOnTouch() and Hook.isTouchWakeEnabled() then
                state.touch_wake_cost_ms = wakePanel(state, Screen) or state.touch_wake_cost_ms
            end
        end
    end
end

-- ==================== pacing (e-ink) ====================

-- Remember when the last update was handed to the panel.
local function stamp(state)
    state.last_update_ms = Hook._clock_ms()
end

-- Hand a refresh to an original implementation and stamp it.
local function passThrough(state, fn, screen, x, y, w, h, dither)
    local result = fn(screen, x, y, w, h, dither)
    stamp(state)
    if fn == state.originals.refreshFullImp then
        state.last_full_ms = state.last_update_ms
    end
    return result
end

-- Called from the first beforePaint of a page-turn repaint, before the new
-- page is painted. Same two rules as the Kobalt port's PbInkScreen:
--   * burst: turns closer than BURST_WINDOW_MS to the previous refresh are
--     counted; from the burst_wipes-th one on the wipe is dropped and the
--     turn is shown with the plain refresh, until the turns slow down;
--   * gap: the next page is not painted until min_gap_ms have passed since
--     the last refresh, so the controller has finished reading the old one,
--     and at least full_gap_ms since the last full refresh. A wipe ends at
--     the edge where a wipe in the other direction starts, so a turn that
--     changes direction also waits for full_gap_ms since the last refresh.
local function paceTurn(state)
    local now = Hook._clock_ms()
    local since = state.last_update_ms and (now - state.last_update_ms) or math.huge

    if since < Hook.BURST_WINDOW_MS then
        state.quick_turns = state.quick_turns + 1
    else
        state.quick_turns = 0
    end
    local burst = Hook.getBurstWipes()
    state.skip_wipe = burst > 0 and state.quick_turns >= burst

    local gap = Hook.getMinGapMs()
    local wait = gap - since
    if state.last_full_ms then
        wait = math.max(wait, Hook.getFullGapMs() - (now - state.last_full_ms))
    end
    if state.last_wipe_forward ~= nil and state.last_wipe_forward ~= state.forward then
        wait = math.max(wait, Hook.getFullGapMs() - since)
    end
    if wait > 0 then
        logger.dbg("SwipeAnimation: pacing the page turn by", wait, "ms")
        ffiUtil.usleep(math.floor(wait * 1000 + 0.5))
    end
end

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

local function mtkSendUpdate(screen, data)
    return ffi.C.ioctl(screen.fd, ffi.C.HWTCON_SEND_UPDATE, data)
end
Hook._mtk_send_update = mtkSendUpdate -- tests replace this

-- A strip refresh with the signature of the original Imp methods that talks
-- to the driver directly: the reading waveform in partial mode, then a wait
-- for submission, as Kobalt's PageAnimation::submit() does. Otherwise the
-- steps mirror mxc_update(), minus the panel wake of every update (wakePanel()
-- covers the whole wipe). Markers come from the framebuffer's own counter, so
-- refreshWaitForLast() keeps working.
local function directStripRefresh(state, screen)
    local C = ffi.C
    local data = state.mtk_update
    if not data then
        data = ffi.new("struct hwtcon_update_data")
        state.mtk_update = data
    end
    local night = screen.night_mode
    data.waveform_mode = night and C.HWTCON_WAVEFORM_MODE_GLKW16 or C.HWTCON_WAVEFORM_MODE_GLR16
    data.update_mode = C.UPDATE_MODE_PARTIAL
    data.dither_mode = 0
    data.flags = 0
    if night and Device:canHWInvert() and not screen:getHWNightmode() then
        data.flags = C.EPDC_FLAG_ENABLE_INVERSION
    end

    local bb = screen.full_bb or screen.bb
    return function(_, x, y, w, h)
        x, y, w, h = bb:getBoundedRect(x, y, w, h, screen.alignment_constraint)
        x, y, w, h = bb:getPhysicalRect(x, y, w, h)
        if w <= 1 or h <= 1 then return end
        data.update_region.left = x
        data.update_region.top = y
        data.update_region.width = w * (screen.refresh_pixel_size or 1)
        data.update_region.height = h
        local marker = screen:_get_next_marker()
        data.update_marker = marker
        if Hook._mtk_send_update(screen, data) == -1 then
            error("HWTCON_SEND_UPDATE failed: " .. ffi.errno())
        end
        if screen:mech_wait_update_submission(marker) == -1 then
            error("HWTCON_WAIT_FOR_UPDATE_SUBMISSION failed: " .. ffi.errno())
        end
    end
end

-- Reveal the new page (already in the framebuffer) strip by strip inside
-- the refresh region. Runs with state.bypass set, so nested refresh calls
-- go straight to the original framebuffer implementation.
local function runStripWipe(state, screen, x, y, w, h, dither, forward)
    local landscape = screen.bb:getWidth() > screen.bb:getHeight()

    local delay_ms = Hook.getConfiguredDelayMs(landscape) or Hook.getDefaultDelayMs(landscape)
    local steps = Hook.getConfiguredSteps(landscape) or Hook.getDefaultSteps(landscape)
    local strip_refresh
    -- REAGL is a text waveform: dithered content stays on the AUTO path.
    if Hook.usesDirectStrips() and not dither then
        mark(state, "wake0")
        wakePanel(state, screen)
        mark(state, "wake1")
        setTimingMode(state, "direct")
        strip_refresh = directStripRefresh(state, screen)
    else
        setTimingMode(state, "strips")
        strip_refresh = state.originals[Hook.getRefreshMode() == "fast" and "refreshFastImp" or "refreshUIImp"]
            or state.originals.refreshPartialImp
    end

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
        if i == 1 then mark(state, "first") end
        if i < nslots and delay_ms > 0 then
            ffiUtil.usleep(delay_ms * 1000)
        end
    end
    mark(state, "done")
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
            return passThrough(state, original, screen, x, y, w, h, dither)
        end

        state.armed = false
        mark(state, "refresh")
        local old_bb = state.old_bb
        state.old_bb = nil
        -- Never let an MTK driver run its own animation on top of ours.
        screen.swipe_animations = false

        local lcd = state.display == "lcd"

        if not lcd and FLASHING[name] then
            -- KOReader asked for a flash (clearing refresh, chapter
            -- boundary, image page): no animation, honour it.
            setTimingMode(state, "flash")
            if Hook.isMildGlobalRefresh() and state.originals.refreshPartialImp then
                logger.dbg("SwipeAnimation: mild global refresh instead of", name)
                return passThrough(state, state.originals.refreshPartialImp, screen, x, y, w, h, dither)
            end
            logger.dbg("SwipeAnimation: flashing refresh, skipping animation:", name)
            return passThrough(state, original, screen, x, y, w, h, dither)
        end

        if not lcd and state.skip_wipe then
            -- Too many quick turns in a row for the panel controller
            -- (see paceTurn): plain refresh until the turns slow down.
            logger.dbg("SwipeAnimation: quick succession, plain refresh instead of a wipe")
            return passThrough(state, original, screen, x, y, w, h, dither)
        end

        local sw, sh = screen.bb:getWidth(), screen.bb:getHeight()
        x, y = x or 0, y or 0
        w, h = w or sw, h or sh
        if w * h < MIN_AREA_RATIO * sw * sh or (lcd and not old_bb) then
            freeBuffer(old_bb)
            return passThrough(state, original, screen, x, y, w, h, dither)
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
            return passThrough(state, original, screen, x, y, w, h, dither)
        end
        freeBuffer(old_bb)
        freeBuffer(new_bb)
        -- The last strip (or frame) is the last update handed to the panel.
        stamp(state)
        state.last_wipe_forward = state.forward
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
                        paceTurn(state)
                        runMTKFence(state, screen)
                    end
                    mark(state, "paint")
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
            if state.t and state.t.refresh then
                logTurn(state)
            end
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
        if state.pending and state.active and state.display == "eink" and Hook.isTimingEnabled() then
            state.t = { turn = Hook._clock_ms() }
        end
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

-- Touch-down panel wake and the tap time of the timing log.
local function installInputHook(state)
    local detector = Device.input and Device.input.gesture_detector
    if not detector or type(detector.feedEvent) ~= "function" then
        logger.warn("SwipeAnimation: gesture detector not found, no touch hook")
        return
    end
    state.original_feedEvent = detector.feedEvent
    detector.feedEvent = function(self, tevs)
        if state.active then
            noteTouch(state, self, tevs)
        end
        return state.original_feedEvent(self, tevs)
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
        last_update_ms = nil, -- e-ink: when the last refresh was issued (Hook._clock_ms)
        last_full_ms = nil,   -- e-ink: when the last full refresh was issued
        last_wipe_forward = nil, -- e-ink: the direction of the last wipe
        quick_turns = 0,      -- e-ink: consecutive page turns within BURST_WINDOW_MS
        skip_wipe = false,    -- e-ink: this turn is past the burst, plain refresh
        mtk_update = nil,     -- Kobo MTK: the update struct of the direct strips
        last_wake_ms = nil,   -- Kobo MTK: when the panel was last woken
        t = nil,              -- timing log: stage stamps of the current turn
        lift_ms = nil,        -- timing log: when the last touch lift was seen
        lift_age_ms = nil,    -- timing log: how old that lift was when seen
        touch_wake_cost_ms = nil, -- timing log: how long the last touch wake took
    }
    Screen._swipeanimation_state = state

    installScreenHooks(state)
    installDeviceHook(state)
    installPagingHook(state)
    if state.display == "eink" then
        installInputHook(state)
    end
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
        state.quick_turns = 0
        state.skip_wipe = false
        state.t = nil
        state.lift_ms = nil
        freeBuffer(state.old_bb)
        state.old_bb = nil
    end
end

function Hook.getState()
    return Screen._swipeanimation_state
end

return Hook
