module Builder.Deps.Bump exposing (getPossibilities)

{-| Generates possible version bump candidates for package publishing.

Given the known version history of a package, this module computes all valid next
versions for MAJOR, MINOR, and PATCH bumps. It identifies appropriate base versions
by grouping existing versions by major and minor version numbers.

For example, with versions [1.0.0, 1.0.1, 1.1.0, 2.0.0]:

  - MAJOR bump from 2.0.0 to 3.0.0
  - MINOR bumps from 1.1.0 to 1.2.0 and 2.0.0 to 2.1.0
  - PATCH bumps from 1.0.1 to 1.0.2, 1.1.0 to 1.1.1, and 2.0.0 to 2.0.1


# Version Candidates

@docs getPossibilities

-}

import Builder.Deps.Registry exposing (KnownVersions(..))
import Compiler.Elm.Magnitude as M
import Compiler.Elm.Version as V
import List.Extra
import Utils.Main as Utils



-- GET POSSIBILITIES


getPossibilities : KnownVersions -> List ( V.Version, V.Version, M.Magnitude )
getPossibilities (KnownVersions latest previous) =
    let
        allVersions : List V.Version
        allVersions =
            List.reverse (latest :: previous)

        minorPoints : List V.Version
        minorPoints =
            List.filterMap List.Extra.last (Utils.listGroupBy sameMajor allVersions)

        patchPoints : List V.Version
        patchPoints =
            List.filterMap List.Extra.last (Utils.listGroupBy sameMinor allVersions)
    in
    ( latest, V.bumpMajor latest, M.MAJOR )
        :: List.map (\v -> ( v, V.bumpMinor v, M.MINOR )) minorPoints
        ++ List.map (\v -> ( v, V.bumpPatch v, M.PATCH )) patchPoints


sameMajor : V.Version -> V.Version -> Bool
sameMajor (V.Version major1 _ _) (V.Version major2 _ _) =
    major1 == major2


sameMinor : V.Version -> V.Version -> Bool
sameMinor (V.Version major1 minor1 _) (V.Version major2 minor2 _) =
    major1 == major2 && minor1 == minor2
