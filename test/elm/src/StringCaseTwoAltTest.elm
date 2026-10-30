module StringCaseTwoAltTest exposing (main)

{-| Regression pin: the front end never emits a two-alternative string `eco.case`.

A match on one string pattern (`case s of "hello" -> a; _ -> b`) becomes a decision-tree Chain, an
`eco.value.eq` test feeding a Bool case, not a string fan-out, so every `case_kind = "str"` case
has at least two patterns (three alternatives). EcoControlFlowToSCF depends on that today: its
generic two-alternative pattern (`CaseToScfIfPattern`) would lower a top-level two-alternative
string case by constructor tag, sending every string down the same branch (cpp-review-bugs.md,
"Two-alternative `str` case lowered by constructor tag"; test/codegen/case\_string\_two\_alt\_jit.mlir).
If a front-end change ever emits a single-pattern string case, the CHECK-MLIR-NOT below fails, so
the backend fix must land first.

The shapes: a plain single-pattern match, the same inside a tail-recursive function, a string inside
a tuple pattern and inside a constructor pattern, and a three-way match (the control: it must stay a
string case with two patterns).

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
