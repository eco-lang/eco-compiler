//===- StatepointConversion.h - Convert marker calls to gc.statepoint -----===//
//
// Post-MLIR LLVM IR pass that converts __eco_safepoint_marker calls into
// proper gc.statepoint intrinsics with gc-live operand bundles, then rewrites
// GC root uses via an alloca/mem2reg pattern to produce correct SSA (including
// loop-carried phi nodes for relocated pointers).
//
// Phase 1: Replace each marker + target call with gc.statepoint + gc.result.
// Phase 2: For each function, emit gc.relocate for live roots, insert allocas,
//          stores, and loads, then run PromoteMemToReg to synthesize phis.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_STATEPOINT_CONVERSION_H
#define ECO_STATEPOINT_CONVERSION_H

#include "llvm/IR/Module.h"

namespace eco {

/// Convert __eco_safepoint_marker calls to gc.statepoint intrinsics and
/// rewrite GC root uses using alloca/mem2reg to produce correct SSA with
/// phi nodes for loop-carried relocated pointers.
/// Should be run after MLIR-to-LLVM IR translation, before optimization.
/// Returns true if any conversions were made.
bool convertSafepointMarkers(llvm::Module &module);

/// Remove dead gc.relocate + ptrtoint pairs from the module.
/// LLVM's SelectionDAG asserts that every gc.relocate in the same block as
/// its statepoint is visited. Dead relocates (created by our SSA rewriting
/// or by LLVM optimization passes like inlining) trigger this assertion.
/// Should be run after optimization and before codegen.
void removeDeadGCRelocates(llvm::Module &module);

} // namespace eco

#endif // ECO_STATEPOINT_CONVERSION_H
