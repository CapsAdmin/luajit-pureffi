local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
-- Create window
local wnd = cocoa.window()
-- Initialize renderer
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "fifo",
		image_count = nil,
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
-- Game of Life configuration
local WORKGROUP_SIZE = 16
local GAME_WIDTH, GAME_HEIGHT -- Will be set based on window size
local UniformData = ffi.typeof("struct { float time; float colorShift; float brightness; float contrast; }")
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

-- Random initialization helper
local function initialize_random_state()
	-- Create staging buffer with random data
	local extent = renderer:GetExtent()
	local w = tonumber(extent.width)
	local h = tonumber(extent.height)
	local pixel_count = w * h
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

	return data, pixel_count, w, h
end

do
	local ComputePipeline = {}
	ComputePipeline.__index = ComputePipeline

	function Renderer:CreateComputePipeline(config)
		local shader = self.device:CreateShaderModule(config.shader, "compute")
		-- Descriptor set layout for compute (2 storage images)
		local descriptor_set_layout = self.device:CreateDescriptorSetLayout(config.descriptor_layout)
		local pipeline_layout = self.device:CreatePipelineLayout({descriptor_set_layout})
		local pipeline = self.device:CreateComputePipeline(shader, pipeline_layout)
		-- Create descriptor pool for compute (2 sets, each with 2 storage images)
		local descriptor_pool = self.device:CreateDescriptorPool(config.descriptor_pool, #config.descriptor_layout)
		-- Create descriptor sets for ping-pong
		local descriptor_sets = {}

		for i = 1, #config.descriptor_layout do
			descriptor_sets[i] = descriptor_pool:AllocateDescriptorSet(descriptor_set_layout)
		end

		return setmetatable(
			{
				shader = shader,
				pipeline = pipeline,
				pipeline_layout = pipeline_layout,
				descriptor_set_layout = descriptor_set_layout,
				descriptor_pool = descriptor_pool,
				descriptor_sets = descriptor_sets,
				current_image_index = 1,
				config = config,
			},
			ComputePipeline
		)
	end

	function ComputePipeline:Update(data, pixel_count, w, h)
		-- Create storage images for compute shader (ping-pong buffers)
		self.storage_images = {}
		self.storage_image_views = {}

		for i = 1, #self.config.descriptor_layout do
			local image = renderer.device:CreateImage(
				w,
				h,
				"R8G8B8A8_UNORM",
				{"storage", "transfer_dst", "transfer_src"},
				"device_local"
			)
			renderer:UploadToImage(image, data, pixel_count, w, h)
			self.storage_images[i] = image
			self.storage_image_views[i] = image:CreateView()
		end

		-- Update descriptor sets with new storage image views
		for i = 1, #self.config.descriptor_layout do
			local input_idx = i
			local output_idx = (i % 2) + 1
			renderer.device:UpdateDescriptorSet(self.descriptor_sets[i], 0, self.storage_image_views[input_idx], "storage_image")
			renderer.device:UpdateDescriptorSet(self.descriptor_sets[i], 1, self.storage_image_views[output_idx], "storage_image")
		end
	end

	function ComputePipeline:Bind(cmd)
		-- Bind compute pipeline
		cmd:BindPipeline(self.pipeline, "compute")
		cmd:BindDescriptorSets(
			"compute",
			self.pipeline_layout,
			{self.descriptor_sets[self.current_image_index]},
			0
		)
		local extent = renderer:GetExtent()
		local w = tonumber(extent.width)
		local h = tonumber(extent.height)
		-- Dispatch compute shader
		local group_count_x = math.ceil(w / WORKGROUP_SIZE)
		local group_count_y = math.ceil(h / WORKGROUP_SIZE)
		cmd:Dispatch(group_count_x, group_count_y, 1)
		-- Barrier: compute write -> fragment read
		cmd:PipelineBarrier(
			{
				srcStage = "compute",
				dstStage = "fragment",
				imageBarriers = {
					{
						image = self.storage_images[(self.current_image_index % 2) + 1],
						srcAccessMask = "shader_write",
						dstAccessMask = "shader_read",
						oldLayout = "general",
						newLayout = "general",
					},
				},
			}
		)
		-- Swap images for next frame
		self.current_image_index = (self.current_image_index % 2) + 1
	end
end

local compute_pipeline = renderer:CreateComputePipeline(
	{
		shader = COMPUTE_SHADER,
		descriptor_layout = {
			{binding = 0, type = "storage_image", stageFlags = "compute", count = 1},
			{binding = 1, type = "storage_image", stageFlags = "compute", count = 1},
		},
		descriptor_pool = {
			{type = "storage_image", count = 4},
		},
	}
)
compute_pipeline:Update(initialize_random_state())

local graphics_pipeline = renderer:CreatePipeline(
	{
		dynamic_states = {"viewport", "scissor"},
		input_assembly = {topology = "triangle_list", primitive_restart = false},
		storage_images = {
			{stage = "fragment", image_view = compute_pipeline.storage_image_views[1]},
		},
		uniform_buffers = {
			{
				stage = "fragment",
				buffer = renderer:CreateBuffer(
					{
						byte_size = ffi.sizeof(UniformData),
						buffer_usage = "uniform_buffer",
						data = UniformData({0.0, 0.0, 0.0, 1.0}),
					}
				),
			},
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
	}
)


function renderer:OnRecreateSwapchain()
	compute_pipeline:Update(initialize_random_state())
	graphics_pipeline:UpdateDescriptorSet(1, 0 , "storage_image", compute_pipeline.storage_image_views[1])
end

wnd:Initialize()
wnd:OpenWindow()
-- Simulation state
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

	if events.window_close_requested then break end

	if events.window_resized then renderer:RecreateSwapchain() end

	-- Handle keyboard input
	if events.key_pressed then
		if events.key == "escape" then
			break
		elseif events.key == " " then
			paused = not paused
			print(paused and "Paused" or "Resumed")
		elseif events.key == "r" or events.key == "R" then
			initialize_random_state(renderer.device, storage_images[1], GAME_WIDTH, GAME_HEIGHT)
			print("Reset to random state")
		end
	end

	if renderer:BeginFrame() then
		local cmd = renderer:GetCommandBuffer()

		-- Run compute shader (only if not paused)
		if not paused then compute_pipeline:Bind(cmd) end

		-- Update uniform buffer
		time = time + 0.016
		graphics_pipeline:UpdateUniformBuffer(1, UniformData({
			time,
			(
				time * 0.1
			) % 1.0,
			0.0,
			1.2,
		}))
		-- Render fullscreen quad
		cmd = renderer:BeginRenderPass(ffi.new("float[4]", {0.0, 0.0, 0.0, 1.0}))
		graphics_pipeline:Bind(cmd)
		local extent = renderer:GetExtent()
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		cmd:Draw(6, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(16)
end

renderer:WaitForIdle()
