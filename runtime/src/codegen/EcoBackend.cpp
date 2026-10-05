//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

#include "LoweringStats.h"
#include "Passes/EcoPtrIntVerify.h" // for addEcoGCPipeline
#include "Passes/EcoCapHoistCore.h"  // CGEN_074 core + config (shared with EcoCapHoistPlan)
#include "Passes/EcoMarkerFacts.h"   // marker table (plan 01 P3)
#include "Passes/EcoSlotCastBarriers.h" // REP_LLVM_002: barrier switch <-> gcfree-guard coupling

#include "mlir/ExecutionEngine/OptUtils.h" // for makeOptimizingTransformer

#include <algorithm>

#include "llvm/IR/Function.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Analysis/ConstantFolding.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"   // getDefaultTargetTriple
#include "llvm/TargetParser/Triple.h"
#include "llvm/Transforms/IPO/Internalize.h"
#include "llvm/Transforms/IPO/GlobalDCE.h"
#include "llvm/Transforms/IPO/SCCP.h"           // IPSCCPPass
#include "llvm/Transforms/IPO/GlobalOpt.h"      // GlobalOptPass
#include "llvm/Transforms/IPO/FunctionAttrs.h"  // Post/ReversePostOrderFunctionAttrsPass
#include "llvm/Transforms/IPO/AlwaysInliner.h"  // AlwaysInlinerPass
#include "llvm/Analysis/CGSCCPassManager.h"     // createModuleToPostOrderCGSCCPassAdaptor
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Passes/OptimizationLevel.h"
#include "llvm/Transforms/Utils/SplitModule.h"
#include "llvm/Transforms/Utils/Local.h"        // callsGCLeafFunction (GCFREE)
#include "llvm/Analysis/TargetLibraryInfo.h"    // TargetLibraryInfo (GCFREE)
#include "llvm/IR/Statepoint.h"                 // GCStatepointInst (GCFREE)
#include "llvm/ADT/SCCIterator.h"               // scc_iterator (CAPHOIST)
#include "llvm/IR/CFG.h"                        // GraphTraits<Function*> (CAPHOIST)
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include <cstdlib>  // getenv/strtoul (E1.3 threshold override)
#include <fstream>  // ECO_CAP_INLINE_LIST delta-debug hook
#include <queue>
#include <map>
#include <set>
#include "llvm/Support/Format.h"
#include <chrono>
#include <string>
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalIFunc.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"                    // call-census name cache
#include "llvm/Transforms/Utils/ModuleUtils.h"     // appendToGlobalCtors (call-census)
#include "llvm/Transforms/Utils/BasicBlockUtils.h" // SplitBlockAndInsertIfThen
#include "../allocator/Heap.hpp"                   // TAG_BITS, Elm::Tag_Forward

#include <cstddef>  // offsetof (kernel-opt-04 header-size probe)
#include <cstdint>

#include <array>    // call-census bucket filter
#include <cstring>  // strcmp (call-census env gate)
#include <atomic>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace llvm;

namespace eco {

// Plan 05 (EcoSplit): the partition a worker thread lowers; -1 outside a
// partition worker. Every diagnostic file a worker writes gets a `.p<i>`
// suffix so N threads never truncate the same path (review R9).
static thread_local int tlPartitionIndex = -1;

void setPartitionIndex(int i) { tlPartitionIndex = i; }

std::string partitionDumpPath(StringRef path) {
    if (tlPartitionIndex < 0)
        return path.str();
    return path.str() + ".p" + std::to_string(tlPartitionIndex);
}

namespace {

// RAII sub-phase timing scope that is a no-op when `stats` is null.
struct MaybeScope {
    MaybeScope(eco::LoweringStats *stats, llvm::StringRef name) {
        if (stats)
            scope.emplace(*stats, name);
    }
    std::optional<eco::LoweringStats::Scope> scope;
};

// True when the caller NAMED an env variable, whatever its value. The
// GC-free / capacity-hoisting passes are default-ON, so their one-line
// summaries would otherwise print on every ordinary build; gating the
// summaries on this keeps normal `eco make` output clean while every A/B
// recipe — which always sets the variable explicitly, on every arm — still
// gets its non-vacuity line.
bool envNamed(const char *key) {
    const char *e = ::getenv(key);
    return e && *e;
}

// GC-free function propagation (plans/gc-free-function-propagation.md).
//
// ECO_GCFREE_LEAF: unset (DEFAULT) or "1"/any other value = stamp
// gc-leaf-function on provably GC-free generated functions so RS4GC skips
// statepointing calls to them; "0" = off (escape hatch); "c" = census only
// (analysis runs, nothing is stamped, the module is byte-identical to an
// off run).
//
// Lowering-affecting in stamp mode: census/A-B workflows must rebuild via
// the delete-outputs discipline (ninja is env-blind, tier2-opt.md Phase 1).
//
// Defined HERE (not next to propagateGcFreeLeafAttrs, ~:1419) because the
// stamp-mode structural assert lives in runRS4GCAndMaybeFramePointers
// (~:651), ~750 lines earlier than that function.
// GcFreeMode / gcFreeLeafMode(), CapHoistMode / capHoistMode(),
// capHoistMaxBytes() and capHoistFoldOwnMarkers() live in
// Passes/EcoCapHoistCore.{h,cpp}: the MLIR planning pass (EcoCapHoistPlan)
// reads the same switches (plans/mlir-split-backend-01-cap-hoist-plan.md P2).

void dumpIRTo(const Module &m, const std::string &path0, const char *tag) {
    const std::string path = partitionDumpPath(path0);
    std::error_code ec;
    raw_fd_ostream out(path, ec);
    if (!ec) {
        out << m;
        errs() << "[" << tag << "] Dumped " << tag << " IR to " << path
               << "\n";
    } else {
        errs() << "[" << tag << "] Error: could not open " << path << ": "
               << ec.message() << "\n";
    }
}

//===----------------------------------------------------------------------===//
// Call-kind survivor census (plans/call-survivor-census.md).
//
// Counts SURVIVING call instructions — what remains after every inliner and
// DCE has run — as opposed to the MLIR-lowering-time `fast` counter, which is
// emitted in the caller before the call and therefore survives when
// runCapInlinePrepass inlines the call away (a LOGICAL count). Instrumented
// here, at the emitObjectFile funnel, every AOT path (serial, whole-module,
// both parallel-split variants, single-object inline pipeline) is covered
// after its last IR transformation.
//
// Gated on ECO_CALL_CENSUS at lowering time: unset => zero IR emitted, the
// binary is bit-identical to an uninstrumented build. The value "1"/"all"
// counts every bucket; a comma list ("elm,cap,helper") counts only those
// buckets (the rest still get static site tallies). The census workflow is
// the only consumer — never set this under the E2E harness (env-blind
// binary cache, same rule as ECO_LSS_DISPATCH_SITE_COUNTERS).
//
// Buckets (enum MIRRORED in runtime/src/allocator/RuntimeExports.cpp — keep
// in sync):
//   elm      generated Elm code (defined here or a cross-partition decl)
//   kernel   Elm_Kernel_* / Eco_Kernel_* boundary calls
//   cap      surviving direct calls to *$cap fast clones (survivor `fast`)
//   helper   the 6 dispatch-trampoline entries — one of these plus one
//            runtime-internal indirect call is ONE logical dispatch, so they
//            must never be summed with the other buckets as "calls"
//   runtime  other eco_*/__eco_*/elm_*/Eco_Runtime_* helpers (alloc, proj,
//            stores, pap-extend — which never dispatches)
//   extern   libm/libc
//   indirect non-constant callee — expected ~0 in generated code
//===----------------------------------------------------------------------===//

enum CallCensusKind : uint8_t {
    CK_Elm = 0, CK_Kernel, CK_Cap, CK_Helper,
    CK_Runtime, CK_Extern, CK_Indirect, CK_COUNT
};

const char *callCensusKindName(uint8_t k) {
    switch (k) {
    case CK_Elm:      return "elm";
    case CK_Kernel:   return "kernel";
    case CK_Cap:      return "cap";
    case CK_Helper:   return "helper";
    case CK_Runtime:  return "runtime";
    case CK_Extern:   return "extern";
    case CK_Indirect: return "indirect";
    }
    return "?";
}

bool callCensusEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CALL_CENSUS");
        return e && *e && std::strcmp(e, "0") != 0;
    }();
    return on;
}

// Bucket filter from the env value. "1"/"all" => everything; otherwise a
// comma list of bucket names. An unrecognised token counts nothing (loud in
// the static line: counted=0).
bool callCensusKindCounted(uint8_t k) {
    static const auto counted = [] {
        std::array<bool, CK_COUNT> c{};
        const char *e = ::getenv("ECO_CALL_CENSUS");
        StringRef v = e ? e : "";
        if (v.empty() || v == "1" || v == "all") {
            c.fill(true);
            return c;
        }
        SmallVector<StringRef> toks;
        v.split(toks, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
        for (StringRef tok : toks)
            for (uint8_t i = 0; i < CK_COUNT; ++i)
                if (tok.trim() == callCensusKindName(i))
                    c[i] = true;
        return c;
    }();
    return counted[k];
}

// The dispatch-machinery entry points emitted into generated code
// (EcoToLLVMClosures.cpp: emitInlineClosureCall / the generic funnel).
// eco_pap_extend is deliberately ABSENT: it never dispatches
// (RuntimeExports.cpp "No dispatch here — this grows a PAP") => runtime.
bool callCensusIsTrampoline(StringRef n) {
    return n == "eco_apply_closure" || n == "eco_apply_closure_eval" ||
           n == "eco_apply_segmentation_unknown" ||
           n == "eco_apply_closure_typed" ||
           n == "eco_closure_call_saturated" ||
           n == "eco_closure_call_saturated_eval";
}

bool callCensusIsExtern(StringRef n) {
    static const std::set<std::string> externs = {
        "acos", "asin", "atan", "atan2", "sin", "cos", "tan", "exp",
        "log", "log2", "log10", "pow", "fmod", "floor", "ceil", "sqrt",
        "fabs", "trunc", "round", "ldexp",
        "memcpy", "memset", "memmove", "memcmp", "malloc", "free"};
    return externs.count(n.str()) != 0;
}

// Classify a RESOLVED call target (statepoint-unwrapped, casts stripped).
// By NAME, never isDeclaration(): after the partition split a cross-partition
// Elm callee is a declaration in the calling partition (plan AR-4).
uint8_t callCensusClassify(const Function *fn) {
    if (!fn)
        return CK_Indirect;
    StringRef n = fn->getName();
    if (callCensusIsTrampoline(n))
        return CK_Helper;
    if (n.ends_with("$cap"))
        return CK_Cap;
    if (n.starts_with("Elm_Kernel_") || n.starts_with("Eco_Kernel_"))
        return CK_Kernel;
    if (n.starts_with("eco_") || n.starts_with("__eco_") ||
        n.starts_with("elm_") || n.starts_with("Eco_Runtime_"))
        return CK_Runtime;
    if (callCensusIsExtern(n))
        return CK_Extern;
    return CK_Elm;
}

// Instrument one (partition) module. Runs concurrently on disjoint modules in
// disjoint LLVMContexts from the split workers; the only shared state is the
// mutex-guarded stderr tally. The increment is a plain non-atomic
// load/add/store (single-mutator workload; census-grade under future
// threads), touches no GC pointer (safe before a statepoint), and inserting
// BEFORE a call is legal even for musttail (constraints only bind what
// follows the call).
void instrumentCallCensus(Module &m) {
    if (m.getNamedGlobal("__eco_census_counts"))
        return; // idempotence guard

    struct Site {
        CallBase *cb;
        const Function *callee; // null => indirect
        uint8_t kind;
    };
    std::vector<Site> sites;
    uint64_t staticTally[CK_COUNT] = {};
    uint64_t skippedIntrinsics = 0;

    // Pass 1 — collect (mutating while iterating a BB is the classic
    // invalidation bug; all insertion happens in pass 3).
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        for (BasicBlock &bb : f)
            for (Instruction &inst : bb) {
                auto *cb = dyn_cast<CallBase>(&inst);
                if (!cb || cb->isInlineAsm())
                    continue;
                // RS4GC-wrapped calls carry the real callee inside the
                // statepoint; unwrap BEFORE the intrinsic skip. Never use
                // getCalledFunction(): it returns null on the fast form's
                // deliberate site-derived function-type mismatch.
                const Value *target;
                if (auto *sp = dyn_cast<GCStatepointInst>(cb))
                    target = sp->getActualCalledOperand()
                                 ->stripPointerCastsAndAliases();
                else
                    target = cb->getCalledOperand()
                                 ->stripPointerCastsAndAliases();
                const Function *fn = dyn_cast<Function>(target);
                if (fn && (fn->isIntrinsic() ||
                           fn->getName().starts_with("llvm."))) {
                    ++skippedIntrinsics; // gc.relocate/result, memcpy, ...
                    continue;
                }
                uint8_t kind = callCensusClassify(fn);
                ++staticTally[kind];
                if (callCensusKindCounted(kind))
                    sites.push_back({cb, fn, kind});
            }
    }

    // Static tally line (per partition; awk-summable), under a mutex — the
    // split workers run this concurrently.
    {
        static std::mutex tallyMu;
        std::lock_guard<std::mutex> lock(tallyMu);
        errs() << "[call-census] partition sites:";
        for (uint8_t k = 0; k < CK_COUNT; ++k)
            errs() << " " << callCensusKindName(k) << "=" << staticTally[k];
        errs() << " skipped_intrinsics=" << skippedIntrinsics
               << " counted=" << sites.size() << "\n";
    }
    if (sites.empty())
        return; // empty filler partitions register nothing

    // Pass 2 — materialize tables + the registration ctor. All private;
    // liveness is rooted by the ctor's call into the runtime (AR-8).
    LLVMContext &ctx = m.getContext();
    auto *i64Ty = Type::getInt64Ty(ctx);
    auto *i8Ty = Type::getInt8Ty(ctx);
    auto *ptrTy = PointerType::get(ctx, 0);
    const uint64_t n = sites.size();

    auto *countsTy = ArrayType::get(i64Ty, n);
    auto *counts = new GlobalVariable(
        m, countsTy, /*isConstant=*/false, GlobalValue::PrivateLinkage,
        ConstantAggregateZero::get(countsTy), "__eco_census_counts");
    counts->setAlignment(Align(8));

    StringMap<Constant *> nameCache;
    auto nameStr = [&](StringRef s) -> Constant * {
        auto it = nameCache.find(s);
        if (it != nameCache.end())
            return it->second;
        Constant *data = ConstantDataArray::getString(ctx, s, true);
        auto *gv = new GlobalVariable(m, data->getType(), /*isConstant=*/true,
                                      GlobalValue::PrivateLinkage, data,
                                      "__eco_census_str");
        gv->setUnnamedAddr(GlobalValue::UnnamedAddr::Global);
        nameCache[s] = gv;
        return gv;
    };

    SmallVector<Constant *> nameConsts, kindConsts;
    nameConsts.reserve(n);
    kindConsts.reserve(n);
    for (const Site &s : sites) {
        nameConsts.push_back(
            nameStr(s.callee ? s.callee->getName() : StringRef("<indirect>")));
        kindConsts.push_back(ConstantInt::get(i8Ty, s.kind));
    }
    auto *namesTy = ArrayType::get(ptrTy, n);
    auto *names = new GlobalVariable(
        m, namesTy, /*isConstant=*/true, GlobalValue::PrivateLinkage,
        ConstantArray::get(namesTy, nameConsts), "__eco_census_names");
    auto *kindsTy = ArrayType::get(i8Ty, n);
    auto *kinds = new GlobalVariable(
        m, kindsTy, /*isConstant=*/true, GlobalValue::PrivateLinkage,
        ConstantArray::get(kindsTy, kindConsts), "__eco_census_kinds");

    FunctionCallee reg = m.getOrInsertFunction(
        "eco_call_census_register",
        FunctionType::get(Type::getVoidTy(ctx), {ptrTy, ptrTy, ptrTy, i64Ty},
                          /*isVarArg=*/false));

    auto *ctorTy = FunctionType::get(Type::getVoidTy(ctx), false);
    Function *ctor = Function::Create(ctorTy, GlobalValue::PrivateLinkage,
                                      "__eco_census_ctor", &m);
    IRBuilder<> cb(BasicBlock::Create(ctx, "entry", ctor));
    cb.CreateCall(reg, {counts, names, kinds, ConstantInt::get(i64Ty, n)});
    cb.CreateRetVoid();
    appendToGlobalCtors(m, ctor, /*Priority=*/65535);

    // Pass 3 — the increments, immediately before each surviving call.
    for (uint64_t i = 0; i < n; ++i) {
        IRBuilder<> ib(sites[i].cb);
        Value *slot = ib.CreateConstInBoundsGEP2_64(countsTy, counts, 0, i);
        Value *cur = ib.CreateLoad(i64Ty, slot);
        Value *inc = ib.CreateAdd(cur, ConstantInt::get(i64Ty, 1));
        ib.CreateStore(inc, slot);
    }
}

Error emitObjectFile(Module &m, TargetMachine &tm, const std::string &path) {
    if (callCensusEnabled())
        instrumentCallCensus(m);
    std::error_code ec;
    raw_fd_ostream dest(path, ec, sys::fs::OF_None);
    if (ec)
        return createStringError(ec,
            "Could not open object file output '" + path + "': " +
            ec.message());

    legacy::PassManager emitPM;
    if (tm.addPassesToEmitFile(emitPM, dest, nullptr,
                                CodeGenFileType::ObjectFile))
        return createStringError(std::errc::not_supported,
            "Target machine can't emit object files");

    emitPM.run(m);
    dest.flush();
    return Error::success();
}

// Map the codegen opt level to a PassBuilder OptimizationLevel. The
// simplification pipelines assert O0 is invalid, so anything <1 maps to O2
// (parallel-opt is only reached when optLevel != None).
OptimizationLevel toOptLevel(CodeGenOptLevel lvl) {
    switch (lvl) {
    case CodeGenOptLevel::Less:
        return OptimizationLevel::O1;
    case CodeGenOptLevel::Aggressive:
        return OptimizationLevel::O3;
    case CodeGenOptLevel::Default:
    default:
        return OptimizationLevel::O2;
    }
}

// ECO_OPT_PASS_TIMES=1: exclusive wall time per new-PM pass (and analysis),
// summed over every partition worker, printed by eco-boot-native at exit.
// Diagnostic only; nothing is registered when the variable is unset.
bool optPassTimesEnabled() {
    static const bool on = ::getenv("ECO_OPT_PASS_TIMES") != nullptr;
    return on;
}
struct OptPassTimesGlobal {
    std::mutex mu;
    llvm::StringMap<std::pair<double, uint64_t>> total; // seconds, calls
};
OptPassTimesGlobal &optPassTimesGlobal() {
    static OptPassTimesGlobal g;
    return g;
}
// One pipeline run on one thread: a stack of open passes, so each pass is
// charged its own time minus the time of the passes nested inside it.
struct OptPassTimer {
    using Clock = std::chrono::steady_clock;
    struct Frame {
        std::string name;
        Clock::time_point start;
        double child = 0;
    };
    std::vector<Frame> stack;
    llvm::StringMap<std::pair<double, uint64_t>> local;

    void push(std::string name) { stack.push_back({std::move(name), Clock::now()}); }
    void pop() {
        if (stack.empty())
            return;
        Frame f = std::move(stack.back());
        stack.pop_back();
        double el = std::chrono::duration<double>(Clock::now() - f.start).count();
        auto &e = local[f.name];
        e.first += el - f.child;
        e.second += 1;
        if (!stack.empty())
            stack.back().child += el;
    }
    void attach(PassInstrumentationCallbacks &pic) {
        pic.registerBeforeNonSkippedPassCallback(
            [this](StringRef p, Any) { push(p.str()); });
        pic.registerAfterPassCallback(
            [this](StringRef, Any, const PreservedAnalyses &) { pop(); });
        pic.registerAfterPassInvalidatedCallback(
            [this](StringRef, const PreservedAnalyses &) { pop(); });
        pic.registerBeforeAnalysisCallback(
            [this](StringRef p, Any) { push(("analysis: " + p).str()); });
        pic.registerAfterAnalysisCallback([this](StringRef, Any) { pop(); });
    }
    ~OptPassTimer() {
        auto &g = optPassTimesGlobal();
        std::lock_guard<std::mutex> lock(g.mu);
        for (auto &kv : local) {
            auto &e = g.total[kv.first()];
            e.first += kv.second.first;
            e.second += kv.second.second;
        }
    }
};
// No-inline per-partition pipeline (Dev tier): honour explicit `alwaysinline`
// attrs, then run the standard per-function simplification pipeline
// (InstCombine / SROA / GVN / SimplifyCFG / LICM / vectorizers …) with NO CGSCC
// inliner. That fused inliner+simplification is the bulk of an -O2 pipeline's
// wall-clock; dropping the inliner makes the rest embarrassingly parallel.
Error runNoInlineFunctionPipeline(Module &m, TargetMachine *tm,
                                  CodeGenOptLevel optLevel, bool devOptO1) {
    PassInstrumentationCallbacks pic;
    std::optional<OptPassTimer> timer;
    if (optPassTimesEnabled()) {
        timer.emplace();
        timer->attach(pic);
    }
    PassBuilder PB(tm, PipelineTuningOptions(), std::nullopt, &pic);
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    MPM.addPass(AlwaysInlinerPass());
    MPM.addPass(createModuleToFunctionPassAdaptor(
        PB.buildFunctionSimplificationPipeline(
            devOptO1 ? OptimizationLevel::O1 : toOptLevel(optLevel),
            ThinOrFullLTOPhase::None)));
    MPM.run(m, MAM);
    return Error::success();
}

// Eco's -O<n> module pipeline (plans/backend-lowering-optimization.md A3).
// Same shape as mlir::makeOptimizingTransformer (buildPerModuleDefaultPipeline
// with unrolling + interleaving on) EXCEPT:
//   - SLP and loop vectorization OFF: eco code is pointer-chasing; 0.06 % of
//     the produced instructions touched vector registers while SLP alone was
//     11 % of opt time;
//   - CalledValuePropagation skipped: it only attaches !callees metadata, and
//     after RS4GC every indirect call is a gc.statepoint.
Error runEcoModuleOpt(Module &m, TargetMachine *tm, CodeGenOptLevel optLevel) {
    OptimizationLevel ol = toOptLevel(optLevel);
    PipelineTuningOptions pto;
    pto.LoopUnrolling = true;
    pto.LoopInterleaving = true;
    pto.LoopVectorization = false;
    pto.SLPVectorization = false;

    PassInstrumentationCallbacks pic;
    pic.registerShouldRunOptionalPassCallback([](StringRef pass, Any) {
        return pass != "CalledValuePropagationPass";
    });
    std::optional<OptPassTimer> timer;
    if (optPassTimesEnabled()) {
        timer.emplace();
        timer->attach(pic);
    }

    PassBuilder PB(tm, pto, std::nullopt, &pic);
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    if (ol == OptimizationLevel::O0)
        MPM.addPass(PB.buildO0DefaultPipeline(ol));
    else
        MPM.addPass(PB.buildPerModuleDefaultPipeline(ol));
    MPM.run(m, MAM);
    return Error::success();
}

// Optimize one partition module in place according to the parallel-opt tier.
// Dev  = no-inline function pipeline (fast, lower quality).
// Cgu  = full -O2 per partition (keeps intra-partition CGSCC inlining).
Error optimizePartitionModule(Module &m, TargetMachine *tm, ParallelOpt mode,
                              CodeGenOptLevel optLevel, bool devOptO1) {
    if (mode == ParallelOpt::Cgu) {
        return runEcoModuleOpt(m, tm, optLevel);
    }
    return runNoInlineFunctionPipeline(m, tm, optLevel, devOptO1);
}

// Split the (already RS4GC'd + optimized) module into N partitions and emit
// each to its own object file on its own thread. Object emission (ISel /
// MC / codegen) is the single largest phase of the AOT backend and is
// per-function work, so splitting it across cores is a near-linear win.
//
// When `perPartitionMode != None`, each partition is additionally OPTIMIZED in
// its worker thread (before emission) — this is how the opt stage itself is
// parallelized (the whole-module -O2 is skipped upstream and replaced with a
// cheap IPO prologue + this per-partition optimization).
//
// Correctness notes:
//   - PreserveLocals=false: llvm::SplitModule EXTERNALIZES (single definition,
//     unique name) any local global referenced across partitions rather than
//     duplicating it, so GC-root globals (eco.global cells, the type graph and
//     its private satellite arrays) keep exactly one definition — no
//     premature-reclamation landmine.
//   - Each partition is round-tripped through bitcode into its OWN LLVMContext
//     (LLVMContext is not thread-safe) and gets its OWN TargetMachine
//     (MCContext / AsmPrinter state is not shareable across threads).
//   - RS4GC ran once on the whole module BEFORE the split, so statepoints and
//     the frame-pointer attr are already in place and are preserved losslessly
//     through bitcode. Each partition emits a .llvm_stackmaps blob for its own
//     functions; the linker concatenates them and StackMap::parse reads all
//     blobs (multi-blob loop).
// (X) join (plan 02 Q7, F5): a gc-leaf DECLARATION in one partition is only
// as good as its owner's stamped DEFINITION in another; no per-partition check
// can see that link. Each worker reports after its RS4GC; the driver joins.
static void collectGcLeafReport(const Module &m, GcLeafPartitionReport &r) {
    if (gcFreeLeafMode() != GcFreeMode::Stamp)
        return;
    for (const Function &f : m) {
        const bool leaf = f.hasFnAttribute("gc-leaf-function");
        if (f.isDeclaration()) {
            if (leaf)
                r.leafDecls.push_back(f.getName().str());
            continue;
        }
        r.allDefs.push_back(f.getName().str());
        if (leaf)
            r.stampedDefs.push_back(f.getName().str());
    }
}

Error checkCrossPartitionGcLeaf(
    const std::vector<GcLeafPartitionReport> &reports) {
    if (gcFreeLeafMode() != GcFreeMode::Stamp)
        return Error::success();
    llvm::StringSet<> defs, stamped;
    for (const auto &r : reports) {
        for (const auto &n : r.allDefs)
            defs.insert(n);
        for (const auto &n : r.stampedDefs)
            stamped.insert(n);
    }
    unsigned decls = 0, checked = 0;
    for (const auto &r : reports)
        for (const auto &n : r.leafDecls) {
            ++decls;
            if (!defs.contains(n))
                continue; // runtime / kernel declaration: trusted base
            ++checked;
            if (!stamped.contains(n))
                return createStringError(
                    std::errc::invalid_argument,
                    "cross-partition gc-leaf declaration '%s' has an "
                    "unstamped owner (CGEN_072 X)",
                    n.c_str());
        }
    if (const char *e = ::getenv("ECO_GCFREE_PLAN_STATS"); e && *e && *e != '0')
        errs() << "[gcfree-x] partitions=" << reports.size()
               << " decls=" << decls << " checked=" << checked << "\n";
    return Error::success();
}

Error emitObjectFilesSplit(Module &m, unsigned numPartitions,
                           const std::vector<std::string> &paths,
                           CodeGenOptLevel optLevel,
                           ParallelOpt perPartitionMode,
                           unsigned devEmitCG, bool devOptO1,
                           eco::LoweringStats *stats,
                           const RS4GCOptions *partitionRS4GC) {
    if (paths.size() != numPartitions)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: paths count != numPartitions");

    // Serialize each partition to bitcode in the parent context and DISPATCH
    // its worker immediately — the remaining partitions' clone+serialize then
    // overlaps with already-running workers instead of gating all of them.
    // (SplitModule hands sub-modules over one at a time on this thread;
    // LLVMContext is not thread-safe, hence the bitcode hand-off.)
    std::vector<SmallString<0>> bitcodes(numPartitions);
    std::atomic<unsigned> nextFail{0};
    std::vector<std::string> errs(numPartitions);
    std::vector<std::thread> threads;
    threads.reserve(numPartitions);
    std::vector<GcLeafPartitionReport> gcReports(numPartitions);

    auto worker = [&, optLevel, perPartitionMode, devEmitCG, devOptO1](unsigned i) {
        LLVMContext ctx;
        auto buf = MemoryBuffer::getMemBuffer(
            StringRef(bitcodes[i].data(), bitcodes[i].size()),
            "eco-partition", /*RequiresNullTerminator=*/false);
        auto modOr = parseBitcodeFile(buf->getMemBufferRef(), ctx);
        if (!modOr) {
            errs[i] = "parseBitcodeFile failed for partition " +
                      std::to_string(i);
            nextFail++;
            return;
        }
        std::unique_ptr<Module> mod = std::move(*modOr);
        // Dev tier may emit at a cheaper CodeGen level than optLevel; this TM
        // also feeds runNoInlineFunctionPipeline's PassBuilder TTI (acceptable).
        unsigned emitLevel = static_cast<unsigned>(optLevel);
        if (perPartitionMode == ParallelOpt::Dev && devEmitCG != ~0u)
            emitLevel = devEmitCG;
        auto tm = createEcoTargetMachine(*mod, emitLevel);
        if (!tm) {
            errs[i] = "createEcoTargetMachine failed for partition " +
                      std::to_string(i);
            nextFail++;
            return;
        }
        // Per-partition RS4GC (+ frame pointers): when the caller skipped the
        // whole-module RS4GC (parallel-opt modes), each worker statepoints its
        // own partition here — RS4GC is per-function and consults only callee
        // DECLARATION attrs (gc-leaf-function), which CloneModule preserved,
        // so partition-local RS4GC is semantically identical to whole-module
        // (design doc finding: per-partition RS4GC confirmed safe). It runs
        // BEFORE opt, preserving the RS4GC-before-optimization GC invariant
        // per partition.
        if (partitionRS4GC) {
            MaybeScope s(stats, "  partition RS4GC (sum over workers)");
            runRS4GCAndMaybeFramePointers(*mod, *partitionRS4GC);
        }
        collectGcLeafReport(*mod, gcReports[i]);
        // Parallel opt: optimize this partition on its own thread before
        // emission (the whole-module -O2 was skipped upstream).
        if (perPartitionMode != ParallelOpt::None) {
            MaybeScope s(stats, "  partition opt (sum over workers)");
            if (auto err = optimizePartitionModule(
                    *mod, tm.get(), perPartitionMode, optLevel, devOptO1)) {
                errs[i] = "partition opt failed for partition " +
                          std::to_string(i) + ": " +
                          toString(std::move(err));
                nextFail++;
                return;
            }
        }
        MaybeScope s(stats, "  partition emit (sum over workers)");
        if (auto err = emitObjectFile(*mod, *tm, paths[i])) {
            errs[i] = "emitObjectFile failed for partition " +
                      std::to_string(i) + ": " + toString(std::move(err));
            nextFail++;
            return;
        }
    };

    unsigned idx = 0;
    {
        MaybeScope s(stats, "  split + bitcode serialize (serial)");
        SplitModule(
            m, numPartitions,
            [&](std::unique_ptr<Module> mp) {
                if (idx < numPartitions) {
                    {
                        raw_svector_ostream os(bitcodes[idx]);
                        WriteBitcodeToFile(*mp, os);
                    }
                    // Free the partition clone before dispatching; the worker
                    // re-materializes from bitcode in its own context.
                    mp.reset();
                    threads.emplace_back(worker, idx);
                }
                ++idx;
            },
            /*PreserveLocals=*/false);
    }

    unsigned produced = std::min(idx, numPartitions);
    if (produced == 0)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: SplitModule produced no partitions");

    {
        MaybeScope s(stats, "  parallel opt+emit drain (post-split wait)");
        for (auto &t : threads)
            t.join();
    }

    // Any unused partition slots (produced < numPartitions) get an empty
    // object so the linker still finds every expected path. In practice
    // SplitModule always produces exactly numPartitions parts, but guard it.
    for (unsigned i = produced; i < numPartitions; ++i) {
        LLVMContext ctx;
        Module empty("eco-empty-partition", ctx);
        empty.setTargetTriple(m.getTargetTriple());
        empty.setDataLayout(m.getDataLayout());
        auto tm = createEcoTargetMachine(empty,
                                         static_cast<unsigned>(optLevel));
        if (tm)
            if (auto err = emitObjectFile(empty, *tm, paths[i]))
                consumeError(std::move(err));
    }

    if (nextFail.load() != 0) {
        for (auto &e : errs)
            if (!e.empty())
                return createStringError(std::errc::io_error, "%s", e.c_str());
    }
    return checkCrossPartitionGcLeaf(gcReports);
}


// Externalize every module-local symbol to a single ExternalLinkage +
// HiddenVisibility definition — replicates llvm::SplitModule's
// PreserveLocals=false behaviour so cross-partition references resolve at link
// time when each partition keeps only its own definitions. (eco's module has
// no aliases/comdats/ifuncs and no unnamed globals, so this is the whole job;
// the defensive name/alias/ifunc handling mirrors SplitModule for safety.)
void externalizeAllLocals(Module &m) {
    auto ext = [](GlobalValue &GV) {
        if (GV.hasLocalLinkage()) {
            // setVisibility(Hidden) requires non-local linkage, so promote first.
            GV.setLinkage(GlobalValue::ExternalLinkage);
            GV.setVisibility(GlobalValue::HiddenVisibility);
        }
        if (!GV.hasName())
            GV.setName("__eco_lazysplit"); // symbol table auto-uniquifies
    };
    for (Function &F : m.functions())
        ext(F);
    for (GlobalVariable &G : m.globals())
        ext(G);
    for (GlobalAlias &A : m.aliases())
        ext(A);
    for (GlobalIFunc &I : m.ifuncs())
        ext(I);
}


} // namespace

// Plan 05 (EcoSplit): the driver-level join of the workers' gc-leaf reports.
Error joinPartitionGcLeafReports(
    const std::vector<GcLeafPartitionReport> &reports) {
    return checkCrossPartitionGcLeaf(reports);
}

// The shared split policy on a defined-function count, so EcoSplit can apply
// it to the MLIR module before translation (plan 05 U4).
unsigned choosePartitionCountForCount(unsigned numDefinedFns, unsigned request,
                                      bool eligible) {
    if (!eligible || request == 1)
        return 1;
    // Only split modules with enough functions to amortize the per-partition
    // thread + link overhead. ECO_SPLIT_MIN_FUNCS lowers the threshold so
    // tests can force a split on small programs.
    static const unsigned kMinFnsToSplit = [] {
        if (const char *e = ::getenv("ECO_SPLIT_MIN_FUNCS"))
            return (unsigned)strtoul(e, nullptr, 10);
        return 4000u;
    }();
    if (numDefinedFns < kMinFnsToSplit)
        return 1;
    unsigned cores = std::max(1u, std::thread::hardware_concurrency());
    // Auto uses all cores. The old min(cores,16) cap existed because
    // llvm::SplitModule's serial split + N bitcode serializations grew with N
    // and ate the emission gain past ~16. The default tiers now partition in
    // MLIR (EcoSplit, plan 05: no serialization at all), and a 24-core
    // self-host sweep showed backend time still dropping at N=24 (dev
    // 12.4->10.1 s from N=16, no plateau). See backendstats-runs.txt.
    unsigned want = (request == 0) ? cores : request;
    // ~1 partition per 2000 functions, at least 2 once we've decided to split.
    unsigned bySize = std::max(2u, numDefinedFns / 2000u);
    return std::min(want, bySize);
}

namespace {

// Decide how many object-emission partitions to use. This is the split policy
// that used to live inline in eco-boot.cpp; hoisting it here means every driver
// (eco-boot, the unified `eco` native driver, ecoc) gets the same partitioned
// codegen for free. `request`: 0 = auto, 1 = off, N = explicit. `eligible` is
// true only for plain executable output. See
// design_docs/backend-parallel-optimization.md §8.1.
unsigned choosePartitionCount(const Module &m, unsigned request, bool eligible) {
    unsigned numDefinedFns = 0;
    for (const Function &F : m)
        if (!F.isDeclaration())
            ++numDefinedFns;
    return choosePartitionCountForCount(numDefinedFns, request, eligible);
}

} // namespace

std::unique_ptr<TargetMachine> createEcoTargetMachine(Module &module,
                                                      unsigned optLevel) {
    auto triple = sys::getDefaultTargetTriple();
    module.setTargetTriple(Triple(triple));

    std::string error;
    const Target *target = TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        errs() << "Error: Could not find target: " << error << "\n";
        return nullptr;
    }

    TargetOptions targetOpts;
    // Emit each function/data global into its own section so a later
    // `--gc-sections` link can trim dead code at section granularity. Harmless
    // for shared-lib output. (The .llvm_stackmaps section must be KEPT
    // explicitly at link time — see linkExecutable — since nothing relocates
    // into it.)
    targetOpts.FunctionSections = true;
    targetOpts.DataSections = true;
    auto codeGenOpt = static_cast<CodeGenOptLevel>(std::min(optLevel, 3u));

    // Pin CPU/features (kEcoTargetCPU) — no host detection. Host detection
    // baked the build machine's AVX-512 into emitted binaries, which then
    // SIGILL'd on x86-64-v3 CPUs.
    TargetMachine *tm = target->createTargetMachine(
        Triple(triple), kEcoTargetCPU, kEcoTargetFeatures, targetOpts,
        Reloc::PIC_, CodeModel::Small, codeGenOpt);
    if (!tm) {
        errs() << "Error: Could not create TargetMachine\n";
        return nullptr;
    }

    module.setDataLayout(tm->createDataLayout());
    return std::unique_ptr<TargetMachine>(tm);
}

// Local check (plan 02 Q7, F6-F8): before RS4GC, in every flavour, every
// stamped definition may only make calls RS4GC will not statepoint. This is
// independent of hasGC(), so it also covers functions RS4GC never processes
// (__eco_init_globals), where the post-RS4GC assert below is vacuous.
static void checkStampedBodies(Module &m) {
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);
    for (Function &f : m) {
        if (f.isDeclaration() || !f.hasFnAttribute("gc-leaf-function"))
            continue;
        if (f.isInterposable() || f.hasAvailableExternallyLinkage())
            report_fatal_error(Twine("[gcfree] stamped function '") +
                               f.getName() +
                               "' has interposable or available_externally "
                               "linkage");
        for (BasicBlock &bb : f)
            for (Instruction &i : bb)
                if (auto *cb = dyn_cast<CallBase>(&i))
                    if (!llvm::callsGCLeafFunction(cb, TLI)) {
                        const Function *c = cb->getCalledFunction();
                        report_fatal_error(
                            Twine("[gcfree] stamped function '") +
                            f.getName() + "' calls '" +
                            (c ? c->getName() : StringRef("<indirect>")) +
                            "', which may GC");
                    }
    }
}

void runRS4GCAndMaybeFramePointers(Module &m, const RS4GCOptions &opts) {
    if (!opts.preDumpPath.empty())
        dumpIRTo(m, opts.preDumpPath, "pre-rs4gc");

    if (gcFreeLeafMode() == GcFreeMode::Stamp)
        checkStampedBodies(m);

    // RS4GC pipeline: inserts gc.statepoint/gc.relocate for all
    // GC-triggering calls in functions with gc "eco-gc".
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PassBuilder PB;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    addEcoGCPipeline(MPM);
    MPM.run(m, MAM);

    if (!opts.postDumpPath.empty())
        dumpIRTo(m, opts.postDumpPath, "rs4gc");

    // GCFREE self-check (plans/gc-free-function-propagation.md §2.6): a
    // stamped function that RS4GC still statepointed means the fixpoint was
    // unsound — a wrongly-stamped function that allocates leaves unrelocated
    // stale pointers in its callers. RS4GC processes a function on hasGC()
    // alone (a callee's own gc-leaf attr does NOT stop it), so this scan is
    // a real check, not a vacuous one. Placed after the post-RS4GC dump so a
    // failing build still leaves the IR on disk. Stamp mode only.
    if (gcFreeLeafMode() == GcFreeMode::Stamp) {
        for (Function &f : m) {
            if (f.isDeclaration() || !f.hasFnAttribute("gc-leaf-function"))
                continue;
            for (BasicBlock &bb : f)
                for (Instruction &i : bb)
                    if (auto *cb = dyn_cast<CallBase>(&i))
                        if (isa<GCStatepointInst>(cb))
                            report_fatal_error(
                                Twine("[gcfree] stamped function contains a "
                                      "statepoint after RS4GC: ") +
                                f.getName());
        }
    }

    // Frame pointers for GC root discovery. Blanket mode (default):
    // frame-pointer=all on every defined function. ECO_FP_LEAF: only on
    // functions that can hold GC-relevant frame state — ones containing a
    // statepoint (their stackmap records are read mid-walk) or a stack-range
    // registration (shadow-root prologue AND the rooted arg/capture-array
    // sites in EcoToLLVMClosures.cpp; the over-stamp is deliberate — do NOT
    // tighten this to an entry-block-only scan). Statepoint-free functions
    // can never be on the stack during a GC walk (all their calls are
    // gc-leaf, so no GC can begin beneath them), and the walker is CFI-driven
    // anyway (ThreadLocalHeap.cpp collectStackRootsFromStackMap +
    // StackUnwind.cpp), so they may release rbp as an allocatable register.
    // plans/gc-free-function-propagation.md §3.
    if (opts.addFramePointerAttr) {
        // Default-ON since 2026-08-09; ECO_FP_LEAF=0 is the escape hatch.
        static const bool fpLeaf = [] {
            const char *e = ::getenv("ECO_FP_LEAF");
            return !e || !*e || !(e[0] == '0' && e[1] == '\0');
        }();
        unsigned numStamped = 0, numLeaf = 0;
        for (Function &F : m) {
            if (F.isDeclaration())
                continue;
            bool needsFP = !fpLeaf;
            if (!needsFP) {
                for (BasicBlock &bb : F) {
                    for (Instruction &i : bb) {
                        auto *cb = dyn_cast<CallBase>(&i);
                        if (!cb)
                            continue;
                        if (isa<GCStatepointInst>(cb)) {
                            needsFP = true;
                            break;
                        }
                        if (Function *cf = cb->getCalledFunction();
                            cf && cf->getName() == "eco_gc_push_stack_range") {
                            needsFP = true;
                            break;
                        }
                    }
                    if (needsFP)
                        break;
                }
            }
            if (needsFP) {
                F.addFnAttr("frame-pointer", "all");
                ++numStamped;
            } else {
                ++numLeaf;
            }
        }
        if (fpLeaf && envNamed("ECO_FP_LEAF")) {
            // Single write: worker flavours run this concurrently and
            // llvm::errs() is unbuffered — chained << would interleave.
            std::string line;
            raw_string_ostream os(line);
            os << "[gcfree-fp] frame-pointer=all on " << numStamped
               << " statepointed, omitted on " << numLeaf
               << " statepoint-free functions\n";
            llvm::errs() << os.str();
        }
    }
}

void internalizeAndDCEForExecutable(Module &m) {
    // Preserve exactly the two symbols the C entry lib (eco_entry.cpp) resolves
    // by name: the program entry and the GC-root/type-graph initializer. Every
    // other generated symbol (Elm top-level functions, __eco_type_graph,
    // __eco_root_module, string globals, ...) is reached only internally from
    // these two or their call graph, so internalizing them is safe and lets
    // GlobalDCE drop the unreachable remainder.
    internalizeAndDCE(m, {"eco_main", "__eco_init_globals"});
}

bool hasReachabilityStamp(const Module &m) {
    return m.getModuleFlag("eco-reach") != nullptr;
}

static void stripReachabilityStamp(Module &m);

// CGEN_081 (plans/mlir-split-backend-03-reachability.md R5): EcoReachability
// already erased and internalized in MLIR, so the LLVM side keeps only
// GlobalDCE's dead-constant-user sanitizer (translation's folder can leave
// dangling ConstantExprs that would flip Function::hasAddressTaken for
// CGEN_074). Under ECO_REACH_VALIDATE=1 the old internalize + GlobalDCE runs
// as an oracle and must change nothing.
Error finishReachability(Module &m, ArrayRef<std::string> keep,
                         bool partition) {
    if (!hasReachabilityStamp(m))
        return createStringError(std::errc::invalid_argument,
                                 "finishReachability: no eco-reach stamp");
    stripReachabilityStamp(m);
    for (Function &f : m)
        f.removeDeadConstantUsers();
    for (GlobalVariable &g : m.globals())
        g.removeDeadConstantUsers();

    static const bool validate = [] {
        const char *e = ::getenv("ECO_REACH_VALIDATE");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    // Plan 05 R20: per partition the oracle would internalize + GlobalDCE
    // away every definition only another partition references.
    if (!validate || partition)
        return Error::success();
    StringMap<GlobalValue::LinkageTypes> before;
    for (GlobalValue &gv : m.global_values())
        before[gv.getName()] = gv.getLinkage();
    const size_t nBefore = before.size();
    internalizeAndDCE(m, keep);
    size_t nAfter = 0;
    unsigned changed = 0;
    for (GlobalValue &gv : m.global_values()) {
        ++nAfter;
        auto it = before.find(gv.getName());
        if (it == before.end() || it->second != gv.getLinkage()) {
            if (++changed <= 20)
                errs() << "[reach-validate] linkage changed: '"
                       << gv.getName() << "'\n";
        }
    }
    errs() << "[reach-validate] symbols=" << nBefore
           << " removed_by_llvm=" << (nBefore - nAfter)
           << " linkage_changed=" << changed << "\n";
    if (nBefore != nAfter || changed)
        return createStringError(
            std::errc::invalid_argument,
            "reachability validate: LLVM internalize + GlobalDCE changed the "
            "MLIR-reached module (%zu removed, %u relinked)",
            nBefore - nAfter, changed);
    return Error::success();
}

Error checkAddressTaken(const Module &m, const StringMap<bool> &mlirTaken) {
    unsigned compared = 0, mismatch = 0;
    for (const Function &f : m) {
        if (f.isDeclaration())
            continue;
        StringRef n = f.getName();
        auto it = mlirTaken.find(n);
        if (it == mlirTaken.end() && n == "eco_main")
            it = mlirTaken.find("main"); // renamed after translation
        if (it == mlirTaken.end())
            continue; // LLVM-created
        ++compared;
        if (it->second != f.hasAddressTaken() && ++mismatch <= 20)
            errs() << "[reach-validate] address-taken mismatch '" << n
                   << "': mlir=" << it->second
                   << " llvm=" << f.hasAddressTaken() << "\n";
    }
    errs() << "[reach-validate] compared=" << compared
           << " addr_mismatch=" << mismatch << "\n";
    if (mismatch)
        return createStringError(std::errc::invalid_argument,
                                 "reachability validate: %u address-taken "
                                 "mismatches", mismatch);
    return Error::success();
}

void internalizeAndDCE(Module &m, ArrayRef<std::string> keep) {
    StringSet<> keepSet;
    for (const std::string &k : keep)
        keepSet.insert(k);
    auto mustPreserve = [&](const GlobalValue &GV) {
        return keepSet.contains(GV.getName());
    };
    internalizeModule(m, mustPreserve);

    // Drop now-unreachable internal functions/globals before RS4GC + opt +
    // codegen process them.
    PassBuilder PB;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    ModulePassManager MPM;
    MPM.addPass(GlobalDCEPass());
    MPM.run(m, MAM);
}

// Plan P2 (--inline-deref). Expand each `__eco_resolve_fwd` marker call into an
// inline forwarding-check diamond:
//
//     %hdr   = load i32, ptr addrspace(1) %h, align 8   ; object header word
//     %tag   = and i32 %hdr, TAG_MASK
//     %isfwd = icmp eq i32 %tag, Tag_Forward
//     br i1 %isfwd, label %fwd, label %cont, !prof !unlikely   ; predicted cont
//   fwd:
//     %r = call ptr addrspace(1) @eco_follow_forward(ptr addrspace(1) %h) [gc-leaf]
//     br label %cont
//   cont:
//     %base = phi [ %h, %head ], [ %r, %fwd ]   ; replaces the marker result
//
// Runs on the whole module at the very start of runEcoBackend — i.e. before ANY
// RewriteStatepointsForGC pass (whole-module serial, deferred, or per-partition)
// and before module splitting — so RS4GC sees the fully-expanded diamond and
// tracks %base / the field pointers derived from it as ordinary GC pointers.
// The header load stays in addrspace(1); no ptrtoint is introduced. Callee
// eco_follow_forward is gc-leaf so RS4GC inserts no statepoint around the cold
// call. Idempotent / cheap when there are no markers (flag off).
static void expandInlineDerefs(Module &m) {
    Function *marker = m.getFunction("__eco_resolve_fwd");
    if (!marker || marker->use_empty())
        return;

    LLVMContext &ctx = m.getContext();
    Type *i32Ty = Type::getInt32Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee followCallee = m.getOrInsertFunction(
        "eco_follow_forward", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(followCallee.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    // Forwarding is rare (only during an old-gen compaction window): weight the
    // taken (fwd) edge far below the fall-through so the cold call is laid out
    // out of line.
    MDNode *unlikely = mdb.createBranchWeights(/*fwd=*/1, /*cont=*/1u << 20);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *h = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        LoadInst *hdr = b.CreateAlignedLoad(i32Ty, h, Align(8), "eco.hdr");
        Value *tag = b.CreateAnd(hdr, tagMask);
        Value *isfwd = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Forward), "eco.isfwd");

        // Split ci's block at ci; insert an if(isfwd) then-block. thenTerm is the
        // unconditional branch terminating the new then-block.
        Instruction *thenTerm = SplitBlockAndInsertIfThen(
            isfwd, ci, /*Unreachable=*/false, unlikely);
        BasicBlock *thenBB = thenTerm->getParent();
        BasicBlock *headBB = thenBB->getSinglePredecessor();

        IRBuilder<> tb(thenTerm);
        CallInst *fwd = tb.CreateCall(followCallee, {h}, "eco.fwd");

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.base");
        phi->addIncoming(h, headBB);
        phi->addIncoming(fwd, thenBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }
}

// Capacity-check hoisting decisions (plans/capacity-check-hoisting.md,
// CGEN_074) — the output of applyCapacityHoisting, consumed by
// expandInlineAllocs to pick the expansion form per marker. Empty (or null)
// means "expand everything as HEAP_034 diamonds", i.e. today's behaviour.
struct CapHoistDecisions {
    // M1: functions whose ENTIRE marker population expands unchecked. Their
    // capacity guarantee is established by their callers (or, transitively,
    // by their callers' callers).
    DenseSet<Function *> coveredFns;
    // M2: individual markers inside NON-covered functions that a
    // caller-local ensure diamond covers. Disjoint from coveredFns by
    // construction — covered functions are never run-scanned (plan §2.3).
    DenseSet<CallInst *> uncheckedMarkers;

    bool isUnchecked(CallInst *marker) const {
        return coveredFns.contains(marker->getFunction()) ||
               uncheckedMarkers.contains(marker);
    }
};

//===----------------------------------------------------------------------===//
// Bump-state access (plans/inline-bump-state-tls.md)
//
// Both bump-state consumers — the HEAP_034 allocation diamond
// (expandInlineAllocs) and the CGEN_074 hoisted capacity check
// (applyCapacityHoisting) — need the address of the calling thread's
// {ptr, end} struct. `eco_bump_state()`'s body is already call-free, but it
// lives in EcoRuntimeStatic, invisible to LLVM here (no LTO), so every use
// paid a call/ret plus the caller-saved clobber a call forces at the site.
// The survivor census measured 10,462,396,845 of them on one self-compile —
// the largest single row in the census.
//
// `eco_tl_bump_state` (defined in Allocator.cpp) caches exactly what
// eco_bump_state() returns and is written only by Allocator::setThreadHeap,
// so it cannot drift from `tl_heap_`. Caching the ADDRESS is sound because it
// is thread-stable (`nursery_` is a direct member of ThreadLocalHeap, `bump_`
// a direct member of NurserySpace, so `&bump_` never moves); the CONTENTS are
// still re-loaded per use, exactly as before.
//
// NOT for the JIT: ORC cannot resolve an initial-exec TLS reference from
// JIT'd code, so callers pass allowTls=false there and keep the call.
//===----------------------------------------------------------------------===//

static bool bumpStateInlineEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_INLINE_BUMP_STATE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

static GlobalVariable *getOrCreateBumpStateTls(Module &m) {
    if (auto *gv = m.getGlobalVariable("eco_tl_bump_state", /*AllowInternal=*/true))
        return gv;
    auto *gv = new GlobalVariable(
        m, PointerType::get(m.getContext(), 0), /*isConstant=*/false,
        GlobalValue::ExternalLinkage, /*Initializer=*/nullptr,
        "eco_tl_bump_state", /*InsertBefore=*/nullptr,
        GlobalValue::InitialExecTLSModel);
    gv->setAlignment(Align(8));
    return gv;
}

// Emit the bump-state address at `b`'s insert point. `tls` non-null selects
// the TLS load; otherwise the runtime call is kept.
static Value *emitBumpStateAddr(IRBuilder<> &b, GlobalVariable *tls,
                                FunctionCallee bumpStateCallee) {
    if (!tls)
        return b.CreateCall(bumpStateCallee, {}, "eco.bump.state");
    Value *slot = b.CreateThreadLocalAddress(tls);
    return b.CreateAlignedLoad(b.getPtrTy(0), slot, Align(8), "eco.bump.state");
}

// Inline nursery allocation (plans/inline-nursery-allocation.md, HEAP_034).
// Expand each `__eco_alloc_inline(SIZE)` marker call into the bump-pointer
// fast/slow diamond:
//
//     %state = call ptr @eco_bump_state()          ; memory(none) gc-leaf
//     %top   = load ptr addrspace(1), ptr %state   ; bump.ptr at +0
//     %end   = load ptr addrspace(1), ptr %state+8 ; bump.end at +8 (clamped)
//     %new   = gep i8, %top, SIZE
//     %miss  = icmp ugt %new, %end
//     br %miss, slow, fast                          ; !prof slow=1 fast=1<<20
//   slow:  %r = call ptr addrspace(1) @eco_alloc_inline_slow(SIZE)  ; statepointed
//   fast:  store %new, %state                       ; publish the bump
//   cont:  %obj = phi [ %top, fast ], [ %r, slow ]
//
// The single compare preserves ALL GC-trigger semantics: NurserySpace's
// bump.end is pre-clamped to min(from-space extent end, proactive-GC
// threshold trip) (computeAllocEnd), so both space exhaustion and threshold
// trips miss into the statepointed slow call, which collects (HEAP_042: the
// from-space is one contiguous extent, so a miss never means "step to the
// next block").
//
// Address-space discipline: the bump slots are loaded/stored as
// `ptr addrspace(1)` directly (the HPointer word IS the raw address, plan
// D1), so this expansion introduces NO ptrtoint/inttoptr — out of
// REP_LLVM_001(b)'s provenance rules and fold-immune (REP_LLVM_002) by
// construction, exactly like expandInlineDerefs.
//
// RS4GC-liveness fact (HEAP_034(d)): no bump-derived as1 value is live
// across the slow call — `%end`/`%miss` die at the branch, `%new` dies at
// the fast-edge store, and `%top`'s only post-branch use is the merge phi's
// fast-edge incoming. The phi result is a legitimate fresh base pointer on
// both edges; the header + field stores the lowering emitted after the
// marker land in the merge block, so a GC can never observe a
// partially-initialized object (no safepoint between the phi and the
// stores).
//
// Runs with the other marker expansions at the top of runEcoBackend —
// before the `$cap` inline prepass, before partition splitting, and before
// every RS4GC flavour. Idempotent / cheap when there are no markers
// (ECO_INLINE_ALLOC=0 emits none).
//
// `decisions` (capacity-check hoisting, CGEN_074) selects the UNCHECKED form
// for markers whose capacity was already guaranteed by a dominating ensure:
// bump with no end-load, no compare, no slow edge and no phi. Null / empty
// (the default, ECO_ALLOC_HOIST unset) means every marker keeps its diamond.
//
// `allowTls` (plans/inline-bump-state-tls.md) selects how `%state` is
// obtained: a TLS load of `eco_tl_bump_state` (AOT) or the
// `eco_bump_state()` call (JIT, or ECO_INLINE_BUMP_STATE=0).
static void expandInlineAllocs(Module &m,
                               const CapHoistDecisions *decisions = nullptr,
                               bool allowTls = false) {
    Function *marker = m.getFunction("__eco_alloc_inline");
    if (!marker || marker->use_empty())
        return;

    LLVMContext &ctx = m.getContext();
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *i8Ty = Type::getInt8Ty(ctx);
    PointerType *as0 = PointerType::get(ctx, 0);
    PointerType *as1 = PointerType::get(ctx, 1);

    // eco_bump_state() -> ptr: address of the calling thread's {ptr as1 at
    // +0, end as1 at +8}. memory(none): the ADDRESS is thread-stable (set
    // once at initThread), so LLVM may CSE repeated calls per function and
    // LICM them out of allocation loops; the CONTENTS change across block
    // advance / minor GC but are re-loaded per allocation, never cached
    // across a diamond. speculatable: executing it early is harmless (the
    // runtime is initialized before any compiled code runs).
    FunctionCallee bumpStateCallee = m.getOrInsertFunction(
        "eco_bump_state", FunctionType::get(as0, {}, /*isVarArg=*/false));
    if (auto *bs = dyn_cast<Function>(bumpStateCallee.getCallee())) {
        bs->setDoesNotAccessMemory();
        bs->setDoesNotThrow();
        bs->setWillReturn();
        bs->setSpeculatable();
        bs->addFnAttr("gc-leaf-function");
    }

    // plans/inline-bump-state-tls.md: read the bump-state address straight out
    // of TLS instead of calling into the runtime for it. eco_bump_state's body
    // is already call-free, but it lives in EcoRuntimeStatic — invisible to
    // LLVM here (no LTO) — so every allocation paid a call/ret plus the
    // caller-saved clobber a call forces at each allocation site. The survivor
    // census measured 10,462,396,845 of them on one self-compile: the largest
    // single row in the whole census.
    //
    // `eco_tl_bump_state` (Allocator.cpp) caches exactly what eco_bump_state()
    // returns and is written only by Allocator::setThreadHeap, so it cannot
    // drift from tl_heap_. The address is thread-stable (nursery_ and bump_ are
    // both direct members), so caching the ADDRESS is sound; its CONTENTS still
    // get re-loaded per allocation below, exactly as before.
    //
    // NOT for the JIT: ORC cannot resolve an initial-exec TLS reference from
    // JIT'd code, so `allowTls` is false there and the call is kept.
    const bool useTlsBumpState = allowTls && bumpStateInlineEnabled();
    GlobalVariable *bumpStateTls =
        useTlsBumpState ? getOrCreateBumpStateTls(m) : nullptr;

    // eco_alloc_inline_slow(i64) -> ptr addrspace(1). Deliberately NOT
    // gc-leaf: this is the ONE statepoint of an inline-allocated construct
    // (it may run a minor GC); field values live across it are relocated by
    // RS4GC as ordinary SSA values (no hand-rooting anywhere).
    FunctionCallee slowCallee = m.getOrInsertFunction(
        "eco_alloc_inline_slow",
        FunctionType::get(as1, {i64Ty}, /*isVarArg=*/false));
    if (auto *sf = dyn_cast<Function>(slowCallee.getCallee()))
        sf->setDoesNotThrow();

    MDBuilder mdb(ctx);
    // The slow edge fires once per nursery block (thousands of allocations)
    // plus once per minor GC — weight it far below the fall-through.
    MDNode *unlikely = mdb.createBranchWeights(/*slow=*/1, /*fast=*/1u << 20);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    // Bookkeeping cross-check for CGEN_074 (plan §2.6): how many markers the
    // decisions claim, vs how many unchecked forms we actually emit.
    unsigned expectUnchecked = 0, gotUnchecked = 0;
    if (decisions)
        for (CallInst *ci : calls)
            if (decisions->isUnchecked(ci))
                ++expectUnchecked;

    for (CallInst *ci : calls) {
        auto *sizeC = dyn_cast<ConstantInt>(ci->getArgOperand(0));
        if (!sizeC || sizeC->getZExtValue() == 0 ||
            (sizeC->getZExtValue() & 7) != 0 || sizeC->getZExtValue() > 4096)
            report_fatal_error("expandInlineAllocs: __eco_alloc_inline size "
                               "must be a constant, 8-aligned, in (0, 4096]");

        IRBuilder<> b(ci);
        Value *state = emitBumpStateAddr(b, bumpStateTls, bumpStateCallee);
        Value *top = b.CreateAlignedLoad(as1, state, Align(8), "eco.bump.top");

        // Covered marker (CGEN_074): unchecked bump. The guarantee comes from
        // a dominating ensure in this function, or — for a covered callee —
        // from an ensure in its caller, which is why no local evidence of it
        // appears here. No end-load, no compare, no slow edge, no phi, hence
        // no statepoint: this is what makes the enclosing function stampable
        // by the CGEN_072 fixpoint.
        //
        // The `ptr` load stays per-bump: store-to-load forwarding collapses a
        // chain of bumps into register arithmetic where legal, and any
        // intervening real call conservatively blocks it. Never cache it by
        // hand across anything.
        if (decisions && decisions->isUnchecked(ci)) {
            Value *newTop = b.CreateGEP(i8Ty, top,
                                        {b.getInt64(sizeC->getSExtValue())},
                                        "eco.bump.new");
            b.CreateAlignedStore(newTop, state, Align(8));
            ci->replaceAllUsesWith(top);
            ci->eraseFromParent();
            ++gotUnchecked;
            continue;
        }

        Value *endp = b.CreateGEP(i8Ty, state, {b.getInt64(8)}, "eco.bump.endp");
        Value *end = b.CreateAlignedLoad(as1, endp, Align(8), "eco.bump.end");
        // Plain (non-inbounds) GEP: when the block is nearly full the bumped
        // address may exceed the block end before the compare rejects it.
        Value *newTop = b.CreateGEP(i8Ty, top,
                                    {b.getInt64(sizeC->getSExtValue())},
                                    "eco.bump.new");
        Value *miss = b.CreateICmpUGT(newTop, end, "eco.bump.miss");

        Instruction *thenTerm = nullptr;  // slow (cold)
        Instruction *elseTerm = nullptr;  // fast
        SplitBlockAndInsertIfThenElse(miss, ci, &thenTerm, &elseTerm, unlikely);

        IRBuilder<> tb(thenTerm);
        CallInst *slowObj = tb.CreateCall(slowCallee, {sizeC}, "eco.alloc.slow");

        IRBuilder<> eb(elseTerm);
        eb.CreateAlignedStore(newTop, state, Align(8));

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.alloc.obj");
        phi->addIncoming(top, elseTerm->getParent());
        phi->addIncoming(slowObj, thenTerm->getParent());

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandInlineAllocs: surviving __eco_alloc_inline use");
    marker->eraseFromParent();

    if (decisions && gotUnchecked != expectUnchecked)
        report_fatal_error("expandInlineAllocs: CGEN_074 unchecked-marker "
                           "bookkeeping mismatch");
}

//===----------------------------------------------------------------------===//
// GC shadow-root-stack expansion (plans/gc-root-registration-cost.md, Phase 1)
//
// `eco_gc_push_stack_range` is the hottest symbol of the whole self-compile —
// 14.53% self on ~1.99 B events, one per closure-dispatch entry, with
// `eco_gc_stack_range_point` (0.87%) and `eco_gc_restore_stack_range_point`
// (1.28%) bracketing it. All three live in libEcoRuntimeStatic, which is not
// LTO'd against generated code, so every args-array call site paid three
// out-of-line calls (plus the caller-saved clobber each forces) to do a few
// stores.
//
// The shadow stack is now three initial-exec TLS cursors (RootSet.hpp), so the
// whole protocol is inline memory traffic:
//
//   point()   -> %p = threadlocal.address @eco_tl_root_sp ; load ptr
//   push(b,n,m) -> load sp ; store b/+0, n/+8, m/+16 ; store sp+24
//   restore(t)  -> store t
//
// The restore point is the cursor itself (StackRootRangeRec is trivially
// destructible, so there is nothing to unwind), which is why restore collapses
// to a single store. The `size_t` ABI is unchanged — the token is now a pointer
// value rather than an index — so the out-of-line forms stay valid and the JIT,
// which cannot resolve an initial-exec TLS reference from ORC-compiled code,
// keeps calling them (`allowTls` false there, exactly as for the bump state).
//
// Why this is NOT redundant with RS4GC: an args array is a storage boundary,
// and REP_LLVM_001 permits `ptr addrspace(1)` -> `i64` there. The moment a GC
// pointer is ptrtoint'd into the array it stops being an SSA pointer and
// statepoint coverage ends; the shadow range is the patch for exactly that hole
// (EcoToLLVMClosures.cpp:1079-1086, the Stage 7 unsafeIndex crash). This pass
// changes only HOW the range is registered, never WHETHER it is.
//
// No addrspace(1) value is created, loaded or stored here: the base is an
// alloca in addrspace(0) and the other two fields are plain i64. The expansion
// is therefore invisible to RS4GC and outside REP_LLVM_001 entirely.
//
// Conservative by construction — a site is expanded only when `count` is a
// non-zero constant <= 64 (the runtime's own assert) and the base is provably
// non-null. Anything else keeps the call, which still does the right thing.
//===----------------------------------------------------------------------===//

static bool rootStackInlineEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_TLS_ROOT_STACK");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

static GlobalVariable *getOrCreateRootSpTls(Module &m) {
    if (auto *gv = m.getGlobalVariable("eco_tl_root_sp", /*AllowInternal=*/true))
        return gv;
    auto *gv = new GlobalVariable(
        m, PointerType::get(m.getContext(), 0), /*isConstant=*/false,
        GlobalValue::ExternalLinkage, /*Initializer=*/nullptr,
        "eco_tl_root_sp", /*InsertBefore=*/nullptr,
        GlobalValue::InitialExecTLSModel);
    gv->setAlignment(Align(8));
    return gv;
}

// True when `v` cannot be null, using only facts every emission site supplies
// (all seven pass an alloca, directly or through a constant GEP).
static bool isProvablyNonNullStackPtr(Value *v) {
    v = v->stripPointerCastsAndAliases();
    if (isa<AllocaInst>(v) || isa<GlobalValue>(v))
        return true;
    if (auto *gep = dyn_cast<GEPOperator>(v))
        return isProvablyNonNullStackPtr(gep->getPointerOperand());
    return false;
}

static void expandRootRangeOps(Module &m, bool allowTls) {
    if (!allowTls || !rootStackInlineEnabled())
        return;

    Function *pointF = m.getFunction("eco_gc_stack_range_point");
    Function *pushF = m.getFunction("eco_gc_push_stack_range");
    Function *restoreF = m.getFunction("eco_gc_restore_stack_range_point");
    if ((!pointF || pointF->use_empty()) && (!pushF || pushF->use_empty()) &&
        (!restoreF || restoreF->use_empty()))
        return;

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as0 = PointerType::get(ctx, 0);
    GlobalVariable *spTls = getOrCreateRootSpTls(m);

    auto collect = [](Function *f, SmallVectorImpl<CallInst *> &out) {
        if (!f)
            return;
        for (User *u : f->users())
            if (auto *ci = dyn_cast<CallInst>(u))
                if (ci->getCalledFunction() == f)
                    out.push_back(ci);
    };

    SmallVector<CallInst *, 64> points, pushes, restores;
    collect(pointF, points);
    collect(pushF, pushes);
    collect(restoreF, restores);

    // point(): one TLS load. The address is thread-stable, so LLVM is free to
    // CSE the threadlocal.address calls; the LOAD is a real load of mutable
    // state and is re-done wherever the value is needed.
    for (CallInst *ci : points) {
        IRBuilder<> b(ci);
        Value *slot = b.CreateThreadLocalAddress(spTls);
        Value *sp = b.CreateAlignedLoad(as0, slot, Align(8), "eco.root.sp");
        Value *tok = b.CreatePtrToInt(sp, i64Ty, "eco.root.point");
        ci->replaceAllUsesWith(tok);
        ci->eraseFromParent();
    }

    // restore(token): a single store. Unconditional, unlike the C++ form's
    // clamp: compiled code emits point/push/call/restore as one balanced unit
    // per call site, so the token can never be above the cursor.
    for (CallInst *ci : restores) {
        IRBuilder<> b(ci);
        Value *slot = b.CreateThreadLocalAddress(spTls);
        Value *v = b.CreateIntToPtr(ci->getArgOperand(0), as0, "eco.root.tok");
        b.CreateAlignedStore(v, slot, Align(8));
        ci->eraseFromParent();
    }

    // push(base, count, mask): three stores plus the cursor bump.
    for (CallInst *ci : pushes) {
        auto *countC = dyn_cast<ConstantInt>(ci->getArgOperand(1));
        Value *base = ci->getArgOperand(0);
        if (!countC || countC->getZExtValue() == 0 ||
            countC->getZExtValue() > 64 || !isProvablyNonNullStackPtr(base))
            continue;  // keep the call: it re-checks base/count itself

        IRBuilder<> b(ci);
        Value *slot = b.CreateThreadLocalAddress(spTls);
        Value *sp = b.CreateAlignedLoad(as0, slot, Align(8), "eco.root.sp");
        b.CreateAlignedStore(base, sp, Align(8));
        Value *cntSlot = b.CreateGEP(i8Ty, sp, {b.getInt64(8)});
        b.CreateAlignedStore(ci->getArgOperand(1), cntSlot, Align(8));
        Value *maskSlot = b.CreateGEP(i8Ty, sp, {b.getInt64(16)});
        b.CreateAlignedStore(ci->getArgOperand(2), maskSlot, Align(8));
        Value *next = b.CreateGEP(i8Ty, sp, {b.getInt64(24)}, "eco.root.next");
        b.CreateAlignedStore(next, slot, Align(8));
        ci->eraseFromParent();
    }
    (void)i64Ty;
}

//===----------------------------------------------------------------------===//
// `$sat` fast-path diamond (plans/gc-root-registration-cost.md, Phase 3)
//
// The MLIR lowering brackets each array-building apply with a marker pair:
//
//   %tok = call ptr @__eco_sat_begin(ptr as1 %clo, i64 N, i64 KC, i64 RC,
//                                    i64 satByteOff, ...newargs)
//     ... the generic sequence: alloca, memset, N ptrtoints, the three root
//         registrations, and the runtime call that splices combined_args ...
//   call void @__eco_sat_end(ptr %tok, <R> %slowResult)
//
// and this pass turns the pair into the diamond, because a papExtend can sit
// inside a single-block `scf` region (loopified tail recursion — `List.foldl`'s
// loop is one) and EcoToLLVM runs BEFORE SCFToControlFlow, so the lowering
// cannot create blocks there. Same reason `__eco_get_tag_inline` is a marker.
//
//   entry:  %W   = load i64, %clo+8                ; n:6|max:6|rk:2|unboxed:50
//           %n   = W & 63 ; %mx = (W>>6)&63 ; %rk = (W>>12)&3 ; %ub = W>>14
//           %c1  = (%mx - %n) == N
//           %c1b = %mx <= 25                       ; every slot described by %ub
//           %c2  = %rk == RC
//           %c3  = ((%ub >> 2*%n) & ((1<<2N)-1)) == KC
//           br %c1&%c1b&%c2&%c3, maybe, slow
//   maybe:  %d   = load ptr, %clo+16               ; the EvaluatorDesc
//           %sat = load ptr, %d+satByteOff         ; in bounds: %c1 proved N<=P
//           br %sat != null, fast, slow
//   fast:   %rf  = call <R> %sat(ptr as1 %clo, %a0..%aN-1)
//   slow:   ... the generic sequence ...
//   cont:   %r   = phi [%rf, fast], [%slowResult, slow]
//
// `%c3` is what makes passing the args UNBOXED sound (REP_ABI_001, plan §5.4):
// it proves the closure's declared slot kinds for the remaining slots equal the
// site's static assumption. `%c1b` is the guard §5.3 does not state but needs —
// `unboxed` describes only 25 slots, so a wider closure's kind bits must not be
// compared at all, or the mask test could pass on unrelated bits.
//
// Everything the fast edge skips is exactly what §5.5 lists. The pointer args
// stay `ptr addrspace(1)` into the call, so RS4GC covers them as ordinary SSA
// values with no shadow-stack registration at all — which is why this pass MUST
// run before every RS4GC flavour.
//===----------------------------------------------------------------------===//

static bool satFastBackendEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_SAT_FAST");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

static void expandSatMarkers(Module &m) {
    Function *beginF = m.getFunction("__eco_sat_begin");
    Function *endF = m.getFunction("__eco_sat_end");
    if (!beginF || beginF->use_empty())
        return;

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *i1Ty = Type::getInt1Ty(ctx);
    PointerType *as0 = PointerType::get(ctx, 0);
    PointerType *as1 = PointerType::get(ctx, 1);
    const bool enabled = satFastBackendEnabled();

    SmallVector<CallInst *, 64> begins;
    for (User *u : beginF->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            if (ci->getCalledFunction() == beginF)
                begins.push_back(ci);

    MDBuilder mdb(ctx);
    unsigned expanded = 0, dropped = 0;

    for (CallInst *B : begins) {
        // Find this bracket's end: the unique __eco_sat_end whose token operand
        // is B. It is emitted into the same block, after B.
        CallInst *E = nullptr;
        for (User *u : B->users()) {
            auto *ci = dyn_cast<CallInst>(u);
            if (!ci || ci->getCalledFunction() != endF)
                continue;
            if (ci->getParent() != B->getParent())
                continue;
            E = ci;
            break;
        }

        // No usable bracket, or the fast path is switched off: drop the markers
        // and leave the generic sequence exactly as emitted.
        if (!E || !enabled || E->arg_size() != 2) {
            if (E) E->eraseFromParent();
            B->eraseFromParent();
            ++dropped;
            continue;
        }

        Value *clo = B->getArgOperand(0);
        auto *nC = dyn_cast<ConstantInt>(B->getArgOperand(1));
        auto *kcC = dyn_cast<ConstantInt>(B->getArgOperand(2));
        auto *rcC = dyn_cast<ConstantInt>(B->getArgOperand(3));
        auto *offC = dyn_cast<ConstantInt>(B->getArgOperand(4));
        Value *slowVal = E->getArgOperand(1);
        if (!nC || !kcC || !rcC || !offC) {
            E->eraseFromParent();
            B->eraseFromParent();
            ++dropped;
            continue;
        }
        const uint64_t N = nC->getZExtValue();
        if (N == 0 || N > 8 || B->arg_size() != 5 + N) {
            E->eraseFromParent();
            B->eraseFromParent();
            ++dropped;
            continue;
        }

        SmallVector<Value *, 8> fastArgs;
        SmallVector<Type *, 8> fastParamTys;
        fastArgs.push_back(clo);
        fastParamTys.push_back(as1);
        for (uint64_t i = 0; i < N; ++i) {
            Value *a = B->getArgOperand(5 + i);
            fastArgs.push_back(a);
            fastParamTys.push_back(a->getType());
        }
        FunctionType *satTy =
            FunctionType::get(slowVal->getType(), fastParamTys, /*isVarArg=*/false);

        // Split so the generic sequence between the markers becomes `slow`.
        BasicBlock *entry = B->getParent();
        BasicBlock *slow = entry->splitBasicBlock(B, "eco.sat.slow");
        BasicBlock *cont = slow->splitBasicBlock(E, "eco.sat.cont");

        // entry: the guards, in place of the unconditional branch the split left.
        Instruction *entryTerm = entry->getTerminator();
        IRBuilder<> b(entryTerm);
        Value *packedSlot = b.CreateGEP(i8Ty, clo, {b.getInt64(8)}, "eco.clo.packed");
        Value *W = b.CreateAlignedLoad(i64Ty, packedSlot, Align(8), "eco.clo.w");
        Value *n = b.CreateAnd(W, b.getInt64(63), "eco.clo.n");
        Value *mx = b.CreateAnd(b.CreateLShr(W, b.getInt64(6)), b.getInt64(63),
                                "eco.clo.max");
        Value *rk = b.CreateAnd(b.CreateLShr(W, b.getInt64(12)), b.getInt64(3),
                                "eco.clo.rk");
        Value *ub = b.CreateLShr(W, b.getInt64(14), "eco.clo.ub");
        Value *rem = b.CreateSub(mx, n, "eco.clo.rem");
        Value *c1 = b.CreateICmpEQ(rem, b.getInt64(N));
        // `unboxed` describes 25 slots; a wider closure's kinds are not readable.
        Value *c1b = b.CreateICmpULE(mx, b.getInt64(25));
        Value *c2 = b.CreateICmpEQ(rk, b.getInt64(rcC->getZExtValue()));
        Value *shift = b.CreateShl(n, b.getInt64(1));
        // Sat sites carry at most 8 newargs, sat entries at most 16 params
        // (getOrCreateSatEntry), so the 2N-bit mask never shifts past 63.
        assert(N <= 16 && "sat marker: newarg count past the entry bound");
        Value *km = b.CreateAnd(b.CreateLShr(ub, shift),
                                b.getInt64((uint64_t{1} << (2 * N)) - 1));
        Value *c3 = b.CreateICmpEQ(km, b.getInt64(kcC->getZExtValue()));
        Value *ok = b.CreateAnd(b.CreateAnd(c1, c1b), b.CreateAnd(c2, c3));

        BasicBlock *maybe =
            BasicBlock::Create(ctx, "eco.sat.maybe", entry->getParent(), slow);
        BasicBlock *fast =
            BasicBlock::Create(ctx, "eco.sat.fast", entry->getParent(), slow);
        auto *br0 = BranchInst::Create(maybe, slow, ok, entryTerm->getIterator());
        (void)br0;
        entryTerm->eraseFromParent();

        // maybe: the descriptor load. `%c1` already proved N <= stage_arity, and
        // sat[] is sized stage_arity + 1, so this load is always in bounds.
        IRBuilder<> bm(maybe);
        Value *descSlot = bm.CreateGEP(i8Ty, clo, {bm.getInt64(16)}, "eco.clo.desc");
        Value *desc = bm.CreateAlignedLoad(as0, descSlot, Align(8), "eco.evaldesc");
        Value *satSlot = bm.CreateGEP(
            i8Ty, desc, {bm.getInt64(static_cast<int64_t>(offC->getZExtValue()))},
            "eco.sat.slot");
        Value *sat = bm.CreateAlignedLoad(as0, satSlot, Align(8), "eco.sat.fn");
        Value *has = bm.CreateICmpNE(sat, ConstantPointerNull::get(as0));
        bm.CreateCondBr(has, fast, slow);

        // fast: the arity-monomorphised entry, args in registers.
        IRBuilder<> bf(fast);
        CallInst *fastCall = bf.CreateCall(satTy, sat, fastArgs, "eco.sat.r");
        bf.CreateBr(cont);

        // cont: merge. `slow` still falls through to `cont` from the split.
        PHINode *phi = PHINode::Create(slowVal->getType(), 2, "eco.sat.merge",
                                       cont->begin());
        phi->addIncoming(fastCall, fast);
        phi->addIncoming(slowVal, slow);
        slowVal->replaceAllUsesWith(phi);
        phi->setIncomingValue(1, slowVal);

        E->eraseFromParent();
        B->eraseFromParent();
        ++expanded;
        (void)i1Ty;
        (void)mdb;
    }

    if (::getenv("ECO_PAP_HISTO")) {
        llvm::errs() << "[sat-expand] diamonds=" << expanded
                     << " dropped=" << dropped << "\n";
        unsigned satFns = 0, descs = 0;
        for (Function &f : m)
            if (!f.isDeclaration() && f.getName().starts_with("__closure_sat_"))
                ++satFns;
        for (GlobalVariable &g : m.globals())
            if (g.getName().starts_with("__eco_evaldesc_"))
                ++descs;
        llvm::errs() << "[sat-expand] satEntries=" << satFns
                     << " descriptors=" << descs << "\n";
    }

    // Markers are erased; drop the now-unused declarations so nothing downstream
    // (RS4GC, the verifier, the JIT symbol map) ever sees them.
    if (beginF->use_empty()) beginF->eraseFromParent();
    if (endF && endF->use_empty()) endF->eraseFromParent();
}



// P2.5 R1b (plans/allocator-resolve-inlining.md). Expand each
// `__eco_get_tag_inline` marker call into the open-coded eco_get_tag
// semantics (replicated EXACTLY from RuntimeExports.cpp):
//
//   embedded constant (ptr_ind set) -> Bool -> its i1 value; "empty" ->
//     CONSTANT_TAG (0xFFFD);
//   heap object -> Tag_Custom -> ctor (low 16 bits of the word at +8;
//     the upper bits are the unboxed bitmap — load i16, never i32);
//     Tag_Cons -> 1; anything else -> 0.
//
// The marker exists because eco.get_tag sits INSIDE single-block scf regions
// (loopified tail recursion — the hot Dict/Set case loops), where the MLIR
// lowering cannot create blocks; here at the LLVM level block structure is
// free. The heap arm resolves via a `__eco_resolve_fwd` marker call, so this
// MUST run BEFORE expandInlineDerefs (which then expands those) — and, like
// it, before the `$cap` prepass and every RS4GC flavour. The transient
// ptrtoint feeds only a same-block bit-test chain (REP_LLVM_001(c)/(d)); it
// has no foldable inttoptr partner because every slot decode is barriered or
// typed (REP_LLVM_002 §7.6). Idempotent / cheap when there are no markers.
// Chunked-list projections (plans/chunked-list-representation.md §6).
// Expand `__eco_list_head_inline` / `__eco_list_tail_inline` markers into a
// cell-fast / chunk-slow diamond:
//
//   base = __eco_resolve_fwd(v); tag = header(base) & mask;
//   tag == Tag_Cons ?  load the cell slot (head +8 / tail +16) through the
//                      __eco_slot_to_hptr barrier (REP_LLVM_002)
//                   :  call the chunk-aware runtime helper (head is gc-leaf;
//                      tail MAY ALLOCATE a successor view and is deliberately
//                      NOT gc-leaf, so RS4GC statepoints it like any
//                      allocating call — the HEAP_034 slow-edge pattern).
//
// Cells dominate spines (~99.8% measured on the flag-on self-compile), so
// the fast edge carries branch weights. Markers exist for the same reason as
// __eco_get_tag_inline: the projections sit inside single-block scf regions.
// MUST run before expandInlineDerefs (emits __eco_resolve_fwd) and before
// every RS4GC flavour. Only chunk-compiled modules contain these markers.
static void expandListProjMarker(Module &m, const char *markerName,
                                 uint64_t slotOffset, const char *slowName,
                                 bool slowIsGcLeaf) {
    Function *marker = m.getFunction(markerName);
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    FunctionCallee slotBarrier = m.getOrInsertFunction(
        eco::kSlotToHPtrSym, FunctionType::get(as1, {i64Ty}, /*isVarArg=*/false));
    if (auto *bf = dyn_cast<Function>(slotBarrier.getCallee()))
        bf->addFnAttr("gc-leaf-function");

    FunctionCallee slowCallee = m.getOrInsertFunction(
        slowName, FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (slowIsGcLeaf)
        if (auto *sf = dyn_cast<Function>(slowCallee.getCallee()))
            sf->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    MDNode *cellLikely = mdb.createBranchWeights(/*cell=*/1u << 20, /*chunk=*/1);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        CallInst *base = b.CreateCall(fwdMarker, {v}, "eco.listbase");
        Value *hdr = b.CreateAlignedLoad(i32Ty, base, Align(8), "eco.listhdr");
        Value *tag = b.CreateAnd(hdr, tagMask, "eco.listtag");
        Value *isCell = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons),
            "eco.iscell");

        Instruction *cellTerm = nullptr, *chunkTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCell, ci, &cellTerm, &chunkTerm,
                                      cellLikely);

        IRBuilder<> fb(cellTerm);
        Value *slotPtr = fb.CreateGEP(
            i8Ty, base, ConstantInt::get(i64Ty, (uint64_t)slotOffset),
            "eco.slotp");
        Value *slotWord =
            fb.CreateAlignedLoad(i64Ty, slotPtr, Align(8), "eco.slotw");
        CallInst *fastVal =
            fb.CreateCall(slotBarrier, {slotWord}, "eco.fastproj");
        BasicBlock *cellBB = cellTerm->getParent();

        IRBuilder<> sb(chunkTerm);
        CallInst *slowVal = sb.CreateCall(slowCallee, {v}, "eco.slowproj");
        BasicBlock *chunkBB = chunkTerm->getParent();

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.listproj");
        phi->addIncoming(fastVal, cellBB);
        phi->addIncoming(slowVal, chunkBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandListProjMarker: surviving marker use");
    marker->eraseFromParent();
}

// Expand the mixed-spine CURSOR markers (EcoListCursor pass):
//
//   __eco_list_cur_inline(node, idx)       element at position, !eco.value
//   __eco_list_cur_{i64,f64,i16}_inline    unboxed element variants
//   __eco_list_step_node_inline(node, idx) next node (cell tail / same chunk
//                                          while the run lasts / chunk next)
//   __eco_list_step_idx_inline(node, idx)  next index (0 on node change)
//
// Every edge is a pure load — stepping THROUGH a chunk allocates nothing
// (the whole point: it replaces the per-element eco_list_tail_hybrid view
// materialization). All markers are gc-leaf shaped and fully expanded here,
// before every RS4GC flavour. Positions are normalized: idx > 0 only inside
// a chunk with idx < run, so the cell edges may assume idx == 0.
static void expandListCursorMarker(Module &m, const char *markerName,
                                   int variant /*0=value,1=i64,2=f64,3=i16,
                                                 4=stepNode,5=stepIdx*/) {
    Function *marker = m.getFunction(markerName);
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i16Ty = Type::getInt16Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *f64Ty = Type::getDoubleTy(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");
    FunctionCallee slotBarrier = m.getOrInsertFunction(
        eco::kSlotToHPtrSym, FunctionType::get(as1, {i64Ty}, false));
    if (auto *bf = dyn_cast<Function>(slotBarrier.getCallee()))
        bf->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    MDNode *cellLikely = mdb.createBranchWeights(1u << 20, 1);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *node = ci->getArgOperand(0);
        Value *idx = ci->getArgOperand(1);
        IRBuilder<> b(ci);
        CallInst *base = b.CreateCall(fwdMarker, {node}, "eco.curbase");
        Value *hdr = b.CreateAlignedLoad(i32Ty, base, Align(8), "eco.curhdr");
        Value *tag = b.CreateAnd(hdr, tagMask, "eco.curtag");
        Value *isCell = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons),
            "eco.curiscell");

        Instruction *cellTerm = nullptr, *chunkTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCell, ci, &cellTerm, &chunkTerm,
                                      cellLikely);

        // Cell edge.
        IRBuilder<> fb(cellTerm);
        Value *cellVal = nullptr;
        if (variant <= 3) {
            Value *p = fb.CreateGEP(i8Ty, base,
                                    ConstantInt::get(i64Ty, 8), "eco.curhp");
            Value *w = fb.CreateAlignedLoad(i64Ty, p, Align(8), "eco.curhw");
            if (variant == 0)
                cellVal = fb.CreateCall(slotBarrier, {w});
            else if (variant == 1)
                cellVal = w;
            else if (variant == 2)
                cellVal = fb.CreateBitCast(w, f64Ty);
            else
                cellVal = fb.CreateTrunc(w, i16Ty);
        } else if (variant == 4) {
            Value *p = fb.CreateGEP(i8Ty, base,
                                    ConstantInt::get(i64Ty, 16), "eco.curtp");
            Value *w = fb.CreateAlignedLoad(i64Ty, p, Align(8), "eco.curtw");
            cellVal = fb.CreateCall(slotBarrier, {w});
        } else {
            cellVal = ConstantInt::get(i64Ty, 0);
        }
        BasicBlock *cellBB = cellTerm->getParent();

        // Chunk edge: shared field loads.
        IRBuilder<> sb(chunkTerm);
        Value *offP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 16));
        Value *off = sb.CreateZExt(
            sb.CreateAlignedLoad(i32Ty, offP, Align(8), "eco.curoff"), i64Ty);
        Value *chunkVal = nullptr;
        if (variant <= 3) {
            Value *bwP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8));
            Value *bw = sb.CreateAlignedLoad(i64Ty, bwP, Align(8));
            Value *bp = sb.CreateCall(slotBarrier, {bw});
            Value *braw = sb.CreateCall(fwdMarker, {bp});
            Value *pos = sb.CreateAdd(off, idx, "eco.curpos");
            Value *byteOff = sb.CreateAdd(
                ConstantInt::get(i64Ty, 16),
                sb.CreateShl(pos, ConstantInt::get(i64Ty, 3)));
            Value *ep = sb.CreateGEP(i8Ty, braw, byteOff, "eco.curep");
            Value *w = sb.CreateAlignedLoad(i64Ty, ep, Align(8), "eco.curew");
            if (variant == 0)
                chunkVal = sb.CreateCall(slotBarrier, {w});
            else if (variant == 1)
                chunkVal = w;
            else if (variant == 2)
                chunkVal = sb.CreateBitCast(w, f64Ty);
            else
                chunkVal = sb.CreateTrunc(w, i16Ty);
        } else {
            Value *lenP =
                sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 20));
            Value *len = sb.CreateZExt(
                sb.CreateAlignedLoad(i32Ty, lenP, Align(4), "eco.curlen"),
                i64Ty);
            Value *bwP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8));
            Value *bw = sb.CreateAlignedLoad(i64Ty, bwP, Align(8));
            Value *bp = sb.CreateCall(slotBarrier, {bw});
            Value *braw = sb.CreateCall(fwdMarker, {bp});
            Value *capP =
                sb.CreateGEP(i8Ty, braw, ConstantInt::get(i64Ty, 4));
            Value *cap = sb.CreateZExt(
                sb.CreateAlignedLoad(i32Ty, capP, Align(4), "eco.curcap"),
                i64Ty);
            Value *avail = sb.CreateSub(cap, off);
            Value *run = sb.CreateSelect(sb.CreateICmpULT(len, avail), len,
                                         avail, "eco.currun");
            Value *idx1 = sb.CreateAdd(idx, ConstantInt::get(i64Ty, 1));
            Value *inRun = sb.CreateICmpULT(idx1, run, "eco.curinrun");
            if (variant == 4) {
                Value *nxP =
                    sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 24));
                Value *nxW = sb.CreateAlignedLoad(i64Ty, nxP, Align(8));
                Value *nx = sb.CreateCall(slotBarrier, {nxW});
                chunkVal = sb.CreateSelect(inRun, node, nx, "eco.stepnode");
            } else {
                chunkVal = sb.CreateSelect(inRun, idx1,
                                           ConstantInt::get(i64Ty, 0),
                                           "eco.stepidx");
            }
        }
        BasicBlock *chunkBB = chunkTerm->getParent();

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        Type *resTy = variant == 0 || variant == 4
                          ? (Type *)as1
                          : variant == 1 || variant == 5
                                ? i64Ty
                                : variant == 2 ? f64Ty : (Type *)i16Ty;
        PHINode *phi = pb.CreatePHI(resTy, 2, "eco.cur");
        phi->addIncoming(cellVal, cellBB);
        phi->addIncoming(chunkVal, chunkBB);
        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandListCursorMarker: surviving marker use");
    marker->eraseFromParent();
}

static void expandListCursorMarkers(Module &m) {
    expandListCursorMarker(m, "__eco_list_cur_inline", 0);
    expandListCursorMarker(m, "__eco_list_cur_i64_inline", 1);
    expandListCursorMarker(m, "__eco_list_cur_f64_inline", 2);
    expandListCursorMarker(m, "__eco_list_cur_i16_inline", 3);
    expandListCursorMarker(m, "__eco_list_step_node_inline", 4);
    expandListCursorMarker(m, "__eco_list_step_idx_inline", 5);
}

// kernel-opt-04. Byte offset of Header::size inside the 8-byte object header.
// HEAP_025/HEAP_032: for EVERY String form this word IS the logical UTF-16
// length. Deliberately NOT the array length offset (8, layout::ArrayLengthOffset)
// -- arrays keep their length in a field AFTER the header, so a copy-paste from
// ArrayLengthOpLowering would read the first two UTF-16 chars of a Tag_String leaf.
static constexpr uint64_t kHeaderSizeFieldOffset = offsetof(Elm::Header, size);
static_assert(kHeaderSizeFieldOffset == 4,
              "Header::size moved; expandStringLenMarkers reads it directly");

// Expand each `__eco_string_len_inline` marker into the exact observable
// semantics of Elm_Kernel_String_length (StringExports.cpp:18-27):
//
//   ptr_ind set (ANY embedded constant) -> 0
//       Empty  : the kernel's alloc::isEmptyString guard returns 0 directly.
//       Others : Export::toPtr maps them to nullptr and StringOps::length's
//                `if (!str) return 0;` returns 0 (unreachable for a String).
//   otherwise -> resolve forwarding (HEAP_030) + load u32 at header offset 4
//                + zext to i64   (no per-tag dispatch, HEAP_025/HEAP_032)
//
// The ptr_ind test -- not a whole-word `== 0x6` -- is what makes this exact: the
// word test would dereference address 4/5 for a Bool constant where the kernel
// returns 0. Chain shape and same-BB discipline are copied verbatim from
// expandGetTagMarkers' isConst. Marker (not an MLIR diamond) because
// eco.string.length sits inside single-block scf regions -- same rationale as
// __eco_get_tag_inline. MUST run before expandInlineDerefs. Cheap with no markers.
static bool valueEqInlineEnabled() {  // ECO_VALUE_EQ_INLINE=0 -> bare call
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_INLINE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

static bool valueEqGcLeafEnabled() {  // ECO_VALUE_EQ_GCLEAF=1 -> stamp
    return valueEqGcLeafEnv(); // shared with the MLIR planners (plan 02 F10)
}

// Expand each `__eco_value_eq(a, b) -> i1` marker into the word-equality diamond
// (kernel-opt-03 Phase 2). MUST run before EVERY RewriteStatepointsForGC flavour
// and before propagateGcFreeLeafAttrs (CGEN_072), so the fixpoint sees arm 3 as a
// call to a gc-leaf declaration rather than an unknown marker.
//
//   head: %same = icmp eq ptr addrspace(1) %a, %b
//         br %same, cont, test
//   test: %aw = ptrtoint %a ; %bw = ptrtoint %b        (REP_LLVM_001(d): the i64s
//         %any = icmp ne (and (or %aw,%bw), 4), 0       are consumed by or/and/icmp
//         br %any, cont, slow                           in this SAME block)
//   slow: %r  = call @Elm_Kernel_Utils_equal(%a, %b)
//         %rb = icmp eq %r, inttoptr(0x5)
//         br cont
//   cont: %res = phi i1 [true, head], [false, test], [%rb, slow]
//
// NOTE (kernel-opt-03 Phase-0 census, 2026-08-11): the inline arms were measured
// at 6.47% of non-Bool traffic against a 25% bar, so when Phase-3 emission is
// eventually landed the shipped default should be ECO_VALUE_EQ_INLINE=0 (the bare
// call below). Nothing emits eco.value.eq today, so the default here is moot and
// is left ON so the codegen fixture exercises the diamond.
// `planVeq`: the planned value-eq predicate (eco-gcfree-plan / eco-cap-plan
// stamp). When it holds, the Utils_equal declaration is stamped even if this
// module had to create it (plan 02 O5), so a module (or, later, a partition)
// that lacks the MLIR declaration reaches the planner's answer.
static void expandValueEqFastPath(Module &m, bool planVeq) {
    LLVMContext &ctx = m.getContext();
    Type *i1Ty = Type::getInt1Ty(ctx), *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t constBit = 1ULL << PTR_IND_BIT;                   // 0x4
    const uint64_t trueWord = constBit | (uint64_t)Elm::Const_True;  // 0x5

    Function *marker = m.getFunction("__eco_value_eq");
    // Arm 3 needs the decl; create it only when there is a marker to expand.
    FunctionCallee eqCallee;
    if (marker)
        eqCallee = m.getOrInsertFunction(
            "Elm_Kernel_Utils_equal", FunctionType::get(as1, {as1, as1}, false));

    // Module-wide gc-leaf stamp. MUST sit ABOVE the marker early-return: a module
    // can call Elm_Kernel_Utils_equal with NO eco.value.eq in it, and those modules
    // need the stamp too. getFunction, NOT getOrInsertFunction: never conjure the
    // decl into a module that does not reference it.
    if (Function *eqFn = m.getFunction("Elm_Kernel_Utils_equal"))
        if (valueEqGcLeafEnabled() || planVeq)
            eqFn->addFnAttr("gc-leaf-function");  // NEVER memory(none)/speculatable

    if (!marker) return;  // pruned by EcoToLLVM.cpp when unused

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u)) calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *a = ci->getArgOperand(0), *b = ci->getArgOperand(1);
        IRBuilder<> b0(ci);
        if (!valueEqInlineEnabled()) {  // A/B shape: today's codegen
            Value *r = b0.CreateCall(eqCallee, {a, b}, "eq.r");
            Value *tc = b0.CreateIntToPtr(ConstantInt::get(i64Ty, trueWord), as1);
            ci->replaceAllUsesWith(b0.CreateICmpEQ(r, tc, "eq.res"));
            ci->eraseFromParent();
            continue;
        }
        BasicBlock *headBB = ci->getParent();
        Function *F = headBB->getParent();
        BasicBlock *contBB = headBB->splitBasicBlock(ci, "eq.done");
        BasicBlock *testBB = BasicBlock::Create(ctx, "eq.test", F, contBB);
        BasicBlock *slowBB = BasicBlock::Create(ctx, "eq.slow", F, contBB);

        headBB->getTerminator()->eraseFromParent();
        IRBuilder<> hb(headBB);
        hb.CreateCondBr(hb.CreateICmpEQ(a, b, "eq.same"), contBB, testBB);

        IRBuilder<> tb(testBB);
        Value *aw = tb.CreatePtrToInt(a, i64Ty, "eq.aw");
        Value *bw = tb.CreatePtrToInt(b, i64Ty, "eq.bw");
        Value *any = tb.CreateICmpNE(
            tb.CreateAnd(tb.CreateOr(aw, bw), ConstantInt::get(i64Ty, constBit)),
            ConstantInt::get(i64Ty, 0), "eq.anyconst");
        tb.CreateCondBr(any, contBB, slowBB);

        IRBuilder<> sb(slowBB);
        CallInst *r = sb.CreateCall(eqCallee, {a, b}, "eq.r");
        Value *tc = sb.CreateIntToPtr(ConstantInt::get(i64Ty, trueWord), as1);
        Value *rb = sb.CreateICmpEQ(r, tc, "eq.slowres");
        sb.CreateBr(contBB);

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(i1Ty, 3, "eq.res");
        phi->addIncoming(ConstantInt::getTrue(ctx), headBB);
        phi->addIncoming(ConstantInt::getFalse(ctx), testBB);
        phi->addIncoming(rb, slowBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }
    if (!marker->use_empty())
        report_fatal_error("expandValueEqFastPath: surviving __eco_value_eq use");
    marker->eraseFromParent();
}

static void expandStringLenMarkers(Module &m) {
    Function *marker = m.getFunction("__eco_string_len_inline");
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        // ALL direct users of the ptrtoint stay in THIS block -- EcoPtrIntVerify
        // accepts the bit-test chain same-BB only (REP_LLVM_001(d));
        // downstream blocks never see `bits`.
        Value *bits = b.CreatePtrToInt(v, i64Ty, "eco.strbits");
        Value *ptrInd = b.CreateAnd(b.CreateLShr(bits, PTR_IND_BIT), 1);
        Value *isConst =
            b.CreateICmpNE(ptrInd, ConstantInt::get(i64Ty, 0), "eco.strconst");

        Instruction *constTerm = nullptr, *heapTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isConst, ci, &constTerm, &heapTerm);
        BasicBlock *contBB = ci->getParent();  // ci now lives in the join block
        BasicBlock *constBB = constTerm->getParent();

        IRBuilder<> hb(heapTerm);
        CallInst *base = hb.CreateCall(fwdMarker, {v}, "eco.strbase");
        Value *szp =
            hb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, kHeaderSizeFieldOffset),
                         "eco.strszp");
        Value *sz32 = hb.CreateAlignedLoad(i32Ty, szp, Align(4), "eco.strsz");
        Value *sz64 = hb.CreateZExt(sz32, i64Ty, "eco.strlen");
        BasicBlock *heapBB = heapTerm->getParent();

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(i64Ty, 2, "eco.strlen.phi");
        phi->addIncoming(ConstantInt::get(i64Ty, 0), constBB);
        phi->addIncoming(sz64, heapBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandStringLenMarkers: surviving marker use");
    marker->eraseFromParent();
}

static void expandListProjMarkers(Module &m) {
    expandListProjMarker(m, "__eco_list_head_inline", /*slotOffset=*/8,
                         "eco_list_head_hybrid", /*slowIsGcLeaf=*/true);
    expandListProjMarker(m, "__eco_list_tail_inline", /*slotOffset=*/16,
                         "eco_list_tail_hybrid", /*slowIsGcLeaf=*/false);
}

static void expandGetTagMarkers(Module &m) {
    Function *marker = m.getFunction("__eco_get_tag_inline");
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i16Ty = Type::getInt16Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *i8Ty = Type::getInt8Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        Value *bits = b.CreatePtrToInt(v, i64Ty, "eco.tagbits");
        // ALL direct users of the ptrtoint stay in THIS block —
        // EcoPtrIntVerify's bit-test acceptance is same-BB only
        // (REP_LLVM_001(d)); downstream blocks consume only the derived
        // i64s (constField), never the ptrtoint result itself.
        Value *ptrInd = b.CreateAnd(b.CreateLShr(bits, 2), 1);
        Value *constField = b.CreateAnd(bits, 3, "eco.constfield");
        // Null-cons declaration index (HEAP_044): derived i64s in the SAME
        // block as the ptrtoint — the same acceptance class as constField;
        // the embedded branch consumes only the derived And result.
        Value *nullConsIdx = b.CreateAnd(
            b.CreateLShr(bits, NULL_CONS_SHIFT),
            ConstantInt::get(i64Ty, NULL_CONS_MAX), "eco.nullconsidx");
        Value *isConst =
            b.CreateICmpNE(ptrInd, ConstantInt::get(i64Ty, 0), "eco.isconst");

        Instruction *embTerm = nullptr, *heapTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isConst, ci, &embTerm, &heapTerm);
        BasicBlock *contBB = ci->getParent();

        // Embedded constant: null-cons -> embedded declaration index;
        // Bool -> i1 value; empty -> CONSTANT_TAG.
        IRBuilder<> tb(embTerm);
        Value *isTrue = tb.CreateICmpEQ(constField, ConstantInt::get(i64Ty, 1));
        Value *isFalse = tb.CreateICmpEQ(constField, ConstantInt::get(i64Ty, 0));
        Value *isBool = tb.CreateOr(isTrue, isFalse);
        Value *isNullCons = tb.CreateICmpEQ(
            constField, ConstantInt::get(i64Ty, (uint64_t)Elm::Const_NullCons),
            "eco.isnullcons");
        Value *embTag = tb.CreateSelect(
            isNullCons, tb.CreateTrunc(nullConsIdx, i32Ty),
            tb.CreateSelect(
                isBool, tb.CreateZExt(isTrue, i32Ty),
                ConstantInt::get(i32Ty, (uint64_t)CONSTANT_TAG)),
            "eco.embtag");
        BasicBlock *embBB = embTerm->getParent();

        // Heap: resolve (marker), load header, mask tag, discriminate.
        IRBuilder<> hb(heapTerm);
        CallInst *base = hb.CreateCall(fwdMarker, {v}, "eco.tagbase");
        Value *hdr = hb.CreateAlignedLoad(i32Ty, base, Align(8), "eco.taghdr");
        Value *tag = hb.CreateAnd(hdr, (1u << TAG_BITS) - 1, "eco.tag");
        Value *isCustom =
            hb.CreateICmpEQ(tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Custom));
        Instruction *custTerm = nullptr, *otherTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCustom, heapTerm, &custTerm, &otherTerm);
        BasicBlock *heapJoinBB = heapTerm->getParent();

        IRBuilder<> cb(custTerm);
        Value *ctorPtr =
            cb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8), "eco.ctorp");
        Value *ctor = cb.CreateZExt(
            cb.CreateAlignedLoad(i16Ty, ctorPtr, Align(8), "eco.ctor"), i32Ty);
        BasicBlock *custBB = custTerm->getParent();

        IRBuilder<> ob(otherTerm);
        Value *isCons =
            ob.CreateICmpEQ(tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons));
        // Chunked-list modules: a Tag_ConsChunk view is also the list Cons
        // constructor (ctor 1) for case dispatch. The extra compare is
        // emitted ONLY when the module enables chunk production (detected
        // via the injected eco_enable_list_chunks call), so non-chunk
        // binaries keep today's diamond byte-for-byte.
        {
            // Plan 05: under EcoSplit only `main`'s partition sees the
            // injected call, so the whole-module fact also travels as the
            // module flag `eco-list-chunks` (review R13).
            Function *chunksEnable = m.getFunction("eco_enable_list_chunks");
            if ((chunksEnable && !chunksEnable->use_empty()) ||
                m.getModuleFlag("eco-list-chunks")) {
                Value *isChunk = ob.CreateICmpEQ(
                    tag,
                    ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_ConsChunk));
                isCons = ob.CreateOr(isCons, isChunk, "eco.isconslike");
            }
        }
        Value *consOrZero = ob.CreateSelect(isCons, ConstantInt::get(i32Ty, 1),
                                            ConstantInt::get(i32Ty, 0));
        BasicBlock *otherBB = otherTerm->getParent();

        IRBuilder<> jb(&*heapJoinBB->getFirstInsertionPt());
        PHINode *heapTag = jb.CreatePHI(i32Ty, 2, "eco.heaptag");
        heapTag->addIncoming(ctor, custBB);
        heapTag->addIncoming(consOrZero, otherBB);

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *result = pb.CreatePHI(i32Ty, 2, "eco.gettag");
        result->addIncoming(embTag, embBB);
        result->addIncoming(heapTag, heapJoinBB);

        ci->replaceAllUsesWith(result);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandGetTagMarkers: surviving __eco_get_tag_inline use");
    marker->eraseFromParent();
}

// E1.3 (LSS dispatch-value plan §5): force-inline small `$cap` fast-evaluator
// bodies BEFORE any RS4GC. Once a call is statepointed no inliner will touch
// it (the per-partition -O2 runs post-RS4GC), which is exactly why the E1.1
// audit found 9,449 un-inlined direct `$cap` calls despite 55 % of bodies
// being ≤64 B — this pre-statepoint prepass is the ONLY point in the pipeline
// where `$cap` inlining can happen. The order (inline → statepoint) is the
// standard upstream one, so relocation semantics (REP_LLVM_001) are
// unaffected; the merged bodies are statepointed and then optimized normally.
//
// Bodies at or under the instruction threshold get `alwaysinline` (honoured by
// the whole-module AlwaysInlinerPass run here, pre-split — so would-be
// cross-partition pairs inline too); larger bodies get `inlinehint` for any
// later cost-model inliner. `$cap` symbols are address-taken (closure
// evaluator fields), so the bodies survive for indirect dispatch regardless.
// ECO_CAP_INLINE_MAX_INSTS overrides the threshold (0 = hint-only, no
// forcing) for A/B tuning without a rebuild.

// NO signature-coercing direct-call fold here — that was tried and it
// MISCOMPILES (2026-07-20, "Pointer below heap base" at self-compile minor
// GC #52): rebuilding a mismatched `$cap` site with ptrtoint/inttoptr
// coercions and then INLINING it splices the crossings into open code, so an
// i64 derived from `ptrtoint ptr addrspace(1)` becomes live across the
// inlined body's statepoints — a REP_LLVM_001(a) violation by construction.
// Mismatched-view sites (the erased/boxed i64<->ptr classes) therefore stay
// in their AddressOf+indirect form and are simply not inlined (the pre-E1.3
// status quo, sound). Matching-signature sites need no fold at all: MLIR
// translation resolves their called operand to the Function with a matching
// FTy, so `getCalledFunction()` works and the AlwaysInliner below can eat
// them directly. Recovering the mismatched population would require callee
// cloning at the callee's REAL boxedness (AbiCloning-family work), not
// site-side casts.

// The GC-call-free guard is CONDITIONAL as of E1.3 v3 (REP_LLVM_002,
// plans/fold-proof-boxed-slot-crossings.md): with slot-cast barriers ON
// (ECO_SLOT_CAST_BARRIERS default), every boxed-slot i64<->ptr<1> crossing
// is an opaque gc-leaf barrier call this pass's AlwaysInliner cannot fold,
// so BOTH annihilation classes below are structurally impossible and
// GC-bearing bodies inline soundly — the guard is lifted. It is FORCED back
// on when barriers are disabled (ECO_SLOT_CAST_BARRIERS=0 would otherwise
// reconstruct the miscompiles) and available for A/B via
// ECO_CAP_INLINE_GCFREE_ONLY=1. The two bisected, IR-verified miscompile
// classes that used to force it unconditionally (both now fold-proof):
//
// 1. Capture-load annihilation (Terminal_Main_lambda_15194$cap): unpack
//    sites loaded boxed slots as i64+inttoptr; the body's boundary ptrtoint
//    folded with it during inlining (ptrtoint(inttoptr(x)) -> x) — raw i64s
//    crossed the inlined body's statepoints invisible to RS4GC. FIXED at the
//    source: the three unpack sites (ProjectClosureOpLowering,
//    emitFastClosureCall, getOrCreateWrapper) now emit TYPED
//    ptr addrspace(1) loads (E1.3 v2 — keep; sound and prerequisite).
//
// 2. INTERIOR boundary annihilation (Terminal_Main_lambda_14615$cap): the
//    SAME fold fires on every other boxed-slot idiom pair INSIDE an inlined
//    body — e.g. a tuple-projection (load i64 + inttoptr) feeding an
//    args-slot store (ptrtoint + store) across a direct call: the tracked
//    hop folds away, the raw i64 state pointer crosses the statepoint, and
//    a stale pointer lands in the GC-registered args buffer ("Invalid tag
//    value" at evacuate). Standalone bodies never fold (nothing simplifies
//    pre-RS4GC); InlineFunction's SimplifyInstruction does. FIXED by v3:
//    every boxed-slot crossing is now emitted as an opaque gc-leaf barrier
//    (EcoToLLVMInternal.h slot* helpers, REP_LLVM_002) that the inliner
//    cannot fold; StripEcoCastBarriers restores the bare casts strictly
//    post-RS4GC (addEcoGCPipeline placement).
//
// With no statepoint inside the body there is nothing to be live across, so
// the GC-call-free class is sound regardless of folding — which is why it
// remains the forced fallback when barriers are disabled.
static bool bodyIsGCCallFree(const Function &f) {
    for (const BasicBlock &bb : f)
        for (const Instruction &i : bb)
            if (auto *cb = dyn_cast<CallBase>(&i)) {
                const Function *cf = cb->getCalledFunction();
                if (!cf)
                    return false; // indirect: assume it can GC
                if (cf->isIntrinsic())
                    continue;
                if (cf->hasFnAttribute("gc-leaf-function"))
                    continue;
                return false;
            }
    return true;
}

// RS4GC's leaf predicate as the pre-stamp ANALYSES must read it (plan 02,
// the E6 path). callsGCLeafFunction reads gc-leaf off the called OPERAND with
// no type check, so once EcoGcFreePropagation has stamped definitions, a
// type-mismatched (non-direct) call to a stamped GENERATED function reads as
// leaf. Capacity hoisting and the gc-free twin must see such a call exactly
// as before the stamps existed: not leaf. That is also the safe reading — a
// GC-free function may still consume nursery headroom (it can call a
// headroom breaker), so treating it as transparent inside a run would void
// the run's guarantee. RS4GC itself keeps the literal predicate (sound: the
// target cannot GC).
static bool leafForAnalysis(const CallBase *cb, const TargetLibraryInfo &TLI) {
    if (!cb->getCalledFunction())
        if (auto *f = dyn_cast<Function>(
                cb->getCalledOperand()->stripPointerCasts()))
            if (!f->isDeclaration() ||
                f->hasFnAttribute(caphoist::kAttrBudget) ||
                f->hasFnAttribute(caphoist::kAttrTop))
                return false;
    return llvm::callsGCLeafFunction(cb, TLI);
}

// GC-free function propagation (plans/gc-free-function-propagation.md):
// stamp gc-leaf-function on generated functions that provably cannot GC.
// Runs once per module at the pre-RS4GC choke point; every RS4GC flavour
// then skips statepointing direct calls to stamped functions.
//
// Poison = any call RS4GC would statepoint whose callee is not a defined
// function in this module; poison propagates callee->caller to a fixed
// point (an optimistic worklist: a cycle of poison-free functions stays
// GC-free, which is correct — mutual recursion without allocation cannot
// GC). The leaf predicate is llvm::callsGCLeafFunction, i.e. literally the
// one RS4GC consults per call site, so the analysis cannot disagree with
// the pass about what a leaf call is.
//
// At this point in the pipeline allocation is visible ONLY as calls: the
// inline-alloc diamond's slow edge (eco_alloc_inline_slow, deliberately
// not gc-leaf), eco_gc_alloc_region_slow, the boxed eco_alloc_* family,
// and kernel externs. There is no write barrier and no safepoint poll.
//
// Twin mode (`twinFree` non-null, plan 02 Q5): the validate oracle for the
// MLIR producer. Nothing is stamped or reported; a call to a defined,
// non-interposable callee is an edge BEFORE callsGCLeafFunction is consulted,
// so the MLIR stamps already on definitions cannot make the twin agree
// vacuously. The free set is returned in *twinFree.
static void propagateGcFreeLeafAttrs(
    Module &m, GcFreeMode mode,
    DenseSet<const Function *> *twinFree = nullptr) {
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);

    // Reverse call edges among defined functions, plus the poison seeds.
    DenseMap<const Function *, SmallPtrSet<Function *, 8>> callers;
    SmallVector<Function *, 128> worklist;
    DenseSet<const Function *> poisoned;

    unsigned numDefined = 0;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        ++numDefined;
        bool poison = f.isInterposable(); // analyzed body may not be linked
        for (BasicBlock &bb : f) {
            if (poison)
                break;
            for (Instruction &i : bb) {
                if (isa<LandingPadInst>(i)) { // EH: defensive, should not occur
                    poison = true;
                    break;
                }
                auto *cb = dyn_cast<CallBase>(&i);
                if (!cb)
                    continue;
                if (!isa<CallInst>(cb)) { // invoke/callbr: defensive
                    poison = true;
                    break;
                }
                if (twinFree) {
                    Function *dc = cb->getCalledFunction();
                    if (dc && !dc->isDeclaration() && !dc->isInterposable()) {
                        callers[dc].insert(&f);
                        continue;
                    }
                }
                if (leafForAnalysis(cb, TLI))
                    continue; // RS4GC's own per-call-site predicate
                Function *callee = cb->getCalledFunction();
                if (callee && !callee->isDeclaration() &&
                    !callee->isInterposable()) {
                    callers[callee].insert(&f); // resolved by the fixpoint
                    continue;
                }
                poison = true; // indirect call, or non-gc-leaf declaration
                break;
            }
        }
        if (poison) {
            poisoned.insert(&f);
            worklist.push_back(&f);
        }
    }

    while (!worklist.empty()) {
        Function *g = worklist.pop_back_val();
        auto it = callers.find(g);
        if (it == callers.end())
            continue;
        for (Function *caller : it->second)
            if (poisoned.insert(caller).second)
                worklist.push_back(caller);
    }

    if (twinFree) {
        for (Function &f : m)
            if (!f.isDeclaration() && !poisoned.count(&f))
                twinFree->insert(&f);
        return;
    }

    // Census. numSites = direct call sites that will lose their statepoint;
    // counted BEFORE stamping, while callsGCLeafFunction still says false
    // for calls to the about-to-be-stamped callees.
    unsigned numFree = 0, numSites = 0;
    SmallVector<Function *, 64> freeFns;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        if (!poisoned.count(&f)) {
            ++numFree;
            freeFns.push_back(&f);
        }
        for (BasicBlock &bb : f)
            for (Instruction &i : bb)
                if (auto *cb = dyn_cast<CallBase>(&i))
                    if (Function *callee = cb->getCalledFunction())
                        if (!callee->isDeclaration() &&
                            !poisoned.count(callee) &&
                            !llvm::callsGCLeafFunction(cb, TLI))
                            ++numSites;
    }

    if (const char *dump = ::getenv("ECO_GCFREE_LEAF_DUMP")) {
        std::ofstream out(partitionDumpPath(dump));
        for (Function *f : freeFns)
            out << f->getName().str() << "\n";
    }
    // Spike oracle (plans/mlir-split-backend-00-spikes.md): every function
    // still DEFINED at this point (the $cap prepass deletes inlined bodies).
    if (const char *dump = ::getenv("ECO_GCFREE_ALL_DUMP")) {
        std::ofstream out(partitionDumpPath(dump));
        for (Function &f : m)
            if (!f.isDeclaration())
                out << f.getName().str() << "\n";
    }

    if (mode == GcFreeMode::Stamp)
        for (Function *f : freeFns)
            f->addFnAttr("gc-leaf-function");

    // Quiet on ordinary default-ON builds; census mode always reports, and so
    // does any run that named the variable (i.e. every A/B arm).
    if (mode == GcFreeMode::Census || envNamed("ECO_GCFREE_LEAF"))
        llvm::errs() << "[gcfree] " << numFree << "/" << numDefined
                     << " functions GC-free, " << numSites
                     << " direct call sites de-statepointed (mode="
                     << (mode == GcFreeMode::Stamp ? "stamp" : "census")
                     << ")\n";

    // plans/list-map-mlir-template.md Goal 3 sizing. Counted HERE because
    // this is the only point where the fixpoint's verdict exists.
    //
    // SCOPE, stated exactly: this is the whole devirtualized fast-clone
    // population (`*$cap`), not template callees alone — `runEcoBackend`
    // receives only the LLVM module, so the MLIR-side list of which clones a
    // templated loop actually calls is not available here without a new
    // EcoBackendJob field. A `$cap` clone is stamped iff it is
    // allocation-free and call-clean, which is precisely the property that
    // makes a templated loop over it statepoint-free, so this bounds the
    // Goal-3 pool from above; the template-specific figure is the front end's
    // `mapTemplate{... allocFreeCallbacks=}`, and the two are reconciled in
    // the plan's Phase-3 record rather than conflated here.
    //
    // It UNDERCOUNTS in one known direction, and the direction matters:
    // a small callback (<= ECO_CAP_INLINE_MAX_INSTS) was already spliced into
    // its caller by the pre-RS4GC $cap inline prepass and has no surviving
    // clone to stamp. Such a loop is statepoint-free too — trivially, with no
    // stamp involved — so a low number here is not evidence against Goal 3.
    if (envNamed("ECO_CAP_GCLEAF_REPORT")) {
        unsigned capTotal = 0, capLeaf = 0;
        for (Function &f : m) {
            if (f.isDeclaration() || !f.getName().ends_with("$cap"))
                continue;
            ++capTotal;
            if (f.hasFnAttribute("gc-leaf-function"))
                ++capLeaf;
        }
        llvm::errs() << "[cap-gcleaf] calleeGcLeaf{stamped=" << capLeaf
                     << " capClones=" << capTotal
                     << "} (population = all $cap clones; see EcoBackend note)\n";
    }
}

// ---------------------------------------------------------------------
// Capacity-check hoisting (plans/capacity-check-hoisting.md, CGEN_074).
//
// Census step: compute the coverable set (functions whose ONLY GC hazard
// is their own bounded fixed-size inline allocation), their byte budgets,
// and the run structure M1/M2 would instrument. Mutates NOTHING — the
// transformation lands in a later step.
//
// Runs at the pre-expandInlineAllocs choke point, where __eco_alloc_inline
// markers still carry their constant sizes and every other GC hazard is
// already visible as a real call.
// ---------------------------------------------------------------------

// gc-leaf does NOT imply bump-state-transparent: these consume nursery
// headroom despite their attr, so they void a capacity guarantee (plan
// §2.1). eco_alloc_*_fast is declaration-only today; region_fast is live.
static bool isHeadroomBreaker(const Function *f) {
    return f && markers::isHeadroomBreaker(f->getName());
}

// Blocks that sit inside a CFG cycle: a marker there can execute an
// unbounded number of times, so its bytes are not a static budget.
static void computeBlockCycles(Function &f,
                               SmallPtrSetImpl<BasicBlock *> &inCycle) {
    for (scc_iterator<Function *> it = scc_begin(&f); !it.isAtEnd(); ++it)
        if (it.hasCycle()) // true for size>1 AND self-loops
            for (BasicBlock *bb : *it)
                inCycle.insert(bb);
}

namespace {
enum class TopReason { None, Loop, Cycle, Budget, Other };

struct CapHoistInfo {
    uint64_t ownBytes = 0;
    uint64_t budget = 0;
    bool top = false; // ⊤ (unbounded / unanalyzable)
    TopReason reason = TopReason::None;
    bool eligible = false;
    bool addrTaken = false;
    bool nonLocal = false;
    bool selfEdge = false;
    SmallVector<std::pair<Function *, bool>, 8> callees; // (G, callInLoop)
    SmallVector<CallInst *, 4> markers;                  // own, non-cycle
    unsigned numSites = 0; // direct call sites from non-covered callers
};

struct TarjanNode {
    unsigned index = 0;
    unsigned low = 0;
    bool onStack = false;
    bool visited = false;
};

// One straight-line run: a maximal ordered subsequence of ELEMENTS within a
// single basic block with no intervening breaker (plan §2.3). Recorded by the
// scan, emitted afterwards — SplitBlockAndInsertIfThen at a run head moves the
// run's tail into a new block, so an emit-while-scanning loop would re-visit
// the moved tail, re-form the run and never terminate. Instruction pointers
// stay valid across splits, which is what makes collect-first work (the same
// hazard expandInlineAllocs survives the same way).
struct CapHoistRun {
    Instruction *head = nullptr; // first element: the ensure goes before it
    Instruction *tail = nullptr; // last element: bounds the breaker re-check
    uint64_t bytes = 0;
    unsigned elems = 0;
    unsigned covCalls = 0;
    SmallVector<CallInst *, 4> ownMarkers;  // M2: expand these unchecked
    SmallVector<CallInst *, 4> covCallSites; // for the §2.6(a) assert
};
} // namespace

// ---- Plan-given mode (plans/mlir-split-backend-01-cap-hoist-plan.md P6) ----
// Facts the MLIR planner (EcoCapHoistPlan) stamped as passthrough string
// attributes: "eco-cap-budget"="N" | "eco-cap-top", plus "eco-cap-covered".
struct CapFact {
    bool has = false;
    bool top = false;
    bool covered = false;
    uint64_t budget = 0;
};

static Expected<CapFact> readCapFact(const Function &f) {
    CapFact cf;
    const AttributeList al = f.getAttributes();
    if (al.hasFnAttr(caphoist::kAttrBudget)) {
        StringRef v = al.getFnAttr(caphoist::kAttrBudget).getValueAsString();
        if (v.getAsInteger(10, cf.budget))
            return createStringError(std::errc::invalid_argument,
                                     "capacity hoisting: malformed %s on '%s'",
                                     caphoist::kAttrBudget,
                                     f.getName().str().c_str());
        cf.has = true;
    }
    if (al.hasFnAttr(caphoist::kAttrTop)) {
        cf.top = true;
        cf.has = true;
    }
    if (al.hasFnAttr(caphoist::kAttrCovered)) {
        cf.covered = true;
        cf.has = true;
    }
    if (cf.top && (cf.covered || al.hasFnAttr(caphoist::kAttrBudget)))
        return createStringError(std::errc::invalid_argument,
                                 "capacity hoisting: '%s' is both eco-cap-top "
                                 "and budgeted/covered",
                                 f.getName().str().c_str());
    if (cf.covered && cf.budget == 0)
        return createStringError(std::errc::invalid_argument,
                                 "capacity hoisting: covered '%s' has budget 0",
                                 f.getName().str().c_str());
    return cf;
}

static std::optional<std::string> moduleFlagString(const Module &m,
                                                   StringRef key) {
    if (auto *md = dyn_cast_or_null<MDString>(m.getModuleFlag(key)))
        return md->getString().str();
    return std::nullopt;
}

static std::optional<std::string> capPlanFlag(const Module &m) {
    return moduleFlagString(m, caphoist::kPlanFlag);
}

// Remove one string module flag (plan stamps are pass-local and must not
// reach the object).
static void stripModuleFlag(Module &m, StringRef key) {
    NamedMDNode *flags = m.getModuleFlagsMetadata();
    if (!flags || !m.getModuleFlag(key))
        return;
    SmallVector<MDNode *, 8> keep;
    for (MDNode *op : flags->operands()) {
        auto *k = op->getNumOperands() >= 2
                      ? dyn_cast<MDString>(op->getOperand(1))
                      : nullptr;
        if (!k || k->getString() != key)
            keep.push_back(op);
    }
    flags->clearOperands();
    for (MDNode *op : keep)
        flags->addOperand(op);
}

static void stripReachabilityStamp(Module &m) {
    stripModuleFlag(m, "eco-reach");
}

// Drop the plan's attributes and module flag once expandInlineAllocs has
// consumed the decisions (P6.8): they are pass-local, and leaving them would
// renumber `attributes #N` groups in -emit=llvm dumps.
static void stripCapPlan(Module &m) {
    for (Function &f : m) {
        f.removeFnAttr(caphoist::kAttrBudget);
        f.removeFnAttr(caphoist::kAttrTop);
        f.removeFnAttr(caphoist::kAttrCovered);
    }
    stripModuleFlag(m, caphoist::kPlanFlag);
}

// The marker table's expansion-callee column (EcoMarkerFacts.h,
// plan 02 Q3) checked against the module's DECLARATIONS: callsGCLeafFunction
// on a direct call reduces to the callee's own attribute (Eco emits no
// call-site gc-leaf), so this equals a per-call walk at O(#decls). `veq` is
// the planned value-eq predicate; without a plan its row is not checked.
static Error checkMarkerDecls(const Module &m, std::optional<bool> veq) {
    for (const Function &f : m) {
        if (!f.isDeclaration())
            continue;
        StringRef n = f.getName();
        if (!veq && n == "Elm_Kernel_Utils_equal")
            continue;
        const int expect = markers::expansionCalleeLeaf(n, veq.value_or(false));
        if (expect < 0)
            continue;
        if ((int)f.hasFnAttribute("gc-leaf-function") != expect)
            return createStringError(
                std::errc::invalid_argument,
                "marker table disagrees with the expansion: declaration '%s' "
                "is %sgc-leaf",
                n.str().c_str(), expect ? "not " : "");
    }
    return Error::success();
}

// Step 13 when EcoGcFreePropagation stamped the module (plan 02 Q5): the
// stamps are already on the definitions, so this only checks, reports and
// strips the plan flag.
static Error finishGcFreePlan(Module &m, bool partition) {
    auto gcPlan = gcfree::parseStamp(*moduleFlagString(m, gcfree::kPlanFlag));
    if (auto err = checkMarkerDecls(m, gcPlan->valueEqLeaf))
        return err;

    SmallVector<Function *, 64> stamped;
    unsigned numDefined = 0;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        ++numDefined;
        if (f.hasFnAttribute("gc-leaf-function"))
            stamped.push_back(&f);
    }

    // Per partition the twin reads every cross-partition declaration's
    // stamp as a leaf, so it would silently stop checking those edges
    // (plan 05 R11): the whole-module path (ECO_MLIR_SPLIT=0) runs it.
    if (gcFreeValidateEnabled() && !partition) {
        DenseSet<const Function *> twin;
        propagateGcFreeLeafAttrs(m, GcFreeMode::Census, &twin);
        DenseSet<const Function *> mlir(stamped.begin(), stamped.end());
        unsigned mlirOnly = 0, llvmOnly = 0;
        for (const Function *f : stamped)
            if (!twin.count(f) && ++mlirOnly <= 20)
                errs() << "[gcfree-validate] MLIR-only (UNSOUND) '"
                       << f->getName() << "'\n";
        for (const Function *f : twin)
            if (!mlir.count(f) && ++llvmOnly <= 20)
                errs() << "[gcfree-validate] LLVM-only '" << f->getName()
                       << "'\n";
        errs() << "[gcfree-validate] mlir=" << stamped.size()
               << " llvm=" << twin.size() << " mlir_only=" << mlirOnly
               << " llvm_only=" << llvmOnly << "\n";
        if (mlirOnly)
            return createStringError(
                std::errc::invalid_argument,
                "gc-free validate: %u MLIR-stamped functions can reach a GC",
                mlirOnly);
    }

    if (const char *dump = ::getenv("ECO_GCFREE_LEAF_DUMP")) {
        std::ofstream out(partitionDumpPath(dump));
        for (Function *f : stamped)
            out << f->getName().str() << "\n";
    }
    if (envNamed("ECO_GCFREE_LEAF"))
        errs() << "[gcfree] " << stamped.size() << "/" << numDefined
               << " functions GC-free (mode=stamp, source=mlir)\n";
    if (envNamed("ECO_CAP_GCLEAF_REPORT")) {
        unsigned capTotal = 0, capLeaf = 0;
        for (Function &f : m) {
            if (f.isDeclaration() || !f.getName().ends_with("$cap"))
                continue;
            ++capTotal;
            if (f.hasFnAttribute("gc-leaf-function"))
                ++capLeaf;
        }
        errs() << "[cap-gcleaf] calleeGcLeaf{stamped=" << capLeaf
               << " capClones=" << capTotal
               << "} (population = all $cap clones; see EcoBackend note)\n";
    }
    stripModuleFlag(m, gcfree::kPlanFlag);
    return Error::success();
}

static bool capHoistValidateEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CAPHOIST_VALIDATE");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

static Error applyCapacityHoisting(Module &m, CapHoistMode mode,
                                   CapHoistDecisions *decisions,
                                   bool allowTls, bool closedWorld,
                                   bool partition) {
    Function *markerFn = m.getFunction("__eco_alloc_inline");
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);
    const uint64_t K = capHoistMaxBytes();
    // Spike oracle (plans/mlir-split-backend-00-spikes.md, I2): per-phase
    // times and a full per-function dump, only when the variable is set.
    const char *spikeDump = ::getenv("ECO_CAPHOIST_FULL_DUMP");
    auto spikeT0 = std::chrono::steady_clock::now();
    auto spikeT = [&]() {
        auto now = std::chrono::steady_clock::now();
        double s = std::chrono::duration<double>(now - spikeT0).count();
        spikeT0 = now;
        return s;
    };
    double tA = 0, tBC = 0, tD = 0;
    unsigned spikeBrkBudget0 = 0;
    std::map<std::string, unsigned> spikeBrkByCallee;

    // ---- Mode selection (P6.1) ---------------------------------------
    DenseMap<const Function *, CapFact> facts;
    for (Function &f : m) {
        auto cf = readCapFact(f);
        if (!cf)
            return cf.takeError();
        if (cf->has)
            facts[&f] = *cf;
    }
    std::optional<caphoist::PlanStamp> plan;
    if (auto flag = capPlanFlag(m)) {
        plan = caphoist::parsePlanStamp(*flag);
        if (!plan)
            return createStringError(std::errc::invalid_argument,
                                     "capacity hoisting: malformed plan stamp "
                                     "'%s'", flag->c_str());
        if (plan->K != K || plan->m2 != capHoistFoldOwnMarkers() ||
            plan->closedWorld != closedWorld || mode != CapHoistMode::On)
            return createStringError(
                std::errc::invalid_argument,
                "capacity hoisting: plan stamp mismatch (stamp '%s'; backend "
                "K=%u m2=%d cw=%d mode=%s)",
                flag->c_str(), (unsigned)K, (int)capHoistFoldOwnMarkers(),
                (int)closedWorld, mode == CapHoistMode::On ? "on" : "census");
    } else if (!facts.empty()) {
        return createStringError(std::errc::invalid_argument,
                                 "capacity hoisting: eco-cap attributes "
                                 "without a plan stamp (e.g. on '%s')",
                                 facts.begin()->first->getName().str().c_str());
    }
    const bool planGiven = plan.has_value();
    // Plan 05 R13: compute mode needs the whole program; a partition must
    // carry the MLIR plan when hoisting transforms.
    if (partition && !planGiven && mode == CapHoistMode::On)
        return createStringError(
            std::errc::invalid_argument,
            "capacity hoisting: an EcoSplit partition without a plan stamp");
    // The compute-mode twin cannot run on a partition (its cross-partition
    // callees are declarations, plan 05 §1.7).
    const bool validate = planGiven && capHoistValidateEnabled() && !partition;
    auto hasFacts = [&](const Function *f) {
        return planGiven && f && facts.count(f);
    };

    if (!planGiven && mode == CapHoistMode::On) {
        // R2 mirror (02 O1): compute-mode Phase A is stamp-agnostic (it
        // tests a generated defined callee BEFORE gc-leaf, plan 02 Q6), but
        // the transform's Phase D still reads gc-leaf as transparent, which
        // is only sound while no generated definition carries gc-leaf. The
        // census (=c) never transforms, so stamped definitions are fine there.
        for (Function &f : m)
            if (!f.isDeclaration() && f.hasFnAttribute("gc-leaf-function") &&
                !markers::isTrustedLeafDecl(f.getName()))
                return createStringError(
                    std::errc::invalid_argument,
                    "capacity hoisting: compute mode on a module whose "
                    "definition '%s' is already gc-leaf",
                    f.getName().str().c_str());
    } else if (planGiven) {
        // R1 gap (02 F11): a declaration that is gc-leaf without eco-cap
        // facts must be a runtime/kernel name, or a generated callee whose
        // copied facts were lost would read as a transparent leaf.
        for (Function &f : m)
            if (f.isDeclaration() && !facts.count(&f) &&
                f.hasFnAttribute("gc-leaf-function") &&
                !markers::isTrustedLeafDecl(f.getName()))
                return createStringError(
                    std::errc::invalid_argument,
                    "capacity hoisting: untrusted gc-leaf declaration '%s' "
                    "without eco-cap facts",
                    f.getName().str().c_str());
        // P6.6: the marker table must agree with what the expansions emitted.
        if (auto err = checkMarkerDecls(m, plan->valueEqLeaf))
            return err;
    }

    // ---- Phase A: local scan -----------------------------------------
    // `r1` selects the plan-given classification order (R1): a callee that
    // carries eco-cap facts is a callee edge (its contribution comes from
    // the facts), tested BEFORE callsGCLeafFunction, so a covered callee
    // that is also gc-leaf can never be skipped as transparent.
    SmallVector<Function *, 256> defined;
    for (Function &f : m)
        if (!f.isDeclaration())
            defined.push_back(&f);
    auto runPhaseA = [&](DenseMap<Function *, CapHoistInfo> &info, bool r1) {
        for (Function *fp : defined)
            info.try_emplace(fp); // pre-populate: no rehash during the DFS
        for (Function *fp : defined) {
            Function &f = *fp;
            CapHoistInfo &fi = info.find(&f)->second;
            fi.addrTaken = f.hasAddressTaken();
            fi.nonLocal = !f.hasLocalLinkage();
            // Non-eligible functions may still be ROOTS; they just cannot
            // have their own checks hoisted into callers we cannot see.
            fi.eligible = !f.isInterposable() && !fi.addrTaken && !fi.nonLocal;
            if (f.isInterposable()) {
                fi.top = true;
                fi.reason = TopReason::Other;
            }

            SmallPtrSet<BasicBlock *, 16> inCycle;
            computeBlockCycles(f, inCycle);

            for (BasicBlock &bb : f) {
                const bool blockInCycle = inCycle.count(&bb) != 0;
                for (Instruction &i : bb) {
                    if (isa<LandingPadInst>(i)) { // EH: defensive
                        fi.top = true;
                        fi.reason = TopReason::Other;
                        continue;
                    }
                    auto *cb = dyn_cast<CallBase>(&i);
                    if (!cb)
                        continue;
                    if (!isa<CallInst>(cb)) { // invoke/callbr: defensive
                        fi.top = true;
                        fi.reason = TopReason::Other;
                        continue;
                    }
                    Function *callee = cb->getCalledFunction();

                    // The marker test MUST precede callsGCLeafFunction:
                    // __eco_alloc_inline is itself declared gc-leaf, and its
                    // expansion is what carries the statepoint.
                    if (markerFn && callee == markerFn) {
                        auto *szC = dyn_cast<ConstantInt>(cb->getArgOperand(0));
                        uint64_t sz = szC ? szC->getZExtValue() : 0;
                        if (!szC || sz == 0 || (sz & 7) != 0 || sz > 4096)
                            report_fatal_error(
                                "applyCapacityHoisting: __eco_alloc_inline "
                                "size must be a constant, 8-aligned, in "
                                "(0, 4096]");
                        if (blockInCycle) {
                            fi.top = true;
                            if (fi.reason == TopReason::None)
                                fi.reason = TopReason::Loop;
                        } else {
                            fi.ownBytes += sz;
                            fi.markers.push_back(cast<CallInst>(cb));
                        }
                        continue;
                    }
                    if (isHeadroomBreaker(callee)) {
                        fi.top = true;
                        if (fi.reason == TopReason::None)
                            fi.reason = TopReason::Other;
                        continue;
                    }
                    if (r1 && callee && facts.count(callee)) {
                        fi.callees.push_back({callee, blockInCycle});
                        if (callee == &f)
                            fi.selfEdge = true;
                        continue;
                    }
                    // Compute mode is stamp-agnostic (plan 02 Q6): a
                    // generated defined callee is an edge BEFORE its gc-leaf
                    // stamp is consulted. Unstamped, this is today's order
                    // exactly (a defined callee is leaf only when stamped).
                    if (!r1 && callee && !callee->isDeclaration() &&
                        !callee->isInterposable() &&
                        !markers::isTrustedLeafDecl(callee->getName())) {
                        fi.callees.push_back({callee, blockInCycle});
                        if (callee == &f)
                            fi.selfEdge = true;
                        continue;
                    }
                    if (leafForAnalysis(cb, TLI))
                        continue; // transparent
                    if (callee && !callee->isDeclaration() &&
                        !callee->isInterposable()) {
                        fi.callees.push_back({callee, blockInCycle});
                        if (callee == &f)
                            fi.selfEdge = true;
                        continue;
                    }
                    fi.top = true; // indirect, or non-leaf declaration
                    if (fi.reason == TopReason::None)
                        fi.reason = TopReason::Other;
                }
            }
        }
    };

    // ---- Phase B + C (compute mode / validate twin): the shared core ------
    auto solveInfo = [&](DenseMap<Function *, CapHoistInfo> &info) {
        DenseMap<const Function *, uint32_t> idx;
        for (uint32_t k = 0; k < defined.size(); ++k)
            idx[defined[k]] = k;
        std::vector<caphoist::Node> nodes(defined.size());
        for (uint32_t k = 0; k < defined.size(); ++k) {
            const CapHoistInfo &fi = info.find(defined[k])->second;
            caphoist::Node &nd = nodes[k];
            nd.ownBytes = fi.ownBytes;
            nd.top = fi.top;
            nd.reason = (caphoist::Reason)fi.reason;
            nd.eligible = fi.eligible;
            nd.selfEdge = fi.selfEdge;
            for (const auto &e : fi.callees)
                nd.callees.push_back({idx.find(e.first)->second, e.second});
        }
        caphoist::solve(nodes, K);
        for (uint32_t k = 0; k < defined.size(); ++k) {
            CapHoistInfo &fi = info.find(defined[k])->second;
            fi.top = nodes[k].top;
            fi.reason = (TopReason)nodes[k].reason;
            fi.budget = nodes[k].budget;
        }
    };

    DenseMap<Function *, CapHoistInfo> info;
    DenseSet<Function *> covered;
    SmallVector<Function *, 64> coverableFns;
    unsigned exclAddr = 0, exclLinkage = 0, exclLoop = 0, exclCycle = 0,
             exclBudget = 0, exclOther = 0;

    if (validate) {
        // P7: today's compute-mode A-C on the same module, ignoring the plan;
        // every definition must agree with its stamped facts.
        DenseMap<Function *, CapHoistInfo> vinfo;
        runPhaseA(vinfo, /*r1=*/false);
        solveInfo(vinfo);
        unsigned diffs = 0, compared = 0, unplanned = 0;
        for (Function *fp : defined) {
            const CapHoistInfo &vi = vinfo.find(fp)->second;
            const bool vcov = !vi.top && vi.budget > 0 && vi.eligible;
            auto it = facts.find(fp);
            if (it == facts.end()) {
                // Synthesized after planning (e.g. the JIT's _mlir_* packed
                // wrappers): installed as ⊤ below, never covered, so there is
                // nothing to compare.
                ++unplanned;
                continue;
            }
            const CapFact &pf = it->second;
            ++compared;
            if (pf.has && pf.top == vi.top && pf.covered == vcov &&
                (vi.top || pf.budget == vi.budget))
                continue;
            if (++diffs <= 20)
                errs() << "[caphoist-validate] diff '" << fp->getName()
                       << "': plan " << (pf.top ? "top" : "budget=" + std::to_string(pf.budget))
                       << (pf.covered ? " covered" : "") << " vs compute "
                       << (vi.top ? "top" : "budget=" + std::to_string(vi.budget))
                       << (vcov ? " covered" : "") << "\n";
        }
        errs() << "[caphoist-validate] compared=" << compared
               << " diffs=" << diffs << " unplanned=" << unplanned << "\n";
        if (diffs)
            return createStringError(std::errc::invalid_argument,
                                     "capacity hoisting validate: %u "
                                     "plan/compute differences", diffs);
    }

    if (!planGiven) {
        runPhaseA(info, /*r1=*/false);
        if (spikeDump)
            tA = spikeT();
        solveInfo(info);
    } else {
        // ---- §4.3 local verification (P6.4) --------------------------
        runPhaseA(info, /*r1=*/true);
        if (spikeDump)
            tA = spikeT();
        constexpr uint64_t TOP = ~uint64_t(0);
        auto contrib = [&](const Function *g) -> uint64_t {
            auto it = facts.find(g);
            if (it == facts.end())
                return TOP;
            const CapFact &gf = it->second;
            if (gf.covered)
                return gf.budget;
            if (!gf.top && gf.budget == 0)
                return 0;
            return TOP;
        };
        for (Function *fp : defined) {
            auto it = facts.find(fp);
            if (it == facts.end())
                continue; // unplanned definition: treated as ⊤ below
            const CapFact &pf = it->second;
            if (pf.top)
                continue;
            const CapHoistInfo &li = info.find(fp)->second;
            auto fail = [&](const char *rule) {
                return createStringError(
                    std::errc::invalid_argument,
                    "capacity hoisting: plan verification failed for %s "
                    "function '%s': %s",
                    pf.covered ? "covered" : "budget-0",
                    fp->getName().str().c_str(), rule);
            };
            if (!pf.covered && pf.budget > 0)
                continue; // finite but uncovered: keeps its own diamonds
            if (li.top)
                return fail("non-transparent call, breaker or in-loop marker");
            uint64_t sum = li.ownBytes;
            for (const auto &e : li.callees) {
                const uint64_t c = contrib(e.first);
                if (c == TOP)
                    return fail("calls a callee whose contribution is "
                                "unbounded");
                if (e.second && c > 0)
                    return fail("calls a budgeted callee in a loop");
                sum += c;
            }
            if (pf.covered) {
                if (sum > pf.budget || (validate && sum != pf.budget))
                    return fail("own bytes plus callee budgets exceed (or, "
                                "under validate, differ from) its budget");
                // An EcoSplit import copy (available_externally) is a copy
                // of an owner that its own partition verifies (plan 05 §1.4).
                if (!fp->hasLocalLinkage() &&
                    !fp->hasAvailableExternallyLinkage())
                    return fail("covered function without local linkage");
            } else if (sum != 0) {
                return fail("allocates or calls an allocating callee");
            }
        }
        // ---- install the plan --------------------------------------
        for (Function *fp : defined) {
            CapHoistInfo &fi = info.find(fp)->second;
            auto it = facts.find(fp);
            if (it == facts.end()) {
                fi.top = true; // conservative: never covered, never budget-0
                if (fi.reason == TopReason::None)
                    fi.reason = TopReason::Other;
                continue;
            }
            fi.top = it->second.top;
            fi.budget = it->second.top ? 0 : it->second.budget;
            fi.eligible = it->second.covered;
        }
    }
    if (spikeDump)
        tBC = spikeT();

    // ---- Phase C: coverable set --------------------------------------
    for (Function *fp : defined) {
        const CapHoistInfo &fi = info.find(fp)->second;
        if (fi.top) {
            switch (fi.reason) {
            case TopReason::Loop:   ++exclLoop;   break;
            case TopReason::Cycle:  ++exclCycle;  break;
            case TopReason::Budget: ++exclBudget; break;
            default:                ++exclOther;  break;
            }
            continue;
        }
        if (fi.budget == 0)
            continue; // already GC-free: CGEN_072's existing population
        const bool isCov = planGiven ? facts.find(fp)->second.covered
                                     : fi.eligible;
        if (!isCov) {
            // Finite nonzero budget but uninstrumentable callers — the
            // population a v2 callee-cloning extension would recover.
            if (fi.addrTaken)
                ++exclAddr;
            else if (fi.nonLocal)
                ++exclLinkage;
            continue;
        }
        covered.insert(fp);
        coverableFns.push_back(fp);
    }
    // Callee views used by Phase D / D2 / §2.6: in plan-given mode they come
    // from the facts, so they work for DECLARATIONS too (a covered callee in
    // another partition after the split).
    auto calleeCovered = [&](Function *c) {
        if (!c)
            return false;
        if (planGiven) {
            auto it = facts.find(c);
            return it != facts.end() && it->second.covered;
        }
        return covered.count(c) != 0;
    };
    auto calleeBudget = [&](Function *c) -> uint64_t {
        if (planGiven)
            return facts.find(c)->second.budget;
        return info.find(c)->second.budget;
    };
    if (spikeDump) {
        std::ofstream out(partitionDumpPath(spikeDump));
        auto reasonStr = [](TopReason r) {
            switch (r) {
            case TopReason::None:   return "none";
            case TopReason::Loop:   return "loop";
            case TopReason::Cycle:  return "cycle";
            case TopReason::Budget: return "budget";
            default:                return "other";
            }
        };
        for (Function *fp : defined) {
            const CapHoistInfo &fi = info.find(fp)->second;
            out << fp->getName().str() << ";" << (fi.top ? 1 : 0) << ";"
                << reasonStr(fi.reason) << ";" << fi.budget << ";"
                << fi.ownBytes << ";" << (fi.eligible ? 1 : 0) << ";"
                << (fi.addrTaken ? 1 : 0) << ";" << (fi.nonLocal ? 0 : 1)
                << ";" << (covered.count(fp) ? 1 : 0) << "\n";
        }
    }

    // ---- Phase D: run scan (phase 1 — scan and record, never emit) ----
    // Covered functions are NEVER scanned: their guarantee is their
    // caller's, so coveredFns and run-instrumented functions are disjoint.
    const bool foldOwn = capHoistFoldOwnMarkers();
    unsigned sites = 0, runsTotal = 0, runsSingleton = 0, runsMulti = 0,
             foldedMarkers = 0;
    SmallVector<CapHoistRun, 64> runs;
    for (Function *fp : defined) {
        if (covered.count(fp))
            continue;
        for (BasicBlock &bb : *fp) {
            CapHoistRun run;
            auto flushRun = [&]() {
                if (run.elems > 0) {
                    // Soundness vs profitability: a run with a covered call
                    // MUST be emitted (the callee's unchecked bumps depend on
                    // it — an obligation, never a heuristic); pure own-marker
                    // runs need >= 2 units to be worth a check.
                    if (run.covCalls >= 1 || run.elems >= 2) {
                        ++runsTotal;
                        if (run.elems == 1)
                            ++runsSingleton;
                        else
                            ++runsMulti;
                        foldedMarkers += run.ownMarkers.size();
                        runs.push_back(run);
                    }
                }
                run = CapHoistRun();
            };
            auto addElem = [&](Instruction *i, uint64_t b) {
                if (run.bytes + b > K)
                    flushRun(); // greedy K-split at an element boundary
                if (run.elems == 0)
                    run.head = i;
                run.tail = i;
                run.bytes += b;
                ++run.elems;
            };
            for (Instruction &i : bb) {
                auto *cb = dyn_cast<CallBase>(&i);
                if (!cb)
                    continue;
                Function *callee = cb->getCalledFunction();
                if (markerFn && callee == markerFn) {
                    auto *szC = dyn_cast<ConstantInt>(cb->getArgOperand(0));
                    const uint64_t c = szC ? szC->getZExtValue() : 0;
                    // An own marker over K (or with M2 off) keeps its HEAP_034
                    // diamond, whose slow edge can GC — a breaker.
                    if (!foldOwn || !szC || c > K) {
                        flushRun();
                        continue;
                    }
                    addElem(&i, c);
                    run.ownMarkers.push_back(cast<CallInst>(cb));
                    continue;
                }
                if (isHeadroomBreaker(callee)) {
                    flushRun();
                    continue;
                }
                if (callee && calleeCovered(callee)) {
                    addElem(&i, calleeBudget(callee));
                    ++run.covCalls;
                    run.covCallSites.push_back(cast<CallInst>(cb));
                    ++sites;
                    if (auto it = info.find(callee); it != info.end())
                        ++it->second.numSites;
                    continue;
                }
                // R1/R3: a generated callee (eco-cap facts) that is not
                // covered is a breaker even if it is gc-leaf, exactly as an
                // unstamped budget-0 callee is today.
                if (hasFacts(callee)) {
                    flushRun();
                    continue;
                }
                if (leafForAnalysis(cb, TLI))
                    continue; // transparent
                if (spikeDump && callee && !callee->isDeclaration()) {
                    auto it = info.find(callee);
                    if (it != info.end() && !it->second.top &&
                        it->second.budget == 0) {
                        ++spikeBrkBudget0;
                        ++spikeBrkByCallee[callee->getName().str()];
                    }
                }
                flushRun();   // statepoint-capable: breaker
            }
            flushRun();
        }
    }
    if (spikeDump) {
        tD = spikeT();
        std::ofstream out(partitionDumpPath(std::string(spikeDump) + ".breakers"));
        for (auto &kv : spikeBrkByCallee)
            out << kv.first << ";" << kv.second << "\n";
    }

    // ---- Phase D2: verification + emission (transform mode only) ------
    //
    // Everything here is analysis-bug containment first, codegen second. A
    // wrong budget is heap corruption (bumps past the clamped `end`), and the
    // CGEN_072 structural assert cannot see most of this class: a mis-covered
    // function is never STAMPED, so that assert never looks at it.
    unsigned emittedEnsures = 0;
    if (mode == CapHoistMode::On) {
        // Re-walk each recorded run over its ORIGINAL, still-unsplit block
        // and re-derive the scanner's own conclusion instruction by
        // instruction. This is the check that would catch a scanner that let
        // a statepoint-capable call, or a gc-leaf-but-headroom-consuming one
        // (plan §2.1: gc-leaf does NOT imply bump-state-transparent), sit
        // inside a covered region.
        for (const CapHoistRun &run : runs) {
            DenseSet<const CallInst *> owns(run.ownMarkers.begin(),
                                            run.ownMarkers.end());
            DenseSet<const CallInst *> covs(run.covCallSites.begin(),
                                            run.covCallSites.end());
            bool sawTail = false;
            for (Instruction *i = run.head; i; i = i->getNextNode()) {
                if (auto *cb = dyn_cast<CallBase>(i)) {
                    Function *callee = cb->getCalledFunction();
                    auto *ci = dyn_cast<CallInst>(cb);
                    const bool ok =
                        (markerFn && callee == markerFn && ci && owns.count(ci)) ||
                        (callee && calleeCovered(callee) && ci && covs.count(ci)) ||
                        (!isHeadroomBreaker(callee) && !hasFacts(callee) &&
                         leafForAnalysis(cb, TLI));
                    if (!ok)
                        report_fatal_error(
                            "applyCapacityHoisting: run in '" +
                            Twine(run.head->getFunction()->getName()) +
                            "' contains a call that voids its guarantee");
                }
                if (i == run.tail) {
                    sawTail = true;
                    break;
                }
            }
            // head and tail always share a block, so falling off the end
            // means the scanner recorded an inconsistent run.
            if (!sawTail)
                report_fatal_error("applyCapacityHoisting: run head/tail are "
                                   "not in the same block");
        }

        LLVMContext &ctx = m.getContext();
        Type *i64Ty = Type::getInt64Ty(ctx);
        Type *i8Ty = Type::getInt8Ty(ctx);
        PointerType *as0 = PointerType::get(ctx, 0);
        PointerType *as1 = PointerType::get(ctx, 1);

        // Same declaration + attributes expandInlineAllocs installs; whichever
        // pass runs first wins and the other's getOrInsertFunction finds it.
        // Kept even under the TLS path: it is the JIT / ECO_INLINE_BUMP_STATE=0
        // fallback that emitBumpStateAddr falls back to.
        FunctionCallee bumpStateCallee = m.getOrInsertFunction(
            "eco_bump_state", FunctionType::get(as0, {}, /*isVarArg=*/false));
        if (auto *bs = dyn_cast<Function>(bumpStateCallee.getCallee())) {
            bs->setDoesNotAccessMemory();
            bs->setDoesNotThrow();
            bs->setWillReturn();
            bs->setSpeculatable();
            bs->addFnAttr("gc-leaf-function");
        }
        // plans/inline-bump-state-tls.md: the hoisted ensure reads the bump
        // state too, so it takes the same TLS path as the alloc diamond.
        GlobalVariable *bumpStateTls =
            (allowTls && bumpStateInlineEnabled()) ? getOrCreateBumpStateTls(m)
                                                   : nullptr;

        // eco_ensure_nursery_slow(i64) -> void (HEAP_041). Deliberately NOT
        // gc-leaf: it is the ONE statepoint of a covered region, and it must
        // stay an opaque memory clobber so no bump-state load is forwarded
        // across it (on the cold edge ptr/end have both moved).
        FunctionCallee ensureCallee = m.getOrInsertFunction(
            "eco_ensure_nursery_slow",
            FunctionType::get(Type::getVoidTy(ctx), {i64Ty},
                              /*isVarArg=*/false));
        if (auto *ef = dyn_cast<Function>(ensureCallee.getCallee()))
            ef->setDoesNotThrow();

        MDBuilder mdb(ctx);
        // One miss per nursery block transition claimed by this run, plus one
        // per minor GC — the same numerology as the HEAP_034 diamond.
        MDNode *unlikely =
            mdb.createBranchWeights(/*miss=*/1, /*cont=*/1u << 20);

        for (const CapHoistRun &run : runs) {
            IRBuilder<> b(run.head);
            Value *state = emitBumpStateAddr(b, bumpStateTls, bumpStateCallee);
            Value *top = b.CreateAlignedLoad(as1, state, Align(8), "eco.ens.top");
            Value *endp =
                b.CreateGEP(i8Ty, state, {b.getInt64(8)}, "eco.ens.endp");
            Value *end = b.CreateAlignedLoad(as1, endp, Align(8), "eco.ens.end");
            // Plain (non-inbounds) GEP, as in the HEAP_034 diamond: when the
            // block is nearly full the projected address may exceed the block
            // end before the compare rejects it.
            Value *need = b.CreateGEP(i8Ty, top,
                                      {b.getInt64((int64_t)run.bytes)},
                                      "eco.ens.need");
            Value *miss = b.CreateICmpUGT(need, end, "eco.ens.miss");

            // If-THEN (no else): the fast arm carries no instruction, so an
            // else block would be spurious. The run's elements ride into the
            // continuation block, which both edges reach.
            Instruction *thenTerm = SplitBlockAndInsertIfThen(
                miss, run.head, /*Unreachable=*/false, unlikely);
            IRBuilder<> tb(thenTerm);
            tb.CreateCall(ensureCallee,
                          {ConstantInt::get(i64Ty, run.bytes)});
            ++emittedEnsures;

            for (CallInst *mk : run.ownMarkers)
                decisions->uncheckedMarkers.insert(mk);
        }

        decisions->coveredFns.insert(covered.begin(), covered.end());

        // §2.6(a): every direct call site to a covered function is either
        // inside another covered function (whose own guarantee subsumes it)
        // or a member of an emitted run. Covered functions are never
        // address-taken, so every use IS a matched-FTy direct call.
        DenseSet<const CallInst *> runMembers;
        for (const CapHoistRun &run : runs)
            runMembers.insert(run.covCallSites.begin(), run.covCallSites.end());
        // Plan-given mode iterates covered DECLARATIONS too: after the split
        // a covered callee in another partition is a declaration here, and
        // this partition is the only one that sees its call sites.
        SmallVector<Function *, 64> coveredUsersToCheck(covered.begin(),
                                                        covered.end());
        if (planGiven)
            for (Function &f : m)
                if (f.isDeclaration() && calleeCovered(&f))
                    coveredUsersToCheck.push_back(&f);
        for (Function *f : coveredUsersToCheck) {
            for (User *u : f->users()) {
                auto *ci = dyn_cast<CallInst>(u);
                if (!ci || ci->getCalledFunction() != f ||
                    (!covered.count(ci->getFunction()) && !runMembers.count(ci)))
                    return createStringError(
                        std::errc::invalid_argument,
                        "applyCapacityHoisting: unguaranteed use of covered "
                        "function '%s'", f->getName().str().c_str());
            }
        }

        // §2.6(b): no covered function may retain a statepoint-capable or
        // headroom-consuming call. A callee is admissible when it is covered
        // (its budget is inside ours) or provably GC-free (budget 0, which
        // CGEN_072's fixpoint stamps gc-leaf, so RS4GC skips it).
        for (Function *f : covered) {
            for (BasicBlock &bb : *f) {
                for (Instruction &i : bb) {
                    auto *cb = dyn_cast<CallBase>(&i);
                    if (!cb)
                        continue;
                    Function *callee = cb->getCalledFunction();
                    if (markerFn && callee == markerFn)
                        continue;
                    if (isHeadroomBreaker(callee))
                        report_fatal_error(
                            "applyCapacityHoisting: covered function '" +
                            Twine(f->getName()) +
                            "' calls a headroom-breaking leaf");
                    if (hasFacts(callee)) {
                        const CapFact &cf = facts.find(callee)->second;
                        if (cf.covered || (!cf.top && cf.budget == 0))
                            continue;
                        return createStringError(
                            std::errc::invalid_argument,
                            "applyCapacityHoisting: covered function '%s' "
                            "calls '%s', which is neither covered nor "
                            "budget-0", f->getName().str().c_str(),
                            callee->getName().str().c_str());
                    }
                    if (callee && !callee->isDeclaration()) {
                        auto it = info.find(callee);
                        const bool gcFree = it != info.end() &&
                                            !it->second.top &&
                                            it->second.budget == 0;
                        if (covered.count(callee) || gcFree)
                            continue;
                    }
                    if (leafForAnalysis(cb, TLI))
                        continue;
                    report_fatal_error(
                        "applyCapacityHoisting: covered function '" +
                        Twine(f->getName()) +
                        "' retains a statepoint-capable call");
                }
            }
        }

        // §2.6(c): ownership is exclusive — a covered function's markers are
        // covered by ITS caller, never by a run inside itself.
        for (CallInst *mk : decisions->uncheckedMarkers)
            if (covered.count(mk->getFunction()))
                report_fatal_error("applyCapacityHoisting: covered function "
                                   "also holds run-emitted markers");
    }

    if (spikeDump) {
        double tD2 = spikeT();
        llvm::errs() << "[caphoist-spike] tA=" << tA << " tBC=" << tBC
                     << " tD=" << tD << " tD2=" << tD2
                     << " brk_budget0=" << spikeBrkBudget0 << "\n";
    }
    // ---- Phase E: census ---------------------------------------------
    // Nullary-ctor slice: exactly one 16 B marker whose constant header
    // word carries Tag_Custom (size 16 alone is ambiguous — BoxedPrim and
    // RecordBase are also 16). This is the slice the cheaper CAF-slot
    // alternative competes for.
    unsigned nullaryFns = 0, nullarySites = 0;
    for (Function *fp : coverableFns) {
        const CapHoistInfo &fi = info.find(fp)->second;
        if (fi.markers.size() != 1 || fi.ownBytes != 16 ||
            fi.budget != fi.ownBytes)
            continue;
        CallInst *mk = fi.markers[0];
        bool isCustom = false;
        for (User *u : mk->users())
            if (auto *st = dyn_cast<StoreInst>(u))
                if (st->getPointerOperand() == mk)
                    if (auto *hv = dyn_cast<ConstantInt>(st->getValueOperand()))
                        isCustom = (hv->getZExtValue() & 0x1F) == 7; // TagCustom
        if (isCustom) {
            ++nullaryFns;
            nullarySites += fi.numSites;
        }
    }

    std::vector<uint64_t> budgets;
    budgets.reserve(coverableFns.size());
    for (Function *fp : coverableFns)
        budgets.push_back(info.find(fp)->second.budget);
    std::sort(budgets.begin(), budgets.end());
    auto pct = [&](double p) -> uint64_t {
        if (budgets.empty())
            return 0;
        size_t idx = (size_t)(p * (double)(budgets.size() - 1));
        return budgets[idx];
    };

    if (const char *dump = ::getenv("ECO_ALLOC_HOIST_DUMP")) {
        std::ofstream out(partitionDumpPath(dump));
        for (Function *fp : coverableFns) {
            const CapHoistInfo &fi = info.find(fp)->second;
            out << fp->getName().str() << ";" << fi.budget << ";"
                << fi.numSites << ";coverable\n";
        }
        // The v2-cloning population, for sizing that extension.
        for (Function *fp : defined) {
            const CapHoistInfo &fi = info.find(fp)->second;
            if (fi.top || fi.budget == 0 || fi.eligible)
                continue;
            out << fp->getName().str() << ";" << fi.budget << ";0;"
                << (fi.addrTaken ? "excl_addrtaken" : "excl_linkage") << "\n";
        }
    }

    std::string line;
    raw_string_ostream os(line);
    unsigned importCopies = 0;
    for (Function *fp : defined)
        importCopies += fp->hasAvailableExternallyLinkage();
    os << "[caphoist";
    if (partition)
        os << " p" << tlPartitionIndex;
    os << "] coverable=" << coverableFns.size()
       << " defined=" << defined.size() - importCopies
       << " import_copies=" << importCopies << " sites=" << sites
       << " bytes_p50=" << pct(0.50) << " bytes_p90=" << pct(0.90)
       << " bytes_max=" << (budgets.empty() ? 0 : budgets.back())
       << " runs=" << runsTotal << " singleton=" << runsSingleton
       << " multi=" << runsMulti << " folded_markers=" << foldedMarkers
       << " excl_addrtaken=" << exclAddr << " excl_linkage=" << exclLinkage
       << " excl_loop=" << exclLoop << " excl_cycle=" << exclCycle
       << " excl_budget=" << exclBudget << " excl_other=" << exclOther
       << " nullary=" << nullaryFns << " nullary_sites=" << nullarySites
       << " K=" << K
       << " mode=" << (mode == CapHoistMode::On ? "on" : "census");
    if (mode == CapHoistMode::On)
        os << " emitted=" << emittedEnsures
           << " unchecked=" << decisions->uncheckedMarkers.size()
           << " m2=" << (foldOwn ? 1 : 0);
    os << "\n";
    // Same rule as [gcfree]: silent on a default-ON build, loud whenever the
    // run asked for a mode by name.
    if (mode == CapHoistMode::Census || envNamed("ECO_ALLOC_HOIST"))
        llvm::errs() << os.str();
    return Error::success();
}

static void runCapInlinePrepass(Module &m,
                                std::set<std::string> *marked = nullptr) {
    unsigned maxInsts = 64;
    if (const char *e = ::getenv("ECO_CAP_INLINE_MAX_INSTS"))
        maxInsts = (unsigned)strtoul(e, nullptr, 10);

    // Delta-debug hook: ECO_CAP_INLINE_LIST=<file> marks EXACTLY the named
    // functions (one symbol per line), ignoring the threshold. Diagnostic
    // only — lets a crashing marked set be bisected to the guilty body.
    std::set<std::string> onlyList;
    bool useList = false;
    if (const char *lf = ::getenv("ECO_CAP_INLINE_LIST")) {
        useList = true;
        std::ifstream in(lf);
        std::string line;
        while (std::getline(in, line))
            if (!line.empty())
                onlyList.insert(line);
    }

    bool any = false;
    for (Function &f : m) {
        if (f.isDeclaration() || !f.getName().ends_with("$cap"))
            continue;
        if (f.hasFnAttribute(Attribute::NoInline))
            continue;
        // No InlineHint arm: nothing pre-RS4GC consumes a hint, and any attr
        // surviving into the post-RS4GC worker pipelines invites the
        // E1.4-forbidden inlining — attrs are strictly pass-local here.
        // REP_LLVM_002 coupling: the GC-call-free restriction applies only
        // for A/B (ECO_CAP_INLINE_GCFREE_ONLY=1) or FORCED when slot-cast
        // barriers are off — barriers-off + GC-bearing inlining is the
        // known-unsound combination (both bisected miscompiles). The old
        // ECO_CAP_INLINE_NO_GCFREE_GUARD escape is deleted: there is no
        // sound configuration it could enable that the default doesn't.
        static const bool gcfreeOnly =
            (::getenv("ECO_CAP_INLINE_GCFREE_ONLY") != nullptr) ||
            !slotCastBarriersEnabled();
        if (useList ? onlyList.count(f.getName().str()) != 0
                    : (maxInsts && f.getInstructionCount() <= maxInsts &&
                       (!gcfreeOnly || bodyIsGCCallFree(f)))) {
            f.addFnAttr(Attribute::AlwaysInline);
            if (marked)
                marked->insert(f.getName().str());
            any = true;
            static const bool dbg =
                (::getenv("ECO_CAP_INLINE_DEBUG") != nullptr);
            if (dbg)
                llvm::errs() << "[cap-inline] " << f.getName() << " insts="
                             << f.getInstructionCount() << "\n";
        }
    }
    if (!any)
        return;

    PassBuilder PB;
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    MPM.addPass(AlwaysInlinerPass());
    MPM.run(m, MAM);

    // STRIP the inline attrs now that the pre-RS4GC inline pass has consumed
    // them. Leaving them on would arm the POST-RS4GC per-partition pipelines
    // (Dev's explicit AlwaysInlinerPass, Cgu's -O2 inliner) on `$cap` bodies
    // that are statepointed by then — the E1.4-forbidden post-RS4GC inlining
    // that breaks relocation semantics. The attrs exist only for this pass.
    //
    // E1.4 still forbids inlining a STATEPOINTED body post-RS4GC, which is the
    // hazard here. CGEN_072 carves out the complementary case: a stamped
    // GC-free body holds no statepoint, so inlining it post-RS4GC is safe and
    // is deliberately left enabled under ECO_GCFREE_LEAF=1.
    for (Function &f : m) {
        if (f.isDeclaration() || !f.getName().ends_with("$cap"))
            continue;
        f.removeFnAttr(Attribute::AlwaysInline);
    }
}

// plans/mlir-split-backend-00-spikes.md SP5: emulate front-end constant
// thunks (plan 04) on LLVM IR, before the IPO prologue. Diagnostic only.
static void spikeFoldThunks(Module &m, int level) {
    const DataLayout &DL = m.getDataLayout();
    unsigned replacedCalls = 0, foldedBodies = 0, rounds = 0;
    SmallPtrSet<Function *, 32> constantThunks;
    bool changed = true;
    while (changed && rounds < 16) {
        changed = false;
        ++rounds;
        for (Function &f : m) {
            if (f.isDeclaration() || f.arg_size() != 0)
                continue;
            Type *rt = f.getReturnType();
            if (!rt->isIntegerTy() && !rt->isFloatingPointTy())
                continue;
            if (level >= 2 && f.size() == 1) {
                // Constant-fold the body (as LLVM would after substitution).
                SmallVector<Instruction *, 16> insts;
                for (Instruction &i : f.front())
                    insts.push_back(&i);
                for (Instruction *i : insts)
                    if (Constant *c = ConstantFoldInstruction(i, DL)) {
                        i->replaceAllUsesWith(c);
                        i->eraseFromParent();
                        changed = true;
                    }
            }
            if (f.size() != 1)
                continue;
            auto *ret = dyn_cast<ReturnInst>(f.front().getTerminator());
            Constant *cv = ret && ret->getReturnValue()
                               ? dyn_cast<Constant>(ret->getReturnValue())
                               : nullptr;
            if (!cv)
                continue;
            bool pure = true;
            for (Instruction &i : f.front())
                if (&i != ret && i.mayHaveSideEffects())
                    pure = false;
            if (!pure)
                continue;
            if (constantThunks.insert(&f).second && level >= 2)
                ++foldedBodies;
            SmallVector<CallInst *, 16> calls;
            for (Use &u : f.uses())
                if (auto *cb = dyn_cast<CallInst>(u.getUser()))
                    if (cb->getCalledOperand() == &f && cb->arg_size() == 0)
                        calls.push_back(cb);
            for (CallInst *cb : calls) {
                cb->replaceAllUsesWith(cv);
                cb->eraseFromParent();
                ++replacedCalls;
                changed = true;
            }
        }
        if (level < 2)
            break; // phase 1: literal bodies only, one round
    }
    llvm::errs() << "[thunkfold-spike] level=" << level
                 << " constant_thunks=" << constantThunks.size()
                 << " folded_bodies=" << foldedBodies
                 << " replaced_calls=" << replacedCalls << " rounds=" << rounds
                 << "\n";
}

Error runEcoBackend(Module &m, const EcoBackendJob &job,
                    EcoBackendResult *result) {
    // CGEN_081: a reachability stamp the driver did not consume (ecoc
    // paths) must not reach the object.
    stripReachabilityStamp(m);
    // Plan 02 (CGEN_072): did EcoGcFreePropagation stamp this module?
    std::optional<gcfree::Stamp> gcPlan;
    if (auto flag = moduleFlagString(m, gcfree::kPlanFlag)) {
        gcPlan = gcfree::parseStamp(*flag);
        if (!gcPlan)
            return createStringError(std::errc::invalid_argument,
                                     "malformed gc-free plan stamp '%s'",
                                     flag->c_str());
        if (gcFreeLeafMode() != GcFreeMode::Stamp)
            return createStringError(
                std::errc::invalid_argument,
                "gc-free plan stamp without ECO_GCFREE_LEAF stamp mode");
        auto capFlag = capPlanFlag(m);
        if (gcPlan->covered && !capFlag)
            return createStringError(
                std::errc::invalid_argument,
                "gc-free plan stamp says cov=1 but the module has no "
                "capacity-hoisting plan");
        if (capFlag) {
            auto cs = caphoist::parsePlanStamp(*capFlag);
            if (cs && cs->valueEqLeaf != gcPlan->valueEqLeaf)
                return createStringError(
                    std::errc::invalid_argument,
                    "gc-free and capacity-hoisting plan stamps disagree on "
                    "value-eq leafness");
        }
    }
    bool planVeq = gcPlan && gcPlan->valueEqLeaf;
    if (!gcPlan)
        if (auto capFlag = capPlanFlag(m))
            if (auto cs = caphoist::parsePlanStamp(*capFlag))
                planVeq = cs->valueEqLeaf;

    // P2.5 R1b: expand get_tag markers FIRST (their heap arms emit
    // __eco_resolve_fwd calls the next expansion consumes).
    expandGetTagMarkers(m);
    // Chunked-list projection markers (must precede expandInlineDerefs —
    // both this and get_tag emit __eco_resolve_fwd calls it then expands).
    expandListProjMarkers(m);
    // Mixed-spine cursor markers (EcoListCursor): same discipline.
    expandListCursorMarkers(m);
    // kernel-opt-04: eco.string.length markers. Same discipline again -- the
    // heap arm emits a __eco_resolve_fwd call that expandInlineDerefs consumes.
    expandStringLenMarkers(m);
    // kernel-opt-03: eco.value.eq markers. Emits no __eco_resolve_fwd, but must
    // still precede RS4GC and propagateGcFreeLeafAttrs so arm 3 is seen as a call
    // to a gc-leaf declaration rather than an unknown marker.
    expandValueEqFastPath(m, planVeq);
    // Scratch-stack helpers (chunked-list Tier-B templates): mark and the
    // pushes never GC-allocate, so exempt them from RS4GC statepointing.
    // eco_scratch_finish allocates and must statepoint normally.
    for (const char *leaf : {"eco_scratch_mark", "eco_scratch_push_boxed",
                             "eco_scratch_push_scalar"}) {
        if (Function *lf = m.getFunction(leaf))
            lf->addFnAttr("gc-leaf-function");
    }
    // Plan P2: expand inline-deref markers before RS4GC / partition splitting.
    expandInlineDerefs(m);

    // Capacity-check hoisting (plans/capacity-check-hoisting.md, CGEN_074):
    // must run HERE — after every other marker expansion (so all remaining
    // GC hazards are real calls) but BEFORE expandInlineAllocs, while
    // __eco_alloc_inline markers still carry their constant sizes.
    // Census mode is analysis-only and runs regardless of ECO_GCFREE_LEAF;
    // the transform needs the CGEN_072 fixpoint to harvest anything, so a
    // misconfiguration is reported loudly rather than silently no-op'ing.
    CapHoistDecisions capHoist;
    if (capHoistMode() != CapHoistMode::Off) {
        if (capHoistMode() == CapHoistMode::On &&
            gcFreeLeafMode() != GcFreeMode::Stamp) {
            // Both are default-ON, so this only happens when gcfree was
            // turned OFF explicitly. Stay quiet unless hoisting was ALSO
            // asked for by name — otherwise `ECO_GCFREE_LEAF=0` alone would
            // print a warning about a flag the user never mentioned.
            if (envNamed("ECO_ALLOC_HOIST"))
                llvm::errs()
                    << "[caphoist] inactive: capacity hoisting requires "
                       "ECO_GCFREE_LEAF (stamp mode); it is currently off\n";
        } else {
            MaybeScope s(job.stats, "  capacity-hoist analysis (serial)");
            if (auto err = applyCapacityHoisting(
                    m, capHoistMode(), &capHoist,
                    /*allowTls=*/job.kind == BackendKind::EmitObjectFile,
                    /*closedWorld=*/job.capClosedWorld,
                    /*partition=*/job.partition != nullptr))
                return err;
        }
    }

    // Inline nursery allocation (HEAP_034): expand bump-diamond markers.
    // Before the $cap prepass so marker-bearing bodies are correctly
    // classified (the expanded diamond's slow call makes them non-GC-free
    // for bodyIsGCCallFree in the barriers-off fallback config).
    // CGEN_074's decisions select the unchecked form per marker; empty when
    // hoisting is off or census-only.
    // TLS bump-state only for AOT object emission: ORC cannot resolve an
    // initial-exec TLS reference from JIT'd code (plans/inline-bump-state-tls.md).
    expandInlineAllocs(m, &capHoist,
                       /*allowTls=*/job.kind == BackendKind::EmitObjectFile);
    // The plan's attributes and module flag are consumed (P6.8).
    stripCapPlan(m);


    // GC shadow-root-stack registration (plans/gc-root-registration-cost.md):
    // replace the point/push/restore calls that bracket every args-array call
    // site with inline TLS cursor traffic. Same placement rationale as the
    // bump-state inlining above — AOT object emission only, since ORC cannot
    // resolve an initial-exec TLS reference from JIT'd code. Creates no
    // addrspace(1) value, so it is invisible to every RS4GC flavour below.
    expandRootRangeOps(m,
                       /*allowTls=*/job.kind == BackendKind::EmitObjectFile);

    // `$sat` fast-path diamond (plans/gc-root-registration-cost.md Phase 3).
    // MUST precede every RS4GC flavour: the fast edge passes `ptr addrspace(1)`
    // arguments straight into the call, and RS4GC is what covers them there.
    expandSatMarkers(m);

    // Plan 05 (EcoSplit) §1.3: owned functions another partition references
    // become External + hidden BEFORE the prepass, so AlwaysInliner cannot
    // delete an inlined internal `$cap` body that is still needed elsewhere.
    if (job.partition) {
        for (const std::string &name : job.partition->exports)
            if (Function *f = m.getFunction(name))
                if (f->hasLocalLinkage()) {
                    f->setLinkage(GlobalValue::ExternalLinkage);
                    f->setVisibility(GlobalValue::HiddenVisibility);
                }
    }

    std::set<std::string> capMarked; // plan 06 B4: what the prepass marked

    // E1.3: `$cap` inline prepass — must precede EVERY RS4GC flavour (serial,
    // deferred, and per-partition; all are downstream of this point). Skipped
    // at -O0 only.
    if (job.optLevel != CodeGenOptLevel::None) {
        MaybeScope s(job.stats, job.partition
                                    ? "  $cap inline prepass (sum over workers)"
                                    : "  $cap inline prepass (serial)");
        runCapInlinePrepass(m, job.partition ? &capMarked : nullptr);
    }

    // Plan 06 B4: export the late `$cap`s that survived the prepass; record
    // the deleted ones and any marked import copy that survived (the driver
    // turns a marked survivor of a deleted body into a named error).
    if (job.partition) {
        for (Function &f : m)
            if (!f.isDeclaration() && f.hasAvailableExternallyLinkage() &&
                capMarked.count(f.getName().str()))
                job.partition->markedSurvivors.push_back(f.getName().str());
        for (const std::string &name : job.partition->exportsLate) {
            Function *f = m.getFunction(name);
            if (f && !f->isDeclaration()) {
                if (f->hasLocalLinkage()) {
                    f->setLinkage(GlobalValue::ExternalLinkage);
                    f->setVisibility(GlobalValue::HiddenVisibility);
                }
            } else {
                job.partition->deletedLate.push_back(name);
            }
        }
    }

    // Plan 05 §1.3: EcoSplit import copies (available_externally) exist only
    // to be inlined by the prepass. Whatever survives becomes a declaration
    // again — unconditionally (also at -O0): a statepointed copy must never
    // reach the post-RS4GC inliner (02 F8 / E1.4).
    for (Function &f : m)
        if (!f.isDeclaration() && f.hasAvailableExternallyLinkage()) {
            f.deleteBody();
            f.setLinkage(GlobalValue::ExternalLinkage);
        }

    // GC-free function propagation (plans/gc-free-function-propagation.md):
    // must run at THIS choke point — post-marker-expansion + post-$cap-
    // prepass (allocation is visible as non-gc-leaf calls), pre-partition
    // (attrs then ride CloneModule / lazy deleteBody to every RS4GC
    // flavour: serial, deferred, workers, single-partition inline).
    if (gcFreeLeafMode() != GcFreeMode::Off) {
        MaybeScope s(job.stats, "  gc-free leaf propagation (serial)");
        if (gcPlan) {
            // The MLIR stamps are the product (plan 02 Q5); the LLVM fixpoint
            // only runs as their validate twin.
            if (auto err = finishGcFreePlan(m, job.partition != nullptr))
                return err;
        } else {
            propagateGcFreeLeafAttrs(m, gcFreeLeafMode());
            if (gcFreeLeafMode() == GcFreeMode::Stamp)
                if (auto err = checkMarkerDecls(m, std::nullopt))
                    return err;
        }
    }

    // Plan 05 R13: the whole-module chunks fact was consumed by the get-tag
    // expansion; it must not reach the object.
    stripModuleFlag(m, "eco-list-chunks");

    // Plan 05 §1.5: per partition, today's late externalization (it used to
    // run once, whole-module, before the bitcode serialize): every local
    // becomes External + hidden so cross-partition references link.
    if (job.partition) {
        for (GlobalValue &gv : m.global_values())
            if (!gv.hasName())
                return createStringError(
                    std::errc::invalid_argument,
                    "EcoSplit partition holds an unnamed global (its "
                    "externalized name would collide across partitions)");
        externalizeAllLocals(m);
    }
    // Plan 05 R3: no import copy may reach RS4GC, in any mode.
    for (Function &f : m)
        if (f.hasAvailableExternallyLinkage())
            return createStringError(
                std::errc::invalid_argument,
                "available_externally function '%s' reached RS4GC",
                f.getName().str().c_str());

    RS4GCOptions rs4gcOpts;
    rs4gcOpts.preDumpPath = job.preRS4GCDumpPath;
    rs4gcOpts.postDumpPath = job.postRS4GCDumpPath;
    rs4gcOpts.addFramePointerAttr = job.needsFramePointerAttr;

    // EXPERIMENTAL: defer RS4GC to run AFTER opt (EmitObjectFile only). The
    // upfront call is skipped and re-issued below, post-optimization. The
    // bundled SROA/FoldExtractValue cleanup + frame-pointer injection travel
    // with it automatically (they live inside runRS4GCAndMaybeFramePointers).
    // Never combined with parallel-opt: the per-partition workers would then
    // optimize statepoint-free IR with no per-partition RS4GC to follow — GC
    // would break. Parallel-opt forces RS4GC-before (design doc §5).
    const bool deferRS4GC =
        job.rs4gcAfterOpt && job.kind == BackendKind::EmitObjectFile &&
        job.parallelOpt == ParallelOpt::None;

    // Parallel-opt modes move RS4GC + frame-pointer injection INTO the
    // per-partition workers: RS4GC is per-function (consults only callee
    // declaration attrs, preserved by the partition split), so statepointing
    // each partition in parallel is semantically identical to the whole-module
    // run — and the cheap-IPO prologue + split then operate on statepoint-free
    // IR (smaller, faster to serialize). Each worker runs RS4GC BEFORE its
    // optimization, preserving the GC ordering invariant per partition.
    // Diagnostic RS4GC IR dumps force the whole-module path so --dump-*-rs4gc-ir
    // keeps meaning "the module", not "one partition".
    const bool parallelOptEnabled =
        job.kind == BackendKind::EmitObjectFile &&
        job.parallelOpt != ParallelOpt::None &&
        job.optLevel != CodeGenOptLevel::None && job.splitEligible;
    const bool wantRS4GCDumps =
        !job.preRS4GCDumpPath.empty() || !job.postRS4GCDumpPath.empty();
    const bool rs4gcInWorkers = parallelOptEnabled && !wantRS4GCDumps;

    if (!deferRS4GC && !rs4gcInWorkers) {
        MaybeScope s(job.stats, "  RS4GC + frame-pointers (serial)");
        runRS4GCAndMaybeFramePointers(m, rs4gcOpts);
    }

    switch (job.kind) {
    case BackendKind::DumpLLVMText:
        // RS4GC + FP only. Caller owns opt + IR printing so it can pick a
        // TM-aware vs TM-agnostic optimisation pipeline for its use case.
        return Error::success();

    case BackendKind::EmitObjectFile: {
        // ECO_SPIKE_THUNK_FOLD=1|2 (plans/mlir-split-backend-00-spikes.md,
        // SP5): emulate plan 04's front-end constant thunks on LLVM IR.
        // 1 = phase 1 (calls to literal-bodied arity-0 thunks -> constant);
        // 2 = phase 1+2 (closed scalar thunk bodies constant-folded too).
        if (const char *e = ::getenv("ECO_SPIKE_THUNK_FOLD"))
            spikeFoldThunks(m, std::atoi(e));
        // No serial whole-module IPO under the parallel tiers (cgu, dev).
        // The cheap-IPO prologue (IPSCCP + GlobalDCE, ~6 s serial) was
        // retired by plan 04 (plans/mlir-split-backend-04-constant-thunks.md,
        // CGEN_082): its measured value was propagating constant thunks'
        // return values, which the front end now folds at every reference,
        // deleting the calls too (self-compile 108.11 s without it vs 108.25 s
        // with it before 04); its GlobalDCE removed 0.05 % of the functions,
        // since closed-world reachability already ran (CGEN_081).
        if (!parallelOptEnabled && job.optLevel != CodeGenOptLevel::None &&
            job.tm) {
            MaybeScope s(job.stats, "  whole-module opt (serial)");
            if (auto err = runEcoModuleOpt(m, job.tm, job.optLevel))
                return err;
        }
        // Deferred RS4GC runs here — after opt, before object emission.
        if (deferRS4GC)
            runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

        // Decide the partition count here (shared policy — see
        // choosePartitionCount / design_docs/backend-parallel-optimization.md
        // §8.1) rather than in each driver.
        unsigned numParts =
            choosePartitionCount(m, job.splitCodegen, job.splitEligible);
        // When parallel-opt is enabled the per-partition workers optimize;
        // otherwise they only emit (whole-module opt already ran above).
        const ParallelOpt perPart =
            parallelOptEnabled ? job.parallelOpt : ParallelOpt::None;

        // Parallel emission: split the optimized module and emit N objects
        // across threads. The backend owns the extra temp part files; the
        // driver links `result->objectFiles` and removes
        // `result->ownedTempFiles`. See emitObjectFilesSplit.
        if (numParts > 1) {
            if (job.objectFilePath.empty())
                return createStringError(std::errc::invalid_argument,
                    "EmitObjectFile split requires a base objectFilePath");
            std::vector<std::string> paths;
            std::vector<std::string> owned;
            paths.reserve(numParts);
            // Reuse the caller's objectFilePath as partition 0; mint the rest.
            paths.push_back(job.objectFilePath);
            for (unsigned i = 1; i < numParts; ++i) {
                SmallString<256> p;
                if (auto ec = sys::fs::createTemporaryFile("eco-part", "o", p)) {
                    for (auto &f : owned)
                        sys::fs::remove(f);
                    return createStringError(ec,
                        "Could not create temp object file for partition");
                }
                paths.emplace_back(p.str());
                owned.emplace_back(p.str());
            }
            // The lazy bitcode split (externalize + serialize once + per-worker
            // lazy re-parse) was retired by plan 05 (EcoSplit): the default
            // tiers partition in MLIR before translation. This SplitModule
            // path remains for --parallel-opt=none, --rs4gc-after-opt,
            // ECO_MLIR_SPLIT=0 and single-threaded MLIR contexts.
            if (auto err = emitObjectFilesSplit(
                    m, numParts, paths, job.optLevel, perPart,
                    job.devEmitCodeGenLevel, job.devOptO1, job.stats,
                    rs4gcInWorkers ? &rs4gcOpts : nullptr)) {
                for (auto &f : owned)
                    sys::fs::remove(f);
                return err;
            }
            if (result) {
                result->objectFiles = std::move(paths);
                result->ownedTempFiles = std::move(owned);
            }
            return Error::success();
        }

        // Single-object emission. If parallel-opt is enabled but the policy
        // chose a single partition (small module / split off), run the
        // per-partition pipeline here inline — the whole-module -O2 was
        // skipped (and RS4GC too when rs4gcInWorkers).
        // Under EcoSplit (plan 05) this is the partition worker's pipeline;
        // the scopes keep the old "(sum over workers)" stats rows.
        LoweringStats *workerStats = job.partition ? job.stats : nullptr;
        if (rs4gcInWorkers) {
            MaybeScope s(workerStats, "  partition RS4GC (sum over workers)");
            runRS4GCAndMaybeFramePointers(m, rs4gcOpts);
        }
        if (job.partition)
            collectGcLeafReport(m, job.partition->gcReport);
        if (perPart != ParallelOpt::None) {
            MaybeScope s(workerStats, "  partition opt (sum over workers)");
            if (auto err = optimizePartitionModule(
                    m, job.tm, perPart, job.optLevel, job.devOptO1))
                return err;
        }
        if (!job.objectFilePath.empty()) {
            if (!job.tm)
                return createStringError(std::errc::invalid_argument,
                    "EmitObjectFile requires a TargetMachine");
            MaybeScope s(workerStats, "  partition emit (sum over workers)");
            if (auto err = emitObjectFile(m, *job.tm, job.objectFilePath))
                return err;
        }
        if (result)
            result->objectFiles = {job.objectFilePath};
        return Error::success();
    }

    case BackendKind::JITInvokePacked: {
        // JIT path: always run makeOptimizingTransformer (level 0 is a no-op-ish
        // pipeline; matches the pre-Phase-4 behaviour of ecoc::runJIT and
        // EcoRunner::executeJIT). `tm` is typically nullptr — the JIT picks
        // up the real TargetMachine through EcoJIT::create, and the lambda
        // runs after DL is already on the module.
        //
        // The "invalid optimization/size level 288/0" cantFail abort that used
        // to strike here flakily (previously observed on Windows, then on the
        // Linux fork-per-test runner) was NOT an MLIR OptUtils static-state
        // bug: it was a dangling reference. EcoJITOptions::transformer was a
        // non-owning llvm::function_ref bound to a temporary lambda; by the
        // time EcoJIT::create invoked it, the temporary was gone, so job was
        // built by a dead lambda and job.optLevel read stack garbage (288).
        // Fixed by making transformer an owning std::function (EcoJIT.h). The
        // Windows skip below is now redundant but retained conservatively
        // pending a Windows test run.
#if defined(_WIN32)
        return Error::success();
#else
        auto optPipeline = mlir::makeOptimizingTransformer(
            static_cast<unsigned>(job.optLevel), /*sizeLevel=*/0, job.tm);
        if (auto err = optPipeline(&m))
            return err;
        return Error::success();
#endif
    }
    }

    llvm_unreachable("Unknown BackendKind");
}

} // namespace eco

void eco::printOptPassTimes(llvm::raw_ostream &os) {
    if (!optPassTimesEnabled())
        return;
    auto &g = optPassTimesGlobal();
    std::lock_guard<std::mutex> lock(g.mu);
    std::vector<std::pair<std::string, std::pair<double, uint64_t>>> rows;
    double sum = 0;
    for (auto &kv : g.total) {
        rows.push_back({kv.first().str(), kv.second});
        sum += kv.second.first;
    }
    std::sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) {
        return a.second.first > b.second.first;
    });
    os << "\n=== LLVM opt pass times (exclusive, summed over workers) ===\n";
    for (auto &r : rows) {
        if (r.second.first < 0.05)
            break;
        os << llvm::format("  %-60s %9.2f s  %5.1f%%  %9llu\n", r.first.c_str(),
                           r.second.first, 100.0 * r.second.first / sum,
                           (unsigned long long)r.second.second);
    }
    os << llvm::format("  %-60s %9.2f s\n", static_cast<const char *>("total"), sum);
}

