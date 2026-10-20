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
- `/hop status`: your zone and layer, known layers with HopAway user/helper counts and crowd samples, realm type, hop state.
- `/hop on|off`: turn every setting on or off.
- `/hop share|help|autoinvite|autoaccept on|off`: single settings (also in the window).
- `/hop show`: toggle the window. `/hop minimap`: toggle the minimap button.
- `/hop debug on|off|clear`: record a timestamped log of layer, zone, group,
  invite, popup and system-message events (`/hop debug` shows the last lines).
  `/hop mark` adds a numbered snapshot. The log is kept in
  `WTF/Account/<account>/SavedVariables/HopAway.lua` after a `/reload` or logout.

In the window, click a layer to hop to that one. Your own layer is green.
Layers with no helpers are grey and can't be clicked. Each layer shows
**~N seen**: how many players HopAway users there noticed nearby in the last
5 min (a sample, not a headcount), and **left N min ago** if you hopped away
from it recently.

When no other layer has a helper, the window lists up to 4 online friends and
guildmates in your zone. Click one to open a whisper asking for an invite and
press Enter to send it. The game shows their zone but not their layer, so it's
roughly a coin flip whether they're on another one. If their invite moves you,
HopAway leaves the group as usual; if not, it asks whether to leave. The **All off** radio
button turns every setting off; tick the boxes below it to turn single parts
back on.

## Settings

Settings are saved per character.

- **PvE realms:** everything starts **on**, since that's what makes hopping
  work for you and everyone else. A chat message says so on first login.
  Use `/hop off` or **All off** to opt out.
- **PvP realms:** everything starts **off**, and a popup asks whether you
  want to turn it on. See *Privacy* below.
- **How HopAway knows:** a realm whose name says its ruleset (WoW: Forever's
  `ClassicBetaPvE` / `ClassicBetaPvP`) is taken at its word. Otherwise only a
  contested zone proves anything (PvP), and that's remembered for every
  character on the realm. A zone without a PvP type proves nothing, because
  PvP realms report that too.
- **Realm type not known:** everything starts **off** and you get the popup.
  If you never chose settings yourself and the realm turns out to be PvP,
  HopAway turns itself off.

Anything you change yourself is kept and never overridden.

| Setting | What it does |
|---|---|
| Share my layer | Announces your zone + layer to other HopAway users: 5–15 s after a change (at most once every 30 s) and every 10–12 min. |
| Layer help | Answers players who ask to join your layer. Turning it on also turns on sharing, because helpers have to be announced to be found. You keep helping while you lead a party made only of HopAway guests (each joined less than 1 min ago), so several askers can share it. In any other group or raid you're announced as not helping and asks are ignored, so nobody gets added to a group players made; it resumes when you're solo. |
| Auto-invite askers | When someone you offered to help asks, invite them without a popup, even while you're in combat. Otherwise you get an Accept/Decline popup (20 s), and asks that come in while you're fighting are skipped. |
| Auto-accept my helper's invite | Accepts the invite only when it comes from the exact helper you asked. Invites from anyone else are never auto-accepted. |

## Privacy

HopAway users share through a chat channel (`HopAwayNet`) that anyone can
join. When *Share my layer* is on, anyone on that channel can see your
character name, zone and layer, and how many players you've noticed nearby
(a number only, no names). On a PvP realm, enemy players could use this
to find you, which is why HopAway starts off there. With sharing off, your
zone and layer aren't sent, but your name still shows in the channel's
member list.

## How it works

1. HopAway reads your layer from the `zoneUID` in NPC GUIDs (target, mouseover,
   nameplates). A new value only counts after two different NPCs show it and the
   old one has been gone for a few seconds.
2. It also counts the distinct players it notices on your layer in the last 5 min
   (nameplates, target, mouseover): the crowd sample. Turn on friendly player
   nameplates (Options > Interface > Nameplates) for a much better count: by
   default only enemy players get nameplates. This client doesn't let addons
   read the combat log, so HopAway can't count players from it.
3. Users who share their layer announce it, with their crowd sample, on a hidden
   chat channel (`HopAwayNet`) using addon messages.
4. When you hop, HopAway picks another known layer with helpers and asks there.
   It favours layers where HopAway users see fewer players (the median of their
   samples). If a layer has no sample yet, it compares HopAway user counts
   instead. There's some randomness so askers don't all pick the same layer.
   Layers with more helpers get a small bonus (at most +50%), so askers spread
   out without being sent to busier layers. A layer you hopped away from in the
   last 45 min counts a quarter, so you don't land back on it. Helpers
   reply with a chance scaled so that about 6 of them answer. You ask one of them
   (up to 3 in a row) to invite you.
5. Accept the helper's invite within 20 s (instant with auto-accept), or HopAway
   declines it and asks the next helper. When you join their group, the game moves you to their layer. HopAway sees the new
   `zoneUID` and leaves the group. If nothing changes within 20 s, it asks you whether to leave.
6. After a failed ask, you wait 20 s, then 60 s, then 180 s before asking again.

## Limits (please read)

- **Needs other HopAway users.** Someone on another layer of the same zone must
  have *Layer help* on. With no users there, there's nobody to ask.
- **It can't see real crowd sizes.** User and helper counts only include HopAway
  users. The crowd sample only covers players near HopAway users on that layer.
  Nobody can count all players on a layer, so any pick is still a guess (usually
  a good one).
- **0.3.0 doesn't talk to older versions.** The announce format changed, so 0.1.x
  and 0.2.x users won't see 0.3.0 users and the other way round. Later versions
  can add fields without this break.
- **The game's layer cooldown.** If you changed layer recently, joining a group may
  not move you for a few minutes. HopAway will then ask whether to leave the group.
- **Your layer must be known.** Look at a couple of NPCs first. Hopping is blocked in
  instances, in combat, or while you're already in a group.
- You always join the hidden channel so you can see announced layers. Your own
  layer is only announced if *Share my layer* is on. After you turn sharing off,
  others may still list you for up to ~25 min.

## Tests

The pure logic (GUID parsing, layer detection, message format, crowd sample, picks, throttles, contacts)
is in `Logic.lua` and runs without the game:

```
lua tests/test_logic.lua
```

## License

MIT, see [LICENSE](LICENSE).
