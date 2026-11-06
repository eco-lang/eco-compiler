module ErrorMessagesIssue103ImportedModuleWithoutModuleLineTest exposing (..)

{-| MODULE NAME MISSING: an imported module has no `module` line.

<https://github.com/elm/error-message-catalog/issues/103>

The imported file `ErrorMessagesIssue103NoModuleLineHelper.elm` has no `module` line. Elm 0.17
assumed it was called `Main` and reported a name mismatch ("According to the source code it
should be Main"). The report must say the module line is missing.

-}

-- COMPILE-ERROR: MODULE NAME MISSING, an imported module has no module line
-- CHECK: -- MODULE NAME MISSING -
-- CHECK: module ErrorMessagesIssue103NoModuleLineHelper exposing (..)
-- CHECK-NOT: should be Main

import ErrorMessagesIssue103NoModuleLineHelper


answer =
    42
