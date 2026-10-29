//===- EcoToLLVMTypes.cpp - Type and constant lowering patterns -----------===//
//
// The eco-to-llvm conversion patterns for the operations that produce an Elm value without allocating a new
// object: `eco.constant`, `eco.constant.null_cons` and `eco.string_literal`.
//
// The two constant operations need no heap object at all. An embedded constant (False, True, or Empty, which
// stands for Unit, Nil, Nothing and the empty String among others) and a null-cons word (a nullary constructor
// with its declaration index in bits 43-52) are HPointer words that are not addresses, so each lowers to an
// `i64` constant converted by `inttoptr` to `ptr addrspace(1)`. The words come from `value_enc::encodeConstant`
// and `value_enc::encodeNullCons` in EcoToLLVMInternal.h, which own the encoding.
//
// A non-empty string literal does need an object, built at run time by a runtime call from a constant global
// `__eco_str_N`. The empty literal is the Empty constant and has no global. The rest of the file follows from
// one constraint: the body conversion runs in parallel and may not create module-level symbols, so every
// global is created beforehand, serially, by `preMaterializeStringLiterals`, which records each literal's N in
// `EcoRuntime::stringLiteralIndexForOp` for the pattern to read. A literal whose bytes are all below 0x80 is
// stored as `[L x i8]` and built by `eco_alloc_string_literal_utf8`; any other is converted to UTF-16, stored
// as `[L x i16]`, and built by `eco_alloc_string_literal`. Both halves choose with `isAsciiLiteral`, which
// looks only at the bytes, so they agree without sharing any state.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

namespace {

//===----------------------------------------------------------------------===//
// eco.constant -> inttoptr of the embedded-constant word
//===----------------------------------------------------------------------===//

/**
 * The pattern that lowers `eco.constant` to its embedded-constant word as a `ptr addrspace(1)`.
 *
 * The op's kind is passed to `encodeConstant` unchecked.
 */
struct ConstantOpLowering : public OpConversionPattern<ConstantOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConstantOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto hptrTy = getHPtrLLVMType(*ctx);

        int64_t kindValue = static_cast<int64_t>(op.getKind());
        int64_t encoded = value_enc::encodeConstant(kindValue);

        Value i64Val = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
        Value result = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, i64Val);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.constant.null_cons -> inttoptr of the null-cons word (HEAP_044)
//===----------------------------------------------------------------------===//

/**
 * The pattern that lowers `eco.constant.null_cons` to the null-cons word of its declaration index, as a
 * `ptr addrspace(1)`.
 *
 * An index below 0 or above `value_enc::NullConsMax` aborts the compiler with `report_fatal_error`.
 */
struct ConstantNullConsOpLowering
    : public OpConversionPattern<ConstantNullConsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ConstantNullConsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto hptrTy = getHPtrLLVMType(*ctx);

        // The op verifier already rejects this range; the check here does not depend on verification having
        // run.
        int64_t tag = op.getTag();
        if (tag < 0 || tag > static_cast<int64_t>(value_enc::NullConsMax))
            llvm::report_fatal_error(
                "eco.constant.null_cons: ctor index exceeds the 10-bit "
                "null_cons_idx capacity (HEAP_044)");
        int64_t encoded =
            value_enc::encodeNullCons(static_cast<uint64_t>(tag));

        Value i64Val = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
        Value result = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, i64Val);
        rewriter.replaceOp(op, result);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.string_literal -> call eco_alloc_string_literal[_utf8]
//===----------------------------------------------------------------------===//

// Returns whether every byte of `s` is below 0x80, which decides whether a literal's global holds bytes or
// UTF-16 code units.
//
// `isAsciiCasePattern` in EcoToLLVMControlFlow.cpp is a separate copy of the same test for string-case
// patterns. Nothing ties the two together.
static bool isAsciiLiteral(llvm::StringRef s) {
    for (char c : s)
        if (static_cast<unsigned char>(c) & 0x80) return false;
    return true;
}

/**
 * The pattern that lowers a non-empty `eco.string_literal` to a call that builds the String from its global
 * `__eco_str_N`, and the empty literal to the Empty constant.
 *
 * The global must already exist: `preMaterializeStringLiterals` must have run on this `EcoRuntime` for the
 * literal's function. Otherwise an assertion fails in builds with assertions on, and with them off the
 * lookup dereferences the map's end iterator.
 */
struct StringLiteralOpLowering : public OpConversionPattern<StringLiteralOp> {
    // The runtime whose index map and runtime-function declarations the pattern uses. It must outlive the
    // pattern.
    const EcoRuntime &runtime;

    // Creates the pattern; `runtime` must outlive it.
    StringLiteralOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                            const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringLiteralOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        StringRef value = op.getValue();

        auto hptrTy = getHPtrLLVMType(*ctx);

        if (value.empty()) {
            int64_t encoded = value_enc::encodeConstant(value_enc::Empty);
            Value i64Val = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, encoded);
            Value result = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, i64Val);
            rewriter.replaceOp(op, result);
            return success();
        }

        // Only read here: the module's symbol table must not change while bodies are converted in parallel.
        auto idxIt = runtime.stringLiteralIndexForOp.find(op.getOperation());
        assert(idxIt != runtime.stringLiteralIndexForOp.end() &&
               "string-literal global not pre-materialized");
        std::string globalName = "__eco_str_" + std::to_string(idxIt->second);
        auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

        if (isAsciiLiteral(value)) {
            auto func = runtime.getOrCreateAllocStringLiteralUtf8(rewriter);
            auto lenVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                static_cast<int32_t>(value.size()));
            auto call = rewriter.create<LLVM::CallOp>(loc, func,
                ValueRange{addrOf, lenVal});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        std::vector<uint16_t> utf16 = utf8ToUtf16(value);
        size_t length = utf16.size();
        auto func = runtime.getOrCreateAllocStringLiteral(rewriter);
        auto lengthVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
            static_cast<int32_t>(length));
        auto call = rewriter.create<LLVM::CallOp>(loc, func,
            ValueRange{addrOf, lengthVal});

        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoTypePatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime) {

    auto *ctx = patterns.getContext();
    patterns.add<ConstantOpLowering>(typeConverter, ctx);
    patterns.add<ConstantNullConsOpLowering>(typeConverter, ctx);
    patterns.add<StringLiteralOpLowering>(typeConverter, ctx, runtime);
}

// The only place `stringLiteralCounter` is advanced, so N follows the order of `demand` alone.
void eco::detail::preMaterializeStringLiterals(
    OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<PreMatDemand> demand) {
    auto *ctx = builder.getContext();
    auto utf16UnitTy = getU16StorageType(ctx);  // String unit, not Char
    auto i8Ty = IntegerType::get(ctx, 8);
    auto visit = [&](StringLiteralOp op) {
        StringRef value = op.getValue();
        if (value.empty())
            return;  // empty string is an embedded constant; no global
        uint64_t index = runtime.stringLiteralCounter++;
        runtime.stringLiteralIndexForOp[op.getOperation()] = index;
        std::string globalName = "__eco_str_" + std::to_string(index);
        OpBuilder::InsertionGuard guard(builder);
        builder.setInsertionPointToStart(runtime.module.getBody());

        if (isAsciiLiteral(value)) {
            size_t byteLen = value.size();
            auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, byteLen);
            auto globalOp = builder.create<LLVM::GlobalOp>(
                op.getLoc(), arrayTy, /*isConstant=*/true,
                LLVM::Linkage::Internal, globalName, Attribute{});
            // Capturing `value` by copy is safe in a deferred job: it points into attribute storage, which
            // lives as long as the context.
            Location loc = op.getLoc();
            deferOrBuild(runtime, ctx, [=](OpBuilder &builder) mutable {
                Block *initBlock =
                    builder.createBlock(&globalOp.getInitializerRegion());
                builder.setInsertionPointToStart(initBlock);
                SmallVector<int8_t> byteValues;
                for (char c : value) byteValues.push_back(static_cast<int8_t>(c));
                auto denseAttr = DenseElementsAttr::get(
                    RankedTensorType::get({static_cast<int64_t>(byteLen)}, i8Ty),
                    ArrayRef<int8_t>(byteValues));
                Value arrayVal =
                    builder.create<LLVM::ConstantOp>(loc, arrayTy, denseAttr);
                builder.create<LLVM::ReturnOp>(loc, arrayVal);
            }, builder);
            return;
        }

        std::vector<uint16_t> utf16 = utf8ToUtf16(value);
        size_t length = utf16.size();
        auto arrayTy = LLVM::LLVMArrayType::get(utf16UnitTy, length);
        auto globalOp = builder.create<LLVM::GlobalOp>(
            op.getLoc(), arrayTy, /*isConstant=*/true,
            LLVM::Linkage::Internal, globalName, Attribute{});
        Location loc = op.getLoc();
        deferOrBuild(runtime, ctx, [=](OpBuilder &builder) mutable {
            Block *initBlock =
                builder.createBlock(&globalOp.getInitializerRegion());
            builder.setInsertionPointToStart(initBlock);
            SmallVector<int16_t> charValues;
            for (uint16_t c : utf16) charValues.push_back(static_cast<int16_t>(c));
            auto denseAttr = DenseElementsAttr::get(
                RankedTensorType::get({static_cast<int64_t>(length)}, utf16UnitTy),
                ArrayRef<int16_t>(charValues));
            Value arrayVal =
                builder.create<LLVM::ConstantOp>(loc, arrayTy, denseAttr);
            builder.create<LLVM::ReturnOp>(loc, arrayVal);
        }, builder);
    };
    for (const PreMatDemand &d : demand)
        for (Operation *o : d.literals)
            visit(cast<StringLiteralOp>(o));
}
