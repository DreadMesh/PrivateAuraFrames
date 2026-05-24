# PrivateAuraFrames

Displays the game's **private aura icons** — Works for # Elvui and # blizzard default ONLY

Built as a standalone, lightweight solution — no WeakAuras dependency, no large bundle, just one Lua file.

> ⚠️ **This addon was entirely vibecoded — built collaboratively with AI rather than hand-written by a developer.** The code has been tested in live dungeon and raid environments.

## Features

* **Separate layouts for party and raid.** Configure size, position, anchor, spacing, grow direction, border, and maximum icon count independently for party/dungeon (≤5 players) and raid (6+ players) contexts. The addon automatically switches between layouts as your group composition changes.
* **Per-icon tooltips.** Hover any aura to see the tooltip.
* **Independent visual toggles** for the cooldown spiral animation, spiral countdown numbers, and the separate duration text below the icon.
* **Optional tooltip suppression** if you'd rather not have private auras eat your mouseover.
* **Configurable border scale** to match the look of your unit frame addon.
* **Optional fade-with-frame.** When your unit frame addon (ElvUI, Blizzard CompactRaidFrames) fades a unit's frame due to range or other reasons, the private aura icons on it fade too — keeping the visual consistent.
* **Live drag-to-position preview** with numbered placeholder icons, so you don't need to wait for a real private aura to dial in your layout.
* **Always shows on the correct frame.** Anchors are rebuilt from scratch on every roster event — no stale frames, no `/reload` needed mid-session.

## Compatibility

* **WoW Midnight 12.0.5+**
* **Unit frame addons supported out of the box:** ElvUI (all raid layout variants, including split-raid), Blizzard default `CompactPartyFrames` and `CompactRaidFrames`

## Slash Commands

| Command | Description |
| ------- | ----------- |
| `/paf` | Open the settings panel |
| `/paf preview` | Toggle drag-to-position preview (auto-selects party or raid based on current context) |
| `/paf preview party` | Toggle preview for party layout |
| `/paf preview raid` | Toggle preview for raid layout |
| `/paf reload` | Manually rebuild anchors (rarely needed) |
| `/paf debug` | Show live anchor counts |
| `/paf verbose` | Toggle error printing for troubleshooting |
| `/paf dump` | opens a popup window listing every live private aura anchor with its unit binding, slot, and age. Useful for diagnosing stuck-icon or wrong-target bugs. Text is auto-selected for easy copying. |
| `/paf reset` | Wipe saved settings and reload UI |

## Why this exists

Most private aura solutions either bundle with much larger packages or have edge-case issues with non-default unit frame layouts (especially ElvUI's split-raid configurations). This addon is purpose-built to do one thing — show private auras on the unit frames you already use — and do it without taint, library bloat, or dependencies.

## A note on the development process

Every line of this addon was written by an AI assistant working with a user iteratively over many sessions, including extensive debugging in live game environments. Architecture decisions, taint-avoidance strategies, and edge-case handling were collaboratively figured out through testing rather than planned upfront.
