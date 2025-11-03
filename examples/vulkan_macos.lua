local ffi = require("ffi")
local vk = require("vulkan")
local lib = vk.find_library()
local cocoa = require("cocoa")
local threads = require("threads")
local wnd = cocoa.window()

local function vk_assert(result, msg)
	if result ~= 0 then
		error((msg or "error") .. " : " .. vk.EnumToString(result), 2)
	end
end

print("Cocoa window created")
local appInfo = vk.Box(
	vk.VkApplicationInfo,
	{
		sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
		pApplicationName = "MoltenVK LuaJIT Example",
		applicationVersion = 1,
		pEngineName = "No Engine",
		engineVersion = 1,
		apiVersion = vk.VK_API_VERSION_1_0,
	}
)
local extension_names = vk.Array(ffi.typeof("const char*"), 2, {"VK_KHR_surface", "VK_EXT_metal_surface"})
local createInfo = vk.Box(
	vk.VkInstanceCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
		pNext = nil,
		flags = 0,
		pApplicationInfo = appInfo,
		enabledLayerCount = 0,
		ppEnabledLayerNames = nil,
		enabledExtensionCount = 2,
		ppEnabledExtensionNames = extension_names,
	}
)
local instance = vk.Box(vk.VkInstance)()
vk_assert(lib.vkCreateInstance(createInfo, nil, instance), "failed to create vulkan instance")
local surfaceCreateInfo = vk.VkMetalSurfaceCreateInfoEXT(
	{
		sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
		pNext = nil,
		flags = 0,
		pLayer = ffi.cast("const void*", assert(wnd:GetMetalLayer()), "failed to get metal layer"),
	}
)
local surface = vk.Box(vk.VkSurfaceKHR)()
local vkCreateMetalSurfaceEXT = vk.GetExtension(lib, instance[0], "vkCreateMetalSurfaceEXT")
vk_assert(
	vkCreateMetalSurfaceEXT(instance[0], surfaceCreateInfo, nil, surface),
	"failed to create metal surface"
)
local deviceCount = ffi.new("uint32_t[1]", 0)
vk_assert(
	lib.vkEnumeratePhysicalDevices(instance[0], deviceCount, nil),
	"failed to enumerate physical devices"
)

if deviceCount[0] == 0 then error("no physical devices found") end

-- Get physical devices
local physicalDevices = vk.Array(vk.VkPhysicalDevice)(deviceCount[0])
vk_assert(
	lib.vkEnumeratePhysicalDevices(instance[0], deviceCount, physicalDevices),
	"failed to enumerate physical devices"
)
local physicalDevice = physicalDevices[0]
-- Find queue family that supports graphics and present
local queueFamilyCount = ffi.new("uint32_t[1]", 0)
lib.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, queueFamilyCount, nil)
local queueFamilies = vk.Array(vk.VkQueueFamilyProperties)(queueFamilyCount[0])
lib.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, queueFamilyCount, queueFamilies)
print(string.format("Found %d queue families", queueFamilyCount[0]))
local graphicsQueueFamily = nil
local presentQueueFamily = nil

for i = 0, queueFamilyCount[0] - 1 do
	local queueFlags = queueFamilies[i].queueFlags
	print(
		string.format(
			"Queue family %d: flags = 0x%x, count = %d",
			i,
			queueFlags,
			queueFamilies[i].queueCount
		)
	)
	local graphicsBit = vk.VkQueueFlagBits("VK_QUEUE_GRAPHICS_BIT")

	if bit.band(queueFlags, graphicsBit) ~= 0 then
		print(string.format("  - Queue family %d supports graphics", i))

		if not graphicsQueueFamily then graphicsQueueFamily = i end
	end

	local presentSupport = ffi.new("uint32_t[1]", 0)
	lib.vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, i, surface[0], presentSupport)

	if presentSupport[0] ~= 0 then
		print(string.format("  - Queue family %d supports present", i))

		if not presentQueueFamily then presentQueueFamily = i end
	end

	-- If we found one that supports both, use it
	if bit.band(queueFlags, graphicsBit) ~= 0 and presentSupport[0] ~= 0 then
		graphicsQueueFamily = i
		presentQueueFamily = i
		print(string.format("  - Queue family %d supports both graphics and present!", i))

		break
	end
end

if not graphicsQueueFamily then error("no graphics queue family found") end

if not presentQueueFamily then error("no present queue family found") end

print(
	string.format(
		"Using queue family %d for graphics and %d for present",
		graphicsQueueFamily,
		presentQueueFamily
	)
)
-- Create logical device
local queuePriority = ffi.new("float[1]", 1.0)
local queueCreateInfo = vk.Box(
	vk.VkDeviceQueueCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO",
		queueFamilyIndex = graphicsQueueFamily,
		queueCount = 1,
		pQueuePriorities = queuePriority,
	}
)
local deviceExtensions = vk.Array(ffi.typeof("const char*"), 1, {"VK_KHR_swapchain"})
local deviceCreateInfo = vk.Box(
	vk.VkDeviceCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO",
		queueCreateInfoCount = 1,
		pQueueCreateInfos = queueCreateInfo,
		enabledExtensionCount = 1,
		ppEnabledExtensionNames = deviceExtensions,
	}
)
local device = vk.Box(vk.VkDevice)()
vk_assert(
	lib.vkCreateDevice(physicalDevice, deviceCreateInfo, nil, device),
	"failed to create device"
)
-- Get queue
local queue = vk.Box(vk.VkQueue)()
lib.vkGetDeviceQueue(device[0], graphicsQueueFamily, 0, queue)
-- Query surface capabilities
local surfaceCapabilities = vk.Box(vk.VkSurfaceCapabilitiesKHR)()
vk_assert(
	lib.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface[0], surfaceCapabilities),
	"failed to get surface capabilities"
)
-- Query surface formats
local formatCount = ffi.new("uint32_t[1]", 0)
lib.vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface[0], formatCount, nil)
local formats = vk.Array(vk.VkSurfaceFormatKHR)(formatCount[0])
lib.vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface[0], formatCount, formats)
local surfaceFormat = formats[0]
-- Create swapchain
local swapchainCreateInfo = vk.Box(
	vk.VkSwapchainCreateInfoKHR,
	{
		sType = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR",
		surface = surface[0],
		minImageCount = surfaceCapabilities[0].minImageCount,
		imageFormat = surfaceFormat.format,
		imageColorSpace = surfaceFormat.colorSpace,
		imageExtent = surfaceCapabilities[0].currentExtent,
		imageArrayLayers = 1,
		imageUsage = bit.bor(
			vk.VkImageUsageFlagBits("VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT"),
			vk.VkImageUsageFlagBits("VK_IMAGE_USAGE_TRANSFER_DST_BIT")
		),
		imageSharingMode = "VK_SHARING_MODE_EXCLUSIVE",
		preTransform = surfaceCapabilities[0].currentTransform,
		compositeAlpha = vk.VkCompositeAlphaFlagBitsKHR("VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR"),
		presentMode = "VK_PRESENT_MODE_FIFO_KHR",
		clipped = 1,
		oldSwapchain = nil,
	}
)
local swapchain = vk.Box(vk.VkSwapchainKHR)()
vk_assert(
	lib.vkCreateSwapchainKHR(device[0], swapchainCreateInfo, nil, swapchain),
	"failed to create swapchain"
)
-- Get swapchain images
local imageCount = ffi.new("uint32_t[1]", 0)
lib.vkGetSwapchainImagesKHR(device[0], swapchain[0], imageCount, nil)
local swapchainImages = vk.Array(vk.VkImage)(imageCount[0])
lib.vkGetSwapchainImagesKHR(device[0], swapchain[0], imageCount, swapchainImages)
-- Create command pool
local commandPoolCreateInfo = vk.Box(
	vk.VkCommandPoolCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO",
		queueFamilyIndex = graphicsQueueFamily,
		flags = vk.VkCommandPoolCreateFlagBits("VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT"),
	}
)
local commandPool = vk.Box(vk.VkCommandPool)()
vk_assert(
	lib.vkCreateCommandPool(device[0], commandPoolCreateInfo, nil, commandPool),
	"failed to create command pool"
)
-- Allocate command buffer
local commandBufferAllocInfo = vk.Box(
	vk.VkCommandBufferAllocateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO",
		commandPool = commandPool[0],
		level = "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
		commandBufferCount = 1,
	}
)
local commandBuffer = vk.Box(vk.VkCommandBuffer)()
vk_assert(
	lib.vkAllocateCommandBuffers(device[0], commandBufferAllocInfo, commandBuffer),
	"failed to allocate command buffer"
)
-- Create semaphores and fence
local semaphoreCreateInfo = vk.Box(vk.VkSemaphoreCreateInfo, {
	sType = "VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO",
})
local imageAvailableSemaphore = vk.Box(vk.VkSemaphore)()
local renderFinishedSemaphore = vk.Box(vk.VkSemaphore)()
vk_assert(
	lib.vkCreateSemaphore(device[0], semaphoreCreateInfo, nil, imageAvailableSemaphore),
	"failed to create semaphore"
)
vk_assert(
	lib.vkCreateSemaphore(device[0], semaphoreCreateInfo, nil, renderFinishedSemaphore),
	"failed to create semaphore"
)
local fenceCreateInfo = vk.Box(
	vk.VkFenceCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_FENCE_CREATE_INFO",
		flags = vk.VkFenceCreateFlagBits("VK_FENCE_CREATE_SIGNALED_BIT"),
	}
)
local inFlightFence = vk.Box(vk.VkFence)()
vk_assert(
	lib.vkCreateFence(device[0], fenceCreateInfo, nil, inFlightFence),
	"failed to create fence"
)
wnd:Initialize()
wnd:OpenWindow()
print("Starting render loop...")
-- Main event loop
local frame = 0

while not wnd:ShouldQuit() do
	local events = wnd:ReadEvents()
	-- Wait for previous frame
	lib.vkWaitForFences(device[0], 1, inFlightFence, 1, ffi.cast("uint64_t", -1))
	lib.vkResetFences(device[0], 1, inFlightFence)
	-- Acquire next image
	local imageIndex = ffi.new("uint32_t[1]", 0)
	local result = lib.vkAcquireNextImageKHR(
		device[0],
		swapchain[0],
		ffi.cast("uint64_t", -1),
		imageAvailableSemaphore[0],
		nil,
		imageIndex
	)

	if result ~= 0 then
		print(string.format("vkAcquireNextImageKHR failed: %s", vk.EnumToString(result)))
	end

	if result == 0 then
		if frame % 60 == 0 then
			print(string.format("Frame %d, imageIndex %d", frame, imageIndex[0]))
		end

		-- Record command buffer
		lib.vkResetCommandBuffer(commandBuffer[0], 0)
		local beginInfo = vk.Box(
			vk.VkCommandBufferBeginInfo,
			{
				sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO",
				flags = vk.VkCommandBufferUsageFlagBits("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT"),
			}
		)
		vk_assert(
			lib.vkBeginCommandBuffer(commandBuffer[0], beginInfo),
			"failed to begin command buffer"
		)
		-- Transition image to transfer dst
		local barrier = vk.Box(
			vk.VkImageMemoryBarrier,
			{
				sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
				oldLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
				newLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
				srcQueueFamilyIndex = 0xFFFFFFFF, -- VK_QUEUE_FAMILY_IGNORED
				dstQueueFamilyIndex = 0xFFFFFFFF, -- VK_QUEUE_FAMILY_IGNORED
				image = swapchainImages[imageIndex[0]],
				subresourceRange = {
					aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
				srcAccessMask = 0,
				dstAccessMask = vk.VkAccessFlagBits("VK_ACCESS_TRANSFER_WRITE_BIT"),
			}
		)
		lib.vkCmdPipelineBarrier(
			commandBuffer[0],
			vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT"),
			vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
			0,
			0,
			nil,
			0,
			nil,
			1,
			barrier
		)
		-- Clear color (animating through hue)
		local hue = (frame % 360) / 360.0
		local clearColor = vk.Box(vk.VkClearColorValue, {
			float32 = {hue, 0.5, 0.8, 1.0},
		})
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
			clearColor,
			1,
			range
		)
		-- Transition to present
		barrier[0].oldLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL"
		barrier[0].newLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
		barrier[0].srcAccessMask = vk.VkAccessFlagBits("VK_ACCESS_TRANSFER_WRITE_BIT")
		barrier[0].dstAccessMask = 0
		lib.vkCmdPipelineBarrier(
			commandBuffer[0],
			vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
			vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT"),
			0,
			0,
			nil,
			0,
			nil,
			1,
			barrier
		)
		vk_assert(lib.vkEndCommandBuffer(commandBuffer[0]), "failed to end command buffer")
		-- Submit command buffer
		local waitStages = ffi.new(
			"uint32_t[1]",
			vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT")
		)
		local submitInfo = vk.Box(
			vk.VkSubmitInfo,
			{
				sType = "VK_STRUCTURE_TYPE_SUBMIT_INFO",
				waitSemaphoreCount = 1,
				pWaitSemaphores = imageAvailableSemaphore,
				pWaitDstStageMask = waitStages,
				commandBufferCount = 1,
				pCommandBuffers = commandBuffer,
				signalSemaphoreCount = 1,
				pSignalSemaphores = renderFinishedSemaphore,
			}
		)
		vk_assert(
			lib.vkQueueSubmit(queue[0], 1, submitInfo, inFlightFence[0]),
			"failed to submit queue"
		)
		-- Present
		local presentInfo = vk.Box(
			vk.VkPresentInfoKHR,
			{
				sType = "VK_STRUCTURE_TYPE_PRESENT_INFO_KHR",
				waitSemaphoreCount = 1,
				pWaitSemaphores = renderFinishedSemaphore,
				swapchainCount = 1,
				pSwapchains = swapchain,
				pImageIndices = imageIndex,
			}
		)
		lib.vkQueuePresentKHR(queue[0], presentInfo)
	end

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
