module Compiler.Type.Occurs exposing (occurs)

{-| An infinite type is one that contains itself, such as a variable `a` that
has been solved to `List a`. Such a type cannot be written down. This module
provides a test for whether a variable's solved type is infinite.

The solved types live in the union-find store of `Compiler.Type.UnionFind`, as
variables whose contents may refer to further variables. A cycle among those
references is an infinite type. `occurs` walks the references from one variable
and reports whether it ever reaches a variable a second time along the same
path.

The check is a separate walk over the store; nothing in this module runs it
automatically.


# Occurs Check

@docs occurs

-}

import Compiler.AST.TypeVars as Vars
import Compiler.Type.UnionFind as UF
import Dict
import System.TypeCheck.IO as IO exposing (IO)



-- ====== OCCURS ======


{-| Returns `True` when the type reachable from `var` contains a cycle, that is,
when some variable is reached again while following references from `var`.

The variables remembered are those on the current path only, so substructure
shared between two branches is walked once for each branch and is not a cycle.
For an alias, only the alias's arguments are followed, not the type it stands
for. A lambda set is not followed into: its members are not type structure, so
no infinite type can arise through them.

-}
occurs : Vars.Variable -> IO Bool
occurs var =
    occursHelp [] var False


{-| Returns `True` when a variable on the path `seen` is reached again from
`var`, and otherwise `foundCycle`.
-}
occursHelp : List Vars.Variable -> Vars.Variable -> Bool -> IO Bool
occursHelp seen var foundCycle =
    if List.member var seen then
        IO.pure True

    else
        UF.get var
            |> IO.andThen
                (\props ->
                    case props.content of
                        Vars.FlexVar _ ->
                            IO.pure foundCycle

                        Vars.FlexSuper _ _ ->
                            IO.pure foundCycle

                        Vars.RigidVar _ ->
                            IO.pure foundCycle

                        Vars.RigidSuper _ _ ->
                            IO.pure foundCycle

                        Vars.Structure term ->
                            let
                                newSeen : List Vars.Variable
                                newSeen =
                                    var :: seen
                            in
                            case term of
                                Vars.App1 _ _ args ->
                                    IO.foldrM (occursHelp newSeen) foundCycle args

                                Vars.Fun1 a b ->
                                    occursHelp newSeen b foundCycle |> IO.andThen (occursHelp newSeen a)

                                Vars.FunL a b s ->
                                    occursHelp newSeen s foundCycle
                                        |> IO.andThen (occursHelp newSeen b)
                                        |> IO.andThen (occursHelp newSeen a)

                                Vars.LambdaSet1 _ ->
                                    -- Inclusion edges between lambda sets are not type
                                    -- structure, so no infinite type arises through them.
                                    IO.pure foundCycle

                                Vars.EmptyRecord1 ->
                                    IO.pure foundCycle

                                Vars.Record1 fields ext ->
                                    IO.foldrM (occursHelp newSeen) foundCycle (Dict.values fields) |> IO.andThen (occursHelp newSeen ext)

                                Vars.Unit1 ->
                                    IO.pure foundCycle

                                Vars.Tuple1 a b cs ->
                                    IO.foldrM (occursHelp newSeen) foundCycle cs |> IO.andThen (occursHelp newSeen b) |> IO.andThen (occursHelp newSeen a)

                        Vars.Alias _ _ args _ ->
                            IO.foldrM (occursHelp (var :: seen)) foundCycle (List.map Tuple.second args)

                        Vars.Error ->
                            IO.pure foundCycle
                )
