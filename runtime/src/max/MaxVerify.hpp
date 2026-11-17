/// \file MaxVerify.hpp
/// Checks a module before eco hands it to MAX.
///
/// MAX's M_compileModelSync does not survive input it cannot read: when its parser rejects the
/// file it goes on with no module and crashes the process (a segfault, seen with MAX 26.7) rather
/// than returning an error. verifyModule catches what eco can check without MAX's dialects:
///
///   - the file is MLIR that eco's MLIR reads, as generic-form text or bytecode (MAX's dialects
///     are not registered in eco, so their ops must be in generic form; MAX's custom syntax, e.g.
///     `mo.graph @g(...)`, is refused), and MLIR's verifier accepts it;
///   - the module holds exactly one `mo.graph`, whose `argument_names` name its arguments and whose
///     `result_names` name its results (the names eco binds tensors by);
///   - in bytecode, no op of MAX's carries MLIR properties: eco's MLIR stores the properties of ops
///     it does not know as one dictionary, which MAX's bytecode reader rejects (and then crashes).
///     Write them as plain attributes, as MAX accepts and as the Elm bytecode writer does.
///
/// What it cannot catch is a module that is well formed but that MAX's own verifier rejects (a
/// wrongly typed attribute, an unknown op); producers must stay within what MAX accepts.
#pragma once

#include <filesystem>
#include <string>

namespace eco::max {

/// Returns "" when `file` passes every check above, else what is wrong with it.
std::string verifyModule(const std::filesystem::path &file);

} // namespace eco::max
