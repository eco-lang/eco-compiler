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

        // Load the value (i64 tagged pointer)
        auto loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, globalAddr);

        rewriter.replaceOp(op, loadedValue.getResult());
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

        // Store the value (already converted to i64)
        rewriter.create<LLVM::StoreOp>(loc, adaptor.getValue(), globalAddr);

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

        // EcoTypeInfo: 20 bytes
        // { uint32_t type_id, uint8_t kind, uint8_t padding[3], uint8_t data[12] }
        auto typeInfoTy = LLVM::LLVMStructType::getLiteral(ctx, {
            i32Ty,                                    // type_id
            i8Ty,                                     // kind
            LLVM::LLVMArrayType::get(i8Ty, 3),       // padding
            LLVM::LLVMArrayType::get(i8Ty, 12)       // data union
        });

        // EcoFieldInfo: 8 bytes { uint32_t name_index, uint32_t type_id }
        auto fieldInfoTy = LLVM::LLVMStructType::getLiteral(ctx, {i32Ty, i32Ty});

        // EcoCtorInfo: 16 bytes { uint32_t ctor_id, uint32_t name_index, uint32_t first_field, uint32_t field_count }
        auto ctorInfoTy = LLVM::LLVMStructType::getLiteral(ctx, {i32Ty, i32Ty, i32Ty, i32Ty});

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
            auto funcArgsArrayTy = LLVM::LLVMArrayType::get(i32Ty, funcArgCount);
            funcArgsGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, funcArgsArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_func_args_array",
                Attribute());

            Block *initBlock = rewriter.createBlock(&funcArgsGlobal.getInitializerRegion());
            rewriter.setInsertionPointToStart(initBlock);
            Value arr = rewriter.create<LLVM::UndefOp>(loc, funcArgsArrayTy);
            for (size_t i = 0; i < funcArgCount; i++) {
                auto intAttr = llvm::dyn_cast<IntegerAttr>((*funcArgsAttr)[i]);
                int64_t val = intAttr ? intAttr.getInt() : 0;
                auto cst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, val);
                arr = rewriter.create<LLVM::InsertValueOp>(loc, arr, cst, ArrayRef<int64_t>{(int64_t)i});
            }
            rewriter.create<LLVM::ReturnOp>(loc, arr);
            rewriter.setInsertionPointToStart(module.getBody());
        }

        // Create ctors global array
        uint32_t ctorCount = 0;
        LLVM::GlobalOp ctorsGlobal = nullptr;
        if (ctorsAttr && !ctorsAttr->empty()) {
            ctorCount = ctorsAttr->size();
            auto ctorsArrayTy = LLVM::LLVMArrayType::get(ctorInfoTy, ctorCount);
            ctorsGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, ctorsArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_ctors_array",
                Attribute());

            Block *initBlock = rewriter.createBlock(&ctorsGlobal.getInitializerRegion());
            rewriter.setInsertionPointToStart(initBlock);
            Value arr = rewriter.create<LLVM::UndefOp>(loc, ctorsArrayTy);
            for (size_t i = 0; i < ctorCount; i++) {
                auto ctorArr = llvm::dyn_cast<ArrayAttr>((*ctorsAttr)[i]);
                if (!ctorArr || ctorArr.size() < 4) continue;

                Value ctorVal = rewriter.create<LLVM::UndefOp>(loc, ctorInfoTy);
                for (size_t j = 0; j < 4; j++) {
                    auto intAttr = llvm::dyn_cast<IntegerAttr>(ctorArr[j]);
                    int64_t val = intAttr ? intAttr.getInt() : 0;
                    auto cst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, val);
                    ctorVal = rewriter.create<LLVM::InsertValueOp>(loc, ctorVal, cst, ArrayRef<int64_t>{(int64_t)j});
                }
                arr = rewriter.create<LLVM::InsertValueOp>(loc, arr, ctorVal, ArrayRef<int64_t>{(int64_t)i});
            }
            rewriter.create<LLVM::ReturnOp>(loc, arr);
            rewriter.setInsertionPointToStart(module.getBody());
        }

        // Create fields global array
        uint32_t fieldCount = 0;
        LLVM::GlobalOp fieldsGlobal = nullptr;
        if (fieldsAttr && !fieldsAttr->empty()) {
            fieldCount = fieldsAttr->size();
            auto fieldsArrayTy = LLVM::LLVMArrayType::get(fieldInfoTy, fieldCount);
            fieldsGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, fieldsArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_fields_array",
                Attribute());

            Block *initBlock = rewriter.createBlock(&fieldsGlobal.getInitializerRegion());
            rewriter.setInsertionPointToStart(initBlock);
            Value arr = rewriter.create<LLVM::UndefOp>(loc, fieldsArrayTy);
            for (size_t i = 0; i < fieldCount; i++) {
                auto fieldArr = llvm::dyn_cast<ArrayAttr>((*fieldsAttr)[i]);
                if (!fieldArr || fieldArr.size() < 2) continue;

                Value fieldVal = rewriter.create<LLVM::UndefOp>(loc, fieldInfoTy);
                for (size_t j = 0; j < 2; j++) {
                    auto intAttr = llvm::dyn_cast<IntegerAttr>(fieldArr[j]);
                    int64_t val = intAttr ? intAttr.getInt() : 0;
                    auto cst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, val);
                    fieldVal = rewriter.create<LLVM::InsertValueOp>(loc, fieldVal, cst, ArrayRef<int64_t>{(int64_t)j});
                }
                arr = rewriter.create<LLVM::InsertValueOp>(loc, arr, fieldVal, ArrayRef<int64_t>{(int64_t)i});
            }
            rewriter.create<LLVM::ReturnOp>(loc, arr);
            rewriter.setInsertionPointToStart(module.getBody());
        }

        // Create types global array
        uint32_t typeCount = 0;
        LLVM::GlobalOp typesGlobal = nullptr;
        if (typesAttr && !typesAttr->empty()) {
            typeCount = typesAttr->size();
            auto typesArrayTy = LLVM::LLVMArrayType::get(typeInfoTy, typeCount);
            typesGlobal = rewriter.create<LLVM::GlobalOp>(
                loc, typesArrayTy, /*isConstant=*/true,
                LLVM::Linkage::Private, "__eco_types_array",
                Attribute());

            Block *initBlock = rewriter.createBlock(&typesGlobal.getInitializerRegion());
            rewriter.setInsertionPointToStart(initBlock);
            Value arr = rewriter.create<LLVM::UndefOp>(loc, typesArrayTy);

            auto zeroI8Array3 = LLVM::LLVMArrayType::get(i8Ty, 3);
            auto zeroI8Array12 = LLVM::LLVMArrayType::get(i8Ty, 12);

            for (size_t i = 0; i < typeCount; i++) {
                auto typeArr = llvm::dyn_cast<ArrayAttr>((*typesAttr)[i]);
                if (!typeArr || typeArr.size() < 3) continue;

                // Parse type descriptor: [typeId, kind, ...kind-specific-data]
                auto typeIdAttr = llvm::dyn_cast<IntegerAttr>(typeArr[0]);
                auto kindAttr = llvm::dyn_cast<IntegerAttr>(typeArr[1]);
                int64_t typeId = typeIdAttr ? typeIdAttr.getInt() : 0;
                int64_t kind = kindAttr ? kindAttr.getInt() : 0;

                Value typeVal = rewriter.create<LLVM::UndefOp>(loc, typeInfoTy);

                // Set type_id
                auto typeIdCst = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, typeId);
                typeVal = rewriter.create<LLVM::InsertValueOp>(loc, typeVal, typeIdCst, ArrayRef<int64_t>{0});

                // Set kind
                auto kindCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, kind);
                typeVal = rewriter.create<LLVM::InsertValueOp>(loc, typeVal, kindCst, ArrayRef<int64_t>{1});

                // Set padding to zeros
                Value paddingArr = rewriter.create<LLVM::ZeroOp>(loc, zeroI8Array3);
                typeVal = rewriter.create<LLVM::InsertValueOp>(loc, typeVal, paddingArr, ArrayRef<int64_t>{2});

                // Build the 12-byte data union based on kind
                Value dataArr = rewriter.create<LLVM::ZeroOp>(loc, zeroI8Array12);

                switch (kind) {
                case 0: // Primitive: prim_kind at offset 0
                    if (typeArr.size() >= 3) {
                        auto primKindAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        int64_t primKind = primKindAttr ? primKindAttr.getInt() : 0;
                        auto primKindCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, primKind);
                        dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, primKindCst, ArrayRef<int64_t>{0});
                    }
                    break;

                case 1: // List: elem_type_id (uint32) at offset 0
                    if (typeArr.size() >= 3) {
                        auto elemTypeIdAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        int64_t elemTypeId = elemTypeIdAttr ? elemTypeIdAttr.getInt() : 0;
                        // Store as 4 bytes little-endian
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (elemTypeId >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)b});
                        }
                    }
                    break;

                case 2: // Tuple: arity (u16), padding (u16), first_field (u32)
                    if (typeArr.size() >= 5) {
                        auto arityAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        auto firstFieldAttr = llvm::dyn_cast<IntegerAttr>(typeArr[3]);
                        int64_t arity = arityAttr ? arityAttr.getInt() : 0;
                        int64_t firstField = firstFieldAttr ? firstFieldAttr.getInt() : 0;
                        // arity as 2 bytes
                        for (int b = 0; b < 2; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (arity >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)b});
                        }
                        // first_field as 4 bytes at offset 4
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (firstField >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)(4 + b)});
                        }
                    }
                    break;

                case 3: // Record: first_field (u32), field_count (u32)
                    if (typeArr.size() >= 4) {
                        auto firstFieldAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        auto fieldCountAttr = llvm::dyn_cast<IntegerAttr>(typeArr[3]);
                        int64_t firstField = firstFieldAttr ? firstFieldAttr.getInt() : 0;
                        int64_t fldCount = fieldCountAttr ? fieldCountAttr.getInt() : 0;
                        // first_field as 4 bytes
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (firstField >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)b});
                        }
                        // field_count as 4 bytes
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (fldCount >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)(4 + b)});
                        }
                    }
                    break;

                case 4: // Custom: first_ctor (u32), ctor_count (u32)
                    if (typeArr.size() >= 4) {
                        auto firstCtorAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        auto ctorCountAttr = llvm::dyn_cast<IntegerAttr>(typeArr[3]);
                        int64_t firstCtor = firstCtorAttr ? firstCtorAttr.getInt() : 0;
                        int64_t cCount = ctorCountAttr ? ctorCountAttr.getInt() : 0;
                        // first_ctor as 4 bytes
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (firstCtor >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)b});
                        }
                        // ctor_count as 4 bytes
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (cCount >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)(4 + b)});
                        }
                    }
                    break;

                case 5: // Function: first_arg_type (u32), arg_count (u16), padding (u16), result_type_id (u32)
                    if (typeArr.size() >= 5) {
                        auto firstArgTypeAttr = llvm::dyn_cast<IntegerAttr>(typeArr[2]);
                        auto argCountAttr = llvm::dyn_cast<IntegerAttr>(typeArr[3]);
                        auto resultTypeIdAttr = llvm::dyn_cast<IntegerAttr>(typeArr[4]);
                        int64_t firstArgType = firstArgTypeAttr ? firstArgTypeAttr.getInt() : 0;
                        int64_t argCount = argCountAttr ? argCountAttr.getInt() : 0;
                        int64_t resultTypeId = resultTypeIdAttr ? resultTypeIdAttr.getInt() : 0;
                        // first_arg_type as 4 bytes
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (firstArgType >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)b});
                        }
                        // arg_count as 2 bytes
                        for (int b = 0; b < 2; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (argCount >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)(4 + b)});
                        }
                        // result_type_id as 4 bytes at offset 8
                        for (int b = 0; b < 4; b++) {
                            auto byteCst = rewriter.create<LLVM::ConstantOp>(loc, i8Ty, (resultTypeId >> (b * 8)) & 0xFF);
                            dataArr = rewriter.create<LLVM::InsertValueOp>(loc, dataArr, byteCst, ArrayRef<int64_t>{(int64_t)(8 + b)});
                        }
                    }
                    break;
                }

                typeVal = rewriter.create<LLVM::InsertValueOp>(loc, typeVal, dataArr, ArrayRef<int64_t>{3});
                arr = rewriter.create<LLVM::InsertValueOp>(loc, arr, typeVal, ArrayRef<int64_t>{(int64_t)i});
            }
            rewriter.create<LLVM::ReturnOp>(loc, arr);
            rewriter.setInsertionPointToStart(module.getBody());
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

    // Collect all internal LLVM globals (these came from eco.global)
    SmallVector<LLVM::GlobalOp> ecoGlobals;
    module.walk([&](LLVM::GlobalOp globalOp) {
        // eco.global creates internal linkage globals with i64 type
        if (globalOp.getLinkage() == LLVM::Linkage::Internal &&
            globalOp.getGlobalType().isInteger(64)) {
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
