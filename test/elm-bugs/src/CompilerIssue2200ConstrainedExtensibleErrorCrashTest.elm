module CompilerIssue2200ConstrainedExtensibleErrorCrashTest exposing (main)

{-| A type error for an extensible record whose row variable is the constrained `number` must be
reported completely, not crash the compiler.

<https://github.com/elm/compiler/issues/2200>

`{ number | field : () }` with the body `()` is a type error. Elm 0.19.1 starts printing the TYPE
MISMATCH report and then crashes with "Used toErrorType on a type that is not well-formed"
(Type/Type.hs:541). The report must be complete.

-}

-- COMPILE-ERROR: TYPE MISMATCH, printed completely
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -
-- CHECK-NOT: not well-formed

import Html exposing (text)


main =
    text "done"


number : { number | field : () }
number =
    ()
