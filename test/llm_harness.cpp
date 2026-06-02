/**
 * @file llm_harness.cpp
 * @brief Minimal standalone harness to validate the LLM runner FFI end-to-end.
 *
 * Loads a model + tokenizer through the C FFI and streams generated tokens to
 * stdout — the Phase 1 validation step for the native runner, independent of Dart.
 *
 * Build (from native/, source mode with the LLM runner enabled):
 *   cmake -B build -DEXECUTORCH_BUILD_MODE=source -DET_BUILD_LLM=ON \
 *         -DET_BUILD_LLM_HARNESS=ON
 *   cmake --build build --target llm_harness
 *
 * Run:
 *   ./build/llm_harness <model.pte> <tokenizer.json> "Your prompt" [max_new_tokens]
 */

#include "executorch_llm_ffi.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

// Per-token callback: print the piece, then free the heap string we were handed.
static void on_token(char* token, void* /*user_data*/) {
    if (!token) return;
    fputs(token, stdout);
    fflush(stdout);
    et_llm_string_free(token);
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s <model.pte> <tokenizer.json> <prompt> [max_new_tokens]\n",
                argv[0]);
        return 2;
    }
    const char* model_path = argv[1];
    const char* tokenizer_path = argv[2];
    const char* prompt = argv[3];
    const int max_new_tokens = (argc > 4) ? atoi(argv[4]) : 128;

    ETLLMRunner* runner = nullptr;
    ETStatus* status =
        et_llm_runner_create(model_path, tokenizer_path, /*data_path=*/nullptr, &runner);
    if (!status || status->code != ET_OK) {
        fprintf(stderr, "create failed: %s\n",
                (status && status->message) ? status->message : "unknown");
        et_status_free(status);
        return 1;
    }
    et_status_free(status);

    ETGenConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.max_new_tokens = max_new_tokens;
    cfg.seq_len = -1;
    cfg.temperature = 0.8f;
    cfg.echo = 1;        // echo the prompt so output reads naturally
    cfg.ignore_eos = 0;

    printf("--- generating (max_new_tokens=%d) ---\n", max_new_tokens);
    status = et_llm_generate(runner, prompt, &cfg, on_token, /*user_data=*/nullptr);
    printf("\n--- done ---\n");

    int rc = 0;
    if (!status || status->code != ET_OK) {
        fprintf(stderr, "generate failed: %s\n",
                (status && status->message) ? status->message : "unknown");
        rc = 1;
    }
    et_status_free(status);

    et_llm_runner_free(runner);
    return rc;
}
