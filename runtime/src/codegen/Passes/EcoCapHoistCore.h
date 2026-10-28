//===- EcoCapHoistCore.h - IR-neutral capacity-hoisting core --------------===//
//
// Capacity-check hoisting (CGEN_074) is decided on the llvm-dialect MLIR module
// by the planning pass in EcoCapHoistPlan.cpp. `applyCapacityHoisting` in
// EcoBackend.cpp runs the same solver on the LLVM module when the module has no
// plan, or to validate one. This component holds the parts that do not depend
// on which IR is being read, so that both sides run the same code.
//
// Capacity-check hoisting replaces the per-allocation nursery check of the
// inline bump allocator (HEAP_034) with one check for many allocations. A
// function's budget is an upper bound on the bytes its own allocation markers
// and the functions it calls allocate, summed along any single execution. A
// function with a finite, nonzero budget that no unseen caller can reach is
// covered: its callers reserve the budget up front, and its own allocations
// need no check. A function whose demand cannot be bounded, or exceeds the
// per-run cap, is top: it keeps its checks.
//
// The component contains four things:
//
// - Readers for the environment variables that switch hoisting and GC-free
//   stamping (CGEN_072) on, off or into census mode. Each reads its variable
//   once per process and caches the answer.
// - `caphoist::solve`, which turns per-function facts gathered by a caller's
//   local scan into budgets (the budget fixpoint) and then into coverage.
// - The names of the function attributes and module flags through which the
//   planning passes hand their results to the backend.
// - Encoders and parsers for the two module-flag values, which record the
//   settings a plan was computed under, so the backend can refuse a plan that
//   was made with different ones.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_CAP_HOIST_CORE_H
#define ECO_CAP_HOIST_CORE_H

#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace eco {

/// How GC-free function propagation (CGEN_072) runs: not at all, as a census
/// that computes and reports which functions are GC-free without stamping
/// them, or stamping `gc-leaf-function` on them.
enum class GcFreeMode { Off, Census, Stamp };

/// Returns the GC-free mode selected by `ECO_GCFREE_LEAF`: `"0"` gives `Off`,
/// `"c"` gives `Census`, and any other value, or none, gives `Stamp`. The
/// variable is read on the first call only.
GcFreeMode gcFreeLeafMode();

/// How capacity-check hoisting runs: not at all, as a census that computes and
/// reports the plan without transforming the module, or applied.
enum class CapHoistMode { Off, Census, On };

/// Returns the hoisting mode selected by `ECO_ALLOC_HOIST`: `"0"` gives `Off`,
/// `"c"` gives `Census`, and any other value, or none, gives `On`. The variable
/// is read on the first call only.
CapHoistMode capHoistMode();

/// Returns K, the largest budget in bytes a hoisted check may reserve; a
/// function whose budget would exceed it is top. It is `ECO_ALLOC_HOIST_MAX_BYTES`
/// parsed as a decimal integer (512 when unset; an empty or non-numeric value
/// gives 8), clamped to [8, 4096] and rounded down to a multiple of 8. 4096 is
/// the largest single inline allocation HEAP_034 allows. The variable is read on the first call only.
unsigned capHoistMaxBytes();

/// Returns whether the own allocation markers of a function that is not covered
/// are folded into a hoisted run (a sequence of allocations served by one
/// check), as well as its calls into covered functions. It is false only
/// when `ECO_ALLOC_HOIST_M2` is exactly `"0"`. The variable is read on the
/// first call only.
bool capHoistFoldOwnMarkers();

/// Returns whether `Elm_Kernel_Utils_equal` is treated as gc-leaf even when the
/// module carries no gc-leaf declaration of it. It is true only when
/// `ECO_VALUE_EQ_GCLEAF` is exactly `"1"`. The variable is read on the first
/// call only.
bool valueEqGcLeafEnv();

/// Returns whether the MLIR pass, rather than the LLVM fixpoint, stamps GC-free
/// functions. It is false only when `ECO_GCFREE_MLIR` is exactly `"0"`. The
/// variable is read on the first call only.
bool gcFreeMlirEnabled();

/// Returns whether the LLVM GC-free fixpoint also runs as a check on the stamps
/// the MLIR pass made. It is true when `ECO_GCFREE_VALIDATE` is set to anything
/// other than an empty string or `"0"`. The variable is read on the first call
/// only.
bool gcFreeValidateEnabled();

namespace gcfree {

/// The name of the module flag that records a GC-free plan; its value is an
/// encoded `Stamp`.
inline constexpr const char *kPlanFlag = "eco-gcfree-plan";

/// The settings a GC-free plan was computed under, as recorded in its module
/// flag.
struct Stamp {
    /// Whether `Elm_Kernel_Utils_equal` was treated as gc-leaf.
    bool valueEqLeaf = false;
    /// Whether a capacity-hoisting plan was present, so that `eco-cap-covered`
    /// attributes were taken into account.
    bool covered = false;
};

/// Returns `s` encoded as a module-flag value, `v1;veq=<0|1>;cov=<0|1>`.
std::string encodeStamp(const Stamp &s);

/// Returns the stamp that `s` encodes. It returns `std::nullopt` unless `s` is
/// `v1` followed by `;`-separated `veq` and `cov` entries, each present, in any
/// order, each with the value `0` or `1`, and nothing else. A repeated key keeps
/// its last value.
std::optional<Stamp> parseStamp(llvm::StringRef s);

} // namespace gcfree

namespace caphoist {

/// Why a function is top. Only the first reason found is kept.
///
/// `solve` sets `Cycle` for a member of a call-graph cycle with unbounded demand,
/// `Budget` for a budget over K, and `Other` for a call to a top callee or to
/// an allocating one it cannot account for. It never sets `Loop`, which is left
/// for the caller's scan to record an allocation inside a loop.
enum class Reason : uint8_t { None, Loop, Cycle, Budget, Other };

/// One defined function, as the budget solver sees it.
///
/// The caller fills `ownBytes`, `top`, `reason`, `eligible`, `selfEdge` and
/// `callees` from a scan of the function; `solve` then fills `budget` and
/// `covered`, and may set `top` and `reason`.
struct Node {
    /// Bytes allocated by the function's own allocation markers.
    uint64_t ownBytes = 0;
    bool top = false;
    Reason reason = Reason::None;
    /// Whether every caller of the function is visible to the plan, so that a
    /// hoisted check can be placed in each of them.
    bool eligible = false;
    /// Whether the function calls itself directly.
    bool selfEdge = false;
    /// Each direct call to a defined function: the callee's index in the
    /// node vector, and whether the call sits inside a loop.
    std::vector<std::pair<uint32_t, bool>> callees;
    /// Output. Meaningful only when `top` is false.
    uint64_t budget = 0;
    /// Output. Whether the function is covered.
    bool covered = false;
};

/// Computes every node's budget and coverage, with `K` as the largest budget
/// allowed.
///
/// Nodes are resolved one strongly connected component of the call graph at a
/// time, callees before callers. A component that is a cycle (more than one
/// node, or one with `selfEdge`) has unbounded demand if any member is top,
/// allocates, or calls outside the cycle a function that is top or has a nonzero
/// budget; then every member becomes top with reason `Cycle`, and otherwise
/// every member gets budget 0. Any other function's budget is its `ownBytes`
/// plus the budgets of its callees. It becomes top with reason `Other` when a
/// callee is top, or when a callee with a nonzero budget is called inside a loop
/// or is not eligible, and with reason `Budget` when the sum exceeds `K`.
/// Callees are examined in order, and the first condition met decides the
/// reason. A reason is recorded only on a node whose reason is still `None`,
/// and a node marked top on input stays top.
///
/// Finally a node is covered when it is eligible, not top, and its budget is
/// nonzero.
///
/// Every callee index in `nodes` must be less than `nodes.size()`, and a node's
/// `selfEdge` must be true exactly when its `callees` contains its own index.
void solve(std::vector<Node> &nodes, uint64_t K);

/// The name of the function attribute `eco-cap-budget`, whose value is the
/// function's budget in decimal bytes.
inline constexpr const char *kAttrBudget = "eco-cap-budget";
/// The name of the valueless function attribute that marks a function top.
inline constexpr const char *kAttrTop = "eco-cap-top";
/// The name of the valueless function attribute that marks a function covered.
inline constexpr const char *kAttrCovered = "eco-cap-covered";
/// The name of the module flag that records a capacity-hoisting plan; its value
/// is an encoded `PlanStamp`.
inline constexpr const char *kPlanFlag = "eco-cap-plan";

/// The settings a capacity-hoisting plan was computed under, as recorded in its
/// module flag.
struct PlanStamp {
    /// The largest budget the plan allowed.
    unsigned K = 0;
    /// Whether own markers were folded, as `capHoistFoldOwnMarkers` reports.
    bool m2 = true;
    /// Whether eligibility was decided under the closed-world assumption.
    bool closedWorld = false;
    /// Whether `Elm_Kernel_Utils_equal` was treated as gc-leaf.
    bool valueEqLeaf = false;
};

/// Returns `s` encoded as a module-flag value, `v1;K=<n>;m2=<0|1>;cw=<0|1>;veq=<0|1>`.
std::string encodePlanStamp(const PlanStamp &s);

/// Returns the stamp that `s` encodes. It returns `std::nullopt` unless `s` is
/// `v1` followed by `;`-separated `K`, `m2`, `cw` and `veq` entries, each
/// present, in any order, and nothing else, with `K` a decimal integer that fits
/// an `unsigned`. A flag value of `1` reads as true and any other value as
/// false. A repeated key keeps its last value.
std::optional<PlanStamp> parsePlanStamp(llvm::StringRef s);

} // namespace caphoist
} // namespace eco

#endif // ECO_CAP_HOIST_CORE_H
