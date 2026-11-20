# Snippad 2.0.0

Snippad is now a clipboard manager as well as a snippet pad.
It lives in the menu bar, remembers what you copy, keeps it in lists with rules about where it may be pasted, and lets you edit both the history and your `.snippad` files in one window, the **Snippad Organizer**.
Agents can use all of it through MCP.

## Clipboard history

- Records everything you copy -- text, rich text, images, files -- in `~/Library/Application Support/Snippad/History`, readable only by you.
- The menu bar icon (and **⌃⌘V**, anywhere) opens the history; keys **1**–**9** and **0** choose the first ten entries, and pinned entries stay at the top.
- Every entry has a submenu with **Put on Clipboard**, **Paste**, **Paste as Rich Text**, **Paste Original**, **Pin**, **Move to List ▸**, **Extract Text**, **Add to Snippad ▸**, **Share ▸** and **Delete**, plus file commands for copied files (**Copy File Contents**, **Copy Names as Text**, **Copy Paths as Text**, **Show in Finder**).
- **⇧⌘V** opens a small picker with the entries of your preferred list, offering only what may be pasted into the app in front.
- **Extract Text** reads the text and QR codes in an image on your Mac, with Apple's Vision framework, into a new text entry.
- Copied files that have since been deleted or moved are greyed out; their names and paths can still be copied.
- Search covers text, file paths, source applications, and the EXIF, TIFF, GPS and IPTC metadata of copied images.
- Applications can be excluded from recording, and nothing marked concealed or transient (as password managers do) is recorded.

## The Snippad Organizer

- One window for the history, the lists and the `.snippad` files.
- Select several entries and drag them onto a list to move them.
- Text entries are read-only until you click **Edit**; changes are kept as you type.
  The editor has find and replace, absolute or relative line numbers, line wrapping, line commands (**⇧⌘↑/↓**, **⌥⇧↑/↓**, **⇧⌘D**, **⌘⌫**), trimming and case commands, **Convert to Plain Text**, and export to a file.
- Copying part of an entry (⌘C) creates a new entry in the same list, so that list's rules still apply.
- Right-click the toolbar to choose Icon and Text, Icon Only or Text Only.

## Lists and the Paste Guard

- Divide the history into lists, each with its own icon. Every application's copies can go to a list of their own, and one list can collect everything copied in private browser windows.
- Lists are created, edited, deleted (moving or deleting their entries) and exported -- as **TOML**, **XML**, **JSON** or **YAML** -- right in the Organizer.
- The **Paste Guard** (off until you switch it on) stops ⌘V when the clipboard's list may not be pasted into the app in front: allow lists, deny lists, and "only into private browser windows" for Chrome, Brave, Edge, Vivaldi, Firefox and Tor Browser.
- It needs a keyboard tap, which Snippad installs only while the clipboard holds something from a restricted list, or while a paste-once or chained value waits, and removes as soon as neither is true.

## Snippets

- `.snippad` files are edited in the Organizer, with no Save: changes are written a moment after you make them.
- Every file in `~/.snippad` is always open; files from elsewhere stay open until you eject them, and their button windows reopen at launch.
- New per-snippet options:
  - **Password**: shown as dots everywhere, and concealed from other clipboard managers.
  - **Remove after one paste**, and **remove after a time**.
  - **Chains**: once one snippet is pasted, the next goes on the clipboard (user name, then password).
  - **The list** its copies go to.
- A snippet can hold **rich text**, a **file** (the file itself is copied) or an **image**, as well as plain text.
- **Add to Snippad** turns history entries into snippets.

## For agents

- An MCP server gives agents the clipboard, the history, the lists, the applications and the `.snippad` files.
- Password values are never revealed to agents.
- Set it up with the command under *Settings > General > Agents (MCP)*.

## Settings and startup

- Settings live in a window of their own and are saved to `~/.snippad/settings.json`.
- The applications Snippad knows are kept in `~/.snippad/apps.json`. Applications that disappear are forgotten, or, if a setting names them, shown as *Not found* with **Locate…** and **Remove**.
- **Open Snippad at login** in *Settings > General*.

## Permissions

- **Accessibility** is needed for the Paste Guard, paste-once and chained snippets, and pasting for you. Snippad asks for it only when one of these is used, and works without it otherwise.
- **Automation** is asked once per Chromium browser, the first time the Paste Guard needs to know whether its window is private.

## Upgrading from 1.0

- `.snippad` files from 1.0 open unchanged.
- Editing now happens in the Organizer: **Edit Snippets…** (⌘E) takes you there from a button window.
