module ExprParser exposing (bench)

{-| Parse and evaluate arithmetic expressions with `elm/parser`: integers, `+`, `-`, `*`,
parentheses and spaces, with the usual precedence (`*` over `+` and `-`, all left-associative).
Each expression has 1,000 integers (about 7,000 characters), its tree shaped at random by a
linear congruential generator, so the parser's `loop`, `oneOf`, `symbol`, `int` and `lazy` all
get exercised; `n` is the number of expressions, each from its own seed.

Arithmetic is modulo 1000003, so every value stays below 2^53. The generator computes each
value from its own tree, and the parser's must equal it exactly, at every size; a parser that
gets precedence or associativity wrong gets a different value.

The expressions are kept short on purpose: on eco's native backend, a parser source of more
than 128 Ki characters built by appending crashes (`StringOps::ensureFlat` leaves a rope that
long unflattened, and the parser kernel reads it as a flat string;
`plans/benchmark-suite-expansion.md`, Status).

-}

import Parser exposing ((|.), (|=), Parser, Step(..))


modulus : Int
modulus =
    1000003


type Expr
    = Number Int
    | Plus Expr Expr
    | Minus Expr Expr
    | Times Expr Expr


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| A random tree with `leaves` integers; gives the seed it ends with.
-}
generate : Int -> Int -> ( Expr, Int )
generate leaves seed =
    let
        s1 =
            next seed
    in
    if leaves <= 1 then
        ( Number (modBy 1000 s1), s1 )

    else
        let
            s2 =
                next s1

            leftLeaves =
                1 + modBy (leaves - 1) s1

            ( left, s3 ) =
                generate leftLeaves s2

            ( right, s4 ) =
                generate (leaves - leftLeaves) s3
        in
        case modBy 3 s2 of
            0 ->
                ( Plus left right, s4 )

            1 ->
                ( Minus left right, s4 )

            _ ->
                ( Times left right, s4 )


evaluate : Expr -> Int
evaluate expr =
    case expr of
        Number k ->
            k

        Plus a b ->
            modBy modulus (evaluate a + evaluate b)

        Minus a b ->
            modBy modulus (evaluate a - evaluate b)

        Times a b ->
            modBy modulus (evaluate a * evaluate b)


isSum : Expr -> Bool
isSum expr =
    case expr of
        Plus _ _ ->
            True

        Minus _ _ ->
            True

        _ ->
            False


{-| The expression as text, as pieces (joined once at the end): parenthesised where the tree
needs it, so that parsing gives back the same tree.
-}
print : Expr -> List String -> List String
print expr rest =
    let
        parens e r =
            "(" :: print e (")" :: r)
    in
    case expr of
        Number k ->
            String.fromInt k :: rest

        Plus a b ->
            print a (" + " :: (if isSum b then parens b rest else print b rest))

        Minus a b ->
            print a (" - " :: (if isSum b then parens b rest else print b rest))

        Times a b ->
            (if isSum a then parens a else print a)
                (" * "
                    :: (case b of
                            Number _ ->
                                print b rest

                            _ ->
                                parens b rest
                       )
                )


expression : Parser Int
expression =
    term |> Parser.andThen (\first -> Parser.loop first sumStep)


sumStep : Int -> Parser (Step Int Int)
sumStep total =
    Parser.oneOf
        [ Parser.succeed (\t -> Loop (modBy modulus (total + t)))
            |. Parser.symbol "+"
            |. Parser.spaces
            |= term
        , Parser.succeed (\t -> Loop (modBy modulus (total - t)))
            |. Parser.symbol "-"
            |. Parser.spaces
            |= term
        , Parser.succeed (Done total)
        ]


term : Parser Int
term =
    factor |> Parser.andThen (\first -> Parser.loop first productStep)


productStep : Int -> Parser (Step Int Int)
productStep total =
    Parser.oneOf
        [ Parser.succeed (\f -> Loop (modBy modulus (total * f)))
            |. Parser.symbol "*"
            |. Parser.spaces
            |= factor
        , Parser.succeed (Done total)
        ]


factor : Parser Int
factor =
    Parser.oneOf
        [ Parser.succeed identity
            |. Parser.symbol "("
            |. Parser.spaces
            |= Parser.lazy (\_ -> expression)
            |. Parser.symbol ")"
            |. Parser.spaces
        , Parser.int |. Parser.spaces
        ]


parser : Parser Int
parser =
    Parser.succeed identity
        |. Parser.spaces
        |= expression
        |. Parser.end


numbersPerExpression : Int
numbersPerExpression =
    1000


{-| Generate, print, parse and evaluate expression `k`.
-}
parsesBack : Int -> Bool
parsesBack k =
    let
        ( expr, _ ) =
            generate numbersPerExpression (k * 7919 + 1)
    in
    Parser.run parser (String.concat (print expr [])) == Ok (evaluate expr)


bench : Int -> Bool
bench n =
    List.all parsesBack (List.range 1 n)
