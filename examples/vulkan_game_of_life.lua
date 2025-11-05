local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local vulkan = require("helpers.vulkan")

-- Create window
local wnd = cocoa.window()

-- Initialize renderer
local renderer = Renderer.New({
	surface_handle = assert(wnd:GetMetalLayer()),
	present_mode = "fifo",
	image_count = nil,
	surface_format_index = 1,
	composite_alpha = "opaque",
})

-- Game of Life configuration
local WORKGROUP_SIZE = 16
local GAME_WIDTH, GAME_HEIGHT -- Will be set based on window size

-- Compute shader for Game of Life simulation
local COMPUTE_SHADER = [[
#version 450

layout (local_size_x = 16, local_size_y = 16) in;

layout (binding = 0, rgba8) uniform readonly image2D inputImage;
layout (binding = 1, rgba8) uniform writeonly image2D outputImage;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(inputImage);

	if (pos.x >= size.x || pos.y >= size.y) {
		return;
	}

	// Count alive neighbors (wrapping at edges)
	int count = 0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			if (dx == 0 && dy == 0) continue;

			ivec2 neighbor = ivec2(
				(pos.x + dx + size.x) % size.x,
				(pos.y + dy + size.y) % size.y
			);

			vec4 cell = imageLoad(inputImage, neighbor);
			if (cell.r > 0.5) {
				count++;
			}
		}
	}

	// Current cell state
	vec4 current = imageLoad(inputImage, pos);
	bool alive = current.r > 0.5;

	// Conway's Game of Life rules
	bool newState = false;
	if (alive) {
		newState = (count == 2 || count == 3);
	} else {
		newState = (count == 3);
	}

	// Write result
	vec4 color = newState ? vec4(1.0, 1.0, 1.0, 1.0) : vec4(0.0, 0.0, 0.0, 1.0);
	imageStore(outputImage, pos, color);
}
]]

-- Fullscreen vertex shader
local VERTEX_SHADER = [[
#version 450

layout(location = 0) out vec2 fragTexCoord;

vec2 positions[6] = vec2[](
	vec2(-1.0, -1.0),
	vec2( 1.0, -1.0),
	vec2( 1.0,  1.0),
	vec2(-1.0, -1.0),
	vec2( 1.0,  1.0),
	vec2(-1.0,  1.0)
);

vec2 texCoords[6] = vec2[](
	vec2(0.0, 0.0),
	vec2(1.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 1.0)
);

void main() {
	gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
	fragTexCoord = texCoords[gl_VertexIndex];
}
]]

-- Fragment shader with post-processing effects
local FRAGMENT_SHADER = [[
#version 450

layout(binding = 0, rgba8) uniform readonly image2D gameImage;
layout(binding = 1) uniform UniformBuffer {
	float time;
	float colorShift;
	float brightness;
	float contrast;
} ubo;

layout(location = 0) in vec2 fragTexCoord;
layout(location = 0) out vec4 outColor;

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
	ivec2 size = imageSize(gameImage);
	ivec2 texCoord = ivec2(fragTexCoord * vec2(size));

	vec4 cell = imageLoad(gameImage, texCoord);

	// Base color
	vec3 color = cell.rgb;

	// Add color based on alive cells with hue shift over time
	if (cell.r > 0.5) {
		float hue = fract(ubo.colorShift + fragTexCoord.x * 0.1 + fragTexCoord.y * 0.1);
		vec3 hsvColor = hsv2rgb(vec3(hue, 0.8, 1.0));
		color = hsvColor;
	}

	// Apply brightness and contrast
	color = (color - 0.5) * ubo.contrast + 0.5 + ubo.brightness;

	// Vignette effect
	vec2 uv = fragTexCoord * 2.0 - 1.0;
	float vignette = 1.0 - dot(uv, uv) * 0.2;
	color *= vignette;

	outColor = vec4(color, 1.0);
}
]]

-- Storage for compute resources
local compute_shader
local compute_pipeline
local compute_pipeline_layout
local compute_descriptor_set_layout
local compute_descriptor_pool
local compute_descriptor_sets = {}

-- Storage images for ping-pong
local storage_images = {}
local storage_image_views = {}

-- Graphics pipeline resources
local graphics_pipeline
local graphics_uniform_buffer
local current_image_index = 1

-- Random initialization helper
local function initialize_random_state(device, image, width, height)
	-- Create staging buffer with random data
	local pixel_count = width * height
	local data = ffi.new("uint8_t[?]", pixel_count * 4)

	math.randomseed(os.time())
	for i = 0, pixel_count - 1 do
		local alive = math.random() < 0.3
		local value = alive and 255 or 0
		data[i * 4 + 0] = value
		data[i * 4 + 1] = value
		data[i * 4 + 2] = value
		data[i * 4 + 3] = 255
	end

	-- Create staging buffer
	local staging_buffer = device:CreateBuffer(
		pixel_count * 4,
		"transfer_src",
		{"host_visible", "host_coherent"}
	)
	staging_buffer:CopyData(data, pixel_count * 4)

	-- Copy to image using command buffer
	local cmd_pool = device:CreateCommandPool(renderer.graphics_queue_family)
	local cmd = cmd_pool:CreateCommandBuffer()

	cmd:Begin()

	-- Transition image to transfer dst
	cmd:PipelineBarrier({
		srcStage = "compute",
		dstStage = "transfer",
		imageBarriers = {{
			image = image.ptr[0],
			srcAccessMask = 0,
			dstAccessMask = vulkan.enums.VK_ACCESS_("transfer_write"),
			oldLayout = "undefined",
			newLayout = "transfer_dst_optimal",
		}},
	})

	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, image, width, height)

	-- Transition to general layout for compute
	cmd:PipelineBarrier({
		srcStage = "transfer",
		dstStage = "compute",
		imageBarriers = {{
			image = image.ptr[0],
			srcAccessMask = vulkan.enums.VK_ACCESS_("transfer_write"),
			dstAccessMask = vulkan.enums.VK_ACCESS_("shader_read"),
			oldLayout = "transfer_dst_optimal",
			newLayout = "general",
		}},
	})

	cmd:End()

	-- Submit and wait
	local fence = device:CreateFence()
	renderer.queue:SubmitAndWait(device, cmd, fence)
end

function renderer:OnRecreateSwapchain()
	local is_first_call = storage_images == nil or #storage_images == 0

	-- Set simulation size based on window dimensions
	local extent = self:GetExtent()
	GAME_WIDTH = tonumber(extent.width)
	GAME_HEIGHT = tonumber(extent.height)

	-- Create storage images for compute shader (ping-pong buffers)
	storage_images = {}
	storage_image_views = {}

	for i = 1, 2 do
		storage_images[i] = self.device:CreateImage(
			GAME_WIDTH,
			GAME_HEIGHT,
			"R8G8B8A8_UNORM",
			{"storage", "transfer_dst", "transfer_src"},
			"device_local"
		)
		storage_image_views[i] = storage_images[i]:CreateView()
	end

	-- Initialize both images with random state (always, even on resize)
	-- This ensures the simulation always has data after resize
	initialize_random_state(self.device, storage_images[1], GAME_WIDTH, GAME_HEIGHT)
	initialize_random_state(self.device, storage_images[2], GAME_WIDTH, GAME_HEIGHT)

	-- Create compute shader and pipeline (only on first call)
	if is_first_call then
		compute_shader = self.device:CreateShaderModule(COMPUTE_SHADER, "compute")

		-- Descriptor set layout for compute (2 storage images)
		compute_descriptor_set_layout = self.device:CreateDescriptorSetLayout({
			{binding = 0, type = "storage_image", stageFlags = "compute", count = 1},
			{binding = 1, type = "storage_image", stageFlags = "compute", count = 1},
		})

		compute_pipeline_layout = self.device:CreatePipelineLayout({compute_descriptor_set_layout})
		compute_pipeline = self.device:CreateComputePipeline(compute_shader, compute_pipeline_layout)

		-- Create descriptor pool for compute (2 sets, each with 2 storage images)
		compute_descriptor_pool = self.device:CreateDescriptorPool({
			{type = "storage_image", count = 4},
		}, 2)

		-- Create descriptor sets for ping-pong
		compute_descriptor_sets = {}
		for i = 1, 2 do
			local desc_set = compute_descriptor_pool:AllocateDescriptorSet(compute_descriptor_set_layout)
			compute_descriptor_sets[i] = desc_set
		end
	end

	-- Update descriptor sets with new storage image views
	for i = 1, 2 do
		local input_idx = i
		local output_idx = (i % 2) + 1

		self.device:UpdateDescriptorSet(compute_descriptor_sets[i], 0, storage_image_views[input_idx], "storage_image")
		self.device:UpdateDescriptorSet(compute_descriptor_sets[i], 1, storage_image_views[output_idx], "storage_image")
	end

	-- Create uniform buffer for graphics shader (only on first call)
	if is_first_call then
		local UniformData = ffi.typeof("struct { float time; float colorShift; float brightness; float contrast; }")
		graphics_uniform_buffer = self:CreateBuffer({
			byte_size = ffi.sizeof(UniformData),
			buffer_usage = "uniform_buffer",
			data = ffi.new(UniformData, {0.0, 0.0, 0.0, 1.0}),
		})
	end

	-- Create or recreate graphics pipeline
	local extent = self:GetExtent()
	local w = tonumber(extent.width)
	local h = tonumber(extent.height)

	-- Recreate pipeline to update viewport/scissor
	graphics_pipeline = self:CreatePipeline({
		viewport = {x = 0.0, y = 0.0, w = w, h = h, min_depth = 0.0, max_depth = 1.0},
		scissor = {x = 0, y = 0, w = w, h = h},
		input_assembly = {topology = "triangle_list", primitive_restart = false},
		vertex_bindings = {},
		vertex_attributes = {},
		vertex_buffers = {},
		uniform_buffers = {},
		storage_images = {
			{stage = "fragment", image_view = storage_image_views[1]},
		},
		uniform_buffers_graphics = {
			{stage = "fragment", buffer = graphics_uniform_buffer},
		},
		shader_stages = {
			{type = "vertex", code = VERTEX_SHADER},
			{type = "fragment", code = FRAGMENT_SHADER},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "none",
			front_face = "counter_clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {{blend = false, color_write_mask = {"r", "g", "b", "a"}}},
		},
		multisampling = {sample_shading = false, rasterization_samples = "1"},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	})
end

-- Initialize
renderer:OnRecreateSwapchain()
wnd:Initialize()
wnd:OpenWindow()

-- Simulation state
local generation = 0
local paused = false
local time = 0.0

print("Game of Life - Vulkan Compute Shader")
print("Controls:")
print("  Space: Pause/Resume")
print("  R: Reset with random state")
print("  ESC: Exit")

-- Main loop
while true do
	local events = wnd:ReadEvents()

	if events.window_close_requested then
		break
	end

	if events.window_resized then
		renderer:RecreateSwapchain()
	end

	-- Handle keyboard input
	if events.key_pressed then
		if events.key == "escape" then
			break
		elseif events.key == " " then
			paused = not paused
			print(paused and "Paused" or "Resumed")
		elseif events.key == "r" or events.key == "R" then
			initialize_random_state(renderer.device, storage_images[1], GAME_WIDTH, GAME_HEIGHT)
			generation = 0
			print("Reset to random state")
		end
	end

	if renderer:BeginFrame() then
		local cmd = renderer:GetCommandBuffer()

		-- Run compute shader (only if not paused)
		if not paused then
			-- Bind compute pipeline
			cmd:BindComputePipeline(compute_pipeline)
			cmd:BindComputeDescriptorSets(
				compute_pipeline_layout,
				{compute_descriptor_sets[current_image_index]},
				0
			)

			-- Dispatch compute shader
			local group_count_x = math.ceil(GAME_WIDTH / WORKGROUP_SIZE)
			local group_count_y = math.ceil(GAME_HEIGHT / WORKGROUP_SIZE)
			cmd:Dispatch(group_count_x, group_count_y, 1)

			-- Barrier: compute write -> fragment read
			cmd:PipelineBarrier({
				srcStage = "compute",
				dstStage = "fragment",
				imageBarriers = {{
					image = storage_images[(current_image_index % 2) + 1].ptr[0],
					srcAccessMask = vulkan.enums.VK_ACCESS_("shader_write"),
					dstAccessMask = vulkan.enums.VK_ACCESS_("shader_read"),
					oldLayout = "general",
					newLayout = "general",
				}},
			})

			-- Swap images for next frame
			current_image_index = (current_image_index % 2) + 1
			generation = generation + 1
		end

		-- Update uniform buffer
		time = time + 0.016
		local UniformData = ffi.typeof("struct { float time; float colorShift; float brightness; float contrast; }")
		local ubo = ffi.new(UniformData, {
			time,
			(time * 0.1) % 1.0,
			0.0,
			1.2,
		})
		graphics_uniform_buffer:CopyData(ubo, ffi.sizeof(UniformData))

		-- Render fullscreen quad
		cmd = renderer:BeginRenderPass(ffi.new("float[4]", {0.0, 0.0, 0.0, 1.0}))
		graphics_pipeline:Bind(cmd)
		cmd:Draw(6, 1, 0, 0)
		cmd:EndRenderPass()

		renderer:EndFrame()
	end

	threads.sleep(16)
end

print(string.format("Simulation ended at generation %d", generation))
renderer:WaitForIdle()
