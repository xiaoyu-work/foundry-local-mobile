// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Android device detection.
//
// Everything here is read from the NDK and /proc rather than through JNI, so the core
// stays usable from a pure-native context (a Flutter isolate, a background service)
// without needing a JNIEnv. The exceptions are thermal state and network metering, which
// have no NDK equivalent; the Kotlin binding observes them and pushes updates down.

#include "../device_profile.h"

#if defined(__ANDROID__)

#include <sys/statvfs.h>
#include <sys/system_properties.h>
#include <sys/sysinfo.h>
#include <unistd.h>

#include <fstream>
#include <string>

namespace flm {
namespace platform {
namespace {

std::string GetSystemProperty(const char* name) {
  char value[PROP_VALUE_MAX] = {};
  const int length = __system_property_get(name, value);
  return length > 0 ? std::string(value, static_cast<size_t>(length)) : std::string();
}

/// Available memory from /proc/meminfo. sysinfo().freeram excludes reclaimable page
/// cache, so it dramatically understates what a large allocation can actually get.
int64_t ReadAvailableMemoryBytes() {
  std::ifstream meminfo("/proc/meminfo");
  std::string key;
  int64_t value_kb = 0;
  std::string unit;
  while (meminfo >> key >> value_kb >> unit) {
    if (key == "MemAvailable:") {
      return value_kb * 1024;
    }
  }
  return 0;
}

/// Qualcomm Hexagon DSP architecture, which QNN variants are compiled against. A context
/// binary built for v75 will not load on a v68 device, so this feeds the compatibility
/// string used for model-package variant matching.
std::string DetectHexagonArch(const std::string& soc_model) {
  const std::string hardware = GetSystemProperty("ro.hardware");
  const std::string board = GetSystemProperty("ro.board.platform");

  struct Mapping {
    const char* board_prefix;
    const char* dsp_arch;
  };
  // Newest first, because prefixes overlap.
  static constexpr Mapping kMappings[] = {
      {"sun", "v79"},        // Snapdragon 8 Elite
      {"pineapple", "v75"},  // Snapdragon 8 Gen 3
      {"kalama", "v73"},     // Snapdragon 8 Gen 2
      {"taro", "v69"},       // Snapdragon 8 Gen 1
      {"lahaina", "v68"},    // Snapdragon 888
  };
  for (const auto& mapping : kMappings) {
    if (board.rfind(mapping.board_prefix, 0) == 0 || hardware.rfind(mapping.board_prefix, 0) == 0 ||
        soc_model.find(mapping.board_prefix) != std::string::npos) {
      return mapping.dsp_arch;
    }
  }
  return {};
}

bool HasQualcommNpu() {
  // Probing for the vendor QNN libraries is more reliable than an SoC allow-list, which
  // goes stale with every new chip.
  static constexpr const char* kQnnLibraries[] = {
      "/vendor/lib64/libQnnHtp.so",
      "/vendor/lib64/libcdsprpc.so",
  };
  for (const char* path : kQnnLibraries) {
    if (::access(path, F_OK) == 0) {
      return true;
    }
  }
  return false;
}

}  // namespace

void FillStaticInfo(DeviceProfile& profile) {
  profile.platform = "android";
  profile.os_version = GetSystemProperty("ro.build.version.release");
  profile.device_model = GetSystemProperty("ro.product.model");
  profile.soc = GetSystemProperty("ro.soc.model");
  if (profile.soc.empty()) {
    profile.soc = GetSystemProperty("ro.board.platform");
  }
  const std::string manufacturer = GetSystemProperty("ro.soc.manufacturer");
  if (!manufacturer.empty() && profile.soc.find(manufacturer) == std::string::npos) {
    profile.soc = manufacturer + " " + profile.soc;
  }

#if defined(__aarch64__)
  profile.abi = "arm64-v8a";
#elif defined(__arm__)
  profile.abi = "armeabi-v7a";
#elif defined(__x86_64__)
  profile.abi = "x86_64";
#else
  profile.abi = "unknown";
#endif

  profile.cpu_cores = static_cast<int>(::sysconf(_SC_NPROCESSORS_CONF));

  struct sysinfo info = {};
  if (::sysinfo(&info) == 0) {
    profile.total_memory_bytes = static_cast<int64_t>(info.totalram) * info.mem_unit;
  }

  profile.has_npu = HasQualcommNpu();
  // Every Android device has a GPU; whether ORT can use it is decided by EP
  // registration, not by hardware presence.
  profile.has_gpu = true;
}

void FillDynamicInfo(DeviceProfile& profile) {
  profile.available_memory_bytes = ReadAvailableMemoryBytes();

  struct statvfs stats = {};
  if (::statvfs("/data", &stats) == 0) {
    profile.available_storage_bytes = static_cast<int64_t>(stats.f_bavail) * stats.f_frsize;
  }
}

void FillExecutionProviders(DeviceProfile& profile) {
  profile.execution_providers.clear();

  if (profile.has_npu) {
    ExecutionProviderInfo qnn;
    qnn.name = "QNN";
    qnn.device = FLM_DEVICE_NPU;
    qnn.available = true;
    qnn.priority = 0;  // Fastest and most power-efficient placement when the model fits.
    const std::string dsp_arch = DetectHexagonArch(profile.soc);
    if (!dsp_arch.empty()) {
      qnn.compatibility_string = "dsp_arch=" + dsp_arch;
      qnn.attributes["dsp_arch"] = dsp_arch;
    }
    qnn.attributes["soc"] = profile.soc;
    profile.execution_providers.push_back(std::move(qnn));
  }

  ExecutionProviderInfo xnnpack;
  xnnpack.name = "XNNPACK";
  xnnpack.device = FLM_DEVICE_CPU;
  xnnpack.available = true;
  xnnpack.priority = 20;  // The fast CPU path on ARM; always available.
  profile.execution_providers.push_back(std::move(xnnpack));

  ExecutionProviderInfo cpu;
  cpu.name = "CPU";
  cpu.device = FLM_DEVICE_CPU;
  cpu.available = true;
  cpu.priority = 30;  // Universal fallback, always last.
  profile.execution_providers.push_back(std::move(cpu));
}

}  // namespace platform
}  // namespace flm

#endif  // defined(__ANDROID__)
