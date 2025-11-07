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
local RGBA = ffi.typeof("float[4]")
local pipeline
local VERTEX_BIND_POSITION = 0
-- Create 32x32 random noise texture
local texture_size = 32
local texture_data = ffi.new("uint8_t[?]", texture_size * texture_size * 4)
math.randomseed(os.time())

for i = 0, texture_size * texture_size * 4 - 1 do
	texture_data[i] = math.random(0, 255)
end

local texture_image = renderer.device:CreateImage(
	texture_size,
	texture_size,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst"},
	"device_local"
)
renderer:UploadToImage(texture_image, texture_data, texture_size, texture_size)
local texture_view = texture_image:CreateView()
local texture_sampler = renderer.device:CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
local vertex_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = {
			-- bottom-left (red) + UV (0, 0)
			0.0, -- x
			-0.5, -- y
			1.0, -- r
			0.0, -- g
			0.0, -- b
			0.0, -- u
			0.0, -- v
			-- top (blue) + UV (0.5, 1)
			0.5,
			0.5,
			0.0,
			1.0,
			0.0,
			0.5,
			1.0,
			-- bottom-right (green) + UV (1, 0)
			-0.5,
			0.5,
			0.0,
			0.0,
			1.0,
			1.0,
			0.0,
		},
	}
)
-- Create pipeline once at startup with dynamic viewport/scissor
local pipeline = renderer:CreatePipeline(
	{
		dynamic_states = {"viewport", "scissor"},
		input_assembly = {
			topology = "triangle_list",
			primitive_restart = false,
		},
		vertex_bindings = {
			{
				binding = VERTEX_BIND_POSITION,
				stride = ffi.sizeof("float") * 7, -- vec2 + vec3 + vec2
				input_rate = "vertex",
			},
		},
		vertex_attributes = {
			{
				binding = VERTEX_BIND_POSITION,
				location = 0, -- in_position
				format = "R32G32_SFLOAT", -- vec2
				offset = 0,
			},
			{
				binding = VERTEX_BIND_POSITION,
				location = 1, -- in_color
				format = "R32G32B32_SFLOAT", -- vec3
				offset = ffi.sizeof("float") * 2,
			},
			{
				binding = VERTEX_BIND_POSITION,
				location = 2, -- in_uv
				format = "R32G32_SFLOAT", -- vec2
				offset = ffi.sizeof("float") * 5,
			},
		},
		vertex_buffers = {vertex_buffer},
		uniform_buffers = {
			{
				stage = "fragment",
				buffer = renderer:CreateBuffer(
					{
						byte_size = ffi.sizeof(RGBA),
						buffer_usage = "uniform_buffer",
						data = RGBA(1.0, 1.0, 1.0, 1.0),
					}
				),
			},
			{
				stage = "fragment",
				buffer = renderer:CreateBuffer(
					{
						byte_size = ffi.sizeof(RGBA),
						buffer_usage = "uniform_buffer",
						data = RGBA(1.0, 1.0, 1.0, 1.0),
					}
				),
			},
		},
		textures = {
			{
				stage = "fragment",
				texture = {
					image = texture_image,
					view = texture_view,
					sampler = texture_sampler,
				},
			},
		},
		shader_stages = {
			{
				type = "vertex",
				code = [[
						#version 450

						layout(location = 0) in vec2 in_position;
						layout(location = 1) in vec3 in_color;
						layout(location = 2) in vec2 in_uv;

						layout(location = 0) out vec3 frag_color;
						layout(location = 1) out vec2 frag_uv;

						void main() {
							gl_Position = vec4(in_position, 0.0, 1.0);
							frag_color = in_color;
							frag_uv = in_uv;
						}
					]],
			},
			{
				type = "fragment",
				code = [[
						#version 450

						layout(binding = 0) uniform ColorUniform1 {
							vec4 color_multiplier;
						} ubo1;

						layout(binding = 1) uniform ColorUniform2 {
							vec4 color_multiplier;
						} ubo2;

						layout(binding = 2) uniform sampler2D tex_sampler;

						// from vertex shader
						layout(location = 0) in vec3 frag_color;
						layout(location = 1) in vec2 frag_uv;

						// output color
						layout(location = 0) out vec4 out_color;

						void main() {
							vec4 tex_color = texture(tex_sampler, frag_uv);
							out_color = vec4(frag_color, 1.0) * ubo1.color_multiplier * ubo2.color_multiplier * tex_color;
						}
					]],
			},
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
		multisampling = {
			sample_shading = false,
			rasterization_samples = "1",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)
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

	for _, event in ipairs(events) do
		if event.type == "window_close" then
			renderer:WaitForIdle()
			os.exit()
		end

		if event.type == "window_resize" then renderer:RecreateSwapchain() end
	end

	if renderer:BeginFrame() then
		local cmd = renderer:BeginRenderPass(RGBA(0.2, 0.2, 0.2, 1.0))
		pipeline:UpdateUniformBuffer(1, RGBA(hsv_to_rgb((os.clock() % 10) / 10, 1.0, 1.0)))
		pipeline:Bind(cmd)
		local extent = renderer:GetExtent()
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		pipeline:BindVertexBuffers(cmd, VERTEX_BIND_POSITION)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(1)
end
