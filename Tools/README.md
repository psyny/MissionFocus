# MissionFocus Tools

Scripts for checking MissionFocus's built-in tales (Tales tab > Core Tales) and drawing the addon icon. This folder is kept in the repository but left out of the packaged addon (`.pkgmeta` ignores `Tools`); nothing here is loaded by the game.

The tale generators and the BtWQuests chain data live in a separate private repository, `MissionFocusTools`, cloned next to this folder's `MissionFocus` (as `wowAddons/MissionFocusTools`). They read the questline tables below and write their output into `../default_tales`.

Needs Python 3 with `lupa` (`pip install lupa`). The scripts find their paths from where they live (`MissionFocus/Tools`), so they run from anywhere, without arguments for folders. BtWQuests' quest names are read from `ReferenceAddons` next to the `MissionFocus` folder, when it is there.

## Data

| File | What | How to refresh |
|---|---|---|
| `wago/QuestLine.csv` | The game's questlines (ID, name) | `curl -L -o wago/QuestLine.csv https://wago.tools/db2/QuestLine/csv` |
| `wago/QuestLineXQuest.csv` | Which quests are in each questline, in order | `curl -L -o wago/QuestLineXQuest.csv https://wago.tools/db2/QuestLineXQuest/csv` |
| `known_quests.json` | Quests found on Warcraft Wiki that no other source covers (written by the tale generators) | by the generators |

Refresh the tables after a game patch.

## Looking things up

- `ql.py <questLineID | "name">`: a game questline's quests, or questlines by name (with their BtWQuests chain when `MissionFocusTools` is there).

## Checking

`python -I -X utf8 check_tales.py` reads every file in `../default_tales` with MissionFocus's own tale reader and reports read warnings, duplicate step IDs, broken links, main steps that only follow optional ones, and quest or questline IDs that no source knows. Run it after every change; it should end with `OK`.

## Addon icon

`python -I make_icon.py` redraws `../Icons/icon.tga`, the icon shown in the AddOns list (`## IconTexture` in both `.toc` files). Pass a second argument (`python -I make_icon.py ../Icons preview.png`) to also save an enlarged PNG preview. No dependencies.
