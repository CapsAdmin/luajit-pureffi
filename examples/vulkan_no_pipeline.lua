local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local wnd = cocoa.window()
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
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
		renderer:GetCommandBuffer():ClearColorImage({
			image = renderer:GetSwapChainImage(),
			color = {hsv_to_rgb(frame % 1, 1, 1)},
		})
		renderer:EndFrame()
	end

	frame = frame + 0.01
	threads.sleep(1)
end

renderer:WaitForIdle()
