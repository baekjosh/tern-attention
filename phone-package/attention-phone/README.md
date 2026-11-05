# Attention (phone)

**Phone only: never install this on the Mac.** It carries the plugin id `attention`, the same id as the Mac plugin, so on the Mac it would collide with it (a duplicate id, and it would sort first). The folder is still named `attention-phone/`.

Window-half companion for the Attention queue block. Your Mac shows the queue; this package lets a tap on a row focus that conversation on the iPhone or iPad, and takes you to the queue when you tap the mirrored rail.

## Install or upgrade

1. Build and send it: `python3 tools/phone_package.py build`, then `python3 tools/phone_package.py send --to <tailscale-name> --yes`.
2. On the phone, save the zip from Taildrop into Files › On My iPhone › Tern › Plugins and unzip it there. The folder `attention-phone/` must sit directly in `Plugins` with `plugin.toml` inside it. **Upgrading:** delete the old `attention-phone` folder there first (or replace it) so no old file survives.
3. In Tern, Preferences › Plugins (or the palette's Reload plugins). Tern polls the folder every 2 s.

## Use

- Palette: **Attention queue** takes you to the queue block from the Mac you are attached to. It reuses the one that is already open and never makes a second. If that block is parked on the Mac you get a toast instead (`Restore it from Parked panes`); it is never unparked for you.
- The phone also shows the Mac's desktop rail, mirrored in every tab. It is a picture of the Mac's rail, not a control: tapping anywhere on it opens the queue block (toast `Attention queue`) instead of doing what the Mac's rail would do.
- In the queue block, **Test phone link** shows the toast `Attention phone link works` when the route is installed.
- Tapping a row focuses the pane whose title matches the conversation's title (icon glyphs and extra spaces ignored, case kept). If several panes share that title, the pane id, then the working directory, then the program break the tie. A parked pane is never moved; you get a toast instead. If no pane here has that title and the link names a session of this window, the phone switches to that session and looks again (up to three times, 300 ms apart) before giving up with `Couldn't find that conversation on this phone`.
- Palette: **Attention: Copy phone diagnostics** copies a plain-text report (at most 8 KB) to the clipboard and toasts `Diagnostics copied`: the package version, the OS, the hosts and sessions the phone sees, how many panes it has per host, up to 60 of them (title, folder, program, tab, flags, with icon glyphs shown as `\uXXXX`), and what the last tapped row looked for and how many panes matched at each step. Run it right after a row fails to open and paste the report back.

Window half only: no host entry, no processes, no network.
