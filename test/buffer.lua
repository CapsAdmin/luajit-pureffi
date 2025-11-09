local ffi = require("ffi")
local Buffer = require("helpers.buffer")

do
	local buf = ffi.new("uint8_t[10]", {1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
	local buffer = Buffer.New(buf, 10)
	assert(buffer:ReadByte() == 1)
	assert(buffer:ReadByte() == 2)
	assert(buffer:ReadByte() == 3)
	buffer:Advance(2)
	assert(buffer:ReadByte() == 6)
	buffer:Advance(-3)
	assert(buffer:ReadByte() == 4)
end

do
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20)
	buffer:WriteStringNonNullterminated("hello world")
	buffer:SetPosition(0)
	local str = buffer:ReadStringNonNullterminated()
	assert(str == "hello world")
end

do -- test varint
	local buf = ffi.new("uint8_t[10]")
	local buffer = Buffer.New(buf, 10)
	buffer:WriteVariableSizedInteger(300)
	buffer:SetPosition(0)
	local val = buffer:ReadVarInt()
	assert(val == 300)
end

do -- test half
	local buf = ffi.new("uint8_t[10]")
	local buffer = Buffer.New(buf, 10)
	buffer:WriteHalf(3.14159)
	buffer:SetPosition(0)
	local val = buffer:ReadHalf()
	assert(math.abs(val - 3.140625) < 0.0001)
end

do -- test push pop
	local buf = ffi.new("uint8_t[10]", {1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
	local buffer = Buffer.New(buf, 10)
	assert(buffer:ReadByte() == 1)
	buffer:PushPosition(5)
	assert(buffer:ReadByte() == 6)
	buffer:PopPosition()
	assert(buffer:ReadByte() == 2)
end

do -- test read bits
	local buf = ffi.new("uint8_t[2]", {0b10101010, 0b11001100})
	local buffer = Buffer.New(buf, 2)
	buffer:RestartReadBits()
	assert(buffer:ReadBits(4) == 0b1010)
	assert(buffer:ReadBits(4) == 0b1010)
	assert(buffer:ReadBits(8) == 0b11001100)
end

do -- test find string
	local buf = ffi.new("uint8_t[20]", "hello world, this is a test")
	local buffer = Buffer.New(buf, 20)
	local pos = buffer:FindNearest("this")
	assert(buffer:GetStringSlice(pos - #("this"), pos - 1) == "this")
end

do -- write mode
	local buf = ffi.new("uint8_t[5]")
	local buffer = Buffer.New(buf, 5):MakeWritable()
	buffer:WriteBytes("hello", 5)
	buffer:SetPosition(0)
	local str = buffer:ReadBytes(5)
	assert(str == "hello")
end

do -- grow buffer
	local buf = ffi.new("uint8_t[5]")
	local buffer = Buffer.New(buf, 5):MakeWritable()
	buffer:WriteBytes("hello world", 11)
	assert(buffer:GetSize() >= 11)
	buffer:SetPosition(0)
	local str = buffer:ReadBytes(11)
	assert(str == "hello world")
end

print("Testing endianness handling...")

do -- test U16 endianness
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	-- Write the same value in both endiannesses
	buffer:WriteU16LE(0x1234)
	buffer:WriteU16BE(0x1234)

	-- Verify bytes are swapped
	buffer:SetPosition(0)
	assert(buffer:GetByte(0) == 0x34, "LE byte 0 should be 0x34")
	assert(buffer:GetByte(1) == 0x12, "LE byte 1 should be 0x12")
	assert(buffer:GetByte(2) == 0x12, "BE byte 0 should be 0x12")
	assert(buffer:GetByte(3) == 0x34, "BE byte 1 should be 0x34")

	-- Read back
	buffer:SetPosition(0)
	assert(buffer:ReadU16LE() == 0x1234, "LE read failed")
	assert(buffer:ReadU16BE() == 0x1234, "BE read failed")

	print("  U16 endianness: OK")
end

do -- test U32 endianness
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	-- Write a distinctive value
	buffer:WriteU32LE(0x12345678)
	buffer:WriteU32BE(0x12345678)

	-- Verify bytes
	buffer:SetPosition(0)
	assert(buffer:GetByte(0) == 0x78, "LE byte 0")
	assert(buffer:GetByte(1) == 0x56, "LE byte 1")
	assert(buffer:GetByte(2) == 0x34, "LE byte 2")
	assert(buffer:GetByte(3) == 0x12, "LE byte 3")
	assert(buffer:GetByte(4) == 0x12, "BE byte 0")
	assert(buffer:GetByte(5) == 0x34, "BE byte 1")
	assert(buffer:GetByte(6) == 0x56, "BE byte 2")
	assert(buffer:GetByte(7) == 0x78, "BE byte 3")

	-- Read back
	buffer:SetPosition(0)
	assert(buffer:ReadU32LE() == 0x12345678, "LE read failed")
	assert(buffer:ReadU32BE() == 0x12345678, "BE read failed")

	print("  U32 endianness: OK")
end

do -- test I32 signed endianness
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	-- Test negative number
	buffer:WriteI32LE(-1234567)
	buffer:WriteI32BE(-1234567)

	buffer:SetPosition(0)
	assert(buffer:ReadI32LE() == -1234567, "LE signed read failed")
	assert(buffer:ReadI32BE() == -1234567, "BE signed read failed")

	print("  I32 signed endianness: OK")
end

do -- test U64 endianness
	local buf = ffi.new("uint8_t[32]")
	local buffer = Buffer.New(buf, 32):MakeWritable()

	local value = 0x123456789ABCDEF0ULL
	buffer:WriteU64LE(value)
	buffer:WriteU64BE(value)

	-- Verify byte order for LE
	buffer:SetPosition(0)
	assert(buffer:GetByte(0) == 0xF0, "LE byte 0")
	assert(buffer:GetByte(1) == 0xDE, "LE byte 1")
	assert(buffer:GetByte(7) == 0x12, "LE byte 7")

	-- Verify byte order for BE
	assert(buffer:GetByte(8) == 0x12, "BE byte 0")
	assert(buffer:GetByte(15) == 0xF0, "BE byte 7")

	-- Read back
	buffer:SetPosition(0)
	assert(buffer:ReadU64LE() == value, "LE U64 read failed")
	assert(buffer:ReadU64BE() == value, "BE U64 read failed")

	print("  U64 endianness: OK")
end

do -- test Float endianness
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	local test_value = 3.14159
	buffer:WriteFloatLE(test_value)
	buffer:WriteFloatBE(test_value)

	-- Verify bytes are different between LE and BE
	buffer:SetPosition(0)
	local le_byte0 = buffer:GetByte(0)
	local be_byte0 = buffer:GetByte(4)
	local le_byte3 = buffer:GetByte(3)
	local be_byte3 = buffer:GetByte(7)

	assert(le_byte0 == be_byte3, "Float LE byte 0 should equal BE byte 3")
	assert(le_byte3 == be_byte0, "Float LE byte 3 should equal BE byte 0")

	-- Read back and verify values
	buffer:SetPosition(0)
	local read_le = buffer:ReadFloatLE()
	local read_be = buffer:ReadFloatBE()

	assert(math.abs(read_le - test_value) < 0.00001, "Float LE read failed")
	assert(math.abs(read_be - test_value) < 0.00001, "Float BE read failed")

	print("  Float endianness: OK")
end

do -- test Double endianness
	local buf = ffi.new("uint8_t[32]")
	local buffer = Buffer.New(buf, 32):MakeWritable()

	local test_value = 3.141592653589793
	buffer:WriteDoubleLE(test_value)
	buffer:WriteDoubleBE(test_value)

	-- Verify bytes are swapped
	buffer:SetPosition(0)
	local le_byte0 = buffer:GetByte(0)
	local be_byte0 = buffer:GetByte(8)
	local le_byte7 = buffer:GetByte(7)
	local be_byte7 = buffer:GetByte(15)

	assert(le_byte0 == be_byte7, "Double LE byte 0 should equal BE byte 7")
	assert(le_byte7 == be_byte0, "Double LE byte 7 should equal BE byte 0")

	-- Read back and verify values
	buffer:SetPosition(0)
	local read_le = buffer:ReadDoubleLE()
	local read_be = buffer:ReadDoubleBE()

	assert(math.abs(read_le - test_value) < 0.000000000001, "Double LE read failed")
	assert(math.abs(read_be - test_value) < 0.000000000001, "Double BE read failed")

	print("  Double endianness: OK")
end

do -- test I16 endianness
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	buffer:WriteI16LE(-12345)
	buffer:WriteI16BE(-12345)

	buffer:SetPosition(0)
	assert(buffer:ReadI16LE() == -12345, "I16 LE read failed")
	assert(buffer:ReadI16BE() == -12345, "I16 BE read failed")

	print("  I16 endianness: OK")
end

do -- test I64 endianness
	local buf = ffi.new("uint8_t[32]")
	local buffer = Buffer.New(buf, 32):MakeWritable()

	local value = -9223372036854775807LL  -- Near min int64
	buffer:WriteI64LE(value)
	buffer:WriteI64BE(value)

	buffer:SetPosition(0)
	assert(buffer:ReadI64LE() == value, "I64 LE read failed")
	assert(buffer:ReadI64BE() == value, "I64 BE read failed")

	print("  I64 endianness: OK")
end

do -- test cross-endian compatibility
	local buf = ffi.new("uint8_t[20]")
	local buffer = Buffer.New(buf, 20):MakeWritable()

	-- Write as LE, read as BE (should get swapped value)
	buffer:WriteU32LE(0x12345678)
	buffer:SetPosition(0)
	local swapped = buffer:ReadU32BE()
	assert(swapped == 0x78563412, "Cross-endian read failed")

	print("  Cross-endian compatibility: OK")
end

do -- test NaN handling with endianness
	local buf = ffi.new("uint8_t[32]")
	local buffer = Buffer.New(buf, 32):MakeWritable()

	local nan = 0/0
	buffer:WriteFloatLE(nan)
	buffer:WriteFloatBE(nan)
	buffer:WriteDoubleLE(nan)
	buffer:WriteDoubleBE(nan)

	buffer:SetPosition(0)
	local f_le = buffer:ReadFloatLE()
	local f_be = buffer:ReadFloatBE()
	local d_le = buffer:ReadDoubleLE()
	local d_be = buffer:ReadDoubleBE()

	assert(f_le ~= f_le, "Float LE NaN check failed")  -- NaN ~= NaN
	assert(f_be ~= f_be, "Float BE NaN check failed")
	assert(d_le ~= d_le, "Double LE NaN check failed")
	assert(d_be ~= d_be, "Double BE NaN check failed")

	print("  NaN handling: OK")
end

print("All endianness tests passed!")
