//===- EcoToLLVMGlobals.cpp - Global variable lowering patterns -----------===//
//
// This file implements lowering patterns for ECO global variable operations:
// global, load_global, store_global, type_table, and the global root
// initialization function.
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

struct GlobalOpLowering : public OpConversionPattern<GlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(GlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);

        // eco.value becomes i64 (tagged pointer)
        // Create an LLVM global initialized to 0 (null)
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

struct LoadGlobalOpLowering : public OpConversionPattern<LoadGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(LoadGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Load i64 from global then convert to ptr<1>
        auto loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, globalAddr);
        Value result = globalLoadI64ToValue(rewriter, loc, loadedValue.getResult());

        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.store_global -> LLVM store to global address
//===----------------------------------------------------------------------===//

struct StoreGlobalOpLowering : public OpConversionPattern<StoreGlobalOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(StoreGlobalOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Get address of global
        auto globalAddr = rewriter.create<LLVM::AddressOfOp>(
            loc, ptrTy, op.getGlobal());

        // Convert ptr<1> to i64 for global storage
        Value valI64 = globalStoreValueToI64(rewriter, loc, adaptor.getValue());
        rewriter.create<LLVM::StoreOp>(loc, valI64, globalAddr);

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.type_table -> LLVM globals for type graph
//===----------------------------------------------------------------------===//

struct TypeTableOpLowering : public OpConversionPattern<TypeTableOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(TypeTableOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto module = op->getParentOfType<ModuleOp>();

        // Check if global already exists
        if (module.lookupSymbol("__eco_type_graph")) {
            rewriter.eraseOp(op);
            return success();
        }

        // Get LLVM types
        auto i8Ty = IntegerType::get(ctx, 8);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        // Struct byte layouts (emitted directly as byte blobs below, not as
        // LLVM struct-array globals):
        //   EcoTypeInfo  = 20 bytes {u32 type_id, u8 kind, u8 pad[3], u8 data[12]}
        //   EcoFieldInfo =  8 bytes {u32 name_index, u32 type_id}
        //   EcoCtorInfo  = 16 bytes {u32 ctor_id, u32 name_index, u32 first_field, u32 field_count}

        // EcoTypeGraph: 80 bytes
        auto typeGraphTy = LLVM::LLVMStructType::getLiteral(ctx, {
            ptrTy, i32Ty, i32Ty,  // types, type_count, padding1
            ptrTy, i32Ty, i32Ty,  // fields, field_count, padding2
            ptrTy, i32Ty, i32Ty,  // ctors, ctor_count, padding3
            ptrTy, i32Ty, i32Ty,  // func_args, func_arg_count, padding4
            ptrTy, i32Ty, i32Ty   // strings, string_count, padding5
        });

        // Extract arrays from op attributes
        auto typesAttr = op.getTypes();
        auto fieldsAttr = op.getFields();
        auto ctorsAttr = op.getCtors();
        auto funcArgsAttr = op.getFuncArgs();
        auto stringsAttr = op.getStrings();

        // Save insertion point and move to module level for global creation
        OpBuilder::InsertionGuard guard(rewriter);
        rewriter.setInsertionPointToStart(module.getBody());

        // The types/fields/ctors/func_args arrays are fully compile-time-known
        // byte data (arrays of POD structs / u32s with no pointer fields). We
        // emit each as a single `[N x i8]` global with a raw little-endian
        // byte-blob StringAttr initializer instead of a chain of
        // insertvalue/ZeroOp ops. This avoids the O(entries*fields) MLIR op
        // count AND LLVM's quadratic ConstantFoldInsertValueInstruction during
        // MLIR->LLVM-IR translation (each insertvalue re-copies the aggregate).
        // The struct layouts have no internal padding beyond explicit pad
        // fields (EcoTypeInfo=20B {u32,u8,pad[3],u8[12]}, EcoFieldInfo=8B
        // {u32,u32}, EcoCtorInfo=16B {4xu32}), so the packed byte sequence is
        // ABI-identical to the array-of-structs form. Alignment is set
        // explicitly (an [N x i8] global would otherwise be 1-aligned, but the
        // runtime reads these via u32-containing struct pointers).
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

        // Create strings global array
        uint32_t stringCount = 0;
        LLVM::GlobalOp stringsGlobal = nullptr;
        if (stringsAttr && !stringsAttr->empty()) {
            stringCount = stringsAttr->size();
            // Create individual string globals and then an array of pointers
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

            // Create array of string pointers
            auto strPtrArrayTy = LLVM::LLVMArrayType::get(ptrTy, stringCount);
            stringsGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, strPtrArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_strings_array",
                Attribute());

            // Add initializer region for string pointer array
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

        // Create func_args global array
        uint32_t funcArgCount = 0;
        LLVM::GlobalOp funcArgsGlobal = nullptr;
        if (funcArgsAttr && !funcArgsAttr->empty()) {
            funcArgCount = funcArgsAttr->size();
            // Array of u32 -> 4 LE bytes each.
            std::string bytes;
            bytes.reserve(funcArgCount * 4);
            for (size_t i = 0; i < funcArgCount; i++) {
                auto intAttr = llvm::dyn_cast<IntegerAttr>((*funcArgsAttr)[i]);
                appendU32(bytes, intAttr ? intAttr.getInt() : 0);
            }
            funcArgsGlobal =
                emitByteBlobGlobal("__eco_func_args_array", bytes, /*align=*/4);
        }

        // Create ctors global array
        uint32_t ctorCount = 0;
        LLVM::GlobalOp ctorsGlobal = nullptr;
        if (ctorsAttr && !ctorsAttr->empty()) {
            ctorCount = ctorsAttr->size();
            // EcoCtorInfo = 16 bytes {u32 ctor_id, u32 name_index,
            // u32 first_field, u32 field_count}. Entries with a malformed
            // descriptor become 16 zero bytes (the old code left them undef).
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

        // Create fields global array
        uint32_t fieldCount = 0;
        LLVM::GlobalOp fieldsGlobal = nullptr;
        if (fieldsAttr && !fieldsAttr->empty()) {
            fieldCount = fieldsAttr->size();
            // EcoFieldInfo = 8 bytes {u32 name_index, u32 type_id}.
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

        // Create types global array
        uint32_t typeCount = 0;
        LLVM::GlobalOp typesGlobal = nullptr;
        if (typesAttr && !typesAttr->empty()) {
            typeCount = typesAttr->size();
            // EcoTypeInfo = 20 bytes {u32 type_id @0, u8 kind @4, u8 pad[3] @5,
            // u8 data[12] @8}. The per-kind data union layout below mirrors the
            // original insertvalue lowering byte-for-byte (all little-endian).
            std::string bytes;
            bytes.reserve(typeCount * 20);
            for (size_t i = 0; i < typeCount; i++) {
                auto typeArr = llvm::dyn_cast<ArrayAttr>((*typesAttr)[i]);
                if (!typeArr || typeArr.size() < 3) {
                    // Old code left such entries undef; deterministic zeros are
                    // ABI-safe (invalid entries are never dereferenced).
                    bytes.append(20, '\0');
                    continue;
                }

                uint32_t typeId = static_cast<uint32_t>(intAt(typeArr, 0));
                uint8_t kind = static_cast<uint8_t>(intAt(typeArr, 1));

                // 12-byte data union, zero-initialised then filled per kind.
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
                }

                appendU32(bytes, typeId);       // type_id @0..4
                bytes.push_back(char(kind));    // kind    @4
                bytes.append(3, '\0');          // pad     @5..8
                bytes.append(data, 12);         // data    @8..20
            }
            typesGlobal =
                emitByteBlobGlobal("__eco_types_array", bytes, /*align=*/8);
        }

        // Create the main __eco_type_graph global with initializer region
        auto typeGraphGlobal = rewriter.create<LLVM::GlobalOp>(
            loc, typeGraphTy, /*isConstant=*/true,
            LLVM::Linkage::External, "__eco_type_graph",
            Attribute());

        Block *graphInitBlock = rewriter.createBlock(&typeGraphGlobal.getInitializerRegion());
        rewriter.setInsertionPointToStart(graphInitBlock);

        auto zero32 = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);
        auto nullPtr = rewriter.create<LLVM::ZeroOp>(loc, ptrTy);

        Value structVal = rewriter.create<LLVM::UndefOp>(loc, typeGraphTy);

        // types pointer
        if (typesGlobal) {
            auto typesAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, typesGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, typesAddr, ArrayRef<int64_t>{0});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{0});
        }
        auto typeCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)typeCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, typeCountCst, ArrayRef<int64_t>{1});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{2}); // padding

        // fields pointer
        if (fieldsGlobal) {
            auto fieldsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, fieldsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, fieldsAddr, ArrayRef<int64_t>{3});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{3});
        }
        auto fieldCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)fieldCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, fieldCountCst, ArrayRef<int64_t>{4});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{5}); // padding

        // ctors pointer
        if (ctorsGlobal) {
            auto ctorsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, ctorsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, ctorsAddr, ArrayRef<int64_t>{6});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{6});
        }
        auto ctorCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)ctorCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, ctorCountCst, ArrayRef<int64_t>{7});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{8}); // padding

        // func_args pointer
        if (funcArgsGlobal) {
            auto funcArgsAddr = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, funcArgsGlobal.getSymName());
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, funcArgsAddr, ArrayRef<int64_t>{9});
        } else {
            structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, nullPtr, ArrayRef<int64_t>{9});
        }
        auto funcArgCountCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, (int64_t)funcArgCount);
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, funcArgCountCst, ArrayRef<int64_t>{10});
        structVal = rewriter.create<LLVM::InsertValueOp>(loc, structVal, zero32, ArrayRef<int64_t>{11}); // padding

        // strings pointer
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

    // Collect all internal LLVM globals (these came from eco.global) EXCEPT
    // CAF memo slots: those are never pre-registered — eco_caf_promote roots
    // a slot at first evaluation exactly when its value stays heap-resident
    // (declined promotion or ECO_CAF_PERMANENT=0). Pre-registering all of
    // them left every never-evaluated slot (61 % on the self-compile
    // workload) in the JIT root set forever, holding 0, swept every minor.
    SmallVector<LLVM::GlobalOp> ecoGlobals;
    // Globals are top-level only: iterate the module body, not a recursive
    // walk over every op (plans/backend-lowering-optimization.md B8).
    llvm::for_each(module.getOps<LLVM::GlobalOp>(), [&](LLVM::GlobalOp globalOp) {
        // eco.global creates internal linkage globals with i64 type
        if (globalOp.getLinkage() == LLVM::Linkage::Internal &&
            globalOp.getGlobalType().isInteger(64) &&
            !globalOp.getSymName().starts_with("__eco_caf$") &&
            // LSS step 18b string-literal cache slots: only ever hold a
            // PermanentSpace word (eco_string_literal*_fill publishes nothing
            // else), which is immortal and never moves, so the slot needs no
            // root and no fixup. Same reasoning as __eco_caf$ above.
            !globalOp.getSymName().starts_with("__eco_strlit$")) {
            ecoGlobals.push_back(globalOp);
        }
    });

    // Check if type graph exists
    LLVM::GlobalOp typeGraphGlobal = nullptr;
    if (auto sym = module.lookupSymbol<LLVM::GlobalOp>("__eco_type_graph")) {
        typeGraphGlobal = sym;
    }

    // Skip if there's nothing to initialize
    if (ecoGlobals.empty() && !typeGraphGlobal)
        return;

    auto *ctx = runtime.ctx;
    auto loc = module.getLoc();
    OpBuilder builder(ctx);
    builder.setInsertionPointToEnd(module.getBody());

    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);

    // Create the __eco_init_globals function
    // Use External linkage so the JIT can look it up by name
    auto initFuncType = LLVM::LLVMFunctionType::get(voidTy, {});
    auto initFunc = builder.create<LLVM::LLVMFuncOp>(
        loc, "__eco_init_globals", initFuncType);
    initFunc.setLinkage(LLVM::Linkage::External);

    // Create the function body
    Block *entryBlock = initFunc.addEntryBlock(builder);
    builder.setInsertionPointToStart(entryBlock);

    // Register the type graph if it exists
    if (typeGraphGlobal) {
        auto regFunc = runtime.getOrCreateRegisterTypeGraph(builder);
        auto typeGraphAddr = builder.create<LLVM::AddressOfOp>(
            loc, ptrTy, typeGraphGlobal.getSymName());
        builder.create<LLVM::CallOp>(loc, regFunc, ValueRange{typeGraphAddr});
    }

    // Call eco_gc_add_root for each global
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
// CAF memoization guard (plans/caf-memoization-implementation.md, CGEN_068)
//
// A func.func tagged `eco.caf_memo` is a nullary value thunk (arity 0,
// !eco.value result). Wrap it so its body runs at most once per process:
//
//   entry:  %bits = load i64 from @__eco_caf$<name>
//           cond_br (%bits != 0), ^hit, ^body
//   ^hit:   return __eco_slot_to_hptr(%bits)      ; barrier, REP_LLVM_002
//   ^body:  <original body>
//           ; every llvm.return %r becomes:
//           store __eco_hptr_to_slot(%r), @slot ; return %r
//
// Slot value 0 = uninitialized: no valid !eco.value word is 0 (heap pointers
// are nonzero addresses; embedded constants are 0x4/0x5/0x6). The hit path
// contains no statepoint, and each publish store sits immediately before its
// return (CGEN_067 discipline), so no pointer-provenance i64 is live across
// a statepoint. The slot itself is an eco.global-lowered internal i64 global
// that is NOT pre-registered as a GC root (createGlobalRootInitFunction
// skips __eco_caf$): eco_caf_promote on the miss path either moves the value
// into the permanent space (slot never needs GC attention) or registers the
// slot as a JIT root when the value stays heap-resident (HEAP_036).
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

    // Shape check: nullary thunk returning ptr addrspace(1) (the converted
    // !eco.value). The Elm side only stamps such thunks; anything else here
    // is a compiler bug.
    auto fnTy = func.getFunctionType();
    if (fnTy.getNumParams() != 0 || fnTy.getReturnType() != hptrTy)
        return func.emitError(
            "eco.caf_memo on a non-thunk or non-!eco.value function");

    std::string slotName = ("__eco_caf$" + func.getSymName()).str();

    OpBuilder builder(ctx);

    // Declare the promotion hook once per module: gc-leaf (never triggers
    // GC, never re-enters Elm), so RS4GC adds no statepoint and the
    // barrier-i64 crossing it is the authorized store-helper→gc-leaf-arg
    // pattern (EcoPtrIntVerify pattern 2; the return value is pattern 4).
    if (!promoteDeclared)
        declareCafPromote(func->getParentOfType<ModuleOp>(), loc);
    promoteDeclared = true;

    // 1. Instrument every existing return FIRST, so the hit-path return
    //    created below is not instrumented. The miss path routes the value
    //    through eco_caf_promote (ECO_CAF_PERMANENT=1 deep-copies it into
    //    the permanent space and deregisters the slot; default-off returns
    //    it unchanged) and returns the PROMOTED value, so the first caller
    //    shares the permanent copy instead of keeping a heap duplicate.
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

    // 2. New entry block (guard) + hit block. The thunk has no parameters,
    //    so the new entry block carries no arguments.
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
// CAF caller-side fast path (benchmarks/runtime-calls.md Run W)
//
// Rewrite each zero-arg call to a caf_memo thunk:
//
//   %v = llvm.call @thunk()           ; always a call, even on cache hits
//
// into a diamond whose hit edge never calls:
//
//   %bits  = llvm.load @__eco_caf$thunk
//   %isset = llvm.icmp ne %bits, 0
//   llvm.cond_br %isset, ^hit, ^miss
//   ^hit:  %cached = __eco_slot_to_hptr(%bits)   ; barrier → bare cast post-RS4GC
//          llvm.br ^merge(%cached)
//   ^miss: %computed = llvm.call @thunk()        ; publishes via the callee guard
//          llvm.br ^merge(%computed)
//   ^merge(%v: ptr<1>): ...original continuation...
//
// Motivation (Run V): a statepointed call on the hit path loses to
// HEAP_034 inline construction for small values; load+icmp+branch wins.
// GC-safety: the load/branch carry no gc pointers; the barrier form is the
// REP_LLVM_002 slot-crossing; the merge block-arg is ordinary tracked
// ptr<1> SSA. Pre-RS4GC, serial phase.
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

    // Collect first: block splitting below relocates later ops (their
    // Operation*s stay valid; getBlock() is re-read at rewrite time).
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

        // The diamond is built as an scf.if EXPRESSION, not block surgery:
        // post-Stage-2 bodies still contain scf.if/scf.while regions whose
        // single-block constraint block-splitting would violate (the P2.5
        // expandGetTagMarkers lesson). scf lowers to CFG later in the
        // backend pipeline, in every region kind uniformly.
        OpBuilder bb(call);
        auto addr = bb.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
        auto bits = bb.create<LLVM::LoadOp>(loc, i64Ty, addr);
        auto zero = bb.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        auto isSet =
            bb.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, bits, zero);

        auto ifOp = bb.create<scf::IfOp>(loc, TypeRange{hptrTy}, isSet,
                                         /*withElseRegion=*/true);

        // Hit arm: barrier-cast the cached word.
        {
            OpBuilder hb = OpBuilder::atBlockBegin(ifOp.thenBlock());
            Value cached = globalLoadI64ToValue(hb, loc, bits);
            hb.create<scf::YieldOp>(loc, ValueRange{cached});
        }

        // Miss arm: the ORIGINAL call (its callee guard publishes).
        call->getResult(0).replaceAllUsesWith(ifOp.getResult(0));
        call->moveBefore(ifOp.elseBlock(), ifOp.elseBlock()->end());
        {
            OpBuilder mb = OpBuilder::atBlockEnd(ifOp.elseBlock());
            mb.create<scf::YieldOp>(loc, ValueRange{call->getResult(0)});
        }
    }
}

//===----------------------------------------------------------------------===//
// String-literal interning cache (LSS compile-time loop, step 18b)
//
// Every evaluation of a string literal — `"Int"` in a `case name of` arm as
// much as a literal in ordinary code — lowers to
//
//   %s = llvm.call @eco_alloc_string_literal_utf8(@__eco_str_N, len)
//
// and that call is NOT gc-leaf (its miss path allocates), so RS4GC statepoints
// it: every live ptr addrspace(1) in the function is spilled and reloaded
// around what is, after the first evaluation, a hash-table lookup returning a
// pointer that can never change. `eco_alloc_string_literal_utf8` alone was
// 0.60 % of a self-compile's samples (1.22 % of the monomorphization window)
// before this, and the statepoint traffic it forces on its callers is not in
// that figure.
//
// The fix is the CAF caller-side fast path (Run W) applied per literal: give
// each literal global a zero-initialised i64 sibling slot and branch on it.
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
// Built as an scf.if EXPRESSION rather than block surgery for the same reason
// rewriteCafCallSitesFast is: post-Stage-2 bodies still contain scf regions
// whose single-block constraint splitting would violate.
//
// GC-safety, point by point:
//   - the slot is written ONLY by the runtime, ONLY with a PermanentSpace word
//     (HEAP_036: immortal, GC-invisible, never moves), so it is not a root and
//     needs no fixup — createGlobalRootInitFunction skips the prefix;
//   - the hit arm's i64 -> ptr<1> crossing is globalLoadI64ToValue, the
//     REP_LLVM_002 barrier form, identical to the CAF hit arm;
//   - the load/icmp/branch carry no gc pointers, and the merge value is
//     ordinary tracked ptr<1> SSA;
//   - slot value 0 is reserved as "unpublished": no valid word is 0 (HEAP_044).
//
// ECO_STRLIT_CACHE=0 restores the bare call at every site.
//===----------------------------------------------------------------------===//

static bool strLitCacheEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_STRLIT_CACHE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

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

    // Collect first (module order, so slot emission is deterministic), then
    // insert: we are appending to the very block being iterated.
    // `slots` doubles as the existence check below: one module pass instead of
    // a linear module.lookupSymbol per literal (quadratic at self-host scale).
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

    // The cold-edge twins. Declared here (serial, module mutation re-enabled)
    // rather than in materializeAllRuntimeDecls so the escape hatch leaves no
    // trace; the unused-decl strip removes them from modules with no literals.
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

    // Collect first: creating the scf.if relocates later ops.
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
        // Only rewrite when the slot was pre-materialized; a literal whose
        // global this pass never saw keeps the plain call.
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
