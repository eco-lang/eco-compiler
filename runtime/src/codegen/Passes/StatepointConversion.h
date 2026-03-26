//===- StatepointConversion.h - Convert marker calls to gc.statepoint -----===//
//
// Post-MLIR LLVM IR pass that converts __eco_safepoint_marker calls into
// proper gc.statepoint intrinsics with gc-live operand bundles.
//
// This exists because MLIR's LLVM dialect CallOp doesn't correctly handle
// the combination of vararg + operand bundles + elementtype attributes
// required by gc.statepoint. We emit a simple marker call from MLIR and
// convert it to a real statepoint here using LLVM's native IRBuilder API.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_STATEPOINT_CONVERSION_H
#define ECO_STATEPOINT_CONVERSION_H

#include "llvm/IR/Module.h"

namespace eco {

/// Convert __eco_safepoint_marker calls to gc.statepoint intrinsics.
/// Should be run after MLIR-to-LLVM IR translation, before optimization.
/// Returns true if any conversions were made.
bool convertSafepointMarkers(llvm::Module &module);

} // namespace eco

#endif // ECO_STATEPOINT_CONVERSION_H
