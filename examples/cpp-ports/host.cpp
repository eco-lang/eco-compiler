// A C++ program that runs the Elm program src/Upcase.elm and talks to it through its ports.
//
//     ./upcase < some.txt > SOME.TXT
//
// It shows the two ways bytes come into an Elm program, and the one way they go out:
//
//   - asynchronously: a reader thread emits each chunk of standard input into `input`. Off the eco
//     thread an emit fills a buffer, which the eco thread then copies into the program's heap once;
//   - synchronously: when the program sends a chunk on `upcase`, the subscriber reads it in place and
//     emits the answer into `upcased` from inside the call. There an emit writes straight into a new
//     Bytes value in the program's heap, so the round trip makes no copy at all;
//   - out: the `output` subscriber writes each chunk to standard output, again read in place.
//
// Subscribers run on the eco thread while the program waits for them, so they do little and return.
// See docs/embedding.md for the rules.

#include <eco/eco_embed.hpp>

#include <cerrno>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>

#include <unistd.h>

namespace {

constexpr std::size_t kChunk = 64 * 1024;

std::byte upper(std::byte b) {
    const auto c = static_cast<unsigned char>(b);
    return c >= 'a' && c <= 'z' ? static_cast<std::byte>(c - ('a' - 'A')) : b;
}

}  // namespace

int main(int argc, char** argv) {
    // Resolve each port once, by name. From here on a port is a handle; nothing is looked up again.
    // Handles can be made before the program has started.
    const eco::BytesInPort input{"input"};
    const eco::JsonInPort inputEnded{"inputEnded"};
    const eco::BytesOutPort upcase{"upcase"};
    const eco::BytesInPort upcased{"upcased"};
    const eco::BytesOutPort output{"output"};
    const eco::JsonOutPort summary{"summary"};

    std::mutex mutex;
    std::condition_variable done;
    std::string result;

    // Synchronous: read the chunk where it lies in the program's heap, and write the answer straight
    // into a new Bytes value there. Both spans are valid only during the call.
    const eco::Subscription onUpcase = upcase.subscribe([&upcased](const eco::BorrowedBytes& chunk) {
        const std::span<const std::byte> in = chunk.view();
        const eco::EmitResult rc = upcased.emit(in.size(), [in](std::span<std::byte> out) {
            for (std::size_t i = 0; i < in.size(); ++i) out[i] = upper(in[i]);
            return in.size();
        });
        if (rc != eco::EmitResult::Queued) std::fprintf(stderr, "upcase: emit failed (%d)\n", static_cast<int>(rc));
    });

    const eco::Subscription onOutput = output.subscribe([](const eco::BorrowedBytes& chunk) {
        const std::span<const std::byte> bytes = chunk.view();
        std::fwrite(bytes.data(), 1, bytes.size(), stdout);
    });

    const eco::Subscription onSummary = summary.subscribe([&](std::string_view json) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            result = json;
        }
        done.notify_one();
    });

    if (const int rc = eco_app_start(argc, argv, nullptr); rc != 0) {
        std::fprintf(stderr, "upcase: the program did not start (%d)\n", rc);
        return 1;
    }

    // Asynchronous: a thread of the host's own reads standard input and emits each chunk as it comes.
    // A fill that returns std::nullopt sends nothing; that is how the end of the input is handled.
    std::thread reader([&input, &inputEnded] {
        std::uint64_t total = 0;
        for (;;) {
            bool sent = false;
            const eco::EmitResult rc = input.emit(kChunk, [&](std::span<std::byte> out) -> std::optional<std::size_t> {
                ssize_t n;
                do n = ::read(STDIN_FILENO, out.data(), out.size());
                while (n < 0 && errno == EINTR);
                if (n <= 0) return std::nullopt;
                sent = true;
                total += static_cast<std::uint64_t>(n);
                return static_cast<std::size_t>(n);
            });
            if (!sent) break;
            if (rc != eco::EmitResult::Queued) {
                std::fprintf(stderr, "upcase: emit failed (%d)\n", static_cast<int>(rc));
                break;
            }
        }
        // A JSON port takes JSON text; for an `Int` that is the number itself. It is queued behind the
        // chunks, so the program sees it after all of them.
        inputEnded.send(std::to_string(total));
    });

    {
        std::unique_lock<std::mutex> lock(mutex);
        done.wait(lock, [&] { return !result.empty(); });
    }
    reader.join();
    eco_app_stop();
    const int code = eco_app_join();
    // Every subscriber call has returned by now, so all of the output has been written.
    std::fflush(stdout);
    std::fprintf(stderr, "summary: %s\n", result.c_str());
    return code;
}
