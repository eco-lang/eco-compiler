//===- StatepointConversion.cpp - Convert marker calls to gc.statepoint ---===//
//
// Converts __eco_safepoint_marker(ptr addrspace(1), ...) calls into
// llvm.experimental.gc.statepoint calls with "gc-live" operand bundles,
// then emits gc.relocate intrinsics and rewrites post-safepoint SSA uses
// to reference the relocated pointers.
//
// The MLIR EcoToLLVM pass emits these marker calls because MLIR's LLVM
// dialect CallOp doesn't correctly handle the vararg + operand bundle +
// elementtype combination required by gc.statepoint. This pass runs on
// the raw LLVM IR after MLIR translation and uses LLVM's native API.
//
//===----------------------------------------------------------------------===//

#include "StatepointConversion.h"

#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Statepoint.h"

using namespace llvm;

static constexpr const char *MARKER_NAME = "__eco_safepoint_marker";

/// If value is an IntToPtrInst(i64 -> ptr addrspace(1)), return the i64
/// operand. SafepointOpLowering always emits this pattern for live roots.
static Value *stripIntToPtr(Value *V) {
    if (auto *I2P = dyn_cast<IntToPtrInst>(V))
        if (I2P->getSrcTy()->isIntegerTy(64))
            return I2P->getOperand(0);
    return nullptr;
}

bool eco::convertSafepointMarkers(Module &module) {
    auto *markerFn = module.getFunction(MARKER_NAME);
    if (!markerFn)
        return false;

    auto &ctx = module.getContext();

    // Group marker calls by function, preserving order within each function.
    DenseMap<Function*, SmallVector<CallInst*, 8>> callsByFunction;
    for (auto *user : markerFn->users()) {
        if (auto *call = dyn_cast<CallInst>(user))
            callsByFunction[call->getFunction()].push_back(call);
    }

    if (callsByFunction.empty()) {
        markerFn->eraseFromParent();
        return false;
    }

    // Get the statepoint intrinsic declaration
    // Signature: token(i64 id, i32 numPatchBytes, ptr callee, i32 numCallArgs, i32 flags, ...)
    auto *statepointDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(ctx, 0)});

    // Get the gc.relocate intrinsic declaration
    // Signature: ptr addrspace(1)(token, i32 baseIdx, i32 derivedIdx)
    auto *relocateDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_relocate,
        {PointerType::get(ctx, 1)});

    // Build the callee function type for the statepoint (void() for GC-only)
    auto *voidTy = Type::getVoidTy(ctx);
    auto *calleeFnTy = FunctionType::get(voidTy, /*isVarArg=*/false);

    // Create a real no-op callee function for the statepoint.
    // Using null causes LLVM to emit a call through null which segfaults.
    // This function is never actually called — the statepoint lowering
    // replaces it with a nop + stack map record.
    auto *nopCallee = Function::Create(
        calleeFnTy, GlobalValue::InternalLinkage,
        "__eco_gc_safepoint_nop", &module);
    {
        auto *entry = BasicBlock::Create(ctx, "entry", nopCallee);
        IRBuilder<> nopBuilder(entry);
        nopBuilder.CreateRetVoid();
    }

    // Constants for the statepoint call
    auto *i64Zero = ConstantInt::get(Type::getInt64Ty(ctx), 0);
    auto *i32Zero = ConstantInt::get(Type::getInt32Ty(ctx), 0);
    auto *i64Ty = Type::getInt64Ty(ctx);

    for (auto &[F, calls] : callsByFunction) {
        // Build DominatorTree once per function. It remains valid because
        // statepoint conversion replaces one CallInst with another in-place
        // and gc.relocate/ptrtoint are intra-BB additions.
        DominatorTree DT(*F);

        // Sort calls in forward program order: by basic block dominance,
        // then by instruction order within a block.
        std::sort(calls.begin(), calls.end(), [&DT](CallInst *A, CallInst *B) {
            if (A->getParent() != B->getParent())
                return DT.dominates(A->getParent(), B->getParent());
            return A->comesBefore(B);
        });

        for (auto *call : calls) {
            IRBuilder<> builder(call);

            // Step 1.3: Track original i64 values from inttoptr args
            SmallVector<Value*, 8> gcLiveArgs;
            SmallVector<Value*, 8> originalInts;
            for (unsigned i = 0; i < call->arg_size(); i++) {
                Value *arg = call->getArgOperand(i);
                gcLiveArgs.push_back(arg);
                Value *origInt = stripIntToPtr(arg);
                originalInts.push_back(origInt);  // may be nullptr if pattern doesn't match
            }

            // Build statepoint arguments:
            //   i64 id, i32 numPatchBytes, ptr callee, i32 numCallArgs, i32 flags
            SmallVector<Value*, 8> statepointArgs = {
                i64Zero,     // statepoint ID
                i32Zero,     // num patch bytes
                nopCallee,   // callee (nop function for GC-only safepoint)
                i32Zero,     // num call args
                i32Zero      // flags
            };

            // Create gc-live operand bundle with the GC root pointers
            OperandBundleDef gcLiveBundle("gc-live", gcLiveArgs);

            // Create the statepoint call
            auto *statepoint = builder.CreateCall(
                statepointDecl, statepointArgs, {gcLiveBundle});
            statepoint->setDebugLoc(call->getDebugLoc());

            // Add elementtype attribute on the callee argument (arg index 2)
            statepoint->addParamAttr(2,
                Attribute::get(ctx, Attribute::ElementType, calleeFnTy));

            // Step 1.4: Determine which gc-live values have post-statepoint uses,
            // then emit gc.relocate + ptrtoint ONLY for those values.
            // Emitting dead gc.relocate causes LLVM SelectionDAG assertion failures:
            // - At -O0: FastISel marks dead relocates as foldable and never visits them
            // - At -O2: optimizer can reorder a live relocate past a later statepoint,
            //   but dead relocates compound the problem by cluttering PendingGCRelocateCalls
            //
            // First pass: find which original i64 values have dominated uses to rewrite.
            SmallVector<SmallVector<Use*, 8>, 8> allUsesToRewrite(originalInts.size());
            for (unsigned i = 0; i < originalInts.size(); i++) {
                Value *origInt = originalInts[i];
                if (!origInt)
                    continue;

                for (auto &U : origInt->uses()) {
                    auto *userInst = dyn_cast<Instruction>(U.getUser());
                    if (!userInst)
                        continue;
                    if (userInst == statepoint)
                        continue;
                    if (userInst == gcLiveArgs[i])
                        continue;
                    if (DT.dominates(statepoint, userInst))
                        allUsesToRewrite[i].push_back(&U);
                }
            }

            // Second pass: emit gc.relocate only for values with uses to rewrite.
            builder.SetInsertPoint(statepoint->getNextNode());

            for (unsigned i = 0; i < originalInts.size(); i++) {
                if (allUsesToRewrite[i].empty())
                    continue;  // No post-statepoint uses — skip relocate entirely

                auto *idx = ConstantInt::get(Type::getInt32Ty(ctx), i);

                // gc.relocate(token, baseIdx, derivedIdx) -> ptr addrspace(1)
                auto *relocate = builder.CreateCall(
                    relocateDecl, {statepoint, idx, idx});

                // ptrtoint ptr addrspace(1) -> i64
                auto *relocated = builder.CreatePtrToInt(relocate, i64Ty);

                // Rewrite post-statepoint uses to the relocated value
                for (auto *U : allUsesToRewrite[i])
                    U->set(relocated);
            }

            // Remove the marker call
            call->eraseFromParent();
        }
    }

    // Remove the marker function declaration
    markerFn->eraseFromParent();

    assert(module.getFunction(MARKER_NAME) == nullptr &&
           "All safepoint markers must be converted to statepoints");

    return true;
}

void eco::removeDeadGCRelocates(Module &module) {
    auto *relocateDecl = Intrinsic::getDeclaration(
        &module, Intrinsic::experimental_gc_relocate,
        {PointerType::get(module.getContext(), 1)});
    if (!relocateDecl)
        return;

    // Iterate until no more dead relocates are found (removing one
    // can make others dead due to ptrtoint → inttoptr chains).
    bool changed = true;
    while (changed) {
        changed = false;
        SmallVector<CallInst*, 16> toRemove;
        for (auto *user : relocateDecl->users()) {
            auto *relocCall = dyn_cast<CallInst>(user);
            if (!relocCall)
                continue;

            // Check if the gc.relocate has only one user: a ptrtoint
            // whose result is also dead.
            if (relocCall->hasOneUse()) {
                auto *singleUser = relocCall->user_back();
                if (auto *p2i = dyn_cast<PtrToIntInst>(singleUser)) {
                    if (p2i->use_empty()) {
                        toRemove.push_back(relocCall);
                    }
                }
            } else if (relocCall->use_empty()) {
                toRemove.push_back(relocCall);
            }
        }

        for (auto *relocCall : toRemove) {
            // Remove the ptrtoint user first if it exists
            if (relocCall->hasOneUse()) {
                auto *p2i = cast<Instruction>(relocCall->user_back());
                p2i->eraseFromParent();
            }
            relocCall->eraseFromParent();
            changed = true;
        }
    }

    // Reorder gc.relocate instructions so they immediately follow their
    // statepoint, before any subsequent statepoint in the same block.
    // LLVM's optimizer can reorder gc.relocates past other statepoints
    // (no data dependency), but SelectionDAG's startNewStatepoint asserts
    // that all relocates from the prior statepoint have been visited.
    auto *statepointDecl = Intrinsic::getDeclaration(
        &module, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(module.getContext(), 0)});
    if (!statepointDecl)
        return;

    for (auto &F : module) {
        for (auto &BB : F) {
            // Collect statepoints in this block in order
            SmallVector<CallInst*, 4> statepoints;
            for (auto &I : BB) {
                if (auto *CI = dyn_cast<CallInst>(&I)) {
                    if (CI->getCalledFunction() == statepointDecl)
                        statepoints.push_back(CI);
                }
            }

            if (statepoints.size() < 2)
                continue;  // No reordering needed with 0 or 1 statepoints

            // For each statepoint, ensure all its gc.relocates are positioned
            // immediately after it (before the next statepoint).
            for (unsigned si = 0; si < statepoints.size(); si++) {
                auto *sp = statepoints[si];
                // Find the next statepoint (or end of block) as the boundary
                Instruction *boundary = (si + 1 < statepoints.size())
                    ? cast<Instruction>(statepoints[si + 1])
                    : nullptr;

                // Collect gc.relocates that reference this statepoint but
                // appear after the boundary (misplaced by optimizer)
                SmallVector<CallInst*, 8> misplacedRelocates;
                bool pastBoundary = (boundary == nullptr);
                for (auto it = sp->getIterator(); it != BB.end(); ++it) {
                    if (&*it == boundary)
                        pastBoundary = true;
                    if (!pastBoundary)
                        continue;

                    if (auto *CI = dyn_cast<CallInst>(&*it)) {
                        if (CI->getCalledFunction() == relocateDecl &&
                            CI->getArgOperand(0) == sp) {
                            misplacedRelocates.push_back(CI);
                        }
                    }
                }

                // Move misplaced relocates to just after the statepoint
                // (before any other statepoint in the block)
                if (!misplacedRelocates.empty()) {
                    Instruction *insertPt = sp->getNextNode();
                    for (auto *reloc : misplacedRelocates) {
                        reloc->moveBefore(insertPt);
                    }
                }
            }
        }
    }
}
