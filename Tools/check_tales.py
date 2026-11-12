"""Checks every built-in tale in ../default_tales with MissionFocus's own reader.
Reports: read warnings, duplicate step IDs, links to missing steps, main steps that only follow
optional ones, and quest / questline IDs unknown to BtWQuests and the game's questline tables.
Usage: python -I -X utf8 check_tales.py"""
import os, re, csv, json, glob
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)            # MissionFocus
ROOT = os.path.dirname(ADDON)            # wowAddons
REF = os.path.join(ROOT, "ReferenceAddons")

# Known IDs
questlines = set()
for row in csv.DictReader(open(os.path.join(HERE, "wago", "QuestLine.csv"), encoding="utf-8")):
    questlines.add(int(row["ID"]))
quests = set()
for row in csv.DictReader(open(os.path.join(HERE, "wago", "QuestLineXQuest.csv"), encoding="utf-8")):
    quests.add(int(row["QuestID"]))
pattern = re.compile(r'\[(\d+)\] = \{\s*name = ')
for d in os.listdir(REF) if os.path.isdir(REF) else []:
    for rel in ("Database/Quests.lua", "Quests.lua"):
        p = os.path.join(REF, d, rel)
        if os.path.exists(p):
            quests.update(int(m.group(1)) for m in pattern.finditer(open(p, encoding="utf-8", errors="replace").read()))
extra = os.path.join(HERE, "known_quests.json")   # optional: {questID: name} from other sources
if os.path.exists(extra):
    quests.update(int(k) for k in json.load(open(extra, encoding="utf-8")))

# MissionFocus's reader, with the few WoW functions it needs at load time stubbed.
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(r'''
local locale = setmetatable({}, { __index = function(_, k) return k end })
LibStub = function() return { GetLocale = function() return locale end } end
MissionFocus_Utils = { Call = function() return nil end, Debug = function() end, Print = function() end }
function time() return 0 end
MissionFocus_CoreTales = {}
MissionFocus = { db = { global = {}, char = {} } }
''')
for name in ("MissionFocus_JSON.lua", "MissionFocus_Tales.lua"):
    lua.execute(open(os.path.join(ADDON, name), encoding="utf-8").read())

total_problems = 0
for path in sorted(glob.glob(os.path.join(ADDON, "default_tales", "*.lua"))):
    lua.execute("MissionFocus_CoreTales = {}")
    lua.execute(open(path, encoding="utf-8").read())
    texts = lua.eval("MissionFocus_CoreTales")
    for i in range(1, len(texts) + 1):
        tale, warnings = lua.eval("function(t) local tale, w = MissionFocus_Tales:Parse(t) return tale, w end")(texts[i])
        problems = []
        if not tale:
            problems.append(f"not readable: {warnings}")
        else:
            problems += [f"read warning: {w}" for w in warnings.values()]
            data = json.loads(lua.eval("function(t) return MissionFocus_Tales:Export(t) end")(tale))
            seen, steps = set(), 0
            levels = data.get("stories") or [{"chapters": data.get("chapters", [])}]
            for story in levels:
                for chapter in story.get("chapters", []):
                    ids = {s["id"]: s for s in chapter.get("steps", [])}
                    for s in chapter.get("steps", []):
                        steps += 1
                        if s["id"] in seen:
                            problems.append(f"duplicate step id {s['id']}")
                        seen.add(s["id"])
                        prev = s.get("previous", [])
                        if any(p not in ids for p in prev):
                            problems.append(f"{chapter.get('title')}: {s['id']} links to a missing step")
                        if (s.get("role") != "optional" and prev and all(ids.get(p, {}).get("role") == "optional" for p in prev)
                                and any(ids.get(p, {}).get("type") != "note" for p in prev)):
                            problems.append(f"{chapter.get('title')}: {s['id']} only follows optional steps")
                        if s["type"] == "questline" and s["questLineID"] not in questlines:
                            problems.append(f"unknown questline {s['questLineID']}")
                        if s["type"] == "quest" and s["questID"] not in quests:
                            problems.append(f"quest {s['questID']} not in BtWQuests or the questline tables (check it)")
            print(f"{os.path.basename(path)}: '{data.get('title')}' v{data.get('version')} - {steps} steps")
        for p in problems:
            print("   ", p)
        total_problems += len(problems)
print("OK" if total_problems == 0 else f"{total_problems} problem(s)")
