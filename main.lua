--[[
    Swipe Animation -- a self-contained KOReader plugin.

    Drop the swipeanimation.koplugin folder into koreader/plugins/ and
    restart KOReader. Nothing outside this folder is touched: the hooks are
    installed at runtime on the live Screen / Device / ReaderPaging objects
    (see swipehook.lua for how and why that works).

    Derived from the Swipe_Animation patch set
    (https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin),
    GPLv3.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

local Hook = dofile(plugin_dir .. "swipehook.lua")
local Menu = dofile(plugin_dir .. "swipemenu.lua")

local SwipeAnimation = WidgetContainer:extend{
    name = "swipeanimation",
    is_doc_only = true,
}

function SwipeAnimation:init()
    -- PluginLoader runs main.lua even for disabled plugins, so nothing is
    -- hooked at module level: everything happens when a reader instance
    -- actually creates us.
    Hook.install()
    Hook.setActive(true)
    Menu.applyDefaults()
    Menu.registerOrder()
    self.ui.menu:registerToMainMenu(self)
end

function SwipeAnimation:addToMainMenu(menu_items)
    menu_items[Menu.key()] = Menu.build(Hook)
end

function SwipeAnimation:onCloseDocument()
    Hook.setActive(false)
end

function SwipeAnimation:onCloseWidget()
    Hook.setActive(false)
end

return SwipeAnimation
