<p align="center">
  <img src="Icon/peacemenu-icon.png" width="160" alt="PeaceMenu icon: a peace sign under a small menu bar">
</p>

# PeaceMenu

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/stephanepoulin)

[![Download PeaceMenu for macOS](https://img.shields.io/badge/Download-PeaceMenu%20for%20macOS-245A8C?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/spoulin/peace-menu/releases/latest/download/PeaceMenu.dmg)

For macOS 14 or later, on Apple silicon and Intel Macs. See [Install](#install).

A menu bar organizer for macOS. It sorts your menu bar icons into named groups, and profiles
decide which groups are always there, which show with a click on ☮, and which stay hidden:
one profile for work, one for focus, one for the small screen of a laptop.

## What it does

- **Groups.** Put icons in named groups. Each group has a separator in the menu bar (its name, a
  symbol, a line, a dot or a space), left or right of its icons, in an optional color.
- **Profiles.** In each profile, every group is **Always** (in the menu bar), **On demand** (hidden;
  a click on ☮ shows it for a while) or **Off** (never shown), in the order you choose. Icons in
  no group get one of these three too. Switch profiles from the ☮ menu.
- **Change signal.** When an icon of an On demand group changes (a VPN disconnects, for example),
  an orange dot appears on ☮, and the hidden groups can show for a moment.
- **Hidden icons, at a glance.** Right-click ☮: Hidden Icons lists every hidden group, Off ones
  included, with what each icon says right now (a VPN's status, the battery level). Choose one
  to open its app.
- **Running apps and notifications.** Right-click ☮: Notifications lists the apps with a badge
  in the Dock (unread mail, messages), and Running every open app (in a submenu past 12), with
  its windows when it has several. Choose one to bring it to the front; hold ⌥ to force quit it.
  A red badge on ☮ shows the total, even with the Dock hidden (a setting turns it off).
- **App switcher.** Choose a shortcut in Settings and press it: the apps of the Dock show in a
  grid, with their badges; the ones that aren't running are greyed out. The apps with a badge
  come first, above a thin line, then the others; in each, the ones you use most come first. Move
  with the arrows or type the start of a name, then press Return to bring the app to the front,
  or open it. As with ⌘⇥, keep the modifier down and press the key again to move to the next
  app; let go to open it.
- **New icons.** When an app adds an icon, PeaceMenu puts it in its group, or behind the others.
- **The purple recording indicator.** macOS never lets an app hide it; PeaceMenu keeps it just
  right of ‹, out of the way of your groups.
- **A colored ☮** if you like: rainbow or 70s stripes.

From left to right, the menu bar looks like this:

```
[Off…] ‹‹ [On demand groups] ‹ [Always groups] ☮ [always visible] clock
```

## Install

1. Download [PeaceMenu.dmg](https://github.com/spoulin/peace-menu/releases/latest/download/PeaceMenu.dmg)
   and open it.
2. Drag PeaceMenu onto Applications.

   <img src="Resources/install-dmg.png" width="660" alt="The PeaceMenu disk image: drag PeaceMenu to Applications">

3. Open PeaceMenu from Applications. macOS says it can't check the app: click **Done**
   (not Move to Trash).
4. Open System Settings › Privacy & Security, scroll down to Security, and click
   **Open Anyway** next to “PeaceMenu.app” was blocked. Confirm with your password.
   You only do this once.
5. PeaceMenu asks for **Accessibility**: allow it in System Settings › Privacy & Security ›
   Accessibility. It needs it to read the menu bar icons and move them. The permission stays
   from one version to the next.

PeaceMenu isn't notarized by Apple: it's signed with its own certificate, not tied to an Apple
developer account. That's why macOS asks first.

**Updates.** Right-click ☮ › Check for Updates… opens the latest release. Download the new disk
image and drag PeaceMenu onto Applications again, replacing the old one.

**Clicked Move to Trash by mistake?** Download the disk image again and start over.

## Use

| | |
|---|---|
| Click ☮ | Show or hide what the profile has On demand |
| Right-click or ⌥-click ☮ | Profiles, Hidden Icons, Settings, Check for Updates |
| Click a group's separator | The group's menu |
| ⌘-drag an icon right of ☮ | It always stays visible |

**Settings › Groups:** create groups, add icons to them, pick the separator's style, side and color.
**Settings › Profiles:** for each profile, set every group to Always, On demand or Off, and their
order (top to bottom is left to right in the menu bar). **Settings › General:** when hidden icons hide again, what happens
when an icon of a folded group changes, launch at login.

## How it works

macOS has no public way to move another app's menu bar icon, so PeaceMenu does what you would do:
a ⌘-drag. While it moves icons, your clicks are held off for a moment and the cursor shows a
spinning wheel. Hidden icons sit off screen, pushed there by the stretched ‹ and ‹‹ separators.

Measured on macOS 26: every menu bar icon window belongs to Control Center, so PeaceMenu finds
which icon is whose through Accessibility. A log of what it moved is kept in
`~/Library/Logs/PeaceMenu.log`.

## Build

```bash
./build.sh
```

builds `build/PeaceMenu.app`, signs it and installs it in `~/Applications`. `NO_INSTALL=1` only
builds; `UNIVERSAL=1` builds for Apple silicon and Intel Macs.

### Releases

A version tag builds the app on GitHub, makes the disk image and publishes a release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

To make the disk image locally (with [dmgbuild](https://github.com/dmgbuild/dmgbuild) installed):

```bash
UNIVERSAL=1 NO_INSTALL=1 ./build.sh
NAME="PeaceMenu" COLORS="1E6E78 245A8C 25307A" tools/make-dmg.sh build/PeaceMenu.app PeaceMenu.dmg
```

## Support

If PeaceMenu brings some peace to your menu bar (and your mind), you can buy me a coffee.

<a href="https://buymeacoffee.com/stephanepoulin"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>

Made by [Stéphane Poulin](https://www.stephanepoulin.com).
