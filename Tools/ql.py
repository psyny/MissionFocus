"""Questline lookup from wago.tools tables (+ quest names from BtWQuests' data).
Usage: python -I -X utf8 ql.py <questLineID | "name text"> ..."""
import sys, os, csv, re, json

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)            # MissionFocus
ROOT = os.path.dirname(ADDON)            # wowAddons (ReferenceAddons lives there)
REF = os.path.join(ROOT, "ReferenceAddons")

lines = {}
with open(os.path.join(HERE, "wago", "QuestLine.csv"), encoding="utf-8") as f:
    for row in csv.DictReader(f):
        lines[int(row["ID"])] = row
members = {}
with open(os.path.join(HERE, "wago", "QuestLineXQuest.csv"), encoding="utf-8") as f:
    for row in csv.DictReader(f):
        members.setdefault(int(row["QuestLineID"]), []).append((int(row["OrderIndex"]), int(row["QuestID"])))

# Quest names from every BtWQuests Database/Quests.lua (and Prologue Quests.lua).
names = {}
pattern = re.compile(r'\[(\d+)\] = \{\s*name = "((?:[^"\\]|\\.)*)"')
for d in os.listdir(REF):
    for rel in ("Database/Quests.lua", "Quests.lua"):
        path = os.path.join(REF, d, rel)
        if os.path.exists(path):
            text = open(path, encoding="utf-8", errors="replace").read()
            for m in pattern.finditer(text):
                names.setdefault(int(m.group(1)), m.group(2).replace('\\"', '"').replace("\\'", "'"))

# Which BtW chain lists a quest (needs btw_chains.json from the private MissionFocusTools
# folder next to MissionFocus; skipped when it is not there).
quest_chain = {}
chains_path = os.path.join(ROOT, "MissionFocusTools", "btw_chains.json")
if os.path.exists(chains_path):
    for c in json.load(open(chains_path, encoding="utf-8")):
        for it in c["items"]:
            for q in ([it.get("id")] if it.get("type") == "quest" else []) + (it.get("ids") or []):
                if isinstance(q, int):
                    quest_chain.setdefault(q, c["id"])


def show(lid):
    row = lines.get(lid)
    print(f"== questline {lid}: {row['Name_lang'] if row else '?'}")
    for order, qid in sorted(members.get(lid, [])):
        chain = quest_chain.get(qid)
        print(f"   {order:3d}  {qid:6d}  {names.get(qid, '?')}" + (f"   [btw chain {chain}]" if chain else ""))


for arg in sys.argv[1:]:
    if arg.isdigit():
        show(int(arg))
    else:
        for lid, row in sorted(lines.items()):
            if arg.lower() in row["Name_lang"].lower():
                print(f"{lid}: {row['Name_lang']}  ({len(members.get(lid, []))} quests)")
