#include "whisper.h"
#include "json.hpp"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <filesystem>

using json = nlohmann::json;

static uint32_t little(const std::vector<unsigned char>& data, size_t offset, size_t size) {
    if (offset + size > data.size()) throw std::runtime_error("Invalid WAV header");
    uint32_t result = 0;
    for (size_t i = 0; i < size; ++i) result |= uint32_t(data[offset + i]) << (8 * i);
    return result;
}

static std::vector<float> read_audio(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Audio file cannot be opened");
    const auto size = file.tellg();
    if (size < 44 || size > 16000 * 2 * 120 + 4096) throw std::runtime_error("Invalid audio size");
    file.seekg(0);
    std::vector<unsigned char> bytes(static_cast<size_t>(size));
    if (!file.read(reinterpret_cast<char*>(bytes.data()), size)) throw std::runtime_error("Audio read failed");
    if (std::string(bytes.begin(), bytes.begin() + 4) != "RIFF" ||
        std::string(bytes.begin() + 8, bytes.begin() + 12) != "WAVE")
        throw std::runtime_error("Expected WAV audio");
    bool valid_format = false;
    for (size_t offset = 12; offset + 8 <= bytes.size();) {
        const std::string name(bytes.begin() + offset, bytes.begin() + offset + 4);
        const size_t length = little(bytes, offset + 4, 4);
        const size_t start = offset + 8;
        if (length > bytes.size() - start) throw std::runtime_error("Truncated WAV chunk");
        if (name == "fmt ") {
            valid_format = length >= 16 && little(bytes, start, 2) == 1 &&
                little(bytes, start + 2, 2) == 1 && little(bytes, start + 4, 4) == 16000 &&
                little(bytes, start + 14, 2) == 16;
        } else if (name == "data") {
            if (!valid_format || length % 2) throw std::runtime_error("Expected mono PCM16 at 16 kHz");
            std::vector<float> samples(length / 2);
            for (size_t i = 0; i < samples.size(); ++i)
                samples[i] = static_cast<int16_t>(little(bytes, start + 2 * i, 2)) / 32768.0f;
            return samples;
        }
        offset = start + length + (length % 2);
    }
    throw std::runtime_error("Missing WAV data");
}

static void write_result(const std::string& path, const json& value) {
    const auto temporary = path + ".writing";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file) throw std::runtime_error("Result cannot be created");
        std::filesystem::permissions(temporary, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
        file << value.dump();
        file.flush();
        if (!file) throw std::runtime_error("Result write failed");
    }
    std::filesystem::rename(temporary, path);
}

int main(int argc, char** argv) {
    if (argc < 3) return 2;
    bool use_gpu = true;
    std::string ready_path;
    for (int i = 3; i < argc; ++i) {
        const std::string option = argv[i];
        if (option == "--cpu") use_gpu = false;
        else if (option == "--ready-file" && i + 1 < argc) ready_path = argv[++i];
        else return 2;
    }
    // Models live for the entire stdin session. No network listener or external service.
    auto config = whisper_context_default_params();
    config.use_gpu = use_gpu;
    std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
        whisper_init_from_file_with_params(argv[1], config), whisper_free);
    if (!context) return 3;
    if (!ready_path.empty()) {
        try { write_result(ready_path, {{"ready", true}}); }
        catch (const std::exception&) { return 5; }
    }
    std::string line;
    while (std::getline(std::cin, line)) {
        std::string output;
        try {
            if (line.size() > 32768) throw std::runtime_error("Request too large");
            const auto request = json::parse(line);
            output = request.at("output").get<std::string>();
            const auto audio = read_audio(request.at("audio").get<std::string>());
            const auto language = request.at("language").get<std::string>();
            // Match the CLI quality setting while keeping the model resident. Three
            // candidates recover short words/negations that a single greedy path loses.
            auto params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
            params.n_threads = 4;
            params.no_context = true;
            params.print_progress = false;
            params.print_realtime = false;
            params.print_timestamps = false;
            params.print_special = false;
            params.language = language.c_str();
            params.suppress_nst = true;
            params.temperature = 0;
            params.beam_search.beam_size = 3;
            params.vad = true;
            params.vad_model_path = argv[2];
            // VAD operates on coarse windows. Preserve consonants around its edges
            // instead of trimming speech almost exactly at the detected boundary.
            params.vad_params.speech_pad_ms = 200;
            if (audio.empty() || whisper_full(context.get(), params, audio.data(), static_cast<int>(audio.size())) != 0)
                throw std::runtime_error("Speech recognition failed");
            json segments = json::array();
            for (int i = 0; i < whisper_full_n_segments(context.get()); ++i) {
                segments.push_back({{"text", whisper_full_get_segment_text(context.get(), i)},
                    {"offsets", {{"from", whisper_full_get_segment_t0(context.get(), i) * 10},
                                 {"to", whisper_full_get_segment_t1(context.get(), i) * 10}}}});
            }
            const char* detected = whisper_lang_str(whisper_full_lang_id(context.get()));
            write_result(output, {{"transcription", segments},
                {"result", {{"language", detected ? std::string(detected) : language}}}});
        } catch (const std::exception&) {
            // No meeting contents or paths in diagnostics.
            if (output.empty()) return 4;
            try { write_result(output, {{"error", "Native speech recognition failed"}}); }
            catch (const std::exception&) { return 5; }
        }
    }
    return 0;
}
