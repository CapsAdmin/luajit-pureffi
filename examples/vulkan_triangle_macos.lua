local ffi = require("ffi")
local vulkan = require("helpers.vulkan")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
local wnd = cocoa.window()
local vk = vulkan.vk
local lib = vulkan.lib

-- Initialize renderer
local renderer = Renderer.New({
	surface_handle = assert(wnd:GetMetalLayer()),
	present_mode = "VK_PRESENT_MODE_FIFO_KHR",
	image_count = nil, -- Use default (minImageCount + 1)
	surface_format_index = 1,
	composite_alpha = "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR",
})

renderer:PrintCapabilities()

local renderPass = renderer:CreateRenderPass()

renderer:CreateImageViews()
renderer:CreateFramebuffers()

local pipelineLayout = renderer.device:CreatePipelineLayout()

-- Shader source code (stored for pipeline recreation)
local vertShaderSource = [[
    #version 450

    vec2 positions[3] = vec2[](
        vec2(0.0, -0.5),
        vec2(0.5, 0.5),
        vec2(-0.5, 0.5)
    );

    vec3 colors[3] = vec3[](
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, 1.0, 0.0),
        vec3(0.0, 0.0, 1.0)
    );

    layout(location = 0) out vec3 fragColor;

    void main() {
        gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
        fragColor = colors[gl_VertexIndex];
    }
]]

local fragShaderSource = [[
    #version 450

    layout(location = 0) in vec3 fragColor;
    layout(location = 0) out vec4 outColor;

    void main() {
        outColor = vec4(fragColor, 1.0);
    }
]]

local function createPipeline()
	local extent = renderer:GetExtent()
	return renderer.device:CreateGraphicsPipeline({
		vertShaderModule = renderer.device:CreateShaderModule(vertShaderSource, "vertex"),
		fragShaderModule = renderer.device:CreateShaderModule(fragShaderSource, "fragment"),
		pipelineLayout = pipelineLayout,
		renderPass = renderPass,
		extent = extent,
	})
end

local pipeline = createPipeline()

print("Graphics pipeline created successfully")

-- Open window
wnd:Initialize()
wnd:OpenWindow()

local frame = 0

-- Main render loop
while true do
	local events = wnd:ReadEvents()

	-- Handle window close
	if events.window_close_requested then
		print("Window close requested")
		break
	end

	-- Handle window resize
	if events.window_resized then
		print("Window resized, recreating swapchain and pipeline...")
		renderer:RecreateSwapchain()

		-- Create new pipeline with updated extent
		pipeline = createPipeline()
	end

	local commandBuffer, imageIndex, swapchainImages, status = renderer:BeginFrame(true)

	-- Recreate pipeline if swapchain was recreated
	if status == "out_of_date" then
		pipeline = createPipeline()
		goto continue
	end

	-- Get current extent for render pass
	local extent = renderer:GetExtent()

	-- Begin render pass with clear color
	commandBuffer:BeginRenderPass(
		renderPass,
		renderer.framebuffers[imageIndex[0] + 1],
		extent,
		{0.0, 0.0, 0.0, 1.0}
	)

	-- Bind pipeline and draw triangle
	commandBuffer:BindPipeline(pipeline)
	commandBuffer:Draw(3, 1, 0, 0)

	-- End render pass
	commandBuffer:EndRenderPass()

	local present_status = renderer:EndFrame(true)

	-- Recreate pipeline if swapchain was recreated
	if present_status == "out_of_date" or present_status == "suboptimal" then
		pipeline = createPipeline()
	end

	frame = frame + 1
	threads.sleep(1)
	::continue::
end

-- Cleanup
renderer:cleanup()
print("Cleaned up successfully")
