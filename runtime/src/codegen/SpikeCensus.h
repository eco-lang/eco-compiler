//===- SpikeCensus.h - De-risking census for the MLIR split plans ---------===//
//
// plans/mlir-split-backend-00-spikes.md. Diagnostic only: runs when
// ECO_SPIKE_DIR is set, on the final llvm-dialect module just before
// translation, and never modifies that module.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_SPIKE_CENSUS_H
#define ECO_SPIKE_CENSUS_H

#include "mlir/IR/BuiltinOps.h"
#include "llvm/ADT/StringRef.h"

namespace eco {
void runSpikeCensus(mlir::ModuleOp module, llvm::StringRef outDir);
} // namespace eco

#endif // ECO_SPIKE_CENSUS_H
