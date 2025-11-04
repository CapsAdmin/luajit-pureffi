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
local renderPass = renderer:CreateRenderPass()
renderer:CreateImageViews()
renderer:CreateFramebuffers()
local pipelineLayout = renderer.device:CreatePipelineLayout()
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
	return renderer.device:CreateGraphicsPipeline(
		{
			vertShaderModule = renderer.device:CreateShaderModule(vertShaderSource, "vertex"),
			fragShaderModule = renderer.device:CreateShaderModule(fragShaderSource, "fragment"),
			pipelineLayout = pipelineLayout,
			renderPass = renderPass,
			extent = extent,
		}
	)
end

local pipeline = createPipeline()

function renderer:OnRecreateSwapchain()
	pipeline = createPipeline()
end

print("Graphics pipeline created successfully")
wnd:Initialize()
wnd:OpenWindow()

while true do
	local events = wnd:ReadEvents()

	if events.window_close_requested then
		print("Window close requested")

		break
	end

	if events.window_resized then renderer:RecreateSwapchain() end

	if renderer:BeginFrame() then
		local extent = renderer:GetExtent()
		local cmd = renderer:GetCommandBuffer()
		cmd:BeginRenderPass(renderer.render_pass, renderer:GetFramebuffer(), extent, {0.0, 0.0, 0.0, 1.0})
		cmd:BindPipeline(pipeline)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRenderPass()
		renderer:EndFrame()
	end

	threads.sleep(1)
end

renderer:WaitForIdle()
