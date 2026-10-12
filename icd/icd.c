#include <string.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_icd.h>
#include <hardware/hardware.h>
#include <hardware/hwvulkan.h>

static hwvulkan_device_t *g_hal;

static int hal_open(void) {
  if (g_hal) return 0;
  const hw_module_t *m;
  hw_device_t *d;
  if (hw_get_module(HWVULKAN_HARDWARE_MODULE_ID, &m)) return -1;
  if (m->methods->open(m, HWVULKAN_DEVICE_0, &d)) return -1;
  g_hal = (hwvulkan_device_t *)d;
  return 0;
}

VKAPI_ATTR VkResult VKAPI_CALL
vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *v) {
  if (*v > 5) *v = 5;
  return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
icd_CreateInstance(const VkInstanceCreateInfo *ci,
                   const VkAllocationCallbacks *a, VkInstance *out) {
  if (hal_open()) return VK_ERROR_INITIALIZATION_FAILED;
  return g_hal->CreateInstance(ci, a, out);
}

static VKAPI_ATTR VkResult VKAPI_CALL
icd_EnumInstExt(const char *layer, uint32_t *n, VkExtensionProperties *p) {
  if (hal_open()) return VK_ERROR_INITIALIZATION_FAILED;
  return g_hal->EnumerateInstanceExtensionProperties(layer, n, p);
}

static VKAPI_ATTR VkResult VKAPI_CALL icd_EnumInstVer(uint32_t *v) {
  *v = VK_API_VERSION_1_1;
  return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vk_icdGetInstanceProcAddr(VkInstance i, const char *name) {
  if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)icd_CreateInstance;
  if (!strcmp(name, "vkEnumerateInstanceExtensionProperties")) return (PFN_vkVoidFunction)icd_EnumInstExt;
  if (!strcmp(name, "vkEnumerateInstanceVersion")) return (PFN_vkVoidFunction)icd_EnumInstVer;
  if (hal_open()) return NULL;
  return (PFN_vkVoidFunction)g_hal->GetInstanceProcAddr(i, name);
}
