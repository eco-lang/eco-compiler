module PolyStepLoopMinimalDisagreeTest exposing (main)

{-| Minimal two-loop reproduction of the same stage-6 bug as
    `PolyStepLoopMultiSpecTest`: two specializations of `loop` where `a`
    differs (Int vs String). The compiler registers two concrete `Step`
    shapes plus a partially-polymorphic one from loop's body.
    `findConcreteCtorField` sees `Int` and `String` candidates for
    `Done.field0`, finds disagreement, returns `Nothing`, and downstream
    code falls back to `MVar`. Without the `generateDestruct` / TailRec
    fallback that reaches for the destructor's own `monoType`, the
    Int-returning loop's `eco.project.custom` would emit `!eco.value`
    even though the enclosing `eco.construct.tuple2` expects an unboxed
    `i64`. Native (`eco-boot-native`) rejects the mismatch; the JIT
    runner tolerates it, so this test mainly guards the native path.

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
