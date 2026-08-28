// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "device_profile.h"

#include <algorithm>
#include <cctype>
#include <mutex>

namespace flm {
namespace {

std::mutex g_profile_mutex;
DeviceProfile g_profile;
bool g_static_initialized = false;

// Fraction of *available* memory a model may occupy. Mobile OSes kill the largest
// consumer first, and inference needs headroom for the KV cache on top of the weights,
// so we stay well clear of the limit rather than optimistically filling RAM.
constexpr double kMemoryBudgetFraction = 0.45;

}  // namespace

const char* ToString(ThermalState state) noexcept {
  switch (state) {
    case ThermalState::kNominal: return "nominal";
    case ThermalState::kFair: return "fair";
    case ThermalState::kSerious: return "serious";
    case ThermalState::kCritical: return "critical";
  }
  return "nominal";
}

const char* ToString(flm_device device) noexcept {
  switch (device) {
    case FLM_DEVICE_CPU: return "cpu";
    case FLM_DEVICE_GPU: return "gpu";
    case FLM_DEVICE_NPU: return "npu";
    case FLM_DEVICE_UNKNOWN: return "unknown";
  }
  return "unknown";
}

flm_device DeviceFromString(const std::string& value) noexcept {
  if (value == "cpu") return FLM_DEVICE_CPU;
  if (value == "gpu") return FLM_DEVICE_GPU;
  if (value == "npu") return FLM_DEVICE_NPU;
  return FLM_DEVICE_UNKNOWN;
}

nlohmann::json DeviceProfile::ToJson() const {
  nlohmann::json eps = nlohmann::json::array();
  for (const auto& ep : execution_providers) {
    eps.push_back({
        {"name", ep.name},
        {"device", ToString(ep.device)},
        {"available", ep.available},
        {"priority", ep.priority},
        {"compatibility_string", ep.compatibility_string},
        {"attributes", ep.attributes},
    });
  }

  return nlohmann::json{
      {"platform", platform},
      {"os_version", os_version},
      {"device_model", device_model},
      {"soc", soc},
      {"abi", abi},
      {"cpu_cores", cpu_cores},
      {"total_memory_bytes", total_memory_bytes},
      {"available_memory_bytes", available_memory_bytes},
      {"available_storage_bytes", available_storage_bytes},
      {"has_npu", has_npu},
      {"has_gpu", has_gpu},
      {"thermal_state", ToString(thermal_state)},
      {"low_power_mode", low_power_mode},
      // Retained in the JSON schema for binding compatibility. This SDK never
      // accesses the network, so it deliberately does not monitor connectivity.
      {"network", "unknown"},
      {"max_model_bytes", MaxModelBytes()},
      {"execution_providers", eps},
  };
}

int64_t DeviceProfile::MaxModelBytes() const {
  if (available_memory_bytes <= 0) {
    // Detection failed. Assume a conservative 1 GB budget rather than letting an
    // unknown device attempt a multi-gigabyte load and get killed.
    return 1024LL * 1024 * 1024;
  }
  auto budget = static_cast<int64_t>(static_cast<double>(available_memory_bytes) * kMemoryBudgetFraction);

  // A hot or power-limited device will throttle hard during a long generation; smaller
  // models keep the app responsive instead of stuttering.
  if (thermal_state >= ThermalState::kSerious || low_power_mode) {
    budget /= 2;
  }
  return budget;
}

DeviceProfile GetDeviceProfile() {
  std::lock_guard<std::mutex> lock(g_profile_mutex);
  if (!g_static_initialized) {
    platform::FillStaticInfo(g_profile);
    platform::FillExecutionProviders(g_profile);
    g_static_initialized = true;
  }
  // Memory, thermal and network change constantly, so they are always re-read. The
  // expensive probes above are not.
  platform::FillDynamicInfo(g_profile);
  return g_profile;
}

void RefreshDeviceProfile() {
  std::lock_guard<std::mutex> lock(g_profile_mutex);
  g_static_initialized = false;
}

void ClassifyExecutionProvider(const std::string& name, flm_device* out_device, int* out_priority) {
  // Names arrive in several shapes across runtime versions ("QNN", "QNNExecutionProvider",
  // "qnn"), so match case-insensitively on a substring rather than on equality.
  std::string lower;
  lower.reserve(name.size());
  for (char c : name) {
    lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }

  const auto contains = [&lower](const char* needle) { return lower.find(needle) != std::string::npos; };

  flm_device device = FLM_DEVICE_CPU;
  int priority = 100;

  if (contains("qnn") || contains("nnapi") || contains("vitisai") || contains("openvino") || contains("coreml")) {
    // CoreML and OpenVINO span CPU/GPU/NPU; report NPU because that is the placement
    // worth selecting a specialised variant for.
    device = FLM_DEVICE_NPU;
    priority = 0;
  } else if (contains("cuda") || contains("dml") || contains("directml") || contains("rocm") || contains("webgpu") ||
             contains("metal")) {
    device = FLM_DEVICE_GPU;
    priority = 10;
  } else if (contains("xnnpack")) {
    device = FLM_DEVICE_CPU;
    priority = 20;
  } else if (contains("cpu")) {
    device = FLM_DEVICE_CPU;
    priority = 30;
  }

  if (out_device != nullptr) {
    *out_device = device;
  }
  if (out_priority != nullptr) {
    *out_priority = priority;
  }
}

void MergeRuntimeExecutionProviders(std::vector<ExecutionProviderInfo> runtime_providers) {
  std::lock_guard<std::mutex> lock(g_profile_mutex);
  if (!g_static_initialized) {
    platform::FillStaticInfo(g_profile);
    platform::FillExecutionProviders(g_profile);
    g_static_initialized = true;
  }

  for (auto& incoming : runtime_providers) {
    auto it = std::find_if(g_profile.execution_providers.begin(), g_profile.execution_providers.end(),
                           [&incoming](const ExecutionProviderInfo& existing) { return existing.name == incoming.name; });
    if (it != g_profile.execution_providers.end()) {
      // The runtime is authoritative on availability — it knows what actually
      // registered. Platform detection keeps its richer attributes and priority.
      it->available = incoming.available;
      if (!incoming.compatibility_string.empty()) {
        it->compatibility_string = incoming.compatibility_string;
      }
      for (auto& [key, value] : incoming.attributes.items()) {
        it->attributes[key] = value;
      }
    } else {
      g_profile.execution_providers.push_back(std::move(incoming));
    }
  }

  std::stable_sort(g_profile.execution_providers.begin(), g_profile.execution_providers.end(),
                   [](const ExecutionProviderInfo& a, const ExecutionProviderInfo& b) {
                     if (a.available != b.available) {
                       return a.available;  // Available providers first.
                     }
                     return a.priority < b.priority;
                   });
}

}  // namespace flm
