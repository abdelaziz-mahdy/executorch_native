/**
 * @file executorch_llm_ffi.h
 * @brief C interface for ExecuTorch LLM (text generation) runner.
 *
 * This header exposes ExecuTorch's `extension/llm/runner` (autoregressive decode
 * loop + sampler + tokenizer + KV cache) to Dart via dart:ffi. It is SEPARATE from
 * the tensor API in executorch_ffi.h: LLMs are driven by a stateful generate loop,
 * not the single-shot `et_module_forward` path.
 *
 * Design Principles (shared with executorch_ffi.h):
 * 1. Opaque Pointers: `ETLLMRunner` hides the C++ runner.
 * 2. Status Returns: functions return `ETStatus*` (NULL or code==ET_OK on success);
 *    caller frees with `et_status_free()` (declared in executorch_ffi.h).
 * 3. Memory Ownership: token strings passed to callbacks are valid ONLY during the
 *    call — copy them. The runner owns the model/tokenizer until `et_llm_runner_free`.
 * 4. Thread Safety: `et_llm_generate` is synchronous on the calling thread.
 *    `et_llm_generate_async` runs on an internal C++ thread and marshals tokens via
 *    the callback (use Dart `NativeCallable.listener`). `et_llm_stop` is safe to call
 *    from another thread to cooperatively cancel an in-flight generation.
 *
 * Sampling note: mirrors upstream `GenerationConfig` — temperature-only sampling.
 * There is intentionally NO top_p / top_k (upstream does not support them here).
 *
 * Multimodal (image/audio) is a FUTURE addition: `et_llm_generate_multimodal` will be
 * added additively without changing any signature below.
 */

#ifndef EXECUTORCH_LLM_FFI_H
#define EXECUTORCH_LLM_FFI_H

#include <stdint.h>
#include <stddef.h>

/* Reuse ET_API, ETStatus, ETErrorCode, ETCallback_1 from the tensor FFI header. */
#include "executorch_ffi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Handle
 * ============================================================================ */

/**
 * Opaque LLM runner handle. Wraps an ExecuTorch TextLLMRunner plus its tokenizer.
 * Create with et_llm_runner_create(); destroy with et_llm_runner_free().
 */
typedef struct ETLLMRunner ETLLMRunner;

/* ============================================================================
 * Generation Config
 * ============================================================================ */

/**
 * Generation parameters. Field semantics mirror
 * executorch::extension::llm::GenerationConfig EXACTLY.
 *
 * Defaults (when constructing on the Dart side): max_new_tokens=-1, seq_len=-1,
 * temperature=0.8, echo=0, ignore_eos=0, num_bos=0, num_eos=0.
 */
typedef struct ETGenConfig {
    int32_t max_new_tokens; /**< Max new tokens; -1 => derive from model max_context_len. */
    int32_t seq_len;        /**< Max total tokens; -1 => use model metadata. */
    float   temperature;    /**< Sampling temperature. <= 0 behaves greedily (argmax). */
    int32_t echo;           /**< Bool (0/1): echo the prompt in the output stream. */
    int32_t ignore_eos;     /**< Bool (0/1): keep generating past EOS up to the limit. */
    int32_t num_bos;        /**< Number of BOS tokens to prepend to the prompt. */
    int32_t num_eos;        /**< Number of EOS tokens to append to the prompt. */
} ETGenConfig;

/* ============================================================================
 * Callbacks
 * ============================================================================ */

/**
 * Per-token streaming callback.
 *
 * @param token     Heap-allocated, NUL-terminated UTF-8 token piece. OWNERSHIP
 *                  TRANSFERS to the callback: the receiver MUST free it with
 *                  et_llm_string_free(). (Heap ownership — rather than a transient
 *                  pointer — is required so the string survives the asynchronous hop
 *                  to the Dart isolate via NativeCallable.listener.)
 * @param user_data Opaque pointer passed through from the generate call.
 */
typedef void (*ETTokenCallback)(char* token, void* user_data);

/**
 * Free a token string handed to an ETTokenCallback. Safe to call with NULL.
 */
ET_API void et_llm_string_free(char* token);

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

/**
 * Create a runner from a model file and a tokenizer file.
 *
 * The tokenizer format is auto-detected (HF tokenizer.json, TikToken,
 * SentencePiece, or BPE). The model is mmap'd (with mlock-if-available) so large
 * weights are not copied into RAM.
 *
 * @param model_path     Path to the .pte model file (required).
 * @param tokenizer_path Path to the tokenizer file (required).
 * @param data_path      Optional path to a .ptd weight blob produced by some exports;
 *                       pass NULL when weights are embedded in the .pte.
 * @param out            Out-param; on success receives a non-NULL ETLLMRunner*.
 * @return ETStatus*     code==ET_OK on success; otherwise an error. Caller frees.
 */
ET_API ETStatus* et_llm_runner_create(const char* model_path,
                                      const char* tokenizer_path,
                                      const char* data_path,
                                      ETLLMRunner** out);

/**
 * Eagerly load the model and prepare for inference. Optional — generate() will load
 * lazily on first call. Useful to surface load errors / warm up ahead of time.
 */
ET_API ETStatus* et_llm_runner_load(ETLLMRunner* runner);

/**
 * @return 1 if the runner has loaded its model, 0 otherwise (0 if runner is NULL).
 */
ET_API int32_t et_llm_is_loaded(const ETLLMRunner* runner);

/**
 * Free the runner and all owned resources. Safe to call with NULL.
 * Do not call concurrently with an in-flight generate on the same runner.
 */
ET_API void et_llm_runner_free(ETLLMRunner* runner);

/* ============================================================================
 * Generation
 * ============================================================================ */

/**
 * Synchronous streaming generation. Invokes `token_cb` for each generated UTF-8
 * piece on the CALLING thread, returning when generation finishes (EOS / token
 * limit) or et_llm_stop() is called. Intended for the native C test harness.
 *
 * @return ETStatus* code==ET_OK on success; otherwise an error. Caller frees.
 */
ET_API ETStatus* et_llm_generate(ETLLMRunner* runner,
                                 const char* prompt,
                                 const ETGenConfig* cfg,
                                 ETTokenCallback token_cb,
                                 void* user_data);

/**
 * Asynchronous streaming generation. Runs the decode loop on an internal C++ thread
 * and invokes `token_cb` per piece (use Dart `NativeCallable.listener` so tokens are
 * marshalled to the Dart isolate). When generation ends, `done_cb` is invoked exactly
 * once with the final `ETStatus*` (cast the void* arg to ETStatus*); the receiver owns
 * it and must call et_status_free(). Mirrors et_module_forward_async in executorch_ffi.h.
 *
 * @param token_user_data Passed through to every token_cb invocation.
 * @param done_cb         Completion callback; receives ETStatus* as its void* argument.
 */
ET_API void et_llm_generate_async(ETLLMRunner* runner,
                                  const char* prompt,
                                  const ETGenConfig* cfg,
                                  ETTokenCallback token_cb,
                                  void* token_user_data,
                                  ETCallback_1 done_cb);

/**
 * Cooperatively stop an in-flight generation. Safe to call from a different thread
 * than the one running generate(). No-op if nothing is generating.
 */
ET_API void et_llm_stop(ETLLMRunner* runner);

/**
 * Clear the KV cache and reset the conversation start position (begin a fresh
 * conversation). Do not call during an in-flight generation.
 */
ET_API void et_llm_reset(ETLLMRunner* runner);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* EXECUTORCH_LLM_FFI_H */
