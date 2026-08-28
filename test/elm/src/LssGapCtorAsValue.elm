module LssGapCtorAsValue exposing (main)
{-| Does a constructor's `c|` member reach a REGISTRY POSITION at all?

`standaloneArgMember` already injects `c|` when a ctor is passed as an
argument, so this probe asks the question P2's viability turns on: if the
answer is a named set at `useCtor`'s parameter, members at ctor arrows DO
survive to positions and declaration-site injection can work. If it is ⊤, some
widening absorbs them and P2 would be inert.
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
