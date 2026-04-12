//===- StatepointConversion.cpp - Convert marker calls to gc.statepoint ---===//
//
// Two-phase conversion of __eco_safepoint_marker calls:
//
// Phase 1 (convertMarkersToStatepoints):
//   Replaces each marker + target call pair with gc.statepoint + gc.result.
//   Records SafepointInfo for Phase 2. No gc.relocate emission here.
//
// Phase 2 (rewriteGCRootsWithAllocas):
//   For each function with statepoints:
//   - Creates one alloca per unique GC root in the entry block.
//   - Stores the initial value into the alloca after its definition.
//   - For each statepoint, emits gc.relocate + ptrtoint and stores the
//     relocated value into the alloca.
//   - Rewrites ALL uses of each root (including gc-live operands) to loads
//     from the alloca.
//   - Runs PromoteMemToReg to convert allocas back to SSA with correct phis.
//
//===----------------------------------------------------------------------===//

#include "StatepointConversion.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Statepoint.h"
#include "llvm/Transforms/Utils/PromoteMemToReg.h"

using namespace llvm;

static constexpr const char *MARKER_NAME = "__eco_safepoint_marker";

namespace {

struct SafepointInfo {
    CallBase *Statepoint;
    SmallVector<Value *, 8> LiveRoots;      // original i64 values (stripped from inttoptr)
    SmallVector<unsigned, 8> LiveIndices;    // index of each root in the gc-live bundle
    SmallVector<Value *, 8> GCLivePtrArgs;  // the ptr addrspace(1) values in the gc-live bundle
};

} // anonymous namespace

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

/// Returns true if the type is a GC-managed type (i64 = HPointer representation).
static bool isGCManagedType(Type *T) {
    return T->isIntegerTy(64);
}

//===----------------------------------------------------------------------===//
// Phase 1: Convert markers to statepoints (no gc.relocate)
//===----------------------------------------------------------------------===//

static bool convertMarkersToStatepoints(
    Module &M,
    DenseMap<Function *, SmallVector<SafepointInfo, 4>> &OutMap) {

    auto *markerFn = M.getFunction(MARKER_NAME);
    if (!markerFn)
        return false;

    auto &ctx = M.getContext();

    // Group marker calls by function
    DenseMap<Function *, SmallVector<CallInst *, 8>> callsByFunction;
    for (auto *user : markerFn->users()) {
        if (auto *call = dyn_cast<CallInst>(user))
            callsByFunction[call->getFunction()].push_back(call);
    }

    if (callsByFunction.empty()) {
        markerFn->eraseFromParent();
        return false;
    }

    auto *statepointDecl = Intrinsic::getOrInsertDeclaration(
        &M, Intrinsic::experimental_gc_statepoint,
        {PointerType::get(ctx, 0)});

    auto *i64Zero = ConstantInt::get(Type::getInt64Ty(ctx), 0);
    auto *i32Zero = ConstantInt::get(Type::getInt32Ty(ctx), 0);

    for (auto &[F, calls] : callsByFunction) {
        // Sort calls in forward program order within each function.
        // Use block ordering + comesBefore within blocks.
        std::sort(calls.begin(), calls.end(), [](CallInst *A, CallInst *B) {
            if (A->getParent() != B->getParent()) {
                // Use block order in the function's block list
                for (auto &BB : *A->getFunction()) {
                    if (&BB == A->getParent()) return true;
                    if (&BB == B->getParent()) return false;
                }
                return false;
            }
            return A->comesBefore(B);
        });

        auto &spInfos = OutMap[F];

        for (auto *markerCall : calls) {
            // Collect gc-live args and original i64 values from the marker
            SmallVector<Value *, 8> gcLiveArgs;
            SmallVector<Value *, 8> originalInts;
            SmallVector<unsigned, 8> liveIndices;
            unsigned idx = 0;
            for (unsigned i = 0; i < markerCall->arg_size(); i++) {
                Value *arg = markerCall->getArgOperand(i);
                Value *origInt = stripIntToPtr(arg);
                gcLiveArgs.push_back(arg);
                originalInts.push_back(origInt);
                liveIndices.push_back(idx);
                idx++;
            }

            // Find the target call to wrap (safepoint poll or allocation slow path)
            CallInst *targetCall = findTargetCall(markerCall);
            if (!targetCall) {
                markerCall->eraseFromParent();
                continue;
            }

            // Accept __eco_safepoint_poll and any eco_alloc_* / eco_allocate allocation function
            auto *targetFn = targetCall->getCalledFunction();
            assert(targetFn && "Statepoint target must be a direct call");
            StringRef targetName = targetFn->getName();
            assert((targetName == "__eco_safepoint_poll" ||
                    targetName.starts_with("eco_alloc_") ||
                    targetName == "eco_allocate" ||
                    targetName == "eco_gc_alloc_region_fast" ||
                    targetName == "eco_gc_alloc_region_slow")
                   && "Statepoint target must be __eco_safepoint_poll or an allocation function");

            // Build statepoint wrapping the target call
            FunctionType *targetFnTy = targetCall->getFunctionType();

            SmallVector<Value *, 16> statepointArgs;
            statepointArgs.push_back(i64Zero);  // statepoint ID
            statepointArgs.push_back(i32Zero);  // num patch bytes
            statepointArgs.push_back(targetCall->getCalledOperand());  // callee
            statepointArgs.push_back(
                ConstantInt::get(Type::getInt32Ty(ctx), targetCall->arg_size()));
            statepointArgs.push_back(i32Zero);  // flags

            for (unsigned i = 0; i < targetCall->arg_size(); i++)
                statepointArgs.push_back(targetCall->getArgOperand(i));

            OperandBundleDef gcLiveBundle("gc-live", gcLiveArgs);

            IRBuilder<> builder(targetCall);
            auto *statepoint = builder.CreateCall(
                statepointDecl, statepointArgs, {gcLiveBundle});
            statepoint->setDebugLoc(targetCall->getDebugLoc());

            statepoint->addParamAttr(2,
                Attribute::get(ctx, Attribute::ElementType, targetFnTy));
            statepoint->setCallingConv(targetCall->getCallingConv());

            // Extract the call result via gc.result if non-void
            if (!targetCall->getType()->isVoidTy()) {
                auto *gcResultDecl = Intrinsic::getOrInsertDeclaration(
                    &M, Intrinsic::experimental_gc_result,
                    {targetCall->getType()});
                builder.SetInsertPoint(statepoint->getNextNode()
                    ? statepoint->getNextNode()
                    : targetCall);
                auto *gcResult = builder.CreateCall(gcResultDecl, {statepoint});
                targetCall->replaceAllUsesWith(gcResult);
            }

            // Record SafepointInfo for Phase 2
            SafepointInfo info;
            info.Statepoint = statepoint;
            info.GCLivePtrArgs = gcLiveArgs;
            for (unsigned i = 0; i < originalInts.size(); i++) {
                if (originalInts[i] && isGCManagedType(originalInts[i]->getType())) {
                    info.LiveRoots.push_back(originalInts[i]);
                    info.LiveIndices.push_back(liveIndices[i]);
                }
            }
            spInfos.push_back(std::move(info));

            targetCall->eraseFromParent();
            markerCall->eraseFromParent();
        }
    }

    markerFn->eraseFromParent();

    assert(M.getFunction(MARKER_NAME) == nullptr &&
           "All safepoint markers must be converted to statepoints");

    return true;
}

//===----------------------------------------------------------------------===//
// Phase 2: gc.relocate + alloca/mem2reg rewrite
//===----------------------------------------------------------------------===//

static bool rewriteGCRootsWithAllocas(
    Function &F,
    ArrayRef<SafepointInfo> Safepoints) {

    auto &ctx = F.getContext();
    auto *i64Ty = Type::getInt64Ty(ctx);

    auto *relocateDecl = Intrinsic::getOrInsertDeclaration(
        F.getParent(), Intrinsic::experimental_gc_relocate,
        {PointerType::get(ctx, 1)});

    // 4a. Collect all unique GC root values
    DenseSet<Value *> rootSet;
    SmallVector<Value *, 16> roots;
    for (auto &sp : Safepoints) {
        for (auto *root : sp.LiveRoots) {
            if (rootSet.insert(root).second)
                roots.push_back(root);
        }
    }

    if (roots.empty())
        return false;

    // 4b. Create one alloca per GC root in the entry block
    DenseMap<Value *, AllocaInst *> Allocas;
    SmallVector<AllocaInst *, 16> AllocaVec;
    IRBuilder<> entryBuilder(&F.getEntryBlock(), F.getEntryBlock().getFirstInsertionPt());

    for (auto *root : roots) {
        auto *alloca = entryBuilder.CreateAlloca(i64Ty, nullptr,
            root->getName() + ".gcroot");
        Allocas[root] = alloca;
        AllocaVec.push_back(alloca);
    }

    // 4c. Insert initial store for each root
    // Track which stores are "initial stores" so we skip them during use-rewriting
    DenseSet<StoreInst *> initialStores;
    for (auto *root : roots) {
        AllocaInst *alloca = Allocas[root];
        Instruction *insertPt = nullptr;

        if (isa<Argument>(root)) {
            // Store after all allocas in entry block
            insertPt = &*F.getEntryBlock().getFirstInsertionPt();
            // Skip past all allocas and dbg intrinsics
            while (insertPt && (isa<AllocaInst>(insertPt) || isa<DbgInfoIntrinsic>(insertPt)))
                insertPt = insertPt->getNextNode();
        } else if (auto *PHI = dyn_cast<PHINode>(root)) {
            insertPt = &*PHI->getParent()->getFirstNonPHIIt();
        } else if (auto *I = dyn_cast<Instruction>(root)) {
            insertPt = I->getNextNode();
            while (insertPt && isa<DbgInfoIntrinsic>(insertPt))
                insertPt = insertPt->getNextNode();
        }

        if (insertPt) {
            IRBuilder<> b(insertPt);
            auto *store = b.CreateStore(root, alloca);
            initialStores.insert(store);
        }
    }

    // 4d. For each statepoint: emit gc.relocate, then store into alloca
    for (auto &sp : Safepoints) {
        // Find insertion point after the statepoint (after gc.result if present)
        Instruction *insertAfter = cast<Instruction>(sp.Statepoint);
        for (auto it = insertAfter->getIterator();
             it != insertAfter->getParent()->end(); ++it) {
            if (auto *CI = dyn_cast<CallInst>(&*it)) {
                if (CI->getIntrinsicID() == Intrinsic::experimental_gc_result) {
                    insertAfter = CI;
                    break;
                }
            }
            if (&*it != insertAfter)
                break;
        }

        IRBuilder<> builder(insertAfter->getNextNode());

        for (unsigned i = 0; i < sp.LiveRoots.size(); i++) {
            auto *idx = ConstantInt::get(Type::getInt32Ty(ctx), sp.LiveIndices[i]);
            auto *relocate = builder.CreateCall(
                relocateDecl, {sp.Statepoint, idx, idx});
            auto *relocated = builder.CreatePtrToInt(relocate, i64Ty);
            builder.CreateStore(relocated, Allocas[sp.LiveRoots[i]]);
        }
    }

    // 4e. Rewrite ALL uses of each root V to loads from its alloca
    for (auto *root : roots) {
        AllocaInst *alloca = Allocas[root];

        // Collect uses first (modifying uses while iterating is unsafe)
        SmallVector<Use *, 32> usesToRewrite;
        for (auto &U : root->uses()) {
            auto *userInst = dyn_cast<Instruction>(U.getUser());
            if (!userInst)
                continue;

            // Skip the initial store we created in 4c
            if (auto *SI = dyn_cast<StoreInst>(userInst)) {
                if (SI->getValueOperand() == root &&
                    SI->getPointerOperand() == alloca &&
                    initialStores.count(SI))
                    continue;
            }

            usesToRewrite.push_back(&U);
        }

        for (auto *U : usesToRewrite) {
            auto *userInst = cast<Instruction>(U->getUser());

            // Insert load before the user instruction
            // For PHI nodes, insert at the end of the incoming block
            IRBuilder<> loadBuilder(userInst);
            if (auto *PHI = dyn_cast<PHINode>(userInst)) {
                unsigned opNo = U->getOperandNo();
                auto *incomingBB = PHI->getIncomingBlock(opNo);
                loadBuilder.SetInsertPoint(incomingBB->getTerminator());
            }

            auto *load = loadBuilder.CreateLoad(i64Ty, alloca, root->getName() + ".reload");

            // Check if this use is a gc-live bundle operand (expects ptr addrspace(1))
            // If so, we need inttoptr
            bool isGCLiveUse = false;
            if (auto *CB = dyn_cast<CallBase>(userInst)) {
                // Check if this use index falls within an operand bundle
                for (unsigned b = 0; b < CB->getNumOperandBundles(); b++) {
                    auto bundle = CB->getOperandBundleAt(b);
                    if (bundle.getTagName() == "gc-live") {
                        unsigned bundleStart = bundle.Inputs.data() - CB->op_begin();
                        unsigned bundleEnd = bundleStart + bundle.Inputs.size();
                        unsigned useIdx = U->getOperandNo();
                        if (useIdx >= bundleStart && useIdx < bundleEnd) {
                            isGCLiveUse = true;
                            break;
                        }
                    }
                }
            }

            if (isGCLiveUse) {
                auto *ptrVal = loadBuilder.CreateIntToPtr(load,
                    PointerType::get(ctx, 1));
                U->set(ptrVal);
            } else {
                U->set(load);
            }
        }
    }

    // 4f. Promote allocas back to SSA
    DominatorTree DT(F);
    PromoteMemToReg(AllocaVec, DT);

    return true;
}

//===----------------------------------------------------------------------===//
// Top-level entry point
//===----------------------------------------------------------------------===//

bool eco::convertSafepointMarkers(Module &module) {
    DenseMap<Function *, SmallVector<SafepointInfo, 4>> SPMap;
    bool Changed = convertMarkersToStatepoints(module, SPMap);
    if (!Changed)
        return false;

    for (auto &[F, SPs] : SPMap)
        rewriteGCRootsWithAllocas(*F, SPs);

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
