// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Apple (iOS / iPadOS / macOS) device detection.
//
// Uses sysctl and mach APIs only, so this compiles as plain C++ and needs no
// Objective-C runtime. Thermal state and low-power mode do require Foundation, so the
// Swift binding observes NSProcessInfo and pushes them down through
// flm_manager_notify_lifecycle.

#include "../device_profile.h"

#if defined(__APPLE__)

#include <TargetConditionals.h>
#include <mach/mach.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#include <string>

namespace flm {
namespace platform {
namespace {

std::string SysctlString(const char* name) {
  size_t size = 0;
  if (::sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0) {
    return {};
  }
  std::string value(size, '\0');
  if (::sysctlbyname(name, value.data(), &size, nullptr, 0) != 0) {
    return {};
  }
  if (!value.empty() && value.back() == '\0') {
    value.pop_back();
  }
  return value;
}

int64_t SysctlInt64(const char* name) {
  int64_t value = 0;
  size_t size = sizeof(value);
  if (::sysctlbyname(name, &value, &size, nullptr, 0) == 0) {
    return value;
  }
  // Some keys are 32-bit; retry narrowly rather than reporting zero.
  int32_t value32 = 0;
  size = sizeof(value32);
  if (::sysctlbyname(name, &value32, &size, nullptr, 0) == 0) {
    return value32;
  }
  return 0;
}

/// Memory the process could still allocate.
///
/// On iOS "free memory" is close to meaningless — the OS keeps RAM full of reclaimable
/// pages and enforces a *per-process* jetsam limit far below total RAM. What matters is
/// how much of that per-process budget is left, so we derive the budget from total RAM
/// (roughly half on modern devices) and subtract what we already use.
int64_t EstimateAvailableMemoryBytes(int64_t total_memory_bytes) {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (::task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
    return total_memory_bytes / 4;
  }

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  // `limit_bytes_remaining` is the actual jetsam headroom when the kernel reports it.
  if (info.limit_bytes_remaining != 0 && info.limit_bytes_remaining != UINT64_MAX) {
    return static_cast<int64_t>(info.limit_bytes_remaining);
  }
  const int64_t process_budget = total_memory_bytes / 2;
#else
  const int64_t process_budget = total_memory_bytes;
#endif

  const auto footprint = static_cast<int64_t>(info.phys_footprint);
  const int64_t remaining = process_budget - footprint;
  return remaining > 0 ? remaining : 0;
}

/// Apple Neural Engine availability. Every A11+ and M-series chip has one, and CoreML
/// falls back silently when it does not, so this only needs to exclude the simulator and
/// pre-A11 hardware.
bool HasNeuralEngine() {
#if TARGET_OS_SIMULATOR
  return false;  // The simulator has no ANE; CoreML runs on the host CPU.
#elif TARGET_OS_IPHONE
  // arm64 iOS devices supported by current OS versions are all A12 or newer.
  return true;
#else
  // Apple silicon Macs have an ANE; Intel Macs do not.
  return SysctlString("machdep.cpu.brand_string").find("Apple") != std::string::npos;
#endif
}

}  // namespace

void FillStaticInfo(DeviceProfile& profile) {
#if TARGET_OS_IPHONE
  profile.platform = "ios";
#else
  profile.platform = "macos";
#endif

  profile.os_version = SysctlString("kern.osproductversion");
  if (profile.os_version.empty()) {
    profile.os_version = SysctlString("kern.osrelease");
  }

  // hw.machine is the model identifier ("iPhone16,2") on iOS but the CPU architecture on
  // macOS, where hw.model holds the identifier instead.
#if TARGET_OS_IPHONE
  profile.device_model = SysctlString("hw.machine");
#else
  profile.device_model = SysctlString("hw.model");
#endif

  profile.soc = SysctlString("machdep.cpu.brand_string");
  if (profile.soc.empty()) {
    profile.soc = profile.device_model;
  }

#if defined(__aarch64__) || defined(__arm64__)
  profile.abi = "arm64";
#elif defined(__x86_64__)
  profile.abi = "x86_64";
#else
  profile.abi = "unknown";
#endif

  profile.cpu_cores = static_cast<int>(SysctlInt64("hw.ncpu"));
  profile.total_memory_bytes = SysctlInt64("hw.memsize");
  profile.has_npu = HasNeuralEngine();
  profile.has_gpu = true;
}

void FillDynamicInfo(DeviceProfile& profile) {
  profile.available_memory_bytes = EstimateAvailableMemoryBytes(profile.total_memory_bytes);

  struct statfs stats = {};
  if (::statfs("/", &stats) == 0) {
    profile.available_storage_bytes = static_cast<int64_t>(stats.f_bavail) * stats.f_bsize;
  }
}

void FillExecutionProviders(DeviceProfile& profile) {
  profile.execution_providers.clear();

  if (profile.has_npu) {
    ExecutionProviderInfo coreml;
    coreml.name = "CoreML";
    coreml.device = FLM_DEVICE_NPU;
    coreml.available = true;
    coreml.priority = 0;
    coreml.attributes["soc"] = profile.soc;
    // CoreML decides ANE vs GPU vs CPU placement itself at compile time; we only express
    // the preference.
    coreml.attributes["compute_units"] = "all";
    profile.execution_providers.push_back(std::move(coreml));
  }

  ExecutionProviderInfo xnnpack;
  xnnpack.name = "XNNPACK";
  xnnpack.device = FLM_DEVICE_CPU;
  xnnpack.available = true;
  xnnpack.priority = 20;
  profile.execution_providers.push_back(std::move(xnnpack));

  ExecutionProviderInfo cpu;
  cpu.name = "CPU";
  cpu.device = FLM_DEVICE_CPU;
  cpu.available = true;
  cpu.priority = 30;
  profile.execution_providers.push_back(std::move(cpu));
}

}  // namespace platform
}  // namespace flm

#endif  // defined(__APPLE__)
