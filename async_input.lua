local terminal = require("terminal")

local o = terminal.WrapFile(io.stdin, io.stdout)

while true do
    local event = o:ReadEvent()
    
    if event then
        local mods = {}
        if event.modifiers.ctrl then table.insert(mods, "Ctrl") end
        if event.modifiers.shift then table.insert(mods, "Shift") end
        if event.modifiers.alt then table.insert(mods, "Alt") end
        
        local mod_str = #mods > 0 and table.concat(mods, "+") .. "+" or ""
        
        print(string.format("Key: %s%s", mod_str, event.key))
        
        if event.key == "c" and event.modifiers.ctrl then
            break
        end
    end
end

print("\nExiting...")
