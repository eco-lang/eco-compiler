//===- EcoSplit.h - Partition in MLIR, translate and lower in parallel ----===//
//
// Translating a large program's final LLVM-dialect MLIR module into one
// `llvm::Module` is serial, so this component splits the module while it is
// still MLIR and translates and lowers the pieces in parallel (CGEN_083).
//
// A *partition* is a self-contained module made from part of the source
// module. Every defined symbol has exactly one *owner*, the partition that
// holds its definition. Functions are assigned by longest-processing-time
// scheduling on their MLIR operation counts: largest first, each to the
// partition with the least work so far, ties broken by name, so the result is
// deterministic. A global goes with the first function, or global already
// placed, in module order that references it; anything else defined goes to
// partition 0. Partition 0 also holds the module's non-symbol top-level
// operations and declares what they name. Within a partition, every symbol it
// does not own but names, other than an import copy (below), becomes a
// *declaration*: a function or global with external linkage, default
// visibility and no body or initializer, but otherwise with all of the
// definition's attributes. An *import copy*, as `EcoBackend.h` defines it, is
// an `available_externally` clone of a `$cap` function owned elsewhere, made
// so the backend's `$cap` inline prepass can inline it. Import copies are
// made only at an optimization level above `None` and when
// `ECO_CAP_INLINE_MAX_INSTS` is not 0 (default 64), and they cover every
// `$cap` reachable from the partition's own definitions through direct calls,
// because inlining is recursive.
//
// The backend's capacity-check hoisting reads the `eco-cap-*` function
// attributes of callees, and a declaration or import copy missing one of its
// owner's, such as `eco-cap-covered`, could corrupt the heap. So the split
// fails if any of them differs from the owner's (the fact check; the
// environment variable `ECO_SPLIT_FAULT_DROP_COVERED` removes
// `eco-cap-covered` from the copies and declarations of the symbol it names,
// or of all with `*`, so that tests can see the check fire).
//
// Each partition is then translated on its own thread into its own
// `llvm::LLVMContext` and lowered by `runEcoBackend` as a partition worker,
// with its own target machine. When this path is not taken, `runEcoBackend`
// lowers the whole module and may split it later with `llvm::SplitModule`.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_SPLIT_H
#define ECO_SPLIT_H

#include "EcoBackend.h"

#include "mlir/IR/BuiltinOps.h"
#include "llvm/Support/Error.h"

namespace eco {

// Returns how many partitions `lowerMlirSplit` should make of `module` for
// `job`, where 1 means that the module should not be split in MLIR.
//
// The result is 1 when the environment variable `ECO_MLIR_SPLIT` is `0`, when
// `job` is not an `EmitObjectFile` job at an optimization level above `None`
// with `parallelOpt` `Cgu` or `Dev` and without `rs4gcAfterOpt`, or when the
// module's MLIRContext has multithreading disabled. Otherwise it is what
// `choosePartitionCountForCount` gives for the module's defined functions,
// `job.splitCodegen` and `job.splitEligible`.
unsigned mlirSplitPartitionCount(mlir::ModuleOp module,
                                 const EcoBackendJob &job);

// Splits `module` into `numPartitions` partitions and lowers each to an
// object file on its own thread, as `runEcoBackend` would lower the whole
// module for `base`. A function named `main` is renamed `eco_main` in the
// objects; the caller must not rename it beforehand.
//
// `numPartitions` must be at least 1, normally the count from
// `mlirSplitPartitionCount`. Partition 0 is written to `base.objectFilePath`
// and the others to new temporary files. On success, if `result` is not null,
// its `objectFiles` lists all of them, partition 0 first, and its
// `ownedTempFiles` the temporary ones, which the caller must delete.
//
// Once the partitions are built, the operations in `module`'s body are erased
// on another thread, which is joined before the call returns. The caller must
// not use the module's contents after the call, even on failure; only when
// building the partitions fails is the module left as it was. Its
// MLIRContext is shared by the partitions and must outlive the call.
//
// Returns an error if a declaration or import copy does not carry its
// owner's `eco-cap-*` attributes, if a temporary file cannot be created, if
// translating, finishing reachability, creating the target machine or
// `runEcoBackend` fails for a partition (the error of the lowest-numbered
// failing partition is returned), if a partition kept an import copy whose
// owner's prepass deleted the body, which would leave an undefined reference
// at link time, or if `joinPartitionGcLeafReports` fails. On any
// error after the partitions are built, the temporary files are removed;
// `base.objectFilePath` is not.
llvm::Error lowerMlirSplit(mlir::ModuleOp module, const EcoBackendJob &base,
                           unsigned numPartitions, EcoBackendResult *result);

} // namespace eco

#endif // ECO_SPLIT_H
