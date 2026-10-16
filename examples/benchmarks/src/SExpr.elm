module SExpr exposing (bench)

{-| A Lisp reader written with `elm/parser` and a small evaluator: numbers, `+`, `-`, `*`, `<`,
`if`, `let` (with shadowing) and `lambda` with any number of parameters, closures captured in a
`Dict String Value`. Each of the `n` programs is a generated expression of 300 numbers and
variables, under a recursive Fibonacci written as self-application:

    (let ((fib (lambda (self k) (if (< k 2) k (+ (self self (- k 1)) (self self (- k 2)))))))
      (+ (fib fib 10) EXPR))

Arithmetic is modulo 1000003 (every value stays below 2^53), and the generator computes each
program's value from its own tree; the reader and evaluator must give exactly that, at every
size (fib 10 is 55). Each program is about 4,000 characters, well under the size at which eco
native's parser kernel fails on appended strings (see `ExprParser`).

-}

import Dict exposing (Dict)
import Parser exposing ((|.), (|=), Parser, Step(..))


modulus : Int
modulus =
    1000003



-- READER


type SExpr
    = Num Int
    | Atom String
    | Items (List SExpr)


isSymbolChar : Char -> Bool
isSymbolChar c =
    c /= ' ' && c /= '(' && c /= ')' && c /= '\n'


sexpr : Parser SExpr
sexpr =
    Parser.oneOf
        [ Parser.map Num Parser.int
        , Parser.map Atom (Parser.getChompedString (Parser.chompIf isSymbolChar |. Parser.chompWhile isSymbolChar))
        , Parser.succeed Items
            |. Parser.symbol "("
            |. Parser.spaces
            |= Parser.loop [] items
        ]
        |. Parser.spaces


items : List SExpr -> Parser (Step (List SExpr) (List SExpr))
items acc =
    Parser.oneOf
        [ Parser.succeed (Done (List.reverse acc)) |. Parser.symbol ")"
        , Parser.map (\e -> Loop (e :: acc)) (Parser.lazy (\_ -> sexpr))
        ]


program : Parser SExpr
program =
    Parser.succeed identity
        |. Parser.spaces
        |= sexpr
        |. Parser.end



-- EVALUATOR


type Value
    = VNum Int
    | VBool Bool
    | VFn (List String) SExpr (Dict String Value)


eval : Dict String Value -> SExpr -> Maybe Value
eval env expr =
    case expr of
        Num k ->
            Just (VNum k)

        Atom name ->
            Dict.get name env

        Items [ Atom "+", a, b ] ->
            arithmetic env (+) a b

        Items [ Atom "-", a, b ] ->
            arithmetic env (-) a b

        Items [ Atom "*", a, b ] ->
            arithmetic env (*) a b

        Items [ Atom "<", a, b ] ->
            Maybe.map2 (\x y -> VBool (x < y)) (number env a) (number env b)

        Items [ Atom "if", c, t, f ] ->
            case eval env c of
                Just (VBool True) ->
                    eval env t

                Just (VBool False) ->
                    eval env f

                _ ->
                    Nothing

        Items [ Atom "let", Items [ Items [ Atom name, bound ] ], body ] ->
            eval env bound |> Maybe.andThen (\v -> eval (Dict.insert name v env) body)

        Items [ Atom "lambda", Items params, body ] ->
            List.foldr (\p acc -> Maybe.map2 (::) (atomName p) acc) (Just []) params
                |> Maybe.map (\names -> VFn names body env)

        Items (f :: args) ->
            case eval env f of
                Just (VFn names body closure) ->
                    if List.length names == List.length args then
                        List.foldr (\a acc -> Maybe.map2 (::) (eval env a) acc) (Just []) args
                            |> Maybe.andThen (\values -> eval (List.foldl (\( k, v ) d -> Dict.insert k v d) closure (List.map2 Tuple.pair names values)) body)

                    else
                        Nothing

                _ ->
                    Nothing

        Items [] ->
            Nothing


atomName : SExpr -> Maybe String
atomName e =
    case e of
        Atom name ->
            Just name

        _ ->
            Nothing


number : Dict String Value -> SExpr -> Maybe Int
number env e =
    case eval env e of
        Just (VNum k) ->
            Just k

        _ ->
            Nothing


arithmetic : Dict String Value -> (Int -> Int -> Int) -> SExpr -> SExpr -> Maybe Value
arithmetic env op a b =
    Maybe.map2 (\x y -> VNum (modBy modulus (op x y))) (number env a) (number env b)



-- GENERATOR


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


type alias Generated =
    { text : List String
    , value : Int
    , seed : Int
    }


{-| An expression of `leaves` numbers and variables, as text pieces, with its value. `vars` are
the variables in scope, innermost first.
-}
generate : Int -> List ( String, Int ) -> Int -> Generated
generate leaves vars seed =
    let
        s1 =
            next seed

        s2 =
            next s1

        split total =
            1 + modBy (total - 1) s2

        binary symbol op =
            let
                left =
                    generate (split leaves) vars s2

                right =
                    generate (leaves - split leaves) vars left.seed
            in
            Generated ([ "(", symbol, " " ] ++ left.text ++ (" " :: right.text) ++ [ ")" ]) (modBy modulus (op left.value right.value)) right.seed
    in
    if leaves <= 1 then
        case ( vars, modBy 3 s1 ) of
            ( ( name, v ) :: _, 0 ) ->
                Generated [ name ] v s1

            _ ->
                let
                    k =
                        modBy 1000 s1
                in
                Generated [ String.fromInt k ] k s1

    else
        case modBy 6 s1 of
            0 ->
                binary "+" (+)

            1 ->
                binary "-" (-)

            2 ->
                binary "*" (*)

            3 ->
                if leaves < 4 then
                    binary "+" (+)

                else
                    let
                        quarter =
                            leaves // 4

                        a =
                            generate quarter vars s2

                        b =
                            generate quarter vars a.seed

                        t =
                            generate quarter vars b.seed

                        f =
                            generate (leaves - 3 * quarter) vars t.seed

                        chosen =
                            if a.value < b.value then
                                t.value

                            else
                                f.value
                    in
                    Generated ([ "(if (< " ] ++ a.text ++ (" " :: b.text) ++ (") " :: t.text) ++ (" " :: f.text) ++ [ ")" ]) chosen f.seed

            4 ->
                let
                    name =
                        "v" ++ String.fromInt (modBy 6 s2)

                    bound =
                        generate (split leaves) vars s2

                    body =
                        generate (leaves - split leaves) (( name, bound.value ) :: vars) bound.seed
                in
                Generated ([ "(let ((", name, " " ] ++ bound.text ++ ("))" :: " " :: body.text) ++ [ ")" ]) body.value body.seed

            _ ->
                let
                    name =
                        "v" ++ String.fromInt (modBy 6 s2)

                    argument =
                        generate (split leaves) vars s2

                    body =
                        generate (leaves - split leaves) (( name, argument.value ) :: vars) argument.seed
                in
                Generated ([ "((lambda (", name, ") " ] ++ body.text ++ (") " :: argument.text) ++ [ ")" ]) body.value body.seed


fibonacci : String
fibonacci =
    "(let ((fib (lambda (self k) (if (< k 2) k (+ (self self (- k 1)) (self self (- k 2))))))) (+ (fib fib 10) "


{-| Generate, read and run program `k`.
-}
runs : Int -> Bool
runs k =
    let
        g =
            generate 300 [] (k * 7919 + 1)

        text =
            String.concat (fibonacci :: g.text) ++ "))"
    in
    case Parser.run program text of
        Ok tree ->
            eval Dict.empty tree == Just (VNum (modBy modulus (55 + g.value)))

        Err _ ->
            False


bench : Int -> Bool
bench n =
    List.all runs (List.range 1 n)
