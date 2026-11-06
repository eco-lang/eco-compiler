module LssGapCtorAsValue exposing (main)
{-| A custom type constructor passed as a function argument builds the value it
is applied to.

`useCtor` takes an `Int -> Wrap` and pattern matches on its result;
`useCtor Wrap 7` prints 7.
-}
-- CHECK: ctorAsValue: 7
import Html exposing (text)
type Wrap = Wrap Int
useCtor : (Int -> Wrap) -> Int -> Int
useCtor f x =
    case f x of
        Wrap n -> n
main =
    let _ = Debug.log "ctorAsValue" (useCtor Wrap 7) in text "hello"
