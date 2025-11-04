local ffi = require("ffi")
local vulkan = require("vulkan")
local cocoa = require("cocoa")
local threads = require("threads")
local wnd = cocoa.window()
local vk = vulkan.vk
local lib = vulkan.lib
local instance = vulkan.CreateInstance({"VK_KHR_surface", "VK_EXT_metal_surface"})
local surface = instance:CreateMetalSurface(assert(wnd:GetMetalLayer()))
local physicalDevice = instance:GetPhysicalDevices()[1]
local graphicsQueueFamily = physicalDevice:FindGraphicsQueueFamily(surface)
local device = physicalDevice:CreateDevice({"VK_KHR_swapchain"}, graphicsQueueFamily)
local surfaceFormat = physicalDevice:GetSurfaceFormats(surface)[0]
local surfaceCapabilities = physicalDevice:GetSurfaceCapabilities(surface)
local swapchain = device:CreateSwapchain(surface, surfaceFormat, surfaceCapabilities)
local swapchainImages = swapchain:GetImages()
local commandPool = device:CreateCommandPool(graphicsQueueFamily)
local commandBuffer = commandPool:CreateCommandBuffer()
local imageAvailableSemaphore = device:CreateSemaphore()
local renderFinishedSemaphore = device:CreateSemaphore()
local inFlightFence = device:CreateFence()
local deviceQueue = device:GetQueue(graphicsQueueFamily)
wnd:Initialize()
wnd:OpenWindow()
local frame = 0

while not wnd:ShouldQuit() do
	local events = wnd:ReadEvents()
	inFlightFence:Wait()
	local imageIndex = swapchain:GetNextImage(imageAvailableSemaphore)
	commandBuffer:Reset()
	commandBuffer:Begin()
	local barrier = commandBuffer:CreateImageMemoryBarrier(imageIndex, swapchainImages)
	commandBuffer:StartPipelineBarrier(barrier)

	do
		local range = vk.Box(
			vk.VkImageSubresourceRange,
			{
				aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			}
		)
		lib.vkCmdClearColorImage(
			commandBuffer.ptr[0],
			swapchainImages[imageIndex[0]],
			"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
			vk.Box(vk.VkClearColorValue, {
				float32 = {(frame % 360) / 360.0, 0.5, 0.8, 1.0},
			}),
			1,
			range
		)
	end

	commandBuffer:EndPipelineBarrier(barrier)
	commandBuffer:End()
	deviceQueue:Submit(
		commandBuffer,
		imageAvailableSemaphore,
		renderFinishedSemaphore,
		inFlightFence
	)
	swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
	frame = frame + 1
	threads.sleep(16)
end

-- Cleanup
lib.vkDeviceWaitIdle(device.ptr[0])
