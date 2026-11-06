module LssGapCtorInList exposing (main)
{-| A custom type constructor stored in a list can be taken out and applied.

`makers` is `[ Wrap ]`; `runFirst` applies the first function in the list
and unwraps the result, printing 7.
-}
-- CHECK: ctorInList: 7
import Html exposing (text)
type Wrap = Wrap Int
makers : List (Int -> Wrap)
makers = [ Wrap ]
runFirst : List (Int -> Wrap) -> Int -> Int
runFirst fs x =
    case fs of
        f :: _ -> case f x of
                    Wrap n -> n
        [] -> 0
main =
    let _ = Debug.log "ctorInList" (runFirst makers 7) in text "hello"
