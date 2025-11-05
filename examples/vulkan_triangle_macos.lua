local ffi = require("ffi")
local vulkan = require("helpers.vulkan")
local vk = vulkan.vk
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
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
local pipeline

function renderer:OnRecreateSwapchain()
	-- Vertex data: position (vec2) + color (vec3) = 5 floats per vertex, 3 vertices
	local vertices = ffi.new(
		"float[15]",
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
	local bufferSize = ffi.sizeof(vertices)
	vertexBuffer = renderer.device:CreateBuffer(
		bufferSize,
		vk.VkBufferUsageFlagBits("VK_BUFFER_USAGE_VERTEX_BUFFER_BIT"),
		bit.bor(
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT"),
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_COHERENT_BIT")
		)
	)
	vertexBuffer:CopyData(vertices, bufferSize)
	pipeline = renderer:CreatePipeline(
		{
			input_assembly = {
				topology = "triangle_list",
				primitive_restart = 0,
			},
			viewport = {
				x = 0.0,
				y = 0.0,
				w = tonumber(renderer:GetExtent().width),
				h = tonumber(renderer:GetExtent().height),
				min_depth = 0.0,
				max_depth = 1.0,
			},
			scissor = {
				x = 0,
				y = 0,
				w = tonumber(renderer:GetExtent().width),
				h = tonumber(renderer:GetExtent().height),
			},
			rasterizer = {
				depth_clamp = 0,
				discard = 0,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "back",
				front_face = "clockwise",
				depth_bias = 0,
			},
			multisampling = {
				sample_shading = 0,
				rasterization_samples = "1",
			},
			color_blend = {
				logic_op_enabled = 0,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = 0,
						color_write_mask = {"r","g","b","a"}
					}
				}
			},
			extent = renderer:GetExtent(),
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

while true do
	local events = wnd:ReadEvents()

	if events.window_close_requested then
		print("close")

		break
	end

	if events.window_resized then renderer:RecreateSwapchain() end

	if renderer:BeginFrame() then
		local cmd = renderer:BeginRenderPass({0.0, 0.0, 0.0, 1.0})
		pipeline:Bind(cmd)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(1)
end

renderer:WaitForIdle()
