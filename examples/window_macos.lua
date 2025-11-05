local cocoa = require("cocoa")
local wnd = cocoa.window()
wnd:Initialize()
wnd:OpenWindow()

while true do
	local events = wnd:ReadEvents()

	if events.window_close_requested then
		print("Window close requested")

		break
	end

	if events.window_resized then print("window resize") end
end
