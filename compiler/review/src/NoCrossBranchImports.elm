module NoCrossBranchImports exposing
    ( rule
    , Branches(..)
    )

{-| Forbids imports between two branches of the module tree, in either
direction. A module belongs to a branch when its name starts with one of the
branch's prefixes.


# Rule

@docs rule


# Type

@docs Branches

-}

import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.Node as Node exposing (Node)
import Review.Rule as Rule exposing (Error, Rule)


{-| Two branches, each a list of module-name prefixes.
-}
type Branches
    = Branches (List (List String)) (List (List String))


{-| Reports every import from a module of one branch of a module of the other.
-}
rule : Branches -> Rule
rule branches =
    Rule.newModuleRuleSchema "NoCrossBranchImports" Nothing
        |> Rule.withModuleDefinitionVisitor (moduleDefinitionVisitor branches)
        |> Rule.withImportVisitor importVisitor
        |> Rule.fromModuleRuleSchema


{-| The context is the branch the module is in, as the prefixes of the other
branch, or `Nothing` when it is in neither.
-}
moduleDefinitionVisitor : Branches -> Node Module -> Maybe (List (List String)) -> ( List (Error {}), Maybe (List (List String)) )
moduleDefinitionVisitor (Branches left right) node _ =
    let
        name =
            Module.moduleName (Node.value node)
    in
    ( []
    , if inBranch left name then
        Just right

      else if inBranch right name then
        Just left

      else
        Nothing
    )


importVisitor : Node Import -> Maybe (List (List String)) -> ( List (Error {}), Maybe (List (List String)) )
importVisitor node context =
    let
        imported =
            Node.value (Node.value node).moduleName
    in
    case context of
        Just other ->
            if inBranch other imported then
                ( [ Rule.error
                        { message = "Found import across branches!"
                        , details =
                            [ "\"" ++ String.join "." imported ++ "\" is in the other branch of the compiler, which this module may not import."
                            ]
                        }
                        (Node.range node)
                  ]
                , context
                )

            else
                ( [], context )

        Nothing ->
            ( [], context )


inBranch : List (List String) -> List String -> Bool
inBranch prefixes name =
    List.any (\prefix -> List.take (List.length prefix) name == prefix) prefixes
