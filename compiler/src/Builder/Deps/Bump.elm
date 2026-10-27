module Builder.Deps.Bump exposing (getPossibilities)

{-| A package's next version must follow on from a version already published,
and this module lists the versions that do.

A new version is one of three kinds of bump. A MAJOR bump starts a new major
series above the latest version. A MINOR bump continues a major series from its
highest version, and a PATCH bump continues a major.minor series from its
highest version. Older series may still be continued, so each series gets its
own MINOR or PATCH candidate.

For example, with versions 1.0.0, 1.0.1, 1.1.0 and 2.0.0:

  - MAJOR from 2.0.0 to 3.0.0
  - MINOR from 1.1.0 to 1.2.0 and from 2.0.0 to 2.1.0
  - PATCH from 1.0.1 to 1.0.2, from 1.1.0 to 1.1.1 and from 2.0.0 to 2.0.1

The highest version of a series is found by order, not by comparison: the
known versions are assumed newest first, as `Builder.Deps.Registry`'s
`KnownVersions` describes, and the last of each run of the same series in the
reversed list is taken as its highest.

-}

import Builder.Deps.Registry exposing (KnownVersions(..))
import Compiler.Elm.Magnitude as M
import Compiler.Elm.Version as V
import List.Extra
import Utils.Main as Utils



-- ====== GET POSSIBILITIES ======


{-| Returns every version that may be published next, each as the version it
bumps from, the new version and the kind of bump.

The MAJOR candidate comes first, then the MINOR candidates in ascending order of
series, then the PATCH candidates likewise. The result is only right if the
known versions are newest first.

-}
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


{-| Returns whether two versions have the same major number.
-}
sameMajor : V.Version -> V.Version -> Bool
sameMajor (V.Version major1 _ _) (V.Version major2 _ _) =
    major1 == major2


{-| Returns whether two versions have the same major and minor numbers.
-}
sameMinor : V.Version -> V.Version -> Bool
sameMinor (V.Version major1 minor1 _) (V.Version major2 minor2 _) =
    major1 == major2 && minor1 == minor2
