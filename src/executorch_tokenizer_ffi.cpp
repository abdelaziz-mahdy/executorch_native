/**
 * @file executorch_tokenizer_ffi.cpp
 * @brief Implementation of the standalone tokenizer C API.
 *
 * See executorch_tokenizer_ffi.h for the contract. Two things worth knowing
 * before editing:
 *
 * 1. The SentencePiece reader is constructed through a factory declared below
 *    and defined in executorch_tokenizer_sp.cpp — see that file for why it
 *    cannot share a translation unit with the abseil-dependent readers.
 *
 * 2. Nothing may throw across the C boundary. Every entry point that runs C++
 *    is wrapped, including the loaders: a malformed tokenizer file is exactly
 *    the kind of input that produces an exception from deep inside a parser.
 */

#include "executorch_tokenizer_ffi.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include <pytorch/tokenizers/hf_tokenizer.h>
#include <pytorch/tokenizers/llama2c_tokenizer.h>
#include <pytorch/tokenizers/tiktoken.h>
#include <pytorch/tokenizers/tokenizer.h>

namespace executorch_ffi_tokenizer {
/** Defined in executorch_tokenizer_sp.cpp. */
std::unique_ptr<::tokenizers::Tokenizer> make_sentencepiece_tokenizer();
} // namespace executorch_ffi_tokenizer

/* ============================================================================
 * Handle
 * ============================================================================ */

struct ETTokenizer {
    std::unique_ptr<::tokenizers::Tokenizer> impl;
    const char* format = nullptr; // static literal
};

/* ============================================================================
 * Status helpers (mirrors executorch_ffi.cpp / executorch_llm_ffi.cpp)
 * ============================================================================ */

namespace {

char* dup_cstr(const char* s) {
    if (s == nullptr) return nullptr;
    const size_t n = std::strlen(s);
    char* out = static_cast<char*>(std::malloc(n + 1));
    if (out == nullptr) return nullptr;
    std::memcpy(out, s, n + 1);
    return out;
}

ETStatus* create_status(ETErrorCode code, const char* message, const char* location) {
    ETStatus* status = static_cast<ETStatus*>(std::malloc(sizeof(ETStatus)));
    if (status == nullptr) return nullptr;
    status->code = static_cast<int32_t>(code);
    status->message = (code == ET_OK) ? nullptr : dup_cstr(message);
    status->location = (code == ET_OK) ? nullptr : dup_cstr(location);
    return status;
}

ETStatus* status_ok() {
    return create_status(ET_OK, nullptr, nullptr);
}

/**
 * Try each reader in turn, most specific first.
 *
 * Order matters. The llama2.c reader accepts essentially any binary blob whose
 * header parses, so it goes last — put it earlier and it claims SentencePiece
 * models out from under the correct reader.
 */
std::unique_ptr<::tokenizers::Tokenizer> load_any(const std::string& path,
                                                  const char** out_format) {
    struct Candidate {
        const char* name;
        std::unique_ptr<::tokenizers::Tokenizer> (*make)();
    };

    static const Candidate candidates[] = {
        {"hf_json", []() -> std::unique_ptr<::tokenizers::Tokenizer> {
             return std::make_unique<::tokenizers::HFTokenizer>();
         }},
        {"tiktoken", []() -> std::unique_ptr<::tokenizers::Tokenizer> {
             return std::make_unique<::tokenizers::Tiktoken>();
         }},
        {"sentencepiece", []() -> std::unique_ptr<::tokenizers::Tokenizer> {
             return executorch_ffi_tokenizer::make_sentencepiece_tokenizer();
         }},
        {"llama2c", []() -> std::unique_ptr<::tokenizers::Tokenizer> {
             return std::make_unique<::tokenizers::Llama2cTokenizer>();
         }},
    };

    for (const auto& candidate : candidates) {
        std::unique_ptr<::tokenizers::Tokenizer> tokenizer;
        try {
            tokenizer = candidate.make();
            if (tokenizer == nullptr) continue;
            if (tokenizer->load(path) != ::tokenizers::Error::Ok) continue;
        } catch (...) {
            // A reader that throws on a file it does not understand is just a
            // non-match; keep trying the rest.
            continue;
        }
        if (out_format != nullptr) *out_format = candidate.name;
        return tokenizer;
    }
    return nullptr;
}

/**
 * Whether the file looks like a HuggingFace tokenizer.json.
 *
 * Trying every reader means a genuine failure in the RIGHT reader is followed
 * by three irrelevant ones, and the caller only sees "nothing recognized this
 * file". That sent a user hunting a format problem when the real cause was a
 * lookahead regex the HF pre-tokenizer could not compile
 * (executorch_flutter#45). Knowing the file was JSON lets the error say which
 * reader was supposed to handle it, and where the real message went.
 */
bool looks_like_json(const std::string& path) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) return false;
    char buf[64] = {0};
    const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    for (size_t i = 0; i < n; ++i) {
        const unsigned char c = static_cast<unsigned char>(buf[i]);
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        return c == '{';
    }
    return false;
}

} // namespace

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

ET_API ETStatus* et_tokenizer_create(const char* tokenizer_path,
                                     ETTokenizer** out_tokenizer) {
    if (out_tokenizer == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "out_tokenizer is null", __func__);
    }
    *out_tokenizer = nullptr;
    if (tokenizer_path == nullptr || tokenizer_path[0] == '\0') {
        return create_status(ET_INVALID_ARGUMENT, "tokenizer_path is null/empty", __func__);
    }

    try {
        const char* format = nullptr;
        auto impl = load_any(std::string(tokenizer_path), &format);
        if (impl == nullptr) {
            // Point at the reader that was actually supposed to work, rather
            // than reporting the last of four unrelated failures.
            if (looks_like_json(tokenizer_path)) {
                return create_status(
                    ET_MODEL_LOAD_FAILED,
                    "file parses as JSON, so the HuggingFace reader was the one "
                    "expected to handle it, and it rejected the file. The other "
                    "readers (tiktoken, sentencepiece, llama2c) were then tried "
                    "and failed for unrelated reasons. See stderr for the "
                    "HuggingFace reader's own error — common causes are a "
                    "WordPiece model or a BertNormalizer (neither is "
                    "implemented), or an unsupported pre-tokenizer",
                    __func__);
            }
            return create_status(ET_MODEL_LOAD_FAILED,
                                 "failed to load tokenizer: no reader accepted "
                                 "this file (tried HuggingFace JSON, tiktoken, "
                                 "sentencepiece, llama2c). See stderr for each "
                                 "reader's own error",
                                 __func__);
        }

        auto* handle = new (std::nothrow) ETTokenizer();
        if (handle == nullptr) {
            return create_status(ET_OUT_OF_MEMORY, "failed to allocate tokenizer handle", __func__);
        }
        handle->impl = std::move(impl);
        handle->format = format;
        *out_tokenizer = handle;
        return status_ok();
    } catch (const std::exception& e) {
        return create_status(ET_MODEL_LOAD_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_MODEL_LOAD_FAILED, "unknown error creating tokenizer", __func__);
    }
}

ET_API void et_tokenizer_free(ETTokenizer* tokenizer) {
    delete tokenizer;
}

ET_API int32_t et_tokenizer_is_loaded(const ETTokenizer* tokenizer) {
    if (tokenizer == nullptr || tokenizer->impl == nullptr) return 0;
    return tokenizer->impl->is_loaded() ? 1 : 0;
}

ET_API const char* et_tokenizer_format(const ETTokenizer* tokenizer) {
    if (tokenizer == nullptr) return nullptr;
    return tokenizer->format;
}

/* ============================================================================
 * Encode / Decode
 * ============================================================================ */

ET_API ETStatus* et_tokenizer_encode(const ETTokenizer* tokenizer,
                                     const char* text,
                                     int32_t n_bos,
                                     int32_t n_eos,
                                     uint64_t** out_ids,
                                     size_t* out_count) {
    if (out_ids == nullptr || out_count == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "out pointer is null", __func__);
    }
    *out_ids = nullptr;
    *out_count = 0;
    if (tokenizer == nullptr || tokenizer->impl == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "tokenizer is null", __func__);
    }
    if (text == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "text is null", __func__);
    }

    try {
        auto result = tokenizer->impl->encode(std::string(text),
                                              static_cast<int8_t>(n_bos),
                                              static_cast<int8_t>(n_eos));
        if (result.error() != ::tokenizers::Error::Ok) {
            return create_status(ET_INFERENCE_FAILED, "tokenizer encode failed", __func__);
        }

        const std::vector<uint64_t>& ids = result.get();
        if (ids.empty()) return status_ok(); // out_ids stays NULL, count 0

        auto* buffer = static_cast<uint64_t*>(std::malloc(ids.size() * sizeof(uint64_t)));
        if (buffer == nullptr) {
            return create_status(ET_OUT_OF_MEMORY, "failed to allocate token id buffer", __func__);
        }
        std::memcpy(buffer, ids.data(), ids.size() * sizeof(uint64_t));
        *out_ids = buffer;
        *out_count = ids.size();
        return status_ok();
    } catch (const std::exception& e) {
        return create_status(ET_INFERENCE_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_INFERENCE_FAILED, "unknown error during encode", __func__);
    }
}

ET_API void et_tokenizer_ids_free(uint64_t* ids) {
    std::free(ids);
}

ET_API ETStatus* et_tokenizer_decode(const ETTokenizer* tokenizer,
                                     const uint64_t* ids,
                                     size_t count,
                                     int32_t skip_special_tokens,
                                     char** out_text) {
    if (out_text == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "out_text is null", __func__);
    }
    *out_text = nullptr;
    if (tokenizer == nullptr || tokenizer->impl == nullptr) {
        return create_status(ET_INVALID_ARGUMENT, "tokenizer is null", __func__);
    }
    if (ids == nullptr && count > 0) {
        return create_status(ET_INVALID_ARGUMENT, "ids is null but count > 0", __func__);
    }

    try {
        std::string text;
        // decode() wants the preceding token because BPE vocabularies encode
        // leading-space handling relative to it. There is nothing before the
        // first token, so BOS stands in — the same convention the LLM runner
        // uses when it starts a stream.
        const uint64_t bos = tokenizer->impl->bos_tok();
        const bool skip = (skip_special_tokens != 0);

        for (size_t i = 0; i < count; ++i) {
            const uint64_t prev = (i == 0) ? bos : ids[i - 1];
            auto piece = tokenizer->impl->decode(prev, ids[i], skip);
            if (piece.error() != ::tokenizers::Error::Ok) {
                return create_status(ET_INFERENCE_FAILED, "tokenizer decode failed", __func__);
            }
            text += piece.get();
        }

        char* out = dup_cstr(text.c_str());
        if (out == nullptr) {
            return create_status(ET_OUT_OF_MEMORY, "failed to allocate decoded string", __func__);
        }
        *out_text = out;
        return status_ok();
    } catch (const std::exception& e) {
        return create_status(ET_INFERENCE_FAILED, e.what(), __func__);
    } catch (...) {
        return create_status(ET_INFERENCE_FAILED, "unknown error during decode", __func__);
    }
}

ET_API void et_tokenizer_string_free(char* text) {
    std::free(text);
}

/* ============================================================================
 * Vocabulary Metadata
 * ============================================================================ */

ET_API int32_t et_tokenizer_vocab_size(const ETTokenizer* tokenizer) {
    if (tokenizer == nullptr || tokenizer->impl == nullptr) return 0;
    return tokenizer->impl->vocab_size();
}

ET_API uint64_t et_tokenizer_bos_id(const ETTokenizer* tokenizer) {
    if (tokenizer == nullptr || tokenizer->impl == nullptr) return 0;
    return tokenizer->impl->bos_tok();
}

ET_API uint64_t et_tokenizer_eos_id(const ETTokenizer* tokenizer) {
    if (tokenizer == nullptr || tokenizer->impl == nullptr) return 0;
    return tokenizer->impl->eos_tok();
}
