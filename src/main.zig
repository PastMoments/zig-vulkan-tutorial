const std = @import("std");
const builtin = @import("builtin");
// We seperate the vulkan and glfw imports to make it clear which one we are using
const vulkan = @cImport({
    @cInclude("vulkan/vulkan.h");
});
const glfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});

const validationLayers = .{ // TODO: fix validation layers
    "VK_LAYER_LUNARG_api_dump",
    "VK_LAYER_LUNARG_monitor",
    "VK_LAYER_LUNARG_screenshot",
    "VK_LAYER_KHRONOS_validation",
};

const QueueFamilyIndices = struct { // TODO: just make the entire struct optional instead, so we can do proper checking if every family exists
    graphicsFamily: ?u32,
};

fn findQueueFamilies(allocator: std.mem.Allocator, physicalDevice: vulkan.VkPhysicalDevice) !QueueFamilyIndices {
    var queueFamilyIndices = QueueFamilyIndices{ .graphicsFamily = null };

    var queueFamilyCount: u32 = 0;
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, null);
    var queueFamilies = try allocator.alloc(vulkan.VkQueueFamilyProperties, queueFamilyCount);
    defer allocator.free(queueFamilies);
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, queueFamilies[0..].ptr);

    for (queueFamilies, 0..) |queueFamily, i| {
        if (queueFamily.queueFlags & vulkan.VK_QUEUE_GRAPHICS_BIT != 0) {
            queueFamilyIndices.graphicsFamily = @intCast(u32, i);
        }
    }
    return queueFamilyIndices;
}

pub fn main() !void {
    // set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // glfw init
    if (glfw.glfwInit() != glfw.GLFW_TRUE) return error.GlfwInitFailed;
    defer glfw.glfwTerminate();

    // window creation
    var window: ?*glfw.GLFWwindow = createWindow: {
        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API); // Disable OpenGL context
        glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE); // Disable resizing window (for now)
        var window = glfw.glfwCreateWindow(800, 600, "Vulkan window", null, null);
        if (window == null) return error.GlfwCreateWindowFailed;
        break :createWindow window;
    };
    defer glfw.glfwDestroyWindow(window);

    //var extensionCount: u32 = 0;
    //_ = vulkan.vkEnumerateInstanceExtensionProperties(null, &extensionCount, null);
    //std.debug.print("{} extensions supported\n", .{extensionCount});

    // instance creation
    var instance: vulkan.VkInstance = createInstance: {
        // Instance Info
        var appInfo = vulkan.VkApplicationInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Hello Triangle",
            .applicationVersion = vulkan.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = vulkan.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vulkan.VK_API_VERSION_1_0,
            .pNext = null,
        };

        var createInfo = vulkan.VkInstanceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &appInfo,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = undefined,
            .pNext = null,
            .flags = 0,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
        };
        createInfo.ppEnabledExtensionNames = glfw.glfwGetRequiredInstanceExtensions(&createInfo.enabledExtensionCount);

        // Validation layers
        if (builtin.mode == .Debug) {
            var layerCount: u32 = undefined;
            if (vulkan.vkEnumerateInstanceLayerProperties(&layerCount, null) != vulkan.VK_SUCCESS) return error.VulkanEnumerateLayersFailed;

            var availableLayers = try allocator.alloc(vulkan.VkLayerProperties, layerCount);
            defer allocator.free(availableLayers);
            if (vulkan.vkEnumerateInstanceLayerProperties(&layerCount, @ptrCast([*c]vulkan.VkLayerProperties, availableLayers)) != vulkan.VK_SUCCESS)
                return error.VulkanEnumerateLayersFailed;

            for (availableLayers) |*layerProperties| {
                std.debug.print("available validation layer     {s}\n", .{layerProperties.layerName});
            }
            // check validation layers
            inline for (validationLayers) |desiredLayer| {
                for (availableLayers) |layerProperties| {
                    // we get C string as array of set size, need find null terminal and convert to proper slice
                    const layerName = std.mem.sliceTo(@ptrCast([*:0]const u8, &layerProperties.layerName), 0);
                    if (std.mem.eql(u8, layerName, desiredLayer)) {
                        std.debug.print("found desired validation layer {s}\n", .{layerName});
                        break;
                    }
                } else {
                    std.debug.print("can't find desired validation layer {s}\n", .{desiredLayer});
                    return error.VulkanValidationLayerMissing;
                }
            }
            createInfo.enabledLayerCount = validationLayers.len;
            createInfo.ppEnabledLayerNames = @as([]const [*:0]const u8, &validationLayers).ptr;
        }
        // end validation layers

        var instance: vulkan.VkInstance = undefined;
        if (vulkan.vkCreateInstance(&createInfo, null, &instance) != vulkan.VK_SUCCESS) return error.VulkanCreateInstanceFailed;
        break :createInstance instance;
    };
    defer vulkan.vkDestroyInstance(instance, null);

    // pick physical device
    var physicalDevice: vulkan.VkPhysicalDevice = pickPhysicalDevice: {
        var deviceCount: u32 = 0;
        _ = vulkan.vkEnumeratePhysicalDevices(instance, &deviceCount, null);
        if (deviceCount == 0) return error.VulkanNoGpuDeviceFound;

        var availableDevices = try allocator.alloc(vulkan.VkPhysicalDevice, deviceCount);
        defer allocator.free(availableDevices);
        if (vulkan.vkEnumeratePhysicalDevices(instance, &deviceCount, availableDevices[0..].ptr) != vulkan.VK_SUCCESS)
            return error.VulkanEnumeratePhysicalDevicesFailed;
        for (availableDevices) |device| { // check if devices are valid, and pick a valid one
            var deviceProperties = getDeviceProperties: {
                var deviceProperties: vulkan.VkPhysicalDeviceProperties = undefined;
                vulkan.vkGetPhysicalDeviceProperties(device, &deviceProperties);
                break :getDeviceProperties deviceProperties;
            };
            var deviceFeatures = getDeviceFeatures: {
                var deviceFeatures: vulkan.VkPhysicalDeviceFeatures = undefined;
                vulkan.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);
                break :getDeviceFeatures deviceFeatures;
            };
            var queueFamilyIndices = try findQueueFamilies(allocator, device);

            // TODO; add more criteria for devices
            _ = deviceFeatures;
            if (deviceProperties.deviceType == vulkan.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and
                queueFamilyIndices.graphicsFamily != null)
            {
                break :pickPhysicalDevice device;
            }
        } else {
            return error.VulkanNoPhysicalDevicesSuitable;
        }
    };

    var queueFamilyIndices = try findQueueFamilies(allocator, physicalDevice);

    // logical device creation
    var logicalDevice: vulkan.VkDevice = createLogicalDevice: {
        var logicalDevice: vulkan.VkDevice = undefined;
        const queueCount = 1; // This is the number of queues to create in the family
        var queuePriorities: [queueCount]f32 = .{1.0};
        var queueCreateInfo = vulkan.VkDeviceQueueCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueCount = queueCount,
            .pQueuePriorities = &queuePriorities,
            .queueFamilyIndex = queueFamilyIndices.graphicsFamily.?,
            .flags = 0,
            .pNext = null,
        };

        // TODO: set proper flags for this
        var deviceFeatures = vulkan.VkPhysicalDeviceFeatures{
            .robustBufferAccess = vulkan.VK_FALSE,
            .fullDrawIndexUint32 = vulkan.VK_FALSE,
            .imageCubeArray = vulkan.VK_FALSE,
            .independentBlend = vulkan.VK_FALSE,
            .geometryShader = vulkan.VK_FALSE,
            .tessellationShader = vulkan.VK_FALSE,
            .sampleRateShading = vulkan.VK_FALSE,
            .dualSrcBlend = vulkan.VK_FALSE,
            .logicOp = vulkan.VK_FALSE,
            .multiDrawIndirect = vulkan.VK_FALSE,
            .drawIndirectFirstInstance = vulkan.VK_FALSE,
            .depthClamp = vulkan.VK_FALSE,
            .depthBiasClamp = vulkan.VK_FALSE,
            .fillModeNonSolid = vulkan.VK_FALSE,
            .depthBounds = vulkan.VK_FALSE,
            .wideLines = vulkan.VK_FALSE,
            .largePoints = vulkan.VK_FALSE,
            .alphaToOne = vulkan.VK_FALSE,
            .multiViewport = vulkan.VK_FALSE,
            .samplerAnisotropy = vulkan.VK_FALSE,
            .textureCompressionETC2 = vulkan.VK_FALSE,
            .textureCompressionASTC_LDR = vulkan.VK_FALSE,
            .textureCompressionBC = vulkan.VK_FALSE,
            .occlusionQueryPrecise = vulkan.VK_FALSE,
            .pipelineStatisticsQuery = vulkan.VK_FALSE,
            .vertexPipelineStoresAndAtomics = vulkan.VK_FALSE,
            .fragmentStoresAndAtomics = vulkan.VK_FALSE,
            .shaderTessellationAndGeometryPointSize = vulkan.VK_FALSE,
            .shaderImageGatherExtended = vulkan.VK_FALSE,
            .shaderStorageImageExtendedFormats = vulkan.VK_FALSE,
            .shaderStorageImageMultisample = vulkan.VK_FALSE,
            .shaderStorageImageReadWithoutFormat = vulkan.VK_FALSE,
            .shaderStorageImageWriteWithoutFormat = vulkan.VK_FALSE,
            .shaderUniformBufferArrayDynamicIndexing = vulkan.VK_FALSE,
            .shaderSampledImageArrayDynamicIndexing = vulkan.VK_FALSE,
            .shaderStorageBufferArrayDynamicIndexing = vulkan.VK_FALSE,
            .shaderStorageImageArrayDynamicIndexing = vulkan.VK_FALSE,
            .shaderClipDistance = vulkan.VK_FALSE,
            .shaderCullDistance = vulkan.VK_FALSE,
            .shaderFloat64 = vulkan.VK_FALSE,
            .shaderInt64 = vulkan.VK_FALSE,
            .shaderInt16 = vulkan.VK_FALSE,
            .shaderResourceResidency = vulkan.VK_FALSE,
            .shaderResourceMinLod = vulkan.VK_FALSE,
            .sparseBinding = vulkan.VK_FALSE,
            .sparseResidencyBuffer = vulkan.VK_FALSE,
            .sparseResidencyImage2D = vulkan.VK_FALSE,
            .sparseResidencyImage3D = vulkan.VK_FALSE,
            .sparseResidency2Samples = vulkan.VK_FALSE,
            .sparseResidency4Samples = vulkan.VK_FALSE,
            .sparseResidency8Samples = vulkan.VK_FALSE,
            .sparseResidency16Samples = vulkan.VK_FALSE,
            .sparseResidencyAliased = vulkan.VK_FALSE,
            .variableMultisampleRate = vulkan.VK_FALSE,
            .inheritedQueries = vulkan.VK_FALSE,
        };

        // TODO: Logical device and queries -> Creating the logical device
        var createInfo = vulkan.VkDeviceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = &queueCreateInfo,
            .queueCreateInfoCount = 1, // TODO: find size programmatically?
            .pEnabledFeatures = &deviceFeatures,
            .ppEnabledExtensionNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledLayerNames = null,
            .enabledLayerCount = 0,
            .pNext = null,
            .flags = 0,
        };
        if (builtin.mode == .Debug) { // Only for older implementations of vulkan, newer ones don't have device specific validation layers
            createInfo.enabledLayerCount = validationLayers.len;
            createInfo.ppEnabledLayerNames = @as([]const [*:0]const u8, &validationLayers).ptr;
        }
        if (vulkan.vkCreateDevice(physicalDevice, &createInfo, null, &logicalDevice) != vulkan.VK_SUCCESS) return error.VulkanCreateLogicalDeviceFailed;
        break :createLogicalDevice logicalDevice;
    };
    defer vulkan.vkDestroyDevice(logicalDevice, null);

    // queue handles
    var graphicsQueue: vulkan.VkQueue = getGraphicsQueue: {
        var graphicsQueue: vulkan.VkQueue = undefined;
        vulkan.vkGetDeviceQueue(logicalDevice, queueFamilyIndices.graphicsFamily.?, 0, &graphicsQueue);
        break :getGraphicsQueue graphicsQueue;
    };
    _ = graphicsQueue;

    // main loop
    while (glfw.glfwWindowShouldClose(window) == 0) {
        glfw.glfwPollEvents();
    }
}
