// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Device capability detection.
//
// This is the input to model-package variant selection: which execution providers can
// actually run here, how much memory and storage are available, and whether the device
// is currently in a state (hot, low battery, metered network) where the aggressive
// choice is the wrong one.
//
// Platform specifics live in device_profile_android.cc / device_profile_apple.cc;
// this header is the shared shape.

#ifndef FOUNDRY_LOCAL_MOBILE_DEVICE_PROFILE_H_
#define FOUNDRY_LOCAL_MOBILE_DEVICE_PROFILE_H_

#include <string>
#include <vector>

#include "foundry_local_mobile/flm_types.h"
#include "third_party/json.h"

namespace flm {

enum class ThermalState {
  kNominal = 0,   ///< No throttling.
  kFair = 1,      ///< Mild throttling; still fine for NPU work.
  kSerious = 2,   ///< Sustained throttling; prefer smaller or CPU variants.
  kCritical = 3,  ///< Heavy throttling; avoid accelerators entirely.
};

/// One execution provider the device can offer, with the priority used for scoring.
/// Lower `priority` wins; the ordering encodes "fastest acceptable placement first".
struct ExecutionProviderInfo {
  std::string name;                   ///< "QNN", "CoreML", "XNNPACK", "CPU", ...
  flm_device device = FLM_DEVICE_CPU;
  bool available = false;             ///< Registered and usable right now.
  int priority = 100;
  std::string compatibility_string;   ///< EP-defined; matched against variant metadata.
  nlohmann::json attributes = nlohmann::json::object();  ///< e.g. dsp_arch, soc_model.
};

/// A snapshot of the device. Cheap fields are refreshed on every query; expensive ones
/// (SoC identification, NPU probing) are cached for the process lifetime.
struct DeviceProfile {
  std::string platform;      ///< "android" | "ios" | "macos" | "linux" | "windows"
  std::string os_version;
  std::string device_model;  ///< "Pixel 8 Pro", "iPhone16,2"
  std::string soc;           ///< "Google Tensor G3", "Apple A17 Pro"
  std::string abi;           ///< "arm64-v8a", "arm64"

  int cpu_cores = 0;
  int64_t total_memory_bytes = 0;
  int64_t available_memory_bytes = 0;
  int64_t available_storage_bytes = 0;

  bool has_npu = false;
  bool has_gpu = false;

  ThermalState thermal_state = ThermalState::kNominal;
  bool low_power_mode = false;

  std::vector<ExecutionProviderInfo> execution_providers;

  nlohmann::json ToJson() const;

  /// Largest model we are willing to load, from available memory and the platform's
  /// per-process limit. Variant selection uses this to reject variants that would be
  /// killed by the OS on load.
  int64_t MaxModelBytes() const;

};

/// Detect the device profile. Static fields are cached; dynamic fields such as memory
/// and thermal state are re-read on every call.
///
/// Returned by value on purpose. The cached profile is mutated by dynamic re-reads and by
/// lifecycle notifications from other threads, so handing out a reference would race with
/// any worker that is midway through scoring variants against it.
DeviceProfile GetDeviceProfile();

/// Force a full re-detection. Called on lifecycle transitions that invalidate the
/// cached dynamic state.
void RefreshDeviceProfile();

/// Merge execution providers reported by the runtime into the profile. The runtime knows
/// which EPs are actually registered; platform detection only knows what the hardware
/// could support. The intersection is what variant selection may use.
void MergeRuntimeExecutionProviders(std::vector<ExecutionProviderInfo> runtime_providers);

/// Infer the device type and scheduling priority of an execution provider from its name.
/// The runtime's EP discovery reports only a name and a registration flag, but variant
/// scoring needs to know whether "QNNExecutionProvider" means NPU or CPU. Keeping the
/// mapping in one place stops each platform backend from inventing its own.
void ClassifyExecutionProvider(const std::string& name, flm_device* out_device, int* out_priority);

/// Platform hooks, implemented per-OS.
namespace platform {
void FillStaticInfo(DeviceProfile& profile);
void FillDynamicInfo(DeviceProfile& profile);
void FillExecutionProviders(DeviceProfile& profile);
}  // namespace platform

const char* ToString(ThermalState state) noexcept;
const char* ToString(flm_device device) noexcept;
flm_device DeviceFromString(const std::string& value) noexcept;

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_DEVICE_PROFILE_H_
