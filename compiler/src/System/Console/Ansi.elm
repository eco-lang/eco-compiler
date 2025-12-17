module System.Console.Ansi exposing
    ( Color(..), ColorIntensity(..), ConsoleLayer(..)
    , ConsoleIntensity(..), Underlining(..), BlinkSpeed(..)
    , SGR(..)
    )

{-| ANSI terminal control codes for text styling and coloring.

This module defines types representing ANSI escape sequence parameters for controlling
terminal text appearance. It provides SGR (Select Graphic Rendition) commands that can
be converted to ANSI escape codes for styling terminal output with colors, intensity,
underlining, and other text effects.


# Colors

@docs Color, ColorIntensity, ConsoleLayer


# Text Styling

@docs ConsoleIntensity, Underlining, BlinkSpeed


# SGR Commands

@docs SGR

-}

{-| Standard ANSI terminal colors. -}
type Color
    = Black
    | Red
    | Green
    | Yellow
    | Blue
    | Magenta
    | Cyan
    | White


{-| Intensity of ANSI colors: dull or vivid. -}
type ColorIntensity
    = Dull
    | Vivid


{-| Layer on which to apply colors: foreground (text) or background. -}
type ConsoleLayer
    = Foreground
    | Background


{-| ANSI text blinking speed: most terminals only support NoBlink. -}
type BlinkSpeed
    = SlowBlink
    | RapidBlink
    | NoBlink


{-| ANSI text underlining style. -}
type Underlining
    = SingleUnderline
    | DoubleUnderline
    | NoUnderline


{-| ANSI text intensity affecting font weight and style. -}
type ConsoleIntensity
    = BoldIntensity
    | FaintIntensity
    | NormalIntensity


{-| ANSI Select Graphic Rendition commands for controlling terminal text appearance. -}
type SGR
    = Reset
    | SetConsoleIntensity ConsoleIntensity
    | SetItalicized Bool
    | SetUnderlining Underlining
    | SetBlinkSpeed BlinkSpeed
    | SetVisible Bool
    | SetSwapForegroundBackground Bool
    | SetColor ConsoleLayer ColorIntensity Color
