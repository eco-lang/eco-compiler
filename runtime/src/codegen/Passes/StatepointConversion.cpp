//===- StatepointConversion.cpp - Convert marker calls to gc.statepoint ---===//
//
// Converts __eco_safepoint_marker(ptr addrspace(1), ...) calls into
// llvm.experimental.gc.statepoint calls with "gc-live" operand bundles.
//
// The MLIR EcoToLLVM pass emits these marker calls because MLIR's LLVM
// dialect CallOp doesn't correctly handle the vararg + operand bundle +
// elementtype combination required by gc.statepoint. This pass runs on
// the raw LLVM IR after MLIR translation and uses LLVM's native API.
//
//===----------------------------------------------------------------------===//

#include "StatepointConversion.h"

#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Statepoint.h"

using namespace llvm;

static constexpr const char *MARKER_NAME = "__eco_safepoint_marker";

bool eco::convertSafepointMarkers(Module &module) {
    auto *markerFn = module.getFunction(MARKER_NAME);
    if (!markerFn)
        return false;

    auto &ctx = module.getContext();

    // Collect all calls to the marker (can't modify while iterating)
    SmallVector<CallInst*, 16> markerCalls;
    for (auto *user : markerFn->users()) {
        if (auto *call = dyn_cast<CallInst>(user))
            markerCalls.push_back(call);
    }

    if (markerCalls.empty()) {
        // Remove unused declaration
        markerFn->eraseFromParent();
        return false;
    }

    // Get the statepoint intrinsic declaration
    // Signature: token(i64 id, i32 numPatchBytes, ptr callee, i32 numCallArgs, i32 flags, ...)
    auto *statepointDecl = Intrinsic::getOrInsertDeclaration(
        &module, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(ctx, 0)});

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

    for (auto *call : markerCalls) {
        IRBuilder<> builder(call);

        // Collect GC root pointers from marker call arguments
        SmallVector<Value*, 4> gcLiveArgs;
        for (unsigned i = 0; i < call->arg_size(); i++) {
            gcLiveArgs.push_back(call->getArgOperand(i));
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
        // to satisfy LLVM's statepoint verifier.
        statepoint->addParamAttr(2,
            Attribute::get(ctx, Attribute::ElementType, calleeFnTy));

        // Remove the marker call
        call->eraseFromParent();
    }

    // Remove the marker function declaration
    markerFn->eraseFromParent();
    return true;
}
