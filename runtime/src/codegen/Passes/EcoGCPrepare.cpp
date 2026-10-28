//===- EcoGCPrepare.cpp - GC preparation pass -----------------------------===//
//
// This pass runs before EcoToLLVM lowering and performs:
// 1. Groups adjacent allocation ops (stops at calls, terminators, PAP ops):
//    the leader gets eco.gc_group_size, later members eco.gc_group_member.
// 2. Strips the kernel-opt-12 purity attr (eco.cse_safe) from every eco.call,
//    fencing purity-based merges/erasures out of the rest of the pipeline.
//
// It computes no GC roots: the runtime GC roots, statepoints and stackmap
// entries are computed by LLVM's RS4GC (CGEN_077(b)).
//
//===----------------------------------------------------------------------===//

#include "mlir/IR/Threading.h"
#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"
#include "EcoParallel.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "eco-gc-prepare"

using namespace mlir;

namespace {

/// Returns true if the operation may allocate heap memory.
static bool isMayAllocOp(Operation *op) {
    return isa<eco::AllocateStringOp>(op) ||
           isa<eco::AllocateClosureOp>(op) ||
           isa<eco::ListConstructOp>(op) ||
           isa<eco::Tuple2ConstructOp>(op) ||
           isa<eco::Tuple3ConstructOp>(op) ||
           isa<eco::RecordConstructOp>(op) ||
           isa<eco::CustomConstructOp>(op) ||
           isa<eco::BoxOp>(op) ||
           isa<eco::AllocateOp>(op);
}

/// Returns true if the operation has a statically known fixed allocation size.
/// Only ops that return true here can be grouped for coalesced allocation.
/// AllocateClosureOp, AllocateOp, and non-scalar BoxOp are excluded (V1 scope).
static bool hasFixedAllocSize(Operation *op) {
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        return inputType.isInteger(64) || inputType.isF64() || eco::isEcoCharType(inputType);
    }
    return isa<eco::AllocateStringOp>(op) ||
           isa<eco::ListConstructOp>(op) ||
           isa<eco::Tuple2ConstructOp>(op) ||
           isa<eco::Tuple3ConstructOp>(op) ||
           isa<eco::RecordConstructOp>(op) ||
           isa<eco::CustomConstructOp>(op);
}

/// Compute the aligned allocation size for a given Eco allocation op.
/// Must agree with computeAllocSize in EcoToLLVMHeap.cpp.
static int64_t getFixedAllocSizeForGrouping(Operation *op) {
    constexpr int64_t HeaderSize = 8;

    if (auto allocStr = dyn_cast<eco::AllocateStringOp>(op)) {
        int64_t size = HeaderSize + allocStr.getLength() * 2;
        return (size + 7) & ~7;
    }
    if (isa<eco::ListConstructOp>(op)) return 24;
    if (isa<eco::Tuple2ConstructOp>(op)) return 24;
    if (isa<eco::Tuple3ConstructOp>(op)) return 32;
    // Layout C (HEAP_019): 16 + 8 * (n + K), byte-for-byte as computeAllocSize.
    if (auto recOp = dyn_cast<eco::RecordConstructOp>(op))
        return static_cast<int64_t>(eco::detail::layout::recordByteSize(recOp.getFieldCount()));
    if (auto customOp = dyn_cast<eco::CustomConstructOp>(op))
        return static_cast<int64_t>(eco::detail::layout::customByteSize(customOp.getSize()));
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type inputType = boxOp.getValue().getType();
        if (inputType.isInteger(64) || inputType.isF64() || eco::isEcoCharType(inputType))
            return 16;
    }
    return 0;
}

/// Large-object threshold for group formation (must match runtime default).
/// Groups whose combined size would reach or exceed this are split.
static constexpr int64_t GroupLargeObjectThreshold = 32 * 1024; // 32 KiB

/// Returns true if the operation is a barrier for allocation grouping.
/// Barriers include calls, terminators, and PAP ops.
static bool isGroupBarrier(Operation *op) {
    if (op->hasTrait<OpTrait::IsTerminator>())
        return true;
    if (isa<eco::PapCreateOp>(op) || isa<eco::PapExtendOp>(op))
        return true;
    // Any call-like op is a barrier (D3: conservative)
    if (isa<eco::CallOp>(op))
        return true;
    if (isa<func::CallOp>(op))
        return true;
    return false;
}

//===----------------------------------------------------------------------===//
// kernel-opt-09 Phase 1: allocation-group merge census
//
// Measures, on the real self-compile module, how much opportunity the
// group-merging transform would actually have — BEFORE any of it is built.
// Census-only: `apply` is never true yet, so nothing here mutates IR.
//===----------------------------------------------------------------------===//

static bool censusEnabled() {
    static const bool on = ::getenv("ECO_GCPREPARE_CENSUS") != nullptr;
    return on;
}

/// kernel-opt-09 Phase 2-pre (variant A). `ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0`
/// restores grouping for allocation runs whose every member already has a
/// call-free HEAP_034 inline lowering. Default ON.
///
/// Why splitting such a run is a WIN and not a lost optimization: a GROUP
/// lowers to an out-of-line `eco_gc_alloc_region_fast` call plus one
/// `eco_init_*_at` runtime call per member (EcoToLLVMHeap.cpp
/// lowerOneAllocGroup / emitInitAtPtr), while the same ops lowered
/// individually get inline bump-pointer allocation with straight-line header
/// and field stores and NO calls at all. Grouping is therefore a pessimization
/// for every run this predicate matches. The Phase-1 census measured 16,005
/// such runs covering 35,533 objects — 44.0% of all groupable allocations.
static bool splitInlineGroupsEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCPREPARE_SPLIT_INLINE_GROUPS");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

/// Mirrors the inline-lowering admissibility of the singleton patterns in
/// EcoToLLVMHeap.cpp: BoxOp of a scalar (:221), ListConstructOp (:445),
/// Tuple2/Tuple3ConstructOp (:670, :759), and Record/CustomConstructOp
/// (:951, :1090) which additionally cap at 4096 bytes.
///
/// AllocateStringOp is deliberately absent: it is groupable but has NO
/// inline singleton path, so splitting a run containing one would trade a shared region call for a per-object alloc call and lose.
/// Whitelist discipline — anything not listed keeps today's grouping.
static bool hasInlineSingletonLowering(Operation *op) {
    if (auto boxOp = dyn_cast<eco::BoxOp>(op)) {
        Type t = boxOp.getValue().getType();
        return t.isInteger(64) || t.isF64() || eco::isEcoCharType(t);
    }
    if (isa<eco::ListConstructOp>(op) || isa<eco::Tuple2ConstructOp>(op) ||
        isa<eco::Tuple3ConstructOp>(op))
        return true;
    if (isa<eco::RecordConstructOp>(op) || isa<eco::CustomConstructOp>(op))
        return getFixedAllocSizeForGrouping(op) <= 4096;
    return false;
}

namespace {
struct MergeCensus {
    uint64_t blocks = 0, groupableAllocs = 0, runs2plus = 0, runObjects = 0;
    uint64_t windows = 0, winNoCall = 0, winLeafOnly = 0, winHardBarrier = 0;
    uint64_t mergeableFree = 0, mergeableLeaf = 0;
    uint64_t blockedDeps = 0, blockedSize = 0;
    uint64_t splitGroups = 0, splitObjects = 0, keptGroups = 0, keptObjects = 0;
};
} // namespace

/// Only written with the census on, when the pass runs serially (B6).
static MergeCensus gCensus;

/// Classification predicate for the merge window: can a later allocation be
/// hoisted ABOVE `op` to join an earlier run?
///
/// The gc-leaf exception is ALWAYS ON here, deliberately and independently of
/// any transform gate. If it were gated, the census — which runs with the
/// transform off — would classify every stamped call as a hard barrier and
/// report structurally zero opportunity, i.e. it would measure its own gate
/// rather than the IR.
static bool isHardMotionBarrier(Operation *op) {
    if (op->hasTrait<OpTrait::IsTerminator>())
        return true;
    // Nested regions can hide anything; do not reason across them.
    if (op->getNumRegions() > 0)
        return true;
    if (isa<eco::PapCreateOp>(op) || isa<eco::PapExtendOp>(op) ||
        isa<eco::PapCreateGroupOp>(op))
        return true;
    if (auto callOp = dyn_cast<eco::CallOp>(op)) {
        // A stamped gc-leaf callee cannot GC and cannot re-enter Elm, so an
        // allocation may legally cross it.
        if (op->hasAttr("eco.callee_gc_leaf"))
            return false;
        auto musttail = callOp.getMusttail();
        if (musttail && *musttail)
            return true; // a tail call ends the block for our purposes
        return true;
    }
    if (isa<func::CallOp>(op))
        return true;
    return false;
}

/// Returns true if the operation is a call of any kind (used to separate
/// "window contained no call at all" from "window contained only gc-leaf
/// calls" — the first needs no kernel facts, the second does).
static bool isAnyCall(Operation *op) {
    return isa<eco::CallOp>(op) || isa<func::CallOp>(op);
}

//===----------------------------------------------------------------------===//
// EcoGCPreparePass
//===----------------------------------------------------------------------===//

struct EcoGCPreparePass
    : public PassWrapper<EcoGCPreparePass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCPreparePass)

    StringRef getArgument() const override { return "eco-gc-prepare"; }
    StringRef getDescription() const override {
        return "Group adjacent allocations and strip call purity attributes";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        // B6 (plans/backend-lowering-optimization.md): the work is strictly
        // per function (grouping and purity attrs on the function's own ops;
        // no module-level writes), so run it in parallel over the
        // top-level functions. The census accumulates into the unsynchronised
        // gCensus global, so census runs stay serial.
        SmallVector<func::FuncOp> funcs;
        for (func::FuncOp f : module.getOps<func::FuncOp>())
            if (!f.isExternal())
                funcs.push_back(f);
        if (censusEnabled() || !getContext().isMultithreadingEnabled()) {
            for (func::FuncOp f : funcs)
                processFunction(f);
        } else {
            eco::forEachChunk(&getContext(), funcs.size(),
                              [&](size_t lo, size_t hi) {
                                  for (size_t i = lo; i < hi; ++i)
                                      processFunction(funcs[i]);
                              });
        }

        if (censusEnabled()) {
            llvm::errs() << "[gcprepare-census] blocks=" << gCensus.blocks
                         << " groupable=" << gCensus.groupableAllocs
                         << " runs>=2=" << gCensus.runs2plus
                         << " runObjects=" << gCensus.runObjects << "\n";
            llvm::errs() << "[gcprepare-census] windows=" << gCensus.windows
                         << " noCall=" << gCensus.winNoCall
                         << " leafOnly=" << gCensus.winLeafOnly
                         << " hardBarrier=" << gCensus.winHardBarrier
                         << " mergeableFree=" << gCensus.mergeableFree
                         << " mergeableLeaf=" << gCensus.mergeableLeaf
                         << " blockedDeps=" << gCensus.blockedDeps
                         << " blockedSize=" << gCensus.blockedSize << "\n";
            llvm::errs() << "[gcprepare-census] splitGroups=" << gCensus.splitGroups
                         << " splitObjects=" << gCensus.splitObjects
                         << " keptGroups=" << gCensus.keptGroups
                         << " keptObjects=" << gCensus.keptObjects << "\n";
        }
    }

private:
    void processFunction(func::FuncOp func) {
        if (func.isExternal()) return;

        LLVM_DEBUG(llvm::dbgs() << "EcoGCPrepare: processing function "
                                << func.getName() << "\n");

        // Walk ALL blocks in the function, including those nested inside
        // regions of ops like scf.while/scf.if.
        func.walk([&](Block *block) {
            processBlock(*block);
        });
    }

    /// kernel-opt-09 Phase 1. Single walk that classifies every merge window in
    /// the block. `apply` is reserved for Phase 2's motion and is always false
    /// today — census and transform share this one code path precisely so they
    /// cannot diverge later.
    ///
    /// A "window" is the run of ops between one groupable allocation and the
    /// next. An empty window means the two are already adjacent and already
    /// group today, so it is not counted. A non-empty window is an opportunity:
    /// merging requires hoisting the later allocation above every op in it.
    void scanBlockForMerges(Block &block, bool apply) {
        (void)apply;
        ++gCensus.blocks;

        Operation *prevAlloc = nullptr;         // tail of the current run
        int64_t runSize = 0;                    // bytes already in the run
        unsigned runMembers = 0;                // members in the current run
        SmallVector<Operation *, 8> window;     // ops since prevAlloc
        llvm::SmallPtrSet<Operation *, 8> runSet;

        auto closeRun = [&]() {
            if (runMembers >= 2) {
                ++gCensus.runs2plus;
                gCensus.runObjects += runMembers;
            }
            runMembers = 0;
            runSize = 0;
            runSet.clear();
        };

        for (auto &op : block) {
            if (isMayAllocOp(&op) && hasFixedAllocSize(&op)) {
                ++gCensus.groupableAllocs;
                int64_t opSize = getFixedAllocSizeForGrouping(&op);

                if (prevAlloc && window.empty()) {
                    // Already adjacent: today's group formation covers it.
                    if (runSize + opSize >= GroupLargeObjectThreshold) {
                        closeRun();
                        runMembers = 1;
                        runSize = opSize;
                    } else {
                        if (runMembers == 0) runMembers = 1;
                        ++runMembers;
                        runSize += opSize;
                    }
                    runSet.insert(&op);
                    prevAlloc = &op;
                    continue;
                }

                if (prevAlloc) {
                    // Non-empty window: an opportunity. Classify it.
                    ++gCensus.windows;
                    bool anyCall = false, hardBarrier = false;
                    for (Operation *w : window) {
                        if (isAnyCall(w)) anyCall = true;
                        if (isHardMotionBarrier(w)) hardBarrier = true;
                    }
                    if (hardBarrier)
                        ++gCensus.winHardBarrier;
                    else if (anyCall)
                        ++gCensus.winLeafOnly;
                    else
                        ++gCensus.winNoCall;

                    if (!hardBarrier) {
                        // Would hoisting be legal and useful? The candidate may
                        // not consume anything defined inside the window or by
                        // a member of the run it would join, and the merged run
                        // must stay under the large-object cap.
                        bool dep = false;
                        llvm::SmallPtrSet<Operation *, 8> windowSet(window.begin(),
                                                                    window.end());
                        for (Value v : op.getOperands()) {
                            Operation *defOp = v.getDefiningOp();
                            if (defOp && (windowSet.contains(defOp) ||
                                          runSet.contains(defOp))) {
                                dep = true;
                                break;
                            }
                        }
                        if (dep)
                            ++gCensus.blockedDeps;
                        else if (runSize + opSize >= GroupLargeObjectThreshold)
                            ++gCensus.blockedSize;
                        else if (anyCall)
                            ++gCensus.mergeableLeaf;
                        else
                            ++gCensus.mergeableFree;
                    }
                }

                // The candidate starts (or extends) a run from here on.
                closeRun();
                runMembers = 1;
                runSize = opSize;
                runSet.insert(&op);
                prevAlloc = &op;
                window.clear();
                continue;
            }

            if (prevAlloc)
                window.push_back(&op);
            // A hard barrier ends the run outright: nothing after it can join.
            if (isHardMotionBarrier(&op)) {
                closeRun();
                prevAlloc = nullptr;
                window.clear();
            }
        }
        closeRun();
    }

    void processBlock(Block &block) {
        if (censusEnabled())
            scanBlockForMerges(block, /*apply=*/false);

        // Step 1: Identify groups of adjacent allocation ops.
        // Only ops with statically known sizes can be grouped.
        // Groups are capped at the large-object threshold to avoid
        // pushing a pile of small allocs into old-gen.
        SmallVector<SmallVector<Operation*, 4>> groups;
        SmallVector<Operation*, 4> currentGroup;
        llvm::SmallPtrSet<Operation *, 8> currentGroupSet;
        int64_t runningSize = 0;

        // Lambda: would `&op` consume the result of any op already in
        // currentGroup? The alloc-group lowering initializes members in
        // fast/slow blocks BEFORE the merge block where member results
        // become available, so intra-group result dependencies violate
        // dominance after CFG surgery. Close the group at such a boundary.
        auto consumesGroupMemberResult = [&](Operation *op) {
            if (currentGroup.empty()) return false;
            for (Value v : op->getOperands()) {
                Operation *defOp = v.getDefiningOp();
                if (defOp && currentGroupSet.contains(defOp))
                    return true;
            }
            return false;
        };

        // Close the current group: move it into `groups` and reset the parallel
        // bookkeeping (the mirror set + running size). Centralized so
        // currentGroupSet can never drift out of sync with currentGroup.
        auto flushGroup = [&]() {
            if (currentGroup.empty()) return;
            groups.push_back(std::move(currentGroup));
            currentGroup.clear();
            currentGroupSet.clear();
            runningSize = 0;
        };

        for (auto &op : block) {
            if (isMayAllocOp(&op)) {
                if (!hasFixedAllocSize(&op)) {
                    // Non-fixed-size op: close current group, add as singleton
                    flushGroup();
                    groups.push_back(SmallVector<Operation*, 4>{&op});
                    continue;
                }
                int64_t opSize = getFixedAllocSizeForGrouping(&op);
                bool wouldDependOnGroupMember = consumesGroupMemberResult(&op);
                if (runningSize + opSize >= GroupLargeObjectThreshold ||
                    wouldDependOnGroupMember) {
                    // Either the size cap or an intra-group SSA dependency:
                    // close the current group first.
                    flushGroup();
                }
                currentGroup.push_back(&op);
                currentGroupSet.insert(&op);
                runningSize += opSize;
            } else {
                flushGroup();
                if (isGroupBarrier(&op)) {
                    // Barrier - any pending group already flushed above
                }
            }
        }
        flushGroup();

        // Step 1b (kernel-opt-09 Phase 2-pre): a run whose every member has a
        // call-free inline lowering is CHEAPER ungrouped — see
        // splitInlineGroupsEnabled. Break those runs into singletons, so the
        // members flow through Step 2 exactly as a lone allocation does.
        // Mixed runs are left alone: splitting one would swap a shared region
        // call for a per-object alloc call.
        if (splitInlineGroupsEnabled() && eco::detail::inlineAllocEnabled()) {
            SmallVector<SmallVector<Operation *, 4>> rebuilt;
            rebuilt.reserve(groups.size());
            for (auto &group : groups) {
                if (group.size() < 2) {
                    rebuilt.push_back(std::move(group));
                    continue;
                }
                bool allInline = llvm::all_of(group, hasInlineSingletonLowering);
                if (censusEnabled()) {
                    if (allInline) {
                        ++gCensus.splitGroups;
                        gCensus.splitObjects += group.size();
                    } else {
                        ++gCensus.keptGroups;
                        gCensus.keptObjects += group.size();
                    }
                }
                if (!allInline) {
                    rebuilt.push_back(std::move(group));
                    continue;
                }
                for (Operation *member : group)
                    rebuilt.push_back(SmallVector<Operation *, 4>{member});
            }
            groups = std::move(rebuilt);
        }

        // Step 2: Stamp each group: the leader carries the member count,
        // every later member is marked as such.
        auto *ctx = block.getParentOp()->getContext();
        for (auto &group : groups) {
            if (group.empty()) continue;

            LLVM_DEBUG({
                llvm::dbgs() << "EcoGCPrepare: alloc group leader "
                             << group.front()->getName()
                             << " at " << group.front()->getLoc()
                             << " — " << group.size() << " members\n";
            });

            group.front()->setAttr("eco.gc_group_size",
                IntegerAttr::get(IntegerType::get(ctx, 64), group.size()));
            for (size_t i = 1; i < group.size(); i++) {
                group[i]->setAttr("eco.gc_group_member",
                    BoolAttr::get(ctx, true));
            }
        }

        // Step 3: kernel-opt-12: the Elm-level purity channel dies HERE.
        // Stripping reverts CallOp::getEffects to its conservative branch for
        // all downstream passes, so no later pass can merge or erase a call
        // on the strength of eco.cse_safe.
        for (auto &op : block) {
            if (isa<eco::CallOp>(&op))
                op.removeAttr(eco::kCseSafeAttrName);
        }
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Creation
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoGCPreparePass() {
    return std::make_unique<EcoGCPreparePass>();
}
