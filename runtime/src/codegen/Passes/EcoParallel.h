//===- EcoParallel.h - Chunked parallel loops over the MLIR thread pool ---===//
//
// Passes that visit every function of a large module want to do it in parallel,
// but `mlir::parallelFor` and `mlir::parallelForEach` are costly per element:
// they install a `ParallelDiagnosticHandler`, which takes an order-ID mutex
// twice for each element so that diagnostics come out in index order. With tens
// of thousands of elements that mutex serializes the pool.
//
// `forEachChunk` therefore splits the index range into a bounded number of
// contiguous chunks and runs `mlir::parallelFor` over the chunks, so the mutex
// is taken per chunk rather than per element. Diagnostics stay ordered: by
// chunk, then in index order within a chunk, as the callback emits them.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_PASSES_ECOPARALLEL_H
#define ECO_PASSES_ECOPARALLEL_H

#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/Threading.h"

#include <algorithm>
#include <cstddef>

namespace eco {

/// Calls `fn(lo, hi)` for contiguous half-open ranges that together cover
/// `[0, n)` exactly once, in parallel on `ctx`'s thread pool.
///
/// The number of chunks is `ceil(n / minPerChunk)`, capped at 8 times the
/// context's thread count. When multithreading is disabled on `ctx`, or the
/// chunk count is 1 (`n <= minPerChunk`), `fn(0, n)` is called once on the
/// calling thread. Nothing is called when `n` is 0. `minPerChunk` must not be
/// 0.
///
/// Calls may run concurrently on different threads, so `fn` must touch only
/// state owned by the indices it is given. The call returns after every chunk
/// has finished. `fn` is captured by reference and not kept after the call.
template <typename Fn>
void forEachChunk(mlir::MLIRContext *ctx, size_t n, Fn &&fn,
                  size_t minPerChunk = 16) {
    if (n == 0)
        return;
    size_t nChunks = 1;
    if (ctx->isMultithreadingEnabled()) {
        size_t byWork = (n + minPerChunk - 1) / minPerChunk;
        nChunks = std::min<size_t>(byWork, 8 * ctx->getNumThreads());
    }
    if (nChunks <= 1) {
        fn(size_t(0), n);
        return;
    }
    mlir::parallelFor(ctx, 0, nChunks, [&](size_t c) {
        fn(n * c / nChunks, n * (c + 1) / nChunks);
    });
}

} // namespace eco

#endif // ECO_PASSES_ECOPARALLEL_H
