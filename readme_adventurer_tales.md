# Adventurer's Tales

World of Warcraft tells its stories across thousands of quests, spread over zones, expansions and years. Playing them in an order that makes sense, without missing the parts that matter, is hard. The game shows you what is near, not what comes next in the story.

**Adventurer's Tales** lets you build your own path through those stories, and follow it. It is not a leveling guide and it does not care about speed. A tale is about the story: which quests to play, in which order, and why they matter.

You can make tales for yourself, share them with friends, or play tales other people made.

You find it in the **MissionFocus Center** (right-click the MissionFocus panel, or `/mf log`), in the **Tales** tab.

---

## How a tale is built

A tale is organized like a book:

- **Tale**: the whole journey. *"The Fall and Rise of Quel'Thalas."* It has a title, an author, a description, a faction (Alliance, Horde, or both) and a **game version**: **Retail** or **Forever**. Quests, zones and levels differ between the two, so a tale only plays in the game it was made for. A new tale starts with the game you are playing.
- **Story** (optional): a large part of the tale. *"The Siege of Silvermoon."* Small tales can skip stories and hold chapters directly.
- **Chapter**: one episode of a story. *"Shadows over Eversong."*
- **Step**: what you actually do. Every chapter is made of steps.

A step can be:

| Step | What it is | Done when |
|---|---|---|
| **Quest** | One quest. | You complete it. |
| **Questline** | A whole questline from the game. Its quests are filled in for you. | All its quests are done. |
| **Dungeon / Raid** | Story told inside an instance. | You mark it done (or a linked quest is done). |
| **Achievement** | A lore achievement. | You have earned it. |
| **Visit** | A place worth seeing: a statue, a book, a view. | You mark it done. |
| **Note** | Story text between steps: *"Meanwhile, in Orgrimmar..."* | When you reach it. |

Tales can contain stories or chapters, but never steps directly. That keeps every tale readable.

### Order and parallel paths

Each story, chapter and step can say what comes **before** it (its *previous* items).

- If nothing in a list says what comes before, the items simply follow each other in the order they are listed. Most chapters are like that.
- An item can have several previous items: it waits until all of them are done. That is how two paths join.
- Two items with the same previous item can be played in any order: they are parallel. The tale view shows them side by side, in lanes, like the Questlines tab does.

### Main, side and optional

Every story, chapter and step has a **role**:

- **Main**: the spine of the tale. Always shown on the left lane.
- **Side**: part of the tale and counts toward finishing it, but not the main thread.
- **Optional**: nice to have. Never blocks anything, and does not count toward completion.

### Requirements

Stories, chapters and steps can have requirements. The tale shows them clearly instead of letting you walk into a wall:

- **Level**: a minimum (and optionally a maximum) character level.
- **Completed quests**: quests that must be done first. In the editor you tick them from a list: for a step, the other quests of its chapter; for a chapter, the quests of the other chapters; for a story, the quests of the other stories. A tale file can name any quest, even from outside the tale.
- **Chromie Time**: many older stories only play correctly in a specific timeline.
- **Faction**: a step can be for Alliance or Horde only. A tale for both factions can have both versions of the same scene; you only see yours.

A step can also be marked **no longer available**, for content that was removed from the game. The tale still tells you it was there, and moves on.

---

## Playing a tale

Open a tale and you see its stories (or chapters) as a flow from top to bottom. Click one to go inside. Each level shows:

- what is **done** (green), what you are **on** (gold), what you can **start now** (gold outline),
- what is **waiting** for something before it (grey),
- what is **blocked by a requirement** (red outline, with the reason),
- what you **skipped or still have to do** while later parts are done.

Your progress always comes from the game itself: if you already did a quest years ago, the tale knows.
Quests done on another character of your account are shown as such, so you can replay a story on an alt without losing track.

On each step:

- **Click** a quest you have: MissionFocus focuses it. A quest you do not have yet: a waypoint is set to where it starts.
- **Click** a questline: its full view opens, with all its quests and branches.
- **Click** a visit: a waypoint takes you there.
- **Shift-click** a dungeon, visit or note to mark it done (or not done).
- **Hover** anything to read its story text, requirements and where it starts.

### Following a tale

Press **Follow** on a tale. While you follow it:

- when you pick up the tale's next quest, it becomes your focused quest;
- when you finish a step, MissionFocus tells you what comes next, and focuses it if you already have it;
- the **"Next tale step"** action (bind it in Options > Actions) or `/mf tale` jumps to the next step: focus, waypoint, or open it.

You follow one tale at a time, per character.

### Spoilers

The Tales tab has a **Hide spoilers** switch. With it on, the names of steps you have not reached yet stay hidden until you get there.

---

## Making a tale

You write the parts that are yours: the tale, its stories and chapters, their descriptions and order. The steps come from the game: you pick quests and questlines, you do not type them out.

1. In the Tales tab, press **New Tale**. Give it a title and a description.
2. Add **chapters** (and **stories**, if your tale is long; adding a story to a tale with chapters moves them into it).
3. Add **steps** to each chapter. There are many ways, use whichever is easiest:
   - **From your quest log** or **from your questlines**, picked from a list.
   - **Add to Tale...** from the Quest Log tab (right-click a quest) or from a questline's view.
   - **Record**: turn on recording for a chapter and simply play. Every quest you complete is added to the chapter, with where you got it and from whom. Tidy up afterwards.
   - **By ID**: type a quest, questline or achievement ID.
   - **Here**: add a Visit at your current position.
4. Set the order, roles and requirements in the editor. Each story, chapter and step shows its title and what it comes after; open **Details** for its story text, role and faction, and **Requirements** for level, Chromie Time and quests to do first.

Where a quest starts (NPC, map and position) is found automatically when possible. You only need to fill it in when the automatic answer is wrong or missing.

### With BtWQuests

If you have the **BtWQuests** addon installed, making tales gets much faster:

- search BtWQuests' quest chains by name and add a whole chain to a chapter, either as one questline step or as separate quests **with its branches already in place**;
- quest names and quest givers' locations are filled in from its database.

BtWQuests is only a helper. Every tale works without it, for the people who play it and for the people who make it.

---

## Sharing tales

A tale can be **exported** as text and **imported** by anyone using MissionFocus. Press **Export** on a tale, copy the text, and share it however you like. To play a shared tale, press **Import** in the Tales tab and paste it.

The text is JSON, a common format that other tools can read and write. So tales can also be written or generated outside the game, in a text editor or with your own tools, and imported afterwards.

Tales are saved for your whole account. Each character keeps its own progress.

### Core tales

MissionFocus comes with **core tales**, ready to play: press **Core Tales** in the Tales tab. When a newer version of a core tale comes with an update, the button shows up again and asks before replacing your copy (your progress stays).

The first core tale is **The Tale of the Trolls**: the story of the Darkspear and of the troll empires around them, played as a Darkspear troll of the Horde.

- **Rise of the Darkspear**: the Echo Isles, Stranglethorn and Zandalar. This story also levels you, and each chapter says which Chromie Time to use.
- **Echoes of the Old Empires**: Zul'Drak, the Rise of the Zandalari, the Isle of Thunder and the death of Vol'jin, played as legacy content with Chromie Time off.
- **The Shadow Hunter's Last Journey**: the war for Zandalar, Vol'jin's spirit, the Night Fae and the Darkspear heritage.
- **The Amani Reborn**: Midnight, from Quel'Thalas to the Curse of Ula'tek.

Chromie Time choices change as new expansions arrive, so they are written in the chapters' notes, where they are easy to update.

---

## For tale makers: the file format

This section is for people writing tales outside the game.

A tale file looks like this:

```json
{
  "format": "MissionFocus-Tale",
  "formatVersion": 1,
  "id": "quelthalas-saga",
  "title": "The Fall and Rise of Quel'Thalas",
  "author": "Psyny",
  "version": "1.0",
  "game": "retail",
  "description": "The elves' homeland, from the Light's call to the shadow over Eversong.",
  "faction": "both",
  "stories": [
    {
      "id": "the-call",
      "title": "The Call",
      "chapters": [
        {
          "id": "summons",
          "title": "The Light's Summons",
          "requires": { "level": 80 },
          "steps": [
            { "type": "note", "description": "Quel'Thalas calls for help." },
            { "type": "questline", "questLineID": 5811 }
          ]
        }
      ]
    },
    {
      "id": "eversong",
      "title": "Eversong Woods",
      "previous": ["the-call"],
      "chapters": [
        {
          "id": "whispers",
          "title": "Whispers in the Twilight",
          "steps": [
            { "id": "q1", "type": "quest", "questID": 86733 },
            { "id": "q2", "type": "quest", "questID": 86734, "previous": ["q1"] },
            { "id": "q3", "type": "quest", "questID": 86738, "previous": ["q2"] },
            { "id": "q4", "type": "quest", "questID": 86739, "previous": ["q2"], "role": "side" }
          ]
        }
      ]
    }
  ]
}
```

**Tale fields**

| Field | Meaning |
|---|---|
| `format`, `formatVersion` | Always `"MissionFocus-Tale"` and `1`. |
| `id` | A short unique name. Importing a tale with the same `id` offers to replace the old one. |
| `title`, `author`, `version`, `description` | Text. Only `title` is required. |
| `game` | `"retail"` or `"forever"`: the game version the tale is made for. Default `"retail"`. |
| `faction` | `"both"`, `"alliance"` or `"horde"`. Default `"both"`. |
| `stories` *or* `chapters` | The tale's content: a list of stories, or a list of chapters. Not both. |

**Fields of stories, chapters and steps**

| Field | Meaning |
|---|---|
| `id` | Unique within the tale. Optional: missing IDs are created on import. |
| `title`, `description` | Text. For quests and questlines, `title` is optional (the game's name is used). |
| `role` | `"main"` (default), `"side"` or `"optional"`. |
| `previous` | IDs of what comes before, from the same list. Leave it out everywhere in a list to keep the listed order. |
| `requires` | `{ "level": 80, "maxLevel": 90, "quests": [12345], "chromieTime": 8 }`, every part optional. |
| `faction` | `"alliance"` or `"horde"` to show it to one faction only. |
| `unavailable` | `true` when the content is no longer in the game. |

Stories hold `chapters`; chapters hold `steps`.

**Step types**

| `type` | Extra fields |
|---|---|
| `"quest"` | `questID` |
| `"questline"` | `questLineID` |
| `"dungeon"` | `name`, optional `questID` (done when that quest is done) |
| `"achievement"` | `achievementID` |
| `"visit"` | `mapID`, `x`, `y` (map coordinates as shown in game, 0 to 100) |
| `"note"` | none: just `title` and/or `description` |

Quests can also say where they start, when the automatic answer is not good enough:

```json
"start": { "type": "npc", "npc": "Lor'themar Theron", "mapID": 2424, "x": 52.5, "y": 88.2 }
```

`start.type` is one of `"npc"`, `"location"`, `"item"` (starts from an item), `"followup"` (given by the previous quest) or `"auto"` (pops up by itself in an area).
