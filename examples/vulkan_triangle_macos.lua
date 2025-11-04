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

local extent = renderer:GetExtent()
local pipeline = renderer.device:CreateGraphicsPipeline({
	vertShaderModule = renderer.device:CreateShaderModule([[
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
    ]], "vertex"),
	fragShaderModule = renderer.device:CreateShaderModule([[
        #version 450

        layout(location = 0) in vec3 fragColor;
        layout(location = 0) out vec4 outColor;

        void main() {
            outColor = vec4(fragColor, 1.0);
        }
    ]], "fragment"),
	pipelineLayout = pipelineLayout,
	renderPass = renderPass,
	extent = extent,
})

print("Graphics pipeline created successfully")

-- Open window
wnd:Initialize()
wnd:OpenWindow()

local frame = 0

-- Main render loop
while not wnd:ShouldQuit() do
	local events = wnd:ReadEvents()
	local commandBuffer, imageIndex, swapchainImages = renderer:BeginFrame(true)

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

	renderer:EndFrame(true)
	frame = frame + 1
	threads.sleep(1)
end

-- Cleanup
renderer:cleanup()
print("Cleaned up successfully")
