# Snippad

*A pad of snippets: one button per text you keep typing, one click to copy it.*

Snippad is a small macOS app that opens `.snippad` files.
Each file holds a
list of named snippets -- an address, a signature, a greeting, a command line -- and Snippad shows them as a window full of buttons.
Click a button and its text is on the clipboard, ready to paste anywhere.

There is nothing else on the screen: no editor, no settings, no menu of options.
The snippets you edit with your editor of choice.

## Using it

Double-click a `.snippad` file in Finder (or better in Diptych).
Snippad opens it in its own window,
titled with the file name, with one button per snippet.
Started without a file, it asks for one; **File > Open…** (⌘O) and **File > Open Recent** do the same later.

- **Click** a button to copy its value.
" Copied “name” " appears briefly at the bottom of the window.
- **Hover** over a button to see the value it copies.
- Open several files at once; each gets its own window.

The window resizes freely, and the buttons rearrange to fill it.

Snippad never writes, renames, or moves a file -- it has no Save, Rename, or Move To, and the window title is just a title.
It reads a file each time the file is opened, and only then.

## The .snippad file

A `.snippad` file is [TOML](https://toml.io).
Each snippet is a `[[snippet]]`
section with a `name` -- the button's label -- and a `value` -- what the
button copies:

```toml
# Each [[snippet]] becomes a button. Click it to copy the value.

[[snippet]]
name = "Email"
value = "you@example.com"

[[snippet]]
name = "Greeting"
value = "Hello,\n\nthanks for reaching out."

[[snippet]]
name = "Signature"
value = """
Best regards,
Your Name"""

[[snippet]]
name = 'Regex: date'
value = '\d{4}-\d{2}-\d{2}'
```

The buttons appear in the order the snippets are in the file.
The same file
is in this repository as [`example.snippad`](example.snippad).

All four TOML string forms work, so pick whichever needs the least escaping:

| Form                                               | Example                                | Notes                                                         |
| -------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------- |
| Basic                                              | `"Hello,\nworld"`                      | Escapes such as `\n`, `\t`, `\"`, `\\`, `\u00E9` are decoded. |
|                                                    |                                        |                                                               |
| Literal                                            | `'C:\Users\me'`                        | Taken exactly as written; no escapes.                         |
|                                                    |                                        |                                                               |
| Multi-line basic                                   | `"""` ...                              |                                                               |
| `"""`                                              | Spans lines; escapes work.             |                                                               |
| A `\` at the end of a line joins it with the next. |                                        |                                                               |
|                                                    |                                        |                                                               |
| Multi-line literal                                 | `'''` ...                              |                                                               |
| `'''`                                              | Spans lines, taken exactly as written. |                                                               |


In both multi-line forms, a line break straight after the opening quotes is
dropped, so the text can start on its own line.

`#` starts a comment.
Other tables and other keys -- for example a `title` at
the top, or a `note` inside a snippet -- are allowed and ignored.
Values must
be strings, though: numbers, booleans, arrays and dotted keys are not read.

If a file cannot be read, its window says why and on which line, for example
`Line 7: this [[snippet]] has no value`.
Fix the file and open it again.

## Opening .snippad files from Finder/Diptych

Snippad declares the `.snippad` file type and claims it as its own, so file managers know to open those files with it once the app is in `/Applications`.

At every launch, Snippad also checks which app macOS would use for a `.snippad` file.
If it is not Snippad -- because another app was chosen in Finder's *Open With*, or macOS has not noticed Snippad yet -- Snippadregisters itself and becomes the default again.
To give `.snippad` files to another app instead, choose it in Finder's *Get Info* and do not launch Snippad afterwards.

## Install

Download the `.dmg` from the
[releases page](https://github.com/verhas/snippad/releases), open it, and drag
Snippad to Applications.
Then double-click any `.snippad` file.

Requires macOS 15 or later.

## Build and run

In Xcode: open `Snippad.xcodeproj` and press ⌘R.

From the terminal:

```sh
./build.sh          # build (Debug)
./build.sh run      # build, quit any running copy, relaunch
./build.sh test     # run the unit tests
./build.sh release  # build optimised
./build.sh clean    # delete build products
./build.sh path     # print the path of the built .app
./build.sh stop     # quit a running instance
```

The script hides xcodebuild's output unless something goes wrong, in which case it prints the compiler diagnostics and exits non-zero.
A local build is signed ad hoc, so it runs without a developer account.

Requires Xcode 26 or later.
There are no package dependencies.

To redraw the app icon after changing `make-icon.swift`:

```sh
swift make-icon.swift
```

## Releasing

```sh
./build.sh version 1.0.1   # bump the version (both build configurations)
# write release-notes-1.0.1.md, starting with "# Snippad 1.0.1"
./build.sh dmg             # Release build, Developer ID signed, packaged
./build.sh notarize        # submit to Apple and staple the ticket
./build.sh publish         # tag and create the GitHub release
```

`notarize` uses the notarytool keychain profile named `Snippad` (override with
`NOTARY_PROFILE`), created once with

```sh
xcrun notarytool store-credentials Snippad --apple-id <Apple ID> --team-id <Team ID>
```

`publish` refuses to run with uncommitted or unpushed changes, or with a
`.dmg` that is not notarized or is older than the source it was built from.

## Project layout

| Path                                 | What it is                                                                 |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `Snippad/SnippadApp.swift`           | App entry point, menus, and files opened from Finder.                      |
|                                      |                                                                            |
| `Snippad/SnippadLibrary.swift`       | One window per file; reads the file on every open.                         |
|                                      |                                                                            |
| `Snippad/SnippadParser.swift`        | The TOML reader for snippet files.                                         |
|                                      |                                                                            |
| `Snippad/SnippetBoard.swift`         | The window of buttons and copying to the clipboard.                        |
|                                      |                                                                            |
| `Snippad/FileTypeRegistration.swift` | Becoming the default app for `.snippad` at launch.                         |
|                                      |                                                                            |
| `Info.plist`                         | The `.snippad` type declaration, merged with Xcode's generated Info.plist. |
|                                      |                                                                            |
| `SnippadTests/`                      | Unit tests: the parser, and that opening re-reads and never writes.        |
|                                      |                                                                            |
| `build.sh`                           | Build, test and release helper.                                            |
|                                      |                                                                            |
| `make-icon.swift`                    | Draws the app icon into the asset catalog.                                 |
|                                      |                                                                            |

## License

MIT -- see [LICENSE](LICENSE).
