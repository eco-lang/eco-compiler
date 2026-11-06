// C++ host for the BytesEchoService program compiled as a shared library, written against the C++ layer
// <eco/eco_embed.hpp> (plans/native-bytes-ports-2.md §2.12). The glibc smoke test of the release build
// (docker/static-build.Dockerfile) builds it against the headers the bundle installs.
//
// It checks, end to end through a shipped bundle:
//   - typed port handles, made before the program has registered its ports;
//   - borrowed outgoing bytes, and a direct emit made inside the callback that receives them;
//   - the program's echo of what was emitted, received again.
//
// The program sends four Bytes values at start and echoes back everything it receives. The host emits each
// of the four back reversed, and prints each of the four echoes it gets back.
//
// Build:
//   c++ -std=c++20 bytes_host.cpp -I<eco>/include -L<dir> -l:libbytes.so -lm -o bytes_host -Wl,-rpath,<dir>
//   (<eco> is the directory above bin/eco; in the source tree, -I runtime/include)
//
// Expected output lines (asserted by the smoke test), in any order:
//   HOST got 0 0          HOST back 0 0 -1
//   HOST got 1 7          HOST back 1 7 7
//   HOST got 100000 12492401          HOST back 100000 12492401 101
//   HOST got 50000 6245410            HOST back 50000 6245410 60
//   HOST done
//   HOST exit: 0

#include <eco/eco_embed.hpp>

#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <mutex>

namespace {

std::mutex mutex;
std::condition_variable changed;
int got = 0;
int back = 0;

std::uint64_t sum(std::span<const std::byte> bytes) {
    std::uint64_t total = 0;
    for (std::byte b : bytes) total += static_cast<std::uint8_t>(b);
    return total;
}

}  // namespace

int main(int argc, char** argv) {
    const eco::BytesOutPort out("bytesOut");
    const eco::BytesInPort in("bytesIn");

    eco::Subscription subscription = out.subscribe([&in](const eco::BorrowedBytes& bytes) {
        const std::span<const std::byte> view = bytes.view();
        std::lock_guard<std::mutex> lock(mutex);
        if (got < 4) {
            ++got;
            std::printf("HOST got %zu %llu\n", view.size(), static_cast<unsigned long long>(sum(view)));
            // Inside the callback, on the eco thread: the reversed copy is written straight into the heap.
            const eco::EmitResult rc = in.emit(view.size(), [view](std::span<std::byte> dst) {
                for (std::size_t i = 0; i < view.size(); ++i) dst[i] = view[view.size() - 1 - i];
                return view.size();
            });
            if (rc != eco::EmitResult::Queued) std::printf("HOST emit failed: %d\n", static_cast<int>(rc));
        } else {
            ++back;
            const int first = view.empty() ? -1 : static_cast<int>(static_cast<std::uint8_t>(view[0]));
            std::printf("HOST back %zu %llu %d\n", view.size(), static_cast<unsigned long long>(sum(view)), first);
        }
        std::fflush(stdout);
        changed.notify_all();
    });

    if (int rc = eco_app_start(argc, argv, nullptr); rc != 0) {
        std::printf("HOST start failed: %d\n", rc);
        return 1;
    }
    {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [] { return back >= 4; });
    }
    std::printf("HOST done\n");
    eco_app_stop();
    const int code = eco_app_join();
    subscription.reset();
    std::printf("HOST exit: %d\n", code);
    return code;
}
