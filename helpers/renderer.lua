local ffi = require("ffi")
local setmetatable = require("helpers.setmetatable_gc")
local vulkan = require("helpers.vulkan")
local Renderer = {}
Renderer.__index = Renderer
table.print = require("helpers.table_print").print
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

function Renderer:CreateRenderPass(samples)
	if self.render_pass then return self.render_pass end

	self.msaa_samples = samples or "1"
	self.render_pass = self.device:CreateRenderPass(self.surface_formats[self.config.surface_format_index], self.msaa_samples)
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

	-- Create MSAA resources if needed
	if self.msaa_samples and self.msaa_samples ~= "1" then
		self:CreateMSAAResources()
	end
end

function Renderer:CreateMSAAResources()
	local extent = self.surface_capabilities[0].currentExtent
	local format = self.surface_formats[self.config.surface_format_index].format

	-- Clean up old MSAA resources if they exist
	if self.msaa_images then
		for _, img in ipairs(self.msaa_images) do

		-- Images are garbage collected automatically
		end
	end

	self.msaa_images = {}
	self.msaa_image_views = {}

	-- Create one MSAA image/view per swapchain image
	for i = 1, #self.swapchain_images do
		local msaa_image = self.device:CreateImage(
			extent.width,
			extent.height,
			format,
			{"color_attachment", "transient_attachment"},
			"device_local",
			self.msaa_samples
		)
		local msaa_image_view = msaa_image:CreateView()
		table.insert(self.msaa_images, msaa_image)
		table.insert(self.msaa_image_views, msaa_image_view)
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

	for i, imageView in ipairs(self.image_views) do
		local msaa_view = nil

		if self.msaa_image_views and #self.msaa_image_views > 0 then
			msaa_view = self.msaa_image_views[i].ptr[0]
		end

		table.insert(
			self.framebuffers,
			self.device:CreateFramebuffer(self.render_pass, imageView.ptr[0], extent.width, extent.height, msaa_view)
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
		-- Extract sample count from multisampling config
		local samples = "1"

		if config.multisampling and config.multisampling.rasterization_samples then
			samples = config.multisampling.rasterization_samples
		end

		local renderPass = renderer:CreateRenderPass(samples)
		renderer:CreateImageViews()
		renderer:CreateFramebuffers()
		local layout = {}
		local pool_sizes = {}

		if config.descriptor_sets then
			local counts = {}

			for i, ds in ipairs(config.descriptor_sets) do
				layout[i] = {
					binding_index = ds.binding_index,
					type = ds.type,
					stageFlags = ds.stage,
					count = 1,
				}
				counts[ds.type] = (counts[ds.type] or 0) + 1

				if ds.type == "uniform_buffer" then
					uniform_buffers[ds.binding_index] = ds.args[1]
				end
			end

			for type, count in pairs(counts) do
				table.insert(pool_sizes, {type = type, count = count})
			end
		end

		local descriptorSetLayout = renderer.device:CreateDescriptorSetLayout(layout)
		local pipelineLayout = renderer.device:CreatePipelineLayout({descriptorSetLayout})
		local descriptorPool = renderer.device:CreateDescriptorPool(pool_sizes, 1)
		local descriptorSet = descriptorPool:AllocateDescriptorSet(descriptorSetLayout)

		-- Update descriptor sets
		if config.descriptor_sets then
			for i, ds in ipairs(config.descriptor_sets) do
				renderer.device:UpdateDescriptorSet(ds.type, descriptorSet, ds.binding_index, unpack(ds.args))
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
				dynamic_states = config.dynamic_states,
			},
			{renderPass},
			pipelineLayout
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

	function Pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
		self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
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
		cmd:BindPipeline(self.pipeline, "graphics")
		cmd:BindDescriptorSets("graphics", self.pipeline_layout, self.descriptor_sets, 0)
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

	local buffer = self.device:CreateBuffer(byte_size, config.buffer_usage, config.memory_property)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function Renderer:UploadToImage(image, data, width, height)
	local pixel_count = width * height
	-- Create staging buffer
	local staging_buffer = self.device:CreateBuffer(pixel_count * 4, "transfer_src", {"host_visible", "host_coherent"})
	staging_buffer:CopyData(data, pixel_count * 4)
	-- Copy to image using command buffer
	local cmd_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	local cmd = cmd_pool:CreateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, image, width, height)
	-- Transition to general layout for compute
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "compute",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_dst_optimal",
					newLayout = "general",
				},
			},
		}
	)
	cmd:End()
	-- Submit and wait
	local fence = self.device:CreateFence()
	self.queue:SubmitAndWait(self.device, cmd, fence)
end

do
	local ComputePipeline = {}
	ComputePipeline.__index = ComputePipeline

	function ComputePipeline.New(renderer, config)
		local self = setmetatable({}, ComputePipeline)
		self.renderer = renderer
		self.config = config
		self.current_image_index = 1
		-- Create shader module
		local shader = renderer.device:CreateShaderModule(config.shader, "compute")
		-- Create descriptor set layout
		local descriptor_set_layout = renderer.device:CreateDescriptorSetLayout(config.descriptor_layout)
		local pipeline_layout = renderer.device:CreatePipelineLayout({descriptor_set_layout})
		-- Create compute pipeline
		local pipeline = renderer.device:CreateComputePipeline(shader, pipeline_layout)
		-- Determine number of descriptor sets (for ping-pong or single set)
		local descriptor_set_count = config.descriptor_set_count or 1
		-- Create descriptor pool
		local descriptor_pool = renderer.device:CreateDescriptorPool(config.descriptor_pool, descriptor_set_count)
		-- Create descriptor sets
		local descriptor_sets = {}

		for i = 1, descriptor_set_count do
			descriptor_sets[i] = descriptor_pool:AllocateDescriptorSet(descriptor_set_layout)
		end

		self.shader = shader
		self.pipeline = pipeline
		self.pipeline_layout = pipeline_layout
		self.descriptor_set_layout = descriptor_set_layout
		self.descriptor_pool = descriptor_pool
		self.descriptor_sets = descriptor_sets
		self.workgroup_size = config.workgroup_size or 16
		return self
	end

	function ComputePipeline:UpdateDescriptorSet(type, index, binding_index, ...)
		self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
	end

	function ComputePipeline:Dispatch(cmd)
		-- Bind compute pipeline
		cmd:BindPipeline(self.pipeline, "compute")
		cmd:BindDescriptorSets(
			"compute",
			self.pipeline_layout,
			{self.descriptor_sets[self.current_image_index]},
			0
		)
		local extent = self.renderer:GetExtent()
		local w = tonumber(extent.width)
		local h = tonumber(extent.height)
		-- Dispatch compute shader
		local group_count_x = math.ceil(w / self.workgroup_size)
		local group_count_y = math.ceil(h / self.workgroup_size)
		cmd:Dispatch(group_count_x, group_count_y, 1)
	end

	function ComputePipeline:SwapImages()
		-- Swap images for next frame (useful for ping-pong patterns)
		self.current_image_index = (self.current_image_index % #self.descriptor_sets) + 1
	end

	function Renderer:CreateComputePipeline(...)
		return ComputePipeline.New(self, ...)
	end
end

return Renderer
