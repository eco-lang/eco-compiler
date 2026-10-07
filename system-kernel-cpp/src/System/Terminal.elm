module System.Terminal exposing
    ( Configuration, Size, getConfiguration
    , setStdInRawMode, setProcessTitle
    , onResize
    )

{-| This lets you interact with the user's terminal, if an interactive terminal is connected to
this application.

Unlike gren-node's `Terminal` module there is no permission value and no `initialize`: call
[`getConfiguration`](#getConfiguration) to find out whether a terminal is attached, and use the
other functions directly.


## Configuration

@docs Configuration, Size, getConfiguration


## Commands

@docs setStdInRawMode, setProcessTitle


## Subscriptions

@docs onResize

-}

import Task exposing (Task)


{-| The configuration of the attached interactive terminal: the number of colours it supports
as a bit depth (`1` for no colour, `4` for 16 colours, `8` for 256 colours, `24` for true
colour) and its current size in character cells.

The colour depth is guessed from the environment: `NO_COLOR` or `TERM=dumb` give `1`,
`FORCE_COLOR`, `COLORTERM` and a `TERM` ending in `256color` raise it.

-}
type alias Configuration =
    { colorDepth : Int
    , columns : Int
    , rows : Int
    }


{-| Size of a terminal. Handy to know for drawing a text-based UI.
-}
type alias Size =
    { columns : Int
    , rows : Int
    }


{-| Get the configuration of the attached terminal.

`Nothing` is returned if this program is not connected to an interactive terminal, which can
happen in CI setups or when used as part of a Unix pipe.

This replaces gren-node's `Terminal.initialize`; it can be called at any time and as often as
you like.

-}
getConfiguration : Task x (Maybe Configuration)
getConfiguration =
    Debug.todo "Implement System API"


{-| In its default mode, `stdin` only sends data when the user hits the enter key.

If you switch over to raw mode, every keypress will be sent over the stream, and special
combinations like `Ctrl-C` will no longer trigger the interrupt signal.

Enable this when you need full control over how input is handled. The original terminal mode is
restored when the program exits. This does nothing if stdin is not a terminal.

-}
setStdInRawMode : Bool -> Task x ()
setStdInRawMode toggle =
    Debug.todo "Implement System API"


{-| Set the title of the running process. This will usually display in activity monitors or in
the title bar of your terminal emulator.
-}
setProcessTitle : String -> Task x ()
setProcessTitle title =
    Debug.todo "Implement System API"


{-| A subscription that triggers every time the size of the terminal changes, with the new size.
-}
onResize : (Size -> msg) -> Sub msg
onResize toMsg =
    Debug.todo "Implement System API"
