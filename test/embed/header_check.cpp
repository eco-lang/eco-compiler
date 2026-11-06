// Compiles <eco/eco_embed.hpp> alone, as C++20 with warnings as errors, to show it is self-contained and that
// its templates instantiate (plans/native-bytes-ports-2.md §4 step 9). Built by the embed-header-cxx target;
// never linked or run.
#include <eco/eco_embed.hpp>

int ecoHeaderCheckCxx() {
    eco::BytesOutPort out("frameOut");
    eco::BytesInPort in("frameIn");
    eco::JsonOutPort jsonOut("logOut");
    eco::JsonInPort jsonIn("cmdIn");
    eco::Subscription a = out.subscribe([&in](const eco::BorrowedBytes& bytes) {
        eco::OwnedBytes kept = bytes.retain();
        in.emit(bytes.size(), [&bytes](std::span<std::byte> dst) {
            const std::span<const std::byte> src = bytes.view();
            for (std::size_t i = 0; i < src.size(); ++i) dst[i] = src[i];
            return src.size();
        });
        (void)kept;
    });
    eco::Subscription b = jsonOut.subscribe([](std::string_view json) { (void)json; });
    eco::Buffer buffer(16);
    buffer.setSize(4);
    in.send(std::move(buffer));
    in.emit(8, [](std::span<std::byte>) { return std::optional<std::size_t>(); });
    return static_cast<int>(jsonIn.send("1"));
}
