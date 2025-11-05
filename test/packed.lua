local ffi = require("ffi")

-- This WILL trigger the error:
-- The key is using __attribute__((packed)) to force misalignment
local t = ffi.typeof[[
    __attribute__((packed)) struct {
        unsigned char a : 7;   // Uses bits 0-6 of first byte
        struct {
            unsigned char b : 3;   // Tries to use bits 7-9, crossing into second byte!
        };
    }
]]

local s = t()

print(ffi.sizeof(s))  -- Should be 2 bytes due to packing

s.a = 127 + 1
print(s.a)
s.b = 7 + 1
print(s.b)