print("Starting PNG decode test...")
io.flush()
local ffi = require("ffi")
print("Loaded FFI")
io.flush()
local Buffer = require("helpers.buffer")
print("Loaded Buffer")
io.flush()
local png = require("helpers.png")
print("Loaded PNG")
io.flush()
-- Load PNG file into buffer
local file = io.open("examples/vulkan/capsadmin.png", "rb")
print("Opened file")

if not file then error("Could not open PNG file") end

local file_data = file:read("*a")
file:close()
-- Create buffer from file data
local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
ffi.copy(file_buffer_data, file_data, #file_data)
local file_buffer = Buffer.New(file_buffer_data, #file_data)
-- Decode PNG
print("Decoding PNG...")
local img = png.decode(file_buffer, nil, true) -- verbose = true
-- Print results
print("Width:", img.width)
print("Height:", img.height)
print("Bit depth:", img.depth)
print("Color type:", img.colorType)
print("Buffer size:", img.buffer:GetSize())
print(
	"Expected size:",
	img.width * img.height * 4,
	"(width * height * 4 bytes per pixel)"
)
-- Verify buffer contains data
img.buffer:SetPosition(0)
print("First 16 bytes (RGBA of first 4 pixels):")

for i = 1, 16 do
	print(string.format("  Byte %d: %d", i - 1, img.buffer:ReadByte()))
end

print("\nPNG decode test passed!")
