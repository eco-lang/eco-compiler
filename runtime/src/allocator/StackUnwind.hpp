// To find the heap pointers held in a thread's stack, the collector has to visit each frame on that
// stack and read the frame's return address and saved registers. This component is the frame walker that
// does it, behind one interface with two implementations.
//
// A walk starts from a snapshot of the calling thread's registers, a `Context`, and moves outwards one
// frame at a time with a `Cursor`. At each frame the cursor gives the instruction pointer and the value
// of a register named by its DWARF number, which is the numbering LLVM stack maps use for register
// locations. Each `step` moves to the caller of the current frame.
//
// On Windows the implementation uses `RtlCaptureContext`, `RtlLookupFunctionEntry` and
// `RtlVirtualUnwind`, with the AMD64 DWARF numbering 0..16 (`rax`, `rdx`, `rcx`, `rbx`, `rsi`, `rdi`,
// `rbp`, `rsp`, `r8`..`r15`, `rip`). Elsewhere it uses local-only libunwind, and passes the DWARF
// number to libunwind unchanged as its register number.
//
// A walk can only cover the calling thread's own stack, and only frames that are still live: the
// function that created the `Context` must not return before the walk is over.

#ifndef ECO_STACK_UNWIND_H
#define ECO_STACK_UNWIND_H

#include <cstdint>
#include <memory>

namespace Elm {
namespace StackUnwind {

/// A snapshot of the calling thread's registers, taken by the constructor, from which a stack walk
/// starts.
///
/// A `Context` cannot be copied or moved. The snapshot is only useful while the function that created
/// it is still running, because the frames it leads to are those on the stack at the time.
class Context {
public:
    /// Captures the calling thread's registers at this point.
    Context();
    ~Context();
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;
private:
    friend class Cursor;
    /// The platform's saved register state.
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/// A position in a walk of the calling thread's stack, one frame at a time, outwards from the frame in
/// which its `Context` was captured.
///
/// A `Cursor` cannot be copied or moved. The `Context` it was made from must outlive it: on POSIX the
/// libunwind cursor is initialised from that `Context`'s register state.
class Cursor {
public:
    /// Creates a cursor positioned at the frame in which `ctx` was captured.
    explicit Cursor(Context& ctx);
    ~Cursor();
    Cursor(const Cursor&) = delete;
    Cursor& operator=(const Cursor&) = delete;

    /// Moves the cursor to the caller of the current frame, and returns whether there is one to read.
    ///
    /// With libunwind, returns false at the outermost frame and when `unw_step` fails, and the two are not
    /// told apart. On Windows, returns false only when `RtlLookupFunctionEntry` finds no unwind information
    /// or the unwound return address is 0.
    bool step();

    /// Returns the instruction pointer of the current frame, or 0 if libunwind cannot read it.
    uintptr_t ip() const;

    /// Reads the register with DWARF number `dwarfRegNum` in the current frame into `outValue`, and
    /// returns whether it could. On failure `outValue` is left unchanged. On Windows only numbers 0..16
    /// are known.
    bool getRegister(uint16_t dwarfRegNum, uintptr_t& outValue) const;
private:
    /// The platform unwinder's cursor state.
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace StackUnwind
} // namespace Elm

#endif // ECO_STACK_UNWIND_H
