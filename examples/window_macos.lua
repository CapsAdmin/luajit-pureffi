local cocoa = require("cocoa")
local wnd = cocoa.window()
wnd:Initialize()
wnd:OpenWindow()

while true do
	local events = wnd:ReadEvents()

	for _, event in ipairs(events) do
		if event.type == "window_close" then
			print("Window close requested")
			os.exit()
		end

		if event.type == "window_resize" then 
			print("window resize:", event.width, "x", event.height) 
		end
		
		if event.type == "key_press" then
			print("key pressed:", event.key, event.char or "")
		end
		
		if event.type == "mouse_button" then
			print("mouse button:", event.action, event.button, "at", event.x, event.y)
		end
	end
end