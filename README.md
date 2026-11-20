# Snippad

*A pad of snippets: one button per text you keep typing, one click to copy it.*

Snippad is a small macOS app that lives in the menu bar.
It does two things:

- It remembers what you copy -- text, rich text, images, files -- and gives it back from a menu.
- It opens `.snippad` files.
  Each file holds a list of named snippets -- an address, a signature, a greeting, a command line -- and Snippad shows them as a window full of buttons.
  Click a button and its text is on the clipboard, ready to paste anywhere.

A snippet can also leave the clipboard after a while, leave it after it was pasted once, or hand over to the next snippet once pasted: user name first, then the password.

Agents can use all of it through MCP.

## The clipboard history

The clipboard icon in the menu bar opens the history, newest first.
**⌃⌘V** opens the same menu at the mouse pointer, from any app.
**⇧⌘V** opens a small window with the entries of the [preferred list](#lists), to pick one with the mouse (or the arrow keys and Return); see [The ⇧⌘V window](#the-v-window).

- **Snippad Organizer…** (⌘H), the first item, opens the [Organizer](#the-organizer).
- Choose an entry to put it back on the clipboard, in all the formats it was copied in.
  Keys **1**–**9** and **0** pick the first ten.
- **Pinned** entries are listed first and stay when the history is cleared or trimmed.
- The first list's entries are in the menu itself; every other list is a submenu (see [Lists](#lists)).
- Every entry has its own submenu (the **›**), which opens when you rest the pointer on the entry or press **→**.
  It shows the entry in more detail -- the start of the text or the file paths, where and when it was copied, its list -- and its commands:
  - **Put on Clipboard** -- as when you click the entry.
  - **Paste** -- puts the entry's main form on the clipboard (plain text, rich text, the image, the files) and pastes it into the app in front.
  - **Paste as Rich Text** -- for entries that have rich text: the formatted text only.
  - **Paste Original** -- every format it was copied in, then pastes.
  - **Pin**, **Move to List ▸**, **Delete**.
  - **Extract Text** -- for images and image files: reads the text, and the contents of any QR code, into a new text entry (see below).
  - **Add to Snippad ▸** -- for text: adds it as a new snippet to one of the open `.snippad` files.
  - **Share ▸** -- the services that can take the entry: Mail, Messages, AirDrop, Notes, and so on.
  - For copied files, **Copy File Contents**, **Copy Names as Text**, **Copy Paths as Text** and **Show in Finder**.

  The three Paste commands paste for you, which needs the Accessibility permission; without it the entry is just put on the clipboard.
  Whatever form goes on the clipboard, the entry stays the one of record, so its list's Paste Guard rules apply.
  The history menu stays open beside it, so you see what you are about to delete.
  (A right-click menu is not possible here: macOS does not open a second menu while one is tracking.)
  Menus cannot be dragged from or dropped on either, so moving by drag and drop is in the Organizer.
- Passwords show as `name: ••••••••`, never their value.
- **Snippets** lists the open `.snippad` files, with their snippets.
- **Record Clipboard History** pauses and resumes recording; **Paste Guard** switches the [Paste Guard](#the-paste-guard) on and off.
- **Settings…** (⌘,) opens the [settings window](#settings).

The history is kept in `~/Library/Application Support/Snippad/History`, one file per entry, readable only by you.
Not recorded:

- copies larger than 50 MB;
- copies from applications switched off under *Settings > Applications*;
- anything another app marks *concealed* or *transient* according to [nspasteboard.org](http://nspasteboard.org) -- that is how password managers keep passwords out of clipboard histories.

What Snippad itself puts on the clipboard -- a snippet, the next step of a chain, an entry chosen again -- is always recorded, passwords as dots.

Snippad has a Dock icon and a menu bar only while one of its windows is open.
Closing the last window leaves it in the menu bar; **Quit Snippad** is in its menu.

**Extract Text** adds the new entry at once, with a spinner, and fills it in when the text is read.
It reads the image on this Mac with Apple's Vision framework (nothing is sent anywhere).
The contents of QR codes and other barcodes come first, then the text lines in reading order.
The result is a new text entry in the same list, and it goes on the clipboard.

### The ⇧⌘V window

**⇧⌘V** opens a small window by the mouse pointer with the entries of the preferred list (pinned first), and a search field.
The app you were in is known from the moment you press ⇧⌘V, and its name is in the window's top right corner.
With the Paste Guard on, entries of lists that may not be pasted into that app are left out, and a line says how many; so whatever is offered can be pasted.
When the preferred list is All Lists, each entry shows its list beside its source application and time.
Click an entry -- or move with the arrow keys and press Return -- and it is chosen just as from the menu bar: put on the clipboard, and pasted into the app you were typing in when **Paste after choosing** is on.
The window does not take the app you were in out of the front; Escape or a click elsewhere closes it.

⇧⌘V is *Paste and Match Style* in many apps, and other clipboard managers use it too.
While the shortcut is on (*Settings > General*), Snippad takes it everywhere; switch it off there if it gets in the way.

### The Organizer

The **Snippad Organizer** is the central place for everything: the history, the lists and their rules, and the `.snippad` files.
**Snippad Organizer…** in the menu bar (⌘H), or ⇧⌘H, opens it.
Three columns: the sidebar, the entries of the selected list (or of all of them) or the snippets of the selected file, and the selected entry or snippet.

The sidebar has three parts:

- **All Lists** -- every entry.
- **Lists** -- each list, with its icon and the number of entries it holds; a raised hand marks a list with Paste Guard rules.
  The **preferred list** is in bold with a star: it is the one ⇧⌘V shows. All Lists is the preferred list until you choose another (right-click a list, **Make Preferred**).
- **Snippad Files** -- the open `.snippad` files (see [Editing snippets](#editing-snippets)).

The **+** below the sidebar adds a list, creates a `.snippad` file, or opens one.

**Select several entries** with ⌘-click and ⇧-click.
**Drag entries onto a list** in the sidebar to move them there -- all the selected ones when you drag one of them; the list lights up while you hover.
Entries still shown afterwards (in All Lists, say) stay selected.
With several selected, the right pane and the right-click menu offer Move to List, Pin, Unpin and Delete for all of them.
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
| **Pin**, **List**, **Delete** | Pins the entry, moves it to another list, deletes it.                                     |
| **Recording** / **Paused** | Pauses and resumes recording.                                                                |
| **Clear Unpinned…**  | After asking, deletes every unpinned entry -- of the list shown, or of all lists.                  |

Right-click the toolbar to show **Icon and Text**, **Icon Only** or **Text Only**, as in other Mac apps; Snippad remembers the choice.

**Convert to Plain Text**, in the **Text** menu of a rich text entry, drops its formatting -- also when you are not editing.

**The right-click menu of a list** has **Edit List…**, **Make Preferred**, **Delete List…**, **New List**, and **Export ▸** with **TOML**, **XML**, **JSON** and **YAML**.
An export holds every entry of the list (or of all lists, from All Lists): its date, list, kind, source application, pinned state and label, and its text (with the RTF of rich text), file paths, or image as base64 PNG.
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

### Lists

The history can be divided into lists: say *Clipboard* for everything, *Work*, and *Private*.
Every entry belongs to one list.

Lists are set up in the Organizer, not in the settings:

- **Add** one with the **+** below the sidebar.
- **Right-click** a list for **Edit List…**, **Make Preferred**, **Delete List…**, **New List** and **Export ▸**.
  **Edit List…** opens the list in the right pane: its name, an **icon** to pick, whether it is the preferred list, which applications' copies go to it (**Choose Applications…** opens *Settings > Applications* showing just those; switch the filter off there to assign others), whether it **collects every copy made in a private browser window**, and its [Paste Guard](#the-paste-guard) rules.
- **Private browser windows.** One list -- at most -- collects whatever you copy in a private (incognito) window, whichever list the browser's other copies go to. Switching it on for one list switches it off for the one that had it. That list shows a **lock** in the sidebar.
- In the sidebar the preferred list has a green star, a list with Paste Guard rules a raised hand, and the private-window list a lock.
- **Deleting** a list asks what happens to its entries: move them to another list, or delete them.
  The first list cannot be deleted.

- Copies from an application go to the list chosen for it under *Settings > Applications*; the rest go to the first list.
- A snippet names the list its copies go to (*Copies go to the list* in the snippet editor); the default is the first list, *Clipboard*.
- To move entries: drag them onto a list in the Organizer, or use **Move to List** -- in the Organizer's toolbar or right-click menu, or an entry's submenu in the menu bar's history.
- Each list keeps its own number of unpinned entries.

### Passwords

In the snippet editor, check **Password** for a snippet whose value is secret.
Its value is then shown as `••••••••` everywhere -- in the menu bar, the ⇧⌘V window, the Organizer's lists and its view pane, the snippet list, tooltips -- concealed from other clipboard managers, and never returned by the MCP tools.
There are two ways to see it: the eye in the snippet editor, and **Edit** on its entry in the Organizer.
Only snippets can be passwords: nothing copied elsewhere is treated as one.
A password entry in the history is still stored on disk in your history folder, as the snippet itself is in its `.snippad` file.

### The Paste Guard

The Paste Guard stops pastes that should not happen, such as pasting a URL from a private browsing session into a normal browser window.
It is off until you switch it on (*Settings > Paste Guard*, or the menu bar).

Each list says where its entries may be pasted (right-click it in the Organizer's sidebar, **Edit List…**):

- **Any application**, **only these applications** (an allow list), or **any application except these** (a deny list);
- and, separately, **in web browsers, only into private windows**.

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

## Settings

**Settings…** opens a window with three tabs:

- **General** -- first, the main switch, **Record Clipboard History**; then how many entries each list keeps, the ⌃⌘V and ⇧⌘V shortcuts, *Paste after choosing*, *Open Snippad at login*, the permissions, and the MCP setup command.
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
Two features need more:

- **Accessibility** -- for paste-once, chains, the Paste Guard, *Paste after choosing*, and telling a private Firefox window.
  Snippad asks for it only when you click **Allow…** in Settings, the ⚠︎ item in the menu, or switch on a feature that needs it.
  macOS describes this permission as letting an app control the computer; Snippad uses it only to see ⌘V (and to stop it when the Paste Guard says so), to type ⌘V for *Paste after choosing*, and to read the front browser window's title.
  Without it everything else works.
- **Automation** -- asked for by macOS the first time the Paste Guard needs to know whether a Chrome, Brave, Edge or Vivaldi window is private.

### The keyboard tap

Seeing ⌘V in other apps takes a *keyboard event tap*, the same mechanism keyloggers use, and security software may report an app holding one as intercepting keystrokes.
So Snippad installs its tap only while something needs it:

| Installed while…                                   | Removed when…                                                        |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| the Paste Guard is on **and** the clipboard holds something from a restricted list | something from an unrestricted list is copied, the entry is moved to an unrestricted list, the list's restrictions are removed, or the Paste Guard is switched off |
| a paste-once or chained value waits on the clipboard | the last step is pasted, it expires, the clipboard is cleared, or anything else is copied |

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

**Right-click** a file in the sidebar and choose **Open Window** for its window of buttons, titled with the file name, with one button per snippet.
Closing that window does not close the file.
The windows open when Snippad quits open again when it starts.

- **Click** a button to copy its value.
" Copied “name” " appears briefly at the bottom of the window.
- **Hover** over a button to see the value it copies (dots for a password).
- Small icons on a button show its rules: 🔑 password, ⏲ expires, ① paste once, 🔗 chained.
- Open several files at once; each gets its own window.

The window resizes freely, and the buttons rearrange to fill it.

The button window never writes, renames, or moves a file -- it has no Save, Rename, or Move To, and the window title is just a title.
It reads a file each time the file is opened, and only then.

## Editing snippets

Select a file under **Snippad Files** in the Organizer's sidebar.
The middle column lists its snippets in file order (drag to reorder; **+** and **−** below add and remove; Return puts one on the clipboard), and the right pane edits the selected one.
**Edit Snippets…** (⌘E) brings you there from a button window.
There you set its name, its value, whether it is a **Password** (hidden until you click the eye), the **list its copies go to** (default *Clipboard*), and what happens on the clipboard:

- **Remove from the clipboard after it is pasted once.**
- **Remove from the clipboard after** a time, such as `30s`, `5m` or `1h30m`.
- **Part of a chain. Once pasted, put on the clipboard** another snippet of the file.

A snippet holds one of four kinds of value:

| Kind      | Value in the file           | On the clipboard                         | Edited in Snippad |
| --------- | --------------------------- | ---------------------------------------- | ----------------- |
| text      | the text                    | the text                                 | yes               |
| rich      | RTF                         | the formatted text, and its plain text   | no (shown)        |
| file      | the path                    | the file itself, as Finder copies it     | path only (Choose Another File…) |
| image     | a PNG, base64-encoded       | the image                                | no (shown)        |

The **+** below the snippets adds a text snippet; hold it for **File Snippet…** and **Image Snippet…**.
**Add to Snippad ▸** on a history entry turns rich text, copied files (one snippet per file) and images into snippets of their kind.

A text value is edited with the same editor as history entries.
**Maximize** (beside the value, or in the toolbar) lets the value fill the whole pane, with line numbers and the **Text** menu; **Restore** brings the form back.

There is no Save: like everything in the Organizer, changes are written to the file a moment after you make them.
A change that would make the file unreadable -- a snippet without a name -- is shown at the top of the list and written once it is fixed.
The editor regenerates the file: the comment block at the top survives, other comments and keys Snippad does not know do not.

**File > New Snippad File…** (⌘N), or **+** below the sidebar, asks for a name and creates the file in `~/.snippad`.

### When is something pasted?

macOS does not tell anyone when something is pasted, and reading the clipboard does not count: IDEs, Universal Clipboard and other clipboard managers read every change within a fraction of a second.
So Snippad counts a paste when you type **⌘V** (or ⇧⌘V, ⌥⇧⌘V) while its value is on the clipboard, or when it pastes for you.
To see ⌘V it installs a keyboard tap for as long as the value waits, and removes it afterwards (see [The keyboard tap](#the-keyboard-tap)).
Seeing keystrokes in other apps needs the [Accessibility permission](#permissions); the menu bar shows a warning with a link while it is missing.
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
```

| Key       | Value                                                                                      |
| --------- | ------------------------------------------------------------------------------------------ |
| `expires` | Seconds as a number (`90`), or a duration string: `"45s"`, `"5m"`, `"1h30m"`, `"2d"`.      |
| `once`    | `true` or `false`.                                                                         |
| `password`| `true` or `false`.                                                                         |
| `next`    | The `name` of another snippet in the same file. Each snippet in a chain keeps its own rules. |
| `kind`    | `"text"` (the default), `"rich"` (`value` is RTF), `"file"` (`value` is a path), or `"image"` (`value` is a base64 PNG). |
| `list`    | The name of the history list its copies go to; left out, the first list (*Clipboard*).     |

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
| `history_copy`           | Puts an entry back on the clipboard.                                             |
| `history_add`            | Adds a text entry without touching the clipboard.                                |
| `history_pin`            | Pins or unpins an entry.                                                         |
| `history_delete`         | Deletes an entry.                                                                |
| `history_clear`          | Clears the history, pinned entries too if asked.                                 |
| `history_settings`       | Reads or sets recording on/off and how many entries are kept.                    |
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
| `Snippad/PickerPanel.swift`          | The ⇧⌘V window.                                                            |
|                                      |                                                                            |
| `Snippad/TextRecognition.swift`      | Text and QR codes in images, with Vision.                                  |
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
| `Snippad/HistoryWindow.swift`        | The Snippad Organizer window.                                              |
|                                      |                                                                            |
| `Snippad/ListExport.swift`           | Exporting a list as TOML, XML, JSON or YAML.                               |
|                                      |                                                                            |
| `Snippad/TextEditorView.swift`       | The text editor: find and replace, line numbers, line commands, transforms, wrapping. |
|                                      |                                                                            |
| `Snippad/MCPServer.swift`            | The socket server in the app and the `--mcp` stdio bridge.                 |
|                                      |                                                                            |
| `Snippad/MCPHandler.swift`           | MCP's JSON-RPC methods and the tools.                                      |
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


