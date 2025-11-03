local ffi = require("ffi")
local cocoa = {}
ffi.cdef[[
    // Objective-C runtime
    typedef struct objc_class *Class;
    typedef struct objc_object *id;
    typedef struct objc_selector *SEL;
    typedef id (*IMP)(id, SEL, ...);
    typedef unsigned long NSUInteger;
    typedef long NSInteger;
    
    id objc_getClass(const char *name);
    SEL sel_registerName(const char *str);
    id objc_msgSend(id self, SEL op, ...);
    void objc_msgSend_stret(void *stretAddr, id self, SEL op, ...);
    id objc_retain(id obj);
    void objc_release(id obj);
    Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
    void objc_registerClassPair(Class cls);
    bool class_addMethod(Class cls, SEL name, IMP imp, const char *types);
    
    // CoreGraphics types
    typedef struct CGPoint { double x; double y; } CGPoint;
    typedef struct CGSize { double width; double height; } CGSize;
    typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;
]]
local objc = ffi.load("/usr/lib/libobjc.A.dylib")

local function objc_class(name)
    return objc.objc_getClass(name)
end

local function sel(name)
    return objc.sel_registerName(name)
end

local function msg(obj, selector, ...)
    return objc.objc_msgSend(obj, sel(selector), ...)
end

-- For methods that return structures
local function msg_stret(ret_ptr, obj, selector, ...)
    objc.objc_msgSend_stret(ret_ptr, obj, sel(selector), ...)
end

local function CGRectMake(x, y, width, height)
    return ffi.new("CGRect", {{x, y}, {width, height}})
end

-- Store references to prevent garbage collection
local metal_layer = nil
local window = nil

-- Initialize Cocoa application and create window
local function init_cocoa()
    print("Creating autorelease pool...")
    local NSAutoreleasePool = objc_class("NSAutoreleasePool")
    local pool = msg(msg(NSAutoreleasePool, "alloc"), "init")
    print("Getting NSApplication...")
    local NSApp = msg(objc_class("NSApplication"), "sharedApplication")
    print("Activating app...")
    msg(NSApp, "setActivationPolicy:", 0) -- NSApplicationActivationPolicyRegular
    msg(NSApp, "activateIgnoringOtherApps:", true)
    print("Creating window...")
    local NSWindow = objc_class("NSWindow")
    local frame = CGRectMake(100, 100, 800, 600)
    -- Window style mask: titled, closable, resizable, miniaturizable
    local styleMask = bit.bor(1, 2, 4, 8) -- Titled | Closable | Miniaturizable | Resizable
    -- Allocate window
    local window_alloc = msg(NSWindow, "alloc")
    print("Window allocated:", window_alloc)
    -- Initialize with contentRect - pass args explicitly
    window = ffi.cast("id(*)(id, SEL, CGRect, NSUInteger, NSUInteger, bool)", objc.objc_msgSend)(
        window_alloc,
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        ffi.cast("NSUInteger", styleMask),
        ffi.cast("NSUInteger", 2),
        false
    )
    print("Window initialized:", window)
    print("Setting window title...")
    local NSString = objc_class("NSString")
    local title_cstr = "MoltenVK LuaJIT Window"
    local title = ffi.cast("id(*)(id, SEL, const char*)", objc.objc_msgSend)(NSString, sel("stringWithUTF8String:"), title_cstr)
    print("Title created:", title)
    ffi.cast("void(*)(id, SEL, id)", objc.objc_msgSend)(window, sel("setTitle:"), title)
    print("Title set!")
    print("Making window visible...")
    msg(window, "makeKeyAndOrderFront:", nil)
    print("Getting content view...")
    local contentView = msg(window, "contentView")
    print("Creating CAMetalLayer...")
    local CAMetalLayer = objc_class("CAMetalLayer")
    metal_layer = msg(CAMetalLayer, "layer")
    print("Setting metal layer...")
    msg(contentView, "setWantsLayer:", true)
    msg(contentView, "setLayer:", metal_layer)
    print("Retaining objects...")
    objc.objc_retain(window)
    objc.objc_retain(metal_layer)
    print("Cocoa initialization complete!")
    return pool, window, metal_layer
end

return {
    objc = objc,
    init = init_cocoa,
    msg = msg,
    sel = sel,
    objc_class = objc_class,
}