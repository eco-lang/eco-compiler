//===- Terminal.hpp - eco/system kernel module Terminal (internal) --------===//
//
// plans/eco-system-library.md Appendix B.5, C.4, §3.8 and Phase 5 step 5.3:
// the binding bodies of Eco.Kernel.Terminal (Terminal.cpp), bound by
// TerminalExports.cpp. The `System.Terminal` effect manager (onResize) is in
// TerminalManager.{hpp,cpp}.
//
// Templates used: T1.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TERMINAL_TERMINAL_HPP
#define ECO_SYSTEM_TERMINAL_TERMINAL_HPP

#include "eco-system/Core/Core.hpp"

#include <string>

namespace Eco::System {

HPointer terminalGetConfigurationBody(HPointer captured);
HPointer terminalSetStdInRawModeBody(HPointer captured);
HPointer terminalSetProcessTitleBody(HPointer captured);

// The terminal size in character cells, from TIOCGWINSZ on fd 1, then 0, 2.
// False when none of them is a terminal (or the size is unknown). POD.
bool terminalSize(int& columns, int& rows);

// The colour depth heuristic of B.5 (1, 4, 8 or 24). POD.
int terminalColorDepth();

// The first at most 15 bytes of `title`, cut back to a UTF-8 boundary (the
// Linux thread-name limit, §3.8). POD.
std::string truncatedThreadName(const std::string& title);

} // namespace Eco::System

#endif // ECO_SYSTEM_TERMINAL_TERMINAL_HPP
