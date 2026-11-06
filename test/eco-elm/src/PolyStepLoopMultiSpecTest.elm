module PolyStepLoopMultiSpecTest exposing (main)

{-| One polymorphic `Step`-driven state loop is used at three result types, `Int`,
`String` and `Bool`, with the state threaded through all three runs, and each
gives the right result.

`IO a` is a function from an `Int` state to a pair of the new state and a
result, and `loop` calls its callback until it returns `Done`. Each helper
increments the state on every call, including the final one that returns
`Done`, so each three-element list adds 4 and the final state is 12. The
results are the sum 6, the concatenation `"abc"`, and the `&&` of three `True`s.

## eco

Reproduces a stage-6 MLIR verify failure when several `Step` specializations
coexist with different `a` types (test/eco-elm/src/PolyStepLoopIntResultTest.elm
has only one). The scrutinee path's annotated result type stays a type
variable, and without the fallback in `generateDestruct`
(compiler/src/Compiler/GenerateMlir/Expr.elm) and
compiler/src/Compiler/GenerateMlir/TailRec.elm that consults the destructor's
own type, the Int loop's `eco.project.custom` emits `!eco.value` where the
`eco.construct.tuple2` building the `( State, Int )` return expects `i64`.
The JIT runner tolerates the mismatch and the native backend does not, so the
test mainly guards the native path.

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
