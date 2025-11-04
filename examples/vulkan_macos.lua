local ffi = require("ffi")
local vulkan = require("vulkan")
local cocoa = require("cocoa")
local threads = require("threads")
local wnd = cocoa.window()
local vk = vulkan.vk
local lib = vulkan.lib

local instance = vulkan.CreateInstance({"VK_KHR_surface", "VK_EXT_metal_surface"})
local surface = vulkan.CreateMetalSurface(instance, assert(wnd:GetMetalLayer()))
local physicalDevice = vulkan.GetPhysicalDevices(instance)[0]
local graphicsQueueFamily = vulkan.FindGraphicsQueueFamily(physicalDevice, surface)
local device = vulkan.CreateDevice(physicalDevice, {"VK_KHR_swapchain"}, graphicsQueueFamily)
local surfaceFormat = vulkan.GetSurfaceFormats(physicalDevice, surface)[0]
local surfaceCapabilities = vulkan.GetSurfaceCapabilities(physicalDevice, surface)
local swapchain = vulkan.CreateSwapchain(device, surface, surfaceFormat, surfaceCapabilities)
local swapchainImages = vulkan.GetSwapchainImages(device, swapchain)
local commandPool = vulkan.CreateCommandPool(device, graphicsQueueFamily)
local commandBuffer = vulkan.CreateCommandBuffer(device, commandPool)
local imageAvailableSemaphore = vulkan.CreateSemaphore(device)
local renderFinishedSemaphore = vulkan.CreateSemaphore(device)
local inFlightFence = vulkan.CreateFence(device)
local deviceQueue = vulkan.GetDeviceQueue(device, graphicsQueueFamily)
wnd:Initialize()
wnd:OpenWindow()
local frame = 0

while not wnd:ShouldQuit() do
	local events = wnd:ReadEvents()
	vulkan.WaitForFences(device, inFlightFence)
	local imageIndex = vulkan.GetNextImage(device, swapchain, imageAvailableSemaphore)
	vulkan.BeginCommandBuffer(commandBuffer)
	local barrier = vulkan.ImageStartBarrier(commandBuffer, imageIndex, swapchainImages)

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
			commandBuffer[0],
			swapchainImages[imageIndex[0]],
			"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
			vk.Box(vk.VkClearColorValue, {
				float32 = {(frame % 360) / 360.0, 0.5, 0.8, 1.0},
			}),
			1,
			range
		)
	end

	vulkan.ImageEndBarrier(commandBuffer, barrier)
	vulkan.EndCommandBufferAndSubmit(
		commandBuffer,
		deviceQueue,
		imageAvailableSemaphore,
		renderFinishedSemaphore,
		inFlightFence
	)
	vulkan.Present(renderFinishedSemaphore, deviceQueue, swapchain, imageIndex)
	frame = frame + 1
	threads.sleep(16)
end

-- Cleanup
lib.vkDeviceWaitIdle(device[0])
lib.vkDestroyFence(device[0], inFlightFence[0], nil)
lib.vkDestroySemaphore(device[0], renderFinishedSemaphore[0], nil)
lib.vkDestroySemaphore(device[0], imageAvailableSemaphore[0], nil)
lib.vkDestroyCommandPool(device[0], commandPool[0], nil)
lib.vkDestroySwapchainKHR(device[0], swapchain[0], nil)
lib.vkDestroyDevice(device[0], nil)
