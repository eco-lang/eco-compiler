//===- StatepointConversion.cpp - Convert marker calls to gc.statepoint ---===//
//
// Converts __eco_safepoint_marker(ptr addrspace(1), ...) calls into
// llvm.experimental.gc.statepoint calls that wrap the ACTUAL allocating or
// calling function that follows the marker.
//
// Pattern in LLVM IR (before this pass):
//   call void @__eco_safepoint_marker(ptr addrspace(1) %root1, ...)
//   %result = call i64 @eco_alloc_custom(i32 4, i32 2, i32 0)
//
// Pattern after this pass:
//   %tok = gc.statepoint(@eco_alloc_custom, 4, 2, 0) [ "gc-live"(%root1, ...) ]
//   %result = gc.result(token %tok)
//   %root1.relocated = gc.relocate(token %tok, ...)
//
// This ensures the stack map entry is recorded at the return address of the
// actual allocating call (where GC can trigger), not at a separate nop call.
//
//===----------------------------------------------------------------------===//

#include "StatepointConversion.h"

#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
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

/// Find the first non-intrinsic CallInst after the given instruction
/// in the same basic block. This is the target call that the safepoint
/// marker was placed before.
static CallInst *findTargetCall(Instruction *after) {
    auto *BB = after->getParent();
    for (auto it = std::next(after->getIterator()); it != BB->end(); ++it) {
        if (auto *CI = dyn_cast<CallInst>(&*it)) {
            // Skip LLVM intrinsics (lifetime, dbg, etc.)
            if (CI->getIntrinsicID() != Intrinsic::not_intrinsic)
                continue;
            // Skip other safepoint markers
            if (CI->getCalledFunction() &&
                CI->getCalledFunction()->getName() == MARKER_NAME)
                continue;
            return CI;
        }
    }
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
    auto *statepointDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(ctx, 0)});

    // Get the gc.relocate intrinsic declaration
    auto *relocateDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_relocate,
        {PointerType::get(ctx, 1)});

    auto *i64Zero = ConstantInt::get(Type::getInt64Ty(ctx), 0);
    auto *i32Zero = ConstantInt::get(Type::getInt32Ty(ctx), 0);
    auto *i64Ty = Type::getInt64Ty(ctx);

    for (auto &[F, calls] : callsByFunction) {
        DominatorTree DT(*F);

        // Sort calls in forward program order.
        std::sort(calls.begin(), calls.end(), [&DT](CallInst *A, CallInst *B) {
            if (A->getParent() != B->getParent())
                return DT.dominates(A->getParent(), B->getParent());
            return A->comesBefore(B);
        });

        for (auto *markerCall : calls) {
            // Collect gc-live args and original i64 values from the marker
            SmallVector<Value*, 8> gcLiveArgs;
            SmallVector<Value*, 8> originalInts;
            for (unsigned i = 0; i < markerCall->arg_size(); i++) {
                Value *arg = markerCall->getArgOperand(i);
                gcLiveArgs.push_back(arg);
                Value *origInt = stripIntToPtr(arg);
                originalInts.push_back(origInt);
            }

            // Find the target call to wrap
            CallInst *targetCall = findTargetCall(markerCall);
            if (!targetCall) {
                // No target call found — just remove the marker
                markerCall->eraseFromParent();
                continue;
            }

            // Build statepoint wrapping the target call.
            // Format: gc.statepoint(id, patchBytes, callee, numCallArgs, flags, <callArgs...>)
            //         [ "gc-live"(<gc roots...>) ]
            FunctionType *targetFnTy = targetCall->getFunctionType();

            SmallVector<Value*, 16> statepointArgs;
            statepointArgs.push_back(i64Zero);  // statepoint ID
            statepointArgs.push_back(i32Zero);  // num patch bytes
            statepointArgs.push_back(targetCall->getCalledOperand());  // callee
            statepointArgs.push_back(
                ConstantInt::get(Type::getInt32Ty(ctx), targetCall->arg_size()));  // num call args
            statepointArgs.push_back(i32Zero);  // flags

            // Append the target call's arguments
            for (unsigned i = 0; i < targetCall->arg_size(); i++)
                statepointArgs.push_back(targetCall->getArgOperand(i));

            // Create gc-live operand bundle
            OperandBundleDef gcLiveBundle("gc-live", gcLiveArgs);

            // Insert statepoint before the target call
            IRBuilder<> builder(targetCall);
            auto *statepoint = builder.CreateCall(
                statepointDecl, statepointArgs, {gcLiveBundle});
            statepoint->setDebugLoc(targetCall->getDebugLoc());

            // Add elementtype attribute on the callee argument (arg index 2)
            statepoint->addParamAttr(2,
                Attribute::get(ctx, Attribute::ElementType, targetFnTy));

            // Copy calling convention from target
            statepoint->setCallingConv(targetCall->getCallingConv());

            // Extract the call result via gc.result if non-void
            if (!targetCall->getType()->isVoidTy()) {
                auto *gcResultDecl = Intrinsic::getOrInsertDeclaration(
                    &module, Intrinsic::experimental_gc_result,
                    {targetCall->getType()});
                builder.SetInsertPoint(statepoint->getNextNode()
                    ? statepoint->getNextNode()
                    : targetCall);
                auto *gcResult = builder.CreateCall(gcResultDecl, {statepoint});
                targetCall->replaceAllUsesWith(gcResult);
            }

            // Emit gc.relocate for gc-live values with post-statepoint uses (Option B).
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
                    // Skip the statepoint itself
                    if (userInst == statepoint)
                        continue;
                    // Skip the inttoptr that feeds into gc-live
                    if (userInst == gcLiveArgs[i])
                        continue;
                    // Only rewrite uses dominated by this statepoint
                    if (DT.dominates(statepoint, userInst))
                        allUsesToRewrite[i].push_back(&U);
                }
            }

            // Second pass: emit gc.relocate only for values with uses to rewrite.
            // Insert after the gc.result (if any) or after the statepoint.
            Instruction *insertAfter = statepoint;
            for (auto it = statepoint->getIterator();
                 it != statepoint->getParent()->end(); ++it) {
                if (auto *CI = dyn_cast<CallInst>(&*it)) {
                    if (CI->getIntrinsicID() == Intrinsic::experimental_gc_result) {
                        insertAfter = CI;
                        break;
                    }
                }
                if (&*it != statepoint)
                    break;
            }
            builder.SetInsertPoint(insertAfter->getNextNode());

            for (unsigned i = 0; i < originalInts.size(); i++) {
                if (allUsesToRewrite[i].empty())
                    continue;

                auto *idx = ConstantInt::get(Type::getInt32Ty(ctx), i);
                auto *relocate = builder.CreateCall(
                    relocateDecl, {statepoint, idx, idx});
                auto *relocated = builder.CreatePtrToInt(relocate, i64Ty);

                for (auto *U : allUsesToRewrite[i])
                    U->set(relocated);
            }

            // Remove the target call (replaced by statepoint + gc.result)
            targetCall->eraseFromParent();

            // Remove the marker call
            markerCall->eraseFromParent();
        }
    }

    // Remove the marker function declaration
    markerFn->eraseFromParent();

    assert(module.getFunction(MARKER_NAME) == nullptr &&
           "All safepoint markers must be converted to statepoints");

    return true;
}

void eco::removeDeadGCRelocates(Module &module) {
    auto *relocateDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_relocate,
        {PointerType::get(module.getContext(), 1)});
    if (!relocateDecl)
        return;

    // Remove dead gc.relocate + ptrtoint pairs.
    bool changed = true;
    while (changed) {
        changed = false;
        SmallVector<CallInst*, 16> toRemove;
        for (auto *user : relocateDecl->users()) {
            auto *relocCall = dyn_cast<CallInst>(user);
            if (!relocCall)
                continue;

            if (relocCall->hasOneUse()) {
                auto *singleUser = relocCall->user_back();
                if (auto *p2i = dyn_cast<PtrToIntInst>(singleUser)) {
                    if (p2i->use_empty())
                        toRemove.push_back(relocCall);
                }
            } else if (relocCall->use_empty()) {
                toRemove.push_back(relocCall);
            }
        }

        for (auto *relocCall : toRemove) {
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
    auto *statepointDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(module.getContext(), 0)});
    if (!statepointDecl)
        return;

    for (auto &F : module) {
        for (auto &BB : F) {
            SmallVector<CallInst*, 4> statepoints;
            for (auto &I : BB) {
                if (auto *CI = dyn_cast<CallInst>(&I)) {
                    if (CI->getCalledFunction() == statepointDecl)
                        statepoints.push_back(CI);
                }
            }

            if (statepoints.size() < 2)
                continue;

            for (unsigned si = 0; si < statepoints.size(); si++) {
                auto *sp = statepoints[si];
                Instruction *boundary = (si + 1 < statepoints.size())
                    ? cast<Instruction>(statepoints[si + 1])
                    : nullptr;

                SmallVector<CallInst*, 8> misplacedRelocates;
                bool pastBoundary = (boundary == nullptr);
                for (auto it = sp->getIterator(); it != BB.end(); ++it) {
                    if (&*it == boundary)
                        pastBoundary = true;
                    if (!pastBoundary)
                        continue;

                    if (auto *CI = dyn_cast<CallInst>(&*it)) {
                        if (CI->getCalledFunction() == relocateDecl &&
                            CI->getArgOperand(0) == sp)
                            misplacedRelocates.push_back(CI);
                    }
                }

                if (!misplacedRelocates.empty()) {
                    Instruction *insertPt = sp->getNextNode();
                    for (auto *reloc : misplacedRelocates)
                        reloc->moveBefore(insertPt->getIterator());
                }
            }
        }
    }
}
