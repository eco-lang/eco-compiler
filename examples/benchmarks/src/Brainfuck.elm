module Brainfuck exposing (bench, output)

{-| A brainf*ck interpreter (kostya/benchmarks): the program is parsed once into an `Array` of
operations with matched jumps, and runs on a tape that is an `Array Int`, so this measures
`Array.get` and `Array.set` and an interpreter's dispatch loop. Each run executes 964,872
operations; `n` is the number of runs.

The program is kostya/benchmarks' `brainfuck/bench.b` with its loop nest cut from seven levels of
ten to four (the full program executes 953 million operations, about a minute a run on this
interpreter). It prints the same text, the alphabet backwards and a newline, which every run's
output must match exactly.

kostya/benchmarks, Copyright (c) 2014 'Konstantin Makarchev', MIT License.

-}

import Array exposing (Array)


program : String
program =
    ">++[<+++++++++++++>-]<[[>+>+<<-]>[<+>-]++++++++[>++++++++<-]>.[-]<<>++++++++++[>++++++++++["
        ++ ">++++++++++[>++++++++++[-]<-]<-]<-]<-]++++++++++."


expected : String
expected =
    "ZYXWVUTSRQPONMLKJIHGFEDCBA\n"


type Op
    = Add Int
    | Move Int
    | Open Int
    | Close Int
    | Print


{-| The operations of `source` (non-command characters skipped), each `Open` and `Close` holding
the index of its partner.
-}
parse : String -> Array Op
parse source =
    let
        ops =
            String.toList source
                |> List.filterMap
                    (\c ->
                        case c of
                            '+' ->
                                Just (Add 1)

                            '-' ->
                                Just (Add -1)

                            '>' ->
                                Just (Move 1)

                            '<' ->
                                Just (Move -1)

                            '[' ->
                                Just (Open 0)

                            ']' ->
                                Just (Close 0)

                            '.' ->
                                Just Print

                            _ ->
                                Nothing
                    )
                |> Array.fromList

        link i stack linked =
            case Array.get i linked of
                Nothing ->
                    linked

                Just (Open _) ->
                    link (i + 1) (i :: stack) linked

                Just (Close _) ->
                    case stack of
                        open :: rest ->
                            link (i + 1) rest (linked |> Array.set open (Open i) |> Array.set i (Close open))

                        [] ->
                            linked

                Just _ ->
                    link (i + 1) stack linked
    in
    link 0 [] ops


{-| Run from `pc` with the tape and pointer given; the output's character codes come back in
reverse order.
-}
execute : Array Op -> Int -> Array Int -> Int -> List Int -> List Int
execute ops pc tape ptr out =
    case Array.get pc ops of
        Nothing ->
            out

        Just op ->
            let
                cell =
                    Maybe.withDefault 0 (Array.get ptr tape)
            in
            case op of
                Add d ->
                    execute ops (pc + 1) (Array.set ptr (modBy 256 (cell + d)) tape) ptr out

                Move d ->
                    execute ops (pc + 1) tape (ptr + d) out

                Open close ->
                    if cell == 0 then
                        execute ops (close + 1) tape ptr out

                    else
                        execute ops (pc + 1) tape ptr out

                Close open ->
                    if cell /= 0 then
                        execute ops (open + 1) tape ptr out

                    else
                        execute ops (pc + 1) tape ptr out

                Print ->
                    execute ops (pc + 1) tape ptr (cell :: out)


runOnce : Array Op -> String
runOnce ops =
    execute ops 0 (Array.repeat 64 0) 0 []
        |> List.reverse
        |> List.map Char.fromCode
        |> String.fromList


{-| The program's output, once.
-}
output : Int -> String
output _ =
    runOnce (parse program)


bench : Int -> Bool
bench n =
    let
        ops =
            parse program

        runs i ok =
            if i <= 0 then
                ok

            else
                runs (i - 1) (ok && runOnce ops == expected)
    in
    runs n True
