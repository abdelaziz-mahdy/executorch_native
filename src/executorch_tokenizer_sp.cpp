/**
 * @file executorch_tokenizer_sp.cpp
 * @brief SentencePiece factory, deliberately isolated in its own TU.
 *
 * `sentencepiece_processor.h` opens `namespace absl` and does
 * `using std::string_view;`. The abseil we build against sets
 * ABSL_OPTION_USE_STD_STRING_VIEW to 0, so abseil also declares its own
 * `absl::string_view` class. Pull both into one translation unit and every
 * mention of `absl::string_view` becomes ambiguous and the build fails.
 *
 * The other tokenizer readers (HF, TikToken) reach abseil through re2, so the
 * only way to have all four formats is to keep SentencePiece away from them.
 * Hence this file: it includes exactly one tokenizer header and nothing that
 * drags in abseil.
 *
 * Do not add includes here without checking they stay clear of abseil.
 */

#include <memory>

#include <pytorch/tokenizers/sentencepiece.h>

namespace executorch_ffi_tokenizer {

std::unique_ptr<::tokenizers::Tokenizer> make_sentencepiece_tokenizer() {
    return std::make_unique<::tokenizers::SPTokenizer>();
}

} // namespace executorch_ffi_tokenizer
