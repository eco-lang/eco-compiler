#ifndef ECO_STACK_UNWIND_H
#define ECO_STACK_UNWIND_H

#include <cstdint>
#include <memory>

namespace Elm {
namespace StackUnwind {

// TEMP(diag) (plans/ci-all-platforms-green.md issue 8): the last unw_step result (POSIX).
extern int g_diagLastStepRc;

class Context {
public:
    Context();
    ~Context();
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;
private:
    friend class Cursor;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class Cursor {
public:
    explicit Cursor(Context& ctx);
    ~Cursor();
    Cursor(const Cursor&) = delete;
    Cursor& operator=(const Cursor&) = delete;

    bool step();
    uintptr_t ip() const;
    bool getRegister(uint16_t dwarfRegNum, uintptr_t& outValue) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace StackUnwind
} // namespace Elm

#endif // ECO_STACK_UNWIND_H
