/**
 * @file executorch_tokenizer_ffi.h
 * @brief C interface for the standalone tokenizer (text <-> token ids).
 *
 * This header exposes `pytorch/tokenizers` on its own, WITHOUT the LLM
 * generation runner. It exists for encoder-style models — embeddings,
 * classification, retrieval — where the caller wants token ids to feed into
 * `et_module_forward` themselves, and there is no autoregressive decode loop
 * to speak of.
 *
 * Relationship to the other two headers:
 *   - executorch_ffi.h      tensors in, tensors out (single-shot forward)
 *   - executorch_llm_ffi.h  prompt in, generated text out (stateful decode loop)
 *   - this header           text in, token ids out (and back again)
 *
 * The tokenizer is compiled into the base library for every variant, so it is
 * available without opting into the LLM runner. See ET_BUILD_LLM in
 * CMakeLists.txt for what the LLM path adds on top.
 *
 * Design Principles (shared with executorch_ffi.h):
 * 1. Opaque Pointers: `ETTokenizer` hides the C++ tokenizer.
 * 2. Status Returns: functions return `ETStatus*` (NULL or code==ET_OK on
 *    success); caller frees with `et_status_free()`.
 * 3. Memory Ownership: buffers returned through out-parameters are heap
 *    allocated and owned by the CALLER — free ids with
 *    `et_tokenizer_ids_free()` and strings with `et_tokenizer_string_free()`.
 * 4. Thread Safety: a tokenizer is immutable once created, so `encode` and
 *    `decode` are safe to call concurrently on the same handle. Creation and
 *    `et_tokenizer_free` are not.
 */

#ifndef EXECUTORCH_TOKENIZER_FFI_H
#define EXECUTORCH_TOKENIZER_FFI_H

#include <stdint.h>
#include <stddef.h>

/* Reuse ET_API, ETStatus, ETErrorCode from the tensor FFI header. */
#include "executorch_ffi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Handle
 * ============================================================================ */

/**
 * Opaque tokenizer handle. Create with et_tokenizer_create(); destroy with
 * et_tokenizer_free().
 */
typedef struct ETTokenizer ETTokenizer;

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

/**
 * Load a tokenizer from a file, auto-detecting the format.
 *
 * Formats are tried in order: HuggingFace `tokenizer.json`, TikToken,
 * SentencePiece (`.model`), then the llama2.c binary format. The llama2.c
 * reader is deliberately last because it is the most permissive and would
 * otherwise claim files belonging to the other formats.
 *
 * @param tokenizer_path Path to the tokenizer file. Must not be NULL/empty.
 * @param out_tokenizer  Receives the new handle on success. Must not be NULL.
 * @return NULL/ET_OK on success. ET_MODEL_LOAD_FAILED if no format matched.
 */
ET_API ETStatus* et_tokenizer_create(const char* tokenizer_path,
                                     ETTokenizer** out_tokenizer);

/**
 * Free a tokenizer. Safe to call with NULL.
 */
ET_API void et_tokenizer_free(ETTokenizer* tokenizer);

/**
 * Whether the tokenizer finished loading. Returns 0 for NULL.
 */
ET_API int32_t et_tokenizer_is_loaded(const ETTokenizer* tokenizer);

/**
 * Name of the detected format ("hf_json", "tiktoken", "sentencepiece",
 * "llama2c"), or NULL for a NULL handle.
 *
 * The returned string is a static literal — do NOT free it. Provided so a
 * caller can tell which reader claimed an ambiguous file.
 */
ET_API const char* et_tokenizer_format(const ETTokenizer* tokenizer);

/* ============================================================================
 * Encode / Decode
 * ============================================================================ */

/**
 * Encode text into token ids.
 *
 * @param tokenizer  The tokenizer.
 * @param text       NUL-terminated UTF-8 input. Multi-byte input is fine; the
 *                   underlying readers operate on bytes, not code points.
 * @param n_bos      Number of BOS tokens to prepend (usually 0 or 1).
 * @param n_eos      Number of EOS tokens to append (usually 0 or 1).
 * @param out_ids    Receives a heap-allocated array of token ids. OWNERSHIP
 *                   TRANSFERS to the caller — free with
 *                   et_tokenizer_ids_free(). Set to NULL when the result is
 *                   empty.
 * @param out_count  Receives the number of ids written.
 * @return NULL/ET_OK on success, ET_INFERENCE_FAILED if encoding failed.
 */
ET_API ETStatus* et_tokenizer_encode(const ETTokenizer* tokenizer,
                                     const char* text,
                                     int32_t n_bos,
                                     int32_t n_eos,
                                     uint64_t** out_ids,
                                     size_t* out_count);

/**
 * Free an id array returned by et_tokenizer_encode(). Safe to call with NULL.
 */
ET_API void et_tokenizer_ids_free(uint64_t* ids);

/**
 * Decode token ids back into text.
 *
 * The underlying C++ API decodes one token at a time and takes the PREVIOUS
 * token as context, because BPE vocabularies encode leading-space handling
 * relative to what came before. This function performs that walk internally
 * and concatenates the pieces, so callers get whole-sequence decoding.
 *
 * @param tokenizer           The tokenizer.
 * @param ids                 Token ids to decode. May be NULL when count is 0.
 * @param count               Number of ids.
 * @param skip_special_tokens Bool (0/1): omit special tokens from the output.
 * @param out_text            Receives a heap-allocated NUL-terminated UTF-8
 *                            string. OWNERSHIP TRANSFERS to the caller — free
 *                            with et_tokenizer_string_free(). An empty input
 *                            yields an empty string, not NULL.
 * @return NULL/ET_OK on success, ET_INFERENCE_FAILED if decoding failed.
 */
ET_API ETStatus* et_tokenizer_decode(const ETTokenizer* tokenizer,
                                     const uint64_t* ids,
                                     size_t count,
                                     int32_t skip_special_tokens,
                                     char** out_text);

/**
 * Free a string returned by et_tokenizer_decode(). Safe to call with NULL.
 */
ET_API void et_tokenizer_string_free(char* text);

/* ============================================================================
 * Vocabulary Metadata
 * ============================================================================ */

/**
 * Vocabulary size, or 0 for NULL.
 */
ET_API int32_t et_tokenizer_vocab_size(const ETTokenizer* tokenizer);

/**
 * Beginning-of-sequence token id, or 0 for NULL.
 */
ET_API uint64_t et_tokenizer_bos_id(const ETTokenizer* tokenizer);

/**
 * End-of-sequence token id, or 0 for NULL.
 */
ET_API uint64_t et_tokenizer_eos_id(const ETTokenizer* tokenizer);

#ifdef __cplusplus
}
#endif

#endif /* EXECUTORCH_TOKENIZER_FFI_H */
