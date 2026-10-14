# Fetch for macOS

Fetch is a local download utility for direct files, YouTube media, and BitTorrent. Preserve the working engines from DL Manager. The desktop build lives independently in DL Manager App.

## Direction

A native workspace in the tradition of Finder and Activity Monitor: an adaptable sidebar, quiet toolbar, live transfer rows, and an optional file inspector. The transfer itself is the visual focus. Brand expression belongs in the custom blue download icon, not ornamental interface panels.

## Tokens

Use system semantic colors so the entire interface follows the Mac's appearance automatically. Reference light values: canvas #FFFFFF, sidebar #F2F2F7, primary text #1D1D1F, secondary text #636366, accent #007AFF, success #248A3D. Reference dark values: canvas #1E1E1E, sidebar #282828, primary text #F5F5F7, secondary text #A1A1A6, accent #0A84FF, success #30D158. System accessibility settings and accent colors take precedence over these reference values.

Use San Francisco via system font APIs. Titles 24/semibold, transfer names 14/medium, controls and supporting information 13/regular, metrics tabular 13/medium. Standard SwiftUI/AppKit controls supply their native sizes, focus and accessibility behavior.

## Layout

Left alignment throughout. Sidebar 200–240 points; detail expands with the window; inspector approximately 290 points. Minimum main window 820×560. Transfer rows group file identity, textual state, progress, speed and actions. Avoid marketing headings, statistical cards and imaginary sample downloads.

    Sidebar          Toolbar: filter / search / add
    Library          Transfer rows              Inspector
    Files            Identity / progress        Source
    YouTube          Bytes / ETA / controls     Files
    Torrents         Empty state with add       Segments
    Completed        Footer: engine status      Recovery

## Behavior

The main action adds a download in a native sheet. Command-N opens it, Command-F focuses search, Command-comma opens Settings. YouTube resolution and format remain independent. Torrents accept magnets, URLs and a file picker. Native Finder reveal and Save Copy replace browser downloads. System menus, context menus, alerts, keyboard focus and reduced motion must remain usable.

## Brief review

The design database returned a marketing-page pattern and web font pair. Those results do not fit a native utility. Use native controls, San Francisco and semantic colors instead. SwiftUI guidance supports environment-driven presentation and standard dismissal. No appearance override is applied in normal use.
