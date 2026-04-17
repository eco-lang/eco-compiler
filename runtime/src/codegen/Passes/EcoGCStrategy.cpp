//===- EcoGCStrategy.cpp - GC strategy for the Eco runtime ----------------===//
//
// Registers the "eco-gc" GC strategy with LLVM. This strategy uses statepoints
// (gc.statepoint / gc.relocate) and enables RewriteStatepointsForGC (RS4GC)
// to automatically insert them. GC-managed pointers are identified by
// ptr addrspace(1).
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/GCStrategy.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/Compiler.h"

using namespace llvm;

namespace {

class EcoGCStrategy : public GCStrategy {
public:
    EcoGCStrategy() {
        UseStatepoints = true;
        UseRS4GC = true;
    }

    std::optional<bool> isGCManagedPointer(const Type *Ty) const override {
        if (auto *PT = dyn_cast<PointerType>(Ty))
            return PT->getAddressSpace() == 1;
        return false;
    }
};

static GCRegistry::Add<EcoGCStrategy>
    X("eco-gc", "Eco runtime GC strategy (statepoints via RS4GC)");

} // anonymous namespace

// Force the linker to keep this translation unit (and its static
// GCRegistry::Add constructor) when linking from a static library.
namespace eco {
void linkEcoGCStrategy() {}
}
