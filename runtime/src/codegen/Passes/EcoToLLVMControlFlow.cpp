//===- EcoToLLVMControlFlow.cpp - Control flow lowering patterns ----------===//
//
// The eco dialect expresses branching as structured operations with regions,
// and LLVM has only basic blocks and branches. This file holds the conversion
// patterns that flatten eco's control flow into `cf` blocks and LLVM
// operations, plus the step that creates the globals a string case reads.
//
// The operations lowered are these. `eco.case` picks one of its alternative
// regions by the scrutinee; `eco.yield` ends an alternative with the case's
// results; `eco.joinpoint` defines a labelled block (its body) that
// `eco.jump` branches to, followed by a continuation region; `eco.return`
// ends a function; `eco.get_tag` reads a value's constructor tag.
//
// Most of the file is `eco.case`, which comes in four kinds, told by the
// `case_kind` attribute and the scrutinee type:
//
// - An Int or Char case switches on the unboxed number. A boxed scrutinee is
//   loaded from its heap box first.
// - A String case is a chain of equality tests against the patterns, in
//   order.
// - An ADT case on an `i1` scrutinee switches on the Bool as 0 or 1.
// - Any other ADT case switches on the constructor tag. An `!eco.value` word
//   is either a heap object or an embedded constant, told apart by bit 2
//   (`ptr_ind`; `allocator/Heap` owns the encoding). A heap object's tag is
//   the 16-bit `ctor` field at `layout::CustomCtorOffset`. An embedded
//   constant's tag is computed from the word: a null-constructor word gives
//   its constructor index, True and False give 1 and 0, and any other
//   constant gives `value_enc::ConstantTag`.
//
// Every kind treats the last alternative as the default, so a value matching
// no earlier alternative takes the last one. Each
// alternative becomes a block; operations after the case move to a merge
// block, which takes the case's results as block arguments, and each
// `eco.yield` becomes a branch to it.
//
// `eco.case` is lowered here only outside `scf` regions; inside one, the
// conversion target treats it as legal and it is handled elsewhere.
// `eco.get_tag` does not open-code its test, because it may sit inside an
// `scf` region, where only one block is allowed. It becomes a call to the
// `__eco_get_tag_inline` marker, which the LLVM-IR backend expands.
//
//===----------------------------------------------------------------------===//

#include "EcoToLLVMInternal.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"

#include <atomic>
#include <cstdint>

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/IRMapping.h"

using namespace mlir;
using namespace eco;
using namespace eco::detail;

/// Returns whether every byte of the string-case pattern `s` is below 0x80.
/// Such a pattern's global holds bytes; any other's holds UTF-16 code units.
static bool isAsciiCasePattern(llvm::StringRef s);

namespace {

/// Returns whether a string case compares with the `__eco_value_eq` marker
/// rather than a call to the `Elm_Kernel_Utils_equal` kernel function. It is true unless
/// `ECO_VALUE_EQ_STRCASE` is exactly `0`, and is read once per process.
///
/// EcoControlFlowToSCF.cpp holds an identical copy for the string cases it
/// lowers. The two must change together, or the two kinds of string case
/// will compare differently.
static bool valueEqStrCaseEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_STRCASE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

//===----------------------------------------------------------------------===//
// eco.return -> func.return
//===----------------------------------------------------------------------===//

/// The pattern that turns `eco.return` into `func.return`.
///
/// An `eco.return` with more than one operand is taken to be in a function
/// that returns through a caller-provided slot (CGEN_067): the slot is the
/// enclosing `llvm.func`'s first argument, laid out as a struct of the
/// operands' types. Each operand is stored into its field and the function
/// returns nothing. It is an error if there is no enclosing `llvm.func`.
struct ReturnOpLowering : public OpConversionPattern<ReturnOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReturnOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        // The stores sit directly before the return, so no call (and so no
        // collection) can come between them: the slot is not a GC root and
        // must not hold a pointer across a collection.
        if (adaptor.getResults().size() > 1) {
            auto parent = op->getParentOfType<LLVM::LLVMFuncOp>();
            if (!parent)
                return op.emitError("multi-operand eco.return outside llvm.func");
            auto loc = op.getLoc();
            auto *ctx = rewriter.getContext();
            Value slot = parent.getArgument(0);
            SmallVector<Type> fieldTys(adaptor.getResults().getTypes().begin(),
                                       adaptor.getResults().getTypes().end());
            auto structTy = LLVM::LLVMStructType::getLiteral(ctx, fieldTys);
            auto ptrTy = LLVM::LLVMPointerType::get(ctx);
            for (auto [i, v] : llvm::enumerate(adaptor.getResults())) {
                Value gep = rewriter.create<LLVM::GEPOp>(
                    loc, ptrTy, structTy, slot,
                    ArrayRef<LLVM::GEPArg>{0, static_cast<int32_t>(i)});
                rewriter.create<LLVM::StoreOp>(loc, v, gep);
            }
            rewriter.replaceOpWithNewOp<func::ReturnOp>(op);
            return success();
        }
        rewriter.replaceOpWithNewOp<func::ReturnOp>(op, adaptor.getResults());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.get_tag -> Extract constructor tag from ADT value
//===----------------------------------------------------------------------===//

/// The pattern that turns `eco.get_tag` into a call that returns the value's
/// constructor tag.
///
/// When `inlineDerefExtEnabled()` holds, the call is to the gc-leaf
/// `__eco_get_tag_inline` marker, which the LLVM-IR backend later replaces
/// with an inline test. Otherwise it is to the runtime's `eco_get_tag`.
struct GetTagOpLowering : public OpConversionPattern<GetTagOp> {
    /// The runtime declarations; must outlive the pattern.
    const EcoRuntime &runtime;

    /// Creates the pattern; it keeps a reference to `runtime`.
    GetTagOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                     const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(GetTagOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value value = adaptor.getValue();

        if (!inlineDerefExtEnabled()) {
            auto getTagFunc = runtime.getOrCreateGetTag(rewriter);
            auto call = rewriter.create<LLVM::CallOp>(loc, getTagFunc, ValueRange{value});
            rewriter.replaceOp(op, call.getResult());
            return success();
        }

        // A marker, not inline blocks: this op may be inside an scf region,
        // which must stay a single block.
        auto markerFunc = runtime.getOrCreateGetTagInlineMarker(rewriter);
        auto call = rewriter.create<LLVM::CallOp>(loc, markerFunc, ValueRange{value});
        rewriter.replaceOp(op, call.getResult());
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.case -> cf.switch on constructor tag
//===----------------------------------------------------------------------===//

/// The pattern that turns an `eco.case` outside any `scf` region into
/// `cf` blocks, in the four ways the file comment describes.
struct CaseOpLowering : public OpConversionPattern<CaseOp> {
    /// The runtime declarations and the string-case ids; must outlive the
    /// pattern.
    const EcoRuntime &runtime;

    /// Creates the pattern; it keeps a reference to `runtime`.
    CaseOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                   const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    /// Replaces the Int case (`isIntCase`) or Char case `op` with a
    /// `cf.switch` on the scrutinee's number, compared as 64 bits for Int and
    /// 32 bits for Char against the case's tags.
    ///
    /// The scrutinee may be an unboxed `i64` or `i32`, or a boxed value, whose
    /// number is read as the word after the header. A boxed scrutinee must
    /// be a heap object, not an embedded constant. The last alternative is
    /// the default.
    LogicalResult
    lowerIntegerOrCharCase(CaseOp op, OpAdaptor adaptor,
                           ConversionPatternRewriter &rewriter,
                           bool isIntCase) const {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto charTy = eco::getEcoCharType(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();
        Block *originalOpBlock = op->getBlock();

        Value scrutinee = adaptor.getScrutinee();
        Value unboxedValue;

        // Check if scrutinee is already unboxed (i64 for int, i32 for char)
        Type scrutineeType = scrutinee.getType();
        if (scrutineeType.isInteger(64)) {
            // Already unboxed i64 - use directly
            unboxedValue = scrutinee;
            // For char case, truncate to the i32 code point
            if (!isIntCase) {
                unboxedValue = rewriter.create<LLVM::TruncOp>(loc, charTy, unboxedValue);
            }
        } else if (eco::isEcoCharType(scrutineeType)) {
            // Already unboxed i32 (char) - use directly
            unboxedValue = scrutinee;
            // For int case, extend to i64
            if (isIntCase) {
                unboxedValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, unboxedValue);
            }
        } else {
            // A boxed Int or Char is a heap box, never an embedded constant,
            // so no constant test is needed. The loaded word is a number, not
            // a pointer, so no slot-cast barrier (REP_LLVM_002) applies.
            if (inlineDerefExtEnabled()) {
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value base = inlineResolvedBase(rewriter, loc, scrutinee, runtime);
                auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, hptrTy, i8Ty, base, ValueRange{offset});
                unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr, layout::Alignment);
            } else {
                auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
                auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
                Value ptr = resolveCall.getResult();
                auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
                auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});
                unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
            }

            // For char case, truncate to the i32 code point (ElmChar.value
            // is the low half of the payload word; the high half is padding)
            if (!isIntCase) {
                unboxedValue = rewriter.create<LLVM::TruncOp>(loc, charTy, unboxedValue);
            }
        }

        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        // Create case blocks for each alternative
        SmallVector<Block *> caseBlocks;
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // The LAST alternative is the default (wildcard)
        // Build case values for all but the last alternative
        SmallVector<int64_t> caseValues;
        SmallVector<Block *> caseDests;
        for (size_t i = 0; i < alternatives.size() - 1; ++i) {
            caseValues.push_back(tags[i]);
            caseDests.push_back(caseBlocks[i]);
        }

        // Default block is the last alternative (wildcard)
        Block *defaultBlock = caseBlocks.back();

        rewriter.setInsertionPointToEnd(currentBlock);

        // Create cf.switch with the unboxed value
        SmallVector<ValueRange> caseOperands(caseDests.size(), ValueRange{});

        // cf::SwitchOp requires APInt case values
        unsigned bitWidth = isIntCase ? 64 : eco::kEcoCharBits;
        SmallVector<llvm::APInt> caseValuesAPInt;
        for (int64_t v : caseValues) {
            caseValuesAPInt.push_back(llvm::APInt(bitWidth, v));
        }

        rewriter.create<cf::SwitchOp>(
            loc, unboxedValue, defaultBlock, ValueRange{},
            ArrayRef<llvm::APInt>(caseValuesAPInt),
            caseDests, caseOperands);

        Value originalScrutinee = op->getOperand(0);

        // A case is terminal when nothing follows it, or only an eco.return.
        // A terminal case's alternatives keep their own eco.return.
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    // Copy the return op from merge block
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee
        for (Block *caseBlock : caseBlocks) {
            for (Operation &blockOp : *caseBlock) {
                blockOp.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Fix terminators: handle both eco.return and eco.yield
        // For value-producing cases (with eco.yield), convert to branch with arguments
        if (!isTerminalCase || isValueProducing) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases without results, keep eco.return ops which will be
        // converted to func.return by the ReturnOpLowering pattern.

        // Erase the merge block if it's a terminal case with no results
        if (isTerminalCase && !isValueProducing) {
            rewriter.eraseBlock(mergeBlock);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }

    /// Replaces the String case `op` with a chain of equality tests: pattern
    /// i is compared with the scrutinee, and a match branches to alternative
    /// i. A scrutinee matching no pattern takes the last alternative.
    ///
    /// The comparison is the `__eco_value_eq` marker or `Elm_Kernel_Utils_equal`, as
    /// `valueEqStrCaseEnabled` decides. Each non-empty pattern is built as a
    /// string from its global `__eco_str_case_<id>_<i>`; the empty pattern
    /// is the embedded Empty constant. It is an error if `op` has no
    /// `string_patterns`, and `preMaterializeStringCases` must have given
    /// `op` an id (asserted).
    LogicalResult
    lowerStringCase(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();
        Block *originalOpBlock = op->getBlock();

        Value scrutinee = adaptor.getScrutinee();
        auto alternatives = op.getAlternatives();

        // Get string patterns
        auto stringPatternsAttr = op.getStringPatternsAttr();
        if (!stringPatternsAttr) {
            return op.emitOpError("string case missing string_patterns attribute");
        }

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        // Create case blocks for each alternative
        SmallVector<Block *> caseBlocks;
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        auto equalFunc = valueEqStrCaseEnabled()
                             ? runtime.getOrCreateValueEqMarker(rewriter)
                             : runtime.getOrCreateUtilsEqual(rewriter);

        rewriter.setInsertionPointToEnd(currentBlock);

        size_t numPatterns = stringPatternsAttr.size();

        // Only read here: the globals already exist, and nothing is created.
        auto caseIdIt = runtime.caseIdForOp.find(op.getOperation());
        assert(caseIdIt != runtime.caseIdForOp.end() &&
               "string-case globals not pre-materialized");
        const uint64_t caseId = caseIdIt->second;

        for (size_t i = 0; i < numPatterns; ++i) {
            auto patternAttr = cast<StringAttr>(stringPatternsAttr[i]);
            StringRef pattern = patternAttr.getValue();

            Value patternValue;
            if (pattern.empty()) {
                // The empty string is the embedded Empty constant, made a
                // ptr(1) so both operands have the same type.
                int64_t emptyStringVal = value_enc::encodeConstant(value_enc::Empty);
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value emptyI64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, emptyStringVal);
                patternValue = rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, emptyI64);
            } else {
                // The ASCII test must agree with preMaterializeStringCases,
                // which chose the global's element type with it: [N x i8]
                // UTF-8 for ASCII, [N x u16] UTF-16 units otherwise.
                llvm::SmallString<48> globalName;
                {
                    llvm::raw_svector_ostream os(globalName);
                    os << "__eco_str_case_" << caseId << "_" << i;
                }
                auto addrOf = rewriter.create<LLVM::AddressOfOp>(loc, ptrTy, globalName);

                if (isAsciiCasePattern(pattern)) {
                    auto allocFunc = runtime.getOrCreateAllocStringLiteralUtf8(rewriter);
                    auto lenVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                        static_cast<int32_t>(pattern.size()));
                    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc,
                        ValueRange{addrOf, lenVal});
                    patternValue = allocCall.getResult();
                } else {
                    std::vector<uint16_t> utf16 = utf8ToUtf16(pattern);
                    size_t length = utf16.size();
                    auto allocFunc = runtime.getOrCreateAllocStringLiteral(rewriter);
                    auto lengthVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                        static_cast<int32_t>(length));
                    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc,
                        ValueRange{addrOf, lengthVal});
                    patternValue = allocCall.getResult();
                }
            }

            // The marker returns i1; Elm_Kernel_Utils_equal returns a boxed Bool,
            // compared with the True word.
            auto cmpCall = rewriter.create<LLVM::CallOp>(loc, equalFunc,
                ValueRange{scrutinee, patternValue});
            Value isEqual;
            if (valueEqStrCaseEnabled()) {
                isEqual = cmpCall.getResult();
            } else {
                Value boxedResult = cmpCall.getResult();
                auto hptrTy = getHPtrLLVMType(*ctx);
                Value trueI64 = rewriter.create<LLVM::ConstantOp>(
                    loc, i64Ty, value_enc::encodeConstant(value_enc::True));
                Value trueConst =
                    rewriter.create<LLVM::IntToPtrOp>(loc, hptrTy, trueI64);
                isEqual = rewriter.create<LLVM::ICmpOp>(
                    loc, LLVM::ICmpPredicate::eq, boxedResult, trueConst);
            }

            // createBlock moves the insertion point, so remember this block.
            Block *compareBlock = rewriter.getInsertionBlock();

            Block *elseBlock;
            if (i + 1 < numPatterns) {
                elseBlock = rewriter.createBlock(parentRegion);
                elseBlock->moveBefore(mergeBlock);
            } else {
                elseBlock = caseBlocks.back();
            }

            rewriter.setInsertionPointToEnd(compareBlock);
            rewriter.create<cf::CondBranchOp>(loc, isEqual,
                caseBlocks[i], ValueRange{}, elseBlock, ValueRange{});

            if (i + 1 < numPatterns) {
                rewriter.setInsertionPointToEnd(elseBlock);
            }
        }

        // If there are no patterns, branch directly to default
        if (numPatterns == 0) {
            rewriter.create<cf::BranchOp>(loc, caseBlocks.back());
        }

        Value originalScrutinee = op->getOperand(0);

        // Terminal as in lowerIntegerOrCharCase.
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee
        for (Block *caseBlock : caseBlocks) {
            for (Operation &blockOp : *caseBlock) {
                blockOp.replaceUsesOfWith(originalScrutinee, scrutinee);
            }
        }

        // Fix terminators: handle both eco.return and eco.yield
        // For value-producing cases (with eco.yield), convert to branch with arguments
        if (!isTerminalCase || isValueProducing) {
            for (Block *caseBlock : caseBlocks) {
                if (caseBlock->empty())
                    continue;

                Operation *term = caseBlock->getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }

        // Erase the merge block if it's a terminal case with no results
        if (isTerminalCase && !isValueProducing) {
            rewriter.eraseBlock(mergeBlock);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }

    // Sends Int, Char and String cases to their helpers and lowers ADT
    // cases itself.
    LogicalResult
    matchAndRewrite(CaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto i8Ty = IntegerType::get(ctx, 8);

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        Value scrutinee = adaptor.getScrutinee();

        auto scrutineeType = scrutinee.getType();
        bool isI1Scrutinee = scrutineeType.isInteger(1);

        // Check if this is an integer case
        auto caseKindAttr = op.getCaseKindAttr();
        bool isIntCase = caseKindAttr && caseKindAttr.getValue() == "int";
        bool isChrCase = caseKindAttr && caseKindAttr.getValue() == "chr";
        bool isStrCase = caseKindAttr && caseKindAttr.getValue() == "str";

        // Handle integer/char cases: unbox and switch on actual value
        if (isIntCase || isChrCase) {
            return lowerIntegerOrCharCase(op, adaptor, rewriter, isIntCase);
        }

        // Handle string cases: compare against string patterns using equality
        if (isStrCase) {
            return lowerStringCase(op, adaptor, rewriter);
        }

        Value ctorTag;

        Value isConstant;
        Block *embConstBlock = nullptr;
        Block *embHeapBlock = nullptr;

        if (isI1Scrutinee) {
            ctorTag = rewriter.create<LLVM::ZExtOp>(loc, i32Ty, scrutinee);
        } else {
            // The integer form of the scrutinee is used only in this block;
            // every shift and mask on it is done here (REP_LLVM_001(d)), and
            // the constant block uses only the masked results.
            Value scrutineeI64 = caseScrutineeToI64(rewriter, loc, scrutinee);

            auto ptrIndShift = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::PtrIndBit);
            auto ptrIndShifted = rewriter.create<LLVM::LShrOp>(loc, scrutineeI64, ptrIndShift);
            auto one64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
            auto ptrIndBit = rewriter.create<LLVM::AndOp>(loc, ptrIndShifted, one64);
            auto maskF = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstFieldMask);
            auto constField = rewriter.create<LLVM::AndOp>(loc, scrutineeI64, maskF);
            // The null-constructor index (HEAP_044).
            auto nullConsShiftC = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, value_enc::NullConsShift);
            auto nullConsShifted =
                rewriter.create<LLVM::LShrOp>(loc, scrutineeI64, nullConsShiftC);
            auto nullConsMaxC = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, static_cast<int64_t>(value_enc::NullConsMax));
            auto nullConsIdx64 =
                rewriter.create<LLVM::AndOp>(loc, nullConsShifted, nullConsMaxC);
            auto zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
            isConstant = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne,
                                                             ptrIndBit, zero64);

            embConstBlock = rewriter.createBlock(parentRegion);
            embHeapBlock = rewriter.createBlock(parentRegion);
            Block *tagMergeBlock = rewriter.createBlock(parentRegion);
            tagMergeBlock->addArgument(i32Ty, loc);

            // Embedded constant: the tag comes from the word alone, without
            // the scrutinee's type.
            rewriter.setInsertionPointToStart(embConstBlock);
            auto trueConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::True);
            auto falseConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::False);
            auto isTrue = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                        constField, trueConst);
            auto isFalse = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::eq,
                                                         constField, falseConst);
            auto isBool = rewriter.create<LLVM::OrOp>(loc, isTrue, isFalse);
            auto boolTag64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, isTrue);
            auto constantTagC = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, value_enc::ConstantTag);
            auto nullConsConst = rewriter.create<LLVM::ConstantOp>(
                loc, i64Ty, static_cast<int64_t>(value_enc::NullCons));
            auto isNullCons = rewriter.create<LLVM::ICmpOp>(
                loc, LLVM::ICmpPredicate::eq, constField, nullConsConst);
            auto legacyTag64 = rewriter.create<LLVM::SelectOp>(loc, isBool, boolTag64, constantTagC);
            auto constTag64 = rewriter.create<LLVM::SelectOp>(
                loc, isNullCons, nullConsIdx64, legacyTag64);
            auto constTag = rewriter.create<LLVM::TruncOp>(loc, i32Ty, constTag64);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{constTag});

            // Heap object: only real heap pointers reach this block, so the
            // forwarding-check marker can be used directly.
            rewriter.setInsertionPointToStart(embHeapBlock);

            Value ptr;
            Type ctorGepTy;
            if (inlineDerefExtEnabled()) {
                ptr = inlineResolvedBase(rewriter, loc, scrutinee, runtime);
                ctorGepTy = getHPtrLLVMType(*ctx);
            } else {
                auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
                auto resolveCall = rewriter.create<LLVM::CallOp>(
                    loc, resolveFunc, ValueRange{scrutinee});
                ptr = resolveCall.getResult();
                ctorGepTy = ptrTy;
            }

            auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::CustomCtorOffset);
            auto ctorPtr = rewriter.create<LLVM::GEPOp>(loc, ctorGepTy, i8Ty, ptr,
                                                        ValueRange{offset8});
            // The ctor shares its word with the unboxed-slot bits, so a load
            // wider than 16 bits would mix them into the tag.
            auto ctorFieldTy = getU16StorageType(ctx);  // u16 ctor, not Char
            auto ctorU16 = rewriter.create<LLVM::LoadOp>(loc, ctorFieldTy, ctorPtr);
            auto ctorFromHeap = rewriter.create<LLVM::ZExtOp>(loc, i32Ty, ctorU16);
            rewriter.create<cf::BranchOp>(loc, tagMergeBlock, ValueRange{ctorFromHeap});

            rewriter.setInsertionPointToStart(tagMergeBlock);
            ctorTag = tagMergeBlock->getArgument(0);
            currentBlock = tagMergeBlock;
        }

        Block *originalOpBlock = op->getBlock();

        // Create merge block with arguments for value-producing cases
        Block *mergeBlock = rewriter.createBlock(parentRegion);
        mergeBlock->moveBefore(currentBlock->getNextNode());

        // If eco.case produces results, add block arguments to merge block
        bool isValueProducing = op.getNumResults() > 0;
        SmallVector<Type> resultTypes;
        if (isValueProducing) {
            for (Type t : op.getResultTypes()) {
                Type converted = getTypeConverter()->convertType(t);
                resultTypes.push_back(converted);
                mergeBlock->addArgument(converted, loc);
            }
        }

        ArrayRef<int64_t> tags = op.getTags();
        auto alternatives = op.getAlternatives();

        SmallVector<int64_t> caseValues;
        SmallVector<Block *> caseBlocks;

        for (size_t i = 0; i < alternatives.size(); ++i) {
            Block *caseBlock = rewriter.createBlock(parentRegion);
            caseBlock->moveBefore(mergeBlock);
            caseValues.push_back(tags[i]);
            caseBlocks.push_back(caseBlock);
        }

        // Move operations after eco.case to merge block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(mergeBlock, mergeBlock->end());
            }
        }

        // Create CondBranchOp for embedded constant handling
        if (!isI1Scrutinee) {
            rewriter.setInsertionPointToEnd(originalOpBlock);
            rewriter.create<cf::CondBranchOp>(loc, isConstant, embConstBlock, embHeapBlock);
        }

        rewriter.setInsertionPointToEnd(currentBlock);

        // The default is the last alternative, not the merge block, which
        // may take arguments.
        Block *defaultBlock = caseBlocks.back();
        SmallVector<int32_t> switchCaseValues;
        SmallVector<Block *> switchCaseDests;
        for (size_t i = 0; i < caseBlocks.size() - 1; ++i) {
            switchCaseValues.push_back(static_cast<int32_t>(caseValues[i]));
            switchCaseDests.push_back(caseBlocks[i]);
        }

        SmallVector<ValueRange> caseOperands(switchCaseDests.size(), ValueRange{});

        rewriter.create<cf::SwitchOp>(
            loc, ctorTag, defaultBlock, ValueRange{},
            ArrayRef<int32_t>(switchCaseValues),
            switchCaseDests, caseOperands);

        Value originalScrutinee = op->getOperand(0);

        // Terminal as in lowerIntegerOrCharCase.
        bool isTerminalCase = mergeBlock->empty();
        if (!isTerminalCase && mergeBlock->getOperations().size() == 1 &&
            isa<ReturnOp>(&mergeBlock->front())) {
            isTerminalCase = true;
        }

        // Inline each alternative region
        for (size_t i = 0; i < alternatives.size(); ++i) {
            Region &altRegion = alternatives[i];
            Block *caseBlock = caseBlocks[i];

            if (altRegion.empty()) {
                rewriter.setInsertionPointToEnd(caseBlock);
                if (isTerminalCase) {
                    if (!mergeBlock->empty()) {
                        if (auto retOp = dyn_cast<ReturnOp>(&mergeBlock->front())) {
                            rewriter.clone(*retOp);
                        }
                    }
                } else {
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                }
                continue;
            }

            Block &entryBlock = altRegion.front();
            rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
        }

        // Replace uses of original scrutinee in all blocks between case start and merge.
        // After nested case lowering, alternatives may span multiple blocks.
        {
            bool inCaseRegion = false;
            for (Block &block : *parentRegion) {
                if (&block == caseBlocks.front())
                    inCaseRegion = true;
                if (&block == mergeBlock)
                    break;
                if (inCaseRegion) {
                    for (Operation &op : block) {
                        op.replaceUsesOfWith(originalScrutinee, scrutinee);
                    }
                }
            }
        }

        // Fix terminators: handle both eco.return and eco.yield.
        // After nested case lowering, an alternative may span multiple blocks.
        // Walk all blocks between case start and merge to find yield/return terminators.
        if (!isTerminalCase || isValueProducing) {
            bool inCaseRegion = false;
            for (Block &block : *parentRegion) {
                if (&block == caseBlocks.front())
                    inCaseRegion = true;
                if (&block == mergeBlock)
                    break;
                if (!inCaseRegion || block.empty())
                    continue;

                Operation *term = block.getTerminator();
                if (auto yieldOp = dyn_cast<YieldOp>(term)) {
                    // eco.yield -> cf.branch with yielded values as arguments
                    rewriter.setInsertionPoint(term);
                    SmallVector<Value> branchArgs;
                    for (Value v : yieldOp.getOperands()) {
                        // Convert type if needed
                        Type converted = getTypeConverter()->convertType(v.getType());
                        if (converted != v.getType()) {
                            v = rewriter.create<UnrealizedConversionCastOp>(
                                loc, converted, v).getResult(0);
                        }
                        branchArgs.push_back(v);
                    }
                    rewriter.create<cf::BranchOp>(loc, mergeBlock, branchArgs);
                    rewriter.eraseOp(term);
                } else if (isa<ReturnOp>(term)) {
                    rewriter.setInsertionPoint(term);
                    rewriter.create<cf::BranchOp>(loc, mergeBlock);
                    rewriter.eraseOp(term);
                }
            }
        }
        // For terminal cases without results, keep eco.return ops which will be
        // converted to func.return by the ReturnOpLowering pattern.

        // An empty merge block gets llvm.unreachable as its terminator. No
        // branch here targets it: the switch default is the last alternative.
        if (isTerminalCase && !isValueProducing && mergeBlock->empty()) {
            rewriter.setInsertionPointToEnd(mergeBlock);
            rewriter.create<LLVM::UnreachableOp>(loc);
        }

        // Replace uses of eco.case results with merge block arguments
        if (isValueProducing) {
            rewriter.replaceOp(op, mergeBlock->getArguments());
        } else {
            rewriter.eraseOp(op);
        }
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Joinpoint/Jump lowering with EcoCFContext
//===----------------------------------------------------------------------===//

/// Copies the operations of `sourceBlock` to the rewriter's insertion point,
/// mapping values through `mapping`, which gains the copies' results.
///
/// An `eco.return` becomes a branch with no operands to `exitBlock`; an
/// `eco.jump` is copied for `JumpOpLowering` to lower; a nested
/// `eco.joinpoint` is lowered at once by `lowerNestedJoinpoint`. The
/// joinpoints it meets are recorded in `cfCtx`. `targetBlock` and
/// `isBodyRegion` are not used.
static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx, bool isBodyRegion);

/// Lowers `nestedJP`, met while copying an enclosing joinpoint's region, at
/// the rewriter's insertion block: that block branches to a new continuation
/// block, the body becomes a block taking the body's arguments, and an
/// `eco.return` in either branches to a new exit block, where the insertion
/// point is left. The body block is
/// recorded in `cfCtx`. Values from the enclosing region are taken through
/// `mapping`, which is not changed. `outerExitBlock` is not used, so an
/// `eco.return` in the nested joinpoint branches to its own exit block.
static void lowerNestedJoinpoint(
    JoinpointOp nestedJP, Block *outerExitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx) {

    auto loc = nestedJP.getLoc();
    int64_t jpId = nestedJP.getId();
    Operation *parentFunc = nestedJP->getParentOfType<func::FuncOp>();

    Block *insertBlock = rewriter.getInsertionBlock();
    Region *parentRegion = insertBlock->getParent();

    Block *nestedExitBlock = rewriter.createBlock(parentRegion);
    Block *jpBlock = rewriter.createBlock(parentRegion);
    jpBlock->moveBefore(nestedExitBlock);

    Region &bodyRegion = nestedJP.getBody();
    Block &bodyEntry = bodyRegion.front();
    for (BlockArgument arg : bodyEntry.getArguments()) {
        Type convertedType = typeConverter->convertType(arg.getType());
        jpBlock->addArgument(convertedType, loc);
    }

    cfCtx.joinpointBlocks[{parentFunc, jpId}] = jpBlock;

    Block *contBlock = rewriter.createBlock(parentRegion);
    contBlock->moveBefore(jpBlock);

    rewriter.setInsertionPointToEnd(insertBlock);
    rewriter.create<cf::BranchOp>(loc, contBlock);

    IRMapping bodyMapping(mapping);
    for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                            jpBlock->getArguments())) {
        bodyMapping.map(oldArg, newArg);
    }

    rewriter.setInsertionPointToEnd(jpBlock);
    lowerJoinpointRegion(bodyEntry, jpBlock, nestedExitBlock, bodyMapping,
                         rewriter, typeConverter, cfCtx, /*isBodyRegion=*/true);

    rewriter.setInsertionPointToEnd(contBlock);
    Region &contRegion = nestedJP.getContinuation();
    if (!contRegion.empty()) {
        Block &contEntry = contRegion.front();
        IRMapping contMapping(mapping);
        lowerJoinpointRegion(contEntry, contBlock, nestedExitBlock, contMapping,
                             rewriter, typeConverter, cfCtx, /*isBodyRegion=*/false);
    }

    rewriter.setInsertionPointToEnd(nestedExitBlock);
}

static void lowerJoinpointRegion(
    Block &sourceBlock, Block *targetBlock, Block *exitBlock,
    IRMapping &mapping, ConversionPatternRewriter &rewriter,
    const TypeConverter *typeConverter, EcoCFContext &cfCtx, bool isBodyRegion) {

    auto loc = sourceBlock.getParentOp()->getLoc();

    for (Operation &innerOp : llvm::make_early_inc_range(sourceBlock)) {
        if (isa<ReturnOp>(&innerOp)) {
            rewriter.create<cf::BranchOp>(loc, exitBlock);
        } else if (isa<JumpOp>(&innerOp)) {
            rewriter.clone(innerOp, mapping);
        } else if (auto nestedJP = dyn_cast<JoinpointOp>(&innerOp)) {
            lowerNestedJoinpoint(nestedJP, exitBlock, mapping, rewriter, typeConverter, cfCtx);
        } else {
            Operation *cloned = rewriter.clone(innerOp, mapping);
            for (auto [oldResult, newResult] :
                 llvm::zip(innerOp.getResults(), cloned->getResults())) {
                mapping.map(oldResult, newResult);
            }
        }
    }
}

/// The pattern that turns `eco.joinpoint` into blocks: the operations after
/// it move to an exit block, the continuation region is copied into a block
/// the joinpoint's block branches to, and the body is copied into a block
/// whose arguments are the body's arguments. An `eco.return` in either
/// region becomes a branch with no operands to the exit block.
///
/// The body block is recorded in `cfCtx` under the enclosing function and the
/// joinpoint id, before the regions are copied, so that `JumpOpLowering` can
/// find it.
struct JoinpointOpLowering : public OpConversionPattern<JoinpointOp> {
    /// The joinpoint table; must outlive the pattern.
    EcoCFContext &cfCtx;

    /// Creates the pattern; it keeps a reference to `cfCtx`.
    JoinpointOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                        EcoCFContext &cfCtx)
        : OpConversionPattern(typeConverter, ctx), cfCtx(cfCtx) {}

    LogicalResult
    matchAndRewrite(JoinpointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        int64_t jpId = op.getId();
        Operation *parentFunc = op->getParentOfType<func::FuncOp>();

        Block *currentBlock = op->getBlock();
        Region *parentRegion = currentBlock->getParent();

        Region &bodyRegion = op.getBody();
        Block &bodyEntry = bodyRegion.front();

        Block *exitBlock = rewriter.createBlock(parentRegion);
        exitBlock->moveBefore(currentBlock->getNextNode());

        // Move operations after eco.joinpoint to exit block
        {
            auto opsToMove = llvm::make_early_inc_range(
                llvm::make_range(std::next(Block::iterator(op)), currentBlock->end()));
            for (Operation &opToMove : opsToMove) {
                opToMove.moveBefore(exitBlock, exitBlock->end());
            }
        }

        Block *jpBlock = rewriter.createBlock(parentRegion);
        jpBlock->moveBefore(exitBlock);

        for (BlockArgument arg : bodyEntry.getArguments()) {
            Type convertedType = getTypeConverter()->convertType(arg.getType());
            jpBlock->addArgument(convertedType, loc);
        }

        cfCtx.joinpointBlocks[{parentFunc, jpId}] = jpBlock;

        Block *contBlock = rewriter.createBlock(parentRegion);
        contBlock->moveBefore(jpBlock);

        rewriter.setInsertionPointToEnd(currentBlock);
        rewriter.create<cf::BranchOp>(loc, contBlock);

        IRMapping mapping;
        for (auto [oldArg, newArg] : llvm::zip(bodyEntry.getArguments(),
                                                jpBlock->getArguments())) {
            mapping.map(oldArg, newArg);
        }

        rewriter.setInsertionPointToEnd(jpBlock);
        lowerJoinpointRegion(bodyEntry, jpBlock, exitBlock, mapping,
                             rewriter, getTypeConverter(), cfCtx, /*isBodyRegion=*/true);

        rewriter.setInsertionPointToEnd(contBlock);
        Region &contRegion = op.getContinuation();
        if (!contRegion.empty()) {
            Block &contEntry = contRegion.front();
            IRMapping contMapping;
            lowerJoinpointRegion(contEntry, contBlock, exitBlock, contMapping,
                                 rewriter, getTypeConverter(), cfCtx, /*isBodyRegion=*/false);
        }

        rewriter.eraseOp(op);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// eco.yield
//===----------------------------------------------------------------------===//

/// The pattern that fails the conversion with an error on any `eco.yield` it
/// is asked to convert. `CaseOpLowering` replaces the yields of the cases it
/// lowers itself, so one reaching this pattern belongs to a case nothing
/// lowered.
struct YieldOpLowering : public OpConversionPattern<YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        return op.emitError("eco.yield should have been lowered by EcoControlFlowToSCF "
                           "or converted by CaseOpLowering; this indicates a missing "
                           "pattern for the parent eco.case");
    }
};

/// The pattern that turns `eco.jump` into a branch, with the jump's
/// arguments, to the block recorded in `cfCtx` for its target joinpoint in
/// the enclosing function. A jump to an id with no recorded block is an
/// error.
struct JumpOpLowering : public OpConversionPattern<JumpOp> {
    /// The joinpoint table; must outlive the pattern.
    EcoCFContext &cfCtx;

    /// Creates the pattern; it keeps a reference to `cfCtx`.
    JumpOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                   EcoCFContext &cfCtx)
        : OpConversionPattern(typeConverter, ctx), cfCtx(cfCtx) {}

    LogicalResult
    matchAndRewrite(JumpOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        int64_t targetId = op.getTarget();
        Operation *parentFunc = op->getParentOfType<func::FuncOp>();

        auto it = cfCtx.joinpointBlocks.find({parentFunc, targetId});
        if (it == cfCtx.joinpointBlocks.end()) {
            return op.emitError("jump to unknown joinpoint id ") << targetId;
        }

        Block *targetBlock = it->second;
        rewriter.replaceOpWithNewOp<cf::BranchOp>(op, targetBlock, adaptor.getArgs());
        return success();
    }
};

} // namespace

//===----------------------------------------------------------------------===//
// Pattern Population
//===----------------------------------------------------------------------===//

void eco::detail::populateEcoControlFlowPatterns(
    EcoTypeConverter &typeConverter,
    RewritePatternSet &patterns,
    const EcoRuntime &runtime,
    EcoCFContext &cfCtx) {

    auto *ctx = patterns.getContext();
    patterns.add<ReturnOpLowering>(typeConverter, ctx);
    patterns.add<GetTagOpLowering>(typeConverter, ctx, runtime);
    patterns.add<CaseOpLowering>(typeConverter, ctx, runtime);
    patterns.add<YieldOpLowering>(typeConverter, ctx);
    patterns.add<JoinpointOpLowering>(typeConverter, ctx, cfCtx);
    patterns.add<JumpOpLowering>(typeConverter, ctx, cfCtx);
}

// Depends only on the bytes, so lowerStringCase and preMaterializeStringCases
// make the same choice for the same pattern.
static bool isAsciiCasePattern(llvm::StringRef s) {
    for (char c : s)
        if (static_cast<unsigned char>(c) & 0x80) return false;
    return true;
}

void eco::detail::preMaterializeStringCases(
    OpBuilder &builder, const EcoRuntime &runtime,
    llvm::ArrayRef<PreMatDemand> demand) {
    auto *ctx = builder.getContext();
    auto utf16UnitTy = getU16StorageType(ctx);  // String unit, not Char
    auto i8Ty = IntegerType::get(ctx, 8);
    // Ids count from 0 in demand order, so the same module gets the same ids.
    uint64_t caseCounter = 0;
    auto visit = [&](CaseOp op) {
        auto ck = op.getCaseKindAttr();
        if (!(ck && ck.getValue() == "str")) return;
        auto pats = op.getStringPatternsAttr();
        if (!pats) return;
        uint64_t caseId = caseCounter++;
        runtime.caseIdForOp[op.getOperation()] = caseId;
        for (size_t i = 0; i < pats.size(); ++i) {
            StringRef pattern = cast<StringAttr>(pats[i]).getValue();
            if (pattern.empty()) continue;  // the Empty constant needs no global
            llvm::SmallString<48> globalName;
            {
                llvm::raw_svector_ostream os(globalName);
                os << "__eco_str_case_" << caseId << "_" << i;
            }
            OpBuilder::InsertionGuard guard(builder);
            builder.setInsertionPointToStart(runtime.module.getBody());

            if (isAsciiCasePattern(pattern)) {
                size_t byteLen = pattern.size();
                auto arrayTy = LLVM::LLVMArrayType::get(i8Ty, byteLen);
                auto globalOp = builder.create<LLVM::GlobalOp>(
                    op.getLoc(), arrayTy, /*isConstant=*/true,
                    LLVM::Linkage::Internal, globalName, /*value=*/Attribute{});
                Block *initBlock =
                    builder.createBlock(&globalOp.getInitializerRegion());
                builder.setInsertionPointToStart(initBlock);
                SmallVector<int8_t> byteValues;
                for (char c : pattern)
                    byteValues.push_back(static_cast<int8_t>(c));
                auto denseAttr = DenseElementsAttr::get(
                    RankedTensorType::get({static_cast<int64_t>(byteLen)}, i8Ty),
                    ArrayRef<int8_t>(byteValues));
                auto initValue = builder.create<LLVM::ConstantOp>(
                    op.getLoc(), arrayTy, denseAttr);
                builder.create<LLVM::ReturnOp>(op.getLoc(), initValue.getResult());
                continue;
            }

            std::vector<uint16_t> utf16 = utf8ToUtf16(pattern);
            size_t length = utf16.size();
            auto arrayTy = LLVM::LLVMArrayType::get(utf16UnitTy, length);
            auto globalOp = builder.create<LLVM::GlobalOp>(
                op.getLoc(), arrayTy, /*isConstant=*/true,
                LLVM::Linkage::Internal, globalName, /*value=*/Attribute{});
            Block *initBlock =
                builder.createBlock(&globalOp.getInitializerRegion());
            builder.setInsertionPointToStart(initBlock);
            SmallVector<int16_t> charValues;
            for (uint16_t c : utf16)
                charValues.push_back(static_cast<int16_t>(c));
            auto denseAttr = DenseElementsAttr::get(
                RankedTensorType::get({static_cast<int64_t>(length)}, utf16UnitTy),
                ArrayRef<int16_t>(charValues));
            auto initValue =
                builder.create<LLVM::ConstantOp>(op.getLoc(), arrayTy, denseAttr);
            builder.create<LLVM::ReturnOp>(op.getLoc(), initValue.getResult());
        }
    };
    for (const PreMatDemand &d : demand)
        for (Operation *o : d.cases)
            visit(cast<CaseOp>(o));
}
