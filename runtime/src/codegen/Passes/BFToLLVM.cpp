//===- BFToLLVM.cpp - BF dialect to LLVM dialect lowering -----------------===//
//
// This file implements the pass for lowering BF (ByteFusion) dialect operations
// to LLVM dialect. The bf.cursor type is lowered to a struct {i8*, i8*} and
// operations are lowered to runtime helper calls and inline LLVM ops. Before
// the conversion, cursors live across an op that may run a GC are re-derived
// from their buffers (CursorGCSafety, BFOPS_039).
//
//===----------------------------------------------------------------------===//

#include "../BF/BFDialect.h"
#include "../BF/BFOps.h"
#include "../BF/BFTypes.h"
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"
#include "EcoMarkerFacts.h"
#include "EcoParallel.h"

#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/ControlFlowInterfaces.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/MapVector.h"

using namespace mlir;
using namespace bf;

namespace {

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

/// Type converter for BF dialect.
/// Converts bf.cursor to LLVM struct {i8*, i8*}.
/// Also converts eco.value to i64 for interoperability.
class BFTypeConverter : public LLVMTypeConverter {
public:
    explicit BFTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
        addConversion([](bf::CursorType type) -> Type {
            // Cursor is (current_ptr, end_ptr)
            auto ptrType = LLVM::LLVMPointerType::get(type.getContext());
            return LLVM::LLVMStructType::getLiteral(type.getContext(),
                                                     {ptrType, ptrType});
        });

        // Convert eco.value to ptr addrspace(1), matching EcoTypeConverter.
        addConversion([](eco::ValueType type) -> Type {
            return LLVM::LLVMPointerType::get(type.getContext(), /*addressSpace=*/1);
        });

        // Add source materialization for eco.value -> i64 conversion.
        // This creates unrealized_conversion_cast when we need to convert
        // an eco.value source to i64.
        addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                    ValueRange inputs, Location loc) -> Value {
            if (inputs.size() != 1)
                return nullptr;
            return builder.create<UnrealizedConversionCastOp>(
                loc, resultType, inputs).getResult(0);
        });

        // Add target materialization for i64 -> eco.value conversion.
        addTargetMaterialization([](OpBuilder &builder, Type resultType,
                                    ValueRange inputs, Location loc) -> Value {
            if (inputs.size() != 1)
                return nullptr;
            return builder.create<UnrealizedConversionCastOp>(
                loc, resultType, inputs).getResult(0);
        });
    }
};

//===----------------------------------------------------------------------===//
// Runtime Function Declarations & Cache
//===----------------------------------------------------------------------===//

/// Cached references to BF runtime functions, looked up once after declaration.
struct BFRuntimeFuncs {
    LLVM::LLVMFuncOp allocBytebuffer;
    LLVM::LLVMFuncOp bytebufferLen;
    LLVM::LLVMFuncOp bytebufferData;
    LLVM::LLVMFuncOp builderBegin;
    LLVM::LLVMFuncOp builderEnd;
    LLVM::LLVMFuncOp utf8Width;
    LLVM::LLVMFuncOp utf8Copy;
    LLVM::LLVMFuncOp utf8Decode;
    LLVM::LLVMFuncOp encoderSize;
    LLVM::LLVMFuncOp encoderWriteInto;
};

/// Ensure runtime functions are declared in the module, then cache them.
static BFRuntimeFuncs ensureRuntimeFunctions(ModuleOp module, OpBuilder &builder,
                                             mlir::SymbolTable &symTable) {
    auto loc = module.getLoc();
    auto ctx = module.getContext();
    auto i8Ptr = LLVM::LLVMPointerType::get(ctx);
    auto i32 = builder.getI32Type();

    auto declareFunc = [&](StringRef name, Type resultType,
                           ArrayRef<Type> argTypes) -> LLVM::LLVMFuncOp {
        if (auto existing = symTable.lookup<LLVM::LLVMFuncOp>(name))
            return existing;
        auto funcType = LLVM::LLVMFunctionType::get(resultType, argTypes);
        builder.setInsertionPointToStart(module.getBody());
        auto func = builder.create<LLVM::LLVMFuncOp>(loc, name, funcType);
        symTable.insert(func);
        return func;
    };

    BFRuntimeFuncs funcs;

    auto hptr = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    // ByteBuffer operations
    funcs.allocBytebuffer = declareFunc("elm_alloc_bytebuffer", hptr, {i32});
    funcs.bytebufferLen = declareFunc("elm_bytebuffer_len", i32, {hptr});
    funcs.bytebufferData = declareFunc("elm_bytebuffer_data", i8Ptr, {hptr});
    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    funcs.builderBegin = declareFunc("elm_bytebuffer_builder_begin", voidTy, {hptr});
    funcs.builderEnd = declareFunc("elm_bytebuffer_builder_end", voidTy, {hptr});

    // UTF-8 operations
    funcs.utf8Width = declareFunc("elm_utf8_width", i32, {hptr});
    funcs.utf8Copy = declareFunc("elm_utf8_copy", i32, {hptr, i8Ptr});
    funcs.utf8Decode = declareFunc("elm_utf8_decode", hptr, {hptr, i32, i32});

    // Encoder-tree operations (bytes-fusion escape hatch)
    funcs.encoderSize = declareFunc("elm_encoder_size", i32, {hptr});
    funcs.encoderWriteInto = declareFunc("elm_encoder_write_into", i32, {hptr, i8Ptr});

    // Maybe operations
    declareFunc("elm_maybe_nothing", hptr, {});
    declareFunc("elm_maybe_just", hptr, {hptr});

    return funcs;
}

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

/// Create a cursor struct value from ptr and end pointers.
static Value createCursor(OpBuilder &builder, Location loc, Value ptr,
                          Value end, Type cursorLLVMType) {
    Value cursor = builder.create<LLVM::UndefOp>(loc, cursorLLVMType);
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, ptr,
                                                  ArrayRef<int64_t>{0});
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, end,
                                                  ArrayRef<int64_t>{1});
    return cursor;
}

/// Extract the current pointer from a cursor.
static Value extractPtr(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{0});
}

/// Extract the end pointer from a cursor.
static Value extractEnd(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{1});
}

/// Advance cursor pointer by given number of bytes and return new cursor.
static Value advanceCursor(OpBuilder &builder, Location loc, Value cursor,
                           Value bytes, Type cursorLLVMType) {
    Value ptr = extractPtr(builder, loc, cursor);
    Value end = extractEnd(builder, loc, cursor);

    // gep ptr, bytes
    Value newPtr = builder.create<LLVM::GEPOp>(
        loc, ptr.getType(), builder.getI8Type(), ptr, bytes);

    return createCursor(builder, loc, newPtr, end, cursorLLVMType);
}

//===----------------------------------------------------------------------===//
// Cursors across GC points (BFOPS_039)
//===----------------------------------------------------------------------===//
//
// A cursor is a pair of raw pointers into its buffer's body. A ByteBuffer
// under the large-object threshold lives in the nursery, so any op that may
// run a GC (an allocation, or a call not known to be gc-leaf) can move the
// buffer and leave a live cursor pointing at evacuated memory. Before the
// conversion, every cursor live across such an op is re-derived from its
// buffer: bf.cursor.offsets before the op, bf.cursor.rebase after it. The
// buffer is an eco.value, which RS4GC relocates across the op. A structural
// check then rejects any cursor use still reachable from its definition
// through an op that may collect. bf.read.bytes and bf.read.utf8 allocate
// themselves; their lowerings re-derive the source pointer after the
// allocation from the buffer this analysis finds for their cursor.

/// The analysis and rewrite above, run on each top-level op holding bf ops.
class CursorGCSafety {
public:
    explicit CursorGCSafety(SymbolTable &symbols) : symbols(symbols) {}

    /// Inserts the rebases in `top` and checks the result. Emits an error and
    /// fails when a cursor that must survive a GC point has no known buffer.
    LogicalResult run(Operation *top) {
        buildClasses(top);
        if (failed(insertRebases(top)) || failed(insertBuilders(top)))
            return failure();
        return verify(top);
    }

    /// The buffer `cursor` points into, or null when unknown or ambiguous.
    Value bufferOf(Value cursor) {
        Value rep = find(cursor);
        auto it = buffers.find(rep);
        return it == buffers.end() || ambiguous.contains(rep) ? Value() : it->second;
    }

    /// Does `op` (or any op nested in it) possibly run a GC? Conservative: an
    /// op not known to be GC-free is a GC point; a wrong "yes" only costs a
    /// rebase.
    bool mayCollect(Operation *op) {
        auto it = memo.find(op);
        if (it != memo.end())
            return it->second;
        bool r = computeMayCollect(op);
        memo[op] = r;
        return r;
    }

private:
    SymbolTable &symbols;
    DenseMap<Operation *, bool> memo;
    // Union-find over cursor values: one class per chain of cursors that
    // point into the same buffer.
    DenseMap<Value, Value> parent;
    DenseMap<Value, Value> buffers;       // class representative -> buffer
    llvm::DenseSet<Value> ambiguous;      // representatives with two buffers
    SmallVector<Value> cursors;
    SmallVector<Value> rebasedCursors;    // one member per rebased class

    static bool isCursor(Value v) { return isa<bf::CursorType>(v.getType()); }

    static bool inDialect(Operation *op, StringRef ns) {
        return op->getName().getDialectNamespace() == ns;
    }

    bool leafCallee(StringRef name) {
        if (eco::markers::isScratchHelper(name) || eco::markers::isCursorMarker(name))
            return true;
        if (auto fn = symbols.lookup<LLVM::LLVMFuncOp>(name)) {
            if (auto pt = fn.getPassthrough())
                for (Attribute a : *pt)
                    if (auto s = dyn_cast<StringAttr>(a); s && s.getValue() == "gc-leaf-function")
                        return true;
        }
        return false;
    }

    bool computeMayCollect(Operation *op) {
        if (op->getNumRegions() > 0) {
            // Structured control flow collects iff something inside it does;
            // any other region-holding op is assumed to collect.
            if (!inDialect(op, "scf") && !isa<eco::CaseOp>(op))
                return true;
            for (Region &region : op->getRegions())
                for (Block &block : region)
                    for (Operation &nested : block)
                        if (mayCollect(&nested))
                            return true;
            return false;
        }
        if (inDialect(op, "bf"))
            return isa<bf::AllocOp, bf::ReadBytesOp, bf::ReadUtf8Op>(op);
        if (isa<eco::CallOp>(op)) {
            if (op->hasAttr("eco.callee_gc_leaf"))
                return false;
            auto callee = op->getAttrOfType<FlatSymbolRefAttr>("callee");
            return !(callee && leafCallee(callee.getValue()));
        }
        if (auto call = dyn_cast<func::CallOp>(op))
            return !leafCallee(call.getCallee());
        if (auto call = dyn_cast<LLVM::CallOp>(op)) {
            auto callee = call.getCallee();
            return !(callee && leafCallee(*callee));
        }
        if (op->hasTrait<OpTrait::IsTerminator>())
            return false;
        if (inDialect(op, "llvm"))
            return false; // non-call LLVM ops
        if (isPure(op))
            // Pure but allocating (EcoGCPrepare's may-alloc set).
            return isa<eco::ListConstructOp, eco::Tuple2ConstructOp,
                       eco::Tuple3ConstructOp, eco::RecordConstructOp,
                       eco::CustomConstructOp, eco::BoxOp>(op);
        return true;
    }

    Value find(Value v) {
        auto it = parent.find(v);
        if (it == parent.end() || it->second == v)
            return v;
        Value root = find(it->second);
        parent[v] = root;
        return root;
    }

    void unite(Value a, Value b) {
        if (!isCursor(a) || !isCursor(b))
            return;
        Value ra = find(a), rb = find(b);
        if (ra == rb)
            return;
        parent[ra] = rb;
        auto ia = buffers.find(ra);
        if (ia != buffers.end()) {
            Value buffer = ia->second;
            buffers.erase(ia);
            setBuffer(rb, buffer);
        }
        if (ambiguous.erase(ra))
            ambiguous.insert(rb);
    }

    void setBuffer(Value rep, Value buffer) {
        auto [it, inserted] = buffers.try_emplace(rep, buffer);
        if (!inserted && it->second != buffer)
            ambiguous.insert(rep);
    }

    void uniteRange(ValueRange a, ValueRange b) {
        for (auto [x, y] : llvm::zip(a, b))
            unite(x, y);
    }

    void buildClasses(Operation *top) {
        top->walk([&](Block *block) {
            for (BlockArgument arg : block->getArguments())
                if (isCursor(arg))
                    cursors.push_back(arg);
        });
        top->walk([&](Operation *op) {
            for (Value r : op->getResults())
                if (isCursor(r))
                    cursors.push_back(r);
        });
        top->walk([&](Operation *op) {
            if (auto init = dyn_cast<bf::CursorInitOp>(op)) {
                parent.try_emplace(init.getCursor(), init.getCursor());
                setBuffer(find(init.getCursor()), init.getBuffer());
            } else if (auto init = dyn_cast<bf::DecoderCursorInitOp>(op)) {
                parent.try_emplace(init.getCursor(), init.getCursor());
                setBuffer(find(init.getCursor()), init.getBytes());
            } else if (inDialect(op, "bf")) {
                // A cursor-threading op: its new cursor points into the
                // same buffer as the cursor it consumed.
                for (Value in : op->getOperands())
                    for (Value out : op->getResults())
                        unite(out, in);
            } else if (auto w = dyn_cast<scf::WhileOp>(op)) {
                uniteRange(w.getInits(), w.getBeforeArguments());
                auto cond = w.getConditionOp();
                uniteRange(cond.getArgs(), w.getAfterArguments());
                uniteRange(cond.getArgs(), w.getResults());
                uniteRange(w.getYieldOp()->getOperands(), w.getBeforeArguments());
            } else if (auto f = dyn_cast<scf::ForOp>(op)) {
                uniteRange(f.getInitArgs(), f.getRegionIterArgs());
                uniteRange(f.getBody()->getTerminator()->getOperands(), f.getRegionIterArgs());
                uniteRange(f.getInitArgs(), f.getResults());
            } else if (op->getNumRegions() > 0) {
                // scf.if, scf.index_switch, eco.case: each region's
                // terminator yields the op's results.
                for (Region &region : op->getRegions())
                    for (Block &block : region)
                        if (!block.empty() && block.back().hasTrait<OpTrait::IsTerminator>() &&
                            block.back().getNumOperands() == op->getNumResults())
                            uniteRange(block.back().getOperands(), op->getResults());
            } else if (auto br = dyn_cast<BranchOpInterface>(op)) {
                for (unsigned i = 0, e = op->getNumSuccessors(); i < e; ++i) {
                    SuccessorOperands so = br.getSuccessorOperands(i);
                    Block *dest = op->getSuccessor(i);
                    for (unsigned k = 0, n = so.size(); k < n; ++k)
                        if (Value v = so[k])
                            unite(v, dest->getArgument(k));
                }
            }
        });
    }

    /// Is `v` defined at a point that dominates `op` (structurally)?
    static bool visibleAt(Value v, Operation *op) {
        Block *defBlock = v.getParentBlock();
        Operation *anc = defBlock->findAncestorOpInBlock(*op);
        if (!anc)
            return false;
        Operation *def = v.getDefiningOp();
        return !def || (def != anc && def->isBeforeInBlock(anc));
    }

    /// Is `v` used by an op that comes after `op` in `op`'s block?
    static bool usedAfter(Value v, Operation *op) {
        Block *block = op->getBlock();
        for (Operation *user : v.getUsers()) {
            Operation *anc = block->findAncestorOpInBlock(*user);
            if (anc && anc != op && op->isBeforeInBlock(anc))
                return true;
        }
        return false;
    }

    LogicalResult bufferFor(Value cursor, Operation *at, Value &buffer) {
        buffer = bufferOf(cursor);
        if (!buffer) {
            at->emitError("bf: a cursor is live across this op, which may run a GC, "
                          "and its buffer is unknown, so it cannot be re-derived (BFOPS_039)");
            return failure();
        }
        if (!isa<eco::ValueType>(buffer.getType()) || !visibleAt(buffer, at)) {
            at->emitError("bf: the buffer of a cursor live across this op, which may run "
                          "a GC, is not an eco.value in scope here (BFOPS_039)");
            return failure();
        }
        return success();
    }

    LogicalResult insertRebases(Operation *top) {
        SmallVector<Block *> blocks;
        top->walk([&](Block *b) { blocks.push_back(b); });
        OpBuilder builder(top->getContext());
        for (Block *block : blocks) {
            SmallVector<Operation *> ops;
            for (Operation &op : *block)
                ops.push_back(&op);
            for (Operation *gcPoint : ops) {
                if (!mayCollect(gcPoint))
                    continue;
                // The cursor results of bf.read.bytes / bf.read.utf8 are
                // re-derived by their own lowering; only cursors defined
                // before the op need a rebase.
                for (size_t i = 0; i < cursors.size(); ++i) {
                    Value cursor = cursors[i];
                    if (!visibleAt(cursor, gcPoint) || !usedAfter(cursor, gcPoint))
                        continue;
                    Value buffer;
                    if (failed(bufferFor(cursor, gcPoint, buffer)))
                        return failure();
                    Location loc = gcPoint->getLoc();
                    builder.setInsertionPoint(gcPoint);
                    auto offsets = builder.create<bf::CursorOffsetsOp>(
                        loc, builder.getI64Type(), builder.getI64Type(), cursor, buffer);
                    builder.setInsertionPointAfter(gcPoint);
                    auto rebase = builder.create<bf::CursorRebaseOp>(
                        loc, cursor.getType(), buffer, offsets.getPos(), offsets.getEnd());
                    Value fresh = rebase.getCursor();
                    cursor.replaceUsesWithIf(fresh, [&](OpOperand &use) {
                        Operation *anc = block->findAncestorOpInBlock(*use.getOwner());
                        return anc && anc != gcPoint && gcPoint->isBeforeInBlock(anc);
                    });
                    parent.try_emplace(fresh, fresh);
                    unite(fresh, cursor);
                    cursors.push_back(fresh);
                    rebasedCursors.push_back(cursor);
                }
            }
        }
        // The two allocating reads re-derive their source pointer from the
        // buffer after allocating (their lowerings).
        WalkResult wr = top->walk([&](Operation *op) {
            if (!isa<bf::ReadBytesOp, bf::ReadUtf8Op>(op))
                return WalkResult::advance();
            Value buffer;
            if (failed(bufferFor(op->getOperand(0), op, buffer)))
                return WalkResult::interrupt();
            return WalkResult::advance();
        });
        return failure(wr.wasInterrupted());
    }

    /// An encoder that writes after a GC point writes into an object that has
    /// survived a GC, which HEAP_SNAPSHOT_001 allows only for a builder: the
    /// concurrent tenure job may copy the buffer, and writes into the old copy
    /// would be lost. Brackets each such buffer with bf.builder.begin right
    /// after its bf.alloc and bf.builder.end after its last cursor use.
    LogicalResult insertBuilders(Operation *top) {
        llvm::DenseSet<Value> rebasedReps;
        for (Value v : rebasedCursors)
            rebasedReps.insert(find(v));
        llvm::MapVector<Value, SmallVector<Value, 2>> writers; // buffer -> classes
        top->walk([&](bf::CursorInitOp init) {
            Value rep = find(init.getCursor());
            if (rebasedReps.contains(rep))
                writers[init.getBuffer()].push_back(rep);
        });
        OpBuilder builder(top->getContext());
        for (auto &[buffer, reps] : writers) {
            auto alloc = buffer.getDefiningOp<bf::AllocOp>();
            if (!alloc) {
                top->emitError("bf: an encoder writes after a GC point into a buffer "
                               "not allocated by bf.alloc, which cannot be a builder "
                               "(BFOPS_039)");
                return failure();
            }
            Block *block = alloc->getBlock();
            Operation *last = nullptr;
            for (Value c : cursors) {
                if (!llvm::is_contained(reps, find(c)))
                    continue;
                for (Operation *user : c.getUsers()) {
                    Operation *anc = block->findAncestorOpInBlock(*user);
                    if (!anc || anc->hasTrait<OpTrait::IsTerminator>()) {
                        user->emitError("bf: an encoder cursor that crosses a GC point "
                                        "leaves the block of its bf.alloc (BFOPS_039)");
                        return failure();
                    }
                    if (!last || last->isBeforeInBlock(anc))
                        last = anc;
                }
            }
            builder.setInsertionPointAfter(alloc);
            builder.create<bf::BuilderBeginOp>(alloc.getLoc(), buffer);
            builder.setInsertionPointAfter(last);
            builder.create<bf::BuilderEndOp>(last->getLoc(), buffer);
        }
        return success();
    }

    /// An op that may collect on some path from `v`'s definition to `user`,
    /// or null. Climbing out of a loop that may collect counts as one: a
    /// later iteration reuses the cursor after the GC.
    Operation *collectBetween(Value v, Operation *user) {
        Block *defBlock = v.getParentBlock();
        Operation *cur = user;
        while (cur->getBlock() != defBlock) {
            Block *b = cur->getBlock();
            for (Operation &o : *b) {
                if (&o == cur)
                    break;
                if (mayCollect(&o))
                    return &o;
            }
            Operation *parentOp = b->getParentOp();
            if (!parentOp || !defBlock->getParentOp() ||
                !defBlock->getParentOp()->isAncestor(parentOp)) {
                // Different blocks of one region (unstructured control
                // flow): only safe when nothing in the region collects.
                for (Block &rb : *defBlock->getParent())
                    for (Operation &o : rb)
                        if (mayCollect(&o))
                            return &o;
                return nullptr;
            }
            if (isa<scf::WhileOp, scf::ForOp>(parentOp) && mayCollect(parentOp))
                return parentOp;
            cur = parentOp;
        }
        Operation *def = v.getDefiningOp();
        Operation *o = def ? def->getNextNode() : &defBlock->front();
        for (; o && o != cur; o = o->getNextNode())
            if (mayCollect(o))
                return o;
        return nullptr;
    }

    LogicalResult verify(Operation *top) {
        WalkResult wr = top->walk([&](Operation *user) {
            for (Value v : user->getOperands()) {
                if (!isCursor(v))
                    continue;
                if (Operation *gc = collectBetween(v, user)) {
                    user->emitError("bf: a cursor is used after an op that may run a GC "
                                    "without being re-derived (BFOPS_039): ")
                        << gc->getName() << " at " << gc->getLoc();
                    return WalkResult::interrupt();
                }
            }
            return WalkResult::advance();
        });
        return failure(wr.wasInterrupted());
    }
};

//===----------------------------------------------------------------------===//
// Lowering Patterns
//===----------------------------------------------------------------------===//

/// Lower bf.alloc to call @elm_alloc_bytebuffer.
/// The runtime returns i64, which we cast to eco.value (the MLIR result type).
struct AllocOpLowering : public OpConversionPattern<bf::AllocOp> {
    const BFRuntimeFuncs &rt;
    AllocOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(AllocOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, rt.allocBytebuffer, ValueRange{adaptor.getSize()});

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.cursor.init to runtime calls for ptr and len.
struct CursorInitOpLowering : public OpConversionPattern<bf::CursorInitOp> {
    const BFRuntimeFuncs &rt;
    CursorInitOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(CursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        // Get data pointer
        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBuffer()});
        Value ptr = dataCall.getResult();

        // Get length
        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBuffer()});
        Value len = lenCall.getResult();

        // Compute end = ptr + len
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        // Create cursor struct
        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lower bf.write.u8 to store and cursor advance.
struct WriteU8OpLowering : public OpConversionPattern<bf::WriteU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i8
        Value byte = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI8Type(), adaptor.getValue());

        // Store byte
        rewriter.create<LLVM::StoreOp>(loc, byte, ptr);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        one, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.u16 to stores (with endianness) and cursor advance.
struct WriteU16OpLowering : public OpConversionPattern<bf::WriteU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i16
        Value val16 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI16Type(), adaptor.getValue());

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            val16 = rewriter.create<LLVM::ByteSwapOp>(loc, val16);
        }

        // Store as unaligned i16
        rewriter.create<LLVM::StoreOp>(loc, val16, ptr, /*alignment=*/1);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        two, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.u32 to stores (with endianness) and cursor advance.
struct WriteU32OpLowering : public OpConversionPattern<bf::WriteU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Truncate i64 value to i32
        Value val32 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI32Type(), adaptor.getValue());

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            val32 = rewriter.create<LLVM::ByteSwapOp>(loc, val32);
        }

        // Store as unaligned i32
        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.f32 to cast + store and cursor advance.
struct WriteF32OpLowering : public OpConversionPattern<bf::WriteF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Cast f64 to f32
        Value val32 = rewriter.create<LLVM::FPTruncOp>(
            loc, rewriter.getF32Type(), adaptor.getValue());

        // Bitcast f32 to i32 for byte swapping
        Value asInt = rewriter.create<LLVM::BitcastOp>(
            loc, rewriter.getI32Type(), val32);

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        // Bitcast back to f32
        val32 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), asInt);

        // Store as unaligned f32
        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.f64 to store and cursor advance.
struct WriteF64OpLowering : public OpConversionPattern<bf::WriteF64Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteF64Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value val64 = adaptor.getValue();

        // Bitcast f64 to i64 for byte swapping
        Value asInt = rewriter.create<LLVM::BitcastOp>(
            loc, rewriter.getI64Type(), val64);

        // Handle endianness
        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        // Bitcast back to f64
        val64 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), asInt);

        // Store as unaligned f64
        rewriter.create<LLVM::StoreOp>(loc, val64, ptr, /*alignment=*/1);

        // Advance cursor by 8
        Value eight = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        eight, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.bytes to memcpy and cursor advance.
struct WriteBytesOpLowering : public OpConversionPattern<bf::WriteBytesOp> {
    const BFRuntimeFuncs &rt;
    WriteBytesOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteBytesOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Get source data pointer
        auto srcDataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBytes()});
        Value srcPtr = srcDataCall.getResult();

        // Get source length
        auto srcLenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBytes()});
        Value len = srcLenCall.getResult();

        // Extend len to i64 for memcpy
        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), len);

        // memcpy(dst, src, len)
        rewriter.create<LLVM::MemcpyOp>(
            loc, ptr, srcPtr, len64, /*isVolatile=*/false);

        // Advance cursor by len
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        len, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.write.utf8 to call @elm_utf8_copy and cursor advance.
struct WriteUtf8OpLowering : public OpConversionPattern<bf::WriteUtf8Op> {
    const BFRuntimeFuncs &rt;
    WriteUtf8OpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteUtf8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Call elm_utf8_copy(string, ptr) -> bytesWritten
        auto copyCall = rewriter.create<LLVM::CallOp>(
            loc, rt.utf8Copy, ValueRange{adaptor.getString(), ptr});
        Value bytesWritten = copyCall.getResult();

        // Advance cursor by bytesWritten
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        bytesWritten, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.utf8_width to call @elm_utf8_width.
struct Utf8WidthOpLowering : public OpConversionPattern<bf::Utf8WidthOp> {
    const BFRuntimeFuncs &rt;
    Utf8WidthOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(Utf8WidthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, rt.utf8Width, ValueRange{adaptor.getString()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.bytes_width to call @elm_bytebuffer_len.
struct BytesWidthOpLowering : public OpConversionPattern<bf::BytesWidthOp> {
    const BFRuntimeFuncs &rt;
    BytesWidthOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(BytesWidthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBuffer()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.encoder.width to call @elm_encoder_size — the escape-hatch
/// width walker used when the reifier couldn't statically compute an
/// encoder subtree's byte width.
struct EncoderWidthOpLowering : public OpConversionPattern<bf::EncoderWidthOp> {
    const BFRuntimeFuncs &rt;
    EncoderWidthOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(EncoderWidthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto result = rewriter.create<LLVM::CallOp>(
            loc, rt.encoderSize, ValueRange{adaptor.getEncoder()});
        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};

/// Lower bf.write.encoder to call @elm_encoder_write_into and cursor
/// advance. Mirrors WriteUtf8OpLowering: call the runtime walker
/// against the cursor's current pointer, then advance by bytes-written.
struct WriteEncoderOpLowering : public OpConversionPattern<bf::WriteEncoderOp> {
    const BFRuntimeFuncs &rt;
    WriteEncoderOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteEncoderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Call elm_encoder_write_into(encoder, ptr) -> bytesWritten
        auto writeCall = rewriter.create<LLVM::CallOp>(
            loc, rt.encoderWriteInto, ValueRange{adaptor.getEncoder(), ptr});
        Value bytesWritten = writeCall.getResult();

        // Advance cursor by bytesWritten
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        bytesWritten, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lower bf.require to bounds check.
struct RequireOpLowering : public OpConversionPattern<bf::RequireOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RequireOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value end = extractEnd(rewriter, loc, adaptor.getCursor());

        // Compute ptr + bytes
        Value newPtr = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, adaptor.getBytes());

        // Compare newPtr <= end (unsigned)
        Value ok = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::ule, newPtr, end);

        rewriter.replaceOp(op, ok);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Read Operations Lowering (Decoder - Phase 2)
//===----------------------------------------------------------------------===//

/// Lower bf.read.u8 to load + zext + cursor advance.
struct ReadU8OpLowering : public OpConversionPattern<bf::ReadU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load byte
        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        // Zero-extend to i64 (Elm Int representation)
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), byte);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i8 to load + sext + cursor advance.
struct ReadI8OpLowering : public OpConversionPattern<bf::ReadI8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load byte
        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        // Sign-extend to i64 (Elm Int representation)
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), byte);

        // Advance cursor by 1
        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.u16 to byte-wise load + zext + cursor advance.
struct ReadU16OpLowering : public OpConversionPattern<bf::ReadU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 2 bytes
        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        // Extend to i16
        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

        // Combine based on endianness
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI16Type(), 8);
        Value val16;
        if (op.getEndianness() == bf::Endianness::BE) {
            // Big-endian: (b0 << 8) | b1
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b1_16);
        } else {
            // Little-endian: (b1 << 8) | b0
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b1_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b0_16);
        }

        // Zero-extend to i64
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val16);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i16 to byte-wise load + sext + cursor advance.
struct ReadI16OpLowering : public OpConversionPattern<bf::ReadI16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 2 bytes
        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        // Extend to i16
        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

        // Combine based on endianness
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI16Type(), 8);
        Value val16;
        if (op.getEndianness() == bf::Endianness::BE) {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b1_16);
        } else {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b1_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b0_16);
        }

        // Sign-extend to i64
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val16);

        // Advance cursor by 2
        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.u32 to byte-wise load + zext + cursor advance.
struct ReadU32OpLowering : public OpConversionPattern<bf::ReadU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Zero-extend to i64
        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val32);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.i32 to byte-wise load + sext + cursor advance.
struct ReadI32OpLowering : public OpConversionPattern<bf::ReadI32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Sign-extend to i64
        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val32);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.f32 to byte-wise load + bitcast + fpext + cursor advance.
struct ReadF32OpLowering : public OpConversionPattern<bf::ReadF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 4 bytes
        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i32 and combine
        Value val32 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 0);
        for (int i = 0; i < 4; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (3 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI32Type(), bytes[byteIdx]);
            int shift = (3 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI32Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val32 = rewriter.create<LLVM::OrOp>(loc, val32, ext);
        }

        // Bitcast i32 to f32
        Value f32Val = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), val32);

        // Extend f32 to f64 (Elm Float representation)
        Value value = rewriter.create<LLVM::FPExtOp>(loc, rewriter.getF64Type(), f32Val);

        // Advance cursor by 4
        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lower bf.read.f64 to byte-wise load + bitcast + cursor advance.
struct ReadF64OpLowering : public OpConversionPattern<bf::ReadF64Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF64Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        // Load 8 bytes
        Value bytes[8];
        for (int i = 0; i < 8; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

        // Extend to i64 and combine
        Value val64 = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI64Type(), 0);
        for (int i = 0; i < 8; ++i) {
            int byteIdx = (op.getEndianness() == bf::Endianness::BE) ? i : (7 - i);
            Value ext = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), bytes[byteIdx]);
            int shift = (7 - i) * 8;
            if (shift > 0) {
                Value shiftAmt = rewriter.create<LLVM::ConstantOp>(
                    loc, rewriter.getI64Type(), shift);
                ext = rewriter.create<LLVM::ShlOp>(loc, ext, shiftAmt);
            }
            val64 = rewriter.create<LLVM::OrOp>(loc, val64, ext);
        }

        // Bitcast i64 to f64 (Elm Float)
        Value value = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), val64);

        // Advance cursor by 8
        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), eight, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// The converted buffer `cursor` points into (CursorGCSafety found it
/// before the conversion), as the ptr addrspace(1) the runtime helpers take.
static Value convertedBufferOf(CursorGCSafety &gc, Value cursor,
                               ConversionPatternRewriter &rewriter) {
    Value buffer = gc.bufferOf(cursor);
    return buffer ? rewriter.getRemappedValue(buffer) : Value();
}

/// (ptr - data, end - data) for a cursor into a buffer whose data starts at
/// `data`, as i64 offsets.
static std::pair<Value, Value> cursorOffsets(OpBuilder &builder, Location loc,
                                             Value cursor, Value data) {
    auto i64 = builder.getI64Type();
    Value base = builder.create<LLVM::PtrToIntOp>(loc, i64, data);
    Value ptr = builder.create<LLVM::PtrToIntOp>(loc, i64, extractPtr(builder, loc, cursor));
    Value end = builder.create<LLVM::PtrToIntOp>(loc, i64, extractEnd(builder, loc, cursor));
    return {builder.create<LLVM::SubOp>(loc, ptr, base),
            builder.create<LLVM::SubOp>(loc, end, base)};
}

/// Lower bf.cursor.offsets to the cursor's offsets from its buffer's data.
struct CursorOffsetsOpLowering : public OpConversionPattern<bf::CursorOffsetsOp> {
    const BFRuntimeFuncs &rt;
    CursorOffsetsOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(bf::CursorOffsetsOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value data = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBuffer()}).getResult();
        auto [pos, end] = cursorOffsets(rewriter, loc, adaptor.getCursor(), data);
        rewriter.replaceOp(op, {pos, end});
        return success();
    }
};

/// Lower bf.cursor.rebase to a cursor at the offsets from the buffer's data,
/// read now (after a GC that may have moved the buffer).
struct CursorRebaseOpLowering : public OpConversionPattern<bf::CursorRebaseOp> {
    const BFRuntimeFuncs &rt;
    CursorRebaseOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(bf::CursorRebaseOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value data = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBuffer()}).getResult();
        Value ptr = rewriter.create<LLVM::GEPOp>(
            loc, data.getType(), rewriter.getI8Type(), data, adaptor.getPos());
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, data.getType(), rewriter.getI8Type(), data, adaptor.getEnd());
        Type cursorType = getTypeConverter()->convertType(op.getType());
        rewriter.replaceOp(op, createCursor(rewriter, loc, ptr, end, cursorType));
        return success();
    }
};

/// Lower bf.builder.begin / bf.builder.end to the runtime calls that set and
/// clear the buffer's builder bit.
template <typename OpT>
struct BuilderBitOpLowering : public OpConversionPattern<OpT> {
    LLVM::LLVMFuncOp fn;
    BuilderBitOpLowering(const TypeConverter &tc, MLIRContext *ctx, LLVM::LLVMFuncOp fn)
        : OpConversionPattern<OpT>(tc, ctx), fn(fn) {}

    LogicalResult
    matchAndRewrite(OpT op, typename OpT::Adaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        rewriter.create<LLVM::CallOp>(op.getLoc(), fn, ValueRange{adaptor.getBuffer()});
        rewriter.eraseOp(op);
        return success();
    }
};

/// Lower bf.read.bytes to allocate + memcpy + cursor advance. The allocation
/// may run a GC that moves the source buffer, so the source pointer and the
/// new cursor are re-derived from the (relocated) buffer after it
/// (BFOPS_039).
struct ReadBytesOpLowering : public OpConversionPattern<bf::ReadBytesOp> {
    const BFRuntimeFuncs &rt;
    CursorGCSafety &gc;
    ReadBytesOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt,
                        CursorGCSafety &gc)
        : OpConversionPattern(tc, ctx), rt(rt), gc(gc) {}

    LogicalResult
    matchAndRewrite(ReadBytesOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());
        Value source = convertedBufferOf(gc, op.getCursor(), rewriter);
        if (!source)
            return rewriter.notifyMatchFailure(op, "buffer of the cursor unknown");

        // Offsets of the cursor in the source, before the allocation.
        Value data0 = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{source}).getResult();
        auto [pos, endOff] = cursorOffsets(rewriter, loc, adaptor.getCursor(), data0);

        // Allocate new ByteBuffer (may run a GC).
        auto allocCall = rewriter.create<LLVM::CallOp>(
            loc, rt.allocBytebuffer, ValueRange{adaptor.getLen()});
        Value newBuffer = allocCall.getResult();

        // Re-derive the source pointer from the relocated buffer.
        Value data1 = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{source}).getResult();
        Value srcPtr = rewriter.create<LLVM::GEPOp>(
            loc, data1.getType(), rewriter.getI8Type(), data1, pos);
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, data1.getType(), rewriter.getI8Type(), data1, endOff);

        // Get destination data pointer
        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{newBuffer});
        Value dstPtr = dataCall.getResult();

        // Copy bytes: memcpy(dst, src, len)
        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), adaptor.getLen());
        rewriter.create<LLVM::MemcpyOp>(loc, dstPtr, srcPtr, len64, /*isVolatile=*/false);

        // Advance cursor by len
        Value newCursor = advanceCursor(
            rewriter, loc, createCursor(rewriter, loc, srcPtr, end, cursorType),
            adaptor.getLen(), cursorType);

        // ok = true (allocation success assumed for simplicity)
        Value ok = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI1Type(), 1);

        rewriter.replaceOp(op, {newBuffer, newCursor, ok});
        return success();
    }
};

/// Lower bf.read.utf8 to runtime call + cursor advance. elm_utf8_decode takes
/// the buffer and the offset (it allocates, and roots the buffer across
/// that); the new cursor is re-derived from the relocated buffer after the
/// call (BFOPS_039).
struct ReadUtf8OpLowering : public OpConversionPattern<bf::ReadUtf8Op> {
    const BFRuntimeFuncs &rt;
    CursorGCSafety &gc;
    ReadUtf8OpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt,
                       CursorGCSafety &gc)
        : OpConversionPattern(tc, ctx), rt(rt), gc(gc) {}

    LogicalResult
    matchAndRewrite(ReadUtf8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());
        Value source = convertedBufferOf(gc, op.getCursor(), rewriter);
        if (!source)
            return rewriter.notifyMatchFailure(op, "buffer of the cursor unknown");

        Value data0 = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{source}).getResult();
        auto [pos, endOff] = cursorOffsets(rewriter, loc, adaptor.getCursor(), data0);
        Value pos32 = rewriter.create<LLVM::TruncOp>(loc, rewriter.getI32Type(), pos);

        // Call elm_utf8_decode(buffer, offset, len) -> eco.value (0 on failure)
        auto decodeCall = rewriter.create<LLVM::CallOp>(
            loc, rt.utf8Decode, ValueRange{source, pos32, adaptor.getLen()});
        Value stringVal = decodeCall.getResult();

        // ok = (stringVal != null)
        auto hptrTy = LLVM::LLVMPointerType::get(rewriter.getContext(), 1);
        Value nullPtr = rewriter.create<LLVM::ZeroOp>(loc, hptrTy);
        Value ok = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::ne, stringVal, nullPtr);

        // Re-derive the cursor from the relocated buffer, advanced by len.
        Value data1 = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{source}).getResult();
        Value ptr = rewriter.create<LLVM::GEPOp>(
            loc, data1.getType(), rewriter.getI8Type(), data1, pos);
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, data1.getType(), rewriter.getI8Type(), data1, endOff);
        Value newCursor = advanceCursor(
            rewriter, loc, createCursor(rewriter, loc, ptr, end, cursorType),
            adaptor.getLen(), cursorType);

        rewriter.replaceOp(op, {stringVal, newCursor, ok});
        return success();
    }
};

/// Lower bf.decoder.cursor.init - same as bf.cursor.init.
struct DecoderCursorInitOpLowering : public OpConversionPattern<bf::DecoderCursorInitOp> {
    const BFRuntimeFuncs &rt;
    DecoderCursorInitOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(DecoderCursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        // Get data pointer
        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBytes()});
        Value ptr = dataCall.getResult();

        // Get length
        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBytes()});
        Value len = lenCall.getResult();

        // Compute end = ptr + len
        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        // Create cursor struct
        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lower bf.cursor.ptr to extract current pointer.
struct CursorPtrOpLowering : public OpConversionPattern<bf::CursorPtrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CursorPtrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        // Cast pointer to i64
        Value ptrAsInt = rewriter.create<LLVM::PtrToIntOp>(
            loc, rewriter.getI64Type(), ptr);
        rewriter.replaceOp(op, ptrAsInt);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

struct BFToLLVMPass : public PassWrapper<BFToLLVMPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(BFToLLVMPass)

    StringRef getArgument() const override { return "bf-to-llvm"; }
    StringRef getDescription() const override {
        return "Lower BF dialect to LLVM dialect";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<LLVM::LLVMDialect>();
        registry.insert<bf::BFDialect>();
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        // Early-out: bf.* ops appear only in bytes encoder/decoder functions,
        // a small fraction of any program. When the module has none, skip the
        // runtime-function declarations (a SymbolTable build + 10 dead decls)
        // and the whole-module conversion driver entirely.
        //
        // Plan 07 P10: find the top-level ops that hold a bf op with one
        // parallel scan, and convert only those. Every other op is legal, so
        // the whole-module driver only legality-checked ~4M ops serially.
        Dialect *bfDialect = ctx->getLoadedDialect<bf::BFDialect>();
        SmallVector<Operation *> tops;
        for (Operation &op : *module.getBody())
            tops.push_back(&op);
        std::vector<uint8_t> hasBf(tops.size(), 0);
        eco::forEachChunk(ctx, tops.size(), [&](size_t lo, size_t hi) {
            for (size_t i = lo; i < hi; ++i)
                tops[i]->walk([&](Operation *op) {
                    if (op->getDialect() == bfDialect) {
                        hasBf[i] = 1;
                        return WalkResult::interrupt();
                    }
                    return WalkResult::advance();
                });
        });
        SmallVector<Operation *> bfTops;
        for (size_t i = 0; i < tops.size(); ++i)
            if (hasBf[i])
                bfTops.push_back(tops[i]);
        if (bfTops.empty())
            return;

        // Ensure runtime functions are declared and cache their references
        // (one symbol table for O(1) lookups, shared with the GC analysis).
        OpBuilder builder(ctx);
        mlir::SymbolTable symTable(module);
        BFRuntimeFuncs rtFuncs = ensureRuntimeFunctions(module, builder, symTable);

        // Re-derive every cursor live across an op that may run a GC, and
        // check that none is left (BFOPS_039). Before the conversion, on the
        // bf ops; the read.bytes / read.utf8 lowerings use its buffer map.
        CursorGCSafety gcSafety(symTable);
        for (Operation *top : bfTops)
            if (failed(gcSafety.run(top))) {
                signalPassFailure();
                return;
            }

        // Set up type converter
        BFTypeConverter typeConverter(ctx);

        // Set up conversion target
        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addIllegalDialect<bf::BFDialect>();
        // Mark all other ops as legal - they'll be converted by later passes.
        // This includes eco dialect, func, arith, etc.
        target.markUnknownOpDynamicallyLegal([](Operation *op) { return true; });

        // Populate patterns — patterns that need runtime functions get cached refs
        RewritePatternSet patterns(ctx);

        // Patterns with cached runtime function references (no module.lookupSymbol)
        patterns.add<AllocOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<CursorInitOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<DecoderCursorInitOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<WriteBytesOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<WriteUtf8OpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<Utf8WidthOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<BytesWidthOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<EncoderWidthOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<WriteEncoderOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<ReadBytesOpLowering>(typeConverter, ctx, rtFuncs, gcSafety);
        patterns.add<ReadUtf8OpLowering>(typeConverter, ctx, rtFuncs, gcSafety);
        patterns.add<CursorOffsetsOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<CursorRebaseOpLowering>(typeConverter, ctx, rtFuncs);
        patterns.add<BuilderBitOpLowering<bf::BuilderBeginOp>>(typeConverter, ctx,
                                                                rtFuncs.builderBegin);
        patterns.add<BuilderBitOpLowering<bf::BuilderEndOp>>(typeConverter, ctx,
                                                              rtFuncs.builderEnd);

        // Patterns that don't need runtime function lookups
        patterns.add<
            CursorPtrOpLowering,
            WriteU8OpLowering,
            WriteU16OpLowering,
            WriteU32OpLowering,
            WriteF32OpLowering,
            WriteF64OpLowering,
            RequireOpLowering,
            ReadU8OpLowering,
            ReadI8OpLowering,
            ReadU16OpLowering,
            ReadI16OpLowering,
            ReadU32OpLowering,
            ReadI32OpLowering,
            ReadF32OpLowering,
            ReadF64OpLowering
        >(typeConverter, ctx);

        if (failed(applyPartialConversion(bfTops, target, std::move(patterns))))
            signalPassFailure();
    }
};

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

namespace eco {

std::unique_ptr<Pass> createBFToLLVMPass() {
    return std::make_unique<BFToLLVMPass>();
}

} // namespace eco
