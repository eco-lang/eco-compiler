module Compiler.MonoOpt.TaggedUnions exposing
    ( TagChoice, CtorForm(..), choose, censusLabels, taggedForms, renderStats
    )

{-| Tagged words for multi-constructor unions (plans/constructor-representation-followups.md
F1): every word of a tagged type carries its constructor's declaration index in
bits 43–52, so a one-field constructor whose field's words always have those
bits clear can be the field's word itself, tagged (`Bare`), instead of a heap
`Custom`.

This module only decides; F1.0 runs it in report-only mode, for the
constructor census (`censusLabels`), to measure how many allocations `Bare`
constructors would save (gate F1-D).

A type with two or more constructors is a candidate unless (MONO_035) it is
kernel-owned or kernel-visible at that instantiation, it has more than 1,023
constructors, it is nullable, it is the payload of a nullable type (whose tests
and `Just x = x` read its words in their own encoding), or it meets another
view other than a move-only one (`RepresentationMeets.movesOnly`). A
constructor is `Nullary` (no fields: its null-cons word already carries its
index), `Bare` (one field whose words always have bits 43–52 clear), or `Boxed`
with the reason it cannot be bare. A field's words have those bits set when its
type is Int, Float or Char (unboxed, `alloc-unboxed`), has a nullary
constructor, is nullable or kernel-owned (`alloc-constant-type`), is a type
variable (`alloc-var`), or is itself tagged (`alloc-nested`); a constructor with
several fields is `alloc-fields`. A candidate with no `Bare` constructor is
dropped, which can make another's field bare-eligible again, so the choice
iterates to a fixpoint (the tagged set only shrinks).

@docs TagChoice, CtorForm, choose, censusLabels, taggedForms, renderStats

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Kernel.Visibility as Visibility
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Dict


{-| How one constructor of a tagged type is represented.
-}
type CtorForm
    = Nullary
    | Bare
    | Boxed String


{-| The decision for every custom type with two or more constructors: its
constructors' forms when it is tagged, or the reason it is not.
-}
type alias TagChoice =
    Mono.LayoutMap (Result String (List ( String, CtorForm )))


{-| Chooses the tagged types of a graph whose constructors are `ctorShapes`,
after erasure and after the nullable choice (`nullable`).
-}
choose :
    KernelVisible.KvSet
    -> List RepresentationMeets.Meet
    -> Mono.LayoutMap Mono.NullableInfo
    -> Mono.LayoutMap (List Mono.CtorShape)
    -> TagChoice
choose kv meets nullable ctorShapes =
    let
        nullablePayloads : Mono.LayoutSet
        nullablePayloads =
            Mono.layoutMapFoldl
                (\key _ acc ->
                    case Mono.layoutMapGet key ctorShapes of
                        Just shapes ->
                            List.foldl
                                (\s a ->
                                    case s.fieldTypes of
                                        [ f ] ->
                                            Mono.layoutSetInsert f a

                                        _ ->
                                            a
                                )
                                acc
                                shapes

                        Nothing ->
                            acc
                )
                Mono.layoutSetEmpty
                nullable

        meetsOther : Mono.LayoutSet
        meetsOther =
            List.foldl
                (\m acc ->
                    if Mono.eqKeyLayout m.a m.b then
                        acc

                    else
                        acc |> Mono.layoutSetInsert m.a |> Mono.layoutSetInsert m.b
                )
                Mono.layoutSetEmpty
                meets

        exclusion : Mono.MonoType -> List Mono.CtorShape -> Maybe String
        exclusion key shapes =
            case key of
                Mono.MCustom _ home name _ ->
                    if Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name then
                        Just "kernel-owned"

                    else if KernelVisible.isVisibleInstance kv key then
                        Just "kernel-visible"

                    else if List.length shapes > Mono.nullWordMaxIndex + 1 then
                        Just "too-many-ctors"

                    else if Mono.layoutMapMember key nullable then
                        Just "nullable"

                    else if Mono.layoutSetMember key nullablePayloads then
                        Just "nullable-payload"

                    else if Mono.layoutSetMember key meetsOther then
                        Just "meets"

                    else
                        Nothing

                _ ->
                    Just "not-custom"

        multi : List ( Mono.MonoType, List Mono.CtorShape )
        multi =
            Mono.layoutMapFoldl
                (\key shapes acc ->
                    if List.length shapes >= 2 then
                        ( key, shapes ) :: acc

                    else
                        acc
                )
                []
                ctorShapes

        ( excluded, candidates0 ) =
            List.foldr
                (\( key, shapes ) ( exc, cands ) ->
                    case exclusion key shapes of
                        Just reason ->
                            ( ( key, reason ) :: exc, cands )

                        Nothing ->
                            ( exc, ( key, shapes ) :: cands )
                )
                ( [], [] )
                multi

        fieldForm : Mono.LayoutSet -> Mono.MonoType -> CtorForm
        fieldForm tagged f =
            case f of
                Mono.MInt ->
                    Boxed "alloc-unboxed"

                Mono.MFloat ->
                    Boxed "alloc-unboxed"

                Mono.MChar ->
                    Boxed "alloc-unboxed"

                Mono.MVar _ _ ->
                    Boxed "alloc-var"

                Mono.MCustom _ home name _ ->
                    if Mono.layoutSetMember f tagged then
                        Boxed "alloc-nested"

                    else if
                        Mono.layoutMapMember f nullable
                            || Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name
                            || (Mono.layoutMapGet f ctorShapes
                                    |> Maybe.map (List.any (\s -> List.isEmpty s.fieldTypes))
                                    |> Maybe.withDefault True
                               )
                    then
                        Boxed "alloc-constant-type"

                    else
                        Bare

                _ ->
                    Bare

        formsOf : Mono.LayoutSet -> List Mono.CtorShape -> List ( String, CtorForm )
        formsOf tagged shapes =
            List.map
                (\s ->
                    ( s.name
                    , case s.fieldTypes of
                        [] ->
                            Nullary

                        [ f ] ->
                            fieldForm tagged f

                        _ ->
                            Boxed "alloc-fields"
                    )
                )
                shapes

        fixpoint : List ( Mono.MonoType, List Mono.CtorShape ) -> List ( Mono.MonoType, List ( String, CtorForm ) )
        fixpoint cands =
            let
                candSet =
                    Mono.layoutSetFromList (List.map Tuple.first cands)

                withForms =
                    List.map (\( key, shapes ) -> ( key, shapes, formsOf candSet shapes )) cands

                kept =
                    List.filter (\( _, _, forms ) -> List.any (\( _, form ) -> form == Bare) forms) withForms
            in
            if List.length kept == List.length cands then
                List.map (\( key, _, forms ) -> ( key, forms )) withForms

            else
                fixpoint (List.map (\( key, shapes, _ ) -> ( key, shapes )) kept)

        chosen : List ( Mono.MonoType, List ( String, CtorForm ) )
        chosen =
            fixpoint candidates0

        taggedSet =
            Mono.layoutSetFromList (List.map Tuple.first chosen)

        noBare : List ( Mono.MonoType, String )
        noBare =
            List.filterMap
                (\( key, _ ) ->
                    if Mono.layoutSetMember key taggedSet then
                        Nothing

                    else
                        Just ( key, "no-bare" )
                )
                candidates0
    in
    List.foldl (\( key, forms ) acc -> Mono.layoutMapInsert key (Ok forms) acc)
        (List.foldl (\( key, reason ) acc -> Mono.layoutMapInsert key (Err reason) acc) Mono.layoutMapEmpty (excluded ++ noBare))
        chosen


{-| The census label of each constructor of every multi-constructor type, by
type: `nullary`, `bare`, the `Boxed` reason, or `excluded-<reason>`.
-}
censusLabels : Mono.LayoutMap (List Mono.CtorShape) -> TagChoice -> Mono.LayoutMap (List ( String, String ))
censusLabels ctorShapes choice =
    Mono.layoutMapFoldl
        (\key decision acc ->
            let
                labels =
                    case decision of
                        Ok forms ->
                            List.map
                                (\( ctor, form ) ->
                                    ( ctor
                                    , case form of
                                        Nullary ->
                                            "nullary"

                                        Bare ->
                                            "bare"

                                        Boxed reason ->
                                            reason
                                    )
                                )
                                forms

                        Err reason ->
                            Mono.layoutMapGet key ctorShapes
                                |> Maybe.withDefault []
                                |> List.map (\s -> ( s.name, "excluded-" ++ reason ))
            in
            Mono.layoutMapInsert key labels acc
        )
        Mono.layoutMapEmpty
        choice


{-| The tagged unions of a choice, each with the form of every constructor, as
`Mono.ReprInfo.tagged` holds them for the code generator.
-}
taggedForms : TagChoice -> Mono.LayoutMap (List ( String, Mono.TagForm ))
taggedForms choice =
    Mono.layoutMapFoldl
        (\key decision acc ->
            case decision of
                Ok forms ->
                    Mono.layoutMapInsert key
                        (List.map
                            (\( ctor, form ) ->
                                ( ctor
                                , case form of
                                    Nullary ->
                                        Mono.TagNullary

                                    Bare ->
                                        Mono.TagBare

                                    Boxed _ ->
                                        Mono.TagBoxed
                                )
                            )
                            forms
                        )
                        acc

                Err _ ->
                    acc
        )
        Mono.layoutMapEmpty
        choice


{-| One line for the inline report: the tagged unions chosen, their `Bare`
constructors, and the candidates excluded, by reason.
-}
renderStats : TagChoice -> String
renderStats choice =
    let
        ( tagged, bare, reasons ) =
            Mono.layoutMapFoldl
                (\_ decision ( t, b, rs ) ->
                    case decision of
                        Ok forms ->
                            ( t + 1, b + List.length (List.filter (\( _, f ) -> f == Bare) forms), rs )

                        Err reason ->
                            ( t, b, Dict.update reason (\n -> Just (Maybe.withDefault 0 n + 1)) rs )
                )
                ( 0, 0, Dict.empty )
                choice
    in
    "tagged-unions: "
        ++ String.fromInt tagged
        ++ " types, "
        ++ String.fromInt bare
        ++ " bare constructors; excluded "
        ++ String.join ", " (List.map (\( r, n ) -> r ++ " " ++ String.fromInt n) (Dict.toList reasons))
