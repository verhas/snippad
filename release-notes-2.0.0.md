# Snippad 2.0.0

Snippad is now a clipboard manager as well as a snippet pad.
It lives in the menu bar, remembers what you copy, keeps it in lists with rules about where it may be pasted, and lets you edit both the history and your `.snippad` files in one window, the **Snippad Organizer**.
It takes screenshots, edits images without ever losing the original, and collects what you copy on your iPhone, iPad and other Macs.
Agents can use all of it through MCP.

Requires macOS 15 or later.

## Clipboard history

- Records everything you copy -- text, rich text, images, files -- in `~/Library/Application Support/Snippad/History`, readable only by you.
- The menu bar icon (and **⌃⌘V**, anywhere) opens the history; keys **1**–**9** and **0** choose the first ten entries, and pinned entries stay at the top.
- Every entry has a submenu with **Put on Clipboard**, **Paste**, **Paste as Rich Text**, **Paste Original**, **Pin**, **Move to List ▸**, **Extract Text**, **Add to Snippad ▸**, **Share ▸** and **Delete**, plus file commands for copied files (**Copy File Contents**, **Copy Names as Text**, **Copy Paths as Text**, **Show in Finder**).
- **⇧⌘V** opens a small picker with the entries of your preferred list, offering only what may be pasted into the app in front. ⌘-click or ⇧-click several entries there, and Return pastes them as one, a line break between them.
- All three global shortcuts (⌃⌘V, ⇧⌘V, ⇧⌘H) can be changed in *Settings > General > Shortcuts*, or switched off.
- **Paste as Markdown** turns formatted text into Markdown: headings, bold, italic, code, links and lists.
- **Rename** an entry: its name shows instead of its first line, and search finds it.
- **Undo Delete** brings back what was deleted -- one entry, several, or a whole Clear Unpinned -- for five minutes, from the menu bar, the Organizer's toolbar, or ⌘Z.
- Keep the history by number of entries, by age (a day to a year), or both; *Settings* and the menu bar menu show how much it takes on disk.
- Optional sounds when Snippad puts something on the clipboard and when it pastes for you.
- **Extract Text** reads the text and QR codes in an image on your Mac, with Apple's Vision framework, into a new text entry.
- Copied files that have since been deleted or moved are greyed out; their names and paths can still be copied.
- Search covers text, file paths, source applications, and the EXIF, TIFF, GPS and IPTC metadata of copied images.
- Applications can be excluded from recording, and nothing marked concealed or transient (as password managers do) is recorded.

## Copies from iPhone, iPad and other Macs

- What you copy on another device signed in to the same Apple Account arrives through Universal Clipboard and is recorded too.
- It shows as from *iPhone or iPad* or *Another device* -- macOS does not say which one -- never as from the Mac app that happened to be in front.
- The first such copy asks for the name of a list for all your devices (*iPhone & iPad* is suggested), with its own icon and Paste Guard rules. **Keep With Other Copies** opts out; *Settings > General*, or the list's editor, opts in again.
- Snippad puts the recorded copy back on the clipboard as the Mac's own, so ⌘V pastes it at once, and still does after macOS's short Universal Clipboard window has passed. This can be switched off in *Settings > General*.

## Screenshots

- **Take Screenshot ▸** in the menu bar menu takes a whole **Screen** (each one named when there are several, a Sidecar iPad among them), a screen after a delay of 10, 20, 30 or 60 seconds counted down beside the menu bar icon, a **Window** with or without its shadow, or an **Area**.
- The picture goes on the clipboard and into the screenshot list, chosen in *Settings > General* or with **Screenshots go to this list** in a list's editor; that list shows a camera in the sidebar.
- To capture an iPhone, take a **Window** of the *iPhone Mirroring* window.

## The Snippad Organizer

- One window for the history, the lists and the `.snippad` files. **⇧⌘H** opens it from any app, as does **Snippad Organizer…** in the menu bar menu. (⇧⌘H is also Finder's and Safari's Home, so it can be switched off in *Settings > General*.)
- Select several entries and drag them onto a list to move them.
- Text entries are read-only until you click **Edit**; changes are kept as you type.
  The editor has find and replace, absolute or relative line numbers, line wrapping, line commands (**⇧⌘↑/↓**, **⌥⇧↑/↓**, **⇧⌘D**, **⌘⌫**), trimming and case commands, **Convert to Plain Text**, and export to a file.
- Copying part of an entry (⌘C) creates a new entry in the same list, so that list's rules still apply.
- One click narrows the entries to text, rich text, links, images, files or colours (⇧⌘F goes through them).
- Several selected entries are copied as one with Return or **Copy Together**.
- **Formatted text is edited with its formatting**: headings, fonts, sizes, bold, italic, underline, strikethrough, colours, highlight, alignment, lists and links, with ⌘B, ⌘I and ⌘U, and Writing Tools. **Make Rich Text** turns plain text into formatted text; rich text snippets are edited the same way.
- Right-click the toolbar to choose Icon and Text, Icon Only or Text Only.

## Editing images

Images in the history and image snippets have an **Edit** button that opens the image editor.
Nothing is painted into the image for good: the original is kept, everything added stays an object that can be moved, restyled or removed later, and the crop can be undone at any time.
The original, the objects and the crop are saved with the history entry, in list exports (`image_edits`) and in `.snippad` files (`edits`).

**Drawing**

- Shapes: rectangle, oval, circle, triangle, polygon and freehand, outlined or filled; and text, with an optional background.
- Lines are straight, polylines or freehand, with a head of their own at each end: none, arrow (solid, hollow or open), dot, circle, bar, square, hollow square, diamond or hollow diamond.
- Each has its colour, line width, line style (solid, short or long dashes, dotted, dash-dot) and size.
- Numbered markers -- circles by default, or squares, diamonds, hexagons, map pins, clouds or speech bubbles -- count up 1, 2, 3 as you place them, each the size of the last one; the shape menu shows them in the markers' colour.
- Paste images or text into the picture.

**Changing what is drawn**

- Click an object for its box: drag to move it, a corner to resize it, the round handle to turn it (Shift for 15° steps).
- Double-click it, or use **Edit Points**, to drag its points one by one -- a rectangle's corners too, which makes it a polygon.
- A line made straight, or a polygon made a rectangle, keeps its points for when it is switched back.
- Select several objects with ⌘-click, by dragging a rectangle over them, or with ⌘A, to move, turn, copy, remove or restyle them together; a control works on them when they all have what it sets.
- A list beside the picture selects objects hidden behind others (⇧-click for a range, ⌘-click for more) and changes their order, by dragging or with its buttons; ⌥-click on the picture selects what is behind, too.
- **Cut, Copy, Paste and Duplicate** (⌘X, ⌘C, ⌘V, ⌘D) work on objects, also from one image's editor into another's; in other apps they paste as a picture. Copies go to the history list chosen in *Settings > General > Image editor*, or only onto the clipboard.

**Areas and effects**

- Select an area (rectangle, oval, circle, triangle, polygon or freehand) to delete it, crop to it, copy it as it looks (Cut copies it, then deletes it), or apply an effect: mosaic, hexagon mosaic, crystallize, pointillize, blur, swirl, vortex, bulge, pinch, hole, kaleidoscope, light tunnel, invert, black and white, sepia, posterize, comic, edges, thermal or X-ray.
- An effect stays an object too: move or resize its area, or change the effect, its size or strength.

**Working in the editor**

- Zoom in, out, to 1:1 (one image pixel on one screen pixel) and to fit -- with the buttons at the bottom left, ⌘+ ⌘− ⌘0 ⌘9, ⌘-scrolling or pinching -- and edit zoomed in.
- Zoomed in, scroll (sideways with Shift), swipe on the trackpad, or grab the picture with the hand tool, Space or the middle mouse button.
- A grid of any size, with snapping to the grid and to the other objects, each one click away in the toolbar; ⌘ while dragging snaps to nothing.
- Undo and Redo, and Revert: remove the crop, everything added, or both.
- The controls keep their places: what does not apply is greyed out, never hidden.

## Lists and the Paste Guard

- Divide the history into lists, each with its own icon. Every application's copies can go to a list of their own, and one list can collect everything copied in private browser windows.
- Lists are created, edited, deleted (moving or deleting their entries) and exported -- as **TOML**, **XML**, **JSON** or **YAML** -- right in the Organizer. **Choose Applications…** in a list's editor ticks the applications whose copies go to it.
- The **Paste Guard** (off until you switch it on) stops ⌘V when the clipboard's list may not be pasted into the app in front: allow lists, deny lists, and "only into private browser windows" for Chrome, Brave, Edge, Vivaldi, Firefox and Tor Browser.
- It needs a keyboard tap, which Snippad installs only while the clipboard holds something from a restricted list, or while a paste-once or chained value waits, and removes as soon as neither is true.

## Snippets

- `.snippad` files are edited in the Organizer, with no Save: changes are written a moment after you make them.
- Every file in `~/.snippad` is always open; files from elsewhere stay open until you eject them, and their button windows reopen at launch.
- **New Snippet**, below the snippets and in the right-click menu of a snippet or a file, adds text, file and image snippets.
- New per-snippet options:
  - **Password**: shown as dots everywhere, and concealed from other clipboard managers.
  - **Remove after one paste**, and **remove after a time**.
  - **Chains**: once one snippet is pasted, the next goes on the clipboard (user name, then password).
  - **The list** its copies go to.
  - **A system-wide shortcut** (⌃⌥S, F5, …): pressing it in any app puts the snippet on the clipboard with all its rules, and pastes it when *Paste after choosing* is on. The editor warns about shortcuts that clash or that macOS will not give to Snippad; the menu bar's **Snippets** menu shows them.
- Buttons have colours -- a random one for each new snippet -- and an optional icon in a corner.
  In a file's window, drag a button anywhere, drag its corner to resize it, and drag its icon to another corner; Snippad keeps all of it in the file.
- A snippet can hold **rich text**, a **file** (the file itself is copied) or an **image**, as well as plain text; image snippets open in the image editor.
- **Add to Snippad**, or dragging history entries onto a file in the Organizer's sidebar, turns them into snippets.
- Drag a snippet onto another file in the sidebar to copy it there, or with ⌘ held to move it.
- Drag history entries and snippets into other apps: text into text fields, images into documents, copied files into Finder. Passwords, entries of lists with Paste Guard rules, and snippets with paste rules stay inside Snippad.
- New fields in the file: `shortcut` (such as `"ctrl+opt+s"`), `color`, `icon`, `icon_corner`, `x`, `y`, `width`, `height` and, for image snippets, `edits`, written by Snippad.

## For agents

- An MCP server gives agents the clipboard, the history, the lists, the applications and the `.snippad` files; agents can also set a snippet's shortcut, and see which images were edited.
- Agents see what the Organizer shows (`organizer_state`), so you can ask one to "edit the current image": the `image_*` tools draw shapes, arrows, texts, numbered markers and effects, change, reorder and remove them, crop, revert and undo -- live in the open image editor, with the original kept.
- Agents can also rename entries, copy several as one, copy as Markdown, bring back deleted entries, and set the age limit.
- Password values are never revealed to agents.
- Set it up with the command under *Settings > General > Agents (MCP)*.

## Settings and startup

- **⌘Q** closes the Snippad Organizer instead of quitting, so Snippad keeps recording; **Quit Snippad** is in the menu bar menu.
- Only one Snippad runs at a time: when another copy is already running, Snippad asks which one to keep.
- Settings live in a window of their own and are saved to `~/.snippad/settings.json`.
- The applications Snippad knows are kept in `~/.snippad/apps.json`. Applications that disappear are forgotten, or, if a setting names them, shown as *Not found* with **Locate…** and **Remove**.
- **Open Snippad at login** in *Settings > General*.

## Permissions

Snippad asks for a permission only when a feature that needs it is used, and works without it otherwise.

- **Accessibility**: the Paste Guard, paste-once and chained snippets, and pasting for you (from the history, the picker or a snippet's shortcut).
- **Screen Recording**: **Take Screenshot**; macOS asks the first time.
- **Automation**: asked once per Chromium browser, the first time the Paste Guard needs to know whether its window is private.

## Install

Download `Snippad-2.0.0.dmg` below, open it, and drag Snippad to Applications, replacing 1.0 if you have it.
It is signed with a Developer ID and notarized by Apple.

## Upgrading from 1.0

- `.snippad` files from 1.0 open unchanged; their buttons get colours picked from their names, written into the file the next time Snippad saves it.
- Editing now happens in the Organizer: **Edit Snippets…** (⌘E) takes you there from a button window.
- Clipboard recording is on from the first launch; switch off **Record Clipboard History** in *Settings > General* to use Snippad for snippets only.
