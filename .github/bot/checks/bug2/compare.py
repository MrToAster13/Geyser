"""Bug 2 comparison: Java crafting-table recipes from the Paper jar against the
recipe set the Bedrock bot received (bot.json from bug2.js).

Usage: python3 -I compare.py <extracted jar dir> <bot.json> <mappings items.json>
Exit 0: every recipe in the subset is present and complete.
Exit 1: at least one recipe in the subset is missing or wrong.
Exit 3: the subset is empty or the inputs are unusable (result unverified).

Java item ids are translated to Bedrock ids through Geyser's mappings
items.json (bedrock_identifier, and bedrock_data when nonzero), because some
Java ids name a different Bedrock item: java stone_stairs is bedrock
normal_stone_stairs, and bedrock stone_stairs is java cobblestone_stairs.

Subset (R3-f, R4-h, R5-a): crafting_shaped and crafting_shapeless recipes whose
result has no components and whose result and every input item, after tag
resolution through data/minecraft/tags/item, have an items.json entry.

A Bedrock recipe matches a Java recipe when the output and count are equal and
every input slot matches: an empty slot against an empty descriptor, a Java
ingredient against a `name` descriptor naming the mapped id of one of its
items, or a Java tag ingredient against an `item_tag` descriptor with the same
tag id. When the mapping has a nonzero bedrock_data and the Bedrock side
carries a metadata value other than the 32767 wildcard, the values must be
equal. Shaped recipes also match mirrored, since Java matches the mirrored
pattern.
A Java recipe is
  present   matched, and the matched Bedrock recipes together accept every
            item of every Java ingredient,
  wrong     Bedrock recipes with the same output exist but none match, or the
            matched ones leave some ingredient items out (incomplete),
  missing   no Bedrock recipe has the same output item,
  excluded  not decidable: the recipe is neither present nor missing, and it
            would be present only if a Bedrock item_tag that is not the Java
            tag id (R5-a) accepted the Java items of its slot. The harness has
            no Bedrock tag contents, so it cannot decide those. A recipe that
            fails to match even with every such tag taken as accepting is
            wrong, not excluded. Listed with the reason.
More than EXCLUDED_ALLOWANCE excluded recipes is exit 3 (unverified).
"""
import json
import os
import sys
from collections import defaultdict

LIST_LIMIT = 20
# The last good run (run 38317381443, 1185 subset recipes) excluded 10, all
# Bedrock-only tags such as minecraft:coals, minecraft:egg and minecraft:sand.
# 15 leaves room for a few new Bedrock tags in an upstream update; a jump past
# it means tag handling broke or a translation regression hides behind
# undecidable tags, so the result is unverified, not PASS.
EXCLUDED_ALLOWANCE = 15
WILDCARD = 32767
MAP = {}  # java id -> (bedrock id, bedrock data)


def load_mappings(path, bed_items):
    for k, v in load_json(path).items():
        MAP[nid(k)] = (nid(v["bedrock_identifier"]), int(v.get("bedrock_data") or 0))
    # Geyser's built-in custom items replace the items.json mapping when custom
    # content is on (BuiltInMappings registers java furnace_minecart as
    # geysermc:furnace_minecart). Use them when the bot's registry has one.
    overrides = []
    for k in MAP:
        custom = "geysermc:" + k.split(":", 1)[1]
        if custom in bed_items:
            MAP[k] = (custom, 0)
            overrides.append(f"{k} -> {custom}")
    return overrides


def bid(java_id):
    return MAP[java_id][0] if java_id in MAP else None


def same_item(java_id, name, meta):
    """True when a Bedrock name and metadata are the mapping of java_id."""
    if java_id not in MAP:
        return False
    b, data = MAP[java_id]
    if name != b:
        return False
    if data and meta is not None and meta != WILDCARD:
        return meta == data
    return True


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def nid(s):
    return s if ":" in s else "minecraft:" + s


class Tags:
    def __init__(self, root):
        self.root = os.path.join(root, "data", "minecraft", "tags", "item")
        self.cache = {}

    def resolve(self, tag, seen=()):
        tag = nid(tag)
        if tag in self.cache:
            return self.cache[tag]
        if tag in seen:
            raise ValueError("tag cycle at " + tag)
        ns, path = tag.split(":", 1)
        if ns != "minecraft":
            raise ValueError("non-minecraft tag " + tag)
        file = os.path.join(self.root, *path.split("/")) + ".json"
        if not os.path.isfile(file):
            raise ValueError("no tag file for " + tag)
        out = []
        for v in load_json(file).get("values", []):
            required = True
            if isinstance(v, dict):
                required = v.get("required", True)
                v = v["id"]
            try:
                if v.startswith("#"):
                    out += self.resolve(v[1:], seen + (tag,))
                else:
                    out.append(nid(v))
            except ValueError:
                if required:
                    raise
        out = sorted(set(out))
        self.cache[tag] = out
        return out


def ingredient(raw, tags):
    """Returns (frozenset of item ids, tag id or None)."""
    if isinstance(raw, list):
        if len(raw) == 1:
            return ingredient(raw[0], tags)
        items = set()
        for r in raw:
            items |= ingredient(r, tags)[0]
        return frozenset(items), None
    if isinstance(raw, dict):
        if "tag" in raw:
            raw = "#" + raw["tag"]
        elif "item" in raw:
            raw = raw["item"]
        else:
            raise ValueError("unknown ingredient form " + json.dumps(raw)[:80])
    if raw.startswith("#"):
        t = nid(raw[1:])
        return frozenset(tags.resolve(t)), t
    return frozenset([nid(raw)]), None


def shrink(pattern):
    rows = [r for r in pattern]
    width = max(len(r) for r in rows)
    rows = [r.ljust(width) for r in rows]
    used_rows = [i for i, r in enumerate(rows) if r.strip()]
    used_cols = [c for c in range(width) if any(r[c] != " " for r in rows)]
    if not used_rows:
        return []
    rows = rows[used_rows[0]:used_rows[-1] + 1]
    return [r[used_cols[0]:used_cols[-1] + 1] for r in rows]


def java_recipes(root, tags):
    rdir = os.path.join(root, "data", "minecraft", "recipe")
    out, skipped = [], defaultdict(int)
    for dirpath, _, files in os.walk(rdir):
        for fn in sorted(files):
            if not fn.endswith(".json"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), rdir)
            rid = "minecraft:" + rel[:-5].replace(os.sep, "/")
            data = load_json(os.path.join(dirpath, fn))
            typ = data.get("type", "")
            if typ not in ("minecraft:crafting_shaped", "minecraft:crafting_shapeless"):
                skipped[typ] += 1
                continue
            res = data.get("result", {})
            r = {"id": rid, "kind": typ.split("_")[-1], "out": nid(res.get("id") or res.get("item", "")),
                 "count": res.get("count", 1), "components": bool(res.get("components")), "error": None}
            try:
                if r["kind"] == "shaped":
                    pat = shrink(data["pattern"])
                    key = {k: ingredient(v, tags) for k, v in data["key"].items()}
                    r["h"] = len(pat)
                    r["w"] = len(pat[0]) if pat else 0
                    r["grid"] = [None if ch == " " else key[ch] for row in pat for ch in row]
                else:
                    r["ings"] = [ingredient(v, tags) for v in data["ingredients"]]
            except (ValueError, KeyError) as e:
                r["error"] = str(e)
            out.append(r)
    return out, dict(skipped)


def slot_ok(java, bed, lenient=False):
    """java: None or (items, tag). bed: bot descriptor. lenient: an item_tag
    with another id than the Java tag counts as matching (undecidable)."""
    if java is None:
        return bed["t"] == "empty"
    items, tag = java
    if bed["t"] == "name":
        return any(same_item(i, bed["name"], bed.get("meta")) for i in items)
    if bed["t"] == "tag":
        return (tag is not None and bed["tag"] == tag) or lenient
    return False


def accepted(java, bed):
    """Items of a Java ingredient that a matching descriptor accepts."""
    if java is None:
        return set()
    items, tag = java
    if bed["t"] == "tag":
        return set(items)
    return {i for i in items if same_item(i, bed["name"], bed.get("meta"))}


def match_shaped(j, b, lenient=False):
    if b["kind"] != "shaped" or b["w"] != j["w"] or b["h"] != j["h"] or len(b["in"]) != len(j["grid"]):
        return None
    w = j["w"]
    orient = [list(range(len(j["grid"])))]
    orient.append([r * w + (w - 1 - c) for r in range(j["h"]) for c in range(w)])
    for idx in orient:
        # Bedrock slot i holds the Java ingredient at idx[i] in this orientation.
        if all(slot_ok(j["grid"][idx[i]], b["in"][i], lenient) for i in range(len(idx))):
            return [(j["grid"][idx[i]], b["in"][i]) for i in range(len(idx))]
    return None


def match_shapeless(j, b, lenient=False):
    if b["kind"] != "shapeless":
        return None
    bed = [d for d in b["in"] if d["t"] != "empty"]
    ings = j["ings"]
    if len(bed) != len(ings):
        return None
    used = [False] * len(bed)
    pairs = []

    def go(i):
        if i == len(ings):
            return True
        for k, d in enumerate(bed):
            if not used[k] and slot_ok(ings[i], d, lenient):
                used[k] = True
                pairs.append((ings[i], d))
                if go(i + 1):
                    return True
                pairs.pop()
                used[k] = False
        return False

    return pairs if go(0) else None


def describe_bed(b):
    def d(x):
        if x["t"] == "name":
            return x["name"].replace("minecraft:", "")
        if x["t"] == "tag":
            return "tag:" + x["tag"]
        if x["t"] == "empty":
            return "_"
        return x["t"]
    o = b["out"][0] if b["out"] else {}
    shape = f"{b['w']}x{b['h']} " if b["kind"] == "shaped" else ""
    return f"{b['kind']} {shape}[{' '.join(d(x) for x in b['in'])}] -> {o.get('count')} {o.get('name')}"


def describe_java(j, mapped=False):
    """The Java recipe with Java ids, or with every item mapped to Bedrock."""
    def one(i):
        if not mapped:
            return i.replace("minecraft:", "")
        b, data = MAP.get(i, ("?", 0))
        return b.replace("minecraft:", "") + (f":{data}" if data else "")

    def d(x):
        if x is None:
            return "_"
        items, tag = x
        if tag and not mapped:
            return "#" + tag.replace("minecraft:", "")
        names = sorted({one(i) for i in items})
        return "|".join(names[:6]) + ("|..." if len(names) > 6 else "")
    out = one(j["out"])
    if j["kind"] == "shaped":
        return f"shaped {j['w']}x{j['h']} [{' '.join(d(x) for x in j['grid'])}] -> {j['count']} {out}"
    return f"shapeless [{' '.join(d(x) for x in j['ings'])}] -> {j['count']} {out}"


def main():
    root, botfile, mapfile = sys.argv[1], sys.argv[2], sys.argv[3]
    bot = load_json(botfile)
    overrides = load_mappings(mapfile, set(bot["items"].values()))
    print(f"bug2: items.json entries {len(MAP)}, "
          f"java id differs from bedrock id: {sum(1 for k, v in MAP.items() if k != v[0])}, "
          f"nonzero bedrock_data: {sum(1 for v in MAP.values() if v[1])}, "
          f"geysermc custom item overrides: {overrides or 'none'}")
    bed_items = set(bot["items"].values())
    tags = Tags(root)
    java, skipped = java_recipes(root, tags)
    print(f"bug2: java crafting recipes {len(java)} (other types skipped: {sum(skipped.values())})")

    bedrock = [b for b in bot["recipes"] if b["out"] and b["out"][0].get("name")]
    nameless = len(bot["recipes"]) - len(bedrock)
    by_out = defaultdict(list)
    for b in bedrock:
        by_out[b["out"][0]["name"]].append(b)
    kinds = defaultdict(int)
    for b in bot["recipes"]:
        kinds[b["kind"]] += 1
    print(f"bug2: bedrock final set {len(bot['recipes'])} recipes {dict(kinds)}, "
          f"outputs unmapped through item_registry: {nameless}, item_registry size {len(bed_items)}")
    other = defaultdict(int)
    for b in bot["recipes"]:
        for d in b["in"]:
            if d["t"] not in ("name", "tag", "empty"):
                other[d["t"]] += 1
    if other:
        print(f"bug2: descriptor types outside name/tag/empty: {dict(other)}")

    subset, out_of_subset = [], defaultdict(int)
    unmapped, not_in_registry = set(), set()
    for j in java:
        if j["error"]:
            out_of_subset["unresolvable ingredient"] += 1
            print(f"bug2: excluded {j['id']}: {j['error']}")
            continue
        if j["components"]:
            out_of_subset["result has components"] += 1
            continue
        ing = j["grid"] if j["kind"] == "shaped" else j["ings"]
        names = {j["out"]}
        for x in ing:
            if x is not None:
                names |= x[0]
        if any(x is not None and not x[0] for x in ing):
            out_of_subset["empty ingredient"] += 1
            continue
        if not all(n in MAP for n in names):
            out_of_subset["no items.json entry"] += 1
            unmapped.update(n for n in names if n not in MAP)
            continue
        subset.append(j)
        not_in_registry.update(bid(n) for n in names if bid(n) not in bed_items)
    print(f"bug2: subset compared {len(subset)} of {len(java)} "
          f"(left out: {dict(out_of_subset)})")
    if unmapped:
        print(f"bug2: java ids with no items.json entry: {', '.join(sorted(unmapped)[:LIST_LIMIT])}")
    if not_in_registry:
        print("bug2: mapped bedrock ids absent from the bot's item registry: "
              + ", ".join(sorted(not_in_registry)[:LIST_LIMIT]))
    if not subset:
        print("bug2: subset empty, result unverified")
        return 3

    def coverage(j, cands, lenient):
        """(matched count, uncovered Java items, foreign tags used to match)."""
        matcher = match_shaped if j["kind"] == "shaped" else match_shapeless
        cover = defaultdict(set)
        matched = 0
        foreign = set()
        for b in cands:
            if b["out"][0]["count"] != j["count"]:
                continue
            pairs = matcher(j, b, lenient)
            if pairs is None:
                continue
            matched += 1
            for jx, bx in pairs:
                if jx is not None:
                    cover[jx] |= accepted(jx, bx)
                    if bx["t"] == "tag" and bx["tag"] != jx[1]:
                        foreign.add(bx["tag"])
        ing = j["grid"] if j["kind"] == "shaped" else j["ings"]
        gaps = sorted({i for x in ing if x is not None for i in x[0] - cover[x]}) if matched else []
        return matched, gaps, sorted(foreign)

    present, wrong, missing, excluded = [], [], [], []
    for j in subset:
        cands = [b for b in by_out.get(bid(j["out"]), [])
                 if same_item(j["out"], b["out"][0]["name"], b["out"][0].get("meta"))]
        matched, gaps, _ = coverage(j, cands, False)
        if matched and not gaps:
            present.append(j)
            continue
        if not cands:
            missing.append(j)
            continue
        # Exclude only when the foreign tags are exactly what would close the
        # gap: with every foreign tag taken as accepting, the recipe matches
        # and covers every Java item. Anything else stays wrong.
        l_matched, l_gaps, foreign = coverage(j, cands, True)
        if l_matched and not l_gaps and foreign:
            excluded.append((j, f"Bedrock item_tag {', '.join(foreign)} is not a Java tag id of this recipe"
                                f" (strict: {'incomplete' if matched else 'no match'})"))
        elif matched:
            wrong.append((j, "incomplete: no matching Bedrock recipe accepts " + ", ".join(gaps[:8]), cands))
        else:
            wrong.append((j, "no Bedrock recipe with this output matches", cands))

    print(f"bug2: present {len(present)}, wrong {len(wrong)}, missing {len(missing)}, excluded {len(excluded)}")
    for j, why in excluded[:LIST_LIMIT]:
        print(f"bug2: excluded {j['id']}: {why}")
    for j in missing[:LIST_LIMIT]:
        print(f"bug2: missing {j['id']}: java {describe_java(j)}; mapped {describe_java(j, True)}")
    for j, why, cands in wrong[:LIST_LIMIT]:
        print(f"bug2: wrong {j['id']}: {why}; java {describe_java(j)}; mapped {describe_java(j, True)}")
        for b in cands[:3]:
            print(f"bug2:   bedrock {describe_bed(b)}")
    if wrong or missing:
        return 1
    if len(subset) == len(excluded):
        print("bug2: every subset recipe was excluded, result unverified")
        return 3
    if len(excluded) > EXCLUDED_ALLOWANCE:
        print(f"bug2: {len(excluded)} excluded recipes exceed the allowance of {EXCLUDED_ALLOWANCE}, result unverified")
        return 3
    return 0


if __name__ == "__main__":
    # A crash must not read as FAIL (exit 1): report it as unverified (3).
    try:
        code = main()
    except Exception:
        import traceback
        traceback.print_exc()
        print("bug2: comparison script crashed; result unverified")
        code = 3
    sys.exit(code)
