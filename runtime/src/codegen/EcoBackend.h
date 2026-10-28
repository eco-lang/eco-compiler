//===- EcoBackend.h - Shared Eco LLVM backend helpers ---------------------===//
//
// Generated Elm code runs on a moving garbage collector, so before LLVM may
// compile it, every call that can start a collection must become a
// statepoint, a call whose live heap pointers are recorded so the collector
// can find and relocate them. This component is the one place that turns an
// LLVM module produced from Eco's MLIR into that form and then into an
// optimized object file or JIT-ready IR. Its entry point is `runEcoBackend`.
//
// The lowering leaves some operations as markers: calls to declaration-only
// `__eco_*` functions such as `__eco_alloc_inline`, `__eco_resolve_fwd` and
// `__eco_value_eq`. A marker stands for code that needs new basic blocks in
// places where the MLIR lowering cannot create them. The backend expands every
// marker into open code before RS4GC (LLVM's RewriteStatepointsForGC), so that
// RS4GC sees the final control flow and tracks the pointers in it.
//
// The order of the work follows from two rules. A statepointed call is not
// inlined after RS4GC, so small `$cap` fast-evaluator bodies that may collect
// are inlined just before RS4GC. And a call
// that cannot collect needs no statepoint, so before RS4GC the backend marks
// functions that provably never collect with LLVM's `gc-leaf-function`
// attribute, or checks those marks when the MLIR pipeline already made them
// (CGEN_072). Capacity-check hoisting (CGEN_074) also happens before marker
// expansion completes: where the nursery space for a run of fixed-size
// allocations can be checked once, the allocations expand without their own
// checks, which can leave a function with nothing that collects.
//
// After RS4GC, an object-file job is optimized and emitted. A large executable
// may be emitted as several partitions on several threads. When the module was
// split in MLIR before translation (`EcoSplit`), each partition comes here on
// its own as a partition worker (`PartitionWorkerInfo`); otherwise the module
// may be split here with `llvm::SplitModule`.
//
// The terms used below: a *GC-free* function is one stamped
// `gc-leaf-function` because nothing it calls can collect. A *partition
// worker* is a call that lowers one partition of a split module. An *import
// copy* is an `available_externally` copy of a `$cap` function that another
// partition owns, present only so it can be inlined.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_BACKEND_H
#define ECO_BACKEND_H

#include <memory>
#include <string>
#include <vector>

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/CodeGen.h"
#include "llvm/Support/Error.h"

namespace llvm {
class Module;
class TargetMachine;
} // namespace llvm

namespace eco {

class LoweringStats;

//===----------------------------------------------------------------------===//
// Target machine configuration
//===----------------------------------------------------------------------===//

/// The CPU that `createEcoTargetMachine` targets, chosen by the architecture
/// this code is compiled for: `x86-64-v3` (AVX2, BMI2 and FMA, no AVX-512)
/// on x86-64, and `apple-m1` on AArch64.
///
/// It is pinned rather than detected from the host, so that an object built
/// on a machine with wider vector units still runs on any CPU of the pinned
/// level.
#if defined(__aarch64__) || defined(__arm64__)
inline constexpr const char *kEcoTargetCPU = "apple-m1";
#else
inline constexpr const char *kEcoTargetCPU = "x86-64-v3";
#endif

/// The subtarget features added to `kEcoTargetCPU`. Empty, because the CPU
/// level already implies the features wanted, and nothing host-specific is
/// added.
inline constexpr const char *kEcoTargetFeatures = "";

/// Creates the target machine for AOT object emission, for the host's default
/// triple with `kEcoTargetCPU` and `kEcoTargetFeatures`, position-independent
/// code, the small code model, and each function and data object in its own
/// section. `optLevel` is clamped to 3 and becomes the codegen optimization
/// level.
///
/// Sets `module`'s target triple, and its data layout on success. On Apple
/// platforms built with `ECO_MACOS_MIN`, the triple names that minimum macOS
/// version. Returns null after printing a message to `llvm::errs()` if the
/// target or the machine cannot be created.
std::unique_ptr<llvm::TargetMachine>
createEcoTargetMachine(llvm::Module &module, unsigned optLevel);

/// The settings for one `runRS4GCAndMaybeFramePointers` run.
struct RS4GCOptions {
    /// Where to write the module as text IR before RS4GC; empty for no dump.
    std::string preDumpPath;

    /// Where to write the module as text IR after RS4GC; empty for no dump.
    std::string postDumpPath;

    /// Whether to add `frame-pointer=all` to functions after RS4GC. By
    /// default it goes only on functions that contain a statepoint or call
    /// `eco_gc_push_stack_range`; with `ECO_FP_LEAF=0` it goes on every
    /// defined function.
    bool addFramePointerAttr = false;
};

/// Runs RS4GC on `m` through `addEcoGCPipeline`, with the dumps and frame
/// pointers `opts` asks for. A dump file that cannot be opened is reported on
/// stderr and skipped. A dump path is suffixed with the partition index on a
/// partition worker's thread (see `setPartitionIndex`).
///
/// When GC-free stamping is on (its default; `gcFreeLeafMode` in
/// `Passes/EcoCapHoistCore.h`), the stamps are checked on both sides of RS4GC:
/// before, a stamped definition must not have interposable or
/// `available_externally` linkage and may make only calls RS4GC will not
/// statepoint; after, it must contain no statepoint. A failed check stops the
/// process with `llvm::report_fatal_error`; a failure of the check after
/// RS4GC comes after the post-RS4GC dump has been written.
void runRS4GCAndMaybeFramePointers(llvm::Module &m,
                                   const RS4GCOptions &opts);

/// What `runEcoBackend` produces after the common work of marker expansion
/// and RS4GC.
enum class BackendKind {
    /// Nothing more: the module is left after RS4GC, unoptimized, for the
    /// caller to optimize or print.
    DumpLLVMText,

    /// One or more optimized object files. Linking stays with the caller.
    /// Inline TLS access to the bump state and the root stack is used only
    /// for this kind.
    EmitObjectFile,

    /// A module optimized by `mlir::makeOptimizingTransformer`, for a JIT.
    /// On Windows the optimization is skipped.
    JITInvokePacked,
};

/// Where optimization runs for an `EmitObjectFile` job, and how much of it.
///
/// Under `Dev` and `Cgu` each partition is optimized on its own thread, so no
/// function is inlined into a function of another partition.
enum class ParallelOpt {
    /// The whole module is optimized on one thread, and only object emission
    /// is split.
    None,
    /// Each partition gets the per-function simplification pipeline with no
    /// cost-model inliner: a fast compile and slower code.
    Dev,
    /// Each partition gets the full module pipeline, inlining included.
    Cgu,
};

/// The names one partition defines, stamps GC-free, and declares as
/// gc-leaf, for the check that `joinPartitionGcLeafReports` makes across
/// partitions. Filled only when GC-free stamping is on.
///
/// `stampedDefs` are the defined functions stamped `gc-leaf-function`,
/// `allDefs` every defined function, and `leafDecls` the declarations that
/// carry the attribute.
struct GcLeafPartitionReport {
    std::vector<std::string> stampedDefs, allDefs, leafDecls;
};

/// What a partition worker needs to know about the split, and what it
/// reports back. A `runEcoBackend` call with `EcoBackendJob::partition`
/// pointing at one of these lowers one partition of a module split in MLIR.
///
/// The outputs are written during the call.
struct PartitionWorkerInfo {
    /// The partition's position in the split.
    unsigned index = 0;
    /// Functions another partition references. Each local one is given
    /// external linkage and hidden visibility before the prepass, so the
    /// inliner cannot delete it.
    std::vector<std::string> exports;
    /// Functions exported only if they survive the prepass. A survivor that
    /// is local gets external linkage and hidden visibility; a name with no
    /// definition left is added to `deletedLate`.
    std::vector<std::string> exportsLate;
    /// Output: the names in `exportsLate` that have no definition after the
    /// prepass.
    std::vector<std::string> deletedLate;
    /// Output: import copies the prepass marked `alwaysinline` that still
    /// have a body after it. Their bodies are then deleted.
    std::vector<std::string> markedSurvivors;
    /// Output: this partition's report, filled after RS4GC on the
    /// single-object path.
    GcLeafPartitionReport gcReport;
};

/// The settings for one `runEcoBackend` call: what to produce, and how.
struct EcoBackendJob {
    BackendKind kind = BackendKind::DumpLLVMText;

    /// The target machine to optimize for and emit with. Needed for single
    /// object emission, which fails without it, and for whole-module
    /// optimization, which is skipped without it. May be null otherwise. Must
    /// outlive the call.
    llvm::TargetMachine *tm = nullptr;

    /// The optimization level. At `None` the `$cap` inline prepass and all
    /// optimization are skipped, and no parallel tier applies.
    llvm::CodeGenOptLevel optLevel = llvm::CodeGenOptLevel::None;

    /// Whether to add frame-pointer attributes, as
    /// `RS4GCOptions::addFramePointerAttr` describes.
    bool needsFramePointerAttr = false;

    /// Where to write the module as text IR before and after RS4GC; empty for
    /// no dump. Asking for either keeps RS4GC on the whole module, so the
    /// dump shows all of it.
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;

    /// For `EmitObjectFile`, the object file to write, or the first of the
    /// files when the module is split. When it is empty nothing is emitted,
    /// and a split is an error.
    std::string objectFilePath;

    /// The requested number of emission partitions: 0 for automatic, 1 for
    /// none, or an explicit count. A module with fewer defined functions than
    /// 4000 (or `ECO_SPLIT_MIN_FUNCS`) is never split. Otherwise the count is
    /// the request, or the number of hardware threads for 0, capped at one
    /// partition per 2000 functions, with at least 2. See
    /// `choosePartitionCountForCount`.
    unsigned splitCodegen = 1;

    /// Whether the output may be split and optimized in parallel at all.
    bool splitEligible = false;

    /// Whether the output is closed-world for capacity hoisting (CGEN_074):
    /// no function with internal linkage has a caller outside the module. It
    /// must equal the setting the MLIR plan was computed with; a mismatch
    /// with a stamped plan is an error.
    bool capClosedWorld = false;

    /// The parallel-optimization tier. Honoured only for `EmitObjectFile`
    /// with `optLevel` above `None` and `splitEligible`; otherwise `None`
    /// applies. Under `Dev` or `Cgu`, RS4GC also runs per partition, unless
    /// an RS4GC dump was asked for.
    ParallelOpt parallelOpt = ParallelOpt::None;

    /// Under `ParallelOpt::Dev`, the codegen level for the target machine of
    /// each thread `llvm::SplitModule` emission starts: 0 None, 1 Less,
    /// 2 Default. `~0u` follows `optLevel`. Emission without that split uses
    /// `tm` and ignores this.
    unsigned devEmitCodeGenLevel = ~0u;

    /// Under `ParallelOpt::Dev`, run the per-partition simplification
    /// pipeline at O1 instead of the level `optLevel` gives.
    bool devOptO1 = false;

    /// Where to record the time of each backend sub-phase, or null for no
    /// recording. Partition threads record into it concurrently, which
    /// `LoweringStats::record` allows. Must outlive the call.
    LoweringStats *stats = nullptr;

    /// The partition this call lowers, or null when the call lowers a whole
    /// module. Read and written during the call; see `PartitionWorkerInfo`.
    PartitionWorkerInfo *partition = nullptr;

    /// Experimental and off by default: run RS4GC after optimization instead
    /// of before it. Honoured only for `EmitObjectFile` with `parallelOpt`
    /// `None`. The optimizer then works on IR without statepoints, but it may
    /// move a `ptrtoint` of a heap pointer, such as a tag extraction, across
    /// a call that becomes a statepoint, leaving a value that is stale after
    /// a collection (REP_LLVM_001(a)). Nothing checks for that.
    bool rs4gcAfterOpt = false;
};

/// The object files an `EmitObjectFile` run of `runEcoBackend` wrote.
///
/// `objectFiles` lists every object to link. `ownedTempFiles` is the subset
/// the backend created as temporary files, which the caller must delete; it
/// never includes `EcoBackendJob::objectFilePath`. Without a split,
/// `objectFiles` is `{ job.objectFilePath }`, even when that path is empty and
/// nothing was written, and `ownedTempFiles` is empty.
struct EcoBackendResult {
    std::vector<std::string> objectFiles;
    std::vector<std::string> ownedTempFiles;
};

/// Lowers `m` in place for a garbage-collected runtime, and then produces
/// what `job.kind` asks for.
///
/// `m` must already carry its target triple, which the GC-free checks read.
/// Every kind first:
///   - checks the MLIR pipeline's GC-free and capacity-hoisting plan flags
///     for consistency;
///   - expands every marker, with capacity-check hoisting decided between
///     the other expansions and the allocation markers;
///   - inlines small `$cap` bodies, unless `job.optLevel` is `None`;
///   - deletes the body of any import copy that survives, and on a partition
///     worker exports what `job.partition` names;
///   - stamps or checks GC-free functions (CGEN_072), unless GC-free
///     stamping is switched off;
///   - runs RS4GC with `runRS4GCAndMaybeFramePointers`, unless it is
///     deferred or moved into partition threads, as `EcoBackendJob` says.
/// The plan flags and capacity-hoisting attributes are removed from `m`.
///
/// For `EmitObjectFile` it then writes objects, optimizing when `tm` is set
/// and `job.optLevel` is not `None` (under a parallel tier, each partition is
/// optimized in its own worker after the split). When
/// `job.splitEligible` and the partition count from `job.splitCodegen` is
/// above 1, `m` is split with `llvm::SplitModule` and each part is emitted on
/// its own thread, part 0 to `job.objectFilePath` and the others to new
/// temporary files; the files are reported through `result`. `result` may be
/// null, and is not written for the other kinds.
///
/// Returns an error for inconsistent plan flags or plan facts, a failed
/// check of GC-free stamps against the MLIR plan, an import copy left before
/// RS4GC, an unnamed global in a partition, a file that cannot be created, a
/// failed optimization, or a failed emission. Temporary files it created are removed on a split
/// failure. Several internal checks stop the process with
/// `llvm::report_fatal_error` instead.
///
/// The call may run on several threads at once for distinct modules.
llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job,
                          EcoBackendResult *result = nullptr);

/// Runs `internalizeAndDCE` keeping only `eco_main` and `__eco_init_globals`,
/// the two symbols a program's entry code resolves by name.
///
/// Only for executable output: shared-library and object-only output need
/// other symbols to stay visible. Run it before `runEcoBackend`, so that
/// RS4GC and the stack map cover only live functions. Modules stamped by MLIR
/// reachability need `finishReachability` instead.
void internalizeAndDCEForExecutable(llvm::Module &m);

/// Gives internal linkage to every global of `m` not named in `keep`, then
/// deletes the globals nothing reachable uses (LLVM's GlobalDCE). Internal
/// linkage also lets the optimizer treat the code as non-preemptible.
void internalizeAndDCE(llvm::Module &m, llvm::ArrayRef<std::string> keep);

/// Returns whether `m` carries the `eco-reach` module flag, which says that
/// unreachable code was already erased and the rest internalized in MLIR
/// (CGEN_081).
bool hasReachabilityStamp(const llvm::Module &m);
/// Finishes MLIR reachability on the LLVM side: removes the `eco-reach` flag
/// and the unused constant expressions left on functions and globals, which
/// would otherwise make a function look address-taken.
///
/// Returns an error if `m` has no `eco-reach` flag. When `ECO_REACH_VALIDATE`
/// is set to a value other than "0" and `partition` is false, it also runs
/// `internalizeAndDCE(m, keep)` and returns an error if that removed or
/// relinked anything. In a partition the check is skipped, because it would
/// remove definitions only other partitions use.
llvm::Error finishReachability(llvm::Module &m,
                               llvm::ArrayRef<std::string> keep,
                               bool partition = false);

/// Returns the number of partitions for a module with `numDefinedFns` defined
/// functions, given the request `request` (0 automatic, 1 none, or a count).
/// Returns 1 when `eligible` is false, the request is 1, or there are fewer
/// functions than 4000 (or than `ECO_SPLIT_MIN_FUNCS`, read once). Otherwise
/// returns the request, or the number of hardware threads for 0, capped at
/// `numDefinedFns / 2000` but never below 2.
unsigned choosePartitionCountForCount(unsigned numDefinedFns, unsigned request,
                                      bool eligible);
/// Records, for the calling thread only, that it lowers partition `i`, or no
/// partition when `i` is -1. Only `partitionDumpPath` reads it.
void setPartitionIndex(int i);
/// Returns `path` with `.p<i>` appended when the calling thread lowers
/// partition i, and `path` unchanged otherwise, so that partition threads
/// never write the same diagnostic file.
std::string partitionDumpPath(llvm::StringRef path);
/// Returns an error naming the first gc-leaf declaration in `reports` whose
/// function some partition defines but no partition stamps. A declaration no
/// partition defines is a runtime or kernel function and is trusted. Returns
/// success at once unless GC-free stamping is on.
llvm::Error joinPartitionGcLeafReports(
    const std::vector<GcLeafPartitionReport> &reports);
/// Compares, for each function `m` defines, `Function::hasAddressTaken` with
/// the MLIR symbol graph's answer in `mlirTaken`, and returns an error if any
/// differ. `eco_main` is looked up as `main` when it is absent; functions
/// missing from `mlirTaken` were created in LLVM and are skipped. Prints the
/// counts and up to 20 mismatches to stderr.
llvm::Error checkAddressTaken(const llvm::Module &m,
                              const llvm::StringMap<bool> &mlirTaken);

/// Prints to `os` the exclusive time of each LLVM optimization pass and
/// analysis that took at least 0.05 s, summed over every thread, longest
/// first, with the total. Does nothing unless `ECO_OPT_PASS_TIMES` is set.
void printOptPassTimes(llvm::raw_ostream &os);

} // namespace eco

#endif // ECO_BACKEND_H
