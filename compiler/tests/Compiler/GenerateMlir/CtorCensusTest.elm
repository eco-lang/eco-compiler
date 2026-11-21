module Compiler.GenerateMlir.CtorCensusTest exposing (suite)

{-| Tests for `Compiler.GenerateMlir.CtorCensus`, the constructor census of
plans/constructor-representation-levels.md (unit M0): the level of a custom
type from its constructors, the payload class of a constructor, and the table
that gives each construction its census id.

The tests establish:

  - a type with one constructor of one field is level 1, one constructor of
    several fields level 2, several constructors of at most one field level 3,
    and anything else level 4;
  - a level-1 field of type Int, Float or Char is `unboxed`, any other `boxed`;
  - `Maybe` of a record is `adm`, of an `Int` is `inadm`, of a `String` is
    `spare` (it is nullable with a spare null word, since `Just ""` is Empty);
  - with the census off every lookup gives `Nothing`; with it on, two shapes
    of the same constructor and field types share an id, an unknown shape gets
    id 0, and the rendered table has one row per class.

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateMlir.CtorCensus as CtorCensus
import Compiler.IR.Mono as Mono
import Dict
import Expect
import Test exposing (Test, describe, test)


shape : String -> Int -> List Mono.MonoType -> Mono.CtorShape
shape name tag fields =
    { name = name, tag = tag, fieldTypes = fields }


rec : Mono.MonoType
rec =
    Mono.mRecord (Dict.fromList [ ( "x", Mono.MInt ) ])


maybeOf : Mono.MonoType -> Mono.MonoType
maybeOf t =
    Mono.mCustom ModuleName.maybe "Maybe" [ t ]


maybeShapes : Mono.MonoType -> List Mono.CtorShape
maybeShapes t =
    [ shape "Just" 0 [ t ], shape "Nothing" 1 [] ]


suite : Test
suite =
    describe "Compiler.GenerateMlir.CtorCensus"
        [ test "levels" <|
            \_ ->
                [ CtorCensus.levelOf [ shape "W" 0 [ Mono.MInt ] ]
                , CtorCensus.levelOf [ shape "P" 0 [ Mono.MInt, Mono.MInt ] ]
                , CtorCensus.levelOf (maybeShapes rec)
                , CtorCensus.levelOf [ shape "A" 0 [ Mono.MInt, Mono.MInt ], shape "B" 1 [] ]
                ]
                    |> Expect.equal [ 1, 2, 3, 4 ]
        , test "payload classes" <|
            \_ ->
                let
                    cls t s =
                        CtorCensus.payloadClass (\_ -> Nothing) t s (List.head s |> Maybe.withDefault (shape "" 0 []))
                in
                [ CtorCensus.payloadClass (\_ -> Nothing) Mono.MUnit [ shape "W" 0 [ Mono.MFloat ] ] (shape "W" 0 [ Mono.MFloat ])
                , CtorCensus.payloadClass (\_ -> Nothing) Mono.MUnit [ shape "W" 0 [ Mono.MString ] ] (shape "W" 0 [ Mono.MString ])
                , cls (maybeOf rec) (maybeShapes rec)
                , cls (maybeOf Mono.MInt) (maybeShapes Mono.MInt)
                , cls (maybeOf Mono.MString) (maybeShapes Mono.MString)
                ]
                    |> Expect.equal [ "unboxed", "boxed", "adm", "inadm", "spare" ]
        , test "off gives no ids" <|
            \_ ->
                CtorCensus.idForShape (CtorCensus.build False [] Mono.layoutMapEmpty Mono.layoutMapEmpty) "Just" [ rec ]
                    |> Expect.equal Nothing
        , test "on: ids by shape, unknown shape is 0, one row per class" <|
            \_ ->
                let
                    shapes =
                        Mono.layoutMapEmpty
                            |> Mono.layoutMapInsert (maybeOf rec) (maybeShapes rec)
                            |> Mono.layoutMapInsert (maybeOf Mono.MInt) (maybeShapes Mono.MInt)

                    table =
                        CtorCensus.build True [] Mono.layoutMapEmpty shapes

                    idRec =
                        CtorCensus.idForShape table "Just" [ rec ]

                    idInt =
                        CtorCensus.idForShape table "Just" [ Mono.MInt ]
                in
                Expect.all
                    [ \_ -> Expect.notEqual idRec idInt
                    , \_ -> Expect.equal (CtorCensus.idForShape table "Nope" [ rec ]) (Just 0)
                    , \_ -> Expect.equal (Maybe.map (\i -> i > 0) idRec) (Just True)
                    , \_ ->
                        CtorCensus.render table
                            |> String.lines
                            |> List.filter (\l -> String.contains "\tJust\t" l)
                            |> List.length
                            |> Expect.equal 3
                    ]
                    ()
        ]
