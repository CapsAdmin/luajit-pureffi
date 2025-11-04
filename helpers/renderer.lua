local ffi = require("ffi")
local setmetatable = require("helpers.setmetatable_gc")
local vulkan = require("helpers.vulkan")
local vk = vulkan.vk
local lib = vulkan.lib
local Renderer = {}
Renderer.__index = Renderer
-- Default configuration
local default_config = {
	-- Swapchain settings
	present_mode = "VK_PRESENT_MODE_FIFO_KHR", -- FIFO (vsync), IMMEDIATE (no vsync), MAILBOX (triple buffer)
	image_count = nil, -- nil = minImageCount + 1 (usually triple buffer)
	surface_format_index = 1, -- Which format from available formats to use
	composite_alpha = "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR", -- OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
	clipped = true, -- Clip pixels obscured by other windows
	image_usage = nil, -- nil = COLOR_ATTACHMENT | TRANSFER_DST, or provide custom flags
	-- Image acquisition
	acquire_timeout = ffi.cast("uint64_t", -1), -- Infinite timeout by default
	-- Presentation
	pre_transform = nil, -- nil = use currentTransform
}

function Renderer.New(config)
	config = config or {}

	for k, v in pairs(default_config) do
		if config[k] == nil then config[k] = v end
	end

	local self = setmetatable({}, Renderer)
	self.config = config
	self:Initialize(assert(self.config.surface_handle))
	return self
end

function Renderer:Initialize(metal_surface)
	local layers = {}

	if os.getenv("VULKAN_SDK") then
		table.insert(layers, "VK_LAYER_KHRONOS_validation")
	end

	-- Vulkan initialization
	self.instance = vulkan.CreateInstance(
		{"VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_portability_enumeration"},
		layers
	)
	self.surface = self.instance:CreateMetalSurface(metal_surface)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	self.device = self.physical_device:CreateDevice({"VK_KHR_swapchain"}, self.graphics_queue_family)
	self.command_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	-- Query surface capabilities
	self.surface_formats = self.physical_device:GetSurfaceFormats(self.surface)
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	self.present_modes = self.physical_device:GetPresentModes(self.surface)

	-- Validate format index
	if self.config.surface_format_index > #self.surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#self.surface_formats
				) .. ")"
		)
	end

	-- Build swapchain config
	local swapchain_config = {
		present_mode = self.config.present_mode,
		image_count = self.config.image_count or (self.surface_capabilities[0].minImageCount + 1),
		composite_alpha = self.config.composite_alpha,
		clipped = self.config.clipped,
		image_usage = self.config.image_usage,
		pre_transform = self.config.pre_transform,
	}
	-- Create swapchain
	self.swapchain = self.device:CreateSwapchain(
		self.surface,
		self.surface_formats[self.config.surface_format_index],
		self.surface_capabilities,
		swapchain_config
	)
	self.swapchain_images = self.swapchain:GetImages()
	-- Get the image count for later use
	local imageCount = ffi.new("uint32_t[1]", 0)
	lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.swapchain.ptr[0], imageCount, nil)
	self.swapchain_image_count = imageCount[0]
	-- Create command buffers (one per swapchain image)
	self.command_buffers = {}
	for i = 1, self.swapchain_image_count do
		self.command_buffers[i] = self.command_pool:CreateCommandBuffer()
	end
	-- Create synchronization objects (one set per swapchain image)
	self.image_available_semaphores = {}
	self.render_finished_semaphores = {}
	self.in_flight_fences = {}

	for i = 1, self.swapchain_image_count do
		self.image_available_semaphores[i] = self.device:CreateSemaphore()
		self.render_finished_semaphores[i] = self.device:CreateSemaphore()
		self.in_flight_fences[i] = self.device:CreateFence()
	end

	-- Get queue
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	-- Initialize render pass and framebuffer management
	self.render_pass = nil
	self.image_views = {}
	self.framebuffers = {}
	self.current_frame = 0
	return self
end

function Renderer:CreateRenderPass()
	if self.render_pass then return self.render_pass end

	self.render_pass = self.device:CreateRenderPass(self.surface_formats[self.config.surface_format_index])
	return self.render_pass
end

function Renderer:CreateImageViews()
	self.image_views = {}

	for i = 0, self.swapchain_image_count - 1 do
		local imageView = self.device:CreateImageView(self.swapchain_images[i], self.surface_formats[self.config.surface_format_index].format)
		table.insert(self.image_views, imageView)
	end

	return self.image_views
end

function Renderer:CreateFramebuffers()
	if not self.render_pass then
		error("Render pass must be created before framebuffers")
	end

	if #self.image_views == 0 then
		error("Image views must be created before framebuffers")
	end

	self.framebuffers = {}
	local extent = self.surface_capabilities[0].currentExtent

	for _, imageView in ipairs(self.image_views) do
		local framebuffer = self.device:CreateFramebuffer(self.render_pass, imageView.ptr[0], extent.width, extent.height)
		table.insert(self.framebuffers, framebuffer)
	end

	return self.framebuffers
end

function Renderer:GetExtent()
	return self.surface_capabilities[0].currentExtent
end

function Renderer:PrintCapabilities()
	print("Available surface formats (unique):")
	local seen_formats = {}

	for i, format in ipairs(self.surface_formats) do
		local format_str = vk.EnumToString(format.format)
		local colorspace_str = vk.EnumToString(format.colorSpace)
		local key = format_str .. "|" .. colorspace_str

		if not seen_formats[key] then
			seen_formats[key] = true
			print("  [" .. (i - 1) .. "] " .. format_str .. " / " .. colorspace_str)
		end
	end

	print("\nAvailable present modes (unique):")
	local seen_present_modes = {}

	for _, mode in ipairs(self.present_modes) do
		local modeStr = vk.EnumToString(mode)

		if not seen_present_modes[modeStr] then
			seen_present_modes[modeStr] = true
			print("  " .. modeStr)
		end
	end

	print("\nSurface capabilities:")
	print("  Min image count: " .. self.surface_capabilities[0].minImageCount)
	print("  Max image count: " .. self.surface_capabilities[0].maxImageCount)
	print(
		"  Current extent: " .. self.surface_capabilities[0].currentExtent.width .. "x" .. self.surface_capabilities[0].currentExtent.height
	)
	print(
		"  Current transform: " .. vk.EnumToString(self.surface_capabilities[0].currentTransform)
	)
	-- Decode composite alpha bitmask
	print("  Supported composite alpha modes:")
	local composite_alpha_flags = self.surface_capabilities[0].supportedCompositeAlpha
	local alpha_modes = {
		{bit = 0x1, name = "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR"},
		{bit = 0x2, name = "VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR"},
		{bit = 0x4, name = "VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR"},
		{bit = 0x8, name = "VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR"},
	}

	for _, mode in ipairs(alpha_modes) do
		if bit.band(composite_alpha_flags, mode.bit) ~= 0 then
			print("    " .. mode.name)
		end
	end
end

function Renderer:BeginFrame()
	-- Re-query surface capabilities to check current state
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)

	-- Check if surface is valid before attempting to render
	local extent = self.surface_capabilities[0].currentExtent
	if extent.width == 0 or extent.height == 0 then
		-- Surface is minimized or invalid, skip this frame
		return nil
	end

	-- Use round-robin frame index
	self.current_frame = (self.current_frame % self.swapchain_image_count) + 1

	-- Wait for the fence for this frame FIRST (ensures previous use of this frame's resources is complete)
	self.in_flight_fences[self.current_frame]:Wait()

	-- Acquire next image (after waiting on fence)
	self.image_index, self.acquire_status = self.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

	-- Check if swapchain needs recreation
	if self.acquire_status == "out_of_date" or self.image_index == nil then
		self:RecreateSwapchain()
		return nil
	end

	-- Reset and begin command buffer for this frame
	local command_buffer = self.command_buffers[self.current_frame]
	command_buffer:Reset()
	command_buffer:Begin()
	return true
end

function Renderer:BeginPipelineBarrier()
	self.barrier = self.command_buffer:CreateImageMemoryBarrier(self.image_index, self.swapchain_images)
	self.command_buffer:StartPipelineBarrier(self.barrier)
end

function Renderer:EndPipelineBarrier()
	self.command_buffer:EndPipelineBarrier(self.barrier)
end

function Renderer:GetCommandBuffer()
	return self.command_buffers[self.current_frame]
end

function Renderer:GetSwapChainImage()
	return self.swapchain_images[self.image_index[0]]
end

function Renderer:GetFramebuffer()
	return self.framebuffers[self.image_index[0] + 1]
end

function Renderer:EndFrame()
	local command_buffer = self.command_buffers[self.current_frame]
	command_buffer:End()
	-- Submit command buffer with current frame's semaphores
	self.queue:Submit(
		command_buffer,
		self.image_available_semaphores[self.current_frame],
		self.render_finished_semaphores[self.current_frame],
		self.in_flight_fences[self.current_frame]
	)
	-- Present
	local present_status = self.swapchain:Present(self.render_finished_semaphores[self.current_frame], self.queue, self.image_index)

	-- Recreate swapchain if needed
	if present_status == "out_of_date" or present_status == "suboptimal" then
		self:RecreateSwapchain()
	end

	return present_status
end

function Renderer:RecreateSwapchain()
	-- Wait for device to be idle before recreating
	lib.vkDeviceWaitIdle(self.device.ptr[0])
	-- Re-query surface capabilities (they may have changed)
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)

	-- Check if surface extent is valid (can be 0x0 during window minimize/resize)
	local extent = self.surface_capabilities[0].currentExtent
	if extent.width == 0 or extent.height == 0 then
		-- Skip swapchain recreation when surface is invalid
		return
	end

	-- Re-query surface formats to ensure they're valid
	local new_surface_formats = self.physical_device:GetSurfaceFormats(self.surface)

	-- Validate that we have formats and the selected index is still valid
	if #new_surface_formats == 0 then
		error("No surface formats available")
	end

	if self.config.surface_format_index > #new_surface_formats then
		error("Surface format index out of bounds after resize")
	end

	-- Check if the selected format is valid (not VK_FORMAT_UNDEFINED)
	local selected_format = new_surface_formats[self.config.surface_format_index]
	if selected_format.format == vk.VkFormat("VK_FORMAT_UNDEFINED") then
		error("Selected surface format is VK_FORMAT_UNDEFINED")
	end

	self.surface_formats = new_surface_formats

	-- Build swapchain config
	local swapchain_config = {
		present_mode = self.config.present_mode,
		image_count = self.config.image_count or (self.surface_capabilities[0].minImageCount + 1),
		composite_alpha = self.config.composite_alpha,
		clipped = self.config.clipped,
		image_usage = self.config.image_usage,
		pre_transform = self.config.pre_transform,
	}
	-- Create new swapchain
	self.swapchain = self.device:CreateSwapchain(
		self.surface,
		self.surface_formats[self.config.surface_format_index],
		self.surface_capabilities,
		swapchain_config,
		self.swapchain -- old swapchain for efficient recreation
	)
	self.swapchain_images = self.swapchain:GetImages()
	-- Update image count
	local imageCount = ffi.new("uint32_t[1]", 0)
	lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.swapchain.ptr[0], imageCount, nil)
	local old_count = self.swapchain_image_count
	self.swapchain_image_count = imageCount[0]

	-- Recreate synchronization objects and command buffers if count changed
	if old_count ~= self.swapchain_image_count then
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, self.swapchain_image_count do
			self.command_buffers[i] = self.command_pool:CreateCommandBuffer()
			self.image_available_semaphores[i] = self.device:CreateSemaphore()
			self.render_finished_semaphores[i] = self.device:CreateSemaphore()
			self.in_flight_fences[i] = self.device:CreateFence()
		end

		self.current_frame = 0
	end

	-- Recreate image views if they were created before
	if self.render_pass then
		self:CreateImageViews()
		self:CreateFramebuffers()
	end

	self:OnRecreateSwapchain()
end

function Renderer:OnRecreateSwapchain() -- Override in derived classes if needed
end

function Renderer:NeedsRecreation()
	-- Check if current extent has changed
	local new_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	local old_extent = self.surface_capabilities[0].currentExtent
	local new_extent = new_capabilities[0].currentExtent
	return old_extent.width ~= new_extent.width or old_extent.height ~= new_extent.height
end

function Renderer:WaitForIdle()
	lib.vkDeviceWaitIdle(self.device.ptr[0])
end

return Renderer
