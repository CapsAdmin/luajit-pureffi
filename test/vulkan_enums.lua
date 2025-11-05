local enum_translator = require("helpers.enum_translator")
local vk = require("vk")

local VkSubgroupFeatureFlagBits = enum_translator(vk.VkSubgroupFeatureFlagBits, "VK_SUBGROUP_FEATURE_", {"_BIT"})

print(VkSubgroupFeatureFlagBits.translate({"arithmetic", "ballot"}))