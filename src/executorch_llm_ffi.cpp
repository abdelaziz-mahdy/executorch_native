/**
 * @file executorch_llm_ffi.cpp
 * @brief C++ implementation of the LLM (text generation) FFI interface.
 *
 * Wraps ExecuTorch's extension/llm/runner (TextLLMRunner) for use via dart:ffi.
 * See executorch_llm_ffi.h for the C API contract and ownership rules.
 */

#include "executorch_llm_ffi.h"

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

// ExecuTorch LLM runner + tokenizer headers
#include <executorch/extension/llm/runner/irunner.h>
#include <executorch/extension/llm/runner/llm_runner_helper.h>
#include <executorch/extension/llm/runner/stats.h>
#include <executorch/extension/llm/runner/text_llm_runner.h>
#include <executorch/extension/module/module.h>
#include <executorch/runtime/core/error.h>
#include <pytorch/tokenizers/tokenizer.h>

namespace llm = executorch::extension::llm;
using executorch::runtime::Error;

/* ============================================================================
 * Debug Logging (mirrors executorch_ffi.cpp)
 * ============================================================================ */

static bool g_llm_debug_enabled = false;

#define ETLLM_LOG(fmt, ...) \
    do { if (g_llm_debug_enabled) fprintf(stderr, "[ExecuTorch-LLM] " fmt "\n", ##__VA_ARGS__); } while (0)

/* ============================================================================
 * Internal Structures
 * ============================================================================ */

struct ETLLMRunner {
    std::unique_ptr<llm::TextLLMRunner> runner;
    // Serializes generate()/reset()/load() on a single runner. NOTE: et_llm_stop()
    // intentionally does NOT take this lock — it must cancel an in-flight generate
    // running under the lock on another thread (the runner's stop() flips an
    // internal atomic flag, which is safe to do concurrently).
    std::mutex mutex;
};

/* ============================================================================
 * Status Helpers (self-contained copy of the executorch_ffi.cpp pattern; ETStatus
 * is freed by et_status_free() declared in executorch_ffi.h)
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

// Map an ExecuTorch runtime::Error to our FFI error code.
static ETErrorCode to_et_error(Error err) {
    switch (err) {
        case Error::Ok:               return ET_OK;
        case Error::InvalidArgument:  return ET_INVALID_ARGUMENT;
        case Error::MemoryAllocationFailed: return ET_OUT_OF_MEMORY;
        case Error::InvalidState:     return ET_INVALID_STATE;
        case Error::NotSupported:     return ET_UNSUPPORTED;
        default:                      return ET_INFERENCE_FAILED;
    }
}

/* ============================================================================
 * GenerationConfig translation
 * ============================================================================ */

static llm::GenerationConfig to_generation_config(const ETGenConfig* cfg) {
    llm::GenerationConfig gc;  // upstream defaults
    if (cfg) {
        gc.max_new_tokens = cfg->max_new_tokens;
        gc.seq_len        = cfg->seq_len;
        gc.temperature    = cfg->temperature;
        gc.echo           = cfg->echo != 0;
        gc.ignore_eos     = cfg->ignore_eos != 0;
        gc.num_bos        = cfg->num_bos;
        gc.num_eos        = cfg->num_eos;
    }
    return gc;
}

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

ET_API ETStatus* et_llm_runner_create(const char* model_path,
                                      const char* tokenizer_path,
                                      const char* data_path,
                                      ETLLMRunner** out) {
    ETLLM_LOG("et_llm_runner_create: model=%s tokenizer=%s data=%s",
              model_path ? model_path : "(null)",
              tokenizer_path ? tokenizer_path : "(null)",
              data_path ? data_path : "(null)");

    if (!out) {
        return create_status(ET_INVALID_ARGUMENT, "out pointer is null", __func__);
    }
    *out = nullptr;
    if (!model_path || model_path[0] == '\0') {
        return create_status(ET_INVALID_ARGUMENT, "model_path is null/empty", __func__);
    }
    if (!tokenizer_path || tokenizer_path[0] == '\0') {
        return create_status(ET_INVALID_ARGUMENT, "tokenizer_path is null/empty", __func__);
    }

    try {
        std::unique_ptr<tokenizers::Tokenizer> tokenizer = llm::load_tokenizer(tokenizer_path);
        if (!tokenizer) {
            return create_status(ET_MODEL_LOAD_FAILED,
                                 "failed to load tokenizer (unrecognized format?)", __func__);
        }

        // Construct (don't assign) — std::optional<const std::string> has a
        // deleted copy-assignment operator because `const std::string` isn't
        // assignable.
        const std::optional<const std::string> data_opt =
            (data_path && data_path[0] != '\0')
                ? std::optional<const std::string>(std::string(data_path))
                : std::optional<const std::string>(std::nullopt);

        std::unique_ptr<llm::TextLLMRunner> runner =
            llm::create_text_llm_runner(std::string(model_path), std::move(tokenizer), data_opt);
        if (!runner) {
            return create_status(ET_MODEL_LOAD_FAILED, "failed to create text LLM runner", __func__);
        }

        ETLLMRunner* handle = new (std::nothrow) ETLLMRunner();
        if (!handle) {
            return create_status(ET_OUT_OF_MEMORY, "failed to allocate runner handle", __func__);
        }
        handle->runner = std::move(runner);
        *out = handle;
        return create_ok_status();
    } catch (const std::exception& e) {
        return create_status(ET_MODEL_LOAD_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_MODEL_LOAD_FAILED, "unknown error creating LLM runner", __func__);
    }
}

ET_API ETStatus* et_llm_runner_load(ETLLMRunner* runner) {
    if (!runner || !runner->runner) {
        return create_status(ET_INVALID_ARGUMENT, "runner is null", __func__);
    }
    try {
        std::lock_guard<std::mutex> lock(runner->mutex);
        Error err = runner->runner->load();
        if (err != Error::Ok) {
            return create_status(to_et_error(err), "runner load failed", __func__);
        }
        return create_ok_status();
    } catch (const std::exception& e) {
        return create_status(ET_MODEL_LOAD_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_MODEL_LOAD_FAILED, "unknown error loading runner", __func__);
    }
}

ET_API int32_t et_llm_is_loaded(const ETLLMRunner* runner) {
    if (!runner || !runner->runner) return 0;
    return runner->runner->is_loaded() ? 1 : 0;
}

ET_API void et_llm_runner_free(ETLLMRunner* runner) {
    if (!runner) return;
    delete runner;  // ~unique_ptr releases the TextLLMRunner
}

/* ============================================================================
 * Generation
 * ============================================================================ */

ET_API ETStatus* et_llm_generate(ETLLMRunner* runner,
                                 const char* prompt,
                                 const ETGenConfig* cfg,
                                 ETTokenCallback token_cb,
                                 void* user_data) {
    if (!runner || !runner->runner) {
        return create_status(ET_INVALID_ARGUMENT, "runner is null", __func__);
    }
    if (!prompt) {
        return create_status(ET_INVALID_ARGUMENT, "prompt is null", __func__);
    }

    try {
        std::lock_guard<std::mutex> lock(runner->mutex);

        llm::GenerationConfig gc = to_generation_config(cfg);

        std::function<void(const std::string&)> on_token =
            [token_cb, user_data](const std::string& piece) {
                if (!token_cb) return;
                // Hand the callback an OWNED heap copy so it survives the async hop
                // to the Dart isolate; the receiver frees it via et_llm_string_free().
                char* owned = strdup(piece.c_str());
                if (owned) token_cb(owned, user_data);
            };
        std::function<void(const llm::Stats&)> on_stats = [](const llm::Stats&) {};

        Error err = runner->runner->generate(std::string(prompt), gc, on_token, on_stats);
        if (err != Error::Ok) {
            char msg[96];
            snprintf(msg, sizeof(msg),
                     "generation failed (runtime::Error 0x%02x)",
                     static_cast<unsigned>(err));
            return create_status(to_et_error(err), msg, __func__);
        }
        return create_ok_status();
    } catch (const std::exception& e) {
        return create_status(ET_INFERENCE_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_INFERENCE_FAILED, "unknown error during generation", __func__);
    }
}

ET_API void et_llm_generate_async(ETLLMRunner* runner,
                                  const char* prompt,
                                  const ETGenConfig* cfg,
                                  ETTokenCallback token_cb,
                                  void* token_user_data,
                                  ETCallback_1 done_cb) {
    // Copy caller-owned inputs so they outlive this call (the C strings / cfg may be
    // freed by Dart as soon as we return). The runner must stay alive until done_cb
    // fires (documented contract).
    std::string prompt_copy = prompt ? std::string(prompt) : std::string();
    ETGenConfig cfg_copy = cfg ? *cfg : ETGenConfig{-1, -1, 0.8f, 0, 0, 0, 0};

    std::thread([runner, prompt_copy = std::move(prompt_copy), cfg_copy,
                 token_cb, token_user_data, done_cb]() {
        ETStatus* status = et_llm_generate(runner, prompt_copy.c_str(), &cfg_copy,
                                           token_cb, token_user_data);
        if (done_cb) done_cb(static_cast<void*>(status));
        // Ownership of `status` transfers to the Dart completion handler, which frees
        // it via et_status_free(). If there is no done_cb, free it here to avoid a leak.
        else et_status_free(status);
    }).detach();
}

ET_API void et_llm_string_free(char* token) {
    free(token);  // matches strdup() in the on_token wrapper
}

ET_API void et_llm_stop(ETLLMRunner* runner) {
    if (!runner || !runner->runner) return;
    // Deliberately no mutex: cancels an in-flight generate() holding the lock.
    runner->runner->stop();
}

ET_API void et_llm_reset(ETLLMRunner* runner) {
    if (!runner || !runner->runner) return;
    std::lock_guard<std::mutex> lock(runner->mutex);
    runner->runner->reset();
}
