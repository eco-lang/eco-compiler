// Host for Churn.elm: answers reqOut with a 407,104-byte emit ("both", "emit") or 16 bytes
// ("encode"), and prints VmRSS / VmHWM every 500 requests.
//   churn_host '{"mode":"both","steps":3000}'
#include <eco/eco_embed.hpp>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>

namespace {
std::mutex mu;
std::condition_variable cv;
bool finished = false;
int requests = 0;

std::string mem() {
    std::ifstream f("/proc/self/status");
    std::string line, out;
    while (std::getline(f, line))
        if (line.rfind("VmRSS", 0) == 0 || line.rfind("VmHWM", 0) == 0) out += line + "  ";
    return out;
}
}  // namespace

int main(int argc, char** argv) {
    const std::string flags = argc > 1 ? argv[1] : "{}";
    const bool small = flags.find("\"encode\"") != std::string::npos;
    const eco::BytesOutPort reqOut("reqOut");
    const eco::BytesInPort respIn("respIn");
    const eco::JsonOutPort logOut("logOut");
    eco::Subscription s1 = reqOut.subscribe([&](const eco::BorrowedBytes&) {
        if (++requests % 500 == 0) std::printf("step %5d  %s\n", requests, mem().c_str());
        const size_t n = small ? 16 : 407104;
        respIn.emit(n, [n](std::span<std::byte> dst) {
            std::memset(dst.data(), 1, n);
            return n;
        });
    });
    eco::Subscription s2 = logOut.subscribe([](std::string_view json) {
        std::printf("%.*s  %s\n", int(json.size()), json.data(), mem().c_str());
        std::lock_guard<std::mutex> lock(mu);
        finished = true;
        cv.notify_all();
    });
    if (eco_app_start(1, argv, flags.c_str()) != 0) return 1;
    if (flags.find("slice") != std::string::npos || flags.find("hold") != std::string::npos) {
        // 47 MB, like train-images-idx3-ubyte, lent as MNIST's host lends it.
        const size_t n = 47040016;
        auto* buf = static_cast<uint8_t*>(std::malloc(n));
        std::memset(buf, 3, n);
        eco_port_send_bytes("dataIn", buf, n, std::free, buf);
    }
    std::unique_lock<std::mutex> lock(mu);
    cv.wait(lock, [] { return finished; });
    lock.unlock();
    eco_app_stop();
    return eco_app_join();
}
