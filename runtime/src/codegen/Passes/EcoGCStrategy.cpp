//===- EcoGCStrategy.cpp - GC strategy for the Eco runtime ----------------===//
//
// Registers the LLVM GC strategy named "eco-gc". A function that names this
// strategy in its `gc` attribute has its GC pointers tracked with statepoints
// (gc.statepoint / gc.relocate), which LLVM's RewriteStatepointsForGC (RS4GC)
// inserts. A GC pointer is any pointer in address space 1, and no other value.
//
// The registration is a static constructor in this file, so a tool that gets
// this file from a static library must call `eco::linkEcoGCStrategy()` to keep
// it in the link.
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/GCStrategy.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/Compiler.h"

using namespace llvm;

namespace {

/**
 * The "eco-gc" strategy: statepoints placed by RS4GC, with GC pointers
 * identified by address space 1.
 */
class EcoGCStrategy : public GCStrategy {
public:
    EcoGCStrategy() {
        UseStatepoints = true;
        UseRS4GC = true;
    }

    // Returns true for a pointer type in address space 1 and false for every
    // other type.
    std::optional<bool> isGCManagedPointer(const Type *Ty) const override {
        if (auto *PT = dyn_cast<PointerType>(Ty))
            return PT->getAddressSpace() == 1;
        return false;
    }
};

// The registration of `EcoGCStrategy` under the name "eco-gc".
static GCRegistry::Add<EcoGCStrategy>
    X("eco-gc", "Eco runtime GC strategy (statepoints via RS4GC)");

} // anonymous namespace

namespace eco {
// Does nothing. Calling it makes the linker keep this file, and with it the
// registration of "eco-gc", when the file comes from a static library.
void linkEcoGCStrategy() {}
}
