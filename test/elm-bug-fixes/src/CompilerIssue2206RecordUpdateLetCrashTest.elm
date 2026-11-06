module CompilerIssue2206RecordUpdateLetCrashTest exposing (main)

{-| A type error in a record update inside a let crashes the compiler, depending on a binding's name.

<https://github.com/elm/compiler/issues/2206>

`{ item | two = Second room }` gives `two` a `Custom a b` where `Item` needs `()`: a TYPE MISMATCH, which Elm 0.19.1 reports only if the second let binding's name starts with t-z. With this name it crashes with "Data/Vector/Generic/Mutable.hs:709 (modify): index out of bounds (3,3)" and "thread blocked indefinitely in an MVar operation".

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
