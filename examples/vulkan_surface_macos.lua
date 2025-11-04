local ffi = require("ffi")
local vulkan = require("helpers.vulkan")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local wnd = cocoa.window()
local vk = vulkan.vk
local lib = vulkan.lib
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "VK_PRESENT_MODE_FIFO_KHR",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR",
	}
)
renderer:PrintCapabilities()
wnd:Initialize()
wnd:OpenWindow()
local frame = 0

local function hsv_to_rgb(h, s, v)
	local c = v * s
	local x = c * (1 - math.abs((h * 6) % 2 - 1))
	local m = v - c
	local r, g, b
	local h6 = h * 6

	if h6 < 1 then
		r, g, b = c, x, 0
	elseif h6 < 2 then
		r, g, b = x, c, 0
	elseif h6 < 3 then
		r, g, b = 0, c, x
	elseif h6 < 4 then
		r, g, b = 0, x, c
	elseif h6 < 5 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end

	return r + m, g + m, b + m
end

while true do
	local events = wnd:ReadEvents()

	if events.window_close_requested then
		print("Window close requested")

		break
	end

	if events.window_resized then renderer:RecreateSwapchain() end

	if renderer:BeginFrame() then
		local range = vk.Box(
			vk.VkImageSubresourceRange,
			{
				aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			}
		)
		lib.vkCmdClearColorImage(
			renderer:GetCommandBuffer().ptr[0],
			renderer:GetSwapChainImage(),
			"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
			vk.Box(vk.VkClearColorValue, {
				float32 = {hsv_to_rgb(frame % 1, 1, 1)},
			}),
			1,
			range
		)
		renderer:EndFrame()
	end

	frame = frame + 0.01
	threads.sleep(1)
end

renderer:WaitForIdle()
