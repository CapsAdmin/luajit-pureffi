local ffi = require("ffi")
local vk = require("vk")
local lib = vk.find_library()
local vulkan = {}
vulkan.vk = vk
vulkan.lib = lib

local function vk_assert(result, msg)
	if result ~= 0 then
		error((msg or "error") .. " : " .. vk.EnumToString(result), 2)
	end
end

do -- instance
	local meta = {}
	meta.__index = meta

	function vulkan.CreateInstance(extensions)
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
		local extension_names = vk.Array(ffi.typeof("const char*"), #extensions, extensions)
		local createInfo = vk.Box(
			vk.VkInstanceCreateInfo,
			{
				sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
				pNext = nil,
				flags = 0,
				pApplicationInfo = appInfo,
				enabledLayerCount = 0,
				ppEnabledLayerNames = nil,
				enabledExtensionCount = #extensions,
				ppEnabledExtensionNames = extension_names,
			}
		)
		local ptr = vk.Box(vk.VkInstance)()
		vk_assert(lib.vkCreateInstance(createInfo, nil, ptr), "failed to create vulkan instance")
		local instance = setmetatable({ptr = ptr}, meta)
		return instance
	end

	function meta:__gc()
		lib.vkDestroyInstance(self.ptr[0], nil)
	end

	do -- metal surface
		local meta_instance = meta
		local meta = {}
		meta.__index = meta

		function meta_instance:CreateMetalSurface(metal_layer)
			local surfaceCreateInfo = vk.VkMetalSurfaceCreateInfoEXT(
				{
					sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
					pNext = nil,
					flags = 0,
					pLayer = ffi.cast("const void*", metal_layer, "failed to get metal layer"),
				}
			)
			local ptr = vk.Box(vk.VkSurfaceKHR)()
			local vkCreateMetalSurfaceEXT = vk.GetExtension(lib, self.ptr[0], "vkCreateMetalSurfaceEXT")
			vk_assert(
				vkCreateMetalSurfaceEXT(self.ptr[0], surfaceCreateInfo, nil, ptr),
				"failed to create metal surface"
			)
			local surface = setmetatable({ptr = ptr, instance = self}, meta)
			return surface
		end

		function meta:__gc()
			lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
		end
	end

	do -- physicalDevice
		local meta_instance = meta
		local meta = {}
		meta.__index = meta

		function meta_instance:GetPhysicalDevices()
			local deviceCount = ffi.new("uint32_t[1]", 0)
			vk_assert(
				lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, nil),
				"failed to enumerate physical devices"
			)

			if deviceCount[0] == 0 then error("no physical devices found") end

			local physicalDevices = vk.Array(vk.VkPhysicalDevice)(deviceCount[0])
			vk_assert(
				lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, physicalDevices),
				"failed to enumerate physical devices"
			)
			local out = {}

			for i = 0, deviceCount[0] - 1 do
				out[i + 1] = setmetatable({ptr = physicalDevices[i]}, meta)
			end

			return out
		end

		function meta:FindGraphicsQueueFamily(surface)
			local queueFamilyCount = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, queueFamilyCount, nil)
			local queueFamilies = vk.Array(vk.VkQueueFamilyProperties)(queueFamilyCount[0])
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, queueFamilyCount, queueFamilies)
			local graphicsQueueFamily = nil

			for i = 0, queueFamilyCount[0] - 1 do
				local queueFlags = queueFamilies[i].queueFlags
				local graphicsBit = vk.VkQueueFlagBits("VK_QUEUE_GRAPHICS_BIT")

				if bit.band(queueFlags, graphicsBit) ~= 0 then
					if not graphicsQueueFamily then graphicsQueueFamily = i end
				end

				local presentSupport = ffi.new("uint32_t[1]", 0)
				lib.vkGetPhysicalDeviceSurfaceSupportKHR(self.ptr, i, surface.ptr[0], presentSupport)

				if bit.band(queueFlags, graphicsBit) ~= 0 and presentSupport[0] ~= 0 then
					graphicsQueueFamily = i

					break
				end
			end

			if not graphicsQueueFamily then error("no graphics queue family found") end

			return graphicsQueueFamily
		end

		function meta:GetSurfaceFormats(surface)
			local formatCount = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, nil)
			local formats = vk.Array(vk.VkSurfaceFormatKHR)(formatCount[0])
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, formats)
			return formats
		end

		function meta:GetSurfaceCapabilities(surface)
			local surfaceCapabilities = vk.Box(vk.VkSurfaceCapabilitiesKHR)()
			vk_assert(
				lib.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.ptr, surface.ptr[0], surfaceCapabilities),
				"failed to get surface capabilities"
			)
			return surfaceCapabilities
		end

		do -- device
			local meta_device = {}
			meta_device.__index = meta_device

			function meta:CreateDevice(extensions, graphicsQueueFamily)
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
				local deviceExtensions = vk.Array(ffi.typeof("const char*"), #extensions, extensions)
				local deviceCreateInfo = vk.Box(
					vk.VkDeviceCreateInfo,
					{
						sType = "VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO",
						queueCreateInfoCount = 1,
						pQueueCreateInfos = queueCreateInfo,
						enabledExtensionCount = #extensions,
						ppEnabledExtensionNames = deviceExtensions,
					}
				)
				local ptr = vk.Box(vk.VkDevice)()
				vk_assert(
					lib.vkCreateDevice(self.ptr, deviceCreateInfo, nil, ptr),
					"failed to create device"
				)
				local device = setmetatable({ptr = ptr}, meta_device)
				return device
			end

			function meta_device:__gc()
				lib.vkDestroyDevice(self.ptr[0], nil)
			end

			do -- queue
				local meta_queue = {}
				meta_queue.__index = meta_queue

				function meta_device:GetQueue(graphicsQueueFamily)
					local deviceQueue = vk.Box(vk.VkQueue)()
					lib.vkGetDeviceQueue(self.ptr[0], graphicsQueueFamily, 0, deviceQueue)
					return setmetatable({ptr = deviceQueue}, meta_queue)
				end

				function meta_queue:Submit(
					commandBuffer,
					imageAvailableSemaphore,
					renderFinishedSemaphore,
					inFlightFence
				)
					local waitStages = ffi.new(
						"uint32_t[1]",
						vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT")
					)
					local submitInfo = vk.Box(
						vk.VkSubmitInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SUBMIT_INFO",
							waitSemaphoreCount = 1,
							pWaitSemaphores = imageAvailableSemaphore.ptr,
							pWaitDstStageMask = waitStages,
							commandBufferCount = 1,
							pCommandBuffers = commandBuffer.ptr,
							signalSemaphoreCount = 1,
							pSignalSemaphores = renderFinishedSemaphore.ptr,
						}
					)
					vk_assert(
						lib.vkQueueSubmit(self.ptr[0], 1, submitInfo, inFlightFence.ptr[0]),
						"failed to submit queue"
					)
				end
			end

			do -- swapchain
				local meta_swapchain = {}
				meta_swapchain.__index = meta_swapchain

				function meta_device:CreateSwapchain(surface, surfaceFormat, surfaceCapabilities)
					local swapchainCreateInfo = vk.Box(
						vk.VkSwapchainCreateInfoKHR,
						{
							sType = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR",
							surface = surface.ptr[0],
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
					local ptr = vk.Box(vk.VkSwapchainKHR)()
					vk_assert(
						lib.vkCreateSwapchainKHR(self.ptr[0], swapchainCreateInfo, nil, ptr),
						"failed to create swapchain"
					)
					local swapchain = setmetatable({ptr = ptr, device = self}, meta_swapchain)
					return swapchain
				end

				function meta_swapchain:__gc()
					lib.vkDestroySwapchainKHR(self.device.ptr[0], self.ptr[0], nil)
				end

				function meta_swapchain:GetImages()
					local imageCount = ffi.new("uint32_t[1]", 0)
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, nil)
					local swapchainImages = vk.Array(vk.VkImage)(imageCount[0])
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, swapchainImages)
					return swapchainImages
				end

				function meta_swapchain:GetNextImage(imageAvailableSemaphore)
					local imageIndex = ffi.new("uint32_t[1]", 0)
					vk_assert(
						lib.vkAcquireNextImageKHR(
							self.device.ptr[0],
							self.ptr[0],
							ffi.cast("uint64_t", -1),
							imageAvailableSemaphore.ptr[0],
							nil,
							imageIndex
						),
						"failed to acquire next image"
					)
					return imageIndex
				end

				function meta_swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
					local presentInfo = vk.Box(
						vk.VkPresentInfoKHR,
						{
							sType = "VK_STRUCTURE_TYPE_PRESENT_INFO_KHR",
							waitSemaphoreCount = 1,
							pWaitSemaphores = renderFinishedSemaphore.ptr,
							swapchainCount = 1,
							pSwapchains = self.ptr,
							pImageIndices = imageIndex,
						}
					)
					lib.vkQueuePresentKHR(deviceQueue.ptr[0], presentInfo)
				end
			end

			do -- commandPool
				local meta_commandPool = {}
				meta_commandPool.__index = meta_commandPool

				function meta_device:CreateCommandPool(graphicsQueueFamily)
					local commandPoolCreateInfo = vk.Box(
						vk.VkCommandPoolCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO",
							queueFamilyIndex = graphicsQueueFamily,
							flags = vk.VkCommandPoolCreateFlagBits("VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT"),
						}
					)
					local ptr = vk.Box(vk.VkCommandPool)()
					vk_assert(
						lib.vkCreateCommandPool(self.ptr[0], commandPoolCreateInfo, nil, ptr),
						"failed to create command pool"
					)
					local commandPool = setmetatable({ptr = ptr, device = self}, meta_commandPool)
					return commandPool
				end

				function meta_commandPool:__gc()
					lib.vkDestroyCommandPool(self.device.ptr[0], self.ptr[0], nil)
				end

				do -- commandBuffer
					local meta_commandBuffer = {}
					meta_commandBuffer.__index = meta_commandBuffer

					function meta_commandPool:CreateCommandBuffer()
						local commandBufferAllocInfo = vk.Box(
							vk.VkCommandBufferAllocateInfo,
							{
								sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO",
								commandPool = self.ptr[0],
								level = "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
								commandBufferCount = 1,
							}
						)
						local commandBuffer = vk.Box(vk.VkCommandBuffer)()
						vk_assert(
							lib.vkAllocateCommandBuffers(self.device.ptr[0], commandBufferAllocInfo, commandBuffer),
							"failed to allocate command buffer"
						)
						return setmetatable({ptr = commandBuffer}, meta_commandBuffer)
					end

					function meta_commandBuffer:Begin()
						local beginInfo = vk.Box(
							vk.VkCommandBufferBeginInfo,
							{
								sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO",
								flags = vk.VkCommandBufferUsageFlagBits("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT"),
							}
						)
						vk_assert(
							lib.vkBeginCommandBuffer(self.ptr[0], beginInfo),
							"failed to begin command buffer"
						)
					end

					function meta_commandBuffer:Reset()
						lib.vkResetCommandBuffer(self.ptr[0], 0)
					end

					function meta_commandBuffer:StartPipelineBarrier(barrier)
						lib.vkCmdPipelineBarrier(
							self.ptr[0],
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
					end

					function meta_commandBuffer:EndPipelineBarrier(barrier)
						barrier[0].oldLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL"
						barrier[0].newLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
						barrier[0].srcAccessMask = vk.VkAccessFlagBits("VK_ACCESS_TRANSFER_WRITE_BIT")
						barrier[0].dstAccessMask = 0
						lib.vkCmdPipelineBarrier(
							self.ptr[0],
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
					end

					function meta_commandBuffer:End()
						vk_assert(lib.vkEndCommandBuffer(self.ptr[0]), "failed to end command buffer")
					end
				end
			end

			do -- semaphore
				local meta_semaphore = {}
				meta_semaphore.__index = meta_semaphore

				function meta_device:CreateSemaphore()
					local semaphoreCreateInfo = vk.Box(
						vk.VkSemaphoreCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO",
						}
					)
					local ptr = vk.Box(vk.VkSemaphore)()
					vk_assert(
						lib.vkCreateSemaphore(self.ptr[0], semaphoreCreateInfo, nil, ptr),
						"failed to create semaphore"
					)
					local semaphore = setmetatable({ptr = ptr, device = self}, meta_semaphore)
					return semaphore
				end

				function meta_semaphore:__gc()
					lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- fence
				local meta_fence = {}
				meta_fence.__index = meta_fence

				function meta_device:CreateFence()
					local fenceCreateInfo = vk.Box(
						vk.VkFenceCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_FENCE_CREATE_INFO",
							flags = vk.VkFenceCreateFlagBits("VK_FENCE_CREATE_SIGNALED_BIT"),
						}
					)
					local ptr = vk.Box(vk.VkFence)()
					vk_assert(lib.vkCreateFence(self.ptr[0], fenceCreateInfo, nil, ptr), "failed to create fence")
					local fence = setmetatable({ptr = ptr, device = self}, meta_fence)
					return fence
				end

				function meta_fence:__gc()
					lib.vkDestroyFence(self.device.ptr[0], self.ptr[0], nil)
				end

				function meta_fence:Wait()
					lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))
					lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
				end
			end
		end
	end
end

do -- rendering
	function vulkan.ImageMemoryBarrier(imageIndex, swapchainImages)
		local barrier = vk.Box(
			vk.VkImageMemoryBarrier,
			{
				sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
				oldLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
				newLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
				srcQueueFamilyIndex = 0xFFFFFFFF,
				dstQueueFamilyIndex = 0xFFFFFFFF,
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
		return barrier
	end
end

return vulkan
