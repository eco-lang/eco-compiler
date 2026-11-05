module Compiler.Type.TypeTest exposing (suite)

{-| Tests of `Compiler.Type.Type.toAnnotation` on the members of an unannotated
recursive group, which share their type variables: the annotation of a later
member must quantify over every variable of its type and give each a name of
its own (Hindley-Milner generalizes each member over its own free variables).

In `f x = g x []` and `g x y = f x`, the solved types are `f : a -> b` and
`g : a -> List c -> b`, `g` sharing `a` and `b` with `f`. `toAnnotation` runs on
`f` first and marks and names `a` and `b`; the walk for `g` skips them, and
before the fix their names were not reserved there, so `g`'s own `c` was named
`a` too and `g` was exported as `a -> List a -> b`. Another module's valid
`Main.g n [ "s" ]` was then rejected (`test/scripts/cli-errors.test.js`, "a
later member of a recursive group keeps its own type variables in the
interface").

Among what is not tested: the names themselves, only that they are distinct
and quantified, and groups of more than two members.

-}

import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Canonical as Can
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect
import Maybe.Extra as Maybe
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Compiler.Type.Type.toAnnotation on a recursive group"
        [ Test.test "a later member's own variable gets a name of its own" <|
            \_ ->
                case annotationVars "g" of
                    Ok ( quantified, mentioned ) ->
                        Expect.all
                            [ \_ -> Expect.equal 3 (List.length mentioned)
                            , \_ -> Expect.equal (List.sort mentioned) (List.sort quantified)
                            ]
                            ()

                    Err msg ->
                        Expect.fail msg
        , Test.test "the earlier member quantifies over its two variables" <|
            \_ ->
                case annotationVars "f" of
                    Ok ( quantified, mentioned ) ->
                        Expect.all
                            [ \_ -> Expect.equal 2 (List.length mentioned)
                            , \_ -> Expect.equal (List.sort mentioned) (List.sort quantified)
                            ]
                            ()

                    Err msg ->
                        Expect.fail msg
        ]


{-| The group, as a module whose imports are filtered to the mock interfaces.
-}
source : String
source =
    "module Test exposing (..)\n\n\nf x =\n    g x []\n\n\ng x y =\n    f x\n"


{-| Returns the quantified names of `name`'s annotation and the distinct type
variable names its type mentions.
-}
annotationVars : String -> Result String ( List String, List String )
annotationVars name =
    case Parse.fromByteString Parse.Application source of
        Err _ ->
            Err "the fixture does not parse"

        Ok (Src.Module m) ->
            Src.Module { m | imports = List.filter (\(Src.Import ( _, A.At _ n ) _ _) -> Dict.member n Basic.testIfaces) m.imports }
                |> Pipeline.runToTypeCheck
                |> Result.andThen
                    (\artifacts ->
                        case Dict.get name artifacts.annotations of
                            Just (Can.Forall freeVars tipe) ->
                                Ok ( Dict.keys freeVars, distinct (typeVarNames tipe []) )

                            Nothing ->
                                Err ("no annotation for " ++ name)
                    )


distinct : List String -> List String
distinct names =
    Dict.keys (Dict.fromList (List.map (\n -> ( n, () )) names))


{-| The type variable names `tipe` mentions, with repeats.
-}
typeVarNames : Can.Type String -> List String -> List String
typeVarNames tipe acc =
    case tipe of
        Can.TLambda _ arg result ->
            typeVarNames result (typeVarNames arg acc)

        Can.TVar n ->
            n :: acc

        Can.TType _ _ args ->
            List.foldl typeVarNames acc args

        Can.TRecord fields maybeExt ->
            Dict.foldl (\_ (Can.FieldType _ t) a -> typeVarNames t a) (Maybe.withDefault acc (Maybe.map (\e -> e :: acc) maybeExt)) fields

        Can.TUnit ->
            acc

        Can.TTuple a b cs ->
            List.foldl typeVarNames acc (a :: b :: Maybe.toList cs)

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, t ) a -> typeVarNames t a) acc args
