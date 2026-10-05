# HopAway

Leave a crowded layer: one click asks another HopAway user on a different
layer of your zone to invite you. Once the game moves you, HopAway leaves the
group for you.

## Install

Copy the `HopAway` folder to:

```
<WoW folder>/<client folder>/Interface/AddOns/HopAway/
```

for example `World of Warcraft/_classic_beta_/Interface/AddOns/HopAway/` for WoW: Forever.
The folder must be named `HopAway` (rename it if you downloaded a zip such as `HopAway-main`).

The `.toc` targets `## Interface: 16001` (WoW: Forever). If the client calls the addon
out of date after a patch, update that number. To get the current one in game:
`/run print((select(4, GetBuildInfo())))`.

## Use

- **Minimap button**: left-click shows the layer window, right-click hops
  to another layer, and dragging moves it around the minimap edge. The tooltip shows your status.
- `/hop away`: ask for an invite to another known layer in your zone.
- `/hop cancel`: stop the current hop.
- `/hop status`: your zone and layer, known layers with HopAway user/helper counts, hop state.
- `/hop share|help|autoinvite|autoaccept on|off`: settings (also checkboxes in the window).
- `/hop show`: toggle the window. `/hop minimap`: toggle the minimap button.

In the window, click a layer to hop to that one. Your own layer is green.
Layers with no helpers are grey and can't be clicked.

## Settings (all off by default)

| Setting | What it does |
|---|---|
| Share my layer | Announces your zone + layer to other HopAway users (on change and every ~10 min). |
| Layer help | Answers players who ask to join your layer. Turning it on also turns on sharing, because helpers have to be announced to be found. |
| Auto-invite askers | When someone you offered to help asks, invite them without a popup. Otherwise you get an Accept/Decline popup (20 s). |
| Auto-accept my helper's invite | Accepts the invite only when it comes from the exact helper you asked. Invites from anyone else are never auto-accepted. |

## How it works

1. HopAway reads your layer from the `zoneUID` in NPC GUIDs (target, mouseover,
   nameplates). A new value only counts after two different NPCs show it and the
   old one has been gone for a few seconds.
2. Users who share their layer announce it on a hidden chat channel (`HopAwayNet`) using addon messages.
3. When you hop, HopAway picks another known layer with helpers and asks there. Helpers
   reply with a chance scaled so that about 6 of them answer. You ask one of them
   (up to 3 in a row) to invite you.
4. When you join their group, the game moves you to their layer. HopAway sees the new
   `zoneUID` and leaves the group. If nothing changes within 20 s, it asks you whether to leave.
5. After a failed ask, you wait 20 s, then 60 s, then 180 s before asking again.

## Limits (please read)

- **Needs other HopAway users.** Someone on another layer of the same zone must
  have *Layer help* on. With no users there, there's nobody to ask.
- **It can't see real crowd sizes.** The counts only include HopAway users. Nobody
  can count all players on a layer, so any other layer is a guess (usually a good one).
- **The game's layer cooldown.** If you changed layer recently, joining a group may
  not move you for a few minutes. HopAway will then ask whether to leave the group.
- **Your layer must be known.** Look at a couple of NPCs first. Hopping is blocked in
  instances, in combat, or while you're already in a group.
- You always join the hidden channel so you can see announced layers. Your own
  layer is only announced if *Share my layer* is on. After you turn sharing off,
  others may still list you for up to ~25 min.

## Tests

The pure logic (GUID parsing, layer detection, message format, picks, throttles)
is in `Logic.lua` and runs without the game:

```
lua tests/test_logic.lua
```

## License

MIT, see [LICENSE](LICENSE).
