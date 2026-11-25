# Snippad

*The Swiss pocket knife of clipboard managers.*

Snippad is a macOS clipboard manager and snippet pad that lives in the menu bar.
It remembers everything you copy, sorts it into lists, keeps it from being pasted where it does not belong, and gives you your own snippets one click away.

- **History** of everything copied -- text, rich text, images, files -- searchable down to the EXIF data of photos, in the menu bar (⌃⌘V) and in a picker (⇧⌘V).
- **Lists** for copies from different applications, each with its own icon, and **Paste Guard** rules saying which applications they may be pasted into -- and whether only into private browser windows.
- **Snippets** in `.snippad` files: text, rich text, files and images, with passwords, expiry, paste-once, and chains (user name first, then the password).
- **The Snippad Organizer**, one window to edit it all: a text editor with line commands, find and replace, and export; an image editor with shapes, arrows, text, cropping and pixelating that keeps the original; drag and drop between lists; text and QR codes read from images; lists exported as TOML, XML, JSON or YAML.
- **MCP** for agents, which can use all of it.

**Our promise.**
If another clipboard manager has a feature Snippad lacks, you get your money back in full -- Snippad is free, so that is easy.
Then [open an issue](https://github.com/verhas/snippad/issues/new) asking for the feature, and we will add it.

## The clipboard history

The clipboard icon in the menu bar opens the history, newest first.
**⌃⌘V** opens the same menu at the mouse pointer, from any app.
**⇧⌘V** opens a small window with the entries of the [preferred list](#lists), to pick one with the mouse (or the arrow keys and Return); see [The ⇧⌘V window](#the-v-window).
These shortcuts, and ⇧⌘H for the Organizer, are the defaults; each can be changed or switched off under *Settings > General > Shortcuts*.

- **Snippad Organizer…** (⇧⌘H), the first item, opens the [Organizer](#the-organizer).
- Choose an entry to put it back on the clipboard, in all the formats it was copied in.
  Keys **1**–**9** and **0** pick the first ten.
- **Pinned** entries are listed first and stay when the history is cleared or trimmed.
- The first list's entries are in the menu itself; every other list is a submenu under the **Lists** header (see [Lists](#lists)).
- Each list shows its 25 newest entries (*Settings > General > Clipboard history*, 10 to 50).
  A longer list ends in **Show All *n* Entries…**, which opens the [⇧⌘V window](#the-v-window) on that list, to scroll through or search all of it.
- Every entry has its own submenu (the **›**), which opens when you rest the pointer on the entry or press **→**.
  It shows the entry in more detail -- the start of the text or the file paths, where and when it was copied, its list -- and its commands:
  - **Put on Clipboard** -- as when you click the entry.
  - **Paste** -- puts the entry's main form on the clipboard (plain text, rich text, the image, the files) and pastes it into the app in front.
  - **Paste as Rich Text** -- for entries that have rich text: the formatted text only.
  - **Paste as Markdown** -- for rich text: the formatting written as Markdown (headings, bold, italic, strikethrough, code, links, lists), pasted as plain text.
  - **Paste as Text** -- for images whose text has been read (see [Text in images](#text-in-images)): that text, pasted as plain text.
  - **Paste Original** -- every format it was copied in, then pastes.
  - **Pin**, **Rename…**, **Move to List ▸**, **Delete**.
    A renamed entry shows its name instead of its first line, everywhere, and search finds it by its name.
  - **Extract Text** -- for images and image files: reads the text, and the contents of any QR code, into a new text entry (see below).
  - **Add to Snippad ▸** -- for text: adds it as a new snippet to one of the open `.snippad` files.
  - **Share ▸** -- the services that can take the entry: Mail, Messages, AirDrop, Notes, and so on.
  - For copied files, **Copy File Contents**, **Copy Names as Text**, **Copy Paths as Text** and **Show in Finder**.

  The three Paste commands paste for you, which needs the Accessibility permission; without it the entry is just put on the clipboard.
  Whatever form goes on the clipboard, the entry stays the one of record, so its list's Paste Guard rules apply.
  The history menu stays open beside it, so you see what you are about to delete.
  The submenus are made after the menu is on screen, one by one ahead of the pointer (one you open first is made at once), so the menu opens at once however long the history.
  (A right-click menu is not possible here: macOS does not open a second menu while one is tracking.)
  Menus cannot be dragged from or dropped on either, so moving by drag and drop is in the Organizer.
- The entries stand on a faint band of the system accent colour, set apart from the commands; their symbols are drawn in that colour.
- Passwords show as `name: ••••••••`, never their value.
- **Snippets** lists the open `.snippad` files, with their snippets.
- **Record Clipboard History** pauses and resumes recording; below it, how many entries the history holds and what they take on disk.
- **Undo Delete** appears for five minutes after entries were deleted -- from this menu, the Organizer, or by an agent -- and brings them back.
- **Paste Guard** switches the [Paste Guard](#the-paste-guard) on and off.
- **Settings…** (⌘,) opens the [settings window](#settings).

The history is kept in `~/Library/Application Support/Snippad/History`, one binary property list per entry, readable only by you.
There is no database: at startup every file is read into memory, and a change rewrites only its entry's file.
Only [Public](#classification) entries are on disk: Sensitive, Private and Secret ones are kept in memory only, and are gone when Snippad quits.
Text copied as HTML only is turned into formatted text in the background (WebKit does that, and it once kept Snippad waiting for good); until then it shows as plain text.
Not recorded:

- copies larger than 50 MB;
- copies from applications switched off under *Settings > Applications*;
- anything another app marks *concealed* or *transient* according to [nspasteboard.org](http://nspasteboard.org) -- that is how password managers keep passwords out of clipboard histories.

What Snippad itself puts on the clipboard -- a snippet, the next step of a chain, an entry chosen again -- is always recorded, passwords as dots.

Only one Snippad runs at a time: if another copy is already running (say, an installed one and a fresh build), Snippad asks which one to keep, and the other quits.

Snippad has a Dock icon and a menu bar only while one of its windows is open.
Closing the last window leaves it in the menu bar.
**⌘Q only closes the Organizer**, so Snippad keeps recording; to quit, choose **Quit Snippad** in the menu bar menu (it is also in the app menu, without a shortcut).

**Extract Text** adds the new entry at once, with a spinner, and fills it in when the text is read.
It reads the image on this Mac with Apple's Vision framework (nothing is sent anywhere).
The contents of QR codes and other barcodes come first, then the text lines in reading order.
The result is a new text entry in the same list, and it goes on the clipboard.

### The ⇧⌘V window

**⇧⌘V** opens a small window by the mouse pointer with the entries of the preferred list (pinned first), and a search field.
**Show All *n* Entries…** at the end of a list in the menu bar opens the same window on that list.
The app you were in is known from the moment you press ⇧⌘V, and its name is in the window's top right corner.
With the Paste Guard on, entries of lists that may not be pasted into that app are left out, and a line says how many; so whatever is offered can be pasted.
When the preferred list is All Lists, each entry shows its list beside its source application and time.
Click an entry -- or move with the arrow keys and press Return -- and it is chosen just as from the menu bar: put on the clipboard, and pasted into the app you were typing in when **Paste after choosing** is on.
The window does not take the app you were in out of the front; Escape or a click elsewhere closes it.

**Several at once:** ⌘-click entries to mark them (a number shows the order), or ⇧-click to mark a run of them; then Return pastes their texts as one, in that order, a line break between them.
Formatted text stays formatted.
Entries without text (images, files) are left out; entries of two lists that both have Paste Guard rules, or a password with anything else, are not joined.
The joined text is a new entry, of the entries' list -- or, when they come from several, of the one with Paste Guard rules.
Escape clears the marks first, then closes the window.

⇧⌘V is *Paste and Match Style* in many apps, and other clipboard managers use it too.
While the shortcut is on (*Settings > General*), Snippad takes it everywhere; switch it off there if it gets in the way.

### The Organizer

The **Snippad Organizer** is the central place for everything: the history, the lists and their rules, and the `.snippad` files.
**Snippad Organizer…** in the menu bar, or **⇧⌘H** from any app, opens it. (⌘H is macOS's Hide; ⇧⌘H is also Finder's and Safari's Home, so it can be switched off in *Settings > General*.)
Three columns: the sidebar, the entries of the selected list (or of all of them) or the snippets of the selected file, and the selected entry or snippet.

The sidebar has three parts:

- **All Lists** -- every entry.
- **Lists** -- each list, with its icon and the number of entries it holds; a raised hand marks a list with Paste Guard rules.
  The **preferred list** is in bold with a star: it is the one ⇧⌘V shows. All Lists is the preferred list until you choose another (right-click a list, **Make Preferred**).
- **Snippad Files** -- the open `.snippad` files (see [Editing snippets](#editing-snippets)).

The **+** below the sidebar adds a list, creates a `.snippad` file, or opens one.

**Only one kind:** the row above the entries narrows them to text, rich text, links, images, files or colours with one click, together with the search and the list chosen; **⇧⌘F** goes through the kinds that are there. Click the kind again, or **All**, for everything.

**Select several entries** with ⌘-click and ⇧-click.
**Return** (or **Copy Together**) puts their texts on the clipboard as one, a line break between them, as in the [⇧⌘V window](#the-v-window).
**Drag entries onto a list** in the sidebar to move them there -- all the selected ones when you drag one of them; the list lights up while you hover.
**Drag entries onto a Snippad file** in the sidebar to add them to it as snippets, as **Add to Snippad** does; they stay in the history.
**Drag a snippet onto another Snippad file** in the sidebar to copy it there; hold ⌘ while dropping to move it instead.
A copy gets a name of its own if the file already has one like it, and keeps its rules but not its shortcut (only one snippet can have a shortcut) or its chain (chains stay within a file); a moved snippet keeps its shortcut.
The last snippet of a file is only copied, since a file needs one.

**Drag entries and snippets into other apps**, too: text into a text field, rich text into a document, an image into a mail or onto the desktop, copied files into a Finder window (Finder makes copies; the originals stay where they are).
An image arrives as a PNG file named after the entry -- in Finder, in Diptych, in any app that takes a promised file.
From macOS 26 every selected entry, and every file of an entry, arrives as an item of its own; on macOS 15 a drag into another app carries the one entry dragged, and an entry's first file.
A drop is not a paste, so what has paste rules stays inside Snippad -- it still drags onto lists and files, but not into other apps: passwords, entries of lists with Paste Guard rules, and snippets that are pasted once, expire, chain to another or go to such a list.
Entries still shown afterwards (in All Lists, say) stay selected.

**Hold ⌥** and each entry shows the exact time it was copied (`2026-11-11 10:22:03CET`) instead of "3 days ago", and its application becomes a link: a click switches to the application when it runs with a window on screen, and otherwise shows it in its folder in Finder.
With several selected, the right pane and the right-click menu offer Copy Together, Move to List, Pin, Unpin and Delete for all of them.
**Deleting can be undone**: **Undo Delete** in the toolbar, or ⌘Z in the list, brings back what was deleted last -- one entry, several, or a whole Clear Unpinned -- for five minutes. Deleted entries are kept in memory only; after five minutes, or when Snippad quits, they are gone.
The search field finds text, file paths, snippet names, source applications, and the **EXIF, TIFF, GPS and IPTC metadata** of copied images and of copied image files: search for a camera model, a lens, or a date.

The toolbar acts on the selected entry:

| Button               | What it does                                                                                       |
| -------------------- | -------------------------------------------------------------------------------------------------- |
| **Put on Clipboard** | Puts the whole entry back on the clipboard (also Return). To copy part of a text, select it and press ⌘C. |
| **Edit**             | Switches a text entry between read-only (the default) and editable. A password shows only while it is edited. |
| **Text**             | Find (⌘F), Find and Replace (⌥⌘F), line commands, spaces and case, wrapping, and line numbers: none, absolute, or relative. |
| **Export…**          | Saves the text to a `.txt` file (or `.rtf` for rich text).                                         |
| **Copy Selected Files** | For copied files: a new entry with only the checked files, on the clipboard.                    |
| **Copy File Contents** | For copied files: what the checked files contain, as text or image, one new entry per file.     |
| **Copy as Text**     | For copied files: their names, or their full paths, as text, one per line.                         |
| **Extract Text**     | For images and image files: the text and QR codes in them, as a new text entry.                    |
| **Copy as Markdown** | For rich text: the formatting written as Markdown, on the clipboard as plain text.                 |
| **Rename**           | Gives the entry a name, shown instead of its first line and found by search; an empty name removes it. |
| **Pin**, **List**, **Delete** | Pins the entry, moves it to another list, deletes it.                                     |
| **Recording** / **Paused** | Pauses and resumes recording.                                                                |
| **Undo Delete**      | Shown for five minutes after a deletion: brings the deleted entries back (also ⌘Z in the list).    |
| **Clear Unpinned…**  | After asking, deletes every unpinned entry -- of the list shown, or of all lists. Undo Delete brings them back. |

Right-click the toolbar to show **Icon and Text**, **Icon Only** or **Text Only**, as in other Mac apps; Snippad remembers the choice.

**Convert to Plain Text**, in the **Text** menu of a rich text entry, drops its formatting -- also when you are not editing.
**Make Rich Text**, in the **Text** menu of a plain text entry, does the opposite, so it can be formatted.

**Formatted text is edited with its formatting.**
While a rich text entry (or a rich text snippet) is being edited, a bar above it has:
title, heading, subheading and body text; the font (a few common ones, or **Show Fonts…** for all); smaller and bigger;
**bold**, *italic*, underline and strikethrough (also ⌘B, ⌘I, ⌘U); the text colour and a highlight colour; left, centred, right and justified;
bulleted and numbered lines; a link; and **Clear Formatting**.
Each works on the selection, or on what you type next when nothing is selected, and each can be undone.
macOS's Writing Tools (proofread, rewrite, summarise) work on formatted text too, where Apple Intelligence is available.

**The right-click menu of a list** has **Edit List…**, **Make Preferred**, **Delete List…**, **New List**, and **Export ▸** with **TOML**, **XML**, **JSON** and **YAML**.
An export holds every entry of the list (or of all lists, from All Lists): its date, list, kind, source application, pinned state and label, and its text (with the RTF of rich text), file paths, or image as base64 PNG -- for an edited image also `image_edits`, its original and edits as JSON.
Password values are never exported; such an entry says `password: true` and has no value.

**Editing** is read-only until you switch on **Edit**, so a stray keystroke changes nothing.
Once it is on, every change is kept as you type: there is no Save, and an entry that is on the clipboard changes on the clipboard too.
Undo (⌘Z) works as usual, and so do cut, copy and paste.
The line commands:

| Keys                                   | What they do                          |
| -------------------------------------- | ------------------------------------- |
| **⇧⌘↑** / **⇧⌘↓**, **⌥⇧↑** / **⌥⇧↓** (IntelliJ), **⌥⌘[** / **⌥⌘]** (Xcode) | Move the selected lines up / down |
| **⇧⌘D**                                | Duplicate the selected lines          |
| **⌘⌫**, **⇧⌘K**                        | Delete the selected lines             |

The **Text** menu also has **Strip Spaces at Line Starts**, **Strip Spaces at Line Ends**, **Trim Lines (Both Ends)**, **Make Lower Case**, **Make Upper Case** and **Remove Empty Lines**.
Each works on the selection, or on the whole text when nothing is selected; the space commands work line by line.
**Wrap Lines** switches between wrapping long lines and scrolling sideways, when viewing and when editing.
Rich text stays rich; plain text is shown in a monospaced font.

**Copying part of an entry stays in its list.**
Select some of an entry's text and press ⌘C (or ⌘X): the copy becomes a new entry of the same list as the entry, so the list's Paste Guard rules apply to it as well -- copying a part is no way around them.
A part of a password is a password.
The same holds for a snippet's value: copied from the editor, it goes to the snippet's list.
An edited entry shows a pencil in the list.

**Copy File Contents** puts an image file on the clipboard as an image and any file that reads as text (plain text, source code, Markdown, RTF, …) as text.
Anything else -- a PDF, an archive, a program -- cannot go on the clipboard that way, and Snippad says which files it skipped and why; the others are still copied.

**Files that no longer exist.**
An entry of copied files whose files have all been deleted or moved (to the Trash, for example) is shown greyed out, in the menu bar and in the Organizer.
Clicking it does nothing, and Put on Clipboard, Copy File Contents and Show in Finder are disabled: there is nothing left to paste.
Copy Names as Text and Copy Paths as Text still work, and so do Pin, Move to List and Delete.
When only some of the files are gone, those are greyed out in the file list and cannot be checked; the rest work as usual.

### Editing images

An image entry -- and an image snippet -- has an **Edit** button too. It opens the image editor:

- **Shapes**: rectangle, oval, circle, triangle, polygon and freehand, outlined or filled; **text**, with an optional background.
  A polygon is clicked corner by corner: double-click, press Return or click the first corner to finish.
- **Lines and arrows**: straight, polyline (clicked point by point) or freehand.
  Each end gets its own head: none, arrow, hollow arrow, open arrow, dot, circle, bar, square, hollow square, diamond or hollow diamond.
  With no head at either end it is a plain line.
- Shapes, lines and texts each have their colour, line width, line style (solid, short dashes, long dashes, dotted, dash-dot) and size.
- **Numbered markers**: click with the marker tool, or drag the marker from the editor's bar onto the picture; each new one gets the next number (1, 2, 3, …).
  A marker is a filled circle by default, or a rounded square, square, diamond, hexagon, map pin, cloud or speech bubble, in any colour; the number is white or black, whichever reads better.
  The marker shape menu shows the shapes in the markers' colour.
  The next number can be set, and each marker's number changed.
  A new marker takes the size of the last one placed or resized: resize the first one, and the rest come out the same.
- **Move, Resize and Turn**: click anything added to select it: a box with handles shows round it.
  Drag the object to move it, a corner to resize it, the round handle above it to turn it (with Shift, in steps of 15°); arrow keys nudge it, Delete removes it.
  ⌥-click selects the object behind the selected one.
- **Several objects**: ⌘-click (or ⇧-click) adds an object to the selection or takes it out; dragging a rectangle from an empty spot with the pointer selects everything it touches; ⌘A selects all.
  Selected together, they are moved, nudged, turned, copied, cut, pasted, duplicated and removed together.
  A style control works on them when they all have what it sets -- the colour of shapes and lines, the line width of both -- and is greyed out otherwise.
- **Edit Points**: double-click a line or shape (or use the Edit Points button) to drag its points one by one instead; double-click again or press Escape to go back to the box.
  Moving a corner of a rectangle or triangle makes it a polygon, a point of an oval a freehand shape.
  Polylines and freehand lines differ only in how they run between their points: straight or smooth.
- A line made straight keeps its points, unused; made a polyline or freehand again, it gets them back, fitted between its ends. A polygon made a rectangle keeps its corners the same way.
- **Cut, Copy, Paste and Duplicate** (⌘X, ⌘C, ⌘V, ⌘D) work on objects: they paste into the same picture or into another image's editor, and as a picture into other apps.
  With an area selected, Copy puts that part of the picture on the clipboard as it looks, with everything drawn on it; Cut copies it, then deletes it.
  Copies go into the history list named in Settings ▸ General ▸ Image editor, or only onto the clipboard.
- **Objects**: a list beside the picture shows everything added, the topmost first.
  Click one to select it, also when it is hidden behind another; ⌘-click selects more, ⇧-click a range.
  Drag them, or use the buttons below the list or its context menu, to bring the selected ones forward or send them back.
- **Select an Area** -- a rectangle, oval, circle, triangle, polygon or freehand -- and then **Delete** it (it becomes transparent), **Crop** to it, or give it an **Effect**:
  - *Hide*: Mosaic (4-pixel blocks to begin with), Hexagon Mosaic, Crystallize, Pointillize, Blur -- each with its size;
  - *Distort*: Swirl, Vortex, Bulge, Pinch, Hole, Kaleidoscope, Light Tunnel -- each with its strength;
  - *Colors*: Invert Colors, Black & White, Sepia, Posterize, Comic, Edges, Thermal, X-Ray.
  An effect stays an object too: select it to move or resize its area, or to change the effect, its size or strength.
- **Grid**: show a grid of any size, snap to it, and snap to the edges and centres of the other objects, of the image and of the crop (a pink line shows what lined up).
  Each is one click in the toolbar: the grid on or off, its size (type it, or step through 2, 4, 5, 8, 10, 15, 16, 20, 25 … 1000 px), snapping to the grid, snapping to objects.
  Hold ⌘ while dragging to snap to nothing. These settings are remembered.
- **Zoom**: the buttons at the bottom left zoom out and in, to 1:1 (one pixel of the image on one pixel of the screen) and to fit; the percentage is a menu of sizes.
  Also ⌘+ and ⌘−, ⌘0 for 1:1 and ⌘9 to fit, ⌘- or ⌥-scrolling, pinching, and a double tap with two fingers (1:1 there, or back to fit). Everything can be edited zoomed in; past 1:1 the pixels show sharp.
  Zoomed in, the picture scrolls: up and down, sideways with Shift, two fingers on the trackpad in any direction. The hand tool, Space held down, or the middle mouse button grab the picture to move it; dragging an object past the edge scrolls along.
- **Crop**: drag the part to keep. The rest stays visible, dimmed, while you edit.
- **Paste** (⌘V) puts the image or text on the clipboard into the picture, as an object of its own.
- **Undo** and **Redo** (⌘Z, ⇧⌘Z), and **Revert**: remove the crop, everything added, or both.

The controls keep their places: what does not apply to the tool or the selected object is greyed out, not hidden.

Nothing is painted into the image for good.
Snippad keeps the original image, every shape, text, pasted image and effect as an object, and the crop; the result -- what is pasted -- is drawn from them.
So an edit can be changed or removed at any time later, and a crop undone.
All of it is saved with the history entry, in exports (`image_edits`), and in the `.snippad` file (`edits`).

### Lists

The history can be divided into lists: say *Clipboard* for everything, *Work*, and *Private*.
Every entry belongs to one list.

Lists are set up in the Organizer, not in the settings:

- **Add** one with the **+** below the sidebar.
- **Right-click** a list for **Edit List…**, **Make Preferred**, **Delete List…**, **New List** and **Export ▸**.
  **Edit List…** opens the list in the right pane: its name, an **icon** to pick, whether it is the preferred list, which applications' copies go to it (**Choose Applications…** shows every application with a tick for those whose copies go to this list; tick or untick them there -- the same setting as the List column of *Settings > Applications*, from the list's side), whether it **collects every copy made in a private browser window**, and its [Paste Guard](#the-paste-guard) rules.
- **Private browser windows.** One list -- at most -- collects whatever you copy in a private (incognito) window, whichever list the browser's other copies go to. Switching it on for one list switches it off for the one that had it. That list shows a **lock** in the sidebar.
- In the sidebar the preferred list has a green star, a list with Paste Guard rules a raised hand, and the private-window list a lock.
- **Deleting** a list asks what happens to its entries: move them to another list, or delete them.
  The first list cannot be deleted.

- Copies from an application go to the list chosen for it under *Settings > Applications*; the rest go to the first list.
- A snippet names the list its copies go to (*Copies go to the list* in the snippet editor); the default is the first list, *Clipboard*.
- To move entries: drag them onto a list in the Organizer, or use **Move to List** -- in the Organizer's toolbar or right-click menu, or an entry's submenu in the menu bar's history.
- Each list keeps its own number of unpinned entries.

### Screenshots

**Take Screenshot ▸** in the menu bar menu:

| Command                  | What it takes                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------- |
| **Screen**               | A whole screen; with several screens, a submenu names them -- an iPad used as a Sidecar display is one of them. |
| **Screen in 10 Seconds** | The same after a delay, counted down beside the menu bar icon; the menu offers to cancel meanwhile. The delay is 10, 20, 30 or 60 seconds (*Settings > General*). |
| **Window**               | The pointer becomes a camera: click a window. Without its shadow.                                 |
| **Window with Shadow**   | The same, with the window's shadow.                                                               |
| **Area**                 | Drag a rectangle; Escape cancels.                                                                 |

The picture goes on the clipboard, and into the screenshot list as an image entry: the first list, *Clipboard*, unless you choose another -- in *Settings > General*, or **Screenshots go to this list** when editing a list, which then shows a camera in the sidebar.
An iPhone cannot be an extra screen of the Mac; to capture it, use **Window** on the *iPhone Mirroring* window.

### Copies from iPhone, iPad and other Macs

What you copy on another device signed in to the same Apple Account arrives through Universal Clipboard.
macOS marks such a copy as coming from another device, but not which one, so Snippad shows it as from *iPhone or iPad* (when an iPhone or iPad app made it) or *Another device*, never as from the Mac app that happened to be in front.

**One list for all your devices.**
The first time a copy arrives from another device, Snippad asks for the name of a list for them -- suggesting *iPhone & iPad* -- and creates it; from then on every copy from any of your devices goes there, with its own icon and the list's Paste Guard rules.
Choose **Keep With Other Copies** instead to opt out; you can opt in again any time in *Settings > General*, or with **Collects every copy from iPhone, iPad and other Macs** when editing a list.

**Pasting right away.**
A Universal Clipboard copy is only a promise on the Mac: macOS fetches it from the device when you paste, and only for a short time.
So Snippad puts the copy it recorded back on the clipboard as the Mac's own, and ⌘V pastes it at once and later too.
To leave such copies as they come, switch off **Put them on the Mac's clipboard right away** in *Settings > General*.

### Passwords

In the snippet editor, check **Password** for a snippet whose value is secret.
Its value is then shown as `••••••••` everywhere -- in the menu bar, the ⇧⌘V window, the Organizer's lists and its view pane, the snippet list, tooltips -- concealed from other clipboard managers, and never returned by the MCP tools.
There are two ways to see it: the eye in the snippet editor, and **Edit** on its entry in the Organizer.
Only snippets can be passwords: nothing copied elsewhere is treated as one.
A password entry in the history is Secret, so it is never written to your history folder: it lives in memory until Snippad quits. The snippet itself stays in its `.snippad` file.

### The Paste Guard

The Paste Guard stops pastes that should not happen, such as pasting a URL from a private browsing session into a normal browser window.
It is off until you switch it on (*Settings > Paste Guard*, or the menu bar).

Each list says where its entries may be pasted (right-click it in the Organizer's sidebar, **Edit List…**):

- **Any application**, **only these applications** (an allow list), or **any application except these** (a deny list);
- and, separately, **in web browsers, only into private windows**.
  With an allow list, the browser has to be on it as well; with a deny list, it must not be on it -- otherwise nothing from the list reaches it, private window or not.

When you type ⌘V, Snippad looks at which list the clipboard's content belongs to -- also when that content was not recorded -- and at the application in front.
If the list does not allow it, the ⌘V is stopped, the Mac beeps, and a note by the mouse pointer says why.
To do this Snippad holds a [keyboard tap](#the-keyboard-tap), but only while the clipboard holds something from a restricted list.

How Snippad tells a private window:

| Browser                                         | How                                                                 |
| ----------------------------------------------- | ------------------------------------------------------------------- |
| Chrome, Brave, Edge, Vivaldi, Chromium           | Asks the browser through AppleScript; macOS asks you once per browser (*Automation*). |
| Firefox, Firefox Developer Edition, Nightly, LibreWolf, Waterfox, Zen | Reads "Private Browsing" in the window title (Accessibility). |
| Tor Browser                                     | Always private.                                                     |
| Safari, Arc, and other browsers                 | Cannot tell, so they count as **not** private: a private-only list is never pasted into them. |

Only ⌘V (with or without ⇧ and ⌥) is checked.
Paste from an Edit menu, a context menu, or drag and drop is not.

### Text in images

Snippad reads the text of every image you copy, in the background, one image at a time, on your Mac with Apple's Vision framework (the engine behind Live Text): no download, no network.
When it is done the entry has **Paste as Text** in its submenu, and the text counts for its [classification](#classification).
An edited image is read again; so is every image when the languages change.
It reads in the Mac's preferred languages that Vision knows (*System Settings > General > Language & Region*); Vision guessing the language instead reads some screenshots of English as Chinese.
Hungarian, for one, is not among them: Hungarian text is read as English, and its accented letters may lose their accents.
Both are switches in *Settings > General > Text in images*; **Extract Text** works either way.

### Classification

Every entry is classified in the background, newest first:

| Category      | What                                                                                     | Colour |
| ------------- | ---------------------------------------------------------------------------------------- | ------ |
| **Public**    | everything else: code, documentation, ordinary text, links                               | green  |
| **Sensitive** | personal data: names with contact details, addresses, phone numbers, account and card numbers, ID numbers | orange |
| **Private**   | rude words, insults, sexual content -- what a censored language model refuses             | purple |
| **Secret**    | passwords, API keys, tokens, private keys, recovery codes                                 | red    |

Rules come first: keys and tokens of known shapes, private keys and `password:` lines are Secret; IBANs and card numbers whose check digits are right, Hungarian account numbers, postal addresses and phone numbers are Sensitive.
Then Apple Intelligence -- the model on your Mac, never Private Cloud Compute -- reads the entry (an image: the text read from it); when the two differ, the more careful category stands.
A text the model refuses to handle is Private.
Without Apple Intelligence (macOS 26 or later, switched on in *System Settings*) only the rules classify, and nothing becomes Private; entries are classified again once it is there.
Password snippets are Secret from the start. Files, colours and other data are not classified.

**Snippets** have a classification of their own, set in the snippet editor and kept in the `.snippad` file (`classification`).
Copied, a snippet's history entry is at least that: a Sensitive snippet asks before it is pasted and its copies stay off the disk, like any Sensitive entry.
**Add to Snippad** -- and dropping entries on a file in the sidebar -- gives the new snippet the entry's category; copying or moving a snippet to another file takes it along.

**Copied from an entry.**
What is made from an entry -- a part copied with ⌘C in the Organizer, its text (**Extract Text**), its file names or paths, objects copied in the image editor, several entries copied together -- inherits the category of what it was made from: it is classified on its own as well, and the more careful of the two stands.
A Public entry passes nothing on. The tooltip and the paste question say when an entry counts as more because of where it came from.

**On disk.**
Only Public entries are written to disk.
A Sensitive, Private or Secret entry lives in memory only and is gone when Snippad quits; when an entry becomes one -- classified, set by you, or from an application made Never Public -- its file is deleted at once, and set back to Public it is written again.
While classifying is on, a new entry is written once it is classified, about a second after the copy, so what turns out Sensitive never touches the disk; were Snippad to quit within that second, the entry would be lost.
An entry already on disk that is not classified yet is left there until it is.

**Never Public.**
What is copied in a private browser window (where Snippad can tell, see the [Paste Guard](#the-paste-guard)), or from an application switched to **Never Public** in *Settings > Applications* -- a chat app, IRC -- is classified like anything else, but a Public result counts as Private; Sensitive and Secret stay what they are.
Until it is classified, such an entry counts as Private.
The setting applies at once, to what was copied from the application before as well.

In the Organizer the icon of an entry has its category's colour (a picture or a file icon gets a dot); its tooltip says whether rules, Apple Intelligence or you decided.
**Right-click › Classification** sets it yourself, for one entry or several; **Automatic** gives it back to Snippad.

**Asking before pasting.**
For each category, *Settings > General > Classification* can make pasting and exporting ask first -- on for Sensitive, Private and Secret, off for Public.
A ⌘V of such an entry, or Paste from Snippad's menus, opens a question with four answers: **Paste**, **Don't Paste** (Escape), **Don't Paste, and Delete It**, and **Paste, and Delete It**.
Deleting takes the entry off the clipboard and out of the history; **Undo Delete** brings it back for five minutes.
A copy made a moment ago that is not classified yet is judged by the rules alone.
**Exporting.**
The same categories ask before they are exported.
**Export…** of one entry asks as pasting does: **Export**, **Don't Export**, **Don't Export, and Delete It**, **Export, and Delete It** (deleted once the file is written).
Exporting a list (TOML, XML, JSON, YAML) says how many of its entries are of which category, and offers **Export Without Them**, **Export All** or **Don't Export**.

**Paste Without Asking**, per application in *Settings > Applications*, lets chosen categories into that application without the question -- each on its own: letting Private into a chat app does not let Secret in.
In other apps this needs the [keyboard tap](#the-keyboard-tap), held only while such an entry is on the clipboard.
Classifying, too, can be switched off; categories you set yourself still count.

## Settings

**Settings…** opens a window with three tabs:

- **General** -- first, the main switch, **Record Clipboard History**; then:
  - how many unpinned entries each list keeps, and how old they may get (a day to a year, or no limit) -- Snippad asks before an age limit deletes entries at once; pinned entries are always kept;
  - what the history takes on disk, with **Show in Finder**;
  - how many entries of each list the menu bar menu shows (25 by default), before **Show All *n* Entries…**;
  - *Paste after choosing*;
  - **Shortcuts**: the history menu (⌃⌘V), the picker (⇧⌘V) and the Organizer (⇧⌘H), each on or off, and changed by clicking it and pressing the new keys (**Default** brings the original back); a clash with another of them, or with a snippet's shortcut, or keys macOS would not give Snippad, is pointed out;
  - **Sounds**: one of macOS's alert sounds when Snippad puts something on the clipboard (and, if you like, when you copy in another app), and one when it pastes for you; none by default;
  - [text in images](#text-in-images) and [classification](#classification), with asking before pasting each category;
  - [screenshots](#screenshots), [copies from other devices](#copies-from-iphone-ipad-and-other-macs), *Open Snippad at login*, the permissions, and the MCP setup command.
- **Applications** -- every installed application and every application something was copied from, with how many copies it made.
  Switch **Record** off to keep an application's copies out of the history; pick the **List** its copies go to.
- **Paste Guard** -- switch it on, and what it can and cannot do.
  The rules belong to the lists, which are edited in the Organizer; a button there takes you to them.

**Applications that are gone.**
After the scan at every launch, Snippad looks for each application in `apps.json` where it was, and then wherever macOS knows it to be.
One that is nowhere to be found is removed from `apps.json` -- unless a setting names it (copies not recorded, a list of its own, or a list's Paste Guard rules).
Then it stays, shown greyed out as **Not found** under *Settings > Applications*, with **Locate…** to say where it is now (it must be the same application, by bundle identifier) and **Remove** to forget it together with every setting that names it.
**Only not found** lists just those.

Settings are saved as you change them, to `~/.snippad/settings.json`.
Next to it, `~/.snippad/apps.json` lists the applications Snippad knows: the installed ones, found at every launch, and every one a copy came from, with the number of copies and the first and last copy.
Both are plain JSON.
Edit them only while Snippad is not running, since it rewrites them; keys left out of `settings.json` take their default.

The Organizer's line numbers, wrapping, toolbar style and preferred list are settings too (`lineNumbers`, `wordWrap`, `toolbarDisplayMode`, `preferredList`), and so are the `.snippad` files open from outside `~/.snippad` (`openSnippadFiles`) and the button windows open when Snippad last quit (`openWindows`), which open again at launch.

## Startup

Snippad starts in one of four ways:

- **At login**, if *Open Snippad at login* is on (*Settings > General*).
  This registers Snippad with macOS as a login item, the same as adding it under *System Settings > General > Login Items*; macOS may ask you to approve it there, and Settings shows a button for that.
  Switching it off removes the login item.
- **When you open a `.snippad` file**, from Finder or any other app.
- **When an agent starts its MCP server** (`Snippad --mcp`) and Snippad is not running: the bridge starts the app in the background and waits for it.
- **By hand**, from Applications or Launchpad.

However it starts, the same happens, without a window:

1. The clipboard icon appears in the menu bar and ⌃⌘V is registered.
2. The history is loaded, and entries saved before image metadata was kept get theirs.
3. The clipboard is watched from then on: what was on it before is not recorded.
4. No keyboard tap is installed: one comes only with a restricted value on the clipboard (see [The keyboard tap](#the-keyboard-tap)).
5. The MCP socket opens.
6. The application folders (`/Applications`, `/System/Applications`, `/System/Library/CoreServices`, `~/Applications`) are scanned in the background, applications that are gone are forgotten or marked *Not found*, and `~/.snippad/apps.json` is updated.
7. Snippad makes sure it is the default app for `.snippad` files (see below).

When Snippad quits, it takes a paste-once, chained, or expiring value off the clipboard, so a password is not left there with nothing to remove it.

## Permissions

Snippad needs no permission to record the clipboard, show the menu, or run the MCP server.
Some features need more:

- **Accessibility** -- for paste-once, chains, the Paste Guard, *Paste after choosing*, and telling a private Firefox window.
  Snippad asks for it only when you click **Allow…** in Settings, the ⚠︎ item in the menu, or switch on a feature that needs it.
  macOS describes this permission as letting an app control the computer; Snippad uses it only to see ⌘V (and to stop it when the Paste Guard says so), to type ⌘V for *Paste after choosing*, and to read the front browser window's title.
  Without it everything else works.
- **Automation** -- asked for by macOS the first time the Paste Guard needs to know whether a Chrome, Brave, Edge or Vivaldi window is private.
- **Screen Recording** -- for **Take Screenshot**; macOS asks the first time, and Snippad points to the setting when it is missing.

### The keyboard tap

Seeing ⌘V in other apps takes a *keyboard event tap*, the same mechanism keyloggers use, and security software may report an app holding one as intercepting keystrokes.
So Snippad installs its tap only while something needs it:

| Installed while…                                   | Removed when…                                                        |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| the Paste Guard is on **and** the clipboard holds something from a restricted list | something from an unrestricted list is copied, the entry is moved to an unrestricted list, the list's restrictions are removed, or the Paste Guard is switched off |
| a paste-once or chained value waits on the clipboard | the last step is pasted, it expires, the clipboard is cleared, or anything else is copied |
| the clipboard holds an entry of a category pasting asks about (Sensitive, Private and Secret by default) | something of another category is copied, the entry is classified or set otherwise, or asking is switched off for it |

A list is *restricted* when it allows only some applications, denies at least one, or is for private browser windows only.
"Something from a list" includes copies that were not recorded -- from an excluded application, or marked concealed -- since the source application's list still applies to them.

The rest of the time no tap exists: with the Paste Guard on but only unrestricted content on the clipboard, plain history, snippets, expiry and MCP, Snippad holds no keyboard tap.

Snippad notices a new copy by looking at the clipboard every half second, or every 0.15 seconds while the Paste Guard is on, and installs the tap at that moment.
A ⌘V typed within that fraction of a second after copying from a restricted source can therefore slip through unchecked.
Granting Accessibility installs nothing by itself: the permission is given once, in System Settings, with your password or Touch ID, and after that Snippad adds and removes the tap without asking again.
The permission itself stays listed under *Privacy & Security > Accessibility* until you switch it off there; a check that looks for apps holding the permission sees Snippad, one that looks for keyboard taps sees one only while the table above says so.

The menu shows **⌨︎ Watching ⌘V for …** while the tap is installed, and *Settings* shows its state under **Keyboard tap**.
The tap looks at every key press -- macOS offers no narrower one -- but acts on ⌘V only and keeps nothing.
macOS ties these permissions to the app's signature.
Debug builds are signed with an *Apple Development* certificate, so a rebuild keeps them; an ad-hoc-signed build would count as a new app every time, and System Settings would go on showing a stale, switched-on "Snippad" that no longer applies.
If the permissions ever seem granted but do not work, reset them and allow again:

```sh
tccutil reset Accessibility dev.verhas.Snippad
```

## Using it

Every `.snippad` file in `~/.snippad` is open whenever Snippad runs: it is listed under **Snippad Files** in the Organizer's sidebar, and its snippets are in the menu bar's **Snippets** menu.
Double-click a `.snippad` file elsewhere in Finder (or better in Diptych), or use **File > Open…** (⌘O), **File > Open Recent** or the menu bar's **Open .snippad File…**, and it joins them, shown in the Organizer.
It stays listed -- also after Snippad restarts -- until you close it with the **eject** button beside it.
Files in `~/.snippad` have no eject button: they are always open.

**Double-click** a file in the sidebar, or right-click it and choose **Open Window**, for its window of buttons, titled with the file name, with one button per snippet.
Closing that window does not close the file.
The windows open when Snippad quits open again when it starts.

- **Click** a button to copy its value.
" Copied “name” " appears briefly at the bottom of the window.
- **Hover** over a button to see the value it copies (dots for a password).
- Small icons on a button show its rules: 🔑 password, ⏲ expires, ① paste once, 🔗 chained.
- **Drag** a button to put it anywhere in the window; it stays there.
- **Drag its bottom right corner** to resize it.
- **Drag its icon** to another corner of the button.
- **Right-click** a button for **Back to Automatic Place** and **Back to Automatic Size**, or an empty spot for **Arrange All Automatically**.
- Open several files at once; each gets its own window.

Every button has a colour -- a random one for a new snippet -- and can have an icon in a corner; both are chosen in the Organizer.
A button is as large as its name needs (one line, or two for a long name) until you resize it.
Buttons you have not moved flow from the top left, row by row, around the ones you placed, and rearrange when the window is resized.

The button window never renames or moves a file -- it has no Save, Rename, or Move To, and the window title is just a title.
It writes only where its buttons are, their sizes and their icons' corners, through the Organizer's editor, so the Organizer shows the change at once.
It reads a file each time the file is opened, and only then.

## Editing snippets

Select a file under **Snippad Files** in the Organizer's sidebar.
The middle column lists its snippets in file order (drag to reorder; **New Snippet** and **−** below add and remove; Return puts one on the clipboard), and the right pane edits the selected one.
Right-click a snippet, or the file in the sidebar, for **New Snippet** too.
**Edit Snippets…** (⌘E) brings you there from a button window.
There you set its name, its value, whether it is a **Password** (hidden until you click the eye), the **list its copies go to** (default *Clipboard*), its **Classification** (a coloured dot in the snippet list; a password counts as Secret), and what happens on the clipboard:

- **Remove from the clipboard after it is pasted once.**
- **Remove from the clipboard after** a time, such as `30s`, `5m` or `1h30m`.
- **Part of a chain. Once pasted, put on the clipboard** another snippet of the file.

Under **Button**: its **colour** (**Random** picks another), an **icon** from a grid of symbols or any SF Symbol by name, the **corner** the icon sits in, and its **Place** and **Size** in the window. Each has an **Automatic** checkbox: on, the button flows after the others and is as large as its name needs; off, it uses the numbers beside it, which a drag in the window sets too.

A snippet holds one of four kinds of value:

| Kind      | Value in the file           | On the clipboard                         | Edited in Snippad |
| --------- | --------------------------- | ---------------------------------------- | ----------------- |
| text      | the text                    | the text                                 | yes               |
| rich      | RTF                         | the formatted text, and its plain text   | yes, with fonts, colours and the rest |
| file      | the path                    | the file itself, as Finder copies it     | path only (Choose Another File…) |
| image     | a PNG, base64-encoded       | the image                                | yes, with the [image editor](#editing-images) |

**New Snippet** below the snippets adds a text snippet; the **…** beside it, and the right-click menu, also offer **New File Snippet…** and **New Image Snippet…**.
**Add to Snippad ▸** on a history entry -- or dragging entries onto a file in the Organizer's sidebar -- turns rich text, copied files (one snippet per file) and images into snippets of their kind.

A text value is edited with the same editor as history entries.
**Maximize** (beside the value, or in the toolbar) lets the value fill the whole pane, with line numbers and the **Text** menu; **Restore** brings the form back.

**Shortcut.**
Give any snippet a system-wide keyboard shortcut: click **Record Shortcut** and press the keys, such as ⌃⌥S.
It needs ⌃, ⌥ or ⌘ (a function key, such as F5, may stand alone); Escape cancels, Delete removes it.
Pressing the shortcut in any app puts the snippet on the clipboard with all its rules -- password, expiry, paste once, chain, list -- and pastes it too when *Paste after choosing* is on.
Pasting for you needs the Accessibility permission for that copy of Snippad; without it, a note by the pointer says the snippet is on the clipboard, ready for ⌘V.
Every snippet of every open file can have one; the editor warns when two snippets, or a snippet and Snippad's own ⌃⌘V or ⇧⌘V, share a shortcut, or when macOS would not give it to Snippad.
The menu bar's **Snippets** menu shows the shortcuts.

There is no Save: like everything in the Organizer, changes are written to the file a moment after you make them.
A change that would make the file unreadable -- a snippet without a name -- is shown at the top of the list and written once it is fixed.
The editor regenerates the file: the comment block at the top survives, other comments and keys Snippad does not know do not.

**File > New Snippad File…** (⌘N), or **+** below the sidebar, asks for a name and creates the file in `~/.snippad`.

### When is something pasted?

macOS does not tell anyone when something is pasted, and reading the clipboard does not count: IDEs, Universal Clipboard and other clipboard managers read every change within a fraction of a second.
So Snippad counts a paste when you type **⌘V** (or ⇧⌘V, ⌥⇧⌘V) while its value is on the clipboard, or when it pastes for you.
To see ⌘V it installs a keyboard tap for as long as the value waits, and removes it afterwards (see [The keyboard tap](#the-keyboard-tap)).
Seeing keystrokes in other apps needs the [Accessibility permission](#permissions); the menu bar icon turns into a warning triangle, and the menu has a line in harsh yellow, **⚠︎ Allow Accessibility so Snippad Sees ⌘V…**, that leads to System Settings, while it is missing.
Paste from an Edit menu or a context menu is not noticed.

Paste-once, chained and password values are marked concealed and transient, so other clipboard managers leave them out of their histories.
Snippad's own history records them, passwords as dots.

## The .snippad file

A `.snippad` file is [TOML](https://toml.io).
Each snippet is a `[[snippet]]`
section with a `name` -- the button's label -- and a `value` -- what the
button copies, and optionally the rules the editor sets:

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

[[snippet]]
name = "user"
value = "alice"
next = "password"     # once pasted, "password" goes on the clipboard

[[snippet]]
name = "password"
value = "hunter2"
once = true           # gone after one paste
expires = "30s"       # gone after 30 seconds anyway
password = true       # hidden in the editor, dots in the history
list = "Private"      # its copies go to the history list "Private"
color = "#FDCFE8"     # the button's colour
icon = "key.fill"     # an SF Symbol in a corner of the button
icon_corner = "top-left"
x = 16                # where the button sits in the window ...
y = 120
width = 160           # ... and its size, in points
height = 48
```

| Key       | Value                                                                                      |
| --------- | ------------------------------------------------------------------------------------------ |
| `expires` | Seconds as a number (`90`), or a duration string: `"45s"`, `"5m"`, `"1h30m"`, `"2d"`.      |
| `once`    | `true` or `false`.                                                                         |
| `password`| `true` or `false`.                                                                         |
| `next`    | The `name` of another snippet in the same file. Each snippet in a chain keeps its own rules. |
| `kind`    | `"text"` (the default), `"rich"` (`value` is RTF), `"file"` (`value` is a path), or `"image"` (`value` is a base64 PNG). |
| `list`    | The name of the history list its copies go to; left out, the first list (*Clipboard*).     |
| `classification` | `"public"`, `"sensitive"`, `"private"` or `"secret"`: copied, its history entry is at least that (see [Classification](#classification)). Left out: not set, and a copy is classified as any other. |
| `shortcut`| A system-wide shortcut that copies it, such as `"ctrl+opt+s"` or `"f5"`: `ctrl`, `opt`, `shift`, `cmd` and a key, joined by `+`. |
| `color`   | The button's colour, `"#RRGGBB"`. Left out, a colour picked from the name, the same every time; Snippad writes it when it saves the file. |
| `icon`    | An SF Symbol name, such as `"star.fill"`, shown in a corner of the button.                |
| `icon_corner` | `"top-left"`, `"top-right"` (the default), `"bottom-left"` or `"bottom-right"`.          |
| `x`, `y`  | Whole points from the window's top left, both or neither. Left out, the button flows after the others. |
| `width`, `height` | Whole points, at least 40 × 24, both or neither. Left out, as large as the name needs. |
| `edits`   | Image snippets only, written by Snippad: the original image and everything added to it, as JSON, so the edits stay changeable. `value` is the result. |

Buttons without `x` and `y` appear in the order the snippets are in the file.
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
be strings, whole numbers or booleans: floats, dates, arrays, inline tables and dotted keys are not read.

If a file cannot be read, its window says why and on which line, for example
`Line 7: this [[snippet]] has no value`.
Fix the file and open it again.

## MCP for agents

Snippad is an MCP server.
The running app listens on a socket in `~/Library/Application Support/Snippad`, readable only by you; agents start the app's executable with `--mcp`, which speaks MCP over stdio and relays to it (starting Snippad first if it is not running).
For Claude Code:

```sh
claude mcp add -s user snippad -- /Applications/Snippad.app/Contents/MacOS/Snippad --mcp
```

*Settings > General > Copy Setup Command* puts this command, with the path of the running copy, on the clipboard.
`-s user` makes it available in every project; without it, Claude Code adds it to the current project only.

| Tool                     | What it does                                                                     |
| ------------------------ | -------------------------------------------------------------------------------- |
| `clipboard_read`         | What is on the clipboard: text, file paths, or an image. Concealed values are not revealed. |
| `clipboard_write`        | Puts text on the clipboard, with `expires`, `once`, and `then` -- texts that follow one another paste by paste. |
| `clipboard_clear`        | Empties the clipboard.                                                           |
| `history_list`           | Lists the history, with search (EXIF included), kind and list filters, and paging. |
| `history_get`            | One entry's full text, file paths, or image.                                     |
| `history_copy`           | Puts an entry back on the clipboard: every format, its main form, rich text, or Markdown. |
| `history_copy_joined`    | Puts the texts of several entries on the clipboard as one.                       |
| `history_rename`         | Names an entry, or removes its name.                                             |
| `history_undo_delete`    | Brings back the entries deleted last, within five minutes.                       |
| `history_add`            | Adds a text entry without touching the clipboard.                                |
| `history_pin`            | Pins or unpins an entry.                                                         |
| `history_delete`         | Deletes an entry; `history_undo_delete` brings it back.                          |
| `history_clear`          | Clears the history, pinned entries too if asked.                                 |
| `history_settings`       | Reads or sets recording on/off, how many entries are kept and for how long; tells the size on disk. |
| `history_update_text`    | Changes the text of a text entry.                                                |
| `history_move`           | Moves an entry to another list.                                                  |
| `history_copy_files`     | A new entry with some of an entry's files, on the clipboard.                     |
| `history_copy_file_contents` | Puts the contents of an entry's files on the clipboard, as text or images.   |
| `history_copy_file_names` | Puts the names (or, with `paths`, the full paths) of an entry's files on the clipboard as text; works when the files are gone. |
| `lists_get`              | The lists, their Paste Guard rules, and which application goes to which list.    |
| `lists_create`           | Adds a list.                                                                     |
| `lists_delete`           | Deletes a list, moving its entries to another list or deleting them.             |
| `history_extract_text`   | Reads the text and QR codes of an image entry into a new text entry.             |
| `apps_list`              | The known applications, their copy counts, whether they are recorded, their list. |
| `snippad_files`          | The open `.snippad` files: those in `~/.snippad` and those opened from elsewhere. |
| `snippad_read`           | A file's snippets with their rules.                                              |
| `snippad_write`          | Replaces a file's snippets, creating the file if needed.                         |
| `snippad_set_snippet`    | Adds or changes one snippet; a rename carries the chains along.                  |
| `snippad_delete_snippet` | Removes one snippet.                                                             |
| `snippad_copy`           | Puts a snippet on the clipboard with its rules.                                  |
| `snippad_open`           | Shows a file in the Organizer's editor, or as buttons.                      |
| `organizer_state`        | What the Organizer shows: the list or file chosen, the selected entries or snippet, the image open in the image editor -- "the current image". |
| `organizer_show`         | Opens the Organizer on an entry or a snippet, and with `edit_image` its image in the image editor. |
| `image_get`              | An image's size, crop and objects (with ids), and the picture as it looks now.   |
| `image_add`              | Draws on an image: shapes, lines and arrows, texts, numbered markers, effects on areas. |
| `image_change`           | Changes objects: place, size, rotation, colours, line, text, effect, number.     |
| `image_remove`           | Removes objects.                                                                 |
| `image_order`            | Brings objects to the front or back, or one step.                                |
| `image_crop`             | Crops to a rectangle, or removes the crop.                                       |
| `image_revert`           | Removes the crop, the objects, or both.                                          |
| `image_select`           | Selects objects in the open image editor, to show which ones are meant.          |
| `image_undo`             | Undo or redo in the open image editor.                                           |

**Asking an agent to edit an image.**
Ask for "the current image" and the agent finds it with `organizer_state`: the image open in the image editor, or else the image entry or image snippet selected in the Organizer.
The `image_*` tools work like the editor: everything they add stays an object you can move, change or remove afterwards, the original is kept, and the crop can be undone.
Positions are pixels of the original image, from its top left corner.
While the image is open in the editor, their changes show there at once, can be selected, and one ⌘Z takes back each call; otherwise they are saved with the entry or the snippet.
`image_get` returns the picture, so the agent can look at what it drew.

The file tools only write files ending in `.snippad`, and a file is read back before it is written, so they never leave one Snippad cannot open.
Password values are returned as `••••••••`; writing that mask back keeps the stored password.
Bear in mind that an agent with this server can read everything you copied that is not a password or marked concealed.

## Opening .snippad files from Finder/Diptych

Snippad declares the `.snippad` file type and claims it as its own, so file managers know to open those files with it once the app is in `/Applications`.

At every launch, Snippad also checks which app macOS would use for a `.snippad` file.
If it is not Snippad -- because another app was chosen in Finder's *Open With*, or macOS has not noticed Snippad yet -- Snippad registers itself and becomes the default again.
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
Debug builds are signed with an *Apple Development* certificate of team `QG9YK2GAF4`, so macOS keeps Snippad's Accessibility permission across rebuilds.
Without that certificate, build with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` added to the `xcodebuild` command line (ad hoc, no developer account needed) and expect to grant Accessibility again after each rebuild.
Release builds, `dmg` and `notarize` sign with the Developer ID as before.

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
| `Snippad/main.swift`                 | Starts the app, or the MCP stdio bridge with `--mcp`.                      |
|                                      |                                                                            |
| `Snippad/SnippadApp.swift`           | Menus, launch, and files opened from Finder.                               |
|                                      |                                                                            |
| `Snippad/SnippadLibrary.swift`       | The open files (`~/.snippad` and others), their editing models, one button window per file. Dock icon on and off. |
|                                      |                                                                            |
| `Snippad/SnippadParser.swift`        | The TOML reader for snippet files.                                         |
|                                      |                                                                            |
| `Snippad/SnippadWriter.swift`        | Writes snippets back as TOML.                                              |
|                                      |                                                                            |
| `Snippad/SnippadEditor.swift`        | The snippet editor in the Organizer, saved as you type; the Text menu. |
|                                      |                                                                            |
| `Snippad/ListEditor.swift`           | A list's settings: name, icon, sources, Paste Guard rules.                  |
|                                      |                                                                            |
| `Snippad/PickerPanel.swift`          | The ⇧⌘V window, with pasting several entries as one.                       |
|                                      |                                                                            |
| `Snippad/Markdown.swift`             | Formatted text written as Markdown.                                        |
|                                      |                                                                            |
| `Snippad/Sounds.swift`               | The sounds for copying and pasting.                                        |
|                                      |                                                                            |
| `Snippad/OrganizerDrag.swift`        | Dragging entries and snippets into other apps.                             |
|                                      |                                                                            |
| `Snippad/TextRecognition.swift`      | Text and QR codes in images, with Vision; the background reader.           |
| `Snippad/Classification.swift`       | Public, Sensitive, Private, Secret: rules, Apple Intelligence, asking before a paste. |
|                                      |                                                                            |
| `Snippad/ImageEdits.swift`           | An edited image: the original, its layers and crop, and drawing the result. |
|                                      |                                                                            |
| `Snippad/ImageEditor.swift`          | The image editor: tools, styles, undo, and the canvas.                     |
|                                      |                                                                            |
| `Snippad/SnippetBoard.swift`         | The window of buttons.                                                     |
|                                      |                                                                            |
| `Snippad/PasteEngine.swift`          | Writing the clipboard; expiry, paste-once, chains, passwords.              |
|                                      |                                                                            |
| `Snippad/PasteGuard.swift`           | The ⌘V keyboard tap, the Paste Guard, private-window detection.            |
|                                      |                                                                            |
| `Snippad/ClipboardHistory.swift`     | Recording, storing, editing and searching what was copied; image metadata. |
|                                      |                                                                            |
| `Snippad/Settings.swift`             | `~/.snippad/settings.json`, lists, and the application catalog.            |
|                                      |                                                                            |
| `Snippad/SettingsWindow.swift`       | The settings window.                                                       |
|                                      |                                                                            |
| `Snippad/StatusMenu.swift`           | The menu bar item, ⌃⌘V, and Paste After Choosing.                          |
|                                      |                                                                            |
| `Snippad/HotKey.swift`               | The system-wide shortcuts.                                                 |
|                                      |                                                                            |
| `Snippad/SnippetShortcuts.swift`     | Snippets' own system-wide shortcuts, and the key combination type.         |
|                                      |                                                                            |
| `Snippad/RemoteListPrompt.swift`     | The question at the first copy from another device.                        |
|                                      |                                                                            |
| `Snippad/Screenshots.swift`          | Take Screenshot: screens (ScreenCaptureKit), windows and areas (`screencapture`). |
|                                      |                                                                            |
| `Snippad/HistoryWindow.swift`        | The Snippad Organizer window.                                              |
|                                      |                                                                            |
| `Snippad/ListExport.swift`           | Exporting a list as TOML, XML, JSON or YAML.                               |
|                                      |                                                                            |
| `Snippad/TextEditorView.swift`       | The text editor: find and replace, line numbers, line commands, transforms, wrapping, and formatting rich text. |
|                                      |                                                                            |
| `Snippad/MCPServer.swift`            | The socket server in the app and the `--mcp` stdio bridge.                 |
|                                      |                                                                            |
| `Snippad/MCPHandler.swift`           | MCP's JSON-RPC methods and the tools.                                      |
|                                      |                                                                            |
| `Snippad/MCPOrganizerTools.swift`    | The MCP tools for what the Organizer shows, the image editor, and the newer history commands. |
|                                      |                                                                            |
| `Snippad/FileTypeRegistration.swift` | Becoming the default app for `.snippad` at launch.                         |
|                                      |                                                                            |
| `Info.plist`                         | The `.snippad` type declaration, merged with Xcode's generated Info.plist. |
|                                      |                                                                            |
| `SnippadTests/`                      | Unit tests: parser and writer, paste rules, history, lists, settings, Paste Guard, MCP, and that opening re-reads and never writes. |
|                                      |                                                                            |
| `build.sh`                           | Build, test and release helper.                                            |
|                                      |                                                                            |
| `make-icon.swift`                    | Draws the app icon into the asset catalog.                                 |
|                                      |                                                                            |

## License

MIT -- see [LICENSE](LICENSE).


