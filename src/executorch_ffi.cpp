/**
 * @file executorch_ffi.cpp
 * @brief C++ implementation of the ExecuTorch FFI interface
 *
 * This file implements the C API defined in executorch_ffi.h,
 * wrapping the ExecuTorch C++ API for use via dart:ffi.
 */

#include "executorch_ffi.h"

#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <vector>
#include <memory>
#include <mutex>

// ExecuTorch headers
#include <executorch/extension/module/module.h>
#include <executorch/extension/data_loader/buffer_data_loader.h>
#include <executorch/extension/tensor/tensor.h>
#include <executorch/runtime/core/evalue.h>
#include <executorch/runtime/core/exec_aten/exec_aten.h>
#include <executorch/runtime/core/error.h>
#include <executorch/runtime/core/result.h>

using namespace executorch::extension;
using namespace executorch::runtime;

/* ============================================================================
 * Library Version Info
 * ============================================================================ */

#define EXECUTORCH_FFI_VERSION "2.0.0"
#define EXECUTORCH_VERSION "1.1.0"

/* ============================================================================
 * Debug Logging
 * ============================================================================ */

static bool g_debug_enabled = false;  // Simple on/off debug logging

#define ET_LOG(fmt, ...) \
    do { if (g_debug_enabled) fprintf(stderr, "[ExecuTorch] " fmt "\n", ##__VA_ARGS__); } while(0)

/* ============================================================================
 * Internal Structures
 * ============================================================================ */

struct ETTensor {
    ETDType dtype;
    int32_t rank;
    std::vector<int64_t> shape;
    std::vector<uint8_t> data;
};

struct ETModule {
    std::unique_ptr<Module> module;
    std::vector<uint8_t> model_buffer;  // Keep buffer alive for BufferDataLoader
    bool loaded;
    int32_t input_count;
    int32_t output_count;
    std::mutex mutex;  // Thread safety

    // Storage for input tensor metadata (kept alive during forward pass)
    // This fixes the bug where local vectors go out of scope but TensorImpl still references them
    std::vector<std::vector<executorch::aten::SizesType>> input_sizes_storage;
    std::vector<std::vector<uint8_t>> input_data_storage;
};

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

static ETStatus* create_status(ETErrorCode code, const char* message, const char* location) {
    ETStatus* status = static_cast<ETStatus*>(malloc(sizeof(ETStatus)));
    if (!status) return nullptr;

    status->code = code;
    status->message = message ? strdup(message) : nullptr;
    status->location = location ? strdup(location) : nullptr;

    return status;
}

static ETStatus* create_ok_status() {
    return create_status(ET_OK, nullptr, nullptr);
}

static size_t dtype_size(ETDType dtype) {
    switch (dtype) {
        case ET_DTYPE_FLOAT32: return 4;
        case ET_DTYPE_FLOAT64: return 8;
        case ET_DTYPE_INT64: return 8;
        case ET_DTYPE_INT32: return 4;
        case ET_DTYPE_INT16: return 2;
        case ET_DTYPE_INT8: return 1;
        case ET_DTYPE_UINT8: return 1;
        case ET_DTYPE_BOOL: return 1;
        default: return 0;
    }
}

// Convert ETDType to ExecuTorch ScalarType
static executorch::aten::ScalarType to_scalar_type(ETDType dtype) {
    switch (dtype) {
        case ET_DTYPE_FLOAT32: return executorch::aten::ScalarType::Float;
        case ET_DTYPE_FLOAT64: return executorch::aten::ScalarType::Double;
        case ET_DTYPE_INT64: return executorch::aten::ScalarType::Long;
        case ET_DTYPE_INT32: return executorch::aten::ScalarType::Int;
        case ET_DTYPE_INT16: return executorch::aten::ScalarType::Short;
        case ET_DTYPE_INT8: return executorch::aten::ScalarType::Char;
        case ET_DTYPE_UINT8: return executorch::aten::ScalarType::Byte;
        case ET_DTYPE_BOOL: return executorch::aten::ScalarType::Bool;
        default: return executorch::aten::ScalarType::Float;
    }
}

// Convert ExecuTorch ScalarType to ETDType
static ETDType from_scalar_type(executorch::aten::ScalarType scalar_type) {
    switch (scalar_type) {
        case executorch::aten::ScalarType::Float: return ET_DTYPE_FLOAT32;
        case executorch::aten::ScalarType::Double: return ET_DTYPE_FLOAT64;
        case executorch::aten::ScalarType::Long: return ET_DTYPE_INT64;
        case executorch::aten::ScalarType::Int: return ET_DTYPE_INT32;
        case executorch::aten::ScalarType::Short: return ET_DTYPE_INT16;
        case executorch::aten::ScalarType::Char: return ET_DTYPE_INT8;
        case executorch::aten::ScalarType::Byte: return ET_DTYPE_UINT8;
        case executorch::aten::ScalarType::Bool: return ET_DTYPE_BOOL;
        default: return ET_DTYPE_FLOAT32;
    }
}

// Convert ETTensor to EValue - stores sizes and data in module to keep alive during forward
static EValue tensor_to_evalue(const ETTensor* tensor, ETModule* module, int32_t input_index) {
    if (!tensor) {
        ET_LOG("tensor_to_evalue: tensor is null for input %d", input_index);
        return EValue();
    }

    ET_LOG("tensor_to_evalue: converting input %d, rank=%d, dtype=%d",
           input_index, tensor->rank, static_cast<int>(tensor->dtype));

    // Ensure storage vectors are large enough
    if (static_cast<size_t>(input_index) >= module->input_sizes_storage.size()) {
        module->input_sizes_storage.resize(input_index + 1);
        module->input_data_storage.resize(input_index + 1);
    }

    // Store sizes in module (keeps memory alive during forward pass)
    auto& sizes = module->input_sizes_storage[input_index];
    sizes.resize(tensor->rank);
    for (int32_t i = 0; i < tensor->rank; i++) {
        sizes[i] = static_cast<executorch::aten::SizesType>(tensor->shape[i]);
        ET_LOG("  shape[%d] = %lld", i, static_cast<long long>(tensor->shape[i]));
    }

    // Store data in module (keeps memory alive during forward pass)
    auto& data = module->input_data_storage[input_index];
    data = tensor->data;  // Copy data

    ET_LOG("  data_size = %zu bytes", data.size());

    // Create TensorImpl using module's stored memory
    auto scalar_type = to_scalar_type(tensor->dtype);
    auto* impl = new executorch::runtime::etensor::TensorImpl(
        scalar_type,
        tensor->rank,
        sizes.data(),
        data.data()  // Use module's stored data
    );

    return EValue(executorch::aten::Tensor(impl));
}

// Convert EValue tensor to ETTensor
static ETTensor* evalue_to_tensor(const EValue& evalue, int32_t output_index) {
    if (!evalue.isTensor()) {
        ET_LOG("evalue_to_tensor: output %d is not a tensor", output_index);
        return nullptr;
    }

    const auto& tensor = evalue.toTensor();
    auto sizes = tensor.sizes();
    auto scalar_type = tensor.scalar_type();

    ET_LOG("evalue_to_tensor: converting output %d, rank=%zu", output_index, sizes.size());

    ETTensor* result = new (std::nothrow) ETTensor();
    if (!result) {
        ET_LOG("evalue_to_tensor: failed to allocate ETTensor");
        return nullptr;
    }

    result->dtype = from_scalar_type(scalar_type);
    result->rank = static_cast<int32_t>(sizes.size());
    result->shape.resize(result->rank);

    size_t numel = 1;
    for (size_t i = 0; i < sizes.size(); i++) {
        result->shape[i] = sizes[i];
        numel *= sizes[i];
        ET_LOG("  shape[%zu] = %lld", i, static_cast<long long>(sizes[i]));
    }

    size_t data_size = numel * dtype_size(result->dtype);
    result->data.resize(data_size);

    ET_LOG("  data_size = %zu bytes, dtype=%d", data_size, static_cast<int>(result->dtype));

    const void* src = tensor.const_data_ptr();
    if (src) {
        memcpy(result->data.data(), src, data_size);
    } else {
        ET_LOG("  WARNING: tensor data pointer is null");
    }

    return result;
}

/* ============================================================================
 * Status Functions
 * ============================================================================ */

ET_API void et_status_free(ETStatus* status) {
    if (!status) return;

    if (status->message) free(status->message);
    if (status->location) free(status->location);
    free(status);
}

/* ============================================================================
 * Tensor Functions
 * ============================================================================ */

ET_API ETStatus* et_tensor_create(
    const void* data,
    size_t data_size,
    const int64_t* shape,
    int32_t rank,
    ETDType dtype,
    ETTensor** out
) {
    if (!out) {
        return create_status(ET_INVALID_ARGUMENT, "out pointer is null", __func__);
    }

    if (!shape || rank <= 0) {
        return create_status(ET_INVALID_ARGUMENT, "invalid shape or rank", __func__);
    }

    // Calculate expected size
    size_t element_count = 1;
    for (int32_t i = 0; i < rank; i++) {
        if (shape[i] <= 0) {
            return create_status(ET_INVALID_ARGUMENT, "shape dimensions must be positive", __func__);
        }
        element_count *= static_cast<size_t>(shape[i]);
    }

    size_t expected_size = element_count * dtype_size(dtype);
    if (data_size != expected_size) {
        char msg[256];
        snprintf(msg, sizeof(msg), "data size mismatch: expected %zu, got %zu", expected_size, data_size);
        return create_status(ET_INVALID_ARGUMENT, msg, __func__);
    }

    // Allocate tensor
    ETTensor* tensor = new (std::nothrow) ETTensor();
    if (!tensor) {
        return create_status(ET_OUT_OF_MEMORY, "failed to allocate tensor", __func__);
    }

    tensor->dtype = dtype;
    tensor->rank = rank;
    tensor->shape.assign(shape, shape + rank);

    if (data && data_size > 0) {
        tensor->data.resize(data_size);
        memcpy(tensor->data.data(), data, data_size);
    }

    *out = tensor;
    return create_ok_status();
}

ET_API ETDType et_tensor_dtype(const ETTensor* tensor) {
    if (!tensor) return ET_DTYPE_FLOAT32;
    return tensor->dtype;
}

ET_API int32_t et_tensor_rank(const ETTensor* tensor) {
    if (!tensor) return 0;
    return tensor->rank;
}

ET_API const int64_t* et_tensor_shape(const ETTensor* tensor) {
    if (!tensor || tensor->shape.empty()) return nullptr;
    return tensor->shape.data();
}

ET_API size_t et_tensor_data_size(const ETTensor* tensor) {
    if (!tensor) return 0;
    return tensor->data.size();
}

ET_API const void* et_tensor_data(const ETTensor* tensor) {
    if (!tensor || tensor->data.empty()) return nullptr;
    return tensor->data.data();
}

ET_API void et_tensor_free(ETTensor* tensor) {
    if (tensor) {
        delete tensor;
    }
}

ET_API void et_tensor_array_free(ETTensor** tensors, int32_t count) {
    if (!tensors) return;

    for (int32_t i = 0; i < count; i++) {
        et_tensor_free(tensors[i]);
    }
    free(tensors);
}

/* ============================================================================
 * Module Functions
 * ============================================================================ */

ET_API ETStatus* et_module_load(
    const uint8_t* data,
    size_t data_size,
    ETModule** out
) {
    ET_LOG("et_module_load: loading model from buffer, size=%zu bytes", data_size);

    if (!out) {
        ET_LOG("et_module_load: ERROR - out pointer is null");
        return create_status(ET_INVALID_ARGUMENT, "out pointer is null", __func__);
    }

    if (!data || data_size == 0) {
        ET_LOG("et_module_load: ERROR - invalid model data");
        return create_status(ET_INVALID_ARGUMENT, "invalid model data", __func__);
    }

    // Allocate module
    ETModule* module = new (std::nothrow) ETModule();
    if (!module) {
        ET_LOG("et_module_load: ERROR - failed to allocate module");
        return create_status(ET_OUT_OF_MEMORY, "failed to allocate module", __func__);
    }

    try {
        // Copy model data to keep it alive for BufferDataLoader
        ET_LOG("et_module_load: copying model data to internal buffer");
        module->model_buffer.assign(data, data + data_size);

        // Create BufferDataLoader
        ET_LOG("et_module_load: creating BufferDataLoader");
        auto data_loader = std::make_unique<BufferDataLoader>(
            module->model_buffer.data(),
            module->model_buffer.size()
        );

        // Create Module with the data loader
        ET_LOG("et_module_load: creating Module");
        module->module = std::make_unique<Module>(std::move(data_loader));

        // Load the program
        ET_LOG("et_module_load: loading program");
        auto load_error = module->module->load();
        if (load_error != Error::Ok) {
            int error_code = static_cast<int>(load_error);
            ET_LOG("et_module_load: ERROR - failed to load ExecuTorch program, error code: %d", error_code);
            delete module;
            char msg[256];
            snprintf(msg, sizeof(msg), "failed to load ExecuTorch program (error code: %d)", error_code);
            return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
        }

        // Load the forward method (this initializes backend delegates like CoreML, MPS)
        ET_LOG("et_module_load: loading forward method (initializing backend delegates)");
        ET_LOG("et_module_load: available backends - XNNPACK: %d, CoreML: %d, MPS: %d, Vulkan: %d",
               ET_BUILD_XNNPACK, ET_BUILD_COREML, ET_BUILD_MPS, ET_BUILD_VULKAN);
        auto forward_error = module->module->load_forward();
        if (forward_error != Error::Ok) {
            int error_code = static_cast<int>(forward_error);
            ET_LOG("et_module_load: ERROR - failed to load forward method, error code: %d", error_code);
            ET_LOG("et_module_load: This may indicate a backend delegate initialization failure");
            ET_LOG("et_module_load: Common causes: CoreML delegate not compiled in, model exported for different backend");
            delete module;
            char msg[256];
            snprintf(msg, sizeof(msg), "failed to load forward method (error code: %d) - check backend compatibility", error_code);
            return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
        }

        // Get method metadata
        ET_LOG("et_module_load: getting method metadata");
        auto method_meta_result = module->module->method_meta("forward");
        if (method_meta_result.ok()) {
            auto& meta = method_meta_result.get();
            module->input_count = static_cast<int32_t>(meta.num_inputs());
            module->output_count = static_cast<int32_t>(meta.num_outputs());
            ET_LOG("et_module_load: inputs=%d, outputs=%d", module->input_count, module->output_count);
        } else {
            ET_LOG("et_module_load: WARNING - could not get method metadata, assuming 1 input/output");
            module->input_count = 1;
            module->output_count = 1;
        }

        module->loaded = true;
        *out = module;
        ET_LOG("et_module_load: SUCCESS - module loaded at %p", static_cast<void*>(module));
        return create_ok_status();

    } catch (const std::exception& e) {
        ET_LOG("et_module_load: ERROR - C++ exception: %s", e.what());
        delete module;
        char msg[512];
        snprintf(msg, sizeof(msg), "backend initialization failed: %s", e.what());
        return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
    } catch (...) {
        ET_LOG("et_module_load: ERROR - unknown C++ exception");
        delete module;
        return create_status(ET_MODEL_LOAD_FAILED, "unknown backend initialization error", __func__);
    }
}

ET_API ETStatus* et_module_load_file(
    const char* path,
    ETModule** out
) {
    ET_LOG("et_module_load_file: loading model from file: %s", path ? path : "(null)");

    if (!out) {
        ET_LOG("et_module_load_file: ERROR - out pointer is null");
        return create_status(ET_INVALID_ARGUMENT, "out pointer is null", __func__);
    }

    if (!path) {
        ET_LOG("et_module_load_file: ERROR - path is null");
        return create_status(ET_INVALID_ARGUMENT, "path is null", __func__);
    }

    // Allocate module
    ETModule* module = new (std::nothrow) ETModule();
    if (!module) {
        ET_LOG("et_module_load_file: ERROR - failed to allocate module");
        return create_status(ET_OUT_OF_MEMORY, "failed to allocate module", __func__);
    }

    try {
        // Create Module directly from file path
        ET_LOG("et_module_load_file: creating Module with MmapUseMlockIgnoreErrors");
        module->module = std::make_unique<Module>(
            std::string(path),
            Module::LoadMode::MmapUseMlockIgnoreErrors
        );

        // Load the program
        ET_LOG("et_module_load_file: loading program");
        auto load_error = module->module->load();
        if (load_error != Error::Ok) {
            int error_code = static_cast<int>(load_error);
            ET_LOG("et_module_load_file: ERROR - failed to load program from: %s, error code: %d", path, error_code);
            delete module;
            char msg[512];
            snprintf(msg, sizeof(msg), "failed to load program from: %s (error code: %d)", path, error_code);
            return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
        }

        // Load the forward method (this initializes backend delegates like CoreML, MPS)
        ET_LOG("et_module_load_file: loading forward method (initializing backend delegates)");
        ET_LOG("et_module_load_file: available backends - XNNPACK: %d, CoreML: %d, MPS: %d, Vulkan: %d",
               ET_BUILD_XNNPACK, ET_BUILD_COREML, ET_BUILD_MPS, ET_BUILD_VULKAN);
        auto forward_error = module->module->load_forward();
        if (forward_error != Error::Ok) {
            int error_code = static_cast<int>(forward_error);
            ET_LOG("et_module_load_file: ERROR - failed to load forward method, error code: %d", error_code);
            ET_LOG("et_module_load_file: Model path: %s", path);
            ET_LOG("et_module_load_file: This may indicate a backend delegate initialization failure");
            ET_LOG("et_module_load_file: Common causes: CoreML delegate not compiled in, model exported for different backend");
            delete module;
            char msg[512];
            snprintf(msg, sizeof(msg), "failed to load forward method for %s (error code: %d) - check backend compatibility", path, error_code);
            return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
        }

        // Get method metadata
        ET_LOG("et_module_load_file: getting method metadata");
        auto method_meta_result = module->module->method_meta("forward");
        if (method_meta_result.ok()) {
            auto& meta = method_meta_result.get();
            module->input_count = static_cast<int32_t>(meta.num_inputs());
            module->output_count = static_cast<int32_t>(meta.num_outputs());
            ET_LOG("et_module_load_file: inputs=%d, outputs=%d", module->input_count, module->output_count);
        } else {
            ET_LOG("et_module_load_file: WARNING - could not get method metadata, assuming 1 input/output");
            module->input_count = 1;
            module->output_count = 1;
        }

        module->loaded = true;
        *out = module;
        ET_LOG("et_module_load_file: SUCCESS - module loaded at %p", static_cast<void*>(module));
        return create_ok_status();

    } catch (const std::exception& e) {
        ET_LOG("et_module_load_file: ERROR - C++ exception: %s", e.what());
        delete module;
        char msg[512];
        snprintf(msg, sizeof(msg), "backend initialization failed: %s", e.what());
        return create_status(ET_MODEL_LOAD_FAILED, msg, __func__);
    } catch (...) {
        ET_LOG("et_module_load_file: ERROR - unknown C++ exception");
        delete module;
        return create_status(ET_MODEL_LOAD_FAILED, "unknown backend initialization error", __func__);
    }
}

ET_API int32_t et_module_input_count(const ETModule* module) {
    if (!module || !module->loaded) return 0;
    return module->input_count;
}

ET_API int32_t et_module_output_count(const ETModule* module) {
    if (!module || !module->loaded) return 0;
    return module->output_count;
}

ET_API ETStatus* et_module_forward(
    ETModule* module,
    ETTensor** inputs,
    int32_t input_count,
    ETTensor*** outputs,
    int32_t* output_count
) {
    ET_LOG("et_module_forward: starting forward pass with %d inputs", input_count);

    if (!module || !module->loaded) {
        ET_LOG("et_module_forward: ERROR - module not loaded");
        return create_status(ET_INVALID_STATE, "module not loaded", __func__);
    }

    if (!outputs || !output_count) {
        ET_LOG("et_module_forward: ERROR - invalid output pointers");
        return create_status(ET_INVALID_ARGUMENT, "invalid output pointers", __func__);
    }

    if (input_count > 0 && !inputs) {
        ET_LOG("et_module_forward: ERROR - inputs is null");
        return create_status(ET_INVALID_ARGUMENT, "inputs is null", __func__);
    }

    std::lock_guard<std::mutex> lock(module->mutex);

    try {
        // Clear previous input storage (will be repopulated during conversion)
        ET_LOG("et_module_forward: clearing previous input storage");
        module->input_sizes_storage.clear();
        module->input_data_storage.clear();

        // Convert input tensors to EValues (stores data in module to keep alive)
        ET_LOG("et_module_forward: converting %d input tensors", input_count);
        std::vector<EValue> input_evalues;
        input_evalues.reserve(input_count);

        for (int32_t i = 0; i < input_count; i++) {
            if (!inputs[i]) {
                ET_LOG("et_module_forward: ERROR - input tensor %d is null", i);
                return create_status(ET_INVALID_ARGUMENT, "input tensor is null", __func__);
            }
            // Pass module so tensor data is stored and kept alive
            input_evalues.push_back(tensor_to_evalue(inputs[i], module, i));
        }

        // Execute forward
        ET_LOG("et_module_forward: executing forward");
        auto result = module->module->forward(input_evalues);
        if (!result.ok()) {
            ET_LOG("et_module_forward: ERROR - forward execution failed");
            return create_status(ET_INFERENCE_FAILED, "forward execution failed", __func__);
        }

        auto& output_evalues = result.get();
        *output_count = static_cast<int32_t>(output_evalues.size());
        ET_LOG("et_module_forward: forward returned %d outputs", *output_count);

        // Allocate output array
        *outputs = static_cast<ETTensor**>(malloc(sizeof(ETTensor*) * (*output_count)));
        if (!*outputs) {
            ET_LOG("et_module_forward: ERROR - failed to allocate outputs array");
            return create_status(ET_OUT_OF_MEMORY, "failed to allocate outputs array", __func__);
        }

        // Convert output EValues to ETTensors
        ET_LOG("et_module_forward: converting %d output tensors", *output_count);
        for (int32_t i = 0; i < *output_count; i++) {
            ETTensor* out_tensor = evalue_to_tensor(output_evalues[i], i);
            if (!out_tensor) {
                ET_LOG("et_module_forward: ERROR - failed to convert output tensor %d", i);
                // Clean up
                for (int32_t j = 0; j < i; j++) {
                    delete (*outputs)[j];
                }
                free(*outputs);
                *outputs = nullptr;
                *output_count = 0;
                return create_status(ET_INFERENCE_FAILED, "failed to convert output tensor", __func__);
            }
            (*outputs)[i] = out_tensor;
        }

        ET_LOG("et_module_forward: SUCCESS - completed forward pass");
        return create_ok_status();

    } catch (const std::exception& e) {
        ET_LOG("et_module_forward: ERROR - C++ exception: %s", e.what());
        char msg[512];
        snprintf(msg, sizeof(msg), "inference failed with exception: %s", e.what());
        return create_status(ET_INFERENCE_FAILED, msg, __func__);
    } catch (...) {
        ET_LOG("et_module_forward: ERROR - unknown C++ exception");
        return create_status(ET_INFERENCE_FAILED, "inference failed with unknown exception", __func__);
    }
}

ET_API void et_module_free(ETModule* module) {
    if (module) {
        ET_LOG("et_module_free: freeing module at %p", static_cast<void*>(module));
        delete module;
        ET_LOG("et_module_free: module freed");
    }
}

/* ============================================================================
 * Backend Query Functions
 * ============================================================================ */

#ifndef ET_BUILD_XNNPACK
    #define ET_BUILD_XNNPACK 1
#endif

#ifndef ET_BUILD_COREML
    #if defined(__APPLE__)
        #define ET_BUILD_COREML 1
    #else
        #define ET_BUILD_COREML 0
    #endif
#endif

#ifndef ET_BUILD_MPS
    #if defined(__APPLE__) && defined(__aarch64__)
        #define ET_BUILD_MPS 1
    #else
        #define ET_BUILD_MPS 0
    #endif
#endif

#ifndef ET_BUILD_VULKAN
    #define ET_BUILD_VULKAN 0
#endif

#ifndef ET_BUILD_QNN
    #define ET_BUILD_QNN 0
#endif

ET_API int32_t et_backend_available(ETBackend backend) {
    switch (backend) {
        case ET_BACKEND_XNNPACK: return ET_BUILD_XNNPACK;
        case ET_BACKEND_COREML: return ET_BUILD_COREML;
        case ET_BACKEND_MPS: return ET_BUILD_MPS;
        case ET_BACKEND_VULKAN: return ET_BUILD_VULKAN;
        case ET_BACKEND_QNN: return ET_BUILD_QNN;
        default: return 0;
    }
}

ET_API int32_t et_backend_list(ETBackend* out, int32_t max_count) {
    if (!out || max_count <= 0) return 0;

    int32_t count = 0;

    #if ET_BUILD_XNNPACK
        if (count < max_count) out[count++] = ET_BACKEND_XNNPACK;
    #endif
    #if ET_BUILD_COREML
        if (count < max_count) out[count++] = ET_BACKEND_COREML;
    #endif
    #if ET_BUILD_MPS
        if (count < max_count) out[count++] = ET_BACKEND_MPS;
    #endif
    #if ET_BUILD_VULKAN
        if (count < max_count) out[count++] = ET_BACKEND_VULKAN;
    #endif
    #if ET_BUILD_QNN
        if (count < max_count) out[count++] = ET_BACKEND_QNN;
    #endif

    return count;
}

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

ET_API const char* et_version(void) {
    return EXECUTORCH_FFI_VERSION;
}

ET_API const char* et_executorch_version(void) {
    return EXECUTORCH_VERSION;
}

ET_API void et_string_free(char* str) {
    if (str) free(str);
}

ET_API void et_set_debug_enabled(int32_t enabled) {
    g_debug_enabled = (enabled != 0);
    if (g_debug_enabled) {
        fprintf(stderr, "[ExecuTorch] Debug logging enabled\n");
    }
}
