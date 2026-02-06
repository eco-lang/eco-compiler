module EnforceBoundaries exposing
    ( rule
    , Layer(..), Stack(..)
    )

{-| Allows the enforcement of architecture boundaries using elm-review.


# Rule

@docs rule


# Type

@docs Layer, Stack

-}

import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.Node as Node exposing (Node)
import Review.Rule as Rule exposing (Error, Rule)


{-|


## Example

-}
type Stack
    = LayerStack (List Layer)


{-|


## Example

-}
type Layer
    = PrefixLayer (List (List String))
    | Remainder


{-|


## Example configuration

-}
rule : Stack -> Rule
rule layerRule =
    Rule.newModuleRuleSchema "EnforceBoundaries" 0
        |> Rule.withModuleDefinitionVisitor (moduleDefinitionVisitor layerRule)
        |> Rule.withImportVisitor (importVisitor layerRule)
        |> Rule.fromModuleRuleSchema


moduleDefinitionVisitor : Stack -> Node Module -> Int -> ( List (Error {}), Int )
moduleDefinitionVisitor layerRule node _ =
    ( []
    , Node.value node
        |> Module.moduleName
        |> layerNumber layerRule
    )


importVisitor : Stack -> Node Import -> Int -> ( List (Error {}), Int )
importVisitor layerRule node moduleLayerNumber =
    let
        importingModuleName =
            Node.value node
                |> .moduleName
                |> Node.value
    in
    if moduleLayerNumber > -1 && isViolatedWithLayerRule layerRule moduleLayerNumber importingModuleName then
        ( [ Rule.error
                { message = "Found import to upper layer!"
                , details =
                    [ "This module is layer number " ++ String.fromInt moduleLayerNumber ++ "."
                    , "But the module is importing \"" ++ moduleNameAsString importingModuleName ++ "\" layer number " ++ (String.fromInt <| layerNumber layerRule importingModuleName) ++ "."
                    ]
                }
                (Node.range node)
          ]
        , moduleLayerNumber
        )

    else
        ( []
        , moduleLayerNumber
        )


moduleNameAsString : List String -> String
moduleNameAsString =
    List.intersperse "."
        >> List.foldl (\x acc -> acc ++ x) ""


isViolatedWithLayerRule : Stack -> Int -> List String -> Bool
isViolatedWithLayerRule moduleLayerRule moduleLayerNumber importingModuleName =
    moduleLayerNumber < layerNumber moduleLayerRule importingModuleName


layerNumber : Stack -> List String -> Int
layerNumber ((LayerStack layers) as moduleLayerRule) moduleName =
    let
        fold ( index, layer ) acc =
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if isInLayer layer moduleName then
                        Just index

                    else
                        Nothing
    in
    layers
        |> List.indexedMap (\index layer -> ( index, layer ))
        |> List.foldl fold Nothing
        |> Maybe.withDefault (remainderLayerNumber moduleLayerRule)


remainderLayerNumber : Stack -> Int
remainderLayerNumber (LayerStack layers) =
    layers
        |> List.indexedMap (\i x -> ( i, x ))
        |> List.foldl
            (\( index, layer ) acc ->
                if layer == Remainder then
                    Just index

                else
                    acc
            )
            Nothing
        --|> Maybe.withDefault (List.length layers)
        |> Maybe.withDefault -1


isInLayer : Layer -> List String -> Bool
isInLayer layer moduleName =
    case layer of
        PrefixLayer layerModuleNames ->
            List.any (\layerModuleName -> isMatchWith layerModuleName moduleName) layerModuleNames

        Remainder ->
            False


isMatchWith : List String -> List String -> Bool
isMatchWith names moduleName =
    let
        isMatchWith_ namesX namesY =
            case ( namesX, namesY ) of
                ( [], _ ) ->
                    True

                ( x :: xs, y :: ys ) ->
                    if x == y then
                        isMatchWith_ xs ys

                    else
                        False

                ( _ :: _, [] ) ->
                    False
    in
    isMatchWith_ names moduleName
