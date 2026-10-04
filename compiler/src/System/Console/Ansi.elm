module System.Console.Ansi exposing
    ( Color(..), ColorIntensity(..), ConsoleLayer(..)
    , ConsoleIntensity(..), Underlining(..)
    , SGR(..)
    )

{-| Styled terminal output needs a way to say, as data, how the text that
follows should look, and this module is that vocabulary.

A terminal changes how it draws text when it receives an SGR command. SGR
stands for Select Graphic Rendition: an ANSI escape sequence that sets one
aspect of the text's appearance, such as its colour or whether it is
underlined, for everything written after it. `SGR` is one such command, and
the other types are its parameters.

Only a small subset of SGR is modelled: bold, single underline, six foreground
colours in two shades, and a reset. There is no background colour, no italic,
and no magenta or white. This module holds only the values; it produces no
escape sequences itself.


# Colors

@docs Color, ColorIntensity, ConsoleLayer


# Text Styling

@docs ConsoleIntensity, Underlining


# SGR Commands

@docs SGR

-}


{-| One of the basic ANSI terminal colours. Six of the eight are here; magenta
and white are absent.
-}
type Color
    = Black
    | Red
    | Green
    | Yellow
    | Blue
    | Cyan


{-| Which of a basic colour's two shades is meant: `Dull` is the normal shade
and `Vivid` the bright one.
-}
type ColorIntensity
    = Dull
    | Vivid


{-| The part of the text a colour applies to. Only `Foreground`, the
characters themselves, is modelled; there is no background layer.
-}
type ConsoleLayer
    = Foreground


{-| A style of underline. Only a single underline is modelled.
-}
type Underlining
    = SingleUnderline


{-| A weight for the text. Only bold is modelled.
-}
type ConsoleIntensity
    = BoldIntensity


{-| One SGR command: a change to how the text written after it looks.

`Reset` returns every aspect of the text's appearance to the terminal's
default.

`SetConsoleIntensity` and `SetUnderlining` turn on bold and underline.

`SetColor` gives the text on the named layer the colour in the named shade.

Each of the three setting commands changes one aspect and leaves the others as
they were, so turning a style off again takes a `Reset`.

-}
type SGR
    = Reset
    | SetConsoleIntensity ConsoleIntensity
    | SetUnderlining Underlining
    | SetColor ConsoleLayer ColorIntensity Color
