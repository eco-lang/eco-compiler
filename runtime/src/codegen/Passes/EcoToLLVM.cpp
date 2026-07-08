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
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../BF/BFOps.h"
#include "../Passes.h"

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
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

#include "llvm/Support/CommandLine.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>

using namespace mlir;
using namespace eco;
using namespace eco::detail;

// Plan P2 (HPointer deref inline fast paths). When enabled, heap-dereference
// lowering emits inline `__eco_resolve_fwd` marker calls + GEP + load which the
// ExpandInlineDeref LLVM pass later expands to an inline forwarding-check,
// instead of out-of-line eco_resolve_hptr / eco_*_get_* helper calls. Defaults
// ON (flip validated by the P3 GC-stress gate); `--inline-deref=false` restores
// the helper-call lowering.
llvm::cl::opt<bool> ecoInlineDeref(
    "inline-deref",
    llvm::cl::desc("Inline heap-dereference fast paths (plan P2) instead of "
                   "calling eco_resolve_hptr / eco_*_get_* helpers"),
    llvm::cl::init(true));

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
        runtime.inlineDeref = ecoInlineDeref;
        EcoCFContext cfCtx;
        cfCtx.clear();

        // Pre-scan all func::FuncOps to save original types before conversion.
        // getOrCreateWrapper must distinguish primitive params (Int i64) from
        // !eco.value params (HPointer i64), but after conversion both become
        // LLVM i64 and the func::FuncOp is gone. Also collect functions marked
        // eco.shadow_roots for post-conversion shadow-root frame installation.
        // MUST run before Stage 0 (which erases every func::FuncOp).
        llvm::DenseSet<llvm::StringRef> shadowRootFuncs;
        module.walk([&](func::FuncOp funcOp) {
            runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
            if (funcOp->hasAttr("eco.shadow_roots"))
                shadowRootFuncs.insert(funcOp.getSymName());
        });

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
            ConversionTarget sigTarget(*ctx);
            sigTarget.addLegalDialect<LLVM::LLVMDialect>();
            sigTarget.addLegalOp<ModuleOp>();
            sigTarget.addLegalOp<UnrealizedConversionCastOp>();
            // Bodies are deferred to Stage 2: keep their dialects legal so the
            // signature conversion converts only the func shell.
            sigTarget.addLegalDialect<EcoDialect>();
            sigTarget.addLegalDialect<scf::SCFDialect>();
            sigTarget.addLegalDialect<arith::ArithDialect>();
            sigTarget.addLegalDialect<cf::ControlFlowDialect>();
            // func.call / func.return are body ops (their operands are produced
            // and consumed by deferred eco ops); defer them so the producer eco
            // op and the call/return convert together in Stage 2, exactly as in
            // the single conversion. Only the func.func SHELL converts now.
            sigTarget.addLegalDialect<func::FuncDialect>();
            sigTarget.addIllegalOp<func::FuncOp>();
            // Module-level Eco globals must lower serially at module scope
            // (top-level replaceOp/eraseOp). Body-level load/store globals stay
            // Eco-legal here and defer to Stage 2.
            sigTarget.addIllegalOp<eco::GlobalOp>();
            sigTarget.addIllegalOp<eco::TypeTableOp>();

            RewritePatternSet sigPatterns(ctx);
            // Kernel func.func -> extern llvm.func (benefit 10; MODULE
            // mutation). Higher benefit than the signature pattern so kernel
            // decls are handled here rather than shell-converted.
            populateEcoFuncPatterns(typeConverter, sigPatterns, runtime);
            // Non-kernel func.func -> llvm.func SHELL (signature only). This is
            // the isolated FuncOpConversionPattern that the full func-to-llvm
            // set also carries; taken alone it moves the body region verbatim
            // and type-converts the entry block args, bridging the still-Eco
            // body with unrealized_conversion_cast arg materializations.
            populateFuncToLLVMFuncOpConversionPattern(typeConverter, sigPatterns);
            // GlobalOpLowering + TypeTableOpLowering fire (module level);
            // LoadGlobalOpLowering / StoreGlobalOpLowering are also added but
            // stay inert (their Eco ops are legal/deferred here).
            populateEcoGlobalPatterns(typeConverter, sigPatterns);

            if (failed(applyFullConversion(module, sigTarget,
                                           std::move(sigPatterns)))) {
                signalPassFailure();
                return;
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
            preMaterializeStringLiterals(preBuilder, runtime, bodyFuncs);
            preMaterializeStringCases(preBuilder, runtime, bodyFuncs);
            preMaterializeClosureArtifacts(preBuilder, runtime, &typeConverter,
                                           bodyFuncs);
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
            unsigned numChunks =
                std::max(1u, ctx->getThreadPool().getMaxConcurrency());
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
        module.walk([&](LLVM::LLVMFuncOp func) {
            if (func.isExternal())
                return;
            if (!func.getGarbageCollector())
                func.setGarbageCollector("eco-gc");
            if (!shadowRootFuncs.empty() &&
                shadowRootFuncs.contains(func.getSymName())) {
                OpBuilder builder(func.getContext());
                auto frame = installShadowRootPrologue(func, builder, runtime);
                if (frame.basePtr) {
                    for (auto &entry : frame.slotForArg)
                        rewriteUsesViaShadowSlot(frame, entry.first, builder);
                    emitShadowRootEpilogues(frame, func, builder, runtime);
                }
            }
        });

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
            SymbolTableCollection symbolTables;
            SymbolUserMap userMap(symbolTables, module.getOperation());
            SmallVector<LLVM::LLVMFuncOp> deadDecls;
            for (LLVM::LLVMFuncOp fn : module.getOps<LLVM::LLVMFuncOp>())
                if (fn.isExternal() && userMap.useEmpty(fn))
                    deadDecls.push_back(fn);
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
