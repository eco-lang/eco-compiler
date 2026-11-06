module CompilerIssue2206RecordUpdateLetCrashTest exposing (main)

{-| A type error in a record update inside a let crashes the compiler, depending on a binding's name.

<https://github.com/elm/compiler/issues/2206>

`{ item | two = Second room }` gives `two` a `Custom a b` where `Item` needs `()`, which is a
TYPE MISMATCH. Elm 0.19.1 reports it only if the second let binding's name starts with a letter
from t to z. With the name used here it crashes instead, with "index out of bounds" and "thread
blocked indefinitely in an MVar operation". The test expects the TYPE MISMATCH report and no
crash.

Fixed in Elm 0.19.3.

-}

-- COMPILE-ERROR: TYPE MISMATCH, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


main =
    text "done"


type alias Item =
    { one : ()
    , two : ()
    }


type Custom a b
    = First a
    | Second b


expectItem : Item -> ()
expectItem =
    always ()


problem item room =
    let
        showItemHasDotOne =
            item.one

        crashIfFunctionNameStartsWithAtoS =
            expectItem
                { item | two = Second room }
    in
    ()
