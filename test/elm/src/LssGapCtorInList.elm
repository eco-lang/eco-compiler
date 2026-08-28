module LssGapCtorInList exposing (main)
{-| The one scenario that could still need declaration-site injection: a
constructor held in a CONTAINER, where the use-site `standaloneArgMember` path
does not fire. If the list-element position carries the ctor's member, the
existing machinery already covers it. -}
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
