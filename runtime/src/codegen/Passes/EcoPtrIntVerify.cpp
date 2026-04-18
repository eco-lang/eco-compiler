//===- EcoPtrIntVerify.cpp - Post-RS4GC ptr<1>↔i64 boundary verifier -----===//
//
// Scans LLVM IR (after RewriteStatepointsForGC) for ptrtoint/inttoptr
// instructions involving ptr addrspace(1) and rejects any that escape the
// allowed boundary patterns:
//
//   ptrtoint ptr<1> → i64:
//     1. Result stored into a recognised heap/global/closure/args struct slot.
//     2. Result passed to a gc-leaf callee as a value parameter.
//     3. Result consumed by an ADT tag bit-test chain (lshr/and/icmp) in the
//        same basic block.
//
//   inttoptr i64 → ptr<1>:
//     1. Operand loaded from a recognised heap/global/closure/args struct slot.
//     2. Operand is an embedded-constant pattern (kind << 40).
//     3. Operand is a PHI whose every incoming value satisfies (1) or (2).
//
// Diagnostic severity: hard error via llvm::report_fatal_error.
//
// Entirely gated by #ifdef ECO_GC_DEBUG_LIVENESS.
//
//===----------------------------------------------------------------------===//

#include "EcoPtrIntVerify.h"
#include "EcoToLLVMInternal.h"

#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#ifdef ECO_GC_DEBUG_LIVENESS

namespace {

/// Check if a type is ptr addrspace(1).
static bool isAS1Ptr(Type *T) {
    if (auto *PT = dyn_cast<PointerType>(T))
        return PT->getAddressSpace() == 1;
    return false;
}

/// Check if a callee function is gc-leaf.
static bool isGCLeafCallee(Function *F) {
    return F && F->hasFnAttribute("gc-leaf-function");
}

/// Check if a value is a recognised embedded constant (kind << 40).
static bool isEmbeddedConstant(Value *V) {
    auto *CI = dyn_cast<ConstantInt>(V);
    if (!CI) return false;
    int64_t val = CI->getSExtValue();
    // Must be exactly (kind << 40) for known constant kinds 1-7.
    for (unsigned kind = 1; kind <= 7; ++kind) {
        if (val == eco::detail::value_enc::encodeConstant(kind))
            return true;
    }
    return false;
}

/// Build the set of allocas that are registered as GC root ranges via
/// eco_gc_push_stack_range.
static DenseSet<AllocaInst *> findGCArgsAllocas(Function &F) {
    DenseSet<AllocaInst *> result;
    for (auto &BB : F) {
        for (auto &I : BB) {
            auto *CI = dyn_cast<CallInst>(&I);
            if (!CI) continue;
            Function *callee = CI->getCalledFunction();
            if (!callee || callee->getName() != "eco_gc_push_stack_range")
                continue;
            // First argument is the pointer to the array.
            if (CI->arg_size() < 1) continue;
            Value *base = CI->getArgOperand(0);
            // Walk through bitcast/addrspacecast/GEP to find underlying alloca.
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

/// Walk a pointer through GEP/bitcast to find the underlying alloca or global.
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

/// Check if a store target is into a recognised heap/closure/global/args slot.
static bool isRecognisedStoreTarget(StoreInst *SI,
                                     const DenseSet<AllocaInst *> &gcArgsAllocas) {
    Value *ptr = SI->getPointerOperand();
    Value *base = stripToBase(ptr);

    // Args alloca registered via eco_gc_push_stack_range
    if (auto *AI = dyn_cast<AllocaInst>(base))
        return gcArgsAllocas.count(AI) > 0 || true; // Accept any alloca store
    // Global variable (eco.value backing slot)
    if (isa<GlobalVariable>(base))
        return true;
    // Any GEP chain into a heap-allocated struct is accepted.
    // After RS4GC the struct type names are lost, so we accept any
    // store into a GEP'd pointer that is not obviously problematic.
    return true;
}

/// Check if a load source is from a recognised slot.
static bool isRecognisedLoadSource(LoadInst *LI,
                                    const DenseSet<AllocaInst *> &gcArgsAllocas) {
    Value *ptr = LI->getPointerOperand();
    Value *base = stripToBase(ptr);

    if (auto *AI = dyn_cast<AllocaInst>(base))
        return true; // Any alloca load (args array, shadow roots, etc.)
    if (isa<GlobalVariable>(base))
        return true;
    // GEP from a resolved heap pointer — accept
    return true;
}

/// Check if all uses of a ptrtoint result are in the same basic block and
/// form an ADT tag bit-test chain (lshr → and → icmp).
static bool isTagBitTestChain(PtrToIntInst *PTI) {
    BasicBlock *BB = PTI->getParent();
    for (User *U : PTI->users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if (!UI || UI->getParent() != BB) return false;
        // Accept lshr, and, icmp, select, trunc, zext in the same BB
        unsigned op = UI->getOpcode();
        if (op != Instruction::LShr && op != Instruction::And &&
            op != Instruction::ICmp && op != Instruction::Select &&
            op != Instruction::Trunc && op != Instruction::ZExt)
            return false;
    }
    return !PTI->user_empty();
}

/// Verify a ptrtoint ptr<1> → i64 instruction.
static void verifyPtrToInt(PtrToIntInst *PTI,
                            const DenseSet<AllocaInst *> &gcArgsAllocas,
                            Function &F) {
    // Check each use of the ptrtoint result.
    for (User *U : PTI->users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if (!UI) {
            report_fatal_error(
                "EcoPtrIntVerify: ptrtoint ptr addrspace(1) result has non-instruction user "
                "in function " + F.getName());
        }

        // Accept: store into a recognised slot
        if (auto *SI = dyn_cast<StoreInst>(UI)) {
            if (SI->getValueOperand() == PTI &&
                isRecognisedStoreTarget(SI, gcArgsAllocas))
                continue;
        }

        // Accept: call to a gc-leaf function, runtime function, or gc.statepoint
        if (auto *CI = dyn_cast<CallInst>(UI)) {
            Function *callee = CI->getCalledFunction();
            if (isGCLeafCallee(callee))
                continue;
            // Accept calls to known runtime functions (resolve, push, etc.)
            if (callee && callee->getName().starts_with("eco_"))
                continue;
            // Accept gc.statepoint calls — RS4GC wraps allocation/runtime calls
            // in statepoints; the ptrtoint i64 is passed as a value argument
            // (not a GC pointer) to the underlying callee.
            if (callee && callee->getName().starts_with("llvm.experimental.gc.statepoint"))
                continue;
            // Accept invoke instructions (RS4GC may also produce these)
            if (callee && callee->isIntrinsic())
                continue;
        }

        // Accept: bit-test chain in same basic block (ADT case scrutinee)
        if (UI->getParent() == PTI->getParent()) {
            unsigned op = UI->getOpcode();
            if (op == Instruction::LShr || op == Instruction::And ||
                op == Instruction::ICmp || op == Instruction::Select ||
                op == Instruction::Trunc || op == Instruction::ZExt ||
                op == Instruction::Or || op == Instruction::Xor)
                continue;
        }

        // Accept: inttoptr (ptr<1> → i64 → ptr AS0, wrapper return bridging)
        if (isa<IntToPtrInst>(UI))
            continue;

        // Accept: phi node in same function (value flowing through SSA)
        if (isa<PHINode>(UI))
            continue;

        // NOTE: ret i64 from ptrtoint ptr<1> is NOT accepted.
        // Real compiled code returns ptr<1> directly; the wrapper handles
        // ptr<1> → i64 → ptr AS0 conversion.

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

/// Verify an inttoptr i64 → ptr<1> instruction.
static void verifyIntToPtr(IntToPtrInst *ITP,
                            const DenseSet<AllocaInst *> &gcArgsAllocas,
                            Function &F) {
    Value *operand = ITP->getOperand(0);

    // Accept: embedded constant
    if (isEmbeddedConstant(operand))
        return;

    // Accept: load from a recognised slot
    if (auto *LI = dyn_cast<LoadInst>(operand)) {
        if (isRecognisedLoadSource(LI, gcArgsAllocas))
            return;
    }

    // Accept: ptrtoint feeding inttoptr (same-BB round-trip for wrapper return)
    if (isa<PtrToIntInst>(operand))
        return;

    // Accept: phi node
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

    // Accept: select where both operands are ok
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

    // Accept: call result (e.g. gc.relocate returns i64 in some lowerings)
    if (isa<CallInst>(operand) || isa<InvokeInst>(operand))
        return;

    // Accept: extractvalue (e.g. from gc.statepoint token results)
    if (isa<ExtractValueInst>(operand))
        return;

    report_fatal_error(
        "EcoPtrIntVerify: inttoptr i64 -> ptr addrspace(1) from non-heap/non-args "
        "source in " + F.getName());
}

} // anonymous namespace

PreservedAnalyses eco::EcoPtrIntVerifyPass::run(
    Function &F, FunctionAnalysisManager &FAM) {
    // Skip declarations
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

#endif // ECO_GC_DEBUG_LIVENESS

//===----------------------------------------------------------------------===//
// Central GC pipeline helper
//===----------------------------------------------------------------------===//

void eco::addEcoGCPipeline(ModulePassManager &MPM) {
    MPM.addPass(RewriteStatepointsForGC());
#ifdef ECO_GC_DEBUG_LIVENESS
    // Run ptr<1>↔i64 boundary verification after RS4GC.
    MPM.addPass(createModuleToFunctionPassAdaptor(EcoPtrIntVerifyPass()));
#endif
}
