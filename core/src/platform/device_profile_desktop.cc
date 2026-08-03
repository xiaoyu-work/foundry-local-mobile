// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Desktop device detection (Linux, Windows).
//
// Not a shipping target for this SDK, but it keeps the core buildable and testable on a
// developer machine and on CI without an emulator or a device — which is the difference
// between a fast inner loop and a slow one.

#include "../device_profile.h"

#if !defined(__ANDROID__) && !defined(__APPLE__)

#include <thread>

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/statvfs.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <fstream>
#endif

namespace flm {
namespace platform {

void FillStaticInfo(DeviceProfile& profile) {
#if defined(_WIN32)
  profile.platform = "windows";
  MEMORYSTATUSEX status = {};
  status.dwLength = sizeof(status);
  if (::GlobalMemoryStatusEx(&status)) {
    profile.total_memory_bytes = static_cast<int64_t>(status.ullTotalPhys);
  }
#else
  profile.platform = "linux";
  struct utsname info = {};
  if (::uname(&info) == 0) {
    profile.os_version = info.release;
    profile.device_model = info.machine;
  }
  struct sysinfo sys = {};
  if (::sysinfo(&sys) == 0) {
    profile.total_memory_bytes = static_cast<int64_t>(sys.totalram) * sys.mem_unit;
  }
#endif

#if defined(__aarch64__)
  profile.abi = "arm64";
#elif defined(__x86_64__)
  profile.abi = "x86_64";
#else
  profile.abi = "unknown";
#endif

  profile.cpu_cores = static_cast<int>(std::thread::hardware_concurrency());
  profile.has_npu = false;
  profile.has_gpu = false;
}

void FillDynamicInfo(DeviceProfile& profile) {
#if defined(_WIN32)
  MEMORYSTATUSEX status = {};
  status.dwLength = sizeof(status);
  if (::GlobalMemoryStatusEx(&status)) {
    profile.available_memory_bytes = static_cast<int64_t>(status.ullAvailPhys);
  }
  ULARGE_INTEGER free_bytes = {};
  if (::GetDiskFreeSpaceExA(nullptr, &free_bytes, nullptr, nullptr)) {
    profile.available_storage_bytes = static_cast<int64_t>(free_bytes.QuadPart);
  }
#else
  std::ifstream meminfo("/proc/meminfo");
  std::string key;
  int64_t value_kb = 0;
  std::string unit;
  while (meminfo >> key >> value_kb >> unit) {
    if (key == "MemAvailable:") {
      profile.available_memory_bytes = value_kb * 1024;
      break;
    }
  }
  struct statvfs stats = {};
  if (::statvfs(".", &stats) == 0) {
    profile.available_storage_bytes = static_cast<int64_t>(stats.f_bavail) * stats.f_frsize;
  }
#endif
  profile.network = NetworkState::kUnmetered;
}

void FillExecutionProviders(DeviceProfile& profile) {
  profile.execution_providers.clear();

  ExecutionProviderInfo cpu;
  cpu.name = "CPU";
  cpu.device = FLM_DEVICE_CPU;
  cpu.available = true;
  cpu.priority = 30;
  profile.execution_providers.push_back(std::move(cpu));
}

}  // namespace platform
}  // namespace flm

#endif  // !defined(__ANDROID__) && !defined(__APPLE__)
