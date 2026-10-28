//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

#include "LoweringStats.h"
#include "Passes/EcoPtrIntVerify.h" // for addEcoGCPipeline
#include "Passes/EcoCapHoistCore.h"  // CGEN_074 core and switches (shared with EcoCapHoistPlan)
#include "Passes/EcoMarkerFacts.h"   // marker table
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
#include <cstdlib>  // getenv/strtoul ($cap inline threshold override)
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

#include <cstddef>  // offsetof (string-length header offset)
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

// The index of the partition this thread lowers, or -1 on a thread that is
// not a partition worker. It only affects the names of diagnostic files (see
// `partitionDumpPath`), so concurrent workers never write the same path.
static thread_local int tlPartitionIndex = -1;

void setPartitionIndex(int i) { tlPartitionIndex = i; }

std::string partitionDumpPath(StringRef path) {
    if (tlPartitionIndex < 0)
        return path.str();
    return path.str() + ".p" + std::to_string(tlPartitionIndex);
}

namespace {

// A timing scope for one backend sub-phase, recorded under `name` from
// construction to destruction, or nothing at all when `stats` is null.
struct MaybeScope {
    // Opens the scope on `stats` when it is non-null; `stats` must outlive
    // this object.
    MaybeScope(eco::LoweringStats *stats, llvm::StringRef name) {
        if (stats)
            scope.emplace(*stats, name);
    }
    std::optional<eco::LoweringStats::Scope> scope;
};

// Returns whether the environment variable `key` is set to a non-empty value,
// whatever that value is. The GC-free and capacity-hoisting switches are on
// by default, so their one-line summaries are printed only when the variable
// was named explicitly, and an ordinary build prints nothing.
bool envNamed(const char *key) {
    const char *e = ::getenv(key);
    return e && *e;
}

// The GC-free and capacity-hoisting switches (`gcFreeLeafMode`,
// `capHoistMode`, `capHoistMaxBytes`, `capHoistFoldOwnMarkers`) are defined
// in `Passes/EcoCapHoistCore.h`, because the MLIR planning pass reads the
// same switches.

// Writes `m` as text IR to `path0` (suffixed by `partitionDumpPath` on a
// partition worker) and reports the outcome on stderr under `tag`. A file
// that cannot be opened is reported and otherwise ignored.
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
// Call-kind survivor census.
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
// buckets (the rest still get static site tallies).
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

// The census buckets above. The numbering is shared with the runtime's
// `kCallCensusKindNames` and must change with it; `CK_COUNT` is a count.
enum CallCensusKind : uint8_t {
    CK_Elm = 0, CK_Kernel, CK_Cap, CK_Helper,
    CK_Runtime, CK_Extern, CK_Indirect, CK_COUNT
};

// Returns the bucket name `k` is printed and selected by, or "?" for a value
// outside the enumeration.
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

// Returns whether `ECO_CALL_CENSUS` is set to a non-empty value other than
// "0". Read once per process.
bool callCensusEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CALL_CENSUS");
        return e && *e && std::strcmp(e, "0") != 0;
    }();
    return on;
}

// Returns whether bucket `k` is counted at run time under the value of
// `ECO_CALL_CENSUS`: every bucket for "1", "all" or an empty value, otherwise
// the buckets named in its comma list. An unrecognised name selects nothing.
// Read once per process.
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

// Returns whether `n` names one of the closure-dispatch entry points that
// generated code calls. `eco_pap_extend_l` is deliberately absent: it grows a
// partial application and never dispatches, so it counts as runtime.
bool callCensusIsTrampoline(StringRef n) {
    return n == "eco_apply_closure" || n == "eco_apply_closure_eval" ||
           n == "eco_apply_closure_typed" ||
           n == "eco_closure_call_saturated" ||
           n == "eco_closure_call_saturated_eval";
}

// Returns whether `n` names one of the libm or libc functions the census
// counts as extern.
bool callCensusIsExtern(StringRef n) {
    static const std::set<std::string> externs = {
        "acos", "asin", "atan", "atan2", "sin", "cos", "tan", "exp",
        "log", "log2", "log10", "pow", "fmod", "floor", "ceil", "sqrt",
        "fabs", "trunc", "round", "ldexp",
        "memcpy", "memset", "memmove", "memcmp", "malloc", "free"};
    return externs.count(n.str()) != 0;
}

// Returns the census bucket of the call target `fn`, already unwrapped from
// any statepoint and stripped of casts; null is an indirect call. The bucket
// is chosen by name, never by `isDeclaration()`, because in a partition a
// callee defined in another partition is a declaration.
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

// Adds the call census to `m`: a counter increment before each counted call
// that survives, the tables naming each site, and a constructor that
// registers them with `eco_call_census_register`. Prints the per-bucket
// static tally to stderr. Does nothing if `m` is already instrumented.
//
// May run concurrently on distinct modules; the stderr tally is the only
// shared state and is printed under a mutex. The increment is a plain
// non-atomic load, add and store, it touches no GC pointer, and inserting it
// before a call is legal even for `musttail`, whose constraints bind only
// what follows the call.
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
    // the ctor's call into the runtime keeps them alive.
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

// Emits `m` as an object file at `path` using `tm`, adding the call census
// first when it is enabled. Returns an error if the file cannot be opened or
// `tm` cannot emit objects.
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

// Per-pass optimizer timing. When `ECO_OPT_PASS_TIMES` is set, every pipeline
// run in this file charges each new-pass-manager pass and analysis its
// exclusive wall time, and the totals over all threads are printed by
// `printOptPassTimes`. Nothing is registered when the variable is unset.

// Returns whether `ECO_OPT_PASS_TIMES` is set, to any value. Read once per
// process.
bool optPassTimesEnabled() {
    static const bool on = ::getenv("ECO_OPT_PASS_TIMES") != nullptr;
    return on;
}
// The process-wide pass-time totals, keyed by pass name.
struct OptPassTimesGlobal {
    std::mutex mu;  // guards `total`
    llvm::StringMap<std::pair<double, uint64_t>> total; // seconds, calls
};
// Returns the process-wide totals, created on first use and never destroyed
// before exit.
OptPassTimesGlobal &optPassTimesGlobal() {
    static OptPassTimesGlobal g;
    return g;
}
// The pass timings of one pipeline run on one thread, added to the
// process-wide totals when the timer is destroyed. Each pass is charged its
// own time minus the time of the passes nested inside it.
//
// `attach` registers callbacks that capture `this`, so the timer must outlive
// every pipeline run with the callbacks it was attached to.
struct OptPassTimer {
    using Clock = std::chrono::steady_clock;
    struct Frame {
        std::string name;
        Clock::time_point start;
        double child = 0;
    };
    std::vector<Frame> stack;
    llvm::StringMap<std::pair<double, uint64_t>> local;

    // Opens a frame for the pass or analysis `name`.
    void push(std::string name) { stack.push_back({std::move(name), Clock::now()}); }
    // Closes the innermost frame and charges its exclusive time; does
    // nothing when no frame is open.
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
    // Registers this timer's callbacks on `pic`.
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
// Optimizes `m` in place with the Dev tier's pipeline: `alwaysinline` calls
// are inlined, then the standard per-function simplification pipeline runs at
// O1 when `devOptO1` is set and otherwise at the level `toOptLevel` gives for
// `optLevel`. No cost-model inliner runs. The fused inliner and simplification
// is most of an -O2 pipeline's time, and without it each function is
// optimized on its own. Always returns success.
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

// Optimizes `m` in place with eco's whole-module pipeline at the level
// `toOptLevel` gives for `optLevel`. Always returns success.
//
// This is LLVM's per-module default pipeline with loop unrolling and
// interleaving on, as `mlir::makeOptimizingTransformer` builds it, except
// that SLP and loop vectorization are off, because eco code is pointer
// chasing and little gain from vector registers is expected, and
// CalledValuePropagation is skipped, because it only attaches `!callees`
// metadata and after RS4GC every indirect call is a statepoint.
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

// Optimizes one partition module in place for the tier `mode`: `Cgu` runs
// `runEcoModuleOpt`, and any other value runs `runNoInlineFunctionPipeline`.
Error optimizePartitionModule(Module &m, TargetMachine *tm, ParallelOpt mode,
                              CodeGenOptLevel optLevel, bool devOptO1) {
    if (mode == ParallelOpt::Cgu) {
        return runEcoModuleOpt(m, tm, optLevel);
    }
    return runNoInlineFunctionPipeline(m, tm, optLevel, devOptO1);
}

// The (X) join. With GC-free stamping, a `gc-leaf-function` declaration in
// one partition is sound only if the function's definition, in whichever
// partition owns it, carries the stamp too, and no check inside one partition
// can see that link. Each partition reports what it defines, stamps and
// declares as leaf after its RS4GC, and the reports are joined afterwards.

// Records in `r` the defined functions of `m`, the defined ones stamped
// `gc-leaf-function`, and the declarations carrying that attribute. Records
// nothing unless GC-free mode is Stamp.
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

// Joins `reports`: returns an error naming the first gc-leaf declaration
// whose function is defined in some partition but stamped in none. A
// declaration with no definition in any report is a runtime or kernel
// function and is trusted. Returns success at once unless GC-free mode is
// Stamp, and prints counts when `ECO_GCFREE_PLAN_STATS` is set and not "0".
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

// Splits `m` with `llvm::SplitModule` into `numPartitions` parts and emits
// part i to `paths[i]`, each on its own thread. Object emission is per
// function and the largest phase of the AOT backend, so it divides well
// across cores. `paths` must have `numPartitions` entries. The split modifies
// `m` itself: its local symbols are given external linkage.
//
// Each worker runs, in order:
//   - RS4GC with `*partitionRS4GC`, when it is non-null; when it is null the
//     caller must have run RS4GC on `m` already, and statepoints and
//     frame-pointer attributes carry through bitcode unchanged;
//   - the per-partition optimization for `perPartitionMode`, unless it is
//     `None`; under `Dev`, `devEmitCG` (when not `~0u`) replaces `optLevel`
//     for the worker's target machine, and `devOptO1` is as for
//     `runNoInlineFunctionPipeline`;
//   - object emission.
// After every worker has finished, the gc-leaf reports are joined as
// `checkCrossPartitionGcLeaf` describes. Returns the first worker error in
// partition order, otherwise the result of the join. `stats`, when non-null,
// is recorded into from every worker.
//
// Correctness rests on three facts. The split runs with `PreserveLocals`
// false, so a local global referenced from several parts is externalized with
// one definition rather than copied, and GC-root globals keep exactly one
// definition. Each part travels as bitcode into its own `LLVMContext` and gets
// its own `TargetMachine`, because neither can be shared across threads. Each
// part emits its own stack map section, and the runtime's stack-map parser
// reads every section the linker concatenates.
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
        // RS4GC works function by function and reads only the callees'
        // `gc-leaf-function` attributes, which the split preserves, so
        // running it per partition gives the same result as on the whole
        // module. It runs before optimization here, as everywhere else.
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
    // object so the linker still finds every expected path. A failure here is
    // ignored.
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


// Gives every local symbol of `m` external linkage with hidden visibility,
// and a name if it has none, as `llvm::SplitModule` does with `PreserveLocals`
// false, so references between partitions resolve at link time when each
// partition keeps only its own definitions.
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

Error joinPartitionGcLeafReports(
    const std::vector<GcLeafPartitionReport> &reports) {
    return checkCrossPartitionGcLeaf(reports);
}

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
    // Auto uses every core, with no fixed cap.
    unsigned want = (request == 0) ? cores : request;
    // ~1 partition per 2000 functions, at least 2 once we've decided to split.
    unsigned bySize = std::max(2u, numDefinedFns / 2000u);
    return std::min(want, bySize);
}

namespace {

// Returns the partition count `choosePartitionCountForCount` gives for the
// number of functions `m` defines.
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
    std::string triple = sys::getDefaultTargetTriple();
#if defined(__APPLE__) && defined(ECO_MACOS_MIN)
    // Stamp the minimum macOS version eco and the runtime archives are built
    // for (ECO_MACOS_MIN, from CMAKE_OSX_DEPLOYMENT_TARGET) into the objects'
    // LC_BUILD_VERSION, rather than the darwin<N> version of whatever host
    // LLVM was built on.
    triple = Triple(Triple(triple).getArchName(), "apple",
                    std::string("macosx") + ECO_MACOS_MIN)
                 .str();
#endif
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
    // explicitly at link time, since nothing relocates into it.)
    targetOpts.FunctionSections = true;
    targetOpts.DataSections = true;
    auto codeGenOpt = static_cast<CodeGenOptLevel>(std::min(optLevel, 3u));

    // Pinned CPU and features, never the host's: see kEcoTargetCPU.
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

// Stops the process with a fatal error if a definition in `m` stamped
// `gc-leaf-function` has interposable or `available_externally` linkage, or
// makes a call that `llvm::callsGCLeafFunction` does not count as leaf, that
// is, a call RS4GC would statepoint. The check does not depend on `hasGC()`,
// so it also covers functions RS4GC never processes, where the check after
// RS4GC in `runRS4GCAndMaybeFramePointers` finds nothing.
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

    // A stamped function that RS4GC still statepointed means the GC-free
    // fixpoint was unsound: a wrongly stamped function that allocates leaves
    // stale pointers in its callers. RS4GC processes a function on hasGC()
    // alone, not on the function's own gc-leaf attribute, so this scan can
    // fail. It follows the post-RS4GC dump so a failing build still leaves
    // the IR on disk.
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

    // Leaf-selective frame pointers (the default; ECO_FP_LEAF=0 puts the
    // attribute on every definition): a function gets frame-pointer=all only
    // if it contains a statepoint, whose stack-map record is read during a
    // stack walk, or a call to eco_gc_push_stack_range anywhere in its body.
    // Do not narrow that second test to the entry block: the rooted argument
    // and capture arrays register ranges outside it. A statepoint-free
    // function makes only gc-leaf calls, so no collection can start beneath
    // it, and it may use the frame-pointer register freely.
    if (opts.addFramePointerAttr) {
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
    internalizeAndDCE(m, {"eco_main", "__eco_init_globals"});
}

bool hasReachabilityStamp(const Module &m) {
    return m.getModuleFlag("eco-reach") != nullptr;
}

static void stripReachabilityStamp(Module &m);

// Removing dead constant users matters because translation's constant folder
// can leave unused ConstantExprs that make Function::hasAddressTaken true,
// and capacity hoisting (CGEN_074) reads that.
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
    // In a partition the oracle would internalize and delete every
    // definition that only another partition references, so it is skipped.
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

// Replaces each `__eco_resolve_fwd` marker call in `m` with an inline
// forwarding check:
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
// Must run before every RS4GC flavour, so that RS4GC tracks %base and the
// field pointers derived from it as ordinary GC pointers. The header load
// stays in addrspace(1) and no ptrtoint is introduced. `eco_follow_forward` is
// gc-leaf, so RS4GC puts no statepoint around the cold call. Does nothing when
// the marker has no uses.
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

// Which `__eco_alloc_inline` markers may expand to an unchecked bump because
// capacity-check hoisting (CGEN_074) has already guaranteed their nursery
// space. Produced by `applyCapacityHoisting` and read by `expandInlineAllocs`.
// Empty means every marker keeps its checked form.
struct CapHoistDecisions {
    // M1: functions whose ENTIRE marker population expands unchecked. Their
    // capacity guarantee is established by their callers (or, transitively,
    // by their callers' callers).
    DenseSet<Function *> coveredFns;
    // M2: individual markers inside NON-covered functions that a
    // caller-local ensure diamond covers. Disjoint from coveredFns, because
    // covered functions are never scanned for runs.
    DenseSet<CallInst *> uncheckedMarkers;

    // Returns whether `marker` expands unchecked.
    bool isUnchecked(CallInst *marker) const {
        return coveredFns.contains(marker->getFunction()) ||
               uncheckedMarkers.contains(marker);
    }
};

//===----------------------------------------------------------------------===//
// Bump-state access
//
// Both bump-state consumers — the HEAP_034 allocation diamond
// (expandInlineAllocs) and the CGEN_074 hoisted capacity check
// (applyCapacityHoisting) — need the address of the calling thread's
// {ptr, end} struct. `eco_bump_state()` returns it, but its body is in the
// runtime library, which LLVM cannot see here, so each use would be an
// out-of-line call. In AOT code the address is instead loaded from the
// initial-exec TLS variable `eco_tl_bump_state`, which the runtime keeps
// equal to what `eco_bump_state()` returns. The address is stable for a
// thread; the CONTENTS are still re-loaded per use.
//
// NOT for the JIT: ORC cannot resolve an initial-exec TLS reference from
// JIT'd code, so callers pass allowTls=false there and keep the call.
//===----------------------------------------------------------------------===//

// Returns whether the TLS bump-state load may be used: true unless
// `ECO_INLINE_BUMP_STATE` is exactly "0". Read once per process.
static bool bumpStateInlineEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_INLINE_BUMP_STATE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns `m`'s declaration of the runtime's initial-exec TLS variable
// `eco_tl_bump_state`, adding one if there is none.
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

// Emits the bump-state address at `b`'s insert point and returns it: a load
// from `tls` when it is non-null, otherwise a call to `bumpStateCallee`.
static Value *emitBumpStateAddr(IRBuilder<> &b, GlobalVariable *tls,
                                FunctionCallee bumpStateCallee) {
    if (!tls)
        return b.CreateCall(bumpStateCallee, {}, "eco.bump.state");
    Value *slot = b.CreateThreadLocalAddress(tls);
    return b.CreateAlignedLoad(b.getPtrTy(0), slot, Align(8), "eco.bump.state");
}

// Replaces each `__eco_alloc_inline(SIZE)` marker call in `m` with inline
// nursery allocation (HEAP_034), by default the bump-pointer fast/slow
// diamond:
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
// trips miss into the statepointed slow call, which collects. The from-space
// is one contiguous extent (HEAP_042), so a miss never means "step to the
// next block".
//
// Address-space discipline: the bump slots are loaded/stored as
// `ptr addrspace(1)` directly (the HPointer word IS the raw address), so this
// expansion introduces NO ptrtoint/inttoptr — out of
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
// Must run before every RS4GC flavour. Does nothing when the marker has no
// uses; otherwise erases the marker declaration afterwards.
//
// `decisions`, when non-null, selects the UNCHECKED form for the markers it
// covers: a bump with no end-load, no compare, no slow edge and no phi. Every
// other marker keeps its diamond.
//
// `allowTls` selects how `%state` is obtained: a TLS load of
// `eco_tl_bump_state` when it is true and `bumpStateInlineEnabled`, otherwise
// the `eco_bump_state()` call. It must be false for JIT code, because ORC
// cannot resolve an initial-exec TLS reference.
//
// Stops the process with a fatal error if a marker's size is not a constant
// multiple of 8 in (0, 4096], or if the number of unchecked expansions
// differs from what `decisions` covers.
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

    // Bookkeeping cross-check for CGEN_074: how many markers the
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
// GC shadow-root-stack expansion
//
// Generated code registers each argument array with the shadow root stack
// through three runtime calls, `eco_gc_stack_range_point`,
// `eco_gc_push_stack_range` and `eco_gc_restore_stack_range_point`, which
// LLVM cannot see into. The shadow stack's cursor is an initial-exec TLS
// variable (`RootSet`), so in AOT code the protocol can be inline memory
// traffic instead:
//
//   point()   -> %p = threadlocal.address @eco_tl_root_sp ; load ptr
//   push(b,n,m) -> load sp ; store b/+0, n/+8, m/+16 ; store sp+24
//   restore(t)  -> store t
//
// The restore point is the cursor itself (StackRootRangeRec is trivially
// destructible, so there is nothing to unwind), which is why restore collapses
// to a single store. The token is the cursor's address as a `size_t`, the same
// value the out-of-line forms use, so inline and out-of-line sites can mix.
// The JIT, which cannot resolve an initial-exec TLS reference from
// ORC-compiled code, keeps calling them (`allowTls` false there, as for the
// bump state).
//
// Why this is NOT redundant with RS4GC: an args array is a storage boundary,
// and REP_LLVM_001 permits `ptr addrspace(1)` -> `i64` there. The moment a GC
// pointer is ptrtoint'd into the array it stops being an SSA pointer and
// statepoint coverage ends; the shadow range covers exactly that hole. This
// pass changes only HOW the range is registered, never WHETHER it is.
//
// No addrspace(1) value is created, loaded or stored here: the base is an
// alloca in addrspace(0) and the other two fields are plain i64. The expansion
// is therefore invisible to RS4GC and outside REP_LLVM_001 entirely.
//
// Conservative by construction — a site is expanded only when `count` is a
// non-zero constant <= 64 (the runtime's own limit) and the base is provably
// non-null. Anything else keeps the call, which still does the right thing.
//===----------------------------------------------------------------------===//

// Returns whether the root-stack calls may be inlined: true unless
// `ECO_TLS_ROOT_STACK` is exactly "0". Read once per process.
static bool rootStackInlineEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_TLS_ROOT_STACK");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns `m`'s declaration of the runtime's initial-exec TLS variable
// `eco_tl_root_sp`, adding one if there is none.
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

// Returns whether `v`, after stripping casts and GEPs, is an alloca or a
// global, and so cannot be null. Any other value counts as possibly null.
static bool isProvablyNonNullStackPtr(Value *v) {
    v = v->stripPointerCastsAndAliases();
    if (isa<AllocaInst>(v) || isa<GlobalValue>(v))
        return true;
    if (auto *gep = dyn_cast<GEPOperator>(v))
        return isProvablyNonNullStackPtr(gep->getPointerOperand());
    return false;
}

// Replaces the root-stack calls in `m` with inline TLS traffic as described
// above. Does nothing unless `allowTls` is true and `rootStackInlineEnabled`;
// `allowTls` must be false for JIT code. A push whose count or base fails the
// conditions above keeps its call.
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
// `$sat` fast-path diamond
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
//   entry:  %W   = load i64, %clo+8                ; n:11|max:11|rk:2|unboxed:40
//           %n   = W & 0x7FF ; %mx = (W>>11)&0x7FF ; %rk = (W>>22)&3 ; %ub = W>>24
//           %c1  = (%mx - %n) == N
//           %c1b = %mx <= SAT_MAX_ARITY (20)       ; every slot described by %ub
//           %c2  = %rk == RC
//           %c3  = ((%ub >> 2*(%c1b ? %n : 0)) & ((1<<2N)-1)) == KC
//           br %c1&%c1b&%c2&%c3, maybe, slow
//   maybe:  %d   = load ptr, %clo+16               ; the EvaluatorDesc
//           %sat = load ptr, %d+satByteOff         ; in bounds: %c1 proved N<=P,
//                                                  ; %c1b proved P<=SAT_MAX_ARITY
//           br %sat != null, fast, slow
//   fast:   %rf  = call <R> %sat(ptr as1 %clo, %a0..%aN-1)
//   slow:   ... the generic sequence ...
//   cont:   %r   = phi [%rf, fast], [%slowResult, slow]
//
// `%c3` is what makes passing the args UNBOXED sound (REP_ABI_001):
// it proves the closure's declared slot kinds for the remaining slots equal the
// site's static assumption. `%c1b` is needed as well —
// `unboxed` describes only 20 slots, so a wider closure's kind bits must not be
// compared at all, or the mask test could pass on unrelated bits. It also makes
// sat[] readable: a descriptor has sat[] only when stage_arity <= SAT_MAX_ARITY
// (empty above it), and every compiled closure has max_values == stage_arity.
//
// The fast edge skips the argument array and its root registration. The
// pointer args stay `ptr addrspace(1)` into the call, so RS4GC covers them as ordinary SSA
// values with no shadow-stack registration at all — which is why this pass MUST
// run before every RS4GC flavour.
//===----------------------------------------------------------------------===//

// Returns whether `$sat` brackets are expanded into diamonds: true unless
// `ECO_SAT_FAST` is exactly "0". Read once per process.
static bool satFastBackendEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_SAT_FAST");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Replaces each `__eco_sat_begin` / `__eco_sat_end` bracket in `m` with the
// diamond above, then erases the marker declarations once unused. A bracket
// is dropped instead, leaving only the generic sequence, when the fast path
// is switched off, the end marker is not in the begin marker's block, an
// operand that must be constant is not, or the new-argument count is not in
// 1..8. Prints counts to stderr when `ECO_PAP_HISTO` is set.
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
        // Packed word (HEAP_078): n_values:11 | max_values:11 | rk:2 | unboxed:40.
        Value *n = b.CreateAnd(W, b.getInt64(0x7FF), "eco.clo.n");
        Value *mx = b.CreateAnd(b.CreateLShr(W, b.getInt64(11)), b.getInt64(0x7FF),
                                "eco.clo.max");
        Value *rk = b.CreateAnd(b.CreateLShr(W, b.getInt64(22)), b.getInt64(3),
                                "eco.clo.rk");
        Value *ub = b.CreateLShr(W, b.getInt64(24), "eco.clo.ub");
        Value *rem = b.CreateSub(mx, n, "eco.clo.rem");
        Value *c1 = b.CreateICmpEQ(rem, b.getInt64(N));
        // `unboxed` describes 20 slots; a wider closure's kinds are not
        // readable, and its descriptor's sat[] is empty.
        Value *c1b = b.CreateICmpULE(mx, b.getInt64(Elm::SAT_MAX_ARITY));
        Value *c2 = b.CreateICmpEQ(rk, b.getInt64(rcC->getZExtValue()));
        // A shift >= 64 gives poison, and `and(false, poison)` is poison;
        // branching on it is UB. Clamp the shift operand so it is in range even
        // when the guard fails.
        Value *nSafe = b.CreateSelect(c1b, n, b.getInt64(0), "eco.clo.nsafe");
        Value *shift = b.CreateShl(nSafe, b.getInt64(1));
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

        // maybe: the descriptor load. `%c1` proved N <= stage_arity and `%c1b`
        // proved stage_arity <= SAT_MAX_ARITY, so sat[] has stage_arity + 1
        // slots here and the load is in bounds.
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



// Replaces each call to the marker `markerName` in `m` with a chunked-list
// projection diamond, fast for a cons cell and slow for a chunk. The fast edge
// loads the cell word at `slotOffset`; the slow edge calls the runtime helper
// `slowName`, declared gc-leaf when `slowIsGcLeaf` is set. For the head and
// tail markers that is:
//
//   base = __eco_resolve_fwd(v); tag = header(base) & mask;
//   tag == Tag_Cons ?  load the cell slot (head +8 / tail +16) through the
//                      __eco_slot_to_hptr barrier (REP_LLVM_002)
//                   :  call the chunk-aware runtime helper (head is gc-leaf;
//                      tail MAY ALLOCATE a successor view and is deliberately
//                      NOT gc-leaf, so RS4GC statepoints it like any
//                      allocating call — the HEAP_034 slow-edge pattern).
//
// The cell edge is weighted as the likely one. Markers exist for the same
// reason as
// __eco_get_tag_inline: the projections sit inside single-block scf regions.
// MUST run before expandInlineDerefs (emits __eco_resolve_fwd) and before
// every RS4GC flavour. Erases the marker declaration; stops the process with
// a fatal error if a use survives.
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

// Replaces each call to the list-cursor marker `markerName` in `m` with its
// inline expansion; `variant` says which marker it is, as the parameter's
// comment lists. The markers, emitted by the EcoListCursor pass, are:
//
//   __eco_list_cur_inline(node, idx)       element at position, !eco.value
//   __eco_list_cur_{i64,f64,char}_inline   unboxed element variants (char = i32)
//   __eco_list_step_node_inline(node, idx) next node (cell tail / same chunk
//                                          while the run lasts / chunk next)
//   __eco_list_step_idx_inline(node, idx)  next index (0 on node change)
//
// Every edge is a pure load, so stepping THROUGH a chunk allocates nothing,
// unlike `eco_list_tail_hybrid`. All markers are gc-leaf shaped and fully expanded here,
// before every RS4GC flavour. Positions are normalized: idx > 0 only inside
// a chunk with idx < run, so the cell edges may assume idx == 0.
static void expandListCursorMarker(Module &m, const char *markerName,
                                   int variant /*0=value,1=i64,2=f64,3=char(i32),
                                                 4=stepNode,5=stepIdx*/) {
    Function *marker = m.getFunction(markerName);
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    // Elm Char = i32 code point (eco::kEcoCharBits); its slot word holds the
    // code point zero-extended to 64 bits, so a trunc recovers it.
    Type *charTy = Type::getInt32Ty(ctx);
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
                cellVal = fb.CreateTrunc(w, charTy);
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
                chunkVal = sb.CreateTrunc(w, charTy);
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
                                : variant == 2 ? f64Ty : charTy;
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

// Expands every list-cursor marker in `m`.
static void expandListCursorMarkers(Module &m) {
    expandListCursorMarker(m, "__eco_list_cur_inline", 0);
    expandListCursorMarker(m, "__eco_list_cur_i64_inline", 1);
    expandListCursorMarker(m, "__eco_list_cur_f64_inline", 2);
    expandListCursorMarker(m, "__eco_list_cur_char_inline", 3);
    expandListCursorMarker(m, "__eco_list_step_node_inline", 4);
    expandListCursorMarker(m, "__eco_list_step_idx_inline", 5);
}

// The byte offset of `Header::size` inside the 8-byte object header.
// HEAP_025/HEAP_032: for EVERY String form this word IS the logical UTF-16
// length. Deliberately NOT the array length offset (8, layout::ArrayLengthOffset)
// -- arrays keep their length in a field AFTER the header, so a copy-paste from
// ArrayLengthOpLowering would read the first two UTF-16 chars of a Tag_String leaf.
static constexpr uint64_t kHeaderSizeFieldOffset = offsetof(Elm::Header, size);
static_assert(kHeaderSizeFieldOffset == 4,
              "Header::size moved; expandStringLenMarkers reads it directly");

// Returns whether value-equality markers expand to the inline diamond: true
// unless `ECO_VALUE_EQ_INLINE` is exactly "0", which leaves a bare call.
// Read once per process.
static bool valueEqInlineEnabled() {  // ECO_VALUE_EQ_INLINE=0 -> bare call
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_INLINE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns whether `Elm_Kernel_Utils_equal` is stamped gc-leaf by switch, as
// `valueEqGcLeafEnv` in `Passes/EcoCapHoistCore.h` decides.
static bool valueEqGcLeafEnabled() {  // ECO_VALUE_EQ_GCLEAF=1 -> stamp
    return valueEqGcLeafEnv(); // shared with the MLIR planners
}

// Replaces each `__eco_value_eq(a, b) -> i1` marker call in `m` with the
// word-equality diamond below, or with a bare call to `Elm_Kernel_Utils_equal`
// when `valueEqInlineEnabled` is false. MUST run before EVERY RewriteStatepointsForGC flavour
// and before propagateGcFreeLeafAttrs (CGEN_072), so the fixpoint sees arm 3 as a
// call to a gc-leaf declaration rather than an unknown marker.
//
//   head: %same = icmp eq ptr addrspace(1) %a, %b
//         br %same, cont, test
//   test: %aw = ptrtoint %a ; %bw = ptrtoint %b        (REP_LLVM_001(d): the i64s
//         %any = icmp ne (and (or %aw,%bw), 4), 0       are consumed by or/and/icmp
//         %evh = Empty (0x6) on one side, heap on the   in this SAME block)
//                other (may be a zero-length String)
//         br (%any & !%evh), cont, slow
//   slow: %r  = call @Elm_Kernel_Utils_equal(%a, %b)
//         %rb = icmp eq %r, inttoptr(0x5)
//         br cont
//   cont: %res = phi i1 [true, head], [false, test], [%rb, slow]
//
// Whether or not there are markers, the module's `Elm_Kernel_Utils_equal`
// declaration, which is added only when the marker is declared, is stamped
// gc-leaf when `valueEqGcLeafEnabled` or `planVeq` holds. `planVeq` is
// the value-eq predicate the MLIR plan stamped (eco-gcfree-plan or
// eco-cap-plan), so a module reaches the planner's answer. Erases the marker
// declaration; stops the process with a fatal error if a use survives.
static void expandValueEqFastPath(Module &m, bool planVeq) {
    LLVMContext &ctx = m.getContext();
    Type *i1Ty = Type::getInt1Ty(ctx), *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t constBit = 1ULL << PTR_IND_BIT;                   // 0x4
    const uint64_t trueWord = constBit | (uint64_t)Elm::Const_True;  // 0x5
    const uint64_t emptyWord = constBit | (uint64_t)Elm::Const_Empty; // 0x6

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
        if (!valueEqInlineEnabled()) {  // bare call
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
        // HEAP_071: the Empty constant equals a zero-length heap
        // String, so Empty vs a heap pointer is not decided by the words: it
        // takes the slow arm (Utils_equal checks the length). Every other
        // pair with a constant is unequal.
        Value *zero = ConstantInt::get(i64Ty, 0);
        Value *cb = ConstantInt::get(i64Ty, constBit);
        Value *ew = ConstantInt::get(i64Ty, emptyWord);
        Value *aHeap = tb.CreateICmpEQ(tb.CreateAnd(aw, cb), zero);
        Value *bHeap = tb.CreateICmpEQ(tb.CreateAnd(bw, cb), zero);
        Value *emptyVsHeap = tb.CreateOr(
            tb.CreateAnd(tb.CreateICmpEQ(aw, ew), bHeap),
            tb.CreateAnd(tb.CreateICmpEQ(bw, ew), aHeap), "eq.emptyvsheap");
        Value *decided = tb.CreateAnd(any, tb.CreateNot(emptyVsHeap), "eq.decided");
        tb.CreateCondBr(decided, contBB, slowBB);

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

// Replaces each `__eco_string_len_inline` marker call in `m` with the
// observable semantics of `Elm_Kernel_String_length`:
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
// returns 0. Marker (not an MLIR diamond) because eco.string.length sits
// inside single-block scf regions, as for __eco_get_tag_inline. MUST run
// before expandInlineDerefs. Erases the marker declaration; stops the process
// with a fatal error if a use survives.
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

// Expands the list head and tail projection markers in `m`. The tail helper
// may allocate, so it is not gc-leaf.
static void expandListProjMarkers(Module &m) {
    expandListProjMarker(m, "__eco_list_head_inline", /*slotOffset=*/8,
                         "eco_list_head_hybrid", /*slowIsGcLeaf=*/true);
    expandListProjMarker(m, "__eco_list_tail_inline", /*slotOffset=*/16,
                         "eco_list_tail_hybrid", /*slowIsGcLeaf=*/false);
}

// Replaces each `__eco_get_tag_inline` marker call in `m` with open-coded
// `eco_get_tag` semantics, which must stay identical to the runtime's
// `eco_get_tag`:
//
//   embedded constant (ptr_ind set) -> Bool -> its i1 value; "empty" ->
//     CONSTANT_TAG (0xFFFD);
//   heap object -> Tag_Custom -> ctor (low 16 bits of the word at +8;
//     the upper bits are the unboxed bitmap — load i16, never i32);
//     Tag_Cons -> 1; anything else -> 0.
//
// The marker exists because eco.get_tag sits INSIDE single-block scf regions
// (loopified tail recursion), where the MLIR
// lowering cannot create blocks; here at the LLVM level block structure is
// free. The heap arm resolves via a `__eco_resolve_fwd` marker call, so this
// MUST run BEFORE expandInlineDerefs (which then expands those) — and, like
// it, before the `$cap` prepass and every RS4GC flavour. The transient
// ptrtoint feeds only a same-block bit-test chain (REP_LLVM_001(c)/(d)); it
// has no foldable inttoptr partner because every slot decode is barriered or
// typed (REP_LLVM_002). Erases the marker declaration; stops the process
// with a fatal error if a use survives.
static void expandGetTagMarkers(Module &m) {
    Function *marker = m.getFunction("__eco_get_tag_inline");
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *u16Ty = Type::getInt16Ty(ctx);  // Custom.ctor is u16 (not Char)
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
            cb.CreateAlignedLoad(u16Ty, ctorPtr, Align(8), "eco.ctor"), i32Ty);
        BasicBlock *custBB = custTerm->getParent();

        IRBuilder<> ob(otherTerm);
        Value *isCons =
            ob.CreateICmpEQ(tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons));
        // Chunked-list modules: a Tag_ConsChunk view is also the list Cons
        // constructor (ctor 1) for case dispatch. The extra compare is
        // emitted ONLY when the module enables chunk production, shown by a
        // used eco_enable_list_chunks declaration or the module flag
        // `eco-list-chunks`, so other modules are unchanged.
        {
            // Under EcoSplit only `main`'s partition sees the injected call,
            // which is why the module flag is also read.
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

// Returns whether every call in `f` is to an intrinsic or to a function
// carrying `gc-leaf-function`. An indirect call counts as one that may GC.
// A body with no call that may GC holds no statepoint after RS4GC, so nothing
// can be live across one, and inlining it before RS4GC is sound however
// casts in it fold.
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

// Returns whether the call `cb` counts as a gc-leaf call for the GC-free and
// capacity-hoisting analyses. This is `llvm::callsGCLeafFunction`, except that
// a call that is not direct but whose operand, stripped of casts, is a defined
// function or one carrying a capacity-hoisting fact counts as not leaf.
// callsGCLeafFunction reads gc-leaf off the called OPERAND with
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

// Finds the defined functions of `m` that cannot GC and, when `mode` is
// Stamp, stamps them `gc-leaf-function`, so that every RS4GC flavour skips
// statepointing direct calls to them. Census mode stamps nothing. Prints a
// summary when `mode` is Census or `ECO_GCFREE_LEAF` is named, and writes
// name lists when `ECO_GCFREE_LEAF_DUMP` or `ECO_GCFREE_ALL_DUMP` is set.
//
// A function is poisoned by interposable linkage, a landing pad, an invoke or
// callbr, or a call that `leafForAnalysis` does not count as leaf and whose
// callee is not a defined, non-interposable function of `m`. Poison
// propagates from callee to caller to a fixed point; a cycle of unpoisoned
// functions stays GC-free, which is correct, since recursion without
// allocation cannot GC.
//
// At this point in the pipeline allocation is visible ONLY as calls: the
// inline-alloc diamond's slow edge (eco_alloc_inline_slow, deliberately
// not gc-leaf), eco_gc_alloc_region_slow, the boxed eco_alloc_* family,
// and kernel externs. There is no write barrier and no safepoint poll.
//
// Twin mode (`twinFree` non-null): the validation oracle for the MLIR
// producer. Nothing is stamped or reported; a call to a defined,
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
    // Every function still DEFINED at this point (the $cap prepass may have
    // deleted inlined bodies).
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

    // How many surviving `$cap` clones are stamped. The count covers every
    // `$cap` clone, not only those a templated loop calls, and it omits
    // small clones the `$cap` prepass already inlined and deleted.
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
// Capacity-check hoisting (CGEN_074).
//
// An inline allocation normally checks the nursery's remaining space itself.
// A function whose ONLY GC hazard is its own bounded, fixed-size inline
// allocation is "coverable": its total, its byte budget, can be checked once
// in advance. M1 makes a coverable function's markers unchecked and has its
// callers ensure its budget before calling it; M2 checks a straight-line run
// of markers and covered calls inside one block once, at the run's head.
//
// It runs before expandInlineAllocs, while `__eco_alloc_inline` markers still
// carry their constant sizes and every other GC hazard is already visible as
// a real call.
// ---------------------------------------------------------------------

// Returns whether `f` is non-null and is one of the functions the marker
// table lists as consuming nursery headroom. gc-leaf does NOT imply leaving
// the bump state alone: these functions void a capacity guarantee despite
// their attribute.
static bool isHeadroomBreaker(const Function *f) {
    return f && markers::isHeadroomBreaker(f->getName());
}

// Adds to `inCycle` every block of `f` that sits inside a CFG cycle, self
// loops included. A marker there can execute an unbounded number of times, so
// its bytes are not a static budget.
static void computeBlockCycles(Function &f,
                               SmallPtrSetImpl<BasicBlock *> &inCycle) {
    for (scc_iterator<Function *> it = scc_begin(&f); !it.isAtEnd(); ++it)
        if (it.hasCycle()) // true for size>1 AND self-loops
            for (BasicBlock *bb : *it)
                inCycle.insert(bb);
}

namespace {
// Why a function's budget is unbounded (top), as counted in the summary.
enum class TopReason { None, Loop, Cycle, Budget, Other };

// What the compute-mode analysis knows about one defined function.
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

// Per-node state for a Tarjan SCC walk. Nothing in this file uses it.
struct TarjanNode {
    unsigned index = 0;
    unsigned low = 0;
    bool onStack = false;
    bool visited = false;
};

// One straight-line run: a maximal ordered subsequence of ELEMENTS within a
// single basic block with no intervening breaker. Recorded by the
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
    SmallVector<CallInst *, 4> covCallSites; // for the coverage assert
};
} // namespace

// ---- Plan-given mode ----
// What the MLIR planner (EcoCapHoistPlan) stamped on one function, as
// passthrough string attributes: "eco-cap-budget"="N" or "eco-cap-top", plus
// "eco-cap-covered". `has` is false when the function carries none of them.
struct CapFact {
    bool has = false;
    bool top = false;
    bool covered = false;
    uint64_t budget = 0;
};

// Returns the capacity-hoisting facts stamped on `f`, or an error if the
// budget is not a decimal number, `eco-cap-top` appears with a budget or
// `eco-cap-covered`, or a covered function's budget is 0.
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

// Returns the string value of `m`'s module flag `key`, or nothing if the flag
// is absent or not a string.
static std::optional<std::string> moduleFlagString(const Module &m,
                                                   StringRef key) {
    if (auto *md = dyn_cast_or_null<MDString>(m.getModuleFlag(key)))
        return md->getString().str();
    return std::nullopt;
}

// Returns the capacity-hoisting plan flag of `m`, if the MLIR planner set one.
static std::optional<std::string> capPlanFlag(const Module &m) {
    return moduleFlagString(m, caphoist::kPlanFlag);
}

// Removes the module flag `key` from `m`, if present. Plan stamps are for this
// backend only and must not reach the object.
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

// Removes the `eco-reach` module flag from `m`, if present.
static void stripReachabilityStamp(Module &m) {
    stripModuleFlag(m, "eco-reach");
}

// Removes the capacity-hoisting attributes from every function of `m`, and
// the plan flag. Called once expandInlineAllocs has used the decisions; left
// on, they would renumber `attributes #N` groups in text dumps.
static void stripCapPlan(Module &m) {
    for (Function &f : m) {
        f.removeFnAttr(caphoist::kAttrBudget);
        f.removeFnAttr(caphoist::kAttrTop);
        f.removeFnAttr(caphoist::kAttrCovered);
    }
    stripModuleFlag(m, caphoist::kPlanFlag);
}

// Returns an error naming the first declaration in `m` whose gc-leaf
// attribute disagrees with `markers::expansionCalleeLeaf`, the marker table's
// answer for the functions marker expansion calls. Eco puts gc-leaf only on
// callees, never on call sites, so checking declarations equals checking
// every call. `veq` is the planned value-eq predicate; when it is empty,
// `Elm_Kernel_Utils_equal` is not checked.
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

// Finishes GC-free stamping for a module that EcoGcFreePropagation already
// stamped in MLIR: checks the marker declarations, optionally validates the
// stamps against the LLVM-level analysis, reports, and removes the plan flag.
// `m` must carry a gc-free plan flag that parses. Returns an error if a
// marker declaration disagrees, or if validation (`gcFreeValidateEnabled`,
// whole modules only, not when `partition` is set) finds a stamped function
// that can reach a GC.
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

    // In a partition the twin would read every cross-partition declaration's
    // stamp as a leaf and silently stop checking those edges, so only a
    // whole module is validated.
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

// Returns whether `ECO_CAPHOIST_VALIDATE` is set to a non-empty value other
// than "0". Read once per process.
static bool capHoistValidateEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_CAPHOIST_VALIDATE");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Decides capacity-check hoisting (CGEN_074) for `m` and, when `mode` is On,
// applies it: inserts the hoisted ensure checks before each run and fills
// `*decisions` with the markers `expandInlineAllocs` may expand unchecked.
// Census mode only reports. `allowTls` is as for `expandInlineAllocs`.
//
// When `m` carries the MLIR planner's plan flag, the stamped per-function
// facts are used and verified locally (plan-given mode). Otherwise the
// decision is computed here with `caphoist::solve` (compute mode), which
// needs the whole program and so is refused when `partition` is set.
// `closedWorld` must match the value the plan was computed with.
// `ECO_CAPHOIST_VALIDATE` adds the compute-mode result as a twin check of a
// whole-module plan.
//
// Returns an error for a malformed or mismatched plan, facts without a plan,
// a generated definition already gc-leaf in compute mode, an untrusted
// gc-leaf declaration without facts, facts that fail local verification or
// the twin check, or a covered function used outside a guaranteed site.
// Other internal consistency checks stop the process with a fatal error.
static Error applyCapacityHoisting(Module &m, CapHoistMode mode,
                                   CapHoistDecisions *decisions,
                                   bool allowTls, bool closedWorld,
                                   bool partition) {
    Function *markerFn = m.getFunction("__eco_alloc_inline");
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);
    const uint64_t K = capHoistMaxBytes();
    // Per-phase times and a full per-function dump, only when
    // ECO_CAPHOIST_FULL_DUMP is set.
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

    // ---- Mode selection ----------------------------------------------
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
    // Compute mode needs the whole program; a partition must carry the MLIR
    // plan when hoisting transforms.
    if (partition && !planGiven && mode == CapHoistMode::On)
        return createStringError(
            std::errc::invalid_argument,
            "capacity hoisting: an EcoSplit partition without a plan stamp");
    // The compute-mode twin cannot run on a partition (its cross-partition
    // callees are declarations).
    const bool validate = planGiven && capHoistValidateEnabled() && !partition;
    auto hasFacts = [&](const Function *f) {
        return planGiven && f && facts.count(f);
    };

    if (!planGiven && mode == CapHoistMode::On) {
        // Compute-mode Phase A is stamp-agnostic (it tests a generated
        // defined callee BEFORE gc-leaf), but
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
        // A declaration that is gc-leaf without eco-cap
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
        // The marker table must agree with what the expansions emitted.
        if (auto err = checkMarkerDecls(m, plan->valueEqLeaf))
            return err;
    }

    // ---- Phase A: local scan -----------------------------------------
    // `r1` selects the plan-given classification order: a callee that
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
                    // Compute mode is stamp-agnostic: a generated defined
                    // callee is an edge BEFORE its gc-leaf stamp is
                    // consulted. On an unstamped module the order makes no
                    // difference (a defined callee is leaf only when stamped).
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
        // Run compute-mode A-C on the same module, ignoring the plan; every
        // definition must agree with its stamped facts.
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
        // ---- local verification of the stamped facts ------------------
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
                // of an owner that its own partition verifies.
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
            // Finite nonzero budget but uninstrumentable callers.
            if (fi.addrTaken)
                ++exclAddr;
            else if (fi.nonLocal)
                ++exclLinkage;
            continue;
        }
        covered.insert(fp);
        coverableFns.push_back(fp);
    }
    // Callee views used by Phase D, D2 and the checks: in plan-given mode they come
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
                // A generated callee (eco-cap facts) that is not covered is
                // a breaker even if it is gc-leaf, as an unstamped budget-0
                // callee is in compute mode.
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
        // (gc-leaf does NOT imply leaving the bump state alone), sit
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
        // The hoisted ensure reads the bump state too, so it takes the same TLS path as the alloc diamond.
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

        // Check (a): every direct call site to a covered function is either
        // inside another covered function (whose own guarantee subsumes it)
        // or a member of an emitted run. Any other use of a covered
        // function is rejected below with an error.
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

        // Check (b): no covered function may retain a statepoint-capable or
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

        // Check (c): ownership is exclusive — a covered function's markers are
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
    // RecordBase are also 16).
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
        // Functions with a finite nonzero budget that are not eligible.
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

// Inlines small `$cap` fast-evaluator bodies into their direct callers, in
// the whole module, before any RS4GC. A statepointed call is not inlined, so
// this is the only point where calls to `$cap` bodies that may collect can be
// inlined.
// Inlining before statepointing is LLVM's ordinary order, so relocation
// (REP_LLVM_001) is unaffected.
//
// A defined `$cap` function without `noinline` is marked `alwaysinline` when
// its instruction count is at most the threshold, 64 unless
// `ECO_CAP_INLINE_MAX_INSTS` says otherwise (0 marks nothing), and, when
// `ECO_CAP_INLINE_GCFREE_ONLY` is set or slot-cast barriers are off,
// `bodyIsGCCallFree` holds. When `ECO_CAP_INLINE_LIST` names a file, exactly
// the functions listed in it are marked instead, with no threshold and no
// GC-free test. The marked names are added to `*marked` when it is non-null.
// If anything was marked, LLVM's AlwaysInliner runs, and then `alwaysinline`
// is removed from every `$cap` function. `$cap` functions are address-taken
// by closure evaluator fields, so their bodies survive for indirect calls.
//
// GC-bearing bodies are inlined only because slot-cast barriers are on by
// default. Without them, inlining folds `ptrtoint(inttoptr(x))` pairs at
// boxed-slot crossings, and a raw i64 copy of a GC pointer becomes live
// across a statepoint of the inlined body, which RS4GC cannot relocate. The
// barriers are opaque gc-leaf calls the inliner cannot fold, removed only
// after RS4GC. That is why the GC-free test is forced when they are off.
//
// Only call sites whose signature matches the callee are inlined. A site
// with a mismatched view of the callee stays an indirect call: rebuilding it
// with ptrtoint/inttoptr casts and inlining it would put a raw i64 across
// statepoints, which RS4GC cannot relocate.
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
        // No inlinehint: nothing before RS4GC reads a hint, and an attribute
        // surviving into the post-RS4GC pipelines would invite inlining of
        // statepointed bodies.
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

    // Strip the attribute now that it has been used. Left on, it would make
    // the post-RS4GC pipelines (Dev's AlwaysInlinerPass, Cgu's -O2 inliner)
    // inline `$cap` bodies that are statepointed by then, which breaks
    // relocation. A GC-free body stamped by CGEN_072 holds no statepoint, so
    // the cost-model inliner may still inline it after RS4GC.
    for (Function &f : m) {
        if (f.isDeclaration() || !f.getName().ends_with("$cap"))
            continue;
        f.removeFnAttr(Attribute::AlwaysInline);
    }
}

// A diagnostic experiment: replaces calls to zero-argument functions whose
// single block returns an integer or floating-point constant with no side
// effects by that constant. At `level` 2 or more it also constant-folds such
// bodies and repeats, up to 16 rounds; below 2 it makes one round. Prints the
// counts to stderr.
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
    // CGEN_081: a reachability stamp the caller did not consume must not
    // reach the object.
    stripReachabilityStamp(m);
    // CGEN_072: did EcoGcFreePropagation stamp this module?
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

    // Expand get_tag markers FIRST (their heap arms emit
    // __eco_resolve_fwd calls the next expansion consumes).
    expandGetTagMarkers(m);
    // Chunked-list projection markers (must precede expandInlineDerefs —
    // both this and get_tag emit __eco_resolve_fwd calls it then expands).
    expandListProjMarkers(m);
    // Mixed-spine cursor markers (EcoListCursor): same discipline.
    expandListCursorMarkers(m);
    // eco.string.length markers. Same discipline again -- the
    // heap arm emits a __eco_resolve_fwd call that expandInlineDerefs consumes.
    expandStringLenMarkers(m);
    // eco.value.eq markers. Emits no __eco_resolve_fwd, but must
    // still precede RS4GC and propagateGcFreeLeafAttrs so arm 3 is seen as a call
    // to a gc-leaf declaration rather than an unknown marker.
    expandValueEqFastPath(m, planVeq);
    // Scratch-stack helpers (chunked-list templates): mark and the pushes
    // never GC-allocate, so exempt them from RS4GC statepointing.
    // eco_scratch_finish allocates and must statepoint normally.
    for (const char *leaf : {"eco_scratch_mark", "eco_scratch_push_boxed",
                             "eco_scratch_push_scalar"}) {
        if (Function *lf = m.getFunction(leaf))
            lf->addFnAttr("gc-leaf-function");
    }
    // Expand inline-deref markers, after every expansion that emits them.
    expandInlineDerefs(m);

    // Capacity-check hoisting (CGEN_074): must run HERE — after every other marker expansion (so all remaining
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
    // initial-exec TLS reference from JIT'd code.
    expandInlineAllocs(m, &capHoist,
                       /*allowTls=*/job.kind == BackendKind::EmitObjectFile);
    // The plan's attributes and module flag are consumed.
    stripCapPlan(m);


    // GC shadow-root-stack registration: replace the point/push/restore calls that bracket every args-array call
    // site with inline TLS cursor traffic. Same placement rationale as the
    // bump-state inlining above — AOT object emission only, since ORC cannot
    // resolve an initial-exec TLS reference from JIT'd code. Creates no
    // addrspace(1) value, so it is invisible to every RS4GC flavour below.
    expandRootRangeOps(m,
                       /*allowTls=*/job.kind == BackendKind::EmitObjectFile);

    // `$sat` fast-path diamond.
    // MUST precede every RS4GC flavour: the fast edge passes `ptr addrspace(1)`
    // arguments straight into the call, and RS4GC is what covers them there.
    expandSatMarkers(m);

    // Partition worker: owned functions another partition references
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

    std::set<std::string> capMarked; // what the prepass marked

    // `$cap` inline prepass — must precede EVERY RS4GC flavour (serial,
    // deferred, and per-partition; all are downstream of this point). Skipped
    // at -O0 only.
    if (job.optLevel != CodeGenOptLevel::None) {
        MaybeScope s(job.stats, job.partition
                                    ? "  $cap inline prepass (sum over workers)"
                                    : "  $cap inline prepass (serial)");
        runCapInlinePrepass(m, job.partition ? &capMarked : nullptr);
    }

    // Export the late `$cap`s that survived the prepass; record the deleted
    // ones and any marked import copy that survived.
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

    // EcoSplit import copies (available_externally) exist only to be inlined
    // by the prepass. Whatever survives becomes a declaration again,
    // unconditionally (also at -O0): a statepointed copy must never reach the
    // post-RS4GC inliner.
    for (Function &f : m)
        if (!f.isDeclaration() && f.hasAvailableExternallyLinkage()) {
            f.deleteBody();
            f.setLinkage(GlobalValue::ExternalLinkage);
        }

    // GC-free function propagation: must run at THIS choke point — post-marker-expansion + post-$cap-
    // prepass (allocation is visible as non-gc-leaf calls). Whole-module when
    // unsplit (attrs then ride CloneModule / lazy deleteBody to every RS4GC
    // flavour: serial, deferred, workers, single-partition inline); under the
    // MLIR split it runs per partition, where a cross-partition callee is a
    // declaration and so poison (sound, fewer stamps).
    if (gcFreeLeafMode() != GcFreeMode::Off) {
        MaybeScope s(job.stats, "  gc-free leaf propagation (serial)");
        if (gcPlan) {
            // The MLIR stamps are the product; the LLVM fixpoint only runs
            // as their validation twin.
            if (auto err = finishGcFreePlan(m, job.partition != nullptr))
                return err;
        } else {
            propagateGcFreeLeafAttrs(m, gcFreeLeafMode());
            if (gcFreeLeafMode() == GcFreeMode::Stamp)
                if (auto err = checkMarkerDecls(m, std::nullopt))
                    return err;
        }
    }

    // The whole-module chunks fact was consumed by the get-tag expansion; it
    // must not reach the object.
    stripModuleFlag(m, "eco-list-chunks");

    // Partition worker: every local becomes External + hidden so
    // cross-partition references link.
    if (job.partition) {
        for (GlobalValue &gv : m.global_values())
            if (!gv.hasName())
                return createStringError(
                    std::errc::invalid_argument,
                    "EcoSplit partition holds an unnamed global (its "
                    "externalized name would collide across partitions)");
        externalizeAllLocals(m);
    }
    // No import copy may reach RS4GC, in any mode.
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
    // would break. Parallel-opt forces RS4GC-before.
    const bool deferRS4GC =
        job.rs4gcAfterOpt && job.kind == BackendKind::EmitObjectFile &&
        job.parallelOpt == ParallelOpt::None;

    // Parallel-opt modes move RS4GC + frame-pointer injection INTO the
    // per-partition workers: RS4GC is per-function (consults only callee
    // declaration attrs, preserved by the partition split), so statepointing
    // each partition in parallel is semantically identical to the whole-module
    // run, and the split then operates on statepoint-free IR. Each worker runs RS4GC BEFORE its
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
        // ECO_SPIKE_THUNK_FOLD=1|2: the diagnostic experiment of
        // spikeFoldThunks. 1 = calls to literal-bodied arity-0 thunks become
        // constants; 2 = closed scalar thunk bodies are constant-folded too.
        if (const char *e = ::getenv("ECO_SPIKE_THUNK_FOLD"))
            spikeFoldThunks(m, std::atoi(e));
        // No serial whole-module IPO under the parallel tiers (cgu, dev):
        // the front end folds constant thunks at every reference (CGEN_082)
        // and closed-world reachability already ran (CGEN_081), so IPSCCP and
        // GlobalDCE here would find little.
        if (!parallelOptEnabled && job.optLevel != CodeGenOptLevel::None &&
            job.tm) {
            MaybeScope s(job.stats, "  whole-module opt (serial)");
            if (auto err = runEcoModuleOpt(m, job.tm, job.optLevel))
                return err;
        }
        // Deferred RS4GC runs here — after opt, before object emission.
        if (deferRS4GC)
            runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

        // Decide the partition count here (the shared policy of
        // choosePartitionCount) rather than in each driver.
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
            // This SplitModule path is the fallback for a module that was
            // not already partitioned in MLIR by EcoSplit.
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
        // Under EcoSplit this is the partition worker's pipeline, and the
        // scopes record into the "(sum over workers)" stats rows.
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
        // JIT path: always run makeOptimizingTransformer at job.optLevel
        // (level 0 does little). `job.tm` may be null.
        //
        // `job` must stay alive for the whole call: a caller that reaches
        // this through a non-owning callable bound to a temporary reads a
        // dead `job` and passes a garbage opt level here. The Windows skip
        // below is kept until it has been tested on Windows.
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

