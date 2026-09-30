--[[
    swipemenu.lua -- settings menu for the Swipe Animation plugin.

    Adds "Swipe animation settings" right after "Page turns" under
    Settings > Taps and gestures, mirroring the original patch. The entries
    depend on the display class: strip options on e-ink, frame options on
    LCD, a notice on unsupported devices.
]]

local UIManager = require("ui/uimanager")
local GetText = require("gettext")
local T = require("ffi/util").template

local Menu = {}

local MENU_KEY = "swipe_animation_settings"

-- ==================== localisation ====================
-- English is the gettext source language. Until these strings are part of
-- the KOReader catalogs, ship built-in Chinese and Brazilian Portuguese
-- fallbacks (inherited from the original patch).

local zh_fallback = {
    ["Page turn animations"] = "翻页动画",
    ["Animation frame delay"] = "动画帧延迟",
    ["Cancel"] = "取消",
    ["Restore default"] = "恢复默认",
    ["Save"] = "保存",
    ["Swipe animation refresh mode"] = "翻页动画刷新模式",
    ["UI refresh (default, recommended)"] = "UI刷新（默认，推荐）",
    ["Fast refresh (fastest, more ghosting)"] = "Fast刷新（最快，易残影）",
    ["%1 animation frame delay: %2 ms"] = "%1动画帧延迟：%2 毫秒",
    ["%1 animation frame delay: default %2 ms"] = "%1动画帧延迟：默认 %2 毫秒",
    ["Mild global refresh"] = "轻度全局刷新",
    ["Swipe animation settings"] = "翻页动画设置",
    ["Landscape"] = "横屏",
    ["Portrait"] = "竖屏",
    ["Animation steps"] = "动画步数",
    ["%1 animation steps: %2"] = "%1动画步数：%2",
    ["%1 animation steps: default %2"] = "%1动画步数：默认 %2",
    ["Kobo MTK: sync panel before animation"] = "Kobo MTK：动画前同步屏幕",
    ["Animation style"] = "动画样式",
    ["Slide (new page pushes the old one)"] = "滑动（新页推走旧页）",
    ["Wipe (new page revealed edge to edge)"] = "擦除（新页从一边逐渐显示）",
    ["Animation duration"] = "动画时长",
    ["Animation duration: %1 ms"] = "动画时长：%1 毫秒",
    ["Animation duration: default %1 ms"] = "动画时长：默认 %1 毫秒",
    ["Not available on Android e-ink devices"] = "不支持 Android 墨水屏设备",
    [ [[
Enter the delay between animation frames, in milliseconds.
0 = no extra pause (pace with strip refresh).
Lower is faster, higher is slower.

Current orientation: %1
Current default: %2 ms]] ] = [[
输入每一帧之间的延迟，单位为毫秒。
0 = 不再额外停顿（节奏交给条带刷新）。
数值越低，速度越快，数值越高，速度越慢。

当前保存方向：%1
当前默认值：%2 毫秒]],
    [ [[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh (default): balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]] ] = [[
选择软件翻页动画中，每一小条画面更新时使用的刷新类型。

• UI刷新（默认）：平衡画质与速度，适合大多数情况。
• Fast刷新：速度最快，适合追求流畅度但可接受较多残影的场景。

更改后立即生效。]],
    [ [[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]] ] = [[
调整翻页动画每一帧之间的停顿时间。

直接输入毫秒数即可。竖屏和横屏会分别记住各自的数值。未自定义时，会显示当前方向使用的默认值。]],
    [ [[
• Checked: use partial refresh (for text-only content)

• Unchecked: use full refresh (for content with images)]] ] = [[
• 勾选：使用 Partial 刷新（适用于纯文字内容）

• 未勾选：使用 Full 刷新（适用于图文内容）]],
    [ [[
Adjust the speed (frame delay) and refresh mode (UI / Fast) of the software swipe animation.

The refresh mode directly affects the quality and ghosting of each strip update during the animation.]] ] = [[
调整软件翻页动画的速度（帧延迟）和画面更新刷新模式（UI / Fast）。

刷新模式直接影响动画期间每条画面的更新质量与残影表现。]],
}

local pt_BR_fallback = {
    ["Page turn animations"] = "Animações de virada de página",
    ["Animation frame delay"] = "Intervalo entre quadros da animação",
    ["Cancel"] = "Cancelar",
    ["Restore default"] = "Restaurar padrão",
    ["Save"] = "Salvar",
    ["Swipe animation refresh mode"] = "Modo de atualização da animação de deslizar",
    ["UI refresh (default, recommended)"] = "Atualização da interface (padrão, recomendado)",
    ["Fast refresh (fastest, more ghosting)"] = "Atualização rápida (mais veloz, mais ghosting)",
    ["%1 animation frame delay: %2 ms"] = "%1 - intervalo entre quadros: %2 ms",
    ["%1 animation frame delay: default %2 ms"] = "%1 - intervalo entre quadros: padrão (%2 ms)",
    ["Mild global refresh"] = "Atualização global moderada",
    ["Swipe animation settings"] = "Configurações da animação de deslizar",
    ["Landscape"] = "Modo paisagem",
    ["Portrait"] = "Modo retrato",
    ["Animation steps"] = "Passos da animação",
    ["%1 animation steps: %2"] = "%1 - passos da animação: %2",
    ["%1 animation steps: default %2"] = "%1 - passos da animação: padrão (%2)",
    ["Kobo MTK: sync panel before animation"] = "Kobo MTK: sincronizar o painel antes da animação",
    ["Animation style"] = "Estilo da animação",
    ["Slide (new page pushes the old one)"] = "Deslizar (a nova página empurra a antiga)",
    ["Wipe (new page revealed edge to edge)"] = "Revelar (a nova página aparece de uma borda à outra)",
    ["Animation duration"] = "Duração da animação",
    ["Animation duration: %1 ms"] = "Duração da animação: %1 ms",
    ["Animation duration: default %1 ms"] = "Duração da animação: padrão (%1 ms)",
    ["Not available on Android e-ink devices"] = "Não disponível em dispositivos Android com tela e-ink",
    [ [[
Enter the delay between animation frames, in milliseconds.
0 = no extra pause (pace with strip refresh).
Lower is faster, higher is slower.

Current orientation: %1
Current default: %2 ms]] ] = [[
Insira o intervalo entre quadros da animação, em milissegundos.
0 = sem pausa extra (ritmo pela atualização das faixas).
Menor é mais rápido, maior é mais lento.

Orientação atual: %1
Padrão atual: %2 ms]],
    [ [[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh (default): balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]] ] = [[
Escolha o tipo de atualização utilizado para cada segmento da animação de deslizar por software.

• Atualização da interface (padrão): qualidade e velocidade balanceadas, apropriada para a maioria dos casos.
• Atualização rápida: mais rápida, melhor para a suavização quando pouco ghosting é aceitável.

As alterações são aplicadas imediatamente.]],
    [ [[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]] ] = [[
Ajusta a pausa entre quadros da animação.

Insira um valor em milissegundos. Os modos retrato e paisagem memorizam seus respectivos valores.
Quando inalterado, o padrão para a orientação atual é exibido.]],
    [ [[
• Checked: use partial refresh (for text-only content)

• Unchecked: use full refresh (for content with images)]] ] = [[
• Marcado: utiliza atualização parcial (para conteúdos textuais)

• Desmarcado: utiliza atualização total (para conteúdos com imagens)]],
    [ [[
Adjust the speed (frame delay) and refresh mode (UI / Fast) of the software swipe animation.

The refresh mode directly affects the quality and ghosting of each strip update during the animation.]] ] = [[
Ajusta a velocidade (intervalo de quadros) e o modo de atualização (Interface / Rápido) da animação de deslizar por software.

O modo de atualização impacta diretamente na qualidade e no ghosting de cada faixa de atualização durante a animação.]],
}

local function _(msgid)
    local translated = GetText(msgid)
    if translated ~= msgid then
        return translated
    end
    local lang = G_reader_settings:readSetting("language") or ""
    if lang:match("^zh") then
        return zh_fallback[msgid] or msgid
    elseif lang:match("^pt_BR") then
        return pt_BR_fallback[msgid] or msgid
    end
    return msgid
end

-- ==================== helpers ====================

local function isAnimationEnabled()
    return G_reader_settings:isTrue("swipe_animations")
end

local function orientationLabel(landscape)
    return landscape and _("Landscape") or _("Portrait")
end

local function refreshMenu(touchmenu_instance)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Generic "enter a number" dialog.
-- opts: title, description (already formatted), current, min, save(value|nil)
local function showNumberDialog(opts, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local input_dialog

    input_dialog = InputDialog:new{
        title = opts.title,
        input = tostring(opts.current),
        input_type = "number",
        description = opts.description,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Restore default"),
                    callback = function()
                        opts.save(nil)
                        refreshMenu(touchmenu_instance)
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(input_dialog:getInputValue())
                        if value == nil or value < opts.min then
                            opts.save(nil)
                        else
                            opts.save(math.floor(value))
                        end
                        refreshMenu(touchmenu_instance)
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function showDelayDialog(Hook, touchmenu_instance)
    local landscape = Hook.isLandscape()
    local default_delay_ms = Hook.getDefaultDelayMs(landscape)
    showNumberDialog({
        title = _("Animation frame delay"),
        current = Hook.getConfiguredDelayMs(landscape) or default_delay_ms,
        min = 0,
        description = T(_([[
Enter the delay between animation frames, in milliseconds.
0 = no extra pause (pace with strip refresh).
Lower is faster, higher is slower.

Current orientation: %1
Current default: %2 ms]]), orientationLabel(landscape), default_delay_ms),
        save = function(value) Hook.setConfiguredDelayMs(landscape, value) end,
    }, touchmenu_instance)
end

local function showStepsDialog(Hook, touchmenu_instance)
    local landscape = Hook.isLandscape()
    local default_steps = Hook.getDefaultSteps(landscape)
    showNumberDialog({
        title = _("Animation steps"),
        current = Hook.getConfiguredSteps(landscape) or default_steps,
        min = Hook.MIN_STEPS,
        description = T(_([[
Enter the number of strips the page is revealed in (%1 to %2).
Fewer strips = faster turn, more strips = smoother sweep.

Current orientation: %3
Current default: %4]]), Hook.MIN_STEPS, Hook.MAX_STEPS, orientationLabel(landscape), default_steps),
        save = function(value) Hook.setConfiguredSteps(landscape, value) end,
    }, touchmenu_instance)
end

local function showDurationDialog(Hook, touchmenu_instance)
    showNumberDialog({
        title = _("Animation duration"),
        current = Hook.getLCDDurationMs(),
        min = Hook.MIN_LCD_DURATION_MS,
        description = T(_([[
Enter how long a page turn animation lasts, in milliseconds (%1 to %2).
The number of frames follows the speed of the device.

Current default: %3 ms]]), Hook.MIN_LCD_DURATION_MS, Hook.MAX_LCD_DURATION_MS, Hook.defaults.lcd_duration_ms),
        save = function(value) Hook.setConfiguredLCDDurationMs(value) end,
    }, touchmenu_instance)
end

-- ==================== items ====================

-- Same setting as Page turns > Page turn animations.
local function toggleItem()
    return {
        text = _("Page turn animations"),
        checked_func = isAnimationEnabled,
        callback = function(touchmenu_instance)
            G_reader_settings:flipNilOrFalse("swipe_animations")
            refreshMenu(touchmenu_instance)
        end,
        separator = true,
    }
end

local function radioItem(text, checked_func, callback)
    return {
        text = text,
        radio = true,
        checked_func = checked_func,
        callback = function(touchmenu_instance)
            callback()
            refreshMenu(touchmenu_instance)
        end,
    }
end

local function buildEinkItems(Hook)
    return {
        toggleItem(),
        {
            text = _("Swipe animation refresh mode"),
            enabled_func = isAnimationEnabled,
            help_text = _([[
Choose the refresh type used for each strip of the software swipe animation.

• UI refresh (default): balanced quality and speed, suitable for most cases.
• Fast refresh: fastest, best for smoothness when some ghosting is acceptable.

Changes take effect immediately.]]),
            sub_item_table = {
                radioItem(_("UI refresh (default, recommended)"),
                    function() return Hook.getRefreshMode() == "ui" end,
                    function() Hook.setRefreshMode("ui") end),
                radioItem(_("Fast refresh (fastest, more ghosting)"),
                    function() return Hook.getRefreshMode() == "fast" end,
                    function() Hook.setRefreshMode("fast") end),
            },
        },
        {
            text_func = function()
                local landscape = Hook.isLandscape()
                local configured = Hook.getConfiguredDelayMs(landscape)
                if configured then
                    return T(_("%1 animation frame delay: %2 ms"), orientationLabel(landscape), configured)
                end
                return T(_("%1 animation frame delay: default %2 ms"),
                    orientationLabel(landscape), Hook.getDefaultDelayMs(landscape))
            end,
            enabled_func = isAnimationEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showDelayDialog(Hook, touchmenu_instance)
            end,
            help_text = _([[
Adjust the pause between animation frames.

Enter a value in milliseconds. Portrait and landscape remember their own values.
When unset, the default for the current orientation is shown.]]),
        },
        {
            text_func = function()
                local landscape = Hook.isLandscape()
                local configured = Hook.getConfiguredSteps(landscape)
                if configured then
                    return T(_("%1 animation steps: %2"), orientationLabel(landscape), configured)
                end
                return T(_("%1 animation steps: default %2"),
                    orientationLabel(landscape), Hook.getDefaultSteps(landscape))
            end,
            enabled_func = isAnimationEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showStepsDialog(Hook, touchmenu_instance)
            end,
            help_text = _([[
Number of vertical strips the new page is revealed in.

Fewer strips make the turn faster, more strips make the sweep smoother. Portrait and landscape remember their own values.]]),
        },
        {
            text = _("Mild global refresh"),
            enabled_func = isAnimationEnabled,
            checked_func = Hook.isMildGlobalRefresh,
            callback = function(touchmenu_instance)
                Hook.setMildGlobalRefresh(not Hook.isMildGlobalRefresh())
                refreshMenu(touchmenu_instance)
            end,
            help_text = _([[
• Checked: use partial refresh (for text-only content)

• Unchecked: use full refresh (for content with images)]]),
        },
        Hook.isKoboMTK() and {
            text = _("Kobo MTK: sync panel before animation"),
            enabled_func = isAnimationEnabled,
            checked_func = Hook.isMTKFenceEnabled,
            callback = function(touchmenu_instance)
                Hook.setMTKFenceEnabled(not Hook.isMTKFenceEnabled())
                refreshMenu(touchmenu_instance)
            end,
            help_text = _([[
Before the strips start, wait for the previous screen update and send one no-change full-screen update, so the first strip is not delayed by the display controller.

Inherited from the original patch. Try turning it off: page turns start sooner if your device does not need it.]]),
        } or nil, -- must be the last item
    }
end

local function buildLCDItems(Hook)
    return {
        toggleItem(),
        {
            text = _("Animation style"),
            enabled_func = isAnimationEnabled,
            help_text = _([[
• Slide: the new page pushes the old one out of the screen.
• Wipe: the new page is uncovered from one edge to the other, like the e-ink version.]]),
            sub_item_table = {
                radioItem(_("Slide (new page pushes the old one)"),
                    function() return Hook.getLCDStyle() == "slide" end,
                    function() Hook.setLCDStyle("slide") end),
                radioItem(_("Wipe (new page revealed edge to edge)"),
                    function() return Hook.getLCDStyle() == "wipe" end,
                    function() Hook.setLCDStyle("wipe") end),
            },
        },
        {
            text_func = function()
                local configured = Hook.getConfiguredLCDDurationMs()
                if configured then
                    return T(_("Animation duration: %1 ms"), configured)
                end
                return T(_("Animation duration: default %1 ms"), Hook.defaults.lcd_duration_ms)
            end,
            enabled_func = isAnimationEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showDurationDialog(Hook, touchmenu_instance)
            end,
            help_text = _([[
How long a page turn takes. The animation renders as many frames as the device manages in that time.]]),
        },
    }
end

local function buildInertItems()
    return {
        {
            text = _("Not available on Android e-ink devices"),
            enabled = false,
        },
    }
end

-- ==================== public API ====================

-- Place our entry right after "Page turns" in Settings > Taps and gestures.
-- reader_menu_order is cached by require(), so this only has to run once.
function Menu.registerOrder()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" or type(order.taps_and_gestures) ~= "table" then
        return false
    end
    local section = order.taps_and_gestures
    for i = #section, 1, -1 do
        if section[i] == MENU_KEY then
            return true
        end
    end
    for index, key in ipairs(section) do
        if key == "page_turns" then
            table.insert(section, index + 1, MENU_KEY)
            return true
        end
    end
    return false
end

-- One-time defaults: the animation is on after installing the plugin,
-- and the pre-orientation delay setting of older patch versions is migrated.
function Menu.applyDefaults()
    if not G_reader_settings:isTrue("swipeanimation_defaults_applied") then
        if G_reader_settings:readSetting("swipe_animations") == nil then
            G_reader_settings:saveSetting("swipe_animations", true)
        end
        G_reader_settings:saveSetting("swipeanimation_defaults_applied", true)
    end

    local legacy = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms")) or 0
    if legacy > 0 then
        if (tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_vertical")) or 0) <= 0 then
            G_reader_settings:saveSetting("swipe_animation_delay_ms_vertical", legacy)
        end
        if (tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_horizontal")) or 0) <= 0 then
            G_reader_settings:saveSetting("swipe_animation_delay_ms_horizontal", legacy)
        end
        G_reader_settings:delSetting("swipe_animation_delay_ms")
    end
end

function Menu.key()
    return MENU_KEY
end

function Menu.build(Hook)
    local class = Hook.displayClass()
    local items
    if class == "eink" then
        items = buildEinkItems(Hook)
    elseif class == "lcd" then
        items = buildLCDItems(Hook)
    else
        items = buildInertItems()
    end
    return {
        text = _("Swipe animation settings"),
        -- Fallback placement if reader_menu_order could not be edited.
        sorting_hint = "taps_and_gestures",
        help_text = _([[
Adjust the speed (frame delay) and refresh mode (UI / Fast) of the software swipe animation.

The refresh mode directly affects the quality and ghosting of each strip update during the animation.]]),
        sub_item_table = items,
    }
end

return Menu
