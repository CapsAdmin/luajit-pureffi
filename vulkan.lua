local ffi = require("ffi")

local function try_load(tbl)
    local errors = {}
    for _, name in ipairs(tbl) do
        local status, lib = pcall(ffi.load, name)
        if status then
            return lib
        else
            table.insert(errors, lib)
        end
    end
    return nil, table.concat(errors, "\n")
end

local function load_library()
    if ffi.os == "Windows" then
        return assert(try_load({"vulkan-1.dll"}))
    elseif ffi.os == "OSX" then
        -- Try user's home directory first (expand ~ manually)
        local home = os.getenv("HOME")
        local vulkan_sdk = os.getenv("VULKAN_SDK")
        
        local paths = {}
        
        -- Try VULKAN_SDK environment variable first
        if vulkan_sdk then
            table.insert(paths, vulkan_sdk .. "/lib/libvulkan.dylib")
            table.insert(paths, vulkan_sdk .. "/lib/libMoltenVK.dylib")
        end
        
        -- Try common VulkanSDK installation paths
        if home then
            table.insert(paths, home .. "/VulkanSDK/1.4.328.1/macOS/lib/libvulkan.dylib")
            table.insert(paths, home .. "/VulkanSDK/1.4.328.1/macOS/lib/libMoltenVK.dylib")
        end
        
        -- Try standard locations
        table.insert(paths, "libvulkan.dylib")
        table.insert(paths, "libvulkan.1.dylib")
        table.insert(paths, "/usr/local/lib/libvulkan.dylib")
        table.insert(paths, "libMoltenVK.dylib")
        
        return assert(try_load(paths))
    end

    return assert(try_load({"libvulkan.so", "libvulkan.so.1"}))
end

local lib = load_library()
print("Successfully loaded Vulkan!")