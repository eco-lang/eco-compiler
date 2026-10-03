//===- EcoSplit.h - Partition in MLIR, translate and lower in parallel ----===//
//
// plans/mlir-split-backend-05-ecosplit.md (CGEN_083). The final llvm-dialect
// module is partitioned in MLIR; each partition is translated on its own
// thread into its own LLVMContext and lowered by runEcoBackend in
// partition-worker mode. This replaces the whole-module translation, the
// externalize + bitcode serialize and the per-worker lazy re-parse.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_SPLIT_H
#define ECO_SPLIT_H

#include "EcoBackend.h"

#include "mlir/IR/BuiltinOps.h"
#include "llvm/Support/Error.h"

namespace eco {

/// How many partitions EcoSplit would use for `module` under `job`; 1 means
/// "do not take the EcoSplit path" (§1.9 mode gate: EmitObjectFile, cgu/dev,
/// -O>0, no rs4gcAfterOpt, multithreaded MLIRContext, ECO_MLIR_SPLIT != 0,
/// and the shared partition policy says N > 1).
unsigned mlirSplitPartitionCount(mlir::ModuleOp module,
                                 const EcoBackendJob &job);

/// Partition `module`, then translate + lower every partition in parallel.
/// `base` is the job the driver would have passed to runEcoBackend for the
/// whole module (its objectFilePath becomes partition 0's object). The source
/// module's body is destroyed on a helper thread while the workers run.
/// `result->objectFiles` lists the N objects; `ownedTempFiles` the minted ones.
llvm::Error lowerMlirSplit(mlir::ModuleOp module, const EcoBackendJob &base,
                           unsigned numPartitions, EcoBackendResult *result);

} // namespace eco

#endif // ECO_SPLIT_H
