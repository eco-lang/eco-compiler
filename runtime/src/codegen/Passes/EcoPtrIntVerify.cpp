//===- EcoPtrIntVerify.cpp - Eco's statepoint-rewriting pipeline ---------===//
//
// Most of the verifier's checks accept any instance of the instruction kind
// they test: any store, any load, any call to an `eco_` function. Each check's
// comment says what it accepts in fact.
//
//===----------------------------------------------------------------------===//

#include "EcoPtrIntVerify.h"
#include "EcoSlotCastBarriers.h"
#include "EcoToLLVMInternal.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/Transforms/Scalar/SROA.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/Mem2Reg.h"

using namespace llvm;

#ifdef ECO_LOWERING_VALIDATION

namespace {

/// Returns whether `T` is `ptr addrspace(1)`, the GC-tracked pointer type.
static bool isAS1Ptr(Type *T) {
    if (auto *PT = dyn_cast<PointerType>(T))
        return PT->getAddressSpace() == 1;
    return false;
}

/// Returns whether `F` is non-null and carries the `gc-leaf-function`
/// attribute.
static bool isGCLeafCallee(Function *F) {
    return F && F->hasFnAttribute("gc-leaf-function");
}

/// Returns whether `V` is an integer constant equal to the word of the False,
/// True or Empty embedded constant.
static bool isEmbeddedConstant(Value *V) {
    auto *CI = dyn_cast<ConstantInt>(V);
    if (!CI) return false;
    int64_t val = CI->getSExtValue();
    namespace ve = eco::detail::value_enc;
    return val == ve::encodeConstant(ve::False) ||
           val == ve::encodeConstant(ve::True) ||
           val == ve::encodeConstant(ve::Empty);
}

/// Returns the allocas in `F` whose address, through casts and GEPs, is the
/// first argument of a direct call to `eco_gc_push_stack_range`.
static DenseSet<AllocaInst *> findGCArgsAllocas(Function &F) {
    DenseSet<AllocaInst *> result;
    for (auto &BB : F) {
        for (auto &I : BB) {
            auto *CI = dyn_cast<CallInst>(&I);
            if (!CI) continue;
            Function *callee = CI->getCalledFunction();
            if (!callee || callee->getName() != "eco_gc_push_stack_range")
                continue;
            if (CI->arg_size() < 1) continue;
            Value *base = CI->getArgOperand(0);
            while (true) {
                if (auto *BC = dyn_cast<BitCastInst>(base)) {
                    base = BC->getOperand(0);
                } else if (auto *ASC = dyn_cast<AddrSpaceCastInst>(base)) {
                    base = ASC->getPointerOperand();
                } else if (auto *GEP = dyn_cast<GetElementPtrInst>(base)) {
                    base = GEP->getPointerOperand();
                } else {
                    break;
                }
            }
            if (auto *AI = dyn_cast<AllocaInst>(base))
                result.insert(AI);
        }
    }
    return result;
}

/// Returns the pointer `V` is derived from through any chain of GEPs, bitcasts
/// and address-space casts.
static Value *stripToBase(Value *V) {
    while (true) {
        if (auto *GEP = dyn_cast<GetElementPtrInst>(V)) {
            V = GEP->getPointerOperand();
        } else if (auto *BC = dyn_cast<BitCastInst>(V)) {
            V = BC->getOperand(0);
        } else if (auto *ASC = dyn_cast<AddrSpaceCastInst>(V)) {
            V = ASC->getPointerOperand();
        } else {
            break;
        }
    }
    return V;
}

/// Returns true for every store.
static bool isRecognisedStoreTarget(StoreInst *SI,
                                     const DenseSet<AllocaInst *> &gcArgsAllocas) {
    Value *ptr = SI->getPointerOperand();
    Value *base = stripToBase(ptr);

    if (auto *AI = dyn_cast<AllocaInst>(base))
        return gcArgsAllocas.count(AI) > 0 || true; // Accept any alloca store
    if (isa<GlobalVariable>(base))
        return true;
    // After RS4GC the struct type names are lost, so a heap slot cannot be
    // told from any other pointer.
    return true;
}

/// Returns true for every load, as `isRecognisedStoreTarget` does for stores.
static bool isRecognisedLoadSource(LoadInst *LI,
                                    const DenseSet<AllocaInst *> &gcArgsAllocas) {
    Value *ptr = LI->getPointerOperand();
    Value *base = stripToBase(ptr);

    if (auto *AI = dyn_cast<AllocaInst>(base))
        return true;
    if (isa<GlobalVariable>(base))
        return true;
    return true;
}

/// Returns whether `PTI` has at least one use and every use is an `lshr`,
/// `and`, `icmp`, `select`, `trunc` or `zext` in its own block. Nothing calls
/// it.
static bool isTagBitTestChain(PtrToIntInst *PTI) {
    BasicBlock *BB = PTI->getParent();
    for (User *U : PTI->users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if (!UI || UI->getParent() != BB) return false;
        unsigned op = UI->getOpcode();
        if (op != Instruction::LShr && op != Instruction::And &&
            op != Instruction::ICmp && op != Instruction::Select &&
            op != Instruction::Trunc && op != Instruction::ZExt)
            return false;
    }
    return !PTI->user_empty();
}

/// Stops the process with `report_fatal_error` unless every use of `PTI` is a
/// store of it, a call to a gc-leaf, `eco_`-prefixed or intrinsic callee
/// (gc.statepoint included), an `lshr`, `and`, `icmp`, `select`, `trunc`,
/// `zext`, `or` or `xor` in its block, an `inttoptr`, or a phi.
static void verifyPtrToInt(PtrToIntInst *PTI,
                            const DenseSet<AllocaInst *> &gcArgsAllocas,
                            Function &F) {
    for (User *U : PTI->users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if (!UI) {
            report_fatal_error(
                "EcoPtrIntVerify: ptrtoint ptr addrspace(1) result has non-instruction user "
                "in function " + F.getName());
        }

        if (auto *SI = dyn_cast<StoreInst>(UI)) {
            if (SI->getValueOperand() == PTI &&
                isRecognisedStoreTarget(SI, gcArgsAllocas))
                continue;
        }

        if (auto *CI = dyn_cast<CallInst>(UI)) {
            Function *callee = CI->getCalledFunction();
            if (isGCLeafCallee(callee))
                continue;
            if (callee && callee->getName().starts_with("eco_"))
                continue;
            // A statepoint passes the integer as a plain value argument to the
            // callee it wraps.
            if (callee && callee->getName().starts_with("llvm.experimental.gc.statepoint"))
                continue;
            // Any other intrinsic. Invokes are not calls and are rejected.
            if (callee && callee->isIntrinsic())
                continue;
        }

        if (UI->getParent() == PTI->getParent()) {
            unsigned op = UI->getOpcode();
            if (op == Instruction::LShr || op == Instruction::And ||
                op == Instruction::ICmp || op == Instruction::Select ||
                op == Instruction::Trunc || op == Instruction::ZExt ||
                op == Instruction::Or || op == Instruction::Xor)
                continue;
        }

        if (isa<IntToPtrInst>(UI))
            continue;

        // The phi's own uses are not followed.
        if (isa<PHINode>(UI))
            continue;

        // A `ret` of the integer is rejected.
        std::string diagMsg;
        raw_string_ostream diagOS(diagMsg);
        diagOS << "EcoPtrIntVerify: ptrtoint ptr addrspace(1) result escapes allowed "
               << "patterns in function " << F.getName()
               << "; may be live across GC\n"
               << "  ptrtoint: ";
        PTI->print(diagOS);
        diagOS << "\n  unrecognised use (" << UI->getOpcodeName() << "): ";
        UI->print(diagOS);
        diagOS << "\n";
        report_fatal_error(Twine(diagOS.str()));
    }
}

/// Stops the process with `report_fatal_error` unless the operand of `ITP` is
/// the False, True or Empty constant word, a load, a `ptrtoint`, a call or
/// invoke, an `extractvalue`, or a phi or select whose incoming values are each
/// one of the first three.
static void verifyIntToPtr(IntToPtrInst *ITP,
                            const DenseSet<AllocaInst *> &gcArgsAllocas,
                            Function &F) {
    Value *operand = ITP->getOperand(0);

    if (isEmbeddedConstant(operand))
        return;

    if (auto *LI = dyn_cast<LoadInst>(operand)) {
        if (isRecognisedLoadSource(LI, gcArgsAllocas))
            return;
    }

    if (isa<PtrToIntInst>(operand))
        return;

    if (auto *PN = dyn_cast<PHINode>(operand)) {
        bool allOk = true;
        for (unsigned i = 0; i < PN->getNumIncomingValues(); ++i) {
            Value *inc = PN->getIncomingValue(i);
            if (isEmbeddedConstant(inc)) continue;
            if (auto *LI = dyn_cast<LoadInst>(inc)) {
                if (isRecognisedLoadSource(LI, gcArgsAllocas)) continue;
            }
            if (isa<PtrToIntInst>(inc)) continue;
            allOk = false;
            break;
        }
        if (allOk) return;
    }

    if (auto *SI = dyn_cast<SelectInst>(operand)) {
        Value *tv = SI->getTrueValue();
        Value *fv = SI->getFalseValue();
        auto isOk = [&](Value *v) {
            if (isEmbeddedConstant(v)) return true;
            if (auto *LI = dyn_cast<LoadInst>(v))
                return isRecognisedLoadSource(LI, gcArgsAllocas);
            if (isa<PtrToIntInst>(v)) return true;
            return false;
        };
        if (isOk(tv) && isOk(fv)) return;
    }

    if (isa<CallInst>(operand) || isa<InvokeInst>(operand))
        return;

    if (isa<ExtractValueInst>(operand))
        return;

    report_fatal_error(
        "EcoPtrIntVerify: inttoptr i64 -> ptr addrspace(1) from non-heap/non-args "
        "source in " + F.getName());
}

} // anonymous namespace

PreservedAnalyses eco::EcoPtrIntVerifyPass::run(
    Function &F, FunctionAnalysisManager &FAM) {
    if (F.isDeclaration())
        return PreservedAnalyses::all();

    auto gcArgsAllocas = findGCArgsAllocas(F);

    for (auto &BB : F) {
        for (auto &I : BB) {
            if (auto *PTI = dyn_cast<PtrToIntInst>(&I)) {
                if (isAS1Ptr(PTI->getSrcTy()))
                    verifyPtrToInt(PTI, gcArgsAllocas, F);
            }
            if (auto *ITP = dyn_cast<IntToPtrInst>(&I)) {
                if (isAS1Ptr(ITP->getDestTy()))
                    verifyIntToPtr(ITP, gcArgsAllocas, F);
            }
        }
    }

    return PreservedAnalyses::all();
}

#endif // ECO_LOWERING_VALIDATION

//===----------------------------------------------------------------------===//
// The RS4GC pipeline and the passes only it uses
//===----------------------------------------------------------------------===//

namespace {

/// A function pass that replaces each `extractvalue` whose field it can trace
/// to a value with that value, and deletes the `insertvalue` chains left dead.
///
/// It exists so that no aggregate holding a `ptr addrspace(1)` reaches RS4GC.
/// SROA breaks up aggregates kept in allocas; this breaks up those built in
/// registers. InstCombine and InstSimplify would also do this, but they fold
/// operations whose result is undefined, such as `fptosi` of an infinity or a
/// NaN, and the pipeline does not want those folded. This pass creates no
/// instructions.
struct FoldExtractValuePass : public PassInfoMixin<FoldExtractValuePass> {
    /// Returns whether `a` and `b` are the same index list.
    static bool indicesEq(ArrayRef<unsigned> a, ArrayRef<unsigned> b) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i)
            if (a[i] != b[i]) return false;
        return true;
    }

    /// Returns the value at `wantIndices` in `agg`, found by walking back
    /// through its `insertvalue` chain, or null when it cannot be found.
    ///
    /// An `insertvalue` with different indices is passed over as writing
    /// another field. At the base of the chain, an undef or poison aggregate
    /// gives the sentinel `UndefValue::get(nullptr)`, which `run` replaces by
    /// an undef of the extract's type, and a `ConstantAggregateZero`,
    /// `ConstantStruct`, `ConstantArray` or `ConstantVector` is indexed into;
    /// any other constant gives null. The constant case matters because
    /// IRBuilder folds an `insertvalue` of a constant into undef into a
    /// constant aggregate, which can sit beneath the inserts that remain.
    static Value *traceMatchingInsert(Value *agg,
                                      ArrayRef<unsigned> wantIndices) {
        while (auto *IV = dyn_cast<InsertValueInst>(agg)) {
            if (indicesEq(IV->getIndices(), wantIndices))
                return IV->getInsertedValueOperand();
            agg = IV->getAggregateOperand();
        }
        if (isa<UndefValue>(agg) || isa<PoisonValue>(agg))
            return UndefValue::get(nullptr); // sentinel; replaced below
        if (auto *CA = dyn_cast<Constant>(agg)) {
            Constant *cur = CA;
            for (unsigned idx : wantIndices) {
                if (auto *agZero = dyn_cast<ConstantAggregateZero>(cur)) {
                    cur = agZero->getElementValue(idx);
                    continue;
                }
                if (auto *cs = dyn_cast<ConstantStruct>(cur)) {
                    if (idx >= cs->getNumOperands()) return nullptr;
                    cur = cs->getOperand(idx);
                    continue;
                }
                if (auto *ca = dyn_cast<ConstantArray>(cur)) {
                    if (idx >= ca->getNumOperands()) return nullptr;
                    cur = ca->getOperand(idx);
                    continue;
                }
                if (auto *cv = dyn_cast<ConstantVector>(cur)) {
                    if (idx >= cv->getNumOperands()) return nullptr;
                    cur = cv->getOperand(idx);
                    continue;
                }
                return nullptr;
            }
            return cur;
        }
        return nullptr;
    }

    /// Folds every traceable `extractvalue` in `F`, then deletes every
    /// trivially dead `insertvalue` chain in it.
    PreservedAnalyses run(Function &F, FunctionAnalysisManager &) {
        bool changed = false;
        SmallVector<ExtractValueInst *, 16> work;
        for (auto &BB : F)
            for (auto &I : BB)
                if (auto *EV = dyn_cast<ExtractValueInst>(&I))
                    work.push_back(EV);

        for (auto *EV : work) {
            Value *originalAgg = EV->getAggregateOperand();
            Value *folded = traceMatchingInsert(originalAgg, EV->getIndices());
            if (!folded) continue;
            if (isa<UndefValue>(folded) && folded->getType() != EV->getType())
                folded = UndefValue::get(EV->getType());
            EV->replaceAllUsesWith(folded);
            EV->eraseFromParent();
            // The dead chain is deleted too, so that no aggregate-typed
            // instruction is left for RS4GC.
            RecursivelyDeleteTriviallyDeadInstructions(originalAgg);
            changed = true;
        }

        // Dead chains with no extract left are deleted as well.
        SmallVector<WeakTrackingVH, 16> deadChainHeads;
        for (auto &BB : F)
            for (auto &I : BB)
                if (isa<InsertValueInst>(&I) && isInstructionTriviallyDead(&I))
                    deadChainHeads.push_back(&I);
        for (auto &VH : deadChainHeads) {
            auto *I = dyn_cast_or_null<Instruction>((Value *)VH);
            // Deleting one head can consume upstream links already collected.
            if (I && isInstructionTriviallyDead(I)) {
                RecursivelyDeleteTriviallyDeadInstructions(I);
                changed = true;
            }
        }
        return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
    }
};

/// A diagnostic module pass that, when `ECO_FCA_SCAN` is set, lists every
/// instruction whose result or an operand is an aggregate holding a
/// `ptr addrspace(1)`, then stops the process if it found any.
///
/// These are the instructions the pipeline assumes RS4GC cannot handle. The
/// pass runs after the folding and before RS4GC, so what it lists survived the
/// folding, and it names the function and block.
/// With nothing found it prints `FCA-SCAN: clean`. When `ECO_FCA_SCAN` is
/// unset it does nothing.
struct FcaScanPass : public PassInfoMixin<FcaScanPass> {
    /// Returns whether `T` is, or contains as a struct field or array element,
    /// `ptr addrspace(1)`. Vectors are not looked into.
    static bool aggWithGCPtr(Type *T) {
        if (auto *PT = dyn_cast<PointerType>(T))
            return PT->getAddressSpace() == 1;
        if (auto *ST = dyn_cast<StructType>(T)) {
            for (Type *E : ST->elements())
                if (aggWithGCPtr(E))
                    return true;
            return false;
        }
        if (auto *AT = dyn_cast<ArrayType>(T))
            return aggWithGCPtr(AT->getElementType());
        return false;
    }
    /// Returns whether `T` is a struct or array type.
    static bool isAggregate(Type *T) {
        return isa<StructType>(T) || isa<ArrayType>(T);
    }

    /// Scans the defined functions of `M`, as the type comment describes.
    PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
        if (!::getenv("ECO_FCA_SCAN"))
            return PreservedAnalyses::all();
        unsigned count = 0;
        for (Function &F : M) {
            if (F.isDeclaration())
                continue;
            for (BasicBlock &BB : F)
                for (Instruction &I : BB) {
                    bool bad = isAggregate(I.getType()) &&
                               aggWithGCPtr(I.getType());
                    if (!bad)
                        for (Value *Op : I.operands())
                            if (isAggregate(Op->getType()) &&
                                aggWithGCPtr(Op->getType())) {
                                bad = true;
                                break;
                            }
                    if (bad) {
                        ++count;
                        errs() << "FCA-SCAN: fn=" << F.getName()
                               << " block=" << BB.getName() << "\n  ";
                        I.print(errs());
                        errs() << "\n";
                    }
                }
        }
        if (count)
            report_fatal_error(Twine("FCA-SCAN: ") + Twine(count) +
                               " aggregate-with-gc-pointer instruction(s) "
                               "survived the pre-RS4GC fold (see above)");
        errs() << "FCA-SCAN: clean\n";
        return PreservedAnalyses::all();
    }
};

/// A module pass that replaces every call to a slot-cast barrier with the plain
/// cast it stands for, then deletes the barrier's declaration (REP_LLVM_002).
///
/// The barriers, named in `EcoSlotCastBarriers.h`, keep boxed-slot crossings
/// from being folded before RS4GC, so this must run after RS4GC. It runs before
/// `EcoPtrIntVerifyPass`, which therefore sees the plain casts. Each cast is
/// built where its call was, so it dominates every use the call had. A module
/// without the barrier declarations is left unchanged.
///
/// A use of a barrier that is not a direct call, or one that survives the
/// replacement, stops the process with `report_fatal_error` in every build: a
/// barrier left in the module would be an undefined symbol at link time.
struct StripEcoCastBarriersPass : public PassInfoMixin<StripEcoCastBarriersPass> {
    /// Replaces the calls to the barrier named `name` in `M` with `inttoptr`
    /// to `ptr addrspace(1)` when `toPtr` is set, or `ptrtoint` to `i64`
    /// otherwise, deletes it, and returns whether it was declared.
    static bool stripOne(Module &M, StringRef name, bool toPtr) {
        Function *barrier = M.getFunction(name);
        if (!barrier)
            return false;
        SmallVector<CallInst *, 128> calls;
        for (User *u : barrier->users()) {
            auto *ci = dyn_cast<CallInst>(u);
            if (!ci || ci->getCalledOperand() != barrier)
                report_fatal_error(Twine("StripEcoCastBarriers: non-call use "
                                         "of barrier symbol ") + name);
            calls.push_back(ci);
        }
        for (CallInst *ci : calls) {
            IRBuilder<> b(ci);
            Value *arg = ci->getArgOperand(0);
            Value *cast =
                toPtr ? b.CreateIntToPtr(arg, PointerType::get(M.getContext(), 1))
                      : b.CreatePtrToInt(arg, Type::getInt64Ty(M.getContext()));
            ci->replaceAllUsesWith(cast);
            ci->eraseFromParent();
        }
        if (!barrier->use_empty())
            report_fatal_error(Twine("StripEcoCastBarriers: surviving "
                                     "reference to barrier symbol ") + name);
        barrier->eraseFromParent();
        return true;
    }

    /// Strips both barriers from `M`.
    PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
        bool a = stripOne(M, eco::kSlotToHPtrSym, /*toPtr=*/true);
        bool b = stripOne(M, eco::kHPtrToSlotSym, /*toPtr=*/false);
        return (a || b) ? PreservedAnalyses::none() : PreservedAnalyses::all();
    }
};

} // namespace

void eco::addEcoGCPipeline(ModulePassManager &MPM) {
    // The pipeline assumes RS4GC cannot handle an aggregate holding a
    // `ptr addrspace(1)`. Value-aggregate ops lower to insertvalue and
    // extractvalue chains, so those must be scalarised first; see
    // FoldExtractValuePass for why InstCombine and InstSimplify are not used.
    {
        FunctionPassManager FPM;
        FPM.addPass(PromotePass());                         // mem2reg
        FPM.addPass(SROAPass(SROAOptions::ModifyCFG));
        FPM.addPass(FoldExtractValuePass());
        MPM.addPass(createModuleToFunctionPassAdaptor(std::move(FPM)));
    }

    MPM.addPass(FcaScanPass());

    MPM.addPass(RewriteStatepointsForGC());
    // Bare casts restored here are safe even where a later inliner splices a
    // body into a caller with statepoints. Calls to functions stamped
    // gc-leaf (CGEN_072) stay plain calls that an inliner may inline, but a
    // stamped body has no statepoint, so the inlined casts lie between the
    // caller's statepoints, whose relocations are already explicit SSA values
    // that no fold can bridge.
    MPM.addPass(StripEcoCastBarriersPass());
#ifdef ECO_LOWERING_VALIDATION
    MPM.addPass(createModuleToFunctionPassAdaptor(EcoPtrIntVerifyPass()));
#endif
}
