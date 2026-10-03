//===- EcoToLLVM.cpp - Eco dialect to LLVM dialect lowering ---------------===//
//
// This file implements the combined pass for lowering Eco dialect operations
// to LLVM dialect. It orchestrates pattern modules from:
//   - EcoToLLVMTypes.cpp: Constants and string literals
//   - EcoToLLVMHeap.cpp: Box, unbox, allocate, construct, project
//   - EcoToLLVMClosures.cpp: Closure operations
//   - EcoToLLVMControlFlow.cpp: Case, joinpoint, jump, return
//   - EcoToLLVMArith.cpp: Arithmetic, comparisons, bitwise, type conversions
//   - EcoToLLVMGlobals.cpp: Global variable operations
//   - EcoToLLVMErrorDebug.cpp: Safepoint, debug, crash, expect
//   - EcoToLLVMFunc.cpp: Kernel function declarations
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "EcoSymbolGraph.h"
#include "EcoParallel.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../BF/BFOps.h"
#include "../Passes.h"

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "llvm/ADT/BitVector.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/SCF/Transforms/Patterns.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/IR/Threading.h"

#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>

using namespace mlir;
using namespace eco;
using namespace eco::detail;

//===----------------------------------------------------------------------===//
// Arith Type Conversion Patterns
//===----------------------------------------------------------------------===//

namespace {

/// Pattern to type-convert arith.select operations.
/// This is needed when scf.if is lowered to arith.select but the types
/// still contain eco.value.
struct SelectOpTypeConversion : public OpConversionPattern<arith::SelectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(arith::SelectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Get the converted result type
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (!resultType)
            return failure();

        // Create a new select with converted types
        rewriter.replaceOpWithNewOp<arith::SelectOp>(
            op, resultType, adaptor.getCondition(),
            adaptor.getTrueValue(), adaptor.getFalseValue());
        return success();
    }
};

/// Pattern to type-convert scf.index_switch operations.
/// This handles the case where scf.index_switch has eco.value result types.
struct IndexSwitchOpTypeConversion : public OpConversionPattern<scf::IndexSwitchOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::IndexSwitchOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Convert result types
        SmallVector<Type> convertedTypes;
        if (failed(getTypeConverter()->convertTypes(op.getResultTypes(), convertedTypes)))
            return failure();

        // If types are already converted, no work to do
        if (convertedTypes == SmallVector<Type>(op.getResultTypes().begin(), op.getResultTypes().end()))
            return failure();

        auto loc = op.getLoc();

        // Create new index_switch with converted result types
        // Note: Use original arg (not adaptor) because scf.index_switch requires index type
        auto newOp = rewriter.create<scf::IndexSwitchOp>(
            loc, convertedTypes, op.getArg(), op.getCases(), op.getCases().size());

        // Move the case regions from old op to new op
        for (auto [oldRegion, newRegion] : llvm::zip(op.getCaseRegions(), newOp.getCaseRegions())) {
            rewriter.inlineRegionBefore(oldRegion, newRegion, newRegion.end());
        }

        // Move the default region
        rewriter.inlineRegionBefore(op.getDefaultRegion(), newOp.getDefaultRegion(),
                                    newOp.getDefaultRegion().end());

        // Replace uses with converted results
        rewriter.replaceOp(op, newOp.getResults());
        return success();
    }
};

/// Pattern to type-convert scf.yield operations inside index_switch.
struct YieldOpTypeConversion : public OpConversionPattern<scf::YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // Only convert yields inside index_switch
        if (!op->getParentOfType<scf::IndexSwitchOp>())
            return failure();

        // If operands are already converted (through adaptor), just create new yield
        rewriter.replaceOpWithNewOp<scf::YieldOp>(op, adaptor.getOperands());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

void eco::detail::collectPreMatDemand(MLIRContext *ctx,
                                      llvm::ArrayRef<LLVM::LLVMFuncOp> funcs,
                                      std::vector<PreMatDemand> &out) {
    out.assign(funcs.size(), PreMatDemand{});
    eco::forEachChunk(ctx, funcs.size(), [&](size_t lo, size_t hi) {
        for (size_t i = lo; i < hi; ++i) {
            PreMatDemand &d = out[i];
            LLVM::LLVMFuncOp func = funcs[i];
            // ONE post-order walk: the order every former per-kind walk used.
            func.walk([&](Operation *op) {
                if (isa<StringLiteralOp>(op))
                    d.literals.push_back(op);
                else if (isa<CaseOp>(op))
                    d.cases.push_back(op);
                else if (isa<PapExtendOp, CallOp, PapCreateOp,
                             PapCreateGroupOp, AllocateClosureOp,
                             MakeClosureOp>(op))
                    d.closure.push_back(op);
            });
        }
    });
}

namespace {

struct EcoToLLVMPass : public PassWrapper<EcoToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoToLLVMPass)

    StringRef getArgument() const override { return "eco-to-llvm"; }

    StringRef getDescription() const override {
        return "Lower Eco dialect to LLVM dialect";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, func::FuncDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = &getContext();

        // Env-gated sub-phase timers (ECO_ECO2LLVM_STATS). Passes have no
        // LoweringStats handle, so time the five serial stages of this pass
        // with steady_clock and print to llvm::errs(). Each ecoStageReport()
        // call measures wall time since the previous report (or since here)
        // and then resets the clock. Zero overhead when the env var is unset.
        const bool ecoStatsEnabled = ::getenv("ECO_ECO2LLVM_STATS") != nullptr;
        auto ecoStageClock = std::chrono::steady_clock::now();
        auto ecoStageReport = [&](const char *stageName) {
            if (!ecoStatsEnabled) return;
            auto now = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(
                            now - ecoStageClock).count();
            llvm::errs() << "[eco-to-llvm] " << stageName << ": " << ms
                         << " ms\n";
            ecoStageClock = now;
        };


        // One EcoTypeConverter, reused SERIALLY across Stage 0 (module-level
        // signature + global lowering) and Stage 2 (per-function body
        // lowering). Sequential reuse is safe: the parked concurrency bug
        // (see EcoTailConversions.cpp) was about sharing an LLVMTypeConverter
        // across THREADS / pass-clones — its internal caches mutate during
        // conversion — not about reusing one converter across serial
        // applyFullConversion calls. Declared at function scope so it OUTLIVES
        // the Stage 2 FrozenRewritePatternSet, which captures it by reference.
        EcoTypeConverter typeConverter(ctx);

        // Runtime helper (module symbol cache, origFuncTypes, deterministic
        // string-literal counter) and control-flow lowering context. Both are
        // shared across Stage 0 and Stage 2 exactly as the single-conversion
        // path shared one instance across the whole module: the symbol cache
        // dedups getOrCreate* wrappers/decls created lazily during Stage 2, and
        // cfCtx threads control-flow state across all functions (cleared once,
        // not per function).
        EcoRuntime runtime(module);
        EcoCFContext cfCtx;
        cfCtx.clear();

        // Chunked-list mode (plans/chunked-list-representation.md §6): the
        // front-end stamps `eco.list_chunks` on @main (func attr; also
        // honoured as a module attr for hand-written tests) when
        // config.list.chunks is enabled; list head/tail projections must
        // then handle chunk views (out-of-line hybrid helpers). Absent the
        // marker, lowering is byte-identical to the pre-chunk world.
        runtime.listChunks = module->hasAttr("eco.list_chunks");

        // Pre-scan all func::FuncOps to save original types before conversion.
        // getOrCreateWrapper must distinguish primitive params (Int i64) from
        // !eco.value params (HPointer i64), but after conversion both become
        // LLVM i64 and the func::FuncOp is gone. Also collect functions marked
        // eco.shadow_roots for post-conversion shadow-root frame installation.
        // MUST run before Stage 0 (which erases every func::FuncOp).
        llvm::DenseSet<llvm::StringRef> shadowRootFuncs;
        llvm::DenseSet<llvm::StringRef> cafMemoFuncs;
        // func.func is top-level only: iterate the module body, not every op.
        for (func::FuncOp funcOp : module.getOps<func::FuncOp>()) {
            runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
            if (funcOp->hasAttr("eco.shadow_roots"))
                shadowRootFuncs.insert(funcOp.getSymName());
            if (funcOp->hasAttr("eco.caf_memo"))
                cafMemoFuncs.insert(funcOp.getSymName());
            // Chunked-list marker: the front-end stamps @main when
            // config.list.chunks is on (a func attr flows through text AND
            // bytecode, unlike a module attr).
            if (funcOp->hasAttr("eco.list_chunks"))
                runtime.listChunks = true;
        }

        // Chunked-list mode: inject `call @eco_enable_list_chunks()` at the
        // top of @main so kernel bulk builders switch to chunk production in
        // exactly the binaries whose compiled projections are chunk-aware
        // (plans/chunked-list-representation.md §6). Injected while @main is
        // still a func.func; the LLVM call is already target-legal and rides
        // through Stage 0/2 untouched.
        if (runtime.listChunks) {
            if (auto mainFn = module.lookupSymbol<func::FuncOp>("main")) {
                if (!mainFn.getBody().empty()) {
                    OpBuilder eb(ctx);
                    eb.setInsertionPointToStart(&mainFn.getBody().front());
                    auto enableFn = runtime.getOrCreateFunc(
                        eb, "eco_enable_list_chunks",
                        LLVM::LLVMFunctionType::get(
                            LLVM::LLVMVoidType::get(ctx), {}),
                        /*gcLeaf=*/true);
                    eb.create<LLVM::CallOp>(mainFn.getLoc(), enableFn,
                                            ValueRange{});
                }
            }
        }

        // Lower allocation groups (eco.gc_group_size > 1) into fast/slow/merge
        // CFG before ANY conversion. lowerAllocGroups walks
        // module.getOps<func::FuncOp>(), so it MUST run before Stage 0 erases
        // the func::FuncOps; group member ops are erased, remaining singleton
        // alloc ops are lowered by the Stage 2 body patterns.
        lowerAllocGroups(module, runtime);
        ecoStageReport("1. pre-scan + lowerAllocGroups");

        //===--------------------------------------------------------------===//
        // Stage 0 (serial): func SIGNATURE conversion + module-level lowering.
        //===--------------------------------------------------------------===//
        // At MODULE scope, convert: every func::FuncOp -> llvm.func (kernel
        // decls -> extern llvm.func via KernelFuncOpLowering; every other
        // func.func -> an llvm.func SHELL whose signature is type-converted but
        // whose body region is moved verbatim and left in the Eco/scf/arith/cf
        // dialects), plus the two module-level Eco globals (eco.global ->
        // llvm.mlir.global, eco.type_table -> llvm globals). Everything else
        // (bodies, func.call, func.return, eco.load_global/eco.store_global) is
        // DEFERRED (kept legal) to Stage 2. The resulting llvm.func-with-eco-
        // body IR is intentionally type-inconsistent, but nothing verifies it
        // between stages (applyFullConversion only checks target legality and
        // unreachable blocks; the pass verifier runs after the whole pass), and
        // Stage 2 finishes lowering every deferred op.
        {
            auto buildSigTarget = [&](ConversionTarget &sigTarget) {
                sigTarget.addLegalDialect<LLVM::LLVMDialect>();
                sigTarget.addLegalOp<ModuleOp>();
                sigTarget.addLegalOp<UnrealizedConversionCastOp>();
                // Bodies are deferred to Stage 2: keep their dialects legal so
                // the signature conversion converts only the func shell.
                sigTarget.addLegalDialect<EcoDialect>();
                sigTarget.addLegalDialect<scf::SCFDialect>();
                sigTarget.addLegalDialect<arith::ArithDialect>();
                sigTarget.addLegalDialect<cf::ControlFlowDialect>();
                // func.call / func.return are body ops (their operands are
                // produced and consumed by deferred eco ops); defer them so
                // the producer eco op and the call/return convert together in
                // Stage 2, exactly as in the single conversion. Only the
                // func.func SHELL converts now.
                sigTarget.addLegalDialect<func::FuncDialect>();
                sigTarget.addIllegalOp<func::FuncOp>();
                // Module-level Eco globals must lower serially at module scope
                // (top-level replaceOp/eraseOp). Body-level load/store globals
                // stay Eco-legal here and defer to Stage 2.
                sigTarget.addIllegalOp<eco::GlobalOp>();
                sigTarget.addIllegalOp<eco::TypeTableOp>();
            };
            auto buildSigPatterns = [&](EcoTypeConverter &tc,
                                        RewritePatternSet &sigPatterns) {
                // Kernel func.func -> extern llvm.func (benefit 10; MODULE
                // mutation). Higher benefit than the signature pattern so
                // kernel decls are handled here rather than shell-converted.
                populateEcoFuncPatterns(tc, sigPatterns, runtime);
                // Non-kernel func.func -> llvm.func SHELL (signature only).
                // This is the isolated FuncOpConversionPattern that the full
                // func-to-llvm set also carries; taken alone it moves the body
                // region verbatim and type-converts the entry block args,
                // bridging the still-Eco body with unrealized_conversion_cast
                // arg materializations.
                populateFuncToLLVMFuncOpConversionPattern(tc, sigPatterns);
                // GlobalOpLowering + TypeTableOpLowering fire (module level);
                // LoadGlobalOpLowering / StoreGlobalOpLowering are also added
                // but stay inert (their Eco ops are legal/deferred here).
                populateEcoGlobalPatterns(tc, sigPatterns);
            };

            const char *parEnv0 = ::getenv("ECO_ECO2LLVM_PARALLEL");
            const bool shardStage0 =
                ctx->isMultithreadingEnabled() &&
                !(parEnv0 && parEnv0[0] == '0' && parEnv0[1] == '\0');

            ConversionTarget sigTarget(*ctx);
            buildSigTarget(sigTarget);
            RewritePatternSet sigPatterns(ctx);
            buildSigPatterns(typeConverter, sigPatterns);
            FrozenRewritePatternSet sigFrozen(std::move(sigPatterns));

            if (!shardStage0) {
                if (failed(applyFullConversion(module, sigTarget, sigFrozen))) {
                    signalPassFailure();
                    return;
                }
            } else {
                // Plan 07 P8. The driver visits every op of every body
                // (~4.2M) to convert ~75k shells, serially. Shard it:
                //  1. Serially, in place and in module order: the kernel
                //     decls (the only pattern that reads/writes symCache)
                //     and eco.global / eco.type_table (module-level patterns
                //     that insert at module start / lookupSymbol).
                //  2. Move contiguous ranges of the top-level ops into
                //     detached scratch modules and convert each in parallel
                //     with its own converter/target/patterns. Only non-kernel
                //     func.func shells are illegal by then; their patterns
                //     replace the op in place and never look at the module.
                //  3. Splice the shards back in order.
                SmallVector<Operation *> serialOps;
                for (Operation &op : *module.getBody()) {
                    if (auto f = dyn_cast<func::FuncOp>(op)) {
                        if (f->hasAttr("is_kernel"))
                            serialOps.push_back(&op);
                    } else if (isa<eco::GlobalOp, eco::TypeTableOp>(op)) {
                        serialOps.push_back(&op);
                    }
                }
                if (!serialOps.empty() &&
                    failed(applyFullConversion(serialOps, sigTarget,
                                               sigFrozen))) {
                    signalPassFailure();
                    return;
                }

                auto &topOps = module.getBody()->getOperations();
                const size_t nTop = topOps.size();
                const size_t nShards = std::max<size_t>(
                    1, std::min<size_t>(8 * ctx->getNumThreads(), nTop / 64));
                SmallVector<OwningOpRef<ModuleOp>> shards;
                shards.reserve(nShards);
                for (size_t k = 0; k < nShards; ++k) {
                    size_t len = nTop * (k + 1) / nShards - nTop * k / nShards;
                    OwningOpRef<ModuleOp> shard = ModuleOp::create(module.getLoc());
                    auto first = topOps.begin();
                    auto last = std::next(first, len);
                    shard->getBody()->getOperations().splice(
                        shard->getBody()->end(), topOps, first, last);
                    shards.push_back(std::move(shard));
                }
                std::atomic<bool> shardFailed{false};
                mlir::parallelFor(ctx, 0, nShards, [&](size_t k) {
                    EcoTypeConverter tc(ctx);
                    ConversionTarget target(*ctx);
                    buildSigTarget(target);
                    RewritePatternSet patterns(ctx);
                    buildSigPatterns(tc, patterns);
                    if (failed(applyFullConversion(*shards[k], target,
                                                   std::move(patterns))))
                        shardFailed = true;
                });
                for (auto &shard : shards)
                    topOps.splice(topOps.end(),
                                  shard->getBody()->getOperations());
                if (shardFailed) {
                    signalPassFailure();
                    return;
                }
            }
        }

        // CRITICAL: Stage 0 op-REPLACED every func::FuncOp with an llvm.func
        // (the old op is erased). runtime.symCache was populated DURING Stage 0
        // (EcoToLLVMFunc's kernel-decl lowering calls runtime.lookupSymbol,
        // which triggers ensureSymCache over the then-mixed module), so every
        // cached func::FuncOp pointer now DANGLES. Clear it so Stage 2 rebuilds
        // the cache from the live all-llvm.func module on its first lookup —
        // otherwise getOrCreateWrapper's dyn_cast<LLVM::LLVMFuncOp> on a stale
        // pointer is UB and silently miscompiles closures (runtime SIGSEGV).
        runtime.symCache.clear();

        ecoStageReport("2. stage0 signature + module conversion");

        // ---- Phase 2 pre-materialization (Option B) ----
        // Eagerly create every module-level artifact a Stage 2 body pattern
        // would otherwise create on demand (runtime decls, string-literal +
        // string-case globals, closure wrappers, eval-layouts), so the symbol
        // table + artifact caches become READ-ONLY during body conversion (this
        // is what makes the body stage safe to run in parallel later). Snapshot
        // bodyFuncs BEFORE pre-mat so the wrappers/decls it creates are excluded
        // from body conversion (they are pure LLVM and need none). The walk
        // order == module program order + pre-order within each function.
        SmallVector<LLVM::LLVMFuncOp> bodyFuncs;
        for (LLVM::LLVMFuncOp func : module.getOps<LLVM::LLVMFuncOp>())
            bodyFuncs.push_back(func);
        {
            OpBuilder preBuilder(ctx);
            // Pre-declare ALL runtime helper externs so getOrCreateFunc hits a
            // read-only cache during parallel Stage 2 (unused ones are stripped
            // below so codegen CHECK-NOT fixtures still pass).
            runtime.materializeAllRuntimeDecls(preBuilder);
            ecoStageReport("2b.0 runtime decls");
            // Plan 07 P7: find every demand site in ONE parallel pass, then
            // create serially in the same order the four walks did.
            std::vector<PreMatDemand> demand;
            collectPreMatDemand(ctx, bodyFuncs, demand);
            ecoStageReport("2b.1 demand collection");
            // Plan 07 P11: build in parallel, insert in order. Every decision,
            // counter, name and dedup stays serial and in program order.
            //  - String literals: the global is placed now (a shell); its
            //    initializer is deferred (runtime.deferredBodies).
            //  - Closure artifacts (wrappers, `$sat` entries, descriptors,
            //    eval layouts): logged in creation order (runtime.topLog),
            //    built DETACHED in parallel, then push_front()ed in log order
            //    — the positions the eager creators gave them — and cached.
            // The jobs only READ the symbol cache, so it is frozen meanwhile
            // (a miss that would create a symbol trips cacheSymbol's assert).
            std::vector<std::function<void()>> bodies;
            std::vector<EcoRuntime::TopLevelEntry> topLog;
            const char *defEnv = ::getenv("ECO_PREMAT_PARALLEL");
            const bool deferBodies =
                ctx->isMultithreadingEnabled() &&
                !(defEnv && defEnv[0] == '0' && defEnv[1] == '\0');
            if (deferBodies) {
                runtime.deferredBodies = &bodies;
                runtime.topLog = &topLog;
            }
            preMaterializeStringLiterals(preBuilder, runtime, demand);
            ecoStageReport("2b.2 string literals");
            preMaterializeStringCases(preBuilder, runtime, demand);
            ecoStageReport("2b.3 string cases");
            preMaterializeClosureArtifacts(preBuilder, runtime, &typeConverter,
                                           demand);
            ecoStageReport("2b.4 closure artifacts (plan)");
            runtime.deferredBodies = nullptr;
            runtime.topLog = nullptr;
            if (!bodies.empty() || !topLog.empty()) {
                std::vector<Operation *> made(topLog.size());
                runtime.freeze();
                const size_t nb = bodies.size();
                eco::forEachChunk(ctx, nb + topLog.size(),
                                  [&](size_t lo, size_t hi) {
                    for (size_t i = lo; i < hi; ++i) {
                        if (i < nb) {
                            bodies[i]();
                            continue;
                        }
                        auto &e = topLog[i - nb];
                        made[i - nb] = e.op ? e.op : e.make();
                    }
                });
                runtime.frozen = false;
                Block *top = module.getBody();
                for (size_t i = 0; i < topLog.size(); ++i) {
                    top->push_front(made[i]);
                    if (topLog[i].cache)
                        runtime.cacheSymbol(made[i]);
                }
                runtime.pendingSymbols.clear();
            }
            ecoStageReport("2b.5 artifacts built (parallel) + inserted");
        }
        // Flip read-only: from here every getOrCreate*/wrapper/eval-layout/string
        // artifact MUST hit the cache; any create trips freeze()'s cacheSymbol
        // assert, pinpointing an artifact pre-materialization missed.
        runtime.freeze();
        ecoStageReport("2b. pre-materialization");

        //===--------------------------------------------------------------===//
        // Stage 2: per-function BODY conversion (lock-free parallel).
        //===--------------------------------------------------------------===//
        // Each chunk builds its OWN EcoTypeConverter + FrozenRewritePatternSet +
        // ConversionTarget + EcoCFContext (thread-local): the type converter
        // mutates internal caches during conversion and ConversionTarget lazily
        // caches legality, so neither may be shared across threads. `runtime` is
        // shared but READ-ONLY (symCache fully populated by freeze(); every
        // getOrCreate*/wrapper/eval-layout/string artifact hits the cache), so
        // concurrent DenseMap reads need no lock. cfCtx is keyed by
        // {parentFunc, jpId}; a per-chunk instance matches the legacy single
        // cfCtx exactly (entries never collide across functions). MLIRContext
        // attribute/type uniquing is thread-safe when multithreading is on.
        auto convertChunk =
            [&](llvm::ArrayRef<LLVM::LLVMFuncOp> chunk) -> LogicalResult {
            EcoTypeConverter tc(ctx);
            EcoCFContext cf;
            cf.clear();

            ConversionTarget bodyTarget(*ctx);
            bodyTarget.addLegalDialect<LLVM::LLVMDialect>();
            bodyTarget.addLegalDialect<cf::ControlFlowDialect>();
            bodyTarget.addLegalOp<ModuleOp>();
            bodyTarget.addLegalOp<UnrealizedConversionCastOp>();
            bodyTarget.addDynamicallyLegalDialect<arith::ArithDialect>(
                [](Operation *op) {
                    for (auto operand : op->getOperands())
                        if (isa<eco::ValueType>(operand.getType())) return false;
                    for (auto result : op->getResults())
                        if (isa<eco::ValueType>(result.getType())) return false;
                    return true;
                });
            bodyTarget.addDynamicallyLegalDialect<cf::ControlFlowDialect>(
                [](Operation *op) {
                    for (auto operand : op->getOperands())
                        if (isa<eco::ValueType>(operand.getType())) return false;
                    for (auto result : op->getResults())
                        if (isa<eco::ValueType>(result.getType())) return false;
                    if (auto branchOp = dyn_cast<BranchOpInterface>(op)) {
                        for (auto sIdx : llvm::seq<unsigned>(0, op->getNumSuccessors())) {
                            Block *successor = op->getSuccessor(sIdx);
                            for (auto arg : successor->getArguments())
                                if (isa<eco::ValueType>(arg.getType())) return false;
                        }
                    }
                    return true;
                });
            bodyTarget.addIllegalOp<func::FuncOp>();
            bodyTarget.addIllegalOp<func::CallOp>();
            bodyTarget.addIllegalOp<func::ReturnOp>();
            bodyTarget.addIllegalDialect<EcoDialect>();
            bodyTarget.addDynamicallyLegalOp<CaseOp>([](CaseOp op) {
                if (op->getParentOfType<scf::IfOp>() ||
                    op->getParentOfType<scf::IndexSwitchOp>() ||
                    op->getParentOfType<scf::WhileOp>())
                    return true;
                return false;
            });
            bodyTarget.addDynamicallyLegalOp<ReturnOp>([](ReturnOp op) {
                if (auto caseOp = op->getParentOfType<CaseOp>()) {
                    if (caseOp->getParentOfType<scf::IfOp>() ||
                        caseOp->getParentOfType<scf::IndexSwitchOp>() ||
                        caseOp->getParentOfType<scf::WhileOp>())
                        return true;
                }
                return false;
            });

            RewritePatternSet bodyPatterns(ctx);
            populateFuncToLLVMConversionPatterns(tc, bodyPatterns);
            populateCallOpTypeConversionPattern(bodyPatterns, tc);
            populateBranchOpInterfaceTypeConversionPattern(bodyPatterns, tc);
            scf::populateSCFStructuralTypeConversionsAndLegality(tc, bodyPatterns,
                                                                 bodyTarget);
            bodyTarget.addIllegalDialect<scf::SCFDialect>();
            bodyTarget.addDynamicallyLegalOp<scf::IndexSwitchOp>(
                [](scf::IndexSwitchOp op) {
                    for (Type t : op.getResultTypes())
                        if (isa<eco::ValueType>(t)) return false;
                    return true;
                });
            bodyTarget.addDynamicallyLegalOp<scf::YieldOp>([](scf::YieldOp op) {
                for (Value operand : op.getOperands())
                    if (isa<eco::ValueType>(operand.getType())) return false;
                return true;
            });
            populateSCFToControlFlowConversionPatterns(bodyPatterns);
            bodyPatterns.add<SelectOpTypeConversion>(tc, ctx);
            bodyPatterns.add<IndexSwitchOpTypeConversion>(tc, ctx);
            bodyPatterns.add<YieldOpTypeConversion>(tc, ctx);
            populateEcoTypePatterns(tc, bodyPatterns, runtime);
            populateEcoHeapPatterns(tc, bodyPatterns, runtime);
            populateEcoClosurePatterns(tc, bodyPatterns, runtime);
            populateEcoValueAggPatterns(tc, bodyPatterns, runtime);
            populateEcoControlFlowPatterns(tc, bodyPatterns, runtime, cf);
            populateEcoArithPatterns(tc, bodyPatterns);
            populateEcoArithPatternsWithRuntime(tc, bodyPatterns, runtime);
            populateEcoGlobalPatterns(tc, bodyPatterns);
            populateEcoErrorDebugPatterns(tc, bodyPatterns, runtime);
            FrozenRewritePatternSet bodyFrozen(std::move(bodyPatterns));

            for (LLVM::LLVMFuncOp func : chunk)
                if (failed(applyFullConversion(func, bodyTarget, bodyFrozen)))
                    return failure();
            return success();
        };

        // Per-function body conversion runs in PARALLEL by default. Validated
        // 2026-07-07: byte-reproducible IR (after the eval-layout ordering fix
        // above), full JIT E2E + GC-stress green, and the byte-exact native
        // bootstrap fixed-point (Stage 8c) holds under parallel. Force the
        // serial path with ECO_ECO2LLVM_PARALLEL=0 (determinism bisection /
        // debugging); it is also serial whenever the MLIRContext has
        // multithreading disabled (e.g. Win32 in eco-boot.cpp).
        const char *parEnv = ::getenv("ECO_ECO2LLVM_PARALLEL");
        const bool forceSerial = parEnv && parEnv[0] == '0' && parEnv[1] == '\0';
        const bool runParallel = ctx->isMultithreadingEnabled() && !forceSerial;
        if (!runParallel) {
            if (failed(convertChunk(bodyFuncs))) {
                signalPassFailure();
                return;
            }
        } else {
            // 8 chunks per thread (B4): function sizes vary widely, and with
            // one equal-COUNT chunk per thread the slowest chunk set the stage's
            // wall; failableParallelForEach hands chunks out dynamically.
            unsigned numChunks =
                std::max(1u, 8 * ctx->getThreadPool().getMaxConcurrency());
            numChunks = std::min<unsigned>(numChunks, (unsigned)bodyFuncs.size());
            SmallVector<llvm::ArrayRef<LLVM::LLVMFuncOp>> chunks;
            if (numChunks <= 1) {
                chunks.push_back(llvm::ArrayRef<LLVM::LLVMFuncOp>(bodyFuncs));
            } else {
                size_t base = bodyFuncs.size() / numChunks;
                size_t rem = bodyFuncs.size() % numChunks;
                size_t offset = 0;
                for (unsigned i = 0; i < numChunks; ++i) {
                    size_t len = base + (i < rem ? 1u : 0u);
                    chunks.push_back(
                        llvm::ArrayRef<LLVM::LLVMFuncOp>(bodyFuncs)
                            .slice(offset, len));
                    offset += len;
                }
            }
            if (failed(failableParallelForEach(ctx, chunks, convertChunk))) {
                signalPassFailure();
                return;
            }
        }
        ecoStageReport("3. stage2 per-function body conversion");

        // Re-enable module mutation for the SERIAL post-Stage-2 work
        // (shadow-root prologues + createGlobalRootInitFunction, which create
        // __eco_init_globals and may cacheSymbol).
        runtime.frozen = false;

        // Determinism: eval-layout globals are the ONE module artifact created
        // on demand (ensureEvalLayoutGlobal) instead of in a fixed serial order.
        // Their emission order tracks demand-DISCOVERY order — a StringAttr-keyed
        // dedup set + module-start insertion — which is pointer/hash dependent
        // (and, under ECO_ECO2LLVM_PARALLEL, thread-arrival dependent), so it
        // varies run-to-run in BOTH serial and parallel lowering. They are
        // semantically inert (referenced only by symbol name via AddressOfOp),
        // but the reordering makes eco-boot-native output non-byte-reproducible
        // and breaks the byte-exact native bootstrap fixed-point (Stage 8c).
        // Sort them into a canonical by-name block anchored before the first
        // non-layout op (whose relative order is already deterministic).
        {
            SmallVector<LLVM::GlobalOp> layouts;
            Operation *anchor = nullptr;
            for (Operation &op : *module.getBody()) {
                auto g = dyn_cast<LLVM::GlobalOp>(&op);
                if (g && g.getSymName().starts_with("__eco_eval_layout_"))
                    layouts.push_back(g);
                else if (!anchor)
                    anchor = &op;
            }
            if (anchor && !layouts.empty()) {
                llvm::sort(layouts, [](LLVM::GlobalOp a, LLVM::GlobalOp b) {
                    return a.getSymName() < b.getSymName();
                });
                for (LLVM::GlobalOp g : layouts)
                    g->moveBefore(anchor);
            }
        }

        // Single post-conversion walk over all LLVM functions: (1) set the GC
        // strategy so statepoint intrinsics are recognized, and (2) install
        // shadow-root frames for functions marked eco.shadow_roots. Fused from
        // two separate module.walk sweeps over the ~85k functions. The leading
        // external early-return covers both concerns exactly as before (walk 1
        // also gated on !isExternal; newly-created runtime decls are external
        // and were skipped by walk 2's guard too).
        // String-literal interning cache (step 18b): the slots and the two
        // cold-edge decls must exist before the per-function rewrite below
        // references them, and the module may not be mutated from inside the
        // walk. Deterministic: module order in, module order out.
        llvm::StringSet<> strLitSlots;
        materializeStringLiteralSlots(module, strLitSlots);

        // Plan 07 P6: the per-function work below is function-local except
        // the one lazily created eco_caf_promote decl. Create it up front —
        // at module END, right after the string-literal slots, exactly where
        // the first guard used to put it (nothing else appends in between),
        // with that first function's location — then run the functions in
        // parallel chunks. Shadow-root frames (only @main) may create runtime
        // decls on a cache miss, so they run serially afterwards.
        SmallVector<LLVM::LLVMFuncOp> epiFuncs;
        // Functions are top-level only: iterate the module body (same module
        // order as the post-order walk) instead of recursing through every op
        // (plans/backend-lowering-optimization.md B3a/B8).
        for (LLVM::LLVMFuncOp func : module.getOps<LLVM::LLVMFuncOp>())
            if (!func.isExternal())
                epiFuncs.push_back(func);
        auto wantsCafGuard = [&](LLVM::LLVMFuncOp func) {
            return !cafMemoFuncs.empty() &&
                   cafMemoFuncs.contains(func.getSymName()) &&
                   !shadowRootFuncs.contains(func.getSymName());
        };
        for (LLVM::LLVMFuncOp func : epiFuncs)
            if (wantsCafGuard(func)) {
                declareCafPromote(module, func.getLoc());
                break;
            }
        std::atomic<bool> epiFailed{false};
        auto epilogue = [&](LLVM::LLVMFuncOp func) {
            if (!func.getGarbageCollector())
                func.setGarbageCollector("eco-gc");
            // CAF memoization guard (plans/caf-memoization-implementation.md).
            // Shadow-root funcs (main) are skipped: the guard's hit-path early
            // return would bypass the frame push the epilogues balance. The
            // Elm side also strips the attr from main — belt and braces.
            if (wantsCafGuard(func)) {
                bool promoteDeclared = true; // declared above
                if (failed(installCafMemoGuard(func, promoteDeclared))) {
                    epiFailed = true;
                    return;
                }
            }
            // CAF caller-side fast path (Run W): elide the thunk call at
            // reference sites when the slot is already published.
            if (!cafMemoFuncs.empty() && cafCallerFastEnabled()) {
                rewriteCafCallSitesFast(func, cafMemoFuncs);
            }
            // Per-literal interning cache (step 18b): same diamond, keyed on
            // the literal's bytes global instead of a thunk symbol.
            rewriteStringLiteralCallSitesFast(func, strLitSlots);
        };
        eco::forEachChunk(ctx, epiFuncs.size(), [&](size_t lo, size_t hi) {
            for (size_t i = lo; i < hi; ++i)
                epilogue(epiFuncs[i]);
        });
        if (!shadowRootFuncs.empty()) {
            for (LLVM::LLVMFuncOp func : epiFuncs) {
                if (!shadowRootFuncs.contains(func.getSymName()))
                    continue;
                OpBuilder builder(func.getContext());
                auto frame = installShadowRootPrologue(func, builder, runtime);
                if (frame.basePtr) {
                    for (auto &entry : frame.slotForArg)
                        rewriteUsesViaShadowSlot(frame, entry.first, builder);
                    emitShadowRootEpilogues(frame, func, builder, runtime);
                }
            }
        }
        if (epiFailed) {
            signalPassFailure();
            return;
        }

        ecoStageReport("4. GC-strategy + shadow-root walks");

        // Generate global root initialization function
        createGlobalRootInitFunction(module, runtime);

        // Strip runtime-decl externs that no op ended up using. We pre-declare
        // ALL runtime helpers (materializeAllRuntimeDecls) so getOrCreateFunc is
        // a lock-free cache hit during parallel Stage 2; the unused ones would
        // otherwise linger until the backend's internalize+GlobalDCE and trip
        // codegen-fixture CHECK-NOT patterns that assert e.g. eco_alloc_tuple2
        // is absent. Erasing declaration-only, use-less external llvm.funcs here
        // restores the pre-parallelization symbol set exactly.
        {
            // Build the module's symbol-use map ONCE (O(module)); useEmpty is
            // then O(1) per decl. (SymbolTable::symbolKnownUseEmpty is O(module)
            // PER call — 135 pre-declared decls x an 85k-function module was
            // ~213s.)
            //
            // B3b (plans/backend-lowering-optimization.md): the same use
            // relation SymbolUserMap computes, collected IN PARALLEL over the
            // module's top-level ops (each op's own attributes plus every use
            // nested in its regions; the module is the only symbol table).
            // getSymbolUses materialises an attribute dictionary per op, which
            // made the serial map ~3 s at self-host scale. Falls back to the
            // serial map if any op hides its uses (unknown symbol table).
            //
            // Plan 07 P3: only the external declarations are candidates, so
            // index them first (a few hundred) and let each chunk set bits
            // for the candidates it references, found with
            // symgraph::forEachSymbolRef — the same references
            // getAttrDictionary()/getSymbolUses find, without uniquing a
            // dictionary per op (that serialized the chunks on the
            // context's uniquer lock). The walk visits every op, so no
            // symbol table can hide a use.
            llvm::DenseMap<StringAttr, unsigned> cand;
            SmallVector<LLVM::LLVMFuncOp> candFns;
            for (LLVM::LLVMFuncOp fn : module.getOps<LLVM::LLVMFuncOp>())
                if (fn.isExternal()) {
                    cand.try_emplace(fn.getSymNameAttr(), candFns.size());
                    candFns.push_back(fn);
                }
            SmallVector<Operation *> tops;
            for (Operation &op : *module.getBody())
                tops.push_back(&op);
            const size_t nChunks = std::max<size_t>(
                1, std::min<size_t>(tops.size(), 8 * ctx->getNumThreads()));
            SmallVector<llvm::BitVector> chunkUsed(
                nChunks, llvm::BitVector(candFns.size()));
            auto scan = [&](size_t c) {
                size_t lo = tops.size() * c / nChunks;
                size_t hi = tops.size() * (c + 1) / nChunks;
                auto &used = chunkUsed[c];
                for (size_t i = lo; i < hi; ++i)
                    tops[i]->walk([&](Operation *o) {
                        eco::symgraph::forEachSymbolRef(
                            o, [&](SymbolRefAttr ref, bool) {
                                auto it = cand.find(ref.getRootReference());
                                if (it != cand.end())
                                    used.set(it->second);
                            });
                    });
            };
            if (ctx->isMultithreadingEnabled())
                mlir::parallelFor(ctx, 0, nChunks, scan);
            else
                for (size_t c = 0; c < nChunks; ++c)
                    scan(c);
            llvm::BitVector used(candFns.size());
            for (auto &cu : chunkUsed)
                used |= cu;
            SmallVector<LLVM::LLVMFuncOp> deadDecls;
            for (size_t i = 0; i < candFns.size(); ++i)
                if (!used.test(i))
                    deadDecls.push_back(candFns[i]);
            for (LLVM::LLVMFuncOp fn : deadDecls)
                fn.erase();
        }
        ecoStageReport("5. createGlobalRootInitFunction");
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> eco::createEcoToLLVMPass() {
    return std::make_unique<EcoToLLVMPass>();
}

std::unique_ptr<TypeConverter> eco::createEcoToLLVMTypeConverter(MLIRContext *ctx) {
    return std::make_unique<EcoTypeConverter>(ctx);
}

void eco::registerEcoPasses() {
    PassRegistration<EcoToLLVMPass>();
}
