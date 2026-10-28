//===- EcoGCPrepare.cpp - GC preparation pass -----------------------------===//
//
// The lowering of eco allocations to the LLVM dialect can allocate several adjacent objects with
// one request, but it does not choose which objects to combine. This module pass chooses, and
// marks its choice in attributes the lowering reads. It also removes the purity attribute from
// calls, so that no later pass treats a call as pure.
//
// An allocation group is a run of allocations in one block that the lowering allocates together:
// one region for their combined size, then each member initialised in place. Every op
// `isMayAllocOp` names (the eco ops that allocate a heap object directly) is put in exactly one
// group, often a group of one. The first member, the leader, gets
// `eco.gc_group_size`, the number of members as an i64, and every later member gets
// `eco.gc_group_member`. A group of more than one is a run of fixed-size allocations with nothing
// else between them, and it ends before:
//
// - any other op, including calls and partial-application ops, which may allocate but are not
//   grouped;
// - an allocation whose size is not fixed, which becomes a group of its own;
// - a member that would bring the group's total to `GroupLargeObjectThreshold` or more;
// - a member that takes the result of an earlier member as an operand. The lowering initialises the
//   members in blocks that come before the one where their results are defined, so such a use would
//   not be dominated by its definition.
//
// A group whose members all have an inline lowering, which allocates with a bump of the nursery
// pointer and calls the runtime only when the nursery is full, is then split back into groups of
// one, because the group lowering makes one call for the region and another for each member.
// `splitInlineGroupsEnabled` says when.
//
// Each member's size here must agree byte for byte with the size the lowering computes
// (`computeAllocSize` in EcoToLLVMHeap.cpp); the two are separate copies.
//
// The second job is `eco.cse_safe`, the attribute that marks an `eco.call` as safe to merge with
// an identical call or to erase when unused. The pass removes it from every `eco.call` in the functions it
// processes (see `EcoGCPreparePass`), after which `eco::CallOp`'s reported effects are the
// conservative ones for every later pass.
//
// The pass computes no GC roots. Roots, statepoints and stack maps come later, from LLVM's
// RewriteStatepointsForGC.
//
// With `ECO_GCPREPARE_CENSUS` set, the pass also counts, without changing anything, how many
// allocations could join an earlier group if they were moved up past the ops between, and prints
// the counts to stderr.
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

/// Returns whether `op` is one of the eco ops that allocate a heap object, and so belongs in an
/// allocation group.
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

/// Returns whether `op` allocates an object whose size `getFixedAllocSizeForGrouping` knows, which
/// is what a group of more than one requires: a string allocation, a list cell, a tuple, a record,
/// a custom value, or a box of an i64, f64 or i16. Closure allocations, `eco.allocate` and a box
/// of any other type are not.
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

/// Returns the size in bytes, a multiple of 8, of the object `op` allocates, or 0 when `op` is not
/// one `hasFixedAllocSize` accepts.
///
/// The values must agree with `computeAllocSize` in EcoToLLVMHeap.cpp, which the group lowering
/// uses to size the region.
static int64_t getFixedAllocSizeForGrouping(Operation *op) {
    constexpr int64_t HeaderSize = 8;

    if (auto allocStr = dyn_cast<eco::AllocateStringOp>(op)) {
        int64_t size = HeaderSize + allocStr.getLength() * 2;
        return (size + 7) & ~7;
    }
    if (isa<eco::ListConstructOp>(op)) return 24;
    if (isa<eco::Tuple2ConstructOp>(op)) return 24;
    if (isa<eco::Tuple3ConstructOp>(op)) return 32;
    // Includes the extension kind words that follow the fields of a wide record or custom.
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

/// The combined size in bytes that an allocation group must stay below. A member that would bring
/// the total to this or more starts a new group instead.
///
/// This is not the runtime's default large-object threshold, `LARGE_OBJECT_THRESHOLD`, which is
/// 8 KiB. EcoToLLVMHeap.cpp and Heap.hpp assert that the widest record and custom are smaller than
/// 32 KiB, each with its own copy of the number.
static constexpr int64_t GroupLargeObjectThreshold = 32 * 1024; // 32 KiB

/// Returns whether `op` is a terminator, a partial-application op (`eco.papCreate`,
/// `eco.papExtend`) or a call.
///
/// Grouping does not depend on the answer: `processBlock` ends a group at every op that
/// `isMayAllocOp` rejects, and these ops are among them.
static bool isGroupBarrier(Operation *op) {
    if (op->hasTrait<OpTrait::IsTerminator>())
        return true;
    if (isa<eco::PapCreateOp>(op) || isa<eco::PapExtendOp>(op))
        return true;
    if (isa<eco::CallOp>(op))
        return true;
    if (isa<func::CallOp>(op))
        return true;
    return false;
}

//===----------------------------------------------------------------------===//
// The merge census
//
// Counts how many allocations could join an earlier run of allocations if they were moved up past
// the ops that separate them. It only counts and changes no IR.
//===----------------------------------------------------------------------===//

/// Returns whether the merge census is on, which it is when `ECO_GCPREPARE_CENSUS` is set to any
/// value. The environment is read once.
static bool censusEnabled() {
    static const bool on = ::getenv("ECO_GCPREPARE_CENSUS") != nullptr;
    return on;
}

/// Returns whether a group whose members all have an inline lowering is split into groups of one.
/// True unless `ECO_GCPREPARE_SPLIT_INLINE_GROUPS` is exactly `0`. The environment is read once.
///
/// The split is made because a group lowers to a call of `eco_gc_alloc_region_fast` and one
/// `eco_init_*_at` call per member, while each of the same ops lowered alone is allocated inline,
/// with a runtime call only on the nursery-full path, and stored directly. `processBlock` splits
/// only when `eco::detail::inlineAllocEnabled()` is also true, since otherwise there is no inline lowering.
static bool splitInlineGroupsEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCPREPARE_SPLIT_INLINE_GROUPS");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

/// Returns whether `op`, lowered on its own, is allocated inline: a box of an i64, f64 or i16, a
/// list cell, a tuple, or a record or custom of at most 4096 bytes. This must agree with the
/// patterns in EcoToLLVMHeap.cpp that lower each of these ops outside a group.
///
/// A string allocation can be in a group but is never allocated inline, so it returns false, and
/// a group containing one is kept: splitting it would replace one region call with an allocation
/// call per object. Any op not listed also returns false.
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
/// The merge census's counts, accumulated over every run of the pass in the process.
///
/// A run is a sequence of adjacent groupable allocations, cut at the size limit but not at
/// member-result uses, so it may span several groups; `runs2plus` and `runObjects` count the runs
/// of two or more and their members. A window is the non-empty
/// sequence of ops between the last allocation of a run and the next groupable allocation, and
/// `windows` counts them, split into `winNoCall`, `winLeafOnly` (calls, all gc-leaf) and
/// `winHardBarrier`. `winHardBarrier` stays 0, because a hard barrier ends the run before a window
/// containing it is classified. A window with no hard barrier is counted once more: `blockedDeps` when the
/// next allocation uses a result from the window or the run, `blockedSize` when it would bring the
/// run to `GroupLargeObjectThreshold` or more, otherwise `mergeableLeaf` or `mergeableFree`.
/// `splitGroups`/`splitObjects` and `keptGroups`/`keptObjects` count the groups of two or more
/// that were split into groups of one or kept, and their members, while the split is on.
struct MergeCensus {
    uint64_t blocks = 0, groupableAllocs = 0, runs2plus = 0, runObjects = 0;
    uint64_t windows = 0, winNoCall = 0, winLeafOnly = 0, winHardBarrier = 0;
    uint64_t mergeableFree = 0, mergeableLeaf = 0;
    uint64_t blockedDeps = 0, blockedSize = 0;
    uint64_t splitGroups = 0, splitObjects = 0, keptGroups = 0, keptObjects = 0;
};
} // namespace

/// The census counts since the process started; the pass never resets them, so each run prints
/// cumulative totals. It has no lock, and is written only when the census
/// is on, in which case `runOnOperation` processes the functions on one thread.
static MergeCensus gCensus;

/// Returns whether `op` is one that a later allocation could not be moved above to join an earlier
/// run: a terminator, an op with regions, a partial-application op (`eco.papCreate`,
/// `eco.papExtend`, `eco.papCreateGroup`), a `func.call`, or an `eco.call` without
/// `eco.callee_gc_leaf`. An `eco.call` with that attribute calls a function that cannot collect,
/// so it is not a barrier.
static bool isHardMotionBarrier(Operation *op) {
    if (op->hasTrait<OpTrait::IsTerminator>())
        return true;
    // An op's regions may hold anything, so nothing is moved across it.
    if (op->getNumRegions() > 0)
        return true;
    if (isa<eco::PapCreateOp>(op) || isa<eco::PapExtendOp>(op) ||
        isa<eco::PapCreateGroupOp>(op))
        return true;
    if (auto callOp = dyn_cast<eco::CallOp>(op)) {
        if (op->hasAttr("eco.callee_gc_leaf"))
            return false;
        auto musttail = callOp.getMusttail();
        if (musttail && *musttail)
            return true;
        return true;
    }
    if (isa<func::CallOp>(op))
        return true;
    return false;
}

/// Returns whether `op` is an `eco.call` or a `func.call`. The census uses it to tell a window with
/// no call from one whose calls are all gc-leaf.
static bool isAnyCall(Operation *op) {
    return isa<eco::CallOp>(op) || isa<func::CallOp>(op);
}

//===----------------------------------------------------------------------===//
// EcoGCPreparePass
//===----------------------------------------------------------------------===//

/// The pass that forms and marks allocation groups and removes `eco.cse_safe`, as the file comment
/// describes, in every function defined at the top level of a module.
struct EcoGCPreparePass
    : public PassWrapper<EcoGCPreparePass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoGCPreparePass)

    StringRef getArgument() const override { return "eco-gc-prepare"; }
    StringRef getDescription() const override {
        return "Group adjacent allocations and strip call purity attributes";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        // Each function's work writes only attributes of that function's own ops, so functions
        // run in parallel. The census writes the unlocked gCensus, so with it on they run on one
        // thread.
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
    /// Processes every block of `func`, including the blocks nested in the regions of its ops.
    /// Does nothing for a declaration.
    void processFunction(func::FuncOp func) {
        if (func.isExternal()) return;

        LLVM_DEBUG(llvm::dbgs() << "EcoGCPrepare: processing function "
                                << func.getName() << "\n");

        func.walk([&](Block *block) {
            processBlock(*block);
        });
    }

    /// Adds the merge census counts for `block` to `gCensus`, as `MergeCensus` defines them. Changes
    /// no IR; `apply` is ignored.
    ///
    /// Runs are cut at the size threshold, at a hard motion barrier, and at any other op between
    /// allocations (the allocation after it is counted as starting a new run), but not, unlike
    /// groups, where one member uses another's result.
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
                        // must stay under `GroupLargeObjectThreshold`.
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

                // The census counts the candidate as starting a new run, whether or not it could
                // have joined the last one.
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

    /// Forms the allocation groups of `block` and marks them, then removes `eco.cse_safe` from each
    /// `eco.call` directly in `block`. The blocks nested in its ops' regions are left to their own
    /// call.
    void processBlock(Block &block) {
        if (censusEnabled())
            scanBlockForMerges(block, /*apply=*/false);

        SmallVector<SmallVector<Operation*, 4>> groups;
        SmallVector<Operation*, 4> currentGroup;
        llvm::SmallPtrSet<Operation *, 8> currentGroupSet;
        int64_t runningSize = 0;

        // Returns whether `op` uses a result of a member of currentGroup. The group lowering
        // initialises members in blocks that precede the one where their results are defined, so
        // such a use would not be dominated by its definition.
        auto consumesGroupMemberResult = [&](Operation *op) {
            if (currentGroup.empty()) return false;
            for (Value v : op->getOperands()) {
                Operation *defOp = v.getDefiningOp();
                if (defOp && currentGroupSet.contains(defOp))
                    return true;
            }
            return false;
        };

        // Ends the current group, if it has members, and resets currentGroupSet and runningSize
        // with it, so that they always describe currentGroup.
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
                    flushGroup();
                    groups.push_back(SmallVector<Operation*, 4>{&op});
                    continue;
                }
                int64_t opSize = getFixedAllocSizeForGrouping(&op);
                bool wouldDependOnGroupMember = consumesGroupMemberResult(&op);
                if (runningSize + opSize >= GroupLargeObjectThreshold ||
                    wouldDependOnGroupMember) {
                    flushGroup();
                }
                currentGroup.push_back(&op);
                currentGroupSet.insert(&op);
                runningSize += opSize;
            } else {
                flushGroup();
                if (isGroupBarrier(&op)) {
                    // Nothing to do: flushGroup above has already ended the group at every op isMayAllocOp
                    // rejects.
                }
            }
        }
        flushGroup();

        // Split each group whose members all have an inline lowering into groups of one. A group
        // with any other member is kept whole.
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

        // Without eco.cse_safe, CallOp::getEffects reports the conservative effects to every later
        // pass.
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

// The contract is on the declaration in Passes.h.
std::unique_ptr<Pass> eco::createEcoGCPreparePass() {
    return std::make_unique<EcoGCPreparePass>();
}
