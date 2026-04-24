module PolyStepLoopMultiSpecTest exposing (main)

{-| Reproduces the stage-6 MLIR verify failure when MULTIPLE `Step`
    specializations coexist with different `a` types. The existing
    `PolyStepLoopIntResultTest` only has one `Step` specialization, so
    `findConcreteCtorField` finds trivial agreement. This test forces
    three specializations (a = Int, String, Bool) so the cross-specialization
    agreement scan fails and the scrutinee path's annotated `resultType` stays
    `MVar`. Without the fallback in `generateDestruct` / `compileDestructStep`
    that consults the destructor's own `monoType` (pinned via the outer
    subst's return-type unification), the Int-returning loop's
    `eco.project.custom` emits `!eco.value` but the enclosing
    `eco.construct.tuple2` (building the `(State, Int)` return tuple) expects
    `i64` at the unboxed slot.

    The E2E JIT runner tolerates the type mismatch; `eco-boot-native` does not.
    This test's main value is as a regression check for the native path:
    compile the produced MLIR with `eco-boot-native` and it must parse.

-}

-- CHECK: intResult: 6
-- CHECK: strResult: "abc"
-- CHECK: boolResult: True
-- CHECK: finalState: 12

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


foldInt : Int -> List Int -> IO Int
foldInt seed xs =
    loop foldIntHelp ( xs, seed )


foldIntHelp : ( List Int, Int ) -> IO (Step ( List Int, Int ) Int)
foldIntHelp ( list, acc ) s =
    case list of
        [] ->
            ( s + 1, Done acc )

        x :: rest ->
            ( s + 1, Loop ( rest, acc + x ) )


foldStr : String -> List String -> IO String
foldStr seed xs =
    loop foldStrHelp ( xs, seed )


foldStrHelp : ( List String, String ) -> IO (Step ( List String, String ) String)
foldStrHelp ( list, acc ) s =
    case list of
        [] ->
            ( s + 1, Done acc )

        x :: rest ->
            ( s + 1, Loop ( rest, acc ++ x ) )


foldBool : Bool -> List Bool -> IO Bool
foldBool seed xs =
    loop foldBoolHelp ( xs, seed )


foldBoolHelp : ( List Bool, Bool ) -> IO (Step ( List Bool, Bool ) Bool)
foldBoolHelp ( list, acc ) s =
    case list of
        [] ->
            ( s + 1, Done acc )

        x :: rest ->
            ( s + 1, Loop ( rest, acc && x ) )


main =
    let
        ( s1, intResult ) =
            foldInt 0 [ 1, 2, 3 ] 0

        ( s2, strResult ) =
            foldStr "" [ "a", "b", "c" ] s1

        ( s3, boolResult ) =
            foldBool True [ True, True, True ] s2

        _ =
            Debug.log "intResult" intResult

        _ =
            Debug.log "strResult" strResult

        _ =
            Debug.log "boolResult" boolResult

        _ =
            Debug.log "finalState" s3
    in
    text "done"
