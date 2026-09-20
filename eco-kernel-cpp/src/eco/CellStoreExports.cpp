//===- CellStoreExports.cpp - C-linkage exports for CellStore ------------===//

#include "KernelExports.h"
#include "CellStore.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

int64_t Eco_Kernel_CellStore_new(int64_t cap) {
    return CellStore::newStore(cap);
}

int64_t Eco_Kernel_CellStore_size(int64_t h) {
    return CellStore::size(h);
}

HPtr Eco_Kernel_CellStore_get(int64_t ix, int64_t h) {
    return HPtr::fromBits(CellStore::get(ix, h));
}

int64_t Eco_Kernel_CellStore_set(int64_t ix, HPtr cell, int64_t h) {
    return CellStore::set(ix, cell.toBits(), h);
}

int64_t Eco_Kernel_CellStore_push(HPtr cell, int64_t h) {
    return CellStore::push(cell.toBits(), h);
}

int64_t Eco_Kernel_CellStore_pushMark(int64_t h) {
    return CellStore::pushMark(h);
}

int64_t Eco_Kernel_CellStore_rollback(int64_t h) {
    return CellStore::rollback(h);
}

int64_t Eco_Kernel_CellStore_commit(int64_t h) {
    return CellStore::commit(h);
}

HPtr Eco_Kernel_CellStore_disposeThen(int64_t h, HPtr x) {
    return HPtr::fromBits(CellStore::disposeThen(h, x.toBits()));
}

void Eco_Kernel_CellStore_register_gc_roots() {
    CellStore::registerGcRootScanner();
}
