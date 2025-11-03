local ffi = require("ffi")
local vk = require("vulkan")
local lib = vk.find_library()
local cocoa = require("cocoa")
local threads = require("threads")

local wnd = cocoa.window()

local function vk_assert(result, msg)
	if result ~= 0 then
		error((msg or "error") .. " : " .. vk.EnumToString(result), 2)
	end
end

print("Cocoa window created")
local appInfo = vk.Box(
	vk.VkApplicationInfo,
	{
		sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
		pApplicationName = "MoltenVK LuaJIT Example",
		applicationVersion = 1,
		pEngineName = "No Engine",
		engineVersion = 1,
		apiVersion = vk.VK_API_VERSION_1_0,
	}
)

local extension_names = vk.Array(ffi.typeof("const char*"), 2, {"VK_KHR_surface", "VK_EXT_metal_surface"})
local createInfo = vk.Box(
	vk.VkInstanceCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
		pNext = nil,
		flags = 0,
		pApplicationInfo = appInfo,
		enabledLayerCount = 0,
		ppEnabledLayerNames = nil,
		enabledExtensionCount = 2,
		ppEnabledExtensionNames = extension_names,
	}
)
local instance = vk.Box(vk.VkInstance)()
vk_assert(lib.vkCreateInstance(createInfo, nil, instance), "failed to create vulkan instance")

local surfaceCreateInfo = vk.VkMetalSurfaceCreateInfoEXT(
	{
		sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
		pNext = nil,
		flags = 0,
		pLayer = ffi.cast("const void*", assert(wnd:GetMetalLayer()), "failed to get metal layer"),
	}
)
local surface = vk.Box(vk.VkSurfaceKHR)()
local vkCreateMetalSurfaceEXT = vk.GetExtension(lib, instance[0], "vkCreateMetalSurfaceEXT")
vk_assert(
	vkCreateMetalSurfaceEXT(instance[0], surfaceCreateInfo, nil, surface),
	"failed to create metal surface"
)
local deviceCount = ffi.new("uint32_t[1]", 0)
vk_assert(
	lib.vkEnumeratePhysicalDevices(instance[0], deviceCount, nil),
	"failed to enumerate physical devices"
)

if deviceCount[0] == 0 then error("no physical devices found") end

wnd:Initialize()
wnd:OpenWindow()

-- Main event loop
while not wnd:ShouldQuit() do
	local events = wnd:ReadEvents()

	threads.sleep(16)
end
