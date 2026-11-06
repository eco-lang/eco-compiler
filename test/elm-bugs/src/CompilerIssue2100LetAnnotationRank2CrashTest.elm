module CompilerIssue2100LetAnnotationRank2CrashTest exposing (main)

{-| A wrong annotation on a let-bound function that uses an outer argument crashes the compiler.

<https://github.com/elm/compiler/issues/2100>

Elm 0.19.1 crashes ("attributes [rank = 2]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation"). The body of `b` returns `()` but its annotation says `{ value : String }`, so this is a TYPE MISMATCH.

-}

-- COMPILE-ERROR: TYPE MISMATCH, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


main =
    text "done"


type A attributes
    = A { b : attributes -> () }


a getAttribute =
    let
        b : attributes -> { value : String }
        b attributes =
            let
                _ =
                    getAttribute attributes
            in
            ()
    in
    A { b = b }
