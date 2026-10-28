//===- BFToLLVM.cpp - BF dialect to LLVM dialect lowering -----------------===//
//
// The BF (ByteFusion) dialect describes fused Bytes encoders and decoders as
// straight-line reads and writes through a cursor, and this pass turns it into
// LLVM dialect so that those reads and writes become plain loads and stores.
//
// A cursor (`bf.cursor`) is a position in a ByteBuffer's body together with the
// end of that body. It lowers to an LLVM struct of two raw pointers,
// `{current, end}`. Most bf ops lower to inline LLVM ops on that struct: a load
// or store at `current`, then a new cursor with `current` advanced. The rest
// call `elm_*` runtime helpers, which this pass declares in the module.
//
// Raw pointers are what make the lowering fast, and they are also its one
// hazard. A ByteBuffer below the large-object threshold lives in the nursery,
// and a minor GC moves it, so a cursor that is live across an op that may run
// a GC would point into memory the buffer has left. The buffer itself is an
// `eco.value`, a ptr addrspace(1) that RS4GC relocates across a GC, so the fix
// is to re-derive the cursor from its buffer. The largest single piece of this
// file is that re-derivation (`CursorGCSafety`, invariant BFOPS_039), which
// runs on the bf ops before any of them is converted. The lowering patterns
// that follow it are many, short and mostly alike.
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

/// The type converter for this pass: a `bf.cursor` becomes the LLVM struct
/// `{ptr, ptr}` (current, end), and an `eco.value` becomes ptr addrspace(1).
///
/// The `eco.value` conversion must agree with the one EcoToLLVM uses, since
/// both passes convert the same values.
class BFTypeConverter : public LLVMTypeConverter {
public:
    explicit BFTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
        addConversion([](bf::CursorType type) -> Type {
            auto ptrType = LLVM::LLVMPointerType::get(type.getContext());
            return LLVM::LLVMStructType::getLiteral(type.getContext(),
                                                     {ptrType, ptrType});
        });

        addConversion([](eco::ValueType type) -> Type {
            return LLVM::LLVMPointerType::get(type.getContext(), /*addressSpace=*/1);
        });

        // Both materializations bridge any one-value type mismatch with an
        // unrealized_conversion_cast, for later passes to resolve.
        addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                    ValueRange inputs, Location loc) -> Value {
            if (inputs.size() != 1)
                return nullptr;
            return builder.create<UnrealizedConversionCastOp>(
                loc, resultType, inputs).getResult(0);
        });

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

/// The runtime helper declarations the lowering patterns call, found or
/// created once per module by `ensureRuntimeFunctions`.
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

/// Returns the runtime helpers the patterns call, declaring in `module` each
/// one that `symTable` does not already hold as an LLVM function.
///
/// It also declares `elm_maybe_nothing` and `elm_maybe_just`, which the result
/// does not include. New declarations go at the start of the module body and
/// are added to `symTable`. When it declares anything, `builder`'s insertion
/// point is left at the start of the module body.
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

/// Builds a cursor value of LLVM type `cursorLLVMType` from `ptr` (current)
/// and `end`.
static Value createCursor(OpBuilder &builder, Location loc, Value ptr,
                          Value end, Type cursorLLVMType) {
    Value cursor = builder.create<LLVM::UndefOp>(loc, cursorLLVMType);
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, ptr,
                                                  ArrayRef<int64_t>{0});
    cursor = builder.create<LLVM::InsertValueOp>(loc, cursor, end,
                                                  ArrayRef<int64_t>{1});
    return cursor;
}

/// Returns the current pointer of a lowered `cursor`.
static Value extractPtr(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{0});
}

/// Returns the end pointer of a lowered `cursor`.
static Value extractEnd(OpBuilder &builder, Location loc, Value cursor) {
    auto ptrType = LLVM::LLVMPointerType::get(builder.getContext());
    return builder.create<LLVM::ExtractValueOp>(loc, ptrType, cursor,
                                                 ArrayRef<int64_t>{1});
}

/// Returns a lowered cursor whose current pointer is `bytes` bytes past
/// `cursor`'s and whose end is the same. Nothing checks it against the end.
static Value advanceCursor(OpBuilder &builder, Location loc, Value cursor,
                           Value bytes, Type cursorLLVMType) {
    Value ptr = extractPtr(builder, loc, cursor);
    Value end = extractEnd(builder, loc, cursor);

    Value newPtr = builder.create<LLVM::GEPOp>(
        loc, ptr.getType(), builder.getI8Type(), ptr, bytes);

    return createCursor(builder, loc, newPtr, end, cursorLLVMType);
}

//===----------------------------------------------------------------------===//
// Cursors across GC points (BFOPS_039)
//===----------------------------------------------------------------------===//
//
// A GC point here is an op that may run a GC, as `mayCollect` decides. Every
// cursor that is live across a GC point is re-derived from its buffer:
// bf.cursor.offsets before the op records the cursor's two offsets from the
// start of the buffer's body, and bf.cursor.rebase after it builds a new
// cursor at those offsets in the (possibly moved) body. A structural check
// then rejects any cursor use still reachable from its definition through a
// GC point.
//
// To re-derive a cursor, its buffer must be known. Cursors are grouped into
// classes with a union-find: a cursor made by bf.cursor.init or
// bf.decoder.cursor.init starts a class whose buffer is that op's operand, and
// a cursor that a bf op, a loop, a region result or a branch argument passes
// along joins the class of the cursor it came from. A class reached from two
// different buffers is ambiguous and has no known buffer.
//
// bf.read.bytes and bf.read.utf8 are GC points themselves. Their own
// lowerings re-derive the cursor (and, for read.bytes, the source pointer)
// from the buffer this analysis finds for their cursor, after the allocation;
// elm_utf8_decode re-derives its own source pointer.

/// The analysis and rewrite described above, for the top-level ops of one
/// module.
///
/// One object is run on each top-level op in turn, and its cursor classes
/// accumulate across them. After `run` it answers `bufferOf` for the lowering
/// patterns, so it must outlive the conversion.
class CursorGCSafety {
public:
    /// Creates an analysis that looks up callees in `symbols`, which it keeps
    /// a reference to and which must outlive it.
    explicit CursorGCSafety(SymbolTable &symbols) : symbols(symbols) {}

    /// Rewrites `top` so that no cursor is live across a GC point, then checks
    /// that none is. Emits an error on the offending op and fails when a
    /// cursor that must be re-derived has no single buffer in scope, when an
    /// encoder buffer that must be a builder was not made by bf.alloc or has a
    /// cursor used outside the bf.alloc's block or by a terminator, or when the
    /// check finds a cursor use reachable through a GC point. On failure `top`
    /// may already be partly rewritten.
    LogicalResult run(Operation *top) {
        buildClasses(top);
        if (failed(insertRebases(top)) || failed(insertBuilders(top)))
            return failure();
        return verify(top);
    }

    /// Returns the buffer `cursor` points into, or a null value when its class
    /// has no buffer or two different ones.
    Value bufferOf(Value cursor) {
        Value rep = find(cursor);
        auto it = buffers.find(rep);
        return it == buffers.end() || ambiguous.contains(rep) ? Value() : it->second;
    }

    /// Returns whether `op`, or an op nested in it, may run a GC.
    ///
    /// The answer is conservative: an op not known to be GC-free counts as a GC
    /// point. A bf op is one only if it is bf.alloc, bf.read.bytes or
    /// bf.read.utf8. An `eco.call` is not one if it carries
    /// `eco.callee_gc_leaf`, and neither is any `eco.call`, `func.call` or
    /// `llvm.call` whose callee is a scratch helper, a cursor marker (as
    /// `eco::markers` defines them) or an LLVM function declared with the
    /// `gc-leaf-function` passthrough. An scf op or `eco.case` is one only if
    /// something inside it is; any other op with regions is one. Other LLVM
    /// ops and terminators are not. A pure op is one only if it is an
    /// `eco.construct.*` (list, tuple, record, custom) or `eco.box`. Any other
    /// op is. Answers are memoized per op.
    bool mayCollect(Operation *op) {
        auto it = memo.find(op);
        if (it != memo.end())
            return it->second;
        bool r = computeMayCollect(op);
        memo[op] = r;
        return r;
    }

private:
    SymbolTable &symbols; ///< The module's symbols, owned by the caller.
    DenseMap<Operation *, bool> memo; ///< `mayCollect` answers so far.
    /// Union-find over cursor values: one class per set of cursors that point
    /// into the same buffer. A value absent from `parent` is its own class.
    DenseMap<Value, Value> parent;
    DenseMap<Value, Value> buffers;       ///< Class representative -> buffer.
    llvm::DenseSet<Value> ambiguous;      ///< Representatives with two buffers.
    SmallVector<Value> cursors;           ///< Every cursor value seen, including rebased ones.
    SmallVector<Value> rebasedCursors;    ///< One member per rebase inserted.

    /// Returns whether `v` is a `bf.cursor`.
    static bool isCursor(Value v) { return isa<bf::CursorType>(v.getType()); }

    /// Returns whether `op` belongs to the dialect with namespace `ns`.
    static bool inDialect(Operation *op, StringRef ns) {
        return op->getName().getDialectNamespace() == ns;
    }

    /// Returns whether a call to `name` cannot run a GC: it is a scratch
    /// helper, a cursor marker, or an LLVM function in `symbols` declared with
    /// the `gc-leaf-function` passthrough.
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

    /// Computes `mayCollect` for `op` without consulting the memo for `op`
    /// itself.
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

    /// Returns the representative of `v`'s class, compressing the path.
    Value find(Value v) {
        auto it = parent.find(v);
        if (it == parent.end() || it->second == v)
            return v;
        Value root = find(it->second);
        parent[v] = root;
        return root;
    }

    /// Merges the classes of `a` and `b` when both are cursors, keeping `b`'s
    /// representative. A buffer `a`'s class had is recorded for the merged
    /// class, which becomes ambiguous if it differs from `b`'s.
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

    /// Records `buffer` as the buffer of the class `rep` represents, marking
    /// the class ambiguous if it already had a different one.
    void setBuffer(Value rep, Value buffer) {
        auto [it, inserted] = buffers.try_emplace(rep, buffer);
        if (!inserted && it->second != buffer)
            ambiguous.insert(rep);
    }

    /// Unites `a` and `b` pairwise, up to the shorter of the two.
    void uniteRange(ValueRange a, ValueRange b) {
        for (auto [x, y] : llvm::zip(a, b))
            unite(x, y);
    }

    /// Collects every cursor block argument and op result in `top`, and puts
    /// each cursor into the class of the cursor it is derived from.
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

    /// Returns whether `v` is defined in a block that contains `op`, or an
    /// ancestor of it, and before that ancestor. This is structural dominance:
    /// it looks only up the region nesting, not across blocks.
    static bool visibleAt(Value v, Operation *op) {
        Block *defBlock = v.getParentBlock();
        Operation *anc = defBlock->findAncestorOpInBlock(*op);
        if (!anc)
            return false;
        Operation *def = v.getDefiningOp();
        return !def || (def != anc && def->isBeforeInBlock(anc));
    }

    /// Returns whether `v` has a use, possibly nested, in an op after `op` in
    /// `op`'s block.
    static bool usedAfter(Value v, Operation *op) {
        Block *block = op->getBlock();
        for (Operation *user : v.getUsers()) {
            Operation *anc = block->findAncestorOpInBlock(*user);
            if (anc && anc != op && op->isBeforeInBlock(anc))
                return true;
        }
        return false;
    }

    /// Sets `buffer` to the buffer of `cursor` and succeeds when that buffer is
    /// known, is an `eco.value` and is visible at `at`. Otherwise emits an
    /// error on `at` and fails; `buffer` then holds whatever `bufferOf` gave.
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

    /// Brackets each GC point in `top` with bf.cursor.offsets and
    /// bf.cursor.rebase for every cursor visible at it and used after it, and
    /// redirects those later uses to the rebased cursor. Also requires a known
    /// buffer for the cursor of every bf.read.bytes and bf.read.utf8. Fails,
    /// with an error emitted, as `bufferFor` does.
    ///
    /// A cursor used inside a nested op after the GC point is redirected too.
    /// A rebased cursor joins the class of the one it replaces and is itself
    /// considered at later GC points.
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
        // The two allocating reads need their cursor's buffer whether or not
        // a cursor is live across them: their lowerings re-derive from it.
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

    /// Marks as a builder each buffer that an encoder writes after a GC point,
    /// by inserting bf.builder.begin right after its bf.alloc and
    /// bf.builder.end after the last op in that block that uses one of its
    /// rebased cursor classes.
    ///
    /// A buffer written after a GC point has survived a GC. HEAP_SNAPSHOT_001
    /// forbids writing into an object that has survived a GC unless its
    /// builder bit is set, and a builder is kept young until the bit is
    /// cleared (HEAP_BUILDER_001). An encoder buffer is one reached from a
    /// bf.cursor.init, not a bf.decoder.cursor.init. Fails with an error when
    /// such a buffer is not the result of bf.alloc, or when one of its cursors
    /// is used outside the bf.alloc's block or by a terminator.
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

    /// Returns a GC point that lies on some path from `v`'s definition to
    /// `user`, or null if there is none.
    ///
    /// A loop containing `user` that may collect counts as one, because a
    /// later iteration reuses the cursor after the GC. When `user` is in a
    /// different block of the same region as the definition, any GC point
    /// anywhere in that region counts.
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

    /// Checks that no cursor operand in `top` is reachable from its definition
    /// through a GC point, and emits an error on the first use that is.
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

/// Lowers bf.alloc to a call of `elm_alloc_bytebuffer`, whose ptr addrspace(1)
/// result is the converted `eco.value` with no cast.
///
/// Like every pattern here that takes `rt`, it keeps a reference to it, which
/// must outlive the pattern.
struct AllocOpLowering : public OpConversionPattern<bf::AllocOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations.
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

/// Lowers bf.cursor.init to a cursor from the buffer's data pointer to that
/// pointer plus its length, both read from the runtime.
struct CursorInitOpLowering : public OpConversionPattern<bf::CursorInitOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
    CursorInitOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(CursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBuffer()});
        Value ptr = dataCall.getResult();

        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBuffer()});
        Value len = lenCall.getResult();

        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lowers bf.write.u8 to a store of the value's low byte and a cursor one byte
/// further on.
struct WriteU8OpLowering : public OpConversionPattern<bf::WriteU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value byte = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI8Type(), adaptor.getValue());

        rewriter.create<LLVM::StoreOp>(loc, byte, ptr);

        Value one = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        one, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.u16 to an unaligned store of the value's low 16 bits and a
/// cursor two bytes further on.
///
/// The bytes are swapped for big-endian and stored as they are otherwise, so
/// the result is right only on a little-endian target. The 32-bit and float
/// writes below do the same.
struct WriteU16OpLowering : public OpConversionPattern<bf::WriteU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value val16 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI16Type(), adaptor.getValue());

        if (op.getEndianness() == bf::Endianness::BE) {
            val16 = rewriter.create<LLVM::ByteSwapOp>(loc, val16);
        }

        rewriter.create<LLVM::StoreOp>(loc, val16, ptr, /*alignment=*/1);

        Value two = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        two, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.u32 to an unaligned store of the value's low 32 bits and a
/// cursor four bytes further on.
struct WriteU32OpLowering : public OpConversionPattern<bf::WriteU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value val32 = rewriter.create<LLVM::TruncOp>(
            loc, rewriter.getI32Type(), adaptor.getValue());

        if (op.getEndianness() == bf::Endianness::BE) {
            val32 = rewriter.create<LLVM::ByteSwapOp>(loc, val32);
        }

        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.f32 to an unaligned store of the f64 value rounded to f32,
/// and a cursor four bytes further on.
struct WriteF32OpLowering : public OpConversionPattern<bf::WriteF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(WriteF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value val32 = rewriter.create<LLVM::FPTruncOp>(
            loc, rewriter.getF32Type(), adaptor.getValue());

        // Bitcast f32 to i32 for byte swapping
        Value asInt = rewriter.create<LLVM::BitcastOp>(
            loc, rewriter.getI32Type(), val32);

        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        val32 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), asInt);

        rewriter.create<LLVM::StoreOp>(loc, val32, ptr, /*alignment=*/1);

        Value four = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        four, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.f64 to an unaligned store of the value and a cursor eight
/// bytes further on.
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

        if (op.getEndianness() == bf::Endianness::BE) {
            asInt = rewriter.create<LLVM::ByteSwapOp>(loc, asInt);
        }

        val64 = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), asInt);

        rewriter.create<LLVM::StoreOp>(loc, val64, ptr, /*alignment=*/1);

        Value eight = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        eight, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.bytes to a memcpy of the source buffer's whole contents and
/// a cursor that many bytes further on.
struct WriteBytesOpLowering : public OpConversionPattern<bf::WriteBytesOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
    WriteBytesOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteBytesOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        auto srcDataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBytes()});
        Value srcPtr = srcDataCall.getResult();

        auto srcLenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBytes()});
        Value len = srcLenCall.getResult();

        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), len);

        rewriter.create<LLVM::MemcpyOp>(
            loc, ptr, srcPtr, len64, /*isVolatile=*/false);

        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        len, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.write.utf8 to a call of `elm_utf8_copy`, and a cursor advanced by
/// the byte count it returns.
struct WriteUtf8OpLowering : public OpConversionPattern<bf::WriteUtf8Op> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
    WriteUtf8OpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteUtf8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        auto copyCall = rewriter.create<LLVM::CallOp>(
            loc, rt.utf8Copy, ValueRange{adaptor.getString(), ptr});
        Value bytesWritten = copyCall.getResult();

        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        bytesWritten, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.utf8_width to a call of `elm_utf8_width`.
struct Utf8WidthOpLowering : public OpConversionPattern<bf::Utf8WidthOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
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

/// Lowers bf.bytes_width to a call of `elm_bytebuffer_len`.
struct BytesWidthOpLowering : public OpConversionPattern<bf::BytesWidthOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
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

/// Lowers bf.encoder.width to a call of `elm_encoder_size`, the runtime walker
/// that measures an encoder tree's width in bytes.
struct EncoderWidthOpLowering : public OpConversionPattern<bf::EncoderWidthOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
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

/// Lowers bf.write.encoder to a call of `elm_encoder_write_into` at the
/// cursor's current pointer, and a cursor advanced by the byte count it
/// returns.
///
/// `mayCollect` does not count this op as a GC point, so the walker must not
/// run a GC.
struct WriteEncoderOpLowering : public OpConversionPattern<bf::WriteEncoderOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
    WriteEncoderOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(WriteEncoderOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        auto writeCall = rewriter.create<LLVM::CallOp>(
            loc, rt.encoderWriteInto, ValueRange{adaptor.getEncoder(), ptr});
        Value bytesWritten = writeCall.getResult();

        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(),
                                        bytesWritten, cursorType);

        rewriter.replaceOp(op, newCursor);
        return success();
    }
};

/// Lowers bf.require to an i1 that is true when the cursor's current pointer
/// plus the required byte count does not pass its end, compared unsigned.
struct RequireOpLowering : public OpConversionPattern<bf::RequireOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(RequireOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value end = extractEnd(rewriter, loc, adaptor.getCursor());

        Value newPtr = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, adaptor.getBytes());

        Value ok = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::ule, newPtr, end);

        rewriter.replaceOp(op, ok);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Read Operations Lowering (Decoder)
//===----------------------------------------------------------------------===//
//
// Each fixed-width read loads its bytes one at a time and assembles them in
// the requested byte order, so it is independent of the target's endianness
// and alignment. Integers are widened to i64 and floats to f64, and each read
// yields the value and a cursor past it. No read checks the end; a preceding
// bf.require is what checks the end.

/// Lowers bf.read.u8 to a byte load zero-extended to i64.
struct ReadU8OpLowering : public OpConversionPattern<bf::ReadU8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), byte);

        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.i8 to a byte load sign-extended to i64.
struct ReadI8OpLowering : public OpConversionPattern<bf::ReadI8Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI8Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value byte = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);

        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), byte);

        Value one = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), one, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.u16 to a 16-bit value zero-extended to i64.
struct ReadU16OpLowering : public OpConversionPattern<bf::ReadU16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

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

        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val16);

        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.i16 to a 16-bit value sign-extended to i64.
struct ReadI16OpLowering : public OpConversionPattern<bf::ReadI16Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI16Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value b0 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr);
        Value oneVal = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 1);
        Value ptr1 = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, oneVal);
        Value b1 = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptr1);

        Value b0_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b0);
        Value b1_16 = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI16Type(), b1);

        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI16Type(), 8);
        Value val16;
        if (op.getEndianness() == bf::Endianness::BE) {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b1_16);
        } else {
            Value shifted = rewriter.create<LLVM::ShlOp>(loc, b1_16, eight);
            val16 = rewriter.create<LLVM::OrOp>(loc, shifted, b0_16);
        }

        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val16);

        Value two = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 2);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), two, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.u32 to a 32-bit value zero-extended to i64.
struct ReadU32OpLowering : public OpConversionPattern<bf::ReadU32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadU32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

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

        Value value = rewriter.create<LLVM::ZExtOp>(loc, rewriter.getI64Type(), val32);

        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.i32 to a 32-bit value sign-extended to i64.
struct ReadI32OpLowering : public OpConversionPattern<bf::ReadI32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadI32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

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

        Value value = rewriter.create<LLVM::SExtOp>(loc, rewriter.getI64Type(), val32);

        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.f32 to a 32-bit pattern read as f32 and extended to f64.
struct ReadF32OpLowering : public OpConversionPattern<bf::ReadF32Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF32Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value bytes[4];
        for (int i = 0; i < 4; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

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

        Value f32Val = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF32Type(), val32);

        Value value = rewriter.create<LLVM::FPExtOp>(loc, rewriter.getF64Type(), f32Val);

        Value four = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 4);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), four, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Lowers bf.read.f64 to a 64-bit pattern read as f64.
struct ReadF64OpLowering : public OpConversionPattern<bf::ReadF64Op> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(ReadF64Op op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Type cursorType = getTypeConverter()->convertType(op.getNewCursor().getType());

        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());

        Value bytes[8];
        for (int i = 0; i < 8; ++i) {
            Value offset = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), i);
            Value ptrI = rewriter.create<LLVM::GEPOp>(
                loc, ptr.getType(), rewriter.getI8Type(), ptr, offset);
            bytes[i] = rewriter.create<LLVM::LoadOp>(loc, rewriter.getI8Type(), ptrI);
        }

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

        Value value = rewriter.create<LLVM::BitcastOp>(loc, rewriter.getF64Type(), val64);

        Value eight = rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI32Type(), 8);
        Value newCursor = advanceCursor(rewriter, loc, adaptor.getCursor(), eight, cursorType);

        rewriter.replaceOp(op, {value, newCursor});
        return success();
    }
};

/// Returns the converted form of the buffer `gc` found for `cursor`, or a null
/// value when it found none.
static Value convertedBufferOf(CursorGCSafety &gc, Value cursor,
                               ConversionPatternRewriter &rewriter) {
    Value buffer = gc.bufferOf(cursor);
    return buffer ? rewriter.getRemappedValue(buffer) : Value();
}

/// Returns the i64 offsets of a lowered `cursor`'s current and end pointers
/// from `data`, the start of its buffer's body.
static std::pair<Value, Value> cursorOffsets(OpBuilder &builder, Location loc,
                                             Value cursor, Value data) {
    auto i64 = builder.getI64Type();
    Value base = builder.create<LLVM::PtrToIntOp>(loc, i64, data);
    Value ptr = builder.create<LLVM::PtrToIntOp>(loc, i64, extractPtr(builder, loc, cursor));
    Value end = builder.create<LLVM::PtrToIntOp>(loc, i64, extractEnd(builder, loc, cursor));
    return {builder.create<LLVM::SubOp>(loc, ptr, base),
            builder.create<LLVM::SubOp>(loc, end, base)};
}

/// Lowers bf.cursor.offsets to the cursor's two offsets from the start of its
/// buffer's body.
struct CursorOffsetsOpLowering : public OpConversionPattern<bf::CursorOffsetsOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
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

/// Lowers bf.cursor.rebase to a cursor at the given offsets from the start of
/// the buffer's body, as the body is at that point.
struct CursorRebaseOpLowering : public OpConversionPattern<bf::CursorRebaseOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
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

/// Lowers bf.builder.begin or bf.builder.end, whichever `OpT` is, to a call of
/// `fn` on the buffer. `fn` is the runtime function that sets or clears the
/// buffer's builder bit, as `elm_bytebuffer_builder_begin` describes.
template <typename OpT>
struct BuilderBitOpLowering : public OpConversionPattern<OpT> {
    LLVM::LLVMFuncOp fn;
    /// Creates the pattern calling `fn`.
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

/// Lowers bf.read.bytes to a new ByteBuffer holding the next `len` bytes, a
/// cursor past them, and an `ok` that is always true.
///
/// The allocation may run a GC that moves the source buffer, so the cursor's
/// offsets are taken before it and the source pointer and new cursor are
/// rebuilt from the source buffer after it. The pattern fails to match when
/// `gc` knows no buffer for the cursor. It keeps references to `rt` and `gc`,
/// which must outlive it.
struct ReadBytesOpLowering : public OpConversionPattern<bf::ReadBytesOp> {
    const BFRuntimeFuncs &rt;
    CursorGCSafety &gc;
    /// Creates the pattern over `rt`'s declarations and `gc`'s buffers.
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

        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{newBuffer});
        Value dstPtr = dataCall.getResult();

        Value len64 = rewriter.create<LLVM::ZExtOp>(
            loc, rewriter.getI64Type(), adaptor.getLen());
        rewriter.create<LLVM::MemcpyOp>(loc, dstPtr, srcPtr, len64, /*isVolatile=*/false);

        Value newCursor = advanceCursor(
            rewriter, loc, createCursor(rewriter, loc, srcPtr, end, cursorType),
            adaptor.getLen(), cursorType);

        // The allocation is assumed to succeed.
        Value ok = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI1Type(), 1);

        rewriter.replaceOp(op, {newBuffer, newCursor, ok});
        return success();
    }
};

/// Lowers bf.read.utf8 to a call of `elm_utf8_decode` on the next `len`
/// bytes, a cursor past them, and an `ok` that is true when the result is not
/// null.
///
/// `elm_utf8_decode` is given the buffer and an offset rather than a pointer,
/// because it allocates; its own comment says how it keeps the buffer safe.
/// The new cursor is rebuilt from the buffer after the call. The offset is
/// truncated to 32 bits. The pattern fails to match when `gc` knows no buffer
/// for the cursor. It keeps references to `rt` and `gc`, which must outlive it.
struct ReadUtf8OpLowering : public OpConversionPattern<bf::ReadUtf8Op> {
    const BFRuntimeFuncs &rt;
    CursorGCSafety &gc;
    /// Creates the pattern over `rt`'s declarations and `gc`'s buffers.
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

        // elm_utf8_decode returns null for invalid UTF-8.
        auto decodeCall = rewriter.create<LLVM::CallOp>(
            loc, rt.utf8Decode, ValueRange{source, pos32, adaptor.getLen()});
        Value stringVal = decodeCall.getResult();

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

/// Lowers bf.decoder.cursor.init the same way as bf.cursor.init.
struct DecoderCursorInitOpLowering : public OpConversionPattern<bf::DecoderCursorInitOp> {
    const BFRuntimeFuncs &rt;
    /// Creates the pattern over `rt`'s declarations, which must outlive it.
    DecoderCursorInitOpLowering(const TypeConverter &tc, MLIRContext *ctx, const BFRuntimeFuncs &rt)
        : OpConversionPattern(tc, ctx), rt(rt) {}

    LogicalResult
    matchAndRewrite(DecoderCursorInitOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

        auto dataCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferData, ValueRange{adaptor.getBytes()});
        Value ptr = dataCall.getResult();

        auto lenCall = rewriter.create<LLVM::CallOp>(
            loc, rt.bytebufferLen, ValueRange{adaptor.getBytes()});
        Value len = lenCall.getResult();

        Value end = rewriter.create<LLVM::GEPOp>(
            loc, ptr.getType(), rewriter.getI8Type(), ptr, len);

        Type cursorType = getTypeConverter()->convertType(op.getType());
        Value cursor = createCursor(rewriter, loc, ptr, end, cursorType);

        rewriter.replaceOp(op, cursor);
        return success();
    }
};

/// Lowers bf.cursor.ptr to the cursor's current pointer as an i64.
struct CursorPtrOpLowering : public OpConversionPattern<bf::CursorPtrOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(CursorPtrOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        Value ptr = extractPtr(rewriter, loc, adaptor.getCursor());
        Value ptrAsInt = rewriter.create<LLVM::PtrToIntOp>(
            loc, rewriter.getI64Type(), ptr);
        rewriter.replaceOp(op, ptrAsInt);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass Definition
//===----------------------------------------------------------------------===//

/// The module pass `createBFToLLVMPass` returns, registered as `bf-to-llvm`.
///
/// It converts only the top-level ops that contain a bf op, and converts no
/// non-bf op, though their operands may be bridged with
/// unrealized_conversion_cast. A module with no bf op is left unchanged.
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

        // Find the top-level ops that hold a bf op, scanning them in parallel
        // chunks; each index's flag is written only by the chunk that holds
        // it. Only those ops are analysed and converted, and a module with
        // none gets no symbol table and none of the 12 runtime declarations.
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

        // One symbol table, shared by the declarations and the GC analysis.
        OpBuilder builder(ctx);
        mlir::SymbolTable symTable(module);
        BFRuntimeFuncs rtFuncs = ensureRuntimeFunctions(module, builder, symTable);

        // Runs on the bf ops before any is converted. The read.bytes and
        // read.utf8 patterns keep a reference to it for its buffers.
        CursorGCSafety gcSafety(symTable);
        for (Operation *top : bfTops)
            if (failed(gcSafety.run(top))) {
                signalPassFailure();
                return;
            }

        BFTypeConverter typeConverter(ctx);

        ConversionTarget target(*ctx);
        target.addLegalDialect<LLVM::LLVMDialect>();
        target.addIllegalDialect<bf::BFDialect>();
        // No non-bf op is converted; later passes lower them.
        target.markUnknownOpDynamicallyLegal([](Operation *op) { return true; });

        RewritePatternSet patterns(ctx);

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
