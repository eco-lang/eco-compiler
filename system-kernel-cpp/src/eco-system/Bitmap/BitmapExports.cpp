//===- BitmapExports.cpp - C-linkage exports for eco/system's Bitmap ------===//
//
// `Bitmap.index` and `Bitmap.popCount32` count set bits in the low 32 bits of an Int (SeqDict's trie
// bitmaps). The compiler turns calls at a known type into the `eco.int.bitmap_index` and
// `eco.int.popcount32` ops (Compiler.IR.Kernel.Intrinsics), which lower to `llvm.intr.ctpop`; these
// exports serve the calls it cannot, such as the functions used as values. Both must give the numbers
// the ops and the JavaScript kernel (src/Eco/Kernel/Bitmap.js) give.
//
//===----------------------------------------------------------------------===//

#include <bit>
#include <cstdint>

extern "C" int64_t Eco_Kernel_Bitmap_index(int64_t bitmap, int64_t i) {
    uint32_t mask = (1u << (static_cast<uint32_t>(i) & 31u)) - 1u;
    return std::popcount(static_cast<uint32_t>(bitmap) & mask);
}

extern "C" int64_t Eco_Kernel_Bitmap_popCount32(int64_t x) {
    return std::popcount(static_cast<uint32_t>(x));
}
