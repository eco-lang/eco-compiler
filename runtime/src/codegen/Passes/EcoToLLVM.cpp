//===- EcoToLLVM.cpp - Eco dialect to LLVM dialect lowering ---------------===//
//
// The `eco-to-llvm` pass: it turns a module of `func.func` functions with Eco, scf, arith and cf bodies into the
// LLVM dialect. The rewrite patterns live in the other EcoToLLVM* files and are declared in EcoToLLVMInternal.h;
// this file decides the order they run in and which parts run in parallel.
//
// The order follows from one fact. Most of the work is converting function bodies, which are independent of each
// other, but a body pattern may need a module-level symbol (a runtime declaration, a string-literal global, a
// closure wrapper or descriptor, an eval layout). Creating symbols from several threads at once is not safe, so
// every such symbol is decided and inserted first, before any body is converted, and the shared `EcoRuntime` is
// then frozen: made read-only, so body patterns only look symbols up (`EcoRuntime::freeze` in
// EcoToLLVMInternal.h). The stages are:
//
//   1. A pre-scan records each function's original type and attributes, while the `func.func` ops still exist,
//      and `lowerAllocGroups` lowers allocation groups.
//   2. Stage 0 converts the function signatures and the module-level `eco.global` and `eco.type_table` ops. A
//      function becomes an `llvm.func` shell: its signature is converted and its body is moved unchanged, still in
//      the Eco dialects.
//   3. Pre-materialization creates every module-level symbol a body will need, then freezes `runtime`.
//   4. Stage 2 converts the bodies, in parallel chunks with a converter, target and pattern set per chunk.
//   5. An epilogue sorts the eval-layout globals, sets the `eco-gc` garbage collector on each definition that
//      exists by then and has none (so not on `__eco_init_globals`, which is created later), adds the CAF and
//      string-literal fast paths, installs shadow-root frames, creates `__eco_init_globals`, and erases
//      external declarations no op refers to.
//
// The names Stage 0 and Stage 2 are the ones the code and the stats labels use; there is no Stage 1.
//
// `ECO_ECO2LLVM_PARALLEL=0` makes Stage 0 and Stage 2 serial, and `ECO_PREMAT_PARALLEL=0` makes
// pre-materialization build everything in place; each is also serial when the context has multithreading off.
// `ECO_ECO2LLVM_STATS` set to any value prints the time spent in each stage to stderr.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "EcoSymbolGraph.h"
#include "EcoParallel.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../BF/BFOps.h"
#include "../../allocator/CharValue.hpp"
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

/**
 * A pattern that rebuilds an `arith.select` with its result type converted, for selects whose types still
 * contain `!eco.value`.
 */
struct SelectOpTypeConversion : public OpConversionPattern<arith::SelectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(arith::SelectOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        if (!resultType)
            return failure();

        rewriter.replaceOpWithNewOp<arith::SelectOp>(
            op, resultType, adaptor.getCondition(),
            adaptor.getTrueValue(), adaptor.getFalseValue());
        return success();
    }
};

/**
 * A pattern that rebuilds an `scf.index_switch` with converted result types, moving its case and default
 * regions into the new op. It does not match a switch whose result types are already converted.
 */
struct IndexSwitchOpTypeConversion : public OpConversionPattern<scf::IndexSwitchOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::IndexSwitchOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        SmallVector<Type> convertedTypes;
        if (failed(getTypeConverter()->convertTypes(op.getResultTypes(), convertedTypes)))
            return failure();

        if (convertedTypes == SmallVector<Type>(op.getResultTypes().begin(), op.getResultTypes().end()))
            return failure();

        auto loc = op.getLoc();

        // The original selector, not the adaptor's: scf.index_switch needs an `index` operand.
        auto newOp = rewriter.create<scf::IndexSwitchOp>(
            loc, convertedTypes, op.getArg(), op.getCases(), op.getCases().size());

        for (auto [oldRegion, newRegion] : llvm::zip(op.getCaseRegions(), newOp.getCaseRegions())) {
            rewriter.inlineRegionBefore(oldRegion, newRegion, newRegion.end());
        }

        rewriter.inlineRegionBefore(op.getDefaultRegion(), newOp.getDefaultRegion(),
                                    newOp.getDefaultRegion().end());

        rewriter.replaceOp(op, newOp.getResults());
        return success();
    }
};

/**
 * A pattern that rebuilds an `scf.yield` nested in an `scf.index_switch` with its converted operands. It does not
 * match a yield with no enclosing index_switch.
 */
struct YieldOpTypeConversion : public OpConversionPattern<scf::YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(scf::YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        if (!op->getParentOfType<scf::IndexSwitchOp>())
            return failure();

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
            // One post-order walk fills all three lists, so each list is in post-order.
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

/**
 * The `eco-to-llvm` module pass, whose stages the file comment describes. It is created by
 * `eco::createEcoToLLVMPass` and registered by `eco::registerEcoPasses`.
 */
struct EcoToLLVMPass : public PassWrapper<EcoToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoToLLVMPass)

    // Returns the pass's command-line name, `eco-to-llvm`.
    StringRef getArgument() const override { return "eco-to-llvm"; }

    // Returns the one-line description shown in pass listings.
    StringRef getDescription() const override {
        return "Lower Eco dialect to LLVM dialect";
    }

    // Adds the LLVM and func dialects, which the pass creates ops in, to `registry`.
    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect, func::FuncDialect>();
    }

    // Lowers the module in the stages the file comment lists. On the first stage that fails it signals pass
    // failure and returns, leaving the module partly converted.
    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = &getContext();

        // Stage timers for ECO_ECO2LLVM_STATS. Each ecoStageReport() prints the steady_clock time since the
        // previous report (or since here) and restarts the clock; with the variable unset it does nothing.
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


        // The converter for the serial conversions: serial Stage 0 and the serial pre-materialization. A type
        // converter's caches change as it converts, so it is never shared between threads; each parallel shard
        // and chunk makes its own.
        EcoTypeConverter typeConverter(ctx);

        // The shared runtime state for every stage. `cfCtx` is never used: each Stage 2 chunk makes its own
        // EcoCFContext.
        EcoRuntime runtime(module);
        EcoCFContext cfCtx;
        cfCtx.clear();

        // Chunked-list mode is on when `eco.list_chunks` is on the module or on any function (below). In it,
        // list head and tail projections must also handle chunk views.
        runtime.listChunks = module->hasAttr("eco.list_chunks");

        // Pre-scan, which must run before Stage 0 erases the func::FuncOps. The original types are kept because
        // wrapper creation needs to tell an Int parameter from an `!eco.value` one, and both become i64 once
        // converted; the shadow-root and CAF-memo sets drive the epilogue.
        llvm::DenseSet<llvm::StringRef> shadowRootFuncs;
        llvm::DenseSet<llvm::StringRef> cafMemoFuncs;
        // Only top-level func.func ops are scanned.
        for (func::FuncOp funcOp : module.getOps<func::FuncOp>()) {
            runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
            if (funcOp->hasAttr("eco.shadow_roots"))
                shadowRootFuncs.insert(funcOp.getSymName());
            if (funcOp->hasAttr("eco.caf_memo"))
                cafMemoFuncs.insert(funcOp.getSymName());
            if (funcOp->hasAttr("eco.list_chunks"))
                runtime.listChunks = true;
        }

        // The Char case-mapping build guard (KERN_008): a gc-leaf call to the empty
        // `CharValue::kBuildGuardSymbol` goes at the start of @main's body, so a runtime built with the other
        // ECO_CHAR_CASE_EXPANSION setting fails to link or resolve it.
        if (auto mainFn = module.lookupSymbol<func::FuncOp>("main")) {
            if (!mainFn.getBody().empty()) {
                OpBuilder gb(ctx);
                gb.setInsertionPointToStart(&mainFn.getBody().front());
                auto guardFn = runtime.getOrCreateFunc(
                    gb, Elm::CharValue::kBuildGuardSymbol,
                    LLVM::LLVMFunctionType::get(LLVM::LLVMVoidType::get(ctx), {}),
                    /*gcLeaf=*/true);
                gb.create<LLVM::CallOp>(mainFn.getLoc(), guardFn, ValueRange{});
            }
        }

        // In chunked-list mode, a call to the gc-leaf `eco_enable_list_chunks` goes at the start of @main's
        // body, if @main exists and has one, so the runtime switches to producing chunks. It is an llvm.call,
        // which every later stage leaves alone.
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

        // lowerAllocGroups walks the func::FuncOps, so it must run before Stage 0 erases them. Allocations not
        // in a group are left for the Stage 2 patterns.
        lowerAllocGroups(module, runtime);
        ecoStageReport("1. pre-scan + lowerAllocGroups");

        //===--------------------------------------------------------------===//
        // Stage 0: function signatures and module-level globals.
        //===--------------------------------------------------------------===//
        // Kernel declarations become external llvm.funcs; every other func.func becomes an llvm.func shell
        // whose body is moved unchanged; eco.global and eco.type_table become LLVM globals. Everything else,
        // including func.call, func.return and the global loads and stores, is kept legal here and converted in
        // Stage 2. The IR in between is not type-consistent; nothing verifies it before the pass ends.
        {
            auto buildSigTarget = [&](ConversionTarget &sigTarget) {
                sigTarget.addLegalDialect<LLVM::LLVMDialect>();
                sigTarget.addLegalOp<ModuleOp>();
                sigTarget.addLegalOp<UnrealizedConversionCastOp>();
                // Body dialects stay legal, so only the shells convert.
                sigTarget.addLegalDialect<EcoDialect>();
                sigTarget.addLegalDialect<scf::SCFDialect>();
                sigTarget.addLegalDialect<arith::ArithDialect>();
                sigTarget.addLegalDialect<cf::ControlFlowDialect>();
                // func.call and func.return use values made by Eco ops, so they convert with those ops in
                // Stage 2.
                sigTarget.addLegalDialect<func::FuncDialect>();
                sigTarget.addIllegalOp<func::FuncOp>();
                // These patterns replace and erase top-level ops, so they are converted serially.
                sigTarget.addIllegalOp<eco::GlobalOp>();
                sigTarget.addIllegalOp<eco::TypeTableOp>();
            };
            auto buildSigPatterns = [&](EcoTypeConverter &tc,
                                        RewritePatternSet &sigPatterns) {
                // Kernel declarations; their pattern outranks the shell pattern below.
                populateEcoFuncPatterns(tc, sigPatterns, runtime);
                // Other functions: converts the signature and entry block arguments, moves the body as it is,
                // and bridges the two with unrealized_conversion_casts.
                populateFuncToLLVMFuncOpConversionPattern(tc, sigPatterns);
                // The load and store global patterns in this set do nothing here, as their ops are legal.
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
                // The conversion driver visits every op of every body, so the shells are converted in shards.
                //  1. Serially, in place: the kernel declarations, whose pattern uses the symbol cache, and
                //     eco.global / eco.type_table, whose patterns insert into and look up in the module.
                //  2. Contiguous runs of top-level ops are moved into detached modules and converted in
                //     parallel, each with its own converter, target and patterns. Only shells are left to
                //     convert, and their pattern replaces the op without looking at the module.
                //  3. The shards are spliced back in their original order.
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

        // The kernel-declaration pattern looks symbols up during Stage 0, which fills the symbol cache with
        // the func::FuncOps Stage 0 then erased. Those pointers dangle, so the cache is cleared and refilled
        // from the converted module on the next lookup.
        runtime.symCache.clear();

        ecoStageReport("2. stage0 signature + module conversion");

        // Pre-materialization: every module-level symbol a Stage 2 pattern will look up is created here, so
        // Stage 2 can run with `runtime` frozen. bodyFuncs is taken first, so the functions created here, which
        // are already LLVM, are not converted again.
        SmallVector<LLVM::LLVMFuncOp> bodyFuncs;
        for (LLVM::LLVMFuncOp func : module.getOps<LLVM::LLVMFuncOp>())
            bodyFuncs.push_back(func);
        {
            OpBuilder preBuilder(ctx);
            // Every runtime declaration; the unused ones are erased at the end of the pass.
            runtime.materializeAllRuntimeDecls(preBuilder);
            ecoStageReport("2b.0 runtime decls");
            // The ops that need symbols are found in parallel; the symbols are created serially, in the order
            // of `demand`.
            std::vector<PreMatDemand> demand;
            collectPreMatDemand(ctx, bodyFuncs, demand);
            ecoStageReport("2b.1 demand collection");
            // With deferBodies, what to create, its name and its order are decided serially, and the building
            // is done afterwards in parallel. String-literal globals are placed now and their initializers are
            // queued in `bodies`; other top-level ops are queued in `topLog`. Those not yet built are built
            // detached, in parallel. All of them are then pushed to the module front in log order, which puts
            // them where building in place would have, and the ones logged with `cache` set are cached.
            // `runtime` is frozen while the jobs run, so a job that would create a symbol fails an assertion.
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
        // From here a symbol pre-materialization missed fails cacheSymbol's assertion when a pattern tries to
        // create it.
        runtime.freeze();
        ecoStageReport("2b. pre-materialization");

        //===--------------------------------------------------------------===//
        // Stage 2: per-function body conversion.
        //===--------------------------------------------------------------===//
        // convertChunk converts the bodies of `chunk`, stopping at the first failure. Each call makes its own
        // type converter, target, patterns and EcoCFContext, because the converter and the target cache state
        // as they work. The EcoCFContext holds only per-function entries, so one per chunk is enough. `runtime`
        // is shared and frozen, so the chunks only read it.
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

        // Body conversion is parallel unless ECO_ECO2LLVM_PARALLEL is exactly "0" or the context has
        // multithreading off.
        const char *parEnv = ::getenv("ECO_ECO2LLVM_PARALLEL");
        const bool forceSerial = parEnv && parEnv[0] == '0' && parEnv[1] == '\0';
        const bool runParallel = ctx->isMultithreadingEnabled() && !forceSerial;
        if (!runParallel) {
            if (failed(convertChunk(bodyFuncs))) {
                signalPassFailure();
                return;
            }
        } else {
            // Up to 8 chunks per thread of equal function count: function sizes vary widely, and
            // failableParallelForEach hands the chunks out as threads come free.
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

        // Unfrozen again: the epilogue creates symbols.
        runtime.frozen = false;

        // The `__eco_eval_layout_*` globals are moved, sorted by name, to just before the first top-level op
        // that is not one, so their order in the output does not depend on the order they were created in.
        // They are referred to only by name, so the move changes nothing else.
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

        // The epilogue over the function definitions. The string-literal slots, and eco_caf_promote when a
        // guard needs it, are created first and serially, because the per-function work below runs in
        // parallel and must not add to the module.
        llvm::StringSet<> strLitSlots;
        materializeStringLiteralSlots(module, strLitSlots);

        SmallVector<LLVM::LLVMFuncOp> epiFuncs;
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
            // CAF memoization guard. wantsCafGuard excludes shadow-root functions: the guard's early return on
            // a hit would skip the frame push that the frame's epilogues pop.
            if (wantsCafGuard(func)) {
                bool promoteDeclared = true; // declared above
                if (failed(installCafMemoGuard(func, promoteDeclared))) {
                    epiFailed = true;
                    return;
                }
            }
            // CAF caller-side fast path: skip the thunk call when its slot is already filled.
            if (!cafMemoFuncs.empty() && cafCallerFastEnabled()) {
                rewriteCafCallSitesFast(func, cafMemoFuncs);
            }
            // The same fast path for string literals, keyed on each literal's slot.
            rewriteStringLiteralCallSitesFast(func, strLitSlots);
        };
        eco::forEachChunk(ctx, epiFuncs.size(), [&](size_t lo, size_t hi) {
            for (size_t i = lo; i < hi; ++i)
                epilogue(epiFuncs[i]);
        });
        // Shadow-root frames may create runtime declarations, so they are installed serially after the
        // parallel part.
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

        createGlobalRootInitFunction(module, runtime);

        // Erases every external llvm.func that no op refers to. Pre-materialization declared every runtime
        // function, and this leaves only those that are used.
        {
            // The candidates are indexed, then chunks of the top-level ops are walked in parallel, each
            // setting a bit for every candidate an op refers to through symgraph::forEachSymbolRef. The walk
            // visits every op, so a use inside a nested symbol table is found too. forEachSymbolRef is used
            // rather than per-op symbol-use queries because it builds no attribute dictionary per op.
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
        // This report also covers the declaration erasure above.
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
