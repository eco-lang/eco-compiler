// threaded-gc-05c D9: a no-frames StackUnwind for the heap TSan driver (the
// driver keeps every live value in RootSet roots, never in stack-map slots).
#include "StackUnwind.hpp"

namespace Elm::StackUnwind {
struct Context::Impl {};
struct Cursor::Impl {};
Context::Context() : impl_(new Impl) {}
Context::~Context() = default;
Cursor::Cursor(Context&) : impl_(new Impl) {}
Cursor::~Cursor() = default;
bool Cursor::step() { return false; }
uintptr_t Cursor::ip() const { return 0; }
bool Cursor::getRegister(uint16_t, uintptr_t& out) const { out = 0; return false; }
}  // namespace Elm::StackUnwind
