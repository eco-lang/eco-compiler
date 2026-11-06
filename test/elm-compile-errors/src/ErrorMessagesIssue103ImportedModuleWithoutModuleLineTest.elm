module ErrorMessagesIssue103ImportedModuleWithoutModuleLineTest exposing (..)

{-| Importing a module whose file has no `module` line is reported as MODULE NAME MISSING.

<https://github.com/elm/error-message-catalog/issues/103>

The imported file `ErrorMessagesIssue103NoModuleLineHelper.elm` has no `module` line. The
report must say the line is missing and suggest `module ErrorMessagesIssue103NoModuleLineHelper exposing (..)`.
It must not assume the module is called `Main` and report a name mismatch ("should be Main").

-}

-- COMPILE-ERROR: MODULE NAME MISSING, an imported module has no module line
-- CHECK: -- MODULE NAME MISSING -
-- CHECK: module ErrorMessagesIssue103NoModuleLineHelper exposing (..)
-- CHECK-NOT: should be Main

import ErrorMessagesIssue103NoModuleLineHelper


answer =
    42
