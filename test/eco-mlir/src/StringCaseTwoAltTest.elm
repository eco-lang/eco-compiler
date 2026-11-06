module StringCaseTwoAltTest exposing (main)

{-| `case` expressions on Strings with a single string pattern and a wildcard pick the right branch, in several pattern positions.

The test logs one list holding the results of:

  - `one`, a plain match on `"hello"` with a wildcard, for a matching and a
    non-matching string.
  - `oneTail`, the same match inside a tail-recursive function. `"hello"` recurses
    down to `n = 0` and returns 0; `"x"` returns `n + 100 = 102`.
  - `inTuple`, a string inside a tuple pattern `( "hello", 1 )`.
  - `inMaybe`, a string inside a constructor pattern `Just "hello"`.
  - `three`, a match with two string patterns and a wildcard, called with `"b"`.

## eco

Asserts the front end never emits a two-alternative string `eco.case`. A
single-pattern string match becomes a decision-tree chain: an `eco.value.eq`
test feeding a Bool case, so every `case_kind = "str"` case has at least two
patterns. runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp relies on this:
its generic two-alternative lowering (`CaseToScfIfPattern`) would dispatch a
two-alternative string case by constructor tag and send every string down the
same branch (see test/codegen/case_string_two_alt_jit.mlir). The
CHECK-MLIR-NOT line fails if a single-pattern string case appears; `three` is
the control that must stay a string case with two patterns.

-}

-- CHECK: r: [10,20,0,102,1,2,1,2,2]
-- CHECK-MLIR-NOT: case_kind = "str", string_patterns = [{{"[^"]*"}}]
-- CHECK-MLIR: case_kind = "str", string_patterns = ["a", "b"]


one : String -> Int
one s =
    case s of
        "hello" ->
            10

        _ ->
            20


oneTail : String -> Int -> Int
oneTail s n =
    if n <= 0 then
        n

    else
        case s of
            "hello" ->
                oneTail s (n - 1)

            _ ->
                n + 100


inTuple : ( String, Int ) -> Int
inTuple p =
    case p of
        ( "hello", 1 ) ->
            1

        ( _, _ ) ->
            2


inMaybe : Maybe String -> Int
inMaybe m =
    case m of
        Just "hello" ->
            1

        _ ->
            2


three : String -> Int
three s =
    case s of
        "a" ->
            1

        "b" ->
            2

        _ ->
            3


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r"
                            [ one "hello"
                            , one "world"
                            , oneTail "hello" 2
                            , oneTail "x" 2
                            , inTuple ( "hello", 1 )
                            , inTuple ( "x", 1 )
                            , inMaybe (Just "hello")
                            , inMaybe (Just "x")
                            , three "b"
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
