//===- EcoParallel.h - Chunked parallel loops over the MLIR thread pool ---===//
//
// mlir::parallelForEach / parallelFor set up a ParallelDiagnosticHandler and
// take its order-ID mutex twice PER ELEMENT. Over the ~75k functions of a
// self-compile that mutex serializes the pool (plan 07 §0: 14 of 24 threads
// blocked in CapHoistPlan). forEachChunk hands out at most 8 x threads
// contiguous chunks instead, so the per-element cost is one function call.
// Diagnostics keep their total order: by chunk, then sequentially inside it.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_PASSES_ECOPARALLEL_H
#define ECO_PASSES_ECOPARALLEL_H

#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/Threading.h"

#include <algorithm>
#include <cstddef>

namespace eco {

/// Run fn(lo, hi) over [0, n) in contiguous chunks, in parallel on the
/// context's thread pool; serially as fn(0, n) when threading is off or the
/// range is small. fn must only touch state owned by its indices.
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
