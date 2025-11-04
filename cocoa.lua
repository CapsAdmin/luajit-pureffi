local ffi = require("ffi")
local objc = require("objc")
local cocoa = {}
-- Load required frameworks
objc.loadFramework("Cocoa")
objc.loadFramework("QuartzCore")

local function CGRectMake(x, y, width, height)
    return ffi.new("CGRect", {{x, y}, {width, height}})
end

-- Initialize Cocoa application and create window
local function init_cocoa()
    local pool = objc.NSAutoreleasePool:alloc():init()
    local app = objc.NSApplication:sharedApplication()
    app:setActivationPolicy_(0) -- NSApplicationActivationPolicyRegular
    app:activateIgnoringOtherApps_(true)

    local frame = CGRectMake(100, 100, 800, 600)
    local styleMask = bit.bor(1, 2, 4, 8) -- Titled | Closable | Miniaturizable | Resizable

    local window = objc.NSWindow:alloc():initWithContentRect_styleMask_backing_defer_(
        frame,
        styleMask,
        2, -- NSBackingStoreBuffered
        false
    )

    window:setTitle_(objc.NSString:stringWithUTF8String_("MoltenVK LuaJIT Window"))
    -- Use msgSend directly with explicit NULL pointer
    objc.msgSend(window, "makeKeyAndOrderFront:", ffi.cast("id", 0))

    -- Use msgSend directly for contentView to avoid property lookup
    local contentView = objc.msgSend(window, "contentView")
    local metal_layer = objc.CAMetalLayer:layer()

    -- Set initial drawable size to match the content view bounds
    local bounds = objc.msgSend(contentView, "bounds")
    metal_layer:setDrawableSize_(bounds.size)

    contentView:setWantsLayer_(true)
    contentView:setLayer_(metal_layer)

    return window, metal_layer
end

-- Event loop helpers
local function poll_events(app, window)
    -- Create fresh objects each iteration (they're lightweight singletons)
    local distantPast = objc.NSDate:distantPast()
    local mode = objc.NSString:stringWithUTF8String_("kCFRunLoopDefaultMode")

    -- Poll for events without blocking
    local event = app:nextEventMatchingMask_untilDate_inMode_dequeue_(
        0xFFFFFFFFFFFFFFFFULL,  -- NSEventMaskAny
        distantPast,
        mode,
        true -- dequeue
    )

    if event ~= nil and event ~= objc.ptr(nil) then
        app:sendEvent_(event)
        app:updateWindows()
        return true
    end

    return false
end

-- Helper to get the NSApplication singleton
local function get_app()
    return objc.NSApplication:sharedApplication()
end

local meta = {}
meta.__index = meta

function cocoa.window()
    local self = setmetatable({}, meta)
    self.window, self.metal_layer = init_cocoa()
    self.last_width = nil
    self.last_height = nil
    self.close_requested = false
    return self
end

function meta:Initialize()
    self.app = get_app()

    self.app:finishLaunching()
end

function meta:OpenWindow()
    self.window:makeKeyAndOrderFront_(ffi.cast("id", 0))
    self.app:activateIgnoringOtherApps_(true)
end

function meta:GetMetalLayer()
    return self.metal_layer
end

function meta:ReadEvents()
    while poll_events(self.app, self.window) do
        -- Process events
    end

    -- Poll for window size changes
    local events = {}
    local window_frame = objc.msgSend(self.window, "frame")
    local current_width = tonumber(window_frame.size.width)
    local current_height = tonumber(window_frame.size.height)

    -- Initialize on first call
    if self.last_width == nil then
        self.last_width = current_width
        self.last_height = current_height
    elseif current_width ~= self.last_width or current_height ~= self.last_height then
        events.window_resized = true
        self.last_width = current_width
        self.last_height = current_height

        -- Update metal layer drawable size
        local content_view = objc.msgSend(self.window, "contentView")
        local bounds = objc.msgSend(content_view, "bounds")
        self.metal_layer:setDrawableSize_(bounds.size)
    end

    -- Check if window is closing (no longer visible)
    local isVisible = objc.msgSend(self.window, "isVisible")
    if not isVisible or isVisible == 0 then
        events.window_close_requested = true
    end

    return events
end

function meta:GetWindowSize()
    local window_frame = objc.msgSend(self.window, "frame")
    return tonumber(window_frame.size.width), tonumber(window_frame.size.height)
end

return cocoa