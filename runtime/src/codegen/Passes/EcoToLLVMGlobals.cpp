//===- EcoToLLVMGlobals.cpp - Global variable lowering patterns -----------===//
//
// Lowers the module-level state of an Elm program to LLVM: its globals, its
// type table, and the caches that let a constant or a string literal be read
// with a load once its slot is set. The contracts are on the declarations in
// `EcoToLLVMInternal.h`; this comment says how they are implemented.
//
// Every global this file makes to hold an Elm value is an internal i64,
// initialised to 0. The word 0 means "unset": a heap pointer is a non-zero
// address and every embedded constant has `ptr_ind` set, so no `!eco.value`
// word is 0. Reads and writes convert between the i64 and
// `ptr addrspace(1)` through `globalLoadI64ToValue` and
// `globalStoreValueToI64` (REP_LLVM_002).
//
// `__eco_init_globals` registers every internal i64 global in the module as a
// GC root, except two kinds of cache slot that register themselves or need no
// root:
//
// - A CAF slot, `__eco_caf$<thunk>`, caches the value of a constant defined at
//   top level (a CAF), compiled as a function of no arguments. The thunk
//   stores into it what `eco_caf_promote` returns, and that runtime function
//   roots the slot itself when the value stays in the collected heap.
// - A string-literal slot, `__eco_strlit$<literal global>`, is written only by
//   the runtime's `*_fill` functions, and only with a PermanentSpace word,
//   which never moves and is never collected, so it needs no root.
//
// A rewritten call site reads a slot and makes the call only if it is 0. That
// test is built as an `scf.if` rather than new blocks, because the functions it
// is inserted into may still hold `scf` regions, which must stay single-block.
//
// The type table becomes `__eco_type_graph`, an 80-byte struct of five
// (pointer, count, padding) triples. Four of the arrays it points to hold no
// pointers (types, fields, constructors and function argument type ids) and
// are emitted as little-endian byte blobs, in the layouts of `EcoTypeInfo`,
// `EcoFieldInfo` and `EcoCtorInfo` (`allocator/TypeInfo.hpp`) and of u32. The
// string array holds pointers and is built with `insertvalue`, as is the root
// struct.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../../allocator/TypeInfo.hpp"
#include "mlir/Dialect/SCF/IR/SCF.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.global -> LLVM global variable declaration
//===----------------------------------------------------------------------===//

/**
 * The pattern that replaces `eco.global` with an internal i64 global of the
 * same name, initialised to 0, the unset word.
 */
struct GlobalOpLowering : public OpConversionPattern<GlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(GlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        auto zeroAttr = rewriter.getI64IntegerAttr(0);

        rewriter.replaceOpWithNewOp<LLVM::GlobalOp>(
            op,
            i64Ty,
            /*isConstant=*/false,
            LLVM::Linkage::Internal,
            op.getSymName(),
            zeroAttr);

        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.load_global -> LLVM load from global address
//===----------------------------------------------------------------------===//

/**
 * The pattern that replaces `eco.load_global` with an i64 load from the global,
 * converted to `ptr addrspace(1)` by `globalLoadI64ToValue`.
 */
struct LoadGlobalOpLowering : public OpConversionPattern<LoadGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(LoadGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        auto loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, globalAddr);
        Value result = globalLoadI64ToValue(rewriter, loc, loadedValue.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.store_global -> LLVM store to global address
//===----------------------------------------------------------------------===//

/**
 * The pattern that replaces `eco.store_global` with a store of the value,
 * converted to i64 by `globalStoreValueToI64`, into the global.
 */
struct StoreGlobalOpLowering : public OpConversionPattern<StoreGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(StoreGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        Value valI64 = globalStoreValueToI64(rewriter, loc, adaptor.getValue());
        rewriter.create<LLVM::StoreOp>(loc, valI64, globalAddr);

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.type_table -> LLVM globals for type graph
//===----------------------------------------------------------------------===//

/**
 * The pattern that replaces `eco.type_table` with `__eco_type_graph` and the
 * private arrays it points to.
 *
 * If the module already has `__eco_type_graph`, the op is erased and nothing
 * is emitted. An absent or empty array becomes a null pointer and a count of
 * 0. An entry of the wrong shape becomes zero bytes, and an attribute that is
 * not an integer is written as 0.
 */
struct TypeTableOpLowering : public OpConversionPattern<TypeTableOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(TypeTableOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();

        if (module.lookupSymbol("__eco_type_graph")) {
            rewriter.eraseOp(op);
            return success();
        }

        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // EcoTypeGraph: 80 bytes.
        auto typeGraphTy = LLVM::LLVMStructType::getLiteral(ctx, {
            ptrTy, i32Ty, i32Ty,  // types, type_count, padding1
            ptrTy, i32Ty, i32Ty,  // fields, field_count, padding2
            ptrTy, i32Ty, i32Ty,  // ctors, ctor_count, padding3
            ptrTy, i32Ty, i32Ty,  // func_args, func_arg_count, padding4
            ptrTy, i32Ty, i32Ty   // strings, string_count, padding5
        });

        auto typesAttr = op.getTypes();
        auto fieldsAttr = op.getFields();
        auto ctorsAttr = op.getCtors();
        auto funcArgsAttr = op.getFuncArgs();
        auto stringsAttr = op.getStrings();

        OpBuilder::InsertionGuard guard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());

        // The four pointer-free arrays are each one `[N x i8]` global with a
        // byte-string initializer, not a chain of `insertvalue` ops: such a
        // chain costs one op per field, and LLVM copies the aggregate again for
        // each `insertvalue` when it folds the chain. The structs have no
        // padding beyond their explicit pad fields, so the packed bytes are the
        // array-of-structs layout. Alignment is set because an i8 array would
        // otherwise be 1-aligned, and the runtime reads it through struct
        // pointers.
        auto appendU32 = [](std::string &b, uint64_t v) {
            b.push_back(char(v & 0xFF));
            b.push_back(char((v >> 8) & 0xFF));
            b.push_back(char((v >> 16) & 0xFF));
            b.push_back(char((v >> 24) & 0xFF));
        };
        auto emitByteBlobGlobal = [&](StringRef name, const std::string &bytes,
                                      uint64_t align) -> LLVM::GlobalOp {
            auto arrTy = LLVM::LLVMArrayType::get(i8Ty, bytes.size());
            auto g = rewriter.create<LLVM::GlobalOp>(
                loc, arrTy, /*isConstant=*/true, LLVM::Linkage::Private, name,
                rewriter.getStringAttr(StringRef(bytes.data(), bytes.size())));
            g.setAlignment(align);
            return g;
        };
        auto intAt = [](ArrayAttr a, unsigned i) -> int64_t {
            auto ia = llvm::dyn_cast<IntegerAttr>(a[i]);
            return ia ? ia.getInt() : 0;
        };

        // Strings: one NUL-terminated global per string, and an array of
        // pointers to them.
        uint32_t stringCount = 0;
        LLVM::GlobalOp stringsGlobal = nullptr;
        if (stringsAttr && !stringsAttr->empty()) {
            stringCount = stringsAttr->size();
            SmallVector<LLVM::GlobalOp> stringGlobals;
            for (size_t i = 0; i < stringCount; i++) {
                auto strAttr = llvm::dyn_cast<StringAttr>((*stringsAttr)[i]);
                if (!strAttr) continue;

                auto strValue = strAttr.getValue();
                auto strType = LLVM::LLVMArrayType::get(i8Ty, strValue.size() + 1);

                std::string globalName = "__eco_typestr_" + std::to_string(i);
                auto strGlobal = rewriter.create<LLVM::GlobalOp>(
                    loc, strType, /*isConstant=*/true,
                    LLVM::Linkage::Private, globalName,
                    rewriter.getStringAttr(std::string(strValue) + '\0'));
                stringGlobals.push_back(strGlobal);
            }

            auto strPtrArrayTy = LLVM::LLVMArrayType::get(ptrTy, stringCount);
            stringsGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, strPtrArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_strings_array",
                Attribute());

            Block *strInitBlock = rewriter.createBlock(&stringsGlobal.getInitializerRegion());
            rewriter.setInsertionPointToStart(strInitBlock);
            Value strArray = rewriter.create<LLVM::UndefOp>(loc, strPtrArrayTy);
            for (size_t i = 0; i < stringGlobals.size(); i++) {
                auto addr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, stringGlobals[i].getSymName());
                strArray = rewriter.create<LLVM::InsertValueOp>(loc, strArray, addr, ArrayRef<int64_t>{(int64_t)i});
            }
            rewriter.create<LLVM::ReturnOp>(loc, strArray);
            rewriter.setInsertionPointToStart(module.getBody());
        }

        // Function argument type ids: u32 each.
        uint32_t funcArgCount = 0;
        LLVM::GlobalOp funcArgsGlobal = nullptr;
        if (funcArgsAttr && !funcArgsAttr->empty()) {
            funcArgCount = funcArgsAttr->size();
            std::string bytes;
            bytes.reserve(funcArgCount * 4);
            for (size_t i = 0; i < funcArgCount; i++) {
                auto intAttr = llvm::dyn_cast<IntegerAttr>((*funcArgsAttr)[i]);
                appendU32(bytes, intAttr ? intAttr.getInt() : 0);
            }
            funcArgsGlobal =
                emitByteBlobGlobal("__eco_func_args_array", bytes, /*align=*/4);
        }

        // Constructors: EcoCtorInfo, 16 bytes {u32 ctor_id, u32 name_index,
        // u32 first_field, u32 field_count}.
        uint32_t ctorCount = 0;
        LLVM::GlobalOp ctorsGlobal = nullptr;
        if (ctorsAttr && !ctorsAttr->empty()) {
            ctorCount = ctorsAttr->size();
            std::string bytes;
            bytes.reserve(ctorCount * 16);
            for (size_t i = 0; i < ctorCount; i++) {
                auto ctorArr = llvm::dyn_cast<ArrayAttr>((*ctorsAttr)[i]);
                if (!ctorArr || ctorArr.size() < 4) {
                    bytes.append(16, '\0');
                    continue;
                }
                for (size_t j = 0; j < 4; j++)
                    appendU32(bytes, intAt(ctorArr, j));
            }
            ctorsGlobal =
                emitByteBlobGlobal("__eco_ctors_array", bytes, /*align=*/4);
        }

        // Fields: EcoFieldInfo, 8 bytes {u32 name_index, u32 type_id}.
        uint32_t fieldCount = 0;
        LLVM::GlobalOp fieldsGlobal = nullptr;
        if (fieldsAttr && !fieldsAttr->empty()) {
            fieldCount = fieldsAttr->size();
            std::string bytes;
            bytes.reserve(fieldCount * 8);
            for (size_t i = 0; i < fieldCount; i++) {
                auto fieldArr = llvm::dyn_cast<ArrayAttr>((*fieldsAttr)[i]);
                if (!fieldArr || fieldArr.size() < 2) {
                    bytes.append(8, '\0');
                    continue;
                }
                for (size_t j = 0; j < 2; j++)
                    appendU32(bytes, intAt(fieldArr, j));
            }
            fieldsGlobal =
                emitByteBlobGlobal("__eco_fields_array", bytes, /*align=*/4);
        }

        // Types: EcoTypeInfo, 20 bytes {u32 type_id @0, u8 kind @4,
        // u8 pad[3] @5, u8 data[12] @8}, where `data` is laid out per kind.
        uint32_t typeCount = 0;
        LLVM::GlobalOp typesGlobal = nullptr;
        if (typesAttr && !typesAttr->empty()) {
            typeCount = typesAttr->size();
            std::string bytes;
            bytes.reserve(typeCount * 20);
            for (size_t i = 0; i < typeCount; i++) {
                auto typeArr = llvm::dyn_cast<ArrayAttr>((*typesAttr)[i]);
                if (!typeArr || typeArr.size() < 3) {
                    bytes.append(20, '\0');
                    continue;
                }

                uint32_t typeId = static_cast<uint32_t>(intAt(typeArr, 0));
                uint8_t kind = static_cast<uint8_t>(intAt(typeArr, 1));

                // An unknown kind, or a known one with too few elements, leaves
                // `data` zero.
                char data[12] = {0};
                auto putU16 = [&](size_t off, uint64_t v) {
                    data[off + 0] = char(v & 0xFF);
                    data[off + 1] = char((v >> 8) & 0xFF);
                };
                auto putU32 = [&](size_t off, uint64_t v) {
                    data[off + 0] = char(v & 0xFF);
                    data[off + 1] = char((v >> 8) & 0xFF);
                    data[off + 2] = char((v >> 16) & 0xFF);
                    data[off + 3] = char((v >> 24) & 0xFF);
                };

                switch (kind) {
                case 0: // Primitive: prim_kind (u8) @0
                    data[0] = char(intAt(typeArr, 2) & 0xFF);
                    break;
                case 1: // List: elem_type_id (u32) @0
                    putU32(0, intAt(typeArr, 2));
                    break;
                case 2: // Tuple: arity (u16) @0, first_field (u32) @4
                    if (typeArr.size() >= 5) {
                        putU16(0, intAt(typeArr, 2));
                        putU32(4, intAt(typeArr, 3));
                    }
                    break;
                case 3: // Record: first_field (u32) @0, field_count (u32) @4
                    if (typeArr.size() >= 4) {
                        putU32(0, intAt(typeArr, 2));
                        putU32(4, intAt(typeArr, 3));
                    }
                    break;
                case 4: // Custom: first_ctor (u32) @0, ctor_count (u32) @4
                    if (typeArr.size() >= 4) {
                        putU32(0, intAt(typeArr, 2));
                        putU32(4, intAt(typeArr, 3));
                    }
                    break;
                case 5: // Function: first_arg_type (u32) @0, arg_count (u16) @4,
                        // result_type_id (u32) @8
                    if (typeArr.size() >= 5) {
                        putU32(0, intAt(typeArr, 2));
                        putU16(4, intAt(typeArr, 3));
                        putU32(8, intAt(typeArr, 4));
                    }
                    break;
                case 6: // Polymorphic: constraint (u8) @0, an
                        // EcoConstraintKind.
                    data[0] = char(intAt(typeArr, 2) & 0xFF);
                    break;
                }

                appendU32(bytes, typeId);       // type_id @0..4
                bytes.push_back(char(kind));    // kind    @4
                bytes.append(3, '\0');          // pad     @5..8
                bytes.append(data, 12);         // data    @8..20
            }
            typesGlobal =
                emitByteBlobGlobal("__eco_types_array", bytes, /*align=*/8);
        }

        auto typeGraphGlobal = rewriter.create<LLVM::GlobalOp>(
            loc, typeGraphTy, /*isConstant=*/true,
            LLVM::Linkage::External, "__eco_type_graph",
            Attribute());

        Block *graphInitBlock = rewriter.createBlock(&typeGraphGlobal.getInitializerRegion());
        rewriter.setInsertionPointToStart(graphInitBlock);

        auto zero32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
        auto nullPtr = rewriter.create<LLVM::ZeroOp>(loc, ptrTy);

        Value structVal = rewriter.create<LLVM::UndefOp>(loc, typeGraphTy);

        if (typesGlobal) {
            auto typesAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, typesGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, typesAddr, ArrayRef<int64_t>{0});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{0});
        }
        auto typeCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)typeCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, typeCountCst, ArrayRef<int64_t>{1});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{2}); // padding

        if (fieldsGlobal) {
            auto fieldsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, fieldsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, fieldsAddr, ArrayRef<int64_t>{3});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{3});
        }
        auto fieldCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)fieldCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, fieldCountCst, ArrayRef<int64_t>{4});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{5}); // padding

        if (ctorsGlobal) {
            auto ctorsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, ctorsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, ctorsAddr, ArrayRef<int64_t>{6});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{6});
        }
        auto ctorCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)ctorCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, ctorCountCst, ArrayRef<int64_t>{7});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{8}); // padding

        if (funcArgsGlobal) {
            auto funcArgsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcArgsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, funcArgsAddr, ArrayRef<int64_t>{9});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{9});
        }
        auto funcArgCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)funcArgCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, funcArgCountCst, ArrayRef<int64_t>{10});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{11}); // padding

        if (stringsGlobal) {
            auto stringsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, stringsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, stringsAddr, ArrayRef<int64_t>{12});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{12});
        }
        auto stringCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)stringCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, stringCountCst, ArrayRef<int64_t>{13});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{14}); // padding

        rewriter.create<LLVM::ReturnOp>(loc, structVal);

        rewriter.eraseOp(op);
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoGlobalPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns) {

    auto *ctx = patterns.getContext();
    patterns.add<GlobalOpLowering>(typeConverter, ctx);
    patterns.add<LoadGlobalOpLowering>(typeConverter, ctx);
    patterns.add<StoreGlobalOpLowering>(typeConverter, ctx);
    patterns.add<TypeTableOpLowering>(typeConverter, ctx);
}

//===----------------------------------------------------------------------===//
// Global Root Initialization Function
//===----------------------------------------------------------------------===//

void eco::detail::createGlobalRootInitFunction(
    ModuleOp module,
    EcoRuntime &runtime) {

    // CAF slots are left out because `eco_caf_promote` roots a slot itself, at
    // its first evaluation, when the value stays in the collected heap; rooting
    // every slot up front would keep slots that are never evaluated in the
    // root set. String-literal slots hold only PermanentSpace words and need no
    // root. Globals are top-level, so only the module body is scanned.
    SmallVector<LLVM::GlobalOp> ecoGlobals;
    llvm::for_each(module.getOps<LLVM::GlobalOp>(), [&](LLVM::GlobalOp globalOp) {
        if (globalOp.getLinkage() == LLVM::Linkage::Internal &&
            globalOp.getGlobalType().isInteger(64) &&
            !globalOp.getSymName().starts_with("__eco_caf$") &&
            !globalOp.getSymName().starts_with("__eco_strlit$")) {
            ecoGlobals.push_back(globalOp);
        }
    });

    LLVM::GlobalOp typeGraphGlobal = nullptr;
    if (auto sym = module.lookupSymbol<LLVM::GlobalOp>("__eco_type_graph")) {
        typeGraphGlobal = sym;
    }

    if (ecoGlobals.empty() && !typeGraphGlobal)
        return;

    auto *ctx = runtime.ctx;
    auto loc = module.getLoc();
    OpBuilder builder(ctx);
    builder.setInsertionPointToEnd(module.getBody());

    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);

    auto initFuncType = LLVM::LLVMFunctionType::get(voidTy, {});
    auto initFunc = builder.create<LLVM::LLVMFuncOp>(
        loc, "__eco_init_globals", initFuncType);
    initFunc.setLinkage(LLVM::Linkage::External);

    Block *entryBlock = initFunc.addEntryBlock(builder);
    builder.setInsertionPointToStart(entryBlock);

    if (typeGraphGlobal) {
        auto regFunc = runtime.getOrCreateRegisterTypeGraph(builder);
        auto typeGraphAddr = builder.create<LLVM::AddressOfOp>(
            loc, ptrTy, typeGraphGlobal.getSymName());
        builder.create<LLVM::CallOp>(loc, regFunc, ValueRange{typeGraphAddr});
    }

    if (!ecoGlobals.empty()) {
        auto addRootFunc = runtime.getOrCreateGcAddRoot(builder);
        for (auto globalOp : ecoGlobals) {
            auto globalAddr = builder.create<LLVM::AddressOfOp>(
                loc, ptrTy, globalOp.getSymName());
            builder.create<LLVM::CallOp>(loc, addRootFunc, ValueRange{globalAddr});
        }
    }

    builder.create<LLVM::ReturnOp>(loc, ValueRange{});
}

//===----------------------------------------------------------------------===//
// CAF memoization guard (CGEN_068)
//
// The guarded thunk has this shape:
//
//   entry:  %bits = load i64 from @__eco_caf$<name>
//           cond_br (%bits != 0), ^hit, ^body
//   ^hit:   return globalLoadI64ToValue(%bits)
//   ^body:  <original body>, where every `llvm.return %r` becomes
//           %p = eco_caf_promote(globalStoreValueToI64(%r), @slot)
//           store %p, @slot
//           return globalLoadI64ToValue(%p)
//
// The hit path makes no call that can collect, and each store sits just
// before its return, so no i64 that came from a pointer is live across a
// statepoint.
//===----------------------------------------------------------------------===//

void eco::detail::declareCafPromote(ModuleOp module, Location loc) {
    if (module.lookupSymbol<LLVM::LLVMFuncOp>("eco_caf_promote"))
        return;
    auto *ctx = module.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    OpBuilder mb = OpBuilder::atBlockEnd(module.getBody());
    auto promoteTy = LLVM::LLVMFunctionType::get(i64Ty, {i64Ty, ptrTy});
    auto decl = mb.create<LLVM::LLVMFuncOp>(loc, "eco_caf_promote", promoteTy);
    decl->setAttr("passthrough",
                  ArrayAttr::get(ctx, {StringAttr::get(ctx, "gc-leaf-function")}));
}

LogicalResult eco::detail::installCafMemoGuard(LLVM::LLVMFuncOp func,
                                              bool &promoteDeclared) {
    if (func.isExternal())
        return success();

    auto *ctx = func.getContext();
    auto loc = func.getLoc();
    Region &body = func.getBody();
    Block *oldEntry = &body.front();

    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    auto fnTy = func.getFunctionType();
    if (fnTy.getNumParams() != 0 || fnTy.getReturnType() != hptrTy)
        return func.emitError(
            "eco.caf_memo on a non-thunk or non-!eco.value function");

    std::string slotName = ("__eco_caf$" + func.getSymName()).str();

    OpBuilder builder(ctx);

    // `eco_caf_promote` is gc-leaf, so RS4GC adds no statepoint at the call
    // and the converted i64 may be passed to it.
    if (!promoteDeclared)
        declareCafPromote(func->getParentOfType<ModuleOp>(), loc);
    promoteDeclared = true;

    // The existing returns are rewritten before the hit block is made, so its
    // return is not. Each returns what `eco_caf_promote` returned, which may
    // be a copy in PermanentSpace, so the first caller shares the cached value.
    SmallVector<LLVM::ReturnOp> rets;
    body.walk([&](LLVM::ReturnOp r) { rets.push_back(r); });
    for (LLVM::ReturnOp r : rets) {
        builder.setInsertionPoint(r);
        auto addr = builder.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
        Value bits = globalStoreValueToI64(builder, loc, r.getOperand(0));
        auto perm = builder.create<LLVM::CallOp>(
            loc, TypeRange{i64Ty}, llvm::StringRef("eco_caf_promote"),
            ValueRange{bits, addr});
        builder.create<LLVM::StoreOp>(loc, perm.getResult(), addr);
        Value promoted = globalLoadI64ToValue(builder, loc, perm.getResult());
        r.setOperand(0, promoted);
    }

    // The thunk has no parameters, so the new entry block has no arguments.
    Block *entry = new Block();
    body.push_front(entry);
    Block *hit = new Block();
    body.push_back(hit);

    builder.setInsertionPointToEnd(entry);
    auto addr = builder.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
    auto bits = builder.create<LLVM::LoadOp>(loc, i64Ty, addr);
    auto zero = builder.create<LLVM::ConstantOp>(loc, i64Ty, 0);
    auto isSet = builder.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne,
                                              bits, zero);
    builder.create<LLVM::CondBrOp>(loc, isSet, hit, oldEntry);

    builder.setInsertionPointToEnd(hit);
    Value cached = globalLoadI64ToValue(builder, loc, bits);
    builder.create<LLVM::ReturnOp>(loc, ValueRange{cached});

    return success();
}

//===----------------------------------------------------------------------===//
// CAF caller-side fast path
//
// A call `%v = llvm.call @thunk()` becomes
//
//   %bits  = llvm.load @__eco_caf$thunk
//   %isset = llvm.icmp ne %bits, 0
//   %v = scf.if %isset -> ptr<1> {
//     scf.yield globalLoadI64ToValue(%bits)
//   } else {
//     scf.yield llvm.call @thunk()   // the guarded thunk fills the slot
//   }
//
// so a call that hits the cache makes no call, and has no statepoint. The
// load and test carry no GC pointer, and `%v` is an ordinary `ptr<1>` value.
//===----------------------------------------------------------------------===//

void eco::detail::rewriteCafCallSitesFast(
    LLVM::LLVMFuncOp func,
    const llvm::DenseSet<llvm::StringRef> &cafMemoFuncs) {
    if (func.isExternal())
        return;

    auto *ctx = func.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    // Collected first, because the rewrite moves each call into a new region.
    SmallVector<LLVM::CallOp> sites;
    func.walk([&](LLVM::CallOp call) {
        auto callee = call.getCallee();
        if (!callee || !cafMemoFuncs.contains(*callee))
            return;
        if (call.getNumOperands() != 0 || call->getNumResults() != 1)
            return;
        if (call->getResult(0).getType() != hptrTy)
            return;
        sites.push_back(call);
    });

    for (LLVM::CallOp call : sites) {
        auto loc = call.getLoc();
        std::string slotName = ("__eco_caf$" + *call.getCallee()).str();

        OpBuilder bb(call);
        auto addr = bb.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
        auto bits = bb.create<LLVM::LoadOp>(loc, i64Ty, addr);
        auto zero = bb.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        auto isSet =
            bb.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, bits, zero);

        auto ifOp = bb.create<scf::IfOp>(loc, TypeRange{hptrTy}, isSet,
                                         /*withElseRegion=*/true);

        {
            OpBuilder hb = OpBuilder::atBlockBegin(ifOp.thenBlock());
            Value cached = globalLoadI64ToValue(hb, loc, bits);
            hb.create<scf::YieldOp>(loc, ValueRange{cached});
        }

        // The miss arm is the original call, moved.
        call->getResult(0).replaceAllUsesWith(ifOp.getResult(0));
        call->moveBefore(ifOp.elseBlock(), ifOp.elseBlock()->end());
        {
            OpBuilder mb = OpBuilder::atBlockEnd(ifOp.elseBlock());
            mb.create<scf::YieldOp>(loc, ValueRange{call->getResult(0)});
        }
    }
}

//===----------------------------------------------------------------------===//
// String-literal interning cache
//
// Each evaluation of a string literal is a call such as
//
//   %s = llvm.call @eco_alloc_string_literal_utf8(@__eco_str_N, len)
//
// which is not gc-leaf, because it may allocate, so RS4GC makes it a
// statepoint. The cache gives each literal global an i64 slot and tests it, as
// the CAF fast path does:
//
//   %bits  = llvm.load @__eco_strlit$__eco_str_N
//   %isset = llvm.icmp ne %bits, 0
//   scf.if %isset -> ptr<1> {
//     scf.yield __eco_slot_to_hptr(%bits)            // no call, no statepoint
//   } else {
//     scf.yield llvm.call @eco_string_literal_utf8_fill(
//                   @__eco_str_N, len, @__eco_strlit$__eco_str_N)
//   }
//
// The `*_fill` functions store into the slot only a value in PermanentSpace
// (HEAP_036); a literal that is not there leaves its slot 0, and every
// evaluation of it then takes the call.
//===----------------------------------------------------------------------===//

// Returns whether the string-literal cache is on: true unless
// `ECO_STRLIT_CACHE` is exactly `0`. The variable is read once per process.
static bool strLitCacheEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_STRLIT_CACHE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

// Returns whether `callee` names one of the two runtime functions that
// allocate a string literal.
static bool isStringLiteralAllocCallee(llvm::StringRef callee) {
    return callee == "eco_alloc_string_literal_utf8" ||
           callee == "eco_alloc_string_literal";
}

void eco::detail::materializeStringLiteralSlots(ModuleOp module,
                                                llvm::StringSet<> &slots) {
    if (!strLitCacheEnabled())
        return;

    auto *ctx = module.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i32Ty = IntegerType::get(ctx, 32);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    // Collected first, in module order, because the slots are appended to the
    // block being iterated. `slots` also serves as the check for an existing
    // slot, instead of a `lookupSymbol` per literal.
    SmallVector<StringRef> literals;
    for (auto globalOp : module.getOps<LLVM::GlobalOp>()) {
        StringRef name = globalOp.getSymName();
        if (name.starts_with("__eco_strlit$")) {
            slots.insert(name);
            continue;
        }
        if (!name.starts_with("__eco_str_"))
            continue;
        if (globalOp.getLinkage() != LLVM::Linkage::Internal)
            continue;
        if (!isa<LLVM::LLVMArrayType>(globalOp.getGlobalType()))
            continue;
        literals.push_back(name);
    }
    if (literals.empty())
        return;

    auto loc = module.getLoc();
    OpBuilder builder = OpBuilder::atBlockEnd(module.getBody());
    for (StringRef name : literals) {
        std::string slotName = ("__eco_strlit$" + name).str();
        if (!slots.insert(slotName).second)
            continue;
        builder.create<LLVM::GlobalOp>(loc, i64Ty, /*isConstant=*/false,
                                       LLVM::Linkage::Internal, slotName,
                                       builder.getI64IntegerAttr(0));
    }

    // Declared here rather than with the other runtime declarations, so that
    // a module compiled with the cache off has no declaration of them.
    for (const char *name :
         {"eco_string_literal_fill", "eco_string_literal_utf8_fill"}) {
        if (module.lookupSymbol<LLVM::LLVMFuncOp>(name))
            continue;
        auto fnTy = LLVM::LLVMFunctionType::get(hptrTy, {ptrTy, i32Ty, ptrTy});
        builder.create<LLVM::LLVMFuncOp>(loc, name, fnTy);
    }
}

void eco::detail::rewriteStringLiteralCallSitesFast(
    LLVM::LLVMFuncOp func, const llvm::StringSet<> &slots) {
    if (func.isExternal() || !strLitCacheEnabled())
        return;

    auto *ctx = func.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto hptrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    // Collected first, because the rewrite erases each call.
    SmallVector<LLVM::CallOp> sites;
    func.walk([&](LLVM::CallOp call) {
        auto callee = call.getCallee();
        if (!callee || !isStringLiteralAllocCallee(*callee))
            return;
        if (call->getNumOperands() != 2 || call->getNumResults() != 1)
            return;
        if (call->getResult(0).getType() != hptrTy)
            return;
        auto addrOf = call->getOperand(0).getDefiningOp<LLVM::AddressOfOp>();
        if (!addrOf || !addrOf.getGlobalName().starts_with("__eco_str_"))
            return;
        std::string slotName = ("__eco_strlit$" + addrOf.getGlobalName()).str();
        if (!slots.contains(slotName))
            return;
        sites.push_back(call);
    });

    for (LLVM::CallOp call : sites) {
        auto loc = call.getLoc();
        auto addrOf = call->getOperand(0).getDefiningOp<LLVM::AddressOfOp>();
        std::string slotName = ("__eco_strlit$" + addrOf.getGlobalName()).str();
        StringRef fillName = *call.getCallee() == "eco_alloc_string_literal_utf8"
                                 ? "eco_string_literal_utf8_fill"
                                 : "eco_string_literal_fill";
        Value bytes = call->getOperand(0);
        Value len = call->getOperand(1);

        OpBuilder bb(call);
        auto slotAddr = bb.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
        auto bits = bb.create<LLVM::LoadOp>(loc, i64Ty, slotAddr);
        auto zero = bb.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        auto isSet =
            bb.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, bits, zero);
        auto ifOp = bb.create<scf::IfOp>(loc, TypeRange{hptrTy}, isSet,
                                         /*withElseRegion=*/true);
        {
            OpBuilder hb = OpBuilder::atBlockBegin(ifOp.thenBlock());
            Value cached = globalLoadI64ToValue(hb, loc, bits);
            hb.create<scf::YieldOp>(loc, ValueRange{cached});
        }
        {
            OpBuilder mb = OpBuilder::atBlockEnd(ifOp.elseBlock());
            auto fill = mb.create<LLVM::CallOp>(loc, TypeRange{hptrTy}, fillName,
                                                ValueRange{bytes, len, slotAddr});
            mb.create<scf::YieldOp>(loc, ValueRange{fill.getResult()});
        }

        call->getResult(0).replaceAllUsesWith(ifOp.getResult(0));
        call->erase();
    }
}
