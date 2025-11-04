local ffi = require("ffi")
local vk = require("vk")
local shaderc = require("shaderc")
local setmetatable = require("helpers.setmetatable_gc")
local lib = vk.find_library()
local vulkan = {}
vulkan.vk = vk
vulkan.lib = lib

local function vk_assert(result, msg)
	if result ~= 0 then
		msg = msg or "Vulkan error"
		local enum_str = vk.EnumToString(result) or ("error code - " .. tostring(result))
		error(msg .. " : " .. enum_str, 2)
	end
end

function vulkan.GetAvailableLayers()
	-- First, enumerate available layers
	local layerCount = ffi.new("uint32_t[1]", 0)
	lib.vkEnumerateInstanceLayerProperties(layerCount, nil)
	local out = {}

	if layerCount[0] > 0 then
		local availableLayers = vk.Array(vk.VkLayerProperties)(layerCount[0])
		lib.vkEnumerateInstanceLayerProperties(layerCount, availableLayers)

		for i = 0, layerCount[0] - 1 do
			local layerName = ffi.string(availableLayers[i].layerName)
			table.insert(out, layerName)
		end
	end

	return out
end

function vulkan.GetAvailableExtensions()
	-- First, enumerate available extensions
	local extensionCount = ffi.new("uint32_t[1]", 0)
	lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, nil)
	local out = {}

	if extensionCount[0] > 0 then
		local availableExtensions = vk.Array(vk.VkExtensionProperties)(extensionCount[0])
		lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, availableExtensions)

		for i = 0, extensionCount[0] - 1 do
			local extensionName = ffi.string(availableExtensions[i].extensionName)
			table.insert(out, extensionName)
		end
	end

	return out
end

do
	local function major(ver)
		return bit.rshift(ver, 22)
	end

	local function minor(ver)
		return bit.band(bit.rshift(ver, 12), 0x3FF)
	end

	local function patch(ver)
		return bit.band(ver, 0xFFF)
	end

	function vulkan.VersionToString(ver)
		return string.format("%d.%d.%d", major(ver), minor(ver), patch(ver))
	end

	function vulkan.GetVersion()
		local version = ffi.new("uint32_t[1]", 0)
		lib.vkEnumerateInstanceVersion(version)
		return vulkan.VersionToString(version[0])
	end
end

do -- instance
	local Instance = {}
	Instance.__index = Instance

	function vulkan.CreateInstance(extensions, layers)
		print("layers available:")

		for k, v in ipairs(vulkan.GetAvailableLayers()) do
			print("\t" .. v)
		end

		print("extensions available:")
		for k, v in ipairs(vulkan.GetAvailableExtensions()) do
			print("\t" .. v)
		end

		local version = vk.VK_API_VERSION_1_4
		print("requesting version: " .. vulkan.VersionToString(version))
		local appInfo = vk.Box(
			vk.VkApplicationInfo,
			{
				sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
				pApplicationName = "MoltenVK LuaJIT Example",
				applicationVersion = 1,
				pEngineName = "No Engine",
				engineVersion = 1,
				apiVersion = version,
			}
		)
		print("version loaded: " .. vulkan.GetVersion())
	
		local extension_names = extensions and
			vk.Array(ffi.typeof("const char*"), #extensions, extensions) or
			nil
		local layer_names = layers and vk.Array(ffi.typeof("const char*"), #layers, layers) or nil
		local createInfo = vk.Box(
			vk.VkInstanceCreateInfo,
			{
				sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
				pNext = nil,
				flags = vk.VkInstanceCreateFlagBits("VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR"),
				pApplicationInfo = appInfo,
				enabledLayerCount = layers and #layers or 0,
				ppEnabledLayerNames = layer_names,
				enabledExtensionCount = extensions and #extensions or 0,
				ppEnabledExtensionNames = extension_names,
			}
		)
		local ptr = vk.Box(vk.VkInstance)()
		vk_assert(lib.vkCreateInstance(createInfo, nil, ptr), "failed to create vulkan instance")
		return setmetatable({ptr = ptr}, Instance)
	end

	function Instance:__gc()
		lib.vkDestroyInstance(self.ptr[0], nil)
	end

	do -- metal surface
		local Surface = {}
		Surface.__index = Surface

		function Instance:CreateMetalSurface(metal_layer)
			assert(metal_layer ~= nil, "metal_layer cannot be nil")
			local surfaceCreateInfo = vk.VkMetalSurfaceCreateInfoEXT(
				{
					sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
					pNext = nil,
					flags = 0,
					pLayer = ffi.cast("const void*", metal_layer),
				}
			)
			local ptr = vk.Box(vk.VkSurfaceKHR)()
			local vkCreateMetalSurfaceEXT = vk.GetExtension(lib, self.ptr[0], "vkCreateMetalSurfaceEXT")
			vk_assert(
				vkCreateMetalSurfaceEXT(self.ptr[0], surfaceCreateInfo, nil, ptr),
				"failed to create metal surface"
			)
			return setmetatable({ptr = ptr, instance = self}, Surface)
		end

		function Instance:__gc()
			if self.instance then
				lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
			end
		end
	end

	do -- physicalDevice
		local PhysicalDevice = {}
		PhysicalDevice.__index = PhysicalDevice

		function Instance:GetPhysicalDevices()
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
				out[i + 1] = setmetatable({ptr = physicalDevices[i]}, PhysicalDevice)
			end

			return out
		end

		function PhysicalDevice:FindGraphicsQueueFamily(surface)
			local graphicsQueueFamily = nil

			for i, queueFamily in ipairs(self:GetQueueFamilyProperties()) do
				local queueFlags = queueFamily.queueFlags
				local graphicsBit = vk.VkQueueFlagBits("VK_QUEUE_GRAPHICS_BIT")

				if bit.band(queueFlags, graphicsBit) ~= 0 then
					if not graphicsQueueFamily then graphicsQueueFamily = i - 1 end
				end

				local presentSupport = ffi.new("uint32_t[1]", 0)
				lib.vkGetPhysicalDeviceSurfaceSupportKHR(self.ptr, i - 1, surface.ptr[0], presentSupport)

				if bit.band(queueFlags, graphicsBit) ~= 0 and presentSupport[0] ~= 0 then
					graphicsQueueFamily = i - 1

					break
				end
			end

			if not graphicsQueueFamily then error("no graphics queue family found") end

			return graphicsQueueFamily
		end

		function PhysicalDevice:GetSurfaceFormats(surface)
			local formatCount = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, nil)
			local count = formatCount[0]
			local formats = vk.Array(vk.VkSurfaceFormatKHR)(count)
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, formats)
			-- Convert to Lua table
			local result = {}

			for i = 0, count - 1 do
				result[i + 1] = formats[i]
			end

			return result
		end

		function PhysicalDevice:GetQueueFamilyProperties()
			local count = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, count, nil)
			local queue_family_count = count[0]
			local queue_families = vk.Array(vk.VkQueueFamilyProperties)(queue_family_count)
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, count, queue_families)
			local result = {}

			for i = 0, queue_family_count - 1 do
				result[i + 1] = queue_families[i]
			end

			return result
		end

		function PhysicalDevice:GetSurfaceCapabilities(surface)
			local surfaceCapabilities = vk.Box(vk.VkSurfaceCapabilitiesKHR)()
			vk_assert(
				lib.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.ptr, surface.ptr[0], surfaceCapabilities),
				"failed to get surface capabilities"
			)
			return surfaceCapabilities
		end

		function PhysicalDevice:GetPresentModes(surface)
			local presentModeCount = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr, surface.ptr[0], presentModeCount, nil)
			local count = presentModeCount[0]
			local presentModes = vk.Array(vk.VkPresentModeKHR)(count)
			lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr, surface.ptr[0], presentModeCount, presentModes)
			-- Convert to Lua table
			local result = {}

			for i = 0, count - 1 do
				result[i + 1] = presentModes[i]
			end

			return result
		end

		do -- device
			local Device = {}
			Device.__index = Device

			function PhysicalDevice:CreateDevice(extensions, graphicsQueueFamily)
				-- Check if VK_KHR_portability_subset is supported and add it if needed
				local extensionCount = ffi.new("uint32_t[1]", 0)
				lib.vkEnumerateDeviceExtensionProperties(self.ptr, nil, extensionCount, nil)
				local availableExtensions = vk.Array(vk.VkExtensionProperties)(extensionCount[0])
				lib.vkEnumerateDeviceExtensionProperties(self.ptr, nil, extensionCount, availableExtensions)
				local hasPortabilitySubset = false

				for i = 0, extensionCount[0] - 1 do
					local extName = ffi.string(availableExtensions[i].extensionName)

					if extName == "VK_KHR_portability_subset" then
						hasPortabilitySubset = true

						break
					end
				end

				-- Add portability subset and its dependency if supported
				local finalExtensions = {}

				for i, ext in ipairs(extensions) do
					finalExtensions[i] = ext
				end

				if hasPortabilitySubset then
					-- VK_KHR_portability_subset requires VK_KHR_get_physical_device_properties2
					-- but this extension is promoted to core in Vulkan 1.1, so it's likely already available
					table.insert(finalExtensions, "VK_KHR_portability_subset")
					-- Only add the dependency if not already present
					local hasGetProps2 = false

					for _, ext in ipairs(finalExtensions) do
						if ext == "VK_KHR_get_physical_device_properties2" then
							hasGetProps2 = true

							break
						end
					end

					if not hasGetProps2 then
						-- Check if this extension is available
						for i = 0, extensionCount[0] - 1 do
							local extName = ffi.string(availableExtensions[i].extensionName)

							if extName == "VK_KHR_get_physical_device_properties2" then
								table.insert(finalExtensions, "VK_KHR_get_physical_device_properties2")

								break
							end
						end
					end
				end

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
				local deviceExtensions = vk.Array(ffi.typeof("const char*"), #finalExtensions, finalExtensions)
				local deviceCreateInfo = vk.Box(
					vk.VkDeviceCreateInfo,
					{
						sType = "VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO",
						queueCreateInfoCount = 1,
						pQueueCreateInfos = queueCreateInfo,
						enabledExtensionCount = #finalExtensions,
						ppEnabledExtensionNames = deviceExtensions,
					}
				)
				local ptr = vk.Box(vk.VkDevice)()
				vk_assert(
					lib.vkCreateDevice(self.ptr, deviceCreateInfo, nil, ptr),
					"failed to create device"
				)
				return setmetatable({ptr = ptr, physical_device = self}, Device)
			end

			function Device:__gc()
				lib.vkDestroyDevice(self.ptr[0], nil)
			end

			do -- shader
				local ShaderModule = {}
				ShaderModule.__index = ShaderModule

				function Device:CreateShaderModule(glsl, type)
					local spirv_data, spirv_size = shaderc.compile(glsl, type)
					local shaderModuleCreateInfo = vk.Box(
						vk.VkShaderModuleCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO",
							codeSize = spirv_size,
							pCode = ffi.cast("const uint32_t*", spirv_data),
						}
					)
					local ptr = vk.Box(vk.VkShaderModule)()
					vk_assert(
						lib.vkCreateShaderModule(self.ptr[0], shaderModuleCreateInfo, nil, ptr),
						"failed to create shader module"
					)
					return setmetatable({ptr = ptr, device = self}, ShaderModule)
				end

				function ShaderModule:__gc()
					lib.vkDestroyShaderModule(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- queue
				local Queue = {}
				Queue.__index = Queue

				function Device:GetQueue(graphicsQueueFamily)
					local deviceQueue = vk.Box(vk.VkQueue)()
					lib.vkGetDeviceQueue(self.ptr[0], graphicsQueueFamily, 0, deviceQueue)
					return setmetatable({ptr = deviceQueue}, Queue)
				end

				function Queue:Submit(
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
				local Swapchain = {}
				Swapchain.__index = Swapchain

				-- config options:
				--   presentMode: VkPresentModeKHR (default: "VK_PRESENT_MODE_FIFO_KHR")
				--   imageCount: number of images in swapchain (default: surfaceCapabilities.minImageCount)
				--   compositeAlpha: VkCompositeAlphaFlagBitsKHR (default: "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR")
				--   clipped: boolean (default: true)
				--   imageUsage: VkImageUsageFlags (default: COLOR_ATTACHMENT_BIT | TRANSFER_DST_BIT)
				--   preTransform: VkSurfaceTransformFlagBitsKHR (default: currentTransform)
				function Device:CreateSwapchain(surface, surfaceFormat, surfaceCapabilities, config, old_swapchain)
					config = config or {}
					local imageCount = config.imageCount or surfaceCapabilities[0].minImageCount
					local presentMode = config.presentMode or "VK_PRESENT_MODE_FIFO_KHR"
					local compositeAlpha = config.compositeAlpha or "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR"
					local clipped = config.clipped ~= nil and (config.clipped and 1 or 0) or 1
					local preTransform = config.preTransform or surfaceCapabilities[0].currentTransform
					local imageUsage = config.imageUsage or
						bit.bor(
							vk.VkImageUsageFlagBits("VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT"),
							vk.VkImageUsageFlagBits("VK_IMAGE_USAGE_TRANSFER_DST_BIT")
						)

					-- Clamp image count to valid range
					if imageCount < surfaceCapabilities[0].minImageCount then
						imageCount = surfaceCapabilities[0].minImageCount
					end

					if
						surfaceCapabilities[0].maxImageCount > 0 and
						imageCount > surfaceCapabilities[0].maxImageCount
					then
						imageCount = surfaceCapabilities[0].maxImageCount
					end

					local swapchainCreateInfo = vk.Box(
						vk.VkSwapchainCreateInfoKHR,
						{
							sType = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR",
							surface = surface.ptr[0],
							minImageCount = imageCount,
							imageFormat = surfaceFormat.format,
							imageColorSpace = surfaceFormat.colorSpace,
							imageExtent = surfaceCapabilities[0].currentExtent,
							imageArrayLayers = 1,
							imageUsage = imageUsage,
							imageSharingMode = "VK_SHARING_MODE_EXCLUSIVE",
							preTransform = preTransform,
							compositeAlpha = vk.VkCompositeAlphaFlagBitsKHR(compositeAlpha),
							presentMode = presentMode,
							clipped = clipped,
							oldSwapchain = old_swapchain and old_swapchain.ptr[0],
						}
					)
					local ptr = vk.Box(vk.VkSwapchainKHR)()
					vk_assert(
						lib.vkCreateSwapchainKHR(self.ptr[0], swapchainCreateInfo, nil, ptr),
						"failed to create swapchain"
					)
					return setmetatable({ptr = ptr, device = self}, Swapchain)
				end

				function Swapchain:__gc()
					lib.vkDestroySwapchainKHR(self.device.ptr[0], self.ptr[0], nil)
				end

				function Swapchain:GetImages()
					local imageCount = ffi.new("uint32_t[1]", 0)
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, nil)
					local swapchainImages = vk.Array(vk.VkImage)(imageCount[0])
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, swapchainImages)
					local out = {}

					for i = 0, imageCount[0] - 1 do
						out[i + 1] = swapchainImages[i]
					end

					return out
				end

				function Swapchain:GetNextImage(imageAvailableSemaphore)
					local imageIndex = ffi.new("uint32_t[1]", 0)
					local result = lib.vkAcquireNextImageKHR(
						self.device.ptr[0],
						self.ptr[0],
						ffi.cast("uint64_t", -1),
						imageAvailableSemaphore.ptr[0],
						nil,
						imageIndex
					)

					if result == vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
						return nil, "out_of_date"
					elseif result == vk.VkResult("VK_SUBOPTIMAL_KHR") then
						return imageIndex[0], "suboptimal"
					elseif result ~= 0 then
						error("failed to acquire next image: " .. vk.EnumToString(result))
					end

					return imageIndex[0], "ok"
				end

				function Swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
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
					local result = lib.vkQueuePresentKHR(deviceQueue.ptr[0], presentInfo)

					if result == vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
						return false
					elseif result == vk.VkResult("VK_SUBOPTIMAL_KHR") then
						return false
					elseif result ~= vk.VkResult("VK_SUCCESS") then
						error("failed to present: " .. vk.EnumToString(result))
					end

					return true
				end
			end

			do -- commandPool
				local CommandPool = {}
				CommandPool.__index = CommandPool

				function Device:CreateCommandPool(graphicsQueueFamily)
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
					return setmetatable({ptr = ptr, device = self}, CommandPool)
				end

				function CommandPool:__gc()
					lib.vkDestroyCommandPool(self.device.ptr[0], self.ptr[0], nil)
				end

				do -- commandBuffer
					local CommandBuffer = {}
					CommandBuffer.__index = CommandBuffer

					function CommandPool:CreateCommandBuffer()
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
						return setmetatable({ptr = commandBuffer}, CommandBuffer)
					end

					function CommandBuffer:Begin()
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

					function CommandBuffer:Reset()
						lib.vkResetCommandBuffer(self.ptr[0], 0)
					end

					function CommandBuffer:CreateImageMemoryBarrier(imageIndex, swapchainImages, isFirstFrame)
						-- For first frame, transition from UNDEFINED
						-- For subsequent frames, transition from PRESENT_SRC_KHR (what the render pass leaves it in)
						local oldLayout = isFirstFrame and "VK_IMAGE_LAYOUT_UNDEFINED" or "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
						local barrier = vk.Box(
							vk.VkImageMemoryBarrier,
							{
								sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
								oldLayout = oldLayout,
								newLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
								srcQueueFamilyIndex = 0xFFFFFFFF,
								dstQueueFamilyIndex = 0xFFFFFFFF,
								image = swapchainImages[imageIndex],
								subresourceRange = {
									aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
									baseMipLevel = 0,
									levelCount = 1,
									baseArrayLayer = 0,
									layerCount = 1,
								},
								srcAccessMask = 0,
								dstAccessMask = vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
							}
						)
						return barrier
					end

					function CommandBuffer:StartPipelineBarrier(barrier)
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

					function CommandBuffer:EndPipelineBarrier(barrier)
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

					function CommandBuffer:End()
						vk_assert(lib.vkEndCommandBuffer(self.ptr[0]), "failed to end command buffer")
					end

					function CommandBuffer:BeginRenderPass(renderPass, framebuffer, extent, clearColor)
						clearColor = clearColor or {0.0, 0.0, 0.0, 1.0}
						local clearValue = vk.Box(
							vk.VkClearValue,
							{
								color = {
									float32 = clearColor,
								},
							}
						)
						local renderPassInfo = vk.Box(
							vk.VkRenderPassBeginInfo,
							{
								sType = "VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO",
								renderPass = renderPass.ptr[0],
								framebuffer = framebuffer.ptr[0],
								renderArea = {
									offset = {x = 0, y = 0},
									extent = extent,
								},
								clearValueCount = 1,
								pClearValues = clearValue,
							}
						)
						lib.vkCmdBeginRenderPass(
							self.ptr[0],
							renderPassInfo,
							vk.VkSubpassContents("VK_SUBPASS_CONTENTS_INLINE")
						)
					end

					function CommandBuffer:EndRenderPass()
						lib.vkCmdEndRenderPass(self.ptr[0])
					end

					function CommandBuffer:BindPipeline(pipeline)
						lib.vkCmdBindPipeline(
							self.ptr[0],
							vk.VkPipelineBindPoint("VK_PIPELINE_BIND_POINT_GRAPHICS"),
							pipeline.ptr[0]
						)
					end

					function CommandBuffer:BindVertexBuffers(firstBinding, buffers, offsets)
						-- buffers is an array of Buffer objects
						-- offsets is optional array of offsets
						local bufferCount = #buffers
						local bufferArray = vk.Array(vk.VkBuffer)(bufferCount)
						local offsetArray = vk.Array(vk.VkDeviceSize)(bufferCount)

						for i, buffer in ipairs(buffers) do
							bufferArray[i - 1] = buffer.ptr[0]
							offsetArray[i - 1] = offsets and offsets[i] or 0
						end

						lib.vkCmdBindVertexBuffers(
							self.ptr[0],
							firstBinding or 0,
							bufferCount,
							bufferArray,
							offsetArray
						)
					end

					function CommandBuffer:BindDescriptorSets(pipelineLayout, descriptorSets, firstSet)
						-- descriptorSets is an array of descriptor set objects
						local setCount = #descriptorSets
						local setArray = vk.Array(vk.VkDescriptorSet)(setCount)

						for i, ds in ipairs(descriptorSets) do
							setArray[i - 1] = ds.ptr[0]
						end

						lib.vkCmdBindDescriptorSets(
							self.ptr[0],
							vk.VkPipelineBindPoint("VK_PIPELINE_BIND_POINT_GRAPHICS"),
							pipelineLayout.ptr[0],
							firstSet or 0,
							setCount,
							setArray,
							0,
							nil
						)
					end

					function CommandBuffer:Draw(vertexCount, instanceCount, firstVertex, firstInstance)
						lib.vkCmdDraw(
							self.ptr[0],
							vertexCount or 3,
							instanceCount or 1,
							firstVertex or 0,
							firstInstance or 0
						)
					end
				end
			end

			do -- buffer
				local Buffer = {}
				Buffer.__index = Buffer

				function Device:FindMemoryType(typeFilter, properties)
					local memProperties = vk.Box(vk.VkPhysicalDeviceMemoryProperties)()
					lib.vkGetPhysicalDeviceMemoryProperties(self.physical_device.ptr, memProperties)

					for i = 0, memProperties[0].memoryTypeCount - 1 do
						if
							bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and
							bit.band(memProperties[0].memoryTypes[i].propertyFlags, properties) == properties
						then
							return i
						end
					end

					error("failed to find suitable memory type!")
				end

				function Device:CreateBuffer(size, usage, properties)
					local bufferInfo = vk.Box(
						vk.VkBufferCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO",
							size = size,
							usage = usage,
							sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
						}
					)
					local buffer_ptr = vk.Box(vk.VkBuffer)()
					vk_assert(
						lib.vkCreateBuffer(self.ptr[0], bufferInfo, nil, buffer_ptr),
						"failed to create buffer"
					)
					local memRequirements = vk.Box(vk.VkMemoryRequirements)()
					lib.vkGetBufferMemoryRequirements(self.ptr[0], buffer_ptr[0], memRequirements)
					local allocInfo = vk.Box(
						vk.VkMemoryAllocateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO",
							allocationSize = memRequirements[0].size,
							memoryTypeIndex = self:FindMemoryType(memRequirements[0].memoryTypeBits, properties),
						}
					)
					local memory_ptr = vk.Box(vk.VkDeviceMemory)()
					vk_assert(
						lib.vkAllocateMemory(self.ptr[0], allocInfo, nil, memory_ptr),
						"failed to allocate buffer memory"
					)
					lib.vkBindBufferMemory(self.ptr[0], buffer_ptr[0], memory_ptr[0], 0)
					return setmetatable(
						{
							ptr = buffer_ptr,
							memory = memory_ptr,
							size = size,
							device = self,
						},
						Buffer
					)
				end

				function Buffer:Map()
					local data = ffi.new("void*[1]")
					lib.vkMapMemory(self.device.ptr[0], self.memory[0], 0, self.size, 0, data)
					return data[0]
				end

				function Buffer:Unmap()
					lib.vkUnmapMemory(self.device.ptr[0], self.memory[0])
				end

				function Buffer:CopyData(src_data, size)
					local data = self:Map()
					ffi.copy(data, src_data, size or self.size)
					self:Unmap()
				end

				function Buffer:__gc()
					lib.vkDestroyBuffer(self.device.ptr[0], self.ptr[0], nil)
					lib.vkFreeMemory(self.device.ptr[0], self.memory[0], nil)
				end
			end

			do -- descriptor set layout
				local DescriptorSetLayout = {}
				DescriptorSetLayout.__index = DescriptorSetLayout

				function Device:CreateDescriptorSetLayout(bindings)
					-- bindings is an array of tables: {{binding, type, stageFlags, count}, ...}
					local bindingArray = vk.Array(vk.VkDescriptorSetLayoutBinding)(#bindings)

					for i, b in ipairs(bindings) do
						bindingArray[i - 1].binding = b.binding or (i - 1)
						bindingArray[i - 1].descriptorType = vk.VkDescriptorType(b.type or "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER")
						bindingArray[i - 1].descriptorCount = b.count or 1
						bindingArray[i - 1].stageFlags = b.stageFlags or vk.VkShaderStageFlagBits("VK_SHADER_STAGE_FRAGMENT_BIT")
						bindingArray[i - 1].pImmutableSamplers = nil
					end

					local layoutInfo = vk.Box(
						vk.VkDescriptorSetLayoutCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO",
							bindingCount = #bindings,
							pBindings = bindingArray,
						}
					)
					local ptr = vk.Box(vk.VkDescriptorSetLayout)()
					vk_assert(
						lib.vkCreateDescriptorSetLayout(self.ptr[0], layoutInfo, nil, ptr),
						"failed to create descriptor set layout"
					)
					return setmetatable({ptr = ptr, device = self}, DescriptorSetLayout)
				end

				function DescriptorSetLayout:__gc()
					lib.vkDestroyDescriptorSetLayout(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- descriptor pool
				local DescriptorPool = {}
				DescriptorPool.__index = DescriptorPool

				function Device:CreateDescriptorPool(poolSizes, maxSets)
					-- poolSizes is an array of tables: {{type, count}, ...}
					local poolSizeArray = vk.Array(vk.VkDescriptorPoolSize)(#poolSizes)

					for i, ps in ipairs(poolSizes) do
						poolSizeArray[i - 1].type = vk.VkDescriptorType(ps.type or "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER")
						poolSizeArray[i - 1].descriptorCount = ps.count or 1
					end

					local poolInfo = vk.Box(
						vk.VkDescriptorPoolCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO",
							poolSizeCount = #poolSizes,
							pPoolSizes = poolSizeArray,
							maxSets = maxSets or 1,
						}
					)
					local ptr = vk.Box(vk.VkDescriptorPool)()
					vk_assert(
						lib.vkCreateDescriptorPool(self.ptr[0], poolInfo, nil, ptr),
						"failed to create descriptor pool"
					)
					return setmetatable({ptr = ptr, device = self}, DescriptorPool)
				end

				function DescriptorPool:AllocateDescriptorSet(layout)
					local allocInfo = vk.Box(
						vk.VkDescriptorSetAllocateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO",
							descriptorPool = self.ptr[0],
							descriptorSetCount = 1,
							pSetLayouts = layout.ptr,
						}
					)
					local ptr = vk.Box(vk.VkDescriptorSet)()
					vk_assert(
						lib.vkAllocateDescriptorSets(self.device.ptr[0], allocInfo, ptr),
						"failed to allocate descriptor set"
					)
					return {ptr = ptr, device = self.device}
				end

				function DescriptorPool:__gc()
					lib.vkDestroyDescriptorPool(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			function Device:UpdateDescriptorSet(descriptorSet, binding, buffer, descriptorType)
				local bufferInfo = vk.Box(
					vk.VkDescriptorBufferInfo,
					{
						buffer = buffer.ptr[0],
						offset = 0,
						range = buffer.size,
					}
				)
				local descriptorWrite = vk.Box(
					vk.VkWriteDescriptorSet,
					{
						sType = "VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET",
						dstSet = descriptorSet.ptr[0],
						dstBinding = binding or 0,
						dstArrayElement = 0,
						descriptorType = descriptorType or "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER",
						descriptorCount = 1,
						pBufferInfo = bufferInfo,
					}
				)
				lib.vkUpdateDescriptorSets(self.ptr[0], 1, descriptorWrite, 0, nil)
			end

			do -- semaphore
				local Semaphore = {}
				Semaphore.__index = Semaphore

				function Device:CreateSemaphore()
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
					return setmetatable({ptr = ptr, device = self}, Semaphore)
				end

				function Semaphore:__gc()
					lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- fence
				local Fence = {}
				Fence.__index = Fence

				function Device:CreateFence()
					local fenceCreateInfo = vk.Box(
						vk.VkFenceCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_FENCE_CREATE_INFO",
							flags = vk.VkFenceCreateFlagBits("VK_FENCE_CREATE_SIGNALED_BIT"),
						}
					)
					local ptr = vk.Box(vk.VkFence)()
					vk_assert(lib.vkCreateFence(self.ptr[0], fenceCreateInfo, nil, ptr), "failed to create fence")
					return setmetatable({ptr = ptr, device = self}, Fence)
				end

				function Fence:__gc()
					lib.vkDestroyFence(self.device.ptr[0], self.ptr[0], nil)
				end

				function Fence:Wait()
					lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))
					lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
				end
			end

			do -- render pass
				local RenderPass = {}
				RenderPass.__index = RenderPass

				function Device:CreateRenderPass(surfaceFormat)
					local colorAttachment = vk.Box(
						vk.VkAttachmentDescription,
						{
							format = surfaceFormat.format,
							samples = "VK_SAMPLE_COUNT_1_BIT",
							loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
							storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
							stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
							stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
							initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
							finalLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR",
						}
					)
					local colorAttachmentRef = vk.Box(
						vk.VkAttachmentReference,
						{
							attachment = 0,
							layout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
						}
					)
					local subpass = vk.Box(
						vk.VkSubpassDescription,
						{
							pipelineBindPoint = "VK_PIPELINE_BIND_POINT_GRAPHICS",
							colorAttachmentCount = 1,
							pColorAttachments = colorAttachmentRef,
						}
					)
					local dependency = vk.Box(
						vk.VkSubpassDependency,
						{
							srcSubpass = vk.VK_SUBPASS_EXTERNAL,
							dstSubpass = 0,
							srcStageMask = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
							srcAccessMask = 0,
							dstStageMask = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
							dstAccessMask = vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
						}
					)
					local renderPassInfo = vk.Box(
						vk.VkRenderPassCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO",
							attachmentCount = 1,
							pAttachments = colorAttachment,
							subpassCount = 1,
							pSubpasses = subpass,
							dependencyCount = 1,
							pDependencies = dependency,
						}
					)
					local ptr = vk.Box(vk.VkRenderPass)()
					vk_assert(
						lib.vkCreateRenderPass(self.ptr[0], renderPassInfo, nil, ptr),
						"failed to create render pass"
					)
					return setmetatable({ptr = ptr, device = self}, RenderPass)
				end

				function RenderPass:__gc()
					lib.vkDestroyRenderPass(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- framebuffer
				local Framebuffer = {}
				Framebuffer.__index = Framebuffer

				function Device:CreateFramebuffer(renderPass, imageView, width, height)
					local attachments = vk.Array(vk.VkImageView, 1, {imageView})
					local framebufferInfo = vk.Box(
						vk.VkFramebufferCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO",
							renderPass = renderPass.ptr[0],
							attachmentCount = 1,
							pAttachments = attachments,
							width = width,
							height = height,
							layers = 1,
						}
					)
					local ptr = vk.Box(vk.VkFramebuffer)()
					vk_assert(
						lib.vkCreateFramebuffer(self.ptr[0], framebufferInfo, nil, ptr),
						"failed to create framebuffer"
					)
					return setmetatable({ptr = ptr, device = self}, Framebuffer)
				end

				function Framebuffer:__gc()
					lib.vkDestroyFramebuffer(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- image view
				local ImageView = {}
				ImageView.__index = ImageView

				function Device:CreateImageView(image, format)
					local viewInfo = vk.Box(
						vk.VkImageViewCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO",
							image = image,
							viewType = "VK_IMAGE_VIEW_TYPE_2D",
							format = format,
							subresourceRange = {
								aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
								baseMipLevel = 0,
								levelCount = 1,
								baseArrayLayer = 0,
								layerCount = 1,
							},
						}
					)
					local ptr = vk.Box(vk.VkImageView)()
					vk_assert(
						lib.vkCreateImageView(self.ptr[0], viewInfo, nil, ptr),
						"failed to create image view"
					)
					return setmetatable({ptr = ptr, device = self}, ImageView)
				end

				function ImageView:__gc()
					lib.vkDestroyImageView(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- pipeline layout
				local PipelineLayout = {}
				PipelineLayout.__index = PipelineLayout

				-- used to pass data to shaders
				function Device:CreatePipelineLayout(descriptorSetLayouts)
					-- descriptorSetLayouts is an optional array of DescriptorSetLayout objects
					local setLayoutArray = nil
					local setLayoutCount = 0

					if descriptorSetLayouts and #descriptorSetLayouts > 0 then
						setLayoutCount = #descriptorSetLayouts
						setLayoutArray = vk.Array(vk.VkDescriptorSetLayout)(setLayoutCount)

						for i, layout in ipairs(descriptorSetLayouts) do
							setLayoutArray[i - 1] = layout.ptr[0]
						end
					end

					local pipelineLayoutInfo = vk.Box(
						vk.VkPipelineLayoutCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO",
							setLayoutCount = setLayoutCount,
							pSetLayouts = setLayoutArray,
							pushConstantRangeCount = 0,
							pPushConstantRanges = nil,
						}
					)
					local ptr = vk.Box(vk.VkPipelineLayout)()
					vk_assert(
						lib.vkCreatePipelineLayout(self.ptr[0], pipelineLayoutInfo, nil, ptr),
						"failed to create pipeline layout"
					)
					return setmetatable({ptr = ptr, device = self}, PipelineLayout)
				end

				function PipelineLayout:__gc()
					lib.vkDestroyPipelineLayout(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- graphics pipeline
				local Pipeline = {}
				Pipeline.__index = Pipeline

				function Device:CreateGraphicsPipeline(config)
					-- config should contain: vertShaderModule, fragShaderModule, pipelineLayout, renderPass, extent
					local vertShaderStageInfo = vk.Box(
						vk.VkPipelineShaderStageCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO",
							stage = vk.VkShaderStageFlagBits("VK_SHADER_STAGE_VERTEX_BIT"),
							module = config.vertShaderModule.ptr[0],
							pName = "main",
						}
					)
					local fragShaderStageInfo = vk.Box(
						vk.VkPipelineShaderStageCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO",
							stage = vk.VkShaderStageFlagBits("VK_SHADER_STAGE_FRAGMENT_BIT"),
							module = config.fragShaderModule.ptr[0],
							pName = "main",
						}
					)
					-- Allocate shader stages array manually
					local stageArrayType = ffi.typeof("$ [2]", vk.VkPipelineShaderStageCreateInfo)
					local shaderStagesArray = ffi.new(stageArrayType)
					shaderStagesArray[0] = vertShaderStageInfo[0]
					shaderStagesArray[1] = fragShaderStageInfo[0]
					-- Vertex input state
					local bindingArray = nil
					local attributeArray = nil
					local bindingCount = 0
					local attributeCount = 0

					if config.vertexBindings then
						bindingCount = #config.vertexBindings
						bindingArray = vk.Array(vk.VkVertexInputBindingDescription)(bindingCount)

						for i, binding in ipairs(config.vertexBindings) do
							bindingArray[i - 1].binding = binding.binding or (i - 1)
							bindingArray[i - 1].stride = binding.stride
							bindingArray[i - 1].inputRate = vk.VkVertexInputRate(binding.inputRate or "VK_VERTEX_INPUT_RATE_VERTEX")
						end
					end

					if config.vertexAttributes then
						attributeCount = #config.vertexAttributes
						attributeArray = vk.Array(vk.VkVertexInputAttributeDescription)(attributeCount)

						for i, attr in ipairs(config.vertexAttributes) do
							attributeArray[i - 1].location = attr.location
							attributeArray[i - 1].binding = attr.binding or 0
							attributeArray[i - 1].format = vk.VkFormat(attr.format)
							attributeArray[i - 1].offset = attr.offset
						end
					end

					local vertexInputInfo = vk.Box(
						vk.VkPipelineVertexInputStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO",
							vertexBindingDescriptionCount = bindingCount,
							pVertexBindingDescriptions = bindingArray,
							vertexAttributeDescriptionCount = attributeCount,
							pVertexAttributeDescriptions = attributeArray,
						}
					)
					local inputAssembly = vk.Box(
						vk.VkPipelineInputAssemblyStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO",
							topology = "VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST",
							primitiveRestartEnable = 0,
						}
					)
					local viewport = vk.Box(
						vk.VkViewport,
						{
							x = 0.0,
							y = 0.0,
							width = tonumber(config.extent.width),
							height = tonumber(config.extent.height),
							minDepth = 0.0,
							maxDepth = 1.0,
						}
					)
					local scissor = vk.Box(
						vk.VkRect2D,
						{
							offset = {x = 0, y = 0},
							extent = config.extent,
						}
					)
					local viewportState = vk.Box(
						vk.VkPipelineViewportStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO",
							viewportCount = 1,
							pViewports = viewport,
							scissorCount = 1,
							pScissors = scissor,
						}
					)
					local rasterizer = vk.Box(
						vk.VkPipelineRasterizationStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO",
							depthClampEnable = 0,
							rasterizerDiscardEnable = 0,
							polygonMode = "VK_POLYGON_MODE_FILL",
							lineWidth = 1.0,
							cullMode = vk.VkCullModeFlagBits("VK_CULL_MODE_BACK_BIT"),
							frontFace = "VK_FRONT_FACE_CLOCKWISE",
							depthBiasEnable = 0,
						}
					)
					local multisampling = vk.Box(
						vk.VkPipelineMultisampleStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO",
							sampleShadingEnable = 0,
							rasterizationSamples = "VK_SAMPLE_COUNT_1_BIT",
						}
					)
					local colorBlendAttachment = vk.Box(
						vk.VkPipelineColorBlendAttachmentState,
						{
							colorWriteMask = bit.bor(
								vk.VkColorComponentFlagBits("VK_COLOR_COMPONENT_R_BIT"),
								vk.VkColorComponentFlagBits("VK_COLOR_COMPONENT_G_BIT"),
								vk.VkColorComponentFlagBits("VK_COLOR_COMPONENT_B_BIT"),
								vk.VkColorComponentFlagBits("VK_COLOR_COMPONENT_A_BIT")
							),
							blendEnable = 0,
						}
					)
					local colorBlending = vk.Box(
						vk.VkPipelineColorBlendStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO",
							logicOpEnable = 0,
							logicOp = "VK_LOGIC_OP_COPY",
							attachmentCount = 1,
							pAttachments = colorBlendAttachment,
							blendConstants = {0.0, 0.0, 0.0, 0.0},
						}
					)
					local pipelineInfo = vk.Box(
						vk.VkGraphicsPipelineCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO",
							stageCount = 2,
							pStages = shaderStagesArray,
							pVertexInputState = vertexInputInfo,
							pInputAssemblyState = inputAssembly,
							pViewportState = viewportState,
							pRasterizationState = rasterizer,
							pMultisampleState = multisampling,
							pDepthStencilState = nil,
							pColorBlendState = colorBlending,
							pDynamicState = nil,
							layout = config.pipelineLayout.ptr[0],
							renderPass = config.renderPass.ptr[0],
							subpass = 0,
							basePipelineHandle = nil,
							basePipelineIndex = -1,
						}
					)
					local ptr = vk.Box(vk.VkPipeline)()
					vk_assert(
						lib.vkCreateGraphicsPipelines(self.ptr[0], nil, 1, pipelineInfo, nil, ptr),
						"failed to create graphics pipeline"
					)
					return setmetatable({ptr = ptr, device = self, config = config}, Pipeline)
				end

				function Pipeline:__gc()
					lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
				end
			end
		end
	end
end

return vulkan
