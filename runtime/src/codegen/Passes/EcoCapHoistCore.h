//===- EcoCapHoistCore.h - IR-neutral capacity-hoisting core --------------===//
//
// Shared by the LLVM backend (applyCapacityHoisting, EcoBackend.cpp) and the
// MLIR planning pass (EcoCapHoistPlan.cpp): the configuration readers, the
// Phase B (budget fixpoint over call-graph SCCs) + Phase C (coverage) solver,
// and the plan-stamp / attribute vocabulary. One algorithm, two front ends,
// so the two sides cannot drift.
//
// plans/mlir-split-backend-01-cap-hoist-plan.md Part II (P2), CGEN_074.
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

// ECO_GCFREE_LEAF (plans/gc-free-function-propagation.md): unset/other =
// Stamp (default), "0" = Off, "c" = Census.
enum class GcFreeMode { Off, Census, Stamp };
GcFreeMode gcFreeLeafMode();

// ECO_ALLOC_HOIST (plans/capacity-check-hoisting.md): unset/other = On
// (default), "0" = Off, "c" = Census.
enum class CapHoistMode { Off, Census, On };
CapHoistMode capHoistMode();

// Per-run byte budget cap K (ECO_ALLOC_HOIST_MAX_BYTES, default 512, clamped
// to [8, 4096], rounded down to a multiple of 8).
unsigned capHoistMaxBytes();

// M2: fold a root function's own markers into a run (ECO_ALLOC_HOIST_M2,
// default on).
bool capHoistFoldOwnMarkers();

// ECO_VALUE_EQ_GCLEAF=1: stamp Elm_Kernel_Utils_equal gc-leaf even when the
// module did not keep its MLIR declaration (value-eq arm 3, plan 02 O5).
bool valueEqGcLeafEnv();
// ECO_GCFREE_MLIR (plan 02): unset/other = the MLIR pass stamps (default),
// "0" = the LLVM fixpoint stays the producer.
bool gcFreeMlirEnabled();
// ECO_GCFREE_VALIDATE=1: run the LLVM fixpoint as a twin of the MLIR stamps.
bool gcFreeValidateEnabled();

namespace gcfree {
inline constexpr const char *kPlanFlag = "eco-gcfree-plan"; // module flag
struct Stamp {
    bool valueEqLeaf = false; // veq
    bool covered = false;     // eco-cap-covered was read (cap plan present)
};
std::string encodeStamp(const Stamp &s);
std::optional<Stamp> parseStamp(llvm::StringRef s);
} // namespace gcfree

namespace caphoist {

enum class Reason : uint8_t { None, Loop, Cycle, Budget, Other };

// One defined function. Phase A fills the inputs; solve() fills the outputs.
struct Node {
    uint64_t ownBytes = 0;
    bool top = false;
    Reason reason = Reason::None;
    bool eligible = false;
    bool selfEdge = false;
    std::vector<std::pair<uint32_t, bool>> callees; // (node index, inLoop)
    uint64_t budget = 0;  // output, valid iff !top
    bool covered = false; // output
};

// Phase B (iterative Tarjan, callees before callers) + Phase C, exactly the
// rules of EcoBackend.cpp's applyCapacityHoisting before the split.
void solve(std::vector<Node> &nodes, uint64_t K);

// ---- vocabulary shared by the MLIR plan and the LLVM consumer -----------
inline constexpr const char *kAttrBudget = "eco-cap-budget";  // key=value
inline constexpr const char *kAttrTop = "eco-cap-top";        // bare
inline constexpr const char *kAttrCovered = "eco-cap-covered"; // bare
inline constexpr const char *kPlanFlag = "eco-cap-plan";      // module flag

struct PlanStamp {
    unsigned K = 0;
    bool m2 = true;
    bool closedWorld = false;
    bool valueEqLeaf = false; // the marker table's value-eq row, as planned
};
std::string encodePlanStamp(const PlanStamp &s);
std::optional<PlanStamp> parsePlanStamp(llvm::StringRef s);

} // namespace caphoist
} // namespace eco

#endif // ECO_CAP_HOIST_CORE_H
