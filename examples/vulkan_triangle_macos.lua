local ffi = require("ffi")
local vulkan = require("helpers.vulkan")
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
local vertexBuffer
local descriptorSetLayout
local descriptorPool
local descriptorSet
local pipelineLayout

-- Create vertex buffer with position and color data
do
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
	-- Copy vertex data to buffer
	vertexBuffer:CopyData(vertices, bufferSize)
end

-- Create uniform buffer for color multiplier
local uniformBuffers = {}

do
	local bufferSize = ffi.sizeof("float") * 4 -- vec4
	uniformBuffers[1] = renderer.device:CreateBuffer(
		bufferSize,
		vk.VkBufferUsageFlagBits("VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT"),
		bit.bor(
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT"),
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_COHERENT_BIT")
		)
	)
	-- Initialize uniform buffer with white color multiplier
	local colorData = ffi.new("float[4]", {1.0, 1.0, 1.0, 1.0})
	uniformBuffers[1]:CopyData(colorData, bufferSize)
end

do
	local bufferSize = ffi.sizeof("float") * 4 -- vec4
	uniformBuffers[2] = renderer.device:CreateBuffer(
		bufferSize,
		vk.VkBufferUsageFlagBits("VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT"),
		bit.bor(
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT"),
			vk.VkMemoryPropertyFlagBits("VK_MEMORY_PROPERTY_HOST_COHERENT_BIT")
		)
	)
	-- Initialize uniform buffer with white color multiplier
	local colorData = ffi.new("float[4]", {23.0, 1.0, 1.0, 1.0})
	uniformBuffers[2]:CopyData(colorData, bufferSize)
end

do
	local renderPass = renderer:CreateRenderPass()
	renderer:CreateImageViews()
	renderer:CreateFramebuffers()
	-- Create descriptor set layout for uniform buffer
	descriptorSetLayout = renderer.device:CreateDescriptorSetLayout(
		{
			{
				binding = 0,
				type = "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER",
				stageFlags = vk.VkShaderStageFlagBits("VK_SHADER_STAGE_FRAGMENT_BIT"),
				count = 1,
			},
			{
				binding = 1,
				type = "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER",
				stageFlags = vk.VkShaderStageFlagBits("VK_SHADER_STAGE_FRAGMENT_BIT"),
				count = 1,
			},
		}
	)
	-- Create pipeline layout with descriptor set layout
	pipelineLayout = renderer.device:CreatePipelineLayout({descriptorSetLayout})
	-- Create descriptor pool
	descriptorPool = renderer.device:CreateDescriptorPool({{type = "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER", count = #uniformBuffers}}, 1)
	-- Allocate descriptor set
	descriptorSet = descriptorPool:AllocateDescriptorSet(descriptorSetLayout)
	-- Update descriptor set to point to uniform buffer
	renderer.device:UpdateDescriptorSet(descriptorSet, 0, uniformBuffers[1])
	renderer.device:UpdateDescriptorSet(descriptorSet, 1, uniformBuffers[2])
	local vertShaderSource = renderer.device:CreateShaderModule(
		[[
		#version 450

		layout(location = 0) in vec2 inPosition;
		layout(location = 1) in vec3 inColor;

		layout(location = 0) out vec3 fragColor;

		void main() {
			gl_Position = vec4(inPosition, 0.0, 1.0);
			fragColor = inColor;
		}
	]],
		"vertex"
	)
	local fragShaderSource = renderer.device:CreateShaderModule(
		[[
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
		"fragment"
	)

	function renderer:OnRecreateSwapchain()
		pipeline = renderer.device:CreateGraphicsPipeline(
			{
				vertShaderModule = vertShaderSource,
				fragShaderModule = fragShaderSource,
				pipelineLayout = pipelineLayout,
				renderPass = renderPass,
				extent = renderer:GetExtent(),
				vertexBindings = {
					{
						binding = 0,
						stride = ffi.sizeof("float") * 5, -- vec2 + vec3
						inputRate = "VK_VERTEX_INPUT_RATE_VERTEX",
					},
				},
				vertexAttributes = {
					{
						location = 0,
						binding = 0,
						format = "VK_FORMAT_R32G32_SFLOAT", -- vec2
						offset = 0,
					},
					{
						location = 1,
						binding = 0,
						format = "VK_FORMAT_R32G32B32_SFLOAT", -- vec3
						offset = ffi.sizeof("float") * 2,
					},
				},
			}
		)
	end

	renderer:OnRecreateSwapchain()
end

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
		cmd:BindPipeline(pipeline)
		cmd:BindVertexBuffers(0, {vertexBuffer})
		cmd:BindDescriptorSets(pipelineLayout, {descriptorSet}, 0)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(1)
end

renderer:WaitForIdle()
