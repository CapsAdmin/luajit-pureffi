local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
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
local pipeline

function renderer:OnRecreateSwapchain()
	local extent = renderer:GetExtent()
	local w = tonumber(extent.width)
	local h = tonumber(extent.height)
	-- Vertex data: position (vec2) + color (vec3) = 5 floats per vertex, 3 vertices
	local vertexBuffer = renderer:CreateVertexBuffer(
		{
			-- bottom-left (red)
			0.0, -- x
			-0.5, -- y
			1.0, -- r
			0.0, -- g
			0.0, -- b
			-- top (blue)
			0.5,
			0.5,
			0.0,
			1.0,
			0.0,
			-- bottom-right (green)
			-0.5,
			0.5,
			0.0,
			0.0,
			1.0,
		}
	)
	pipeline = renderer:CreatePipeline(
		{
			shader_stages = {
				{
					type = "vertex",
					code = [[
						#version 450

						layout(location = 0) in vec2 inPosition;
						layout(location = 1) in vec3 inColor;

						layout(location = 0) out vec3 fragColor;

						void main() {
							gl_Position = vec4(inPosition, 0.0, 1.0);
							fragColor = inColor;
						}
					]],
				},
				{
					type = "fragment",
					code = [[
						#version 450

						layout(binding = 0) uniform ColorUniform {
							vec4 colorMultiplier;
						} ubo;

						layout(binding = 1) uniform ColorUniform2 {
							vec4 colorMultiplier;
						} ubo2;

						layout(location = 0) in vec3 fragColor;
						layout(location = 0) out vec4 outColor;

						void main() {
							outColor = vec4(fragColor, 1.0) * ubo.colorMultiplier * ubo2.colorMultiplier;
						}
					]],
				},
			},
			input_assembly = {
				topology = "triangle_list",
				primitive_restart = false,
			},
			viewport = {
				x = 0.0,
				y = 0.0,
				w = w,
				h = h,
				min_depth = 0.0,
				max_depth = 1.0,
			},
			scissor = {
				x = 0,
				y = 0,
				w = w,
				h = h,
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "back",
				front_face = "clockwise",
				depth_bias = 0,
			},
			multisampling = {
				sample_shading = false,
				rasterization_samples = "1",
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = false,
						color_write_mask = {"r", "g", "b", "a"},
					},
				},
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
				depth_compare_op = "less",
				depth_bounds_test = false,
				stencil_test = false,
			},
			uniform_buffers = {
				{
					stage = "fragment",
					byte_size = ffi.sizeof("float") * 4,
					initial_data = ffi.new("float[4]", {1.0, 1.0, 1.0, 1.0}),
				},
				{
					stage = "fragment",
					byte_size = ffi.sizeof("float") * 4,
					initial_data = ffi.new("float[4]", {1.0, 1.0, 1.0, 1.0}),
				},
			},
			vertex_bindings = {
				{
					binding = 0,
					stride = ffi.sizeof("float") * 5, -- vec2 + vec3
					input_rate = "vertex",
				},
			},
			vertex_attributes = {
				{
					location = 0,
					binding = 0,
					format = "R32G32_SFLOAT", -- vec2
					offset = 0,
				},
				{
					location = 1,
					binding = 0,
					format = "R32G32B32_SFLOAT", -- vec3
					offset = ffi.sizeof("float") * 2,
				},
			},
			vertex_buffers = {vertexBuffer},
		}
	)
end

renderer:OnRecreateSwapchain()
wnd:Initialize()
wnd:OpenWindow()

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
		print("close")

		break
	end

	if events.window_resized then renderer:RecreateSwapchain() end

	if renderer:BeginFrame() then
		local cmd = renderer:BeginRenderPass({0.2, 0.2, 0.2, 1.0})
		pipeline:UpdateUniformBuffer(1, ffi.new("float[4]", {hsv_to_rgb((os.clock() % 10) / 10, 1.0, 1.0)}))
		pipeline:Bind(cmd)
		pipeline:BindVertexBuffers(cmd, 0)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(1)
end

renderer:WaitForIdle()
