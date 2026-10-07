module FileMetadataTest exposing (main)

{-| Metadata and access (plans/eco-system-library.md Phase 4 step 4.6,
Appendix E.3): `metadata`, `checkAccess`, `changeAccess` (one octal digit per
class from `accessPermissionsToInt`), `changeOwner`, and `changeTimes` with
whole-second precision.
-}

-- CHECK: meta-file: ok File 5
-- CHECK: meta-dir: ok Directory
-- CHECK: meta-sane: ok True True True
-- CHECK: perms-int: 6 7 0 4 1
-- CHECK: access-exists: ok f.txt
-- CHECK: access-read-write: ok f.txt
-- CHECK: access-missing: err ENOENT @missing
-- CHECK: chmod-600: ok f.txt
-- CHECK: access-exec-denied: err EACCES @f.txt
-- CHECK: access-exec-denied-flag: True
-- CHECK: chmod-750: ok f.txt
-- CHECK: access-exec-ok: ok f.txt
-- CHECK: chmod-missing: err ENOENT @missing
-- CHECK: utimes: ok 1000000000000 1500000000000
-- CHECK: utimes-nofollow: ok 1200000000000
-- CHECK: chown-self: ok f.txt
-- CHECK: lchown-self: ok f.txt
-- CHECK: metadata-missing: err ENOENT @missing
-- EXIT: 0

import FileTestHelp exposing (attempt, bytes, child, file)
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)
import Time


label : String -> Task x String -> Task x String
label name =
    Task.map (\s -> name ++ ": " ++ s)


entityName : File.EntityType -> String
entityName e =
    case e of
        File.File ->
            "File"

        File.Directory ->
            "Directory"

        _ ->
            "Other"


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : System.SimpleProgram ()
main =
    FileTestHelp.program
        (\_ ->
            FileTestHelp.withTempDir
                (\dir ->
                    let
                        f =
                            child dir "f.txt"

                        missing =
                            child dir "missing"

                        name =
                            Path.filenameWithExtension
                    in
                    Task.sequence
                        [ attempt (\m -> entityName m.entityType ++ " " ++ String.fromInt m.byteSize)
                            (file (File.writeFile (bytes "12345") f |> Task.andThen (File.metadata { resolveLink = True })))
                            |> label "meta-file"
                        , attempt (.entityType >> entityName) (file (File.metadata { resolveLink = True } dir))
                            |> label "meta-dir"
                        , attempt
                            (\m ->
                                String.join " "
                                    [ boolString (Time.posixToMillis m.lastModified > 1577836800000)
                                    , boolString (m.userID >= 0 && m.groupID >= 0 && m.blockSize > 0)
                                    , boolString (Time.posixToMillis m.created > 0)
                                    ]
                            )
                            (file (File.metadata { resolveLink = True } f))
                            |> label "meta-sane"
                        , Task.succeed
                            (String.join " "
                                (List.map (File.accessPermissionsToInt >> String.fromInt)
                                    [ [ File.Read, File.Write ], [ File.Execute, File.Write, File.Read ], [], [ File.Read ], [ File.Execute ] ]
                                )
                            )
                            |> label "perms-int"
                        , attempt name (file (File.checkAccess [] f)) |> label "access-exists"
                        , attempt name (file (File.checkAccess [ File.Read, File.Write ] f)) |> label "access-read-write"
                        , attempt name (file (File.checkAccess [] missing)) |> label "access-missing"
                        , attempt name
                            (file (File.changeAccess { owner = [ File.Read, File.Write ], group = [], others = [] } f))
                            |> label "chmod-600"
                        , attempt name (file (File.checkAccess [ File.Execute ] f)) |> label "access-exec-denied"
                        , FileTestHelp.rawError (File.errorIsPermissionDenied >> boolString) (File.checkAccess [ File.Execute ] f)
                            |> label "access-exec-denied-flag"
                        , attempt name
                            (file
                                (File.changeAccess
                                    { owner = [ File.Read, File.Write, File.Execute ], group = [ File.Read, File.Execute ], others = [] }
                                    f
                                )
                            )
                            |> label "chmod-750"
                        , attempt name (file (File.checkAccess [ File.Execute ] f)) |> label "access-exec-ok"
                        , attempt name
                            (file (File.changeAccess { owner = [ File.Read ], group = [], others = [] } missing))
                            |> label "chmod-missing"
                        , attempt
                            (\m -> String.fromInt (Time.posixToMillis m.lastAccessed) ++ " " ++ String.fromInt (Time.posixToMillis m.lastModified))
                            (file
                                (File.changeTimes
                                    { lastAccessed = Time.millisToPosix 1000000000123
                                    , lastModified = Time.millisToPosix 1500000000999
                                    , resolveLink = True
                                    }
                                    f
                                    |> Task.andThen (File.metadata { resolveLink = True })
                                )
                            )
                            |> label "utimes"
                        , attempt (\m -> String.fromInt (Time.posixToMillis m.lastModified))
                            (file
                                (File.softLink (child dir "link") f
                                    |> Task.andThen
                                        (File.changeTimes
                                            { lastAccessed = Time.millisToPosix 1200000000000
                                            , lastModified = Time.millisToPosix 1200000000000
                                            , resolveLink = False
                                            }
                                        )
                                    |> Task.andThen (File.metadata { resolveLink = False })
                                )
                            )
                            |> label "utimes-nofollow"
                        , attempt name
                            (file
                                (File.metadata { resolveLink = True } f
                                    |> Task.andThen (\m -> File.changeOwner { userID = m.userID, groupID = m.groupID, resolveLink = True } f)
                                )
                            )
                            |> label "chown-self"
                        , attempt name
                            (file
                                (File.metadata { resolveLink = True } f
                                    |> Task.andThen (\m -> File.changeOwner { userID = m.userID, groupID = m.groupID, resolveLink = False } f)
                                )
                            )
                            |> label "lchown-self"
                        , attempt (\_ -> "") (file (File.metadata { resolveLink = True } missing)) |> label "metadata-missing"
                        ]
                )
        )
