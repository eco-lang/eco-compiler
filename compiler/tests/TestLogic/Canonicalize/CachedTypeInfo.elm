module TestLogic.Canonicalize.CachedTypeInfo exposing (expectTypeInfoCached)

{-| An expectation for test programs: the type information that type checking
records for a module's top-level definitions (the `annotations` dictionary)
covers every definition and agrees with the module's source.

`expectTypeInfoCached` runs a source module through
`TestLogic.TestPipeline.runToPostSolve`, which canonicalizes it against the
pipeline's mock interfaces, type checks it with node ids recorded and runs
PostSolve. A stage that fails gives `Err`, and the expectation fails with its
message. A stage that crashes is not caught.

After a successful run, the expectation walks the module's top-level
definitions, the members of recursive groups included, and looks each one's
name up in the annotations, the types that solving returned for the module's
top-level names. It reports an issue when:

  - a definition has no annotation;
  - an annotation is not closed: a type variable (a record extension variable
    included) occurs in its type but is not among its quantified variables;
  - a definition written with a type annotation (`Can.TypedDef`) has an
    annotation whose type, with aliases expanded, differs from the written
    type (the argument types followed by the result type) other than by a
    consistent one-to-one renaming of type variables.

Among what is not checked:

  - the type of a definition without a written annotation, beyond it being
    closed;
  - the node types, before or after PostSolve;
  - anything stored on disk, or what happens after a module is edited.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.Utils.Type as TypeUtils
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Set
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` gets through `TestLogic.TestPipeline.runToPostSolve`
and `collectCachedTypeIssues` finds no issue; fails with the pipeline's message
when a stage fails, and with the issues otherwise.
-}
expectTypeInfoCached : Src.Module -> Expect.Expectation
expectTypeInfoCached srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectCachedTypeIssues result.canonical result.annotations
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| Returns the issues found by checking each top-level definition of
`canonical` against its entry in `annotations`.
-}
collectCachedTypeIssues : Can.Module -> Dict.Dict String (Can.Annotation Name) -> List String
collectCachedTypeIssues canonical annotations =
    let
        (Can.Module moduleData) =
            canonical
    in
    checkDefsHaveAnnotations moduleData.decls annotations


{-| Returns the issues `checkDefHasAnnotation` reports for each definition in
`decls`, the members of a recursive group included.
-}
checkDefsHaveAnnotations : Can.Decls -> Dict.Dict String (Can.Annotation Name) -> List String
checkDefsHaveAnnotations decls annotations =
    case decls of
        Can.Declare def rest ->
            checkDefHasAnnotation def annotations
                ++ checkDefsHaveAnnotations rest annotations

        Can.DeclareRec def defs rest ->
            checkDefHasAnnotation def annotations
                ++ List.concatMap (\d -> checkDefHasAnnotation d annotations) defs
                ++ checkDefsHaveAnnotations rest annotations

        Can.SaveTheEnvironment ->
            []


{-| Returns the issues for one definition: a missing annotation, an annotation
that is not closed, and for a `TypedDef` an annotation whose type does not
match the written one.
-}
checkDefHasAnnotation : Can.Def -> Dict.Dict String (Can.Annotation Name) -> List String
checkDefHasAnnotation def annotations =
    case def of
        Can.Def (A.At _ name) _ _ ->
            case Dict.get name annotations of
                Just annotation ->
                    checkClosed name annotation

                Nothing ->
                    [ "Top-level definition '" ++ name ++ "' has no annotation" ]

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            case Dict.get name annotations of
                Just ((Can.Forall _ annotationType) as annotation) ->
                    let
                        writtenType =
                            List.foldr
                                (\( _, argType ) acc -> Can.TLambda TypeIds.NoArrow argType acc)
                                resultType
                                typedArgs
                    in
                    checkClosed name annotation
                        ++ (if sameTypeUpToRenaming (TypeUtils.deepDealias writtenType) (TypeUtils.deepDealias annotationType) then
                                []

                            else
                                [ "Annotation of '" ++ name ++ "' does not match its written type annotation" ]
                           )

                Nothing ->
                    [ "Top-level definition '" ++ name ++ "' has no annotation" ]


{-| Reports the type variables of `annotation`'s type, record extension
variables included, that are not among its quantified variables.
-}
checkClosed : Name -> Can.Annotation Name -> List String
checkClosed name (Can.Forall freeVars tipe) =
    typeVars tipe
        |> Set.fromList
        |> Set.toList
        |> List.filter (\v -> not (Dict.member v freeVars))
        |> List.map (\v -> "Annotation of '" ++ name ++ "' mentions type variable '" ++ v ++ "' that it does not quantify")


{-| Returns the type variables that occur in `tipe`, record extension
variables included, with repeats.
-}
typeVars : Can.Type Name -> List Name
typeVars tipe =
    case tipe of
        Can.TLambda _ a b ->
            typeVars a ++ typeVars b

        Can.TVar v ->
            [ v ]

        Can.TType _ _ args ->
            List.concatMap typeVars args

        Can.TRecord fields ext ->
            Maybe.withDefault [] (Maybe.map List.singleton ext)
                ++ List.concatMap (\(Can.FieldType _ t) -> typeVars t) (Dict.values fields)

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            List.concatMap typeVars (a :: b :: cs)

        Can.TAlias _ _ args _ ->
            List.concatMap (Tuple.second >> typeVars) args


{-| True when `a` and `b`, both without aliases, are the same type up to a
consistent one-to-one renaming of type variables. Arrow slots and record field
positions are ignored.
-}
sameTypeUpToRenaming : Can.Type Name -> Can.Type Name -> Bool
sameTypeUpToRenaming a b =
    unifyRenaming [ ( a, b ) ] Dict.empty Dict.empty


{-| Walks the pending pairs of types, extending the renaming in both
directions; fails on a shape mismatch or an inconsistent renaming.
-}
unifyRenaming : List ( Can.Type Name, Can.Type Name ) -> Dict.Dict Name Name -> Dict.Dict Name Name -> Bool
unifyRenaming pending forward backward =
    case pending of
        [] ->
            True

        ( a, b ) :: rest ->
            case ( a, b ) of
                ( Can.TVar x, Can.TVar y ) ->
                    bindVar x y rest forward backward

                ( Can.TLambda _ a1 a2, Can.TLambda _ b1 b2 ) ->
                    unifyRenaming (( a1, b1 ) :: ( a2, b2 ) :: rest) forward backward

                ( Can.TType ha na argsA, Can.TType hb nb argsB ) ->
                    ha
                        == hb
                        && na
                        == nb
                        && List.length argsA
                        == List.length argsB
                        && unifyRenaming (List.map2 Tuple.pair argsA argsB ++ rest) forward backward

                ( Can.TUnit, Can.TUnit ) ->
                    unifyRenaming rest forward backward

                ( Can.TTuple a1 a2 as_, Can.TTuple b1 b2 bs ) ->
                    List.length as_
                        == List.length bs
                        && unifyRenaming (( a1, b1 ) :: ( a2, b2 ) :: List.map2 Tuple.pair as_ bs ++ rest) forward backward

                ( Can.TRecord fieldsA extA, Can.TRecord fieldsB extB ) ->
                    let
                        fieldPairs =
                            List.map2 (\( na, Can.FieldType _ ta ) ( nb, Can.FieldType _ tb ) -> ( na == nb, ( ta, tb ) ))
                                (Dict.toList fieldsA)
                                (Dict.toList fieldsB)
                    in
                    Dict.size fieldsA
                        == Dict.size fieldsB
                        && List.all Tuple.first fieldPairs
                        && (case ( extA, extB ) of
                                ( Nothing, Nothing ) ->
                                    unifyRenaming (List.map Tuple.second fieldPairs ++ rest) forward backward

                                ( Just x, Just y ) ->
                                    bindVar x y (List.map Tuple.second fieldPairs ++ rest) forward backward

                                _ ->
                                    False
                           )

                _ ->
                    False


{-| Records that variable `x` of one type corresponds to `y` of the other, and
continues; fails when either is already paired with a different variable.
-}
bindVar : Name -> Name -> List ( Can.Type Name, Can.Type Name ) -> Dict.Dict Name Name -> Dict.Dict Name Name -> Bool
bindVar x y rest forward backward =
    case ( Dict.get x forward, Dict.get y backward ) of
        ( Nothing, Nothing ) ->
            unifyRenaming rest (Dict.insert x y forward) (Dict.insert y x backward)

        ( Just y_, Just x_ ) ->
            y_ == y && x_ == x && unifyRenaming rest forward backward

        _ ->
            False
