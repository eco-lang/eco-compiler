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

            // Step 1.4: Emit gc.relocate + ptrtoint after the statepoint
            builder.SetInsertPoint(statepoint->getNextNode());

            SmallVector<Value*, 8> relocatedInts;
            for (unsigned i = 0; i < originalInts.size(); i++) {
                auto *idx = ConstantInt::get(Type::getInt32Ty(ctx), i);

                // gc.relocate(token, baseIdx, derivedIdx) -> ptr addrspace(1)
                auto *relocate = builder.CreateCall(
                    relocateDecl, {statepoint, idx, idx});

                // ptrtoint ptr addrspace(1) -> i64
                auto *relocated = builder.CreatePtrToInt(relocate, i64Ty);
                relocatedInts.push_back(relocated);
            }

            // Step 1.5: Rewrite post-safepoint SSA uses
            for (unsigned i = 0; i < originalInts.size(); i++) {
                Value *origInt = originalInts[i];
                if (!origInt)
                    continue;  // pattern didn't match, skip

                Value *newInt = relocatedInts[i];

                // Collect uses to rewrite (can't modify use list while iterating)
                SmallVector<Use*, 16> usesToRewrite;
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
                    // Skip relocate/ptrtoint instructions we just created
                    if (userInst == newInt ||
                        (isa<CallInst>(userInst) && cast<CallInst>(userInst)->getCalledFunction() == relocateDecl &&
                         cast<CallInst>(userInst)->getArgOperand(0) == statepoint))
                        continue;
                    // Only rewrite uses dominated by this statepoint
                    if (DT.dominates(statepoint, userInst))
                        usesToRewrite.push_back(&U);
                }

                for (auto *U : usesToRewrite)
                    U->set(newInt);
            }

            // Step 1.6: Remove dead gc.relocate + ptrtoint pairs.
            // LLVM's SelectionDAG asserts that every gc.relocate in the same
            // block as its statepoint is visited during instruction selection.
            // Dead relocates (no uses after SSA rewriting) trigger this assert
            // at both -O0 (FastISel issue #56158) and -O2 (startNewStatepoint
            // sees pending relocates from a prior statepoint in the same block).
            for (unsigned i = 0; i < relocatedInts.size(); i++) {
                auto *ptrToInt = cast<Instruction>(relocatedInts[i]);
                // The ptrtoint's only operand is the gc.relocate call
                auto *relocate = cast<Instruction>(ptrToInt->getOperand(0));

                if (ptrToInt->use_empty()) {
                    ptrToInt->eraseFromParent();
                    // The gc.relocate may still be used if the ptrtoint was
                    // the only user. Check before erasing.
                    if (relocate->use_empty())
                        relocate->eraseFromParent();
                }
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
}
