module PolyStepLoopMinimalDisagreeTest exposing (main)

{-| One polymorphic `Step`-driven state loop is used at two result types, `Int`
and `String`, in the same program, and both uses give the right result.

`IO a` is a function from an `Int` state to a pair of the new state and a
result, and `loop` calls its callback until it returns `Done`. `sumInts` sums
`[ 1, 2, 3 ]` to 6 and `concatStrs` concatenates `[ "a", "b", "c" ]` to
`"abc"`. `PolyStepLoopMultiSpecTest` covers three result types.

## eco

Minimal two-loop reproduction of the stage-6 bug in
test/eco-elm/src/PolyStepLoopMultiSpecTest.elm. Two specializations of `loop`
(Int and String) register two concrete `Step` shapes plus a partly polymorphic
one from `loop`'s body whose `Done` field is still a type variable. Without the
fallback in `generateDestruct` (compiler/src/Compiler/GenerateMlir/Expr.elm)
and compiler/src/Compiler/GenerateMlir/TailRec.elm that uses the destructor's
own type, the Int loop's `eco.project.custom` emits `!eco.value` where the
enclosing `eco.construct.tuple2` expects an unboxed `i64`. The native backend
rejects the mismatch and the JIT runner tolerates it, so this mainly guards
the native path.

-}

-- CHECK: total: 6
-- CHECK: concat: "abc"

import Html exposing (text)


type Step state a
    = Loop state
    | Done a


type alias IO a =
    Int -> ( Int, a )


loop : (state -> IO (Step state a)) -> state -> IO a
loop callback loopState ioState =
    case callback loopState ioState of
        ( newIOState, Loop newLoopState ) ->
            loop callback newLoopState newIOState

        ( newIOState, Done a ) ->
            ( newIOState, a )


sumInts : List Int -> Int -> IO Int
sumInts xs seed =
    loop sumStep ( xs, seed )


sumStep : ( List Int, Int ) -> IO (Step ( List Int, Int ) Int)
sumStep ( list, acc ) s =
    case list of
        [] ->
            ( s, Done acc )

        x :: rest ->
            ( s + 1, Loop ( rest, acc + x ) )


concatStrs : List String -> String -> IO String
concatStrs xs seed =
    loop concatStep ( xs, seed )


concatStep : ( List String, String ) -> IO (Step ( List String, String ) String)
concatStep ( list, acc ) s =
    case list of
        [] ->
            ( s, Done acc )

        x :: rest ->
            ( s + 1, Loop ( rest, acc ++ x ) )


main =
    let
        ( _, total ) =
            sumInts [ 1, 2, 3 ] 0 0

        ( _, concat ) =
            concatStrs [ "a", "b", "c" ] "" 0

        _ =
            Debug.log "total" total

        _ =
            Debug.log "concat" concat
    in
    text "done"
