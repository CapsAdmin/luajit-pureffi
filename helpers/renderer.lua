local ffi = require("ffi")
local setmetatable = require("helpers.setmetatable_gc")
local vulkan = require("helpers.vulkan")
local Renderer = {}
Renderer.__index = Renderer

-- Default configuration
local default_config = {
	-- Swapchain settings
	present_mode = "fifo", -- FIFO (vsync), IMMEDIATE (no vsync), MAILBOX (triple buffer)
	image_count = nil, -- nil = minImageCount + 1 (usually triple buffer)
	surface_format_index = 1, -- Which format from available formats to use
	composite_alpha = "opaque", -- OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
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
	local extensions = {"VK_KHR_surface", "VK_EXT_metal_surface"}

	if os.getenv("VULKAN_SDK") then
		table.insert(layers, "VK_LAYER_KHRONOS_validation")
		table.insert(extensions, "VK_KHR_portability_enumeration")
	end

	-- Vulkan initialization
	self.instance = vulkan.CreateInstance(extensions, layers)
	self.surface = self.instance:CreateMetalSurface(metal_surface)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	self.device = self.physical_device:CreateDevice({"VK_KHR_swapchain"}, self.graphics_queue_family)
	self.command_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	-- Get queue
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	-- Initialize render pass and framebuffer management
	self.render_pass = nil
	self.image_views = {}
	self.framebuffers = {}
	self.current_frame = 0
	-- Create swapchain and related resources
	self:RecreateSwapchain()
	return self
end

function Renderer:RecreateSwapchain()
	-- Wait for device to be idle (skip on initial creation)
	if self.swapchain then self:WaitForIdle() end

	-- Query surface capabilities and formats
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	local new_surface_formats = self.physical_device:GetSurfaceFormats(self.surface)

	-- Validate format index
	if self.config.surface_format_index > #new_surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#new_surface_formats
				) .. ")"
		)
	end

	local selected_format = new_surface_formats[self.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
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
	-- Create new swapchain (pass old swapchain if it exists)
	self.swapchain = self.device:CreateSwapchain(
		self.surface,
		self.surface_formats[self.config.surface_format_index],
		self.surface_capabilities,
		swapchain_config,
		self.swapchain -- old swapchain for efficient recreation (nil on initial creation)
	)
	local old_count = self.swapchain_images and #self.swapchain_images or 0
	self.swapchain_images = self.swapchain:GetImages()

	if old_count ~= #self.swapchain_images then
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, #self.swapchain_images do
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

	if self.OnRecreateSwapchain then self:OnRecreateSwapchain() end
end

function Renderer:CreateRenderPass()
	if self.render_pass then return self.render_pass end

	self.render_pass = self.device:CreateRenderPass(self.surface_formats[self.config.surface_format_index])
	return self.render_pass
end

function Renderer:BeginRenderPass(clear_color)
	local command_buffer = self:GetCommandBuffer()
	command_buffer:BeginRenderPass(self.render_pass, self:GetFramebuffer(), self:GetExtent(), clear_color)
	return command_buffer
end

function Renderer:CreateImageViews()
	self.image_views = {}

	for _, swapchain_image in ipairs(self.swapchain_images) do
		table.insert(
			self.image_views,
			self.device:CreateImageView(swapchain_image, self.surface_formats[self.config.surface_format_index].format)
		)
	end
end

function Renderer:CreateFramebuffers()
	if not self.render_pass then
		error("Render pass must be created before framebuffers")
	end

	if #self.image_views == 0 then
		error("Image views must be created before framebuffers")
	end

	local extent = self.surface_capabilities[0].currentExtent
	self.framebuffers = {}

	for _, imageView in ipairs(self.image_views) do
		table.insert(
			self.framebuffers,
			self.device:CreateFramebuffer(self.render_pass, imageView.ptr[0], extent.width, extent.height)
		)
	end
end

function Renderer:GetExtent()
	return self.surface_capabilities[0].currentExtent
end

function Renderer:BeginFrame()
	-- Use round-robin frame index
	self.current_frame = (self.current_frame % #self.swapchain_images) + 1
	-- Wait for the fence for this frame FIRST (ensures previous use of this frame's resources is complete)
	self.in_flight_fences[self.current_frame]:Wait()
	-- Acquire next image (after waiting on fence)
	local image_index = self.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

	-- Check if swapchain needs recreation
	if image_index == nil then
		self:RecreateSwapchain()
		return nil
	end

	self.image_index = image_index + 1
	-- Reset and begin command buffer for this frame
	self.command_buffers[self.current_frame]:Reset()
	self.command_buffers[self.current_frame]:Begin()
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
	return self.swapchain_images[self.image_index]
end

function Renderer:GetFramebuffer()
	return self.framebuffers[self.image_index]
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

	-- Recreate swapchain if needed
	if
		not self.swapchain:Present(self.render_finished_semaphores[self.current_frame], self.queue, ffi.new("uint32_t[1]", self.image_index - 1))
	then
		self:RecreateSwapchain()
	end

	return present_status
end

function Renderer:NeedsRecreation()
	-- Check if current extent has changed
	local new_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	local old_extent = self.surface_capabilities[0].currentExtent
	local new_extent = new_capabilities[0].currentExtent
	return old_extent.width ~= new_extent.width or old_extent.height ~= new_extent.height
end

function Renderer:WaitForIdle()
	self.device:WaitIdle()
end

do
	local Pipeline = {}
	Pipeline.__index = Pipeline

	function Pipeline.New(renderer, config)
		local self = setmetatable({}, Pipeline)
		local uniform_buffers = {}

		-- Handle legacy uniform_buffers config
		if config.uniform_buffers then
			for i, uniform_config in ipairs(config.uniform_buffers) do
				uniform_buffers[i] = renderer:CreateBuffer(
					{
						byte_size = uniform_config.byte_size,
						data = uniform_config.initial_data,
						data_type = uniform_config.data_type,
						buffer_usage = "uniform_buffer",
					}
				)
			end
		end

		local renderPass = renderer:CreateRenderPass()
		renderer:CreateImageViews()
		renderer:CreateFramebuffers()
		local layout = {}
		local pool_sizes = {}
		local binding_index = 0

		-- Add storage images to layout
		if config.storage_images then
			for i, img_config in ipairs(config.storage_images) do
				layout[binding_index + 1] = {
					binding = binding_index,
					type = "storage_image",
					stageFlags = img_config.stage,
					count = 1,
				}
				binding_index = binding_index + 1
			end
			table.insert(pool_sizes, {type = "storage_image", count = #config.storage_images})
		end

		-- Add uniform buffers to layout
		if config.uniform_buffers_graphics then
			for i, ub_config in ipairs(config.uniform_buffers_graphics) do
				layout[binding_index + 1] = {
					binding = binding_index,
					type = "uniform_buffer",
					stageFlags = ub_config.stage,
					count = 1,
				}
				binding_index = binding_index + 1
			end
			table.insert(pool_sizes, {type = "uniform_buffer", count = #config.uniform_buffers_graphics})
		elseif config.uniform_buffers then
			for i, ub in ipairs(uniform_buffers) do
				layout[binding_index + 1] = {
					binding = binding_index,
					type = "uniform_buffer",
					stageFlags = config.uniform_buffers[i].stage,
					count = 1,
				}
				binding_index = binding_index + 1
			end
			table.insert(pool_sizes, {type = "uniform_buffer", count = #uniform_buffers})
		end

		local descriptorSetLayout = renderer.device:CreateDescriptorSetLayout(layout)
		local pipelineLayout = renderer.device:CreatePipelineLayout({descriptorSetLayout})
		local descriptorPool = renderer.device:CreateDescriptorPool(pool_sizes, 1)
		local descriptorSet = descriptorPool:AllocateDescriptorSet(descriptorSetLayout)

		-- Update descriptor sets
		binding_index = 0

		-- Bind storage images
		if config.storage_images then
			for i, img_config in ipairs(config.storage_images) do
				renderer.device:UpdateDescriptorSet(
					descriptorSet,
					binding_index,
					img_config.image_view,
					"VK_DESCRIPTOR_TYPE_STORAGE_IMAGE"
				)
				binding_index = binding_index + 1
			end
		end

		-- Bind uniform buffers
		if config.uniform_buffers_graphics then
			for i, ub_config in ipairs(config.uniform_buffers_graphics) do
				renderer.device:UpdateDescriptorSet(descriptorSet, binding_index, ub_config.buffer)
				binding_index = binding_index + 1
			end
		elseif config.uniform_buffers then
			for i, ub in ipairs(uniform_buffers) do
				renderer.device:UpdateDescriptorSet(descriptorSet, binding_index, ub)
				binding_index = binding_index + 1
			end
		end

		local shader_modules = {}

		for i, stage in ipairs(config.shader_stages) do
			shader_modules[i] = {
				type = stage.type,
				module = renderer.device:CreateShaderModule(stage.code, stage.type),
			}
		end

		pipeline = renderer.device:CreateGraphicsPipeline(
			{
				shaderModules = shader_modules,
				extent = config.extent,
				vertexBindings = config.vertex_bindings,
				vertexAttributes = config.vertex_attributes,
				input_assembly = config.input_assembly,
				rasterizer = config.rasterizer,
				viewport = config.viewport,
				scissor = config.scissor,
				multisampling = config.multisampling,
				color_blend = config.color_blend,
			}, {renderPass}, pipelineLayout
		)
		self.pipeline = pipeline
		self.vertex_buffers = config.vertex_buffers
		self.descriptor_sets = {descriptorSet}
		self.pipeline_layout = pipelineLayout
		self.renderer = renderer
		self.config = config
		self.uniform_buffers = uniform_buffers
		self.descriptorSetLayout = descriptorSetLayout
		self.descriptorPool = descriptorPool

		return self
	end

	function Pipeline:UpdateUniformBuffer(index, data)
		if index < 1 or index > #self.uniform_buffers then
			error("Invalid uniform buffer index: " .. index)
		end

		local ub = self.uniform_buffers[index]
		ub:CopyData(data, ub.byte_size)
	end

	function Pipeline:UpdateVertexBuffer(index, data)
		if index < 1 or index > #self.vertex_buffers then
			error("Invalid vertex buffer index: " .. index)
		end

		local vb = self.vertex_buffers[index]
		vb:CopyData(data, vb.byte_size)
	end

	function Renderer:CreatePipeline(...)
		return Pipeline.New(self, ...)
	end

	function Pipeline:BindVertexBuffers(cmd, index)
		cmd:BindVertexBuffers(0, self.vertex_buffers)
	end

	function Pipeline:Bind(cmd)
		local cmd = self.renderer:GetCommandBuffer()
		cmd:BindPipeline(self.pipeline)
		cmd:BindDescriptorSets(self.pipeline_layout, self.descriptor_sets, 0)
	end
end

function Renderer:CreateBuffer(config)
	local byte_size
	local data = config.data

	if data then
		if type(data) == "table" then
			data = ffi.new((config.data_type or "float") .. "[" .. (#data) .. "]", data)
			byte_size = ffi.sizeof(data)
		else
			byte_size = config.byte_size or ffi.sizeof(data)
		end
	end

	local buffer = self.device:CreateBuffer(
		byte_size,
		config.buffer_usage,
		config.memory_property
	)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

return Renderer
