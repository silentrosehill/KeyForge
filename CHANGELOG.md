# Changelog

## 1.7.1 (build 17)
- New icon: the frosted K keycap in sunset glass, pink to purple with an orange, pink and purple glow underneath

## 1.7.0 (build 16)
- Works with any keyboard: the picker at the top of the sidebar lists every connected keyboard (and ones you set up before), plus "All keyboards"
- Each keyboard has its own profiles and its own active profile, all working at the same time; "All keyboards" applies everywhere, and a keyboard's own profile goes on top
- Keyboard shapes: Full + media (Huntsman V2), Full, TKL, 60% and Mac (esc, Touch ID, fn, ⌃ ⌥ ⌘, half-height arrows). Guessed automatically, changeable in Settings, with ISO/ANSI per keyboard
- The Lighting tab only shows for keyboards KeyForge can light (Razer Huntsman V2)
- Auto-switching per app and the ⌃⌥ hotkeys work per keyboard; the menu bar lists profiles per keyboard
- Your existing profiles move to the Huntsman V2 automatically

## 1.6.1 (build 14)
- Fix: KeyForge kept saying it had no key access after you allowed it. It now tests access by actually starting its key watcher, checks again every 2 seconds and whenever you come back to the app, and has a Reset permission button for a stale entry
- The app is now signed with a stable identity, so Accessibility and audio permissions keep working after updates (allow it once more after this update)

## 1.6.0 (build 13)
- Profiles switch by themselves: add apps under the profile name ("Turns on for …"). While one of them is in front that profile is on, and it goes back to your pick when you leave
- Keys can do more: send a shortcut, type text, open an app, or run a macro (shortcuts, text and pauses in a row). Needs Accessibility, and works on every keyboard
- ⌃⌥1 … ⌃⌥9 switch to profile 1 … 9, with a small popup showing the new profile (Settings to turn off)
- Live lighting drawn by KeyForge: Ripple (key presses send waves), Rain, Heatmap (your most-used keys glow hotter), Album Cover (follows the song playing in MP3 Tagger 3.24+) and Music (columns dance to your Mac's audio)
- Caps Lock light: the Caps Lock key glows in its own color while Caps Lock is on (Solid, Per Key and Live effects)
- Fix: a crash at startup when a profile had key actions

## 1.5.0 (build 12)
- New look matching MP3 Tagger's Liquid Glass redesign: buttons, menus and switches use Apple's real Liquid Glass, content cards are calm filled panels, and the colored glows are gone
- Theme → Glass slider: from clear, see-through glass to frosted glass tinted with your color
- Lighting: premade themes, all per key: Synthwave, Aurora, Sunset, Inferno, Glacier, Gamer (ZQSD/WASD and arrows lit) and Razer
- Lighting: Randomize gives every key its own random color; click again for a new mix

## 1.4.1 (build 11)
- Fix: choosing Per Key could make the app freeze and use a full CPU core. With a mouse plugged in, the scroll bar kept appearing and disappearing and resizing the keyboard in an endless loop

## 1.4.0 (build 10)
- Lighting: save your own colors. The + button under the presets saves the current color; click a saved color to use it, right-click to remove it
- Saved colors work for Solid, Breathing, Reactive and as Per Key brush colors, in every profile (up to 12)

## 1.3.1 (build 9)
- Fix: Per Key colors landed one key to the right, so Esc, Tab, Caps Lock, Left Shift, Left Ctrl, F1, Right Alt, Up and some numpad keys stayed dark

## 1.3.0 (build 8)
- Lighting: new Per Key effect. Pick a color, then click or drag over keys to paint them; ⌥ Option-click erases
- Fill All paints every key; Clear Painted resets painted keys to the base color
- Each profile keeps its own key colors, and they come back when the keyboard is replugged

## 1.2.0 (build 7)
- Theme: "Match keyboard lighting" makes the whole app follow your keyboard's RGB color, and it updates when you change the color or switch profiles
- Wave, Spectrum and Off keep your chosen theme; white keys give a soft graphite theme

## 1.1.4 (build 6)
- Fix: the Lighting tab was laggy. The keyboard preview is now drawn in one pass with a single glow (about 4.5× faster per color change)
- Key labels are cached instead of being read from the keyboard layout on every redraw
- Profiles are saved shortly after you stop dragging instead of on every change

## 1.1.3 (build 5)
- Icon: a frosted glass K keycap seen from the front, like a photo of a real key; no pen

## 1.1.2 (build 4)
- Icon: the K keycap is now seen from the front and slightly below, with a reflection underneath

## 1.1.1 (build 3)
- New icon: a clear "K" keycap on black with a golden pen, matching MP3 Tagger

## 1.1.0 (build 2)
- Lighting tab: Solid, Breathing, Reactive, Wave, Spectrum and Off, with brightness
- Pick from Screen: click anywhere on your screen to use that color on the keyboard
- Color presets and a custom color picker; the on-screen keyboard glows in your colors
- Each profile keeps its own lighting
- Talks to the keyboard directly over USB, no Razer Synapse needed
- Fix: opening KeyForge always shows its window again

## 1.0.0 (build 1)
- Your Razer Huntsman V2 drawn to scale (ISO/AZERTY or ANSI), with the legends of your current keyboard layout
- Click a key, then pick what it does from the menu or just press the key you want; Default puts it back
- Profiles: add, rename, duplicate, delete; clicking a profile switches to it right away
- Media keys, volume, brightness, Mission Control, Launchpad, Spotlight, Fn and "disabled" as targets
- Quick setups: Mac modifiers, Caps Lock → Esc, media on F7–F12, disable Win keys
- Keys light up while you press them
- Razer only or all keyboards; re-applies when the keyboard is replugged
- Lives in the menu bar (switch profiles there) and opens at login
