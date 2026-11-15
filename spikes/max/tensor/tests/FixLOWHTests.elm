module FixLOWHTests exposing (suite)

import Expect exposing (Expectation)
import Graph
import Max
import Signature as Sig
import Tensor as T
import Tensor.Control as Control
import Tensor.Internal.Expr as E
import Tensor.Internal.Key as K
import Tensor.Internal.Lower as Lower
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Prim as P
import Test exposing (Test, describe, test)
import Transform


type B
    = B


b =
    T.dim B 3


vec =
    Sig.f32 (T.r1 b)


{-| Every operand of the text names a value visible where it is read: the printer writes any other
as `%<bad N>`.
-}
expectValidText : Result (List String) Graph.Graph -> Expectation
expectValidText r =
    case r of
        Ok g ->
            let
                text =
                    Max.toGenericText g
            in
            if String.contains "<bad" text then
                Expect.fail ("operand out of scope:\n" ++ text)

            else
                Expect.pass

        Err e ->
            Expect.fail (String.join "; " e)


textOf : Result (List String) Graph.Graph -> String
textOf r =
    case r of
        Ok g ->
            Max.toGenericText g

        Err e ->
            "ERR " ++ String.join "; " e


positive x =
    T.sumAll x |> T.greaterThan (T.float 0)


{-| Lines of `text` that contain `needle`, trimmed.
-}
linesWith : String -> String -> List String
linesWith needle text =
    String.lines text |> List.filter (String.contains needle) |> List.map String.trim


suite : Test
suite =
    describe "FixLOWH"
        [ describe "B006 nested regions reach values any number of regions out"
            [ test "cond in a cond branch reading the graph input" <|
                \_ ->
                    expectValidText (Graph.function "g" vec nestedCond)
            , test "cond in a cond branch: the inner add reads the graph input, the inner yield the main chain" <|
                \_ ->
                    let
                        text =
                            textOf (Graph.function "g" vec nestedCond)
                    in
                    Expect.all
                        [ -- z and y are both x, so z + x is x + x
                          \t -> Expect.equal [ "%14 = \"rmo.add\"(%arg0, %arg0) : (!mo.tensor<[3], f32>, !mo.tensor<[3], f32>) -> !mo.tensor<[3], f32>" ] (linesWith "rmo.add" t)

                        -- both inner branches yield the chain %5 made in the graph region, two regions out
                        , \t -> Expect.equal 4 (List.length (List.filter (String.endsWith "%5) : (!mo.tensor<[3], f32>, !mo.chain) -> ()") (linesWith "mo.yield" t)))
                        ]
                        text
            , test "cond in a whileLoop body in a cond branch reading the graph input" <|
                \_ ->
                    expectValidText (Graph.function "g" vec condInLoopInCond)
            , test "cond in a whileLoop body in a cond branch: the add reads x three regions out, the predicate the constant 0 two out" <|
                \_ ->
                    let
                        ops =
                            List.map (String.split " : " >> List.head >> Maybe.withDefault "") (String.lines (textOf (Graph.function "g" vec condInLoopInCond)))
                                |> List.map String.trim
                    in
                    Expect.all
                        [ \l -> Expect.equal True (List.member "%17 = \"rmo.add\"(%arg0, %arg10)" l)
                        , \l -> Expect.equal True (List.member "%14 = \"rmo.greater\"(%13, %3)" l)
                        , \l -> Expect.equal True (List.member "%3 = \"mo.constant\"() {value = #M.dense_array<0.0>" l)
                        ]
                        ops
            , test "whileLoop in a whileLoop body reading the graph input" <|
                \_ ->
                    expectValidText (Graph.function "g" vec loopInLoop)
            , test "whileLoop in a whileLoop body: x + s reads the graph input two regions out" <|
                \_ ->
                    Expect.equal [ "%10 = \"rmo.add\"(%arg0, %arg4)", "%11 = \"rmo.add\"(%10, %arg8)" ]
                        (linesWith "rmo.add" (textOf (Graph.function "g" vec loopInLoop)) |> List.map (String.split " : " >> List.head >> Maybe.withDefault ""))
            ]
        , describe "B007 placeholders read only in a nested body are bound"
            [ test "shared: whileLoop body reads the second argument" <|
                \_ ->
                    expectValidText (Graph.function "g" vec (\x -> Transform.call loopShared ( x, T.scale 2 x )))
            , test "shared: the loop body's add reads the subgraph's second argument" <|
                \_ ->
                    Expect.equal True
                        (List.any (String.contains "\"rmo.add\"(%arg1, %arg5)")
                            (linesWith "rmo.add" (textOf (Graph.function "g" vec (\x -> Transform.call loopShared ( x, T.scale 2 x )))))
                        )
            , test "shared: cond branch reads the argument" <|
                \_ ->
                    let
                        sh =
                            Transform.shared "sh2" vec Sig.anyTensor (\v -> Control.cond (T.float 1 |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor (\s -> T.plus s v) T.negate (T.scale 2 v))
                    in
                    expectValidText (Graph.function "g" vec (\x -> Transform.call sh x))
            , test "inlined call (in a cond branch) whose loop body reads an argument" <|
                \_ ->
                    expectValidText
                        (Graph.function "g"
                            vec
                            (\x ->
                                Control.cond (positive x)
                                    Sig.anyTensor
                                    Sig.anyTensor
                                    (\y -> Transform.call loopShared ( y, T.scale 2 y ))
                                    T.negate
                                    x
                            )
                        )
            , test "two inlined calls on different arguments each get their own loop" <|
                \_ ->
                    let
                        text =
                            textOf
                                (Graph.function "g"
                                    vec
                                    (\x ->
                                        Control.cond (positive x)
                                            Sig.anyTensor
                                            Sig.anyTensor
                                            (\y -> T.plus (Transform.call loopShared ( y, T.scale 2 y )) (Transform.call loopShared ( y, T.scale 3 y )))
                                            T.negate
                                            x
                                    )
                                )
                    in
                    Expect.all
                        [ \t -> Expect.equal False (String.contains "<bad" t)
                        , \t -> Expect.equal 2 (List.length (linesWith "\"mo.while\"" t))

                        -- each loop body adds its own second argument: 2y (%9) and 3y (%13)
                        , \t -> Expect.equal [ "%19 = \"rmo.add\"(%9, %arg17)", "%19 = \"rmo.add\"(%13, %arg17)" ] (linesWith "\"rmo.add\"(%" t |> List.map (String.split " : " >> List.head >> Maybe.withDefault "") |> List.filter (String.startsWith "%19"))
                        , \t -> Expect.equal True (List.member "%9 = \"rmo.mul\"(%arg0, %8)" (linesWith "rmo.mul" t |> List.map (String.split " : " >> List.head >> Maybe.withDefault "")))
                        , \t -> Expect.equal True (List.member "%13 = \"rmo.mul\"(%arg0, %12)" (linesWith "rmo.mul" t |> List.map (String.split " : " >> List.head >> Maybe.withDefault "")))
                        ]
                        text
            ]
        , describe "B008 one subgraph per body, whatever the symbol"
            [ test "two bodies under one symbol give two subgraphs, each call calling its own" <|
                \_ ->
                    let
                        x =
                            E.input "g" 0 P.F32 [ 3 ]

                        body tag p =
                            let
                                scope =
                                    K.start tag

                                v =
                                    E.var scope 0 P.F32 [ 3 ]
                            in
                            { scope = scope, arity = 1, outputs = [ E.prim p [ v ] P.noParams ] }

                        c1 =
                            E.proj (E.call "sym" (body "one" P.Neg) [ x ]) 0

                        c2 =
                            E.proj (E.call "sym" (body "two" P.Exp) [ x ]) 0

                        c3 =
                            E.proj (E.call "sym" (body "one" P.Neg) [ c2 ]) 0

                        text =
                            Ir.printGeneric (Lower.graph "g" [ ( "x", x ) ] [ ( "a", c1 ), ( "b", c3 ) ])

                        callees =
                            linesWith "\"mo.call\"" text
                                |> List.map
                                    (\l ->
                                        if String.contains "callee = @sym," l then
                                            "sym"

                                        else if String.contains "callee = @sym_c1," l then
                                            "sym_c1"

                                        else
                                            l
                                    )
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ "sym", "sym_c1", "sym" ] callees
                        , \t -> Expect.equal 1 (List.length (linesWith "rmo.mo.negative" t))
                        , \t -> Expect.equal 1 (List.length (linesWith "rmo.mo.exp" t))
                        , \t -> Expect.equal 3 (List.length (linesWith "\"mo.graph\"" t))
                        ]
                        text
            , test "two traces of one function under different scopes share one subgraph" <|
                \_ ->
                    let
                        x =
                            E.input "g" 0 P.F32 [ 3 ]

                        body tag =
                            let
                                scope =
                                    K.start tag

                                v =
                                    E.var scope 0 P.F32 [ 3 ]
                            in
                            { scope = scope, arity = 1, outputs = [ E.prim P.Neg [ v ] P.noParams ] }

                        c1 =
                            E.proj (E.call "sym" (body "one") [ x ]) 0

                        c2 =
                            E.proj (E.call "sym" (body "two") [ c1 ]) 0

                        text =
                            Ir.printGeneric (Lower.graph "g" [ ( "x", x ) ] [ ( "a", c2 ) ])
                    in
                    Expect.all
                        [ \t -> Expect.equal 2 (List.length (linesWith "callee = @sym," t))
                        , \t -> Expect.equal 2 (List.length (linesWith "\"mo.graph\"" t))
                        ]
                        text
            ]
        ]


nestedCond : T.Tensor Float T.F32 s -> T.Tensor Float T.F32 s
nestedCond x =
    Control.cond (positive x)
        Sig.anyTensor
        Sig.anyTensor
        (\y -> Control.cond (T.sumAll y |> T.greaterThan (T.float 1)) Sig.anyTensor Sig.anyTensor (\z -> T.plus z x) T.negate y)
        T.negate
        x


loopShared =
    Transform.shared "sh" (Sig.pair vec vec) Sig.anyTensor (\( u, v ) -> Control.whileLoop Sig.anyTensor (\s -> T.sumAll s |> T.lessThan (T.float 10)) (\s -> T.plus s v) u)


condInLoopInCond : T.Tensor Float T.F32 s -> T.Tensor Float T.F32 s
condInLoopInCond x =
    Control.cond (positive x)
        Sig.anyTensor
        Sig.anyTensor
        (\y ->
            Control.whileLoop Sig.anyTensor
                (\s -> T.sumAll s |> T.lessThan (T.float 10))
                (\s -> Control.cond (positive s) Sig.anyTensor Sig.anyTensor (\z -> T.plus z x) T.negate s)
                y
        )
        T.negate
        x


loopInLoop : T.Tensor Float T.F32 s -> T.Tensor Float T.F32 s
loopInLoop x =
    Control.whileLoop Sig.anyTensor
        (\s -> T.sumAll s |> T.lessThan (T.float 100))
        (\s ->
            Control.whileLoop Sig.anyTensor
                (\u -> T.sumAll u |> T.lessThan (T.float 10))
                (\u -> T.plus u (T.plus s x))
                s
        )
        x
