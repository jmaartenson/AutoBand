#!/usr/bin/env python3
r"""
Poll the Return of Reckoning online list and write a BuildTableFromCSV-friendly
realm-rank snapshot for AutoBand.

Behavior:
- Fetches online character list from
  https://api.returnofreckoning.com/stats/online_list_new.php?realm_id=<id>
- Parses live payload fields.
- Writes a BuildTableFromCSV-friendly CSV snapshot.
- Writes a metadata row (`ID=1`) with `GeneratedUtc`, `GeneratedEpochMs`, `Source`, and `Stats*`.
- Character rows start at `ID=2` and contain only per-character fields.
- Rewrites CSV only if the online-list snapshot changed since last poll.
- When unchanged, the previous CSV is left untouched (metadata timestamp does not advance).
- Runs once (`--once`) or as a repeating poll loop.

Default output target is `AutoBand_RealmRank.csv`.
For live client usage, pass `--output-csv` to the game's AddOns path.

Requirements:
- Python 3.8+
- Dependency: `cloudscraper`

Dependency install quick reference:
- Linux/macOS/WSL:
  - User install: `python3 -m pip install --user cloudscraper`
  - Venv install: `python3 -m pip install cloudscraper`
- Windows PowerShell:
  - User install: `py -3 -m pip install --user cloudscraper`
  - Venv install: `py -3 -m pip install cloudscraper`
- Windows CMD:
  - User install: `py -3 -m pip install --user cloudscraper`
  - Venv install: `py -3 -m pip install cloudscraper`

Examples:
- Linux/macOS/WSL:
  - One-shot:   `python3 autoband_realmrank_poller.py --once`
  - Continuous: `python3 autoband_realmrank_poller.py --poll-seconds 60`
- Windows PowerShell:
  - One-shot:   `py -3 .\autoband_realmrank_poller.py --once`
  - Continuous: `py -3 .\autoband_realmrank_poller.py --poll-seconds 60`
- Windows CMD:
  - One-shot:   `py -3 autoband_realmrank_poller.py --once`
  - Continuous: `py -3 autoband_realmrank_poller.py --poll-seconds 60`

Helper:
- `--deps-help` prints dependency/install guidance and exits.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import math
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple


API_URL_TEMPLATE = "https://api.returnofreckoning.com/stats/online_list_new.php?realm_id={realm_id}"
DEFAULT_REALMS = (1,)
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_POLL_SECONDS = 60

CSV_HEADERS = [
    "ID",
    "NameLower",
    "RenownRank",
    "Level",
    "CareerLine",
    "CareerName",
    "CareerIcon",
    "Faction",
    "Role",
    "RealmId",
    "CharacterId",
    "Race",
    "Sex",
    "GeneratedUtc",
    "GeneratedEpochMs",
    "Source",
    "StatsOrderCount",
    "StatsDestroCount",
    "StatsTotalCount",
    "StatsOrderPct",
    "StatsDestroPct",
    "StatsT1OrderCount",
    "StatsT1DestroCount",
    "StatsT1TotalCount",
    "StatsT1OrderPct",
    "StatsT1DestroPct",
    "StatsT2PlusOrderCount",
    "StatsT2PlusDestroCount",
    "StatsT2PlusTotalCount",
    "StatsT2PlusOrderPct",
    "StatsT2PlusDestroPct",
]

CSV_STATS_FIELDS = (
    "StatsOrderCount",
    "StatsDestroCount",
    "StatsTotalCount",
    "StatsOrderPct",
    "StatsDestroPct",
    "StatsT1OrderCount",
    "StatsT1DestroCount",
    "StatsT1TotalCount",
    "StatsT1OrderPct",
    "StatsT1DestroPct",
    "StatsT2PlusOrderCount",
    "StatsT2PlusDestroCount",
    "StatsT2PlusTotalCount",
    "StatsT2PlusOrderPct",
    "StatsT2PlusDestroPct",
)

INTEGER_RE = re.compile(r"-?\d+")
ANCHOR_TEXT_RE = re.compile(r">\s*([^<]+?)\s*<")
RACE_IMG_RE = re.compile(r"/races/(\d+)\.png")
IMG_ALT_RE = re.compile(r"""alt=["']([^"']+)["']""", re.IGNORECASE)
CAREER_KEY_NORMALIZE_RE = re.compile(r"[^A-Z0-9]+")
TIER1_MAX_LEVEL = 15
CSV_SCHEMA_SIGNATURE_VERSION = "v2"

# Canonical in-client CareerLine ids used by AutoBand (Lua/GameData.CareerLine).
# We derive these from CareerLine image alt text first to avoid API image-id drift.
CAREER_KEY_TO_CANONICAL_ID = {
    "ENGINEER": 1,
    "BRIGHT_WIZARD": 2,
    "SORCERER": 3,
    "SQUIG_HERDER": 4,
    "MAGUS": 5,
    "SHADOW_WARRIOR": 6,
    "WITCH_ELF": 7,
    "WHITE_LION": 8,
    "SLAYER": 9,
    "WITCH_HUNTER": 10,
    "CHOPPA": 11,
    "MARAUDER": 12,
    "IRON_BREAKER": 13,
    "CHOSEN": 14,
    "BLACK_ORC": 15,
    "KNIGHT": 16,
    "KNIGHT_OF_THE_BLAZING_SUN": 16,
    "SWORDMASTER": 17,
    "SWORD_MASTER": 17,
    "BLACK_GUARD": 18,
    "ZEALOT": 19,
    "WARRIOR_PRIEST": 20,
    "RUNE_PRIEST": 21,
    "ARCHMAGE": 22,
    "SHAMAN": 23,
    "DISCIPLE": 24,
    "DISCIPLE_OF_KHAINE": 24,
    # Some sources omit separators in class names.
    "IRONBREAKER": 13,
    "BLACKGUARD": 18,
}

# Single source of truth for poller-authored class metadata consumed by addon.
# Side/faction classification should be derived from this map (not a second key set).
CANONICAL_CAREER_META_BY_ID: Dict[int, Dict[str, str]] = {
    1: {"name": "Engineer", "icon": "<icon20187>", "faction": "Order", "role": "rdps"},
    2: {"name": "Bright Wizard", "icon": "<icon20183>", "faction": "Order", "role": "rdps"},
    3: {"name": "Sorcerer", "icon": "<icon20196>", "faction": "Destruction", "role": "rdps"},
    4: {"name": "Squig Herder", "icon": "<icon20197>", "faction": "Destruction", "role": "rdps"},
    5: {"name": "Magus", "icon": "<icon20191>", "faction": "Destruction", "role": "rdps"},
    6: {"name": "Shadow Warrior", "icon": "<icon20194>", "faction": "Order", "role": "rdps"},
    7: {"name": "Witch Elf", "icon": "<icon20201>", "faction": "Destruction", "role": "mdps"},
    8: {"name": "White Lion", "icon": "<icon20200>", "faction": "Order", "role": "mdps"},
    9: {"name": "Slayer", "icon": "<icon20188>", "faction": "Order", "role": "mdps"},
    10: {"name": "Witch Hunter", "icon": "<icon20202>", "faction": "Order", "role": "mdps"},
    11: {"name": "Choppa", "icon": "<icon20184>", "faction": "Destruction", "role": "mdps"},
    12: {"name": "Marauder", "icon": "<icon20192>", "faction": "Destruction", "role": "mdps"},
    13: {"name": "Ironbreaker", "icon": "<icon20189>", "faction": "Order", "role": "tank"},
    14: {"name": "Chosen", "icon": "<icon20185>", "faction": "Destruction", "role": "tank"},
    15: {"name": "Black Orc", "icon": "<icon20182>", "faction": "Destruction", "role": "tank"},
    16: {"name": "Knight of the Blazing Sun", "icon": "<icon20190>", "faction": "Order", "role": "tank"},
    17: {"name": "Swordmaster", "icon": "<icon20198>", "faction": "Order", "role": "tank"},
    18: {"name": "Black Guard", "icon": "<icon20181>", "faction": "Destruction", "role": "tank"},
    19: {"name": "Zealot", "icon": "<icon20203>", "faction": "Destruction", "role": "healer"},
    20: {"name": "Warrior Priest", "icon": "<icon20199>", "faction": "Order", "role": "healer"},
    21: {"name": "Rune Priest", "icon": "<icon20193>", "faction": "Order", "role": "healer"},
    22: {"name": "Archmage", "icon": "<icon20180>", "faction": "Order", "role": "healer"},
    23: {"name": "Shaman", "icon": "<icon20195>", "faction": "Destruction", "role": "healer"},
    24: {"name": "Disciple", "icon": "<icon20186>", "faction": "Destruction", "role": "healer"},
}

DEPENDENCY_HELP_TEXT = """\
AutoBand realm-rank poller dependency setup:

Required:
- Python 3.8+
- cloudscraper

Install cloudscraper:
- Linux/macOS/WSL:
  - python3 -m pip install --user cloudscraper
  - or inside venv: python3 -m pip install cloudscraper
- Windows PowerShell:
  - py -3 -m pip install --user cloudscraper
  - or inside venv: py -3 -m pip install cloudscraper
- Windows CMD:
  - py -3 -m pip install --user cloudscraper
  - or inside venv: py -3 -m pip install cloudscraper

Quick checks:
- Linux/macOS/WSL: python3 -c "import cloudscraper; print(cloudscraper.__version__)"
- Windows:         py -3 -c "import cloudscraper; print(cloudscraper.__version__)"
"""


def now_utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def now_utc_display() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def log_info(message: str, quiet: bool = False) -> None:
    if quiet:
        return
    print("[autoband-rr " + now_utc_iso() + "] " + message)


def log_error(message: str) -> None:
    print("[autoband-rr " + now_utc_iso() + "] ERROR: " + message, file=sys.stderr)


def print_dependency_help() -> None:
    print(DEPENDENCY_HELP_TEXT)


def create_scraper() -> Any:
    try:
        import cloudscraper  # type: ignore
    except Exception as exc:
        raise RuntimeError(
            "missing dependency 'cloudscraper' (install with pip, see --deps-help). import error: " + str(exc)
        ) from exc
    return cloudscraper.create_scraper()


def to_int(value: Any) -> Optional[int]:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        if not math.isfinite(number):
            return None
        return int(number)

    text = str(value).strip()
    if not text:
        return None

    match = INTEGER_RE.search(text)
    if not match:
        return None

    try:
        return int(match.group(0))
    except ValueError:
        return None


def parse_name(value: Any) -> Optional[str]:
    if value is None:
        return None

    text = str(value).strip()
    if not text:
        return None

    anchor_match = ANCHOR_TEXT_RE.search(text)
    if anchor_match:
        text = anchor_match.group(1)
    else:
        text = re.sub(r"<[^>]*>", "", text)

    text = html.unescape(text).strip()
    if not text:
        return None
    return text


def parse_img_id(value: Any, img_pattern: re.Pattern[str]) -> Optional[int]:
    if value is None:
        return None

    text = str(value)
    match = img_pattern.search(text)
    if match:
        try:
            return int(match.group(1))
        except ValueError:
            return None

    return to_int(text)


def parse_img_alt(value: Any) -> Optional[str]:
    if value is None:
        return None

    text = str(value)
    match = IMG_ALT_RE.search(text)
    if not match:
        return None

    parsed = html.unescape(match.group(1)).strip()
    return parsed or None


def normalize_career_key(name: Any) -> Optional[str]:
    if name is None:
        return None

    text = str(name).strip().upper()
    if not text:
        return None

    normalized = CAREER_KEY_NORMALIZE_RE.sub("_", text).strip("_")
    return normalized or None


def parse_online_row_side_from_html(career_line_html: Any) -> Optional[str]:
    # Keep realm-side stats aligned with the same canonical metadata that powers
    # per-row CSV fields.
    meta = canonical_career_meta_from_html(career_line_html)
    faction = str(meta.get("Faction") or "").strip().lower()
    if faction == "order":
        return "order"
    if faction == "destruction":
        return "destro"
    return None


def canonical_career_meta_from_html(career_line_html: Any) -> Dict[str, Any]:
    key = normalize_career_key(parse_img_alt(career_line_html))
    if not key:
        return {}

    canonical_id = CAREER_KEY_TO_CANONICAL_ID.get(key)
    if canonical_id is None:
        return {}

    meta = CANONICAL_CAREER_META_BY_ID.get(canonical_id) or {}
    return {
        "CareerLine": canonical_id,
        "CareerName": meta.get("name") or "",
        "CareerIcon": meta.get("icon") or "",
        "Faction": meta.get("faction") or "",
        "Role": meta.get("role") or "",
    }


def parse_online_row(row: Mapping[str, Any]) -> Optional[Dict[str, Any]]:
    name = parse_name(row.get("Name"))
    rr = to_int(row.get("RenownRank"))
    if not name or rr is None:
        return None
    name_lower = name.lower()

    level = to_int(row.get("Level"))
    realm_id = to_int(row.get("RealmId"))
    character_id = to_int(row.get("CharacterId"))
    sex = to_int(row.get("Sex"))
    career_line_html = row.get("CareerLine")
    career_meta = canonical_career_meta_from_html(career_line_html)
    race = parse_img_id(row.get("Race"), RACE_IMG_RE)

    career_line = career_meta.get("CareerLine")
    career_name = str(career_meta.get("CareerName") or "").strip()
    career_icon = str(career_meta.get("CareerIcon") or "").strip()
    faction = str(career_meta.get("Faction") or "").strip()
    role = str(career_meta.get("Role") or "").strip()

    # Keep CSV rows complete for addon consumers: if required data is missing,
    # skip the row entirely instead of writing partial fields.
    if level is None or level <= 0:
        return None
    if character_id is None or character_id <= 0:
        return None
    if career_line is None or int(career_line) <= 0:
        return None
    if not career_name or not faction or not role:
        return None

    return {
        "NameLower": name_lower,
        "RenownRank": rr,
        "Level": level,
        "CareerLine": int(career_line),
        "CareerName": career_name,
        "CareerIcon": career_icon,
        "Faction": faction,
        "Role": role,
        "RealmId": realm_id,
        "CharacterId": character_id,
        "Race": race,
        "Sex": sex,
    }


def choose_preferred(existing: Dict[str, Any], candidate: Dict[str, Any]) -> Dict[str, Any]:
    current_rr = int(existing.get("RenownRank") or 0)
    candidate_rr = int(candidate.get("RenownRank") or 0)
    if candidate_rr > current_rr:
        return candidate
    if candidate_rr < current_rr:
        return existing

    current_level = int(existing.get("Level") or 0)
    candidate_level = int(candidate.get("Level") or 0)
    if candidate_level > current_level:
        return candidate
    if candidate_level < current_level:
        return existing

    current_char = int(existing.get("CharacterId") or 0)
    candidate_char = int(candidate.get("CharacterId") or 0)
    if candidate_char >= current_char:
        return candidate
    return existing


def fetch_realm_payload(scraper: Any, realm_id: int, timeout_seconds: float) -> List[Mapping[str, Any]]:
    url = API_URL_TEMPLATE.format(realm_id=realm_id)
    response = scraper.get(url, timeout=timeout_seconds)
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, list):
        raise RuntimeError("unexpected payload type for realm " + str(realm_id) + ": " + str(type(payload)))
    return payload


def build_records(
    payloads: Sequence[Tuple[int, Sequence[Mapping[str, Any]]]]
) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    records_by_name: Dict[str, Dict[str, Any]] = {}
    stats = {
        "raw_rows": 0,
        "parsed_rows": 0,
        "skipped_rows": 0,
    }

    for _, payload in payloads:
        for row in payload:
            stats["raw_rows"] += 1
            if not isinstance(row, Mapping):
                stats["skipped_rows"] += 1
                continue
            parsed = parse_online_row(row)
            if parsed is None:
                stats["skipped_rows"] += 1
                continue

            key = str(parsed["NameLower"])
            existing = records_by_name.get(key)
            if existing is None:
                records_by_name[key] = parsed
            else:
                records_by_name[key] = choose_preferred(existing, parsed)
            stats["parsed_rows"] += 1

    records = list(records_by_name.values())
    records.sort(key=lambda item: str(item.get("NameLower") or ""))
    return records, stats


def build_signature(records: Sequence[Mapping[str, Any]]) -> str:
    digest = hashlib.sha1()
    digest.update(CSV_SCHEMA_SIGNATURE_VERSION.encode("utf-8", errors="ignore"))
    digest.update(b"\n")
    for row in records:
        line = "|".join(
            [
                str(row.get("NameLower") or ""),
                str(row.get("RenownRank") or ""),
                str(row.get("Level") or ""),
                str(row.get("CareerLine") or ""),
                str(row.get("CareerName") or ""),
                str(row.get("CareerIcon") or ""),
                str(row.get("Faction") or ""),
                str(row.get("Role") or ""),
                str(row.get("RealmId") or ""),
                str(row.get("CharacterId") or ""),
                str(row.get("Race") or ""),
                str(row.get("Sex") or ""),
            ]
        )
        digest.update(line.encode("utf-8", errors="ignore"))
        digest.update(b"\n")
    return digest.hexdigest()


def build_population_stats(
    order_total: int,
    destro_total: int,
    t1_order: int,
    t1_destro: int,
    t2plus_order: int,
    t2plus_destro: int,
) -> Dict[str, Any]:
    def pct(part: int, total: int) -> float:
        if total <= 0:
            return 0.0
        return (float(part) * 100.0) / float(total)

    overall_total = order_total + destro_total
    t1_total = t1_order + t1_destro
    t2plus_total = t2plus_order + t2plus_destro
    return {
        "StatsOrderCount": order_total,
        "StatsDestroCount": destro_total,
        "StatsTotalCount": overall_total,
        "StatsOrderPct": f"{pct(order_total, overall_total):.2f}",
        "StatsDestroPct": f"{pct(destro_total, overall_total):.2f}",
        "StatsT1OrderCount": t1_order,
        "StatsT1DestroCount": t1_destro,
        "StatsT1TotalCount": t1_total,
        "StatsT1OrderPct": f"{pct(t1_order, t1_total):.2f}",
        "StatsT1DestroPct": f"{pct(t1_destro, t1_total):.2f}",
        "StatsT2PlusOrderCount": t2plus_order,
        "StatsT2PlusDestroCount": t2plus_destro,
        "StatsT2PlusTotalCount": t2plus_total,
        "StatsT2PlusOrderPct": f"{pct(t2plus_order, t2plus_total):.2f}",
        "StatsT2PlusDestroPct": f"{pct(t2plus_destro, t2plus_total):.2f}",
    }


def compute_population_stats_from_online_payload(
    payloads: Sequence[Tuple[int, Sequence[Mapping[str, Any]]]]
) -> Dict[str, Any]:
    order_total = 0
    destro_total = 0
    t1_order = 0
    t1_destro = 0
    t2plus_order = 0
    t2plus_destro = 0

    for _, payload in payloads:
        for row in payload:
            if not isinstance(row, Mapping):
                continue
            side = parse_online_row_side_from_html(row.get("CareerLine"))
            if side not in ("order", "destro"):
                continue
            level = to_int(row.get("Level"))
            # Mirror careers.py online-list bucketing: any level < 16 is T1.
            is_t1 = level is not None and level <= TIER1_MAX_LEVEL

            if side == "order":
                order_total += 1
                if is_t1:
                    t1_order += 1
                else:
                    t2plus_order += 1
            else:
                destro_total += 1
                if is_t1:
                    t1_destro += 1
                else:
                    t2plus_destro += 1

    return build_population_stats(
        order_total=order_total,
        destro_total=destro_total,
        t1_order=t1_order,
        t1_destro=t1_destro,
        t2plus_order=t2plus_order,
        t2plus_destro=t2plus_destro,
    )


def write_csv(
    path: Path,
    records: Sequence[Mapping[str, Any]],
    generated_utc: str,
    generated_epoch_ms: int,
    source: str,
    stats: Optional[Mapping[str, Any]] = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")

    with tmp_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        ignored = ["Ignored by BuildTableFromCSV"] + [""] * (len(CSV_HEADERS) - 1)
        writer.writerow(ignored)
        writer.writerow(CSV_HEADERS)

        # Keep generated/stat snapshot data in a single metadata row so player
        # rows stay compact and we avoid duplicating the same stats per character.
        row_id = 1
        metadata_row = {
            "ID": row_id,
            "GeneratedUtc": generated_utc,
            "GeneratedEpochMs": generated_epoch_ms,
            "Source": source,
        }
        if stats:
            for key in CSV_STATS_FIELDS:
                metadata_row[key] = stats.get(key, "")
        writer.writerow([metadata_row.get(column, "") for column in CSV_HEADERS])
        row_id += 1

        for record in records:
            row = {
                "ID": row_id,
                "NameLower": record.get("NameLower") or "",
                "RenownRank": record.get("RenownRank") if record.get("RenownRank") is not None else "",
                "Level": record.get("Level") if record.get("Level") is not None else "",
                "CareerLine": record.get("CareerLine") if record.get("CareerLine") is not None else "",
                "CareerName": record.get("CareerName") or "",
                "CareerIcon": record.get("CareerIcon") or "",
                "Faction": record.get("Faction") or "",
                "Role": record.get("Role") or "",
                "RealmId": record.get("RealmId") if record.get("RealmId") is not None else "",
                "CharacterId": record.get("CharacterId") if record.get("CharacterId") is not None else "",
                "Race": record.get("Race") if record.get("Race") is not None else "",
                "Sex": record.get("Sex") if record.get("Sex") is not None else "",
            }
            writer.writerow([row.get(column, "") for column in CSV_HEADERS])
            row_id += 1

    tmp_path.replace(path)


def parse_realm_ids(raw: str) -> List[int]:
    parts = [part.strip() for part in raw.split(",")]
    output: List[int] = []
    seen: Dict[int, bool] = {}
    for part in parts:
        if not part:
            continue
        try:
            value = int(part)
        except ValueError:
            raise ValueError("invalid realm id: " + part)
        if value <= 0:
            raise ValueError("realm id must be > 0: " + str(value))
        if not seen.get(value):
            seen[value] = True
            output.append(value)
    if not output:
        raise ValueError("no realm ids provided")
    return output


def poll_once(
    scraper: Any,
    realm_ids: Sequence[int],
    output_csv: Path,
    timeout_seconds: float,
    previous_signature: Optional[str],
    validate_only: bool,
    quiet: bool,
) -> str:
    payloads: List[Tuple[int, Sequence[Mapping[str, Any]]]] = []
    for realm_id in realm_ids:
        payload = fetch_realm_payload(scraper, realm_id=realm_id, timeout_seconds=timeout_seconds)
        payloads.append((realm_id, payload))

    records, stats = build_records(payloads)
    signature = build_signature(records)
    # Keep lookup rows deduped by character name, but stats should reflect the
    # raw online-list snapshot with side derived from CareerLine alt text.
    population_stats = compute_population_stats_from_online_payload(payloads)

    summary = (
        "realms="
        + ",".join(str(realm_id) for realm_id in realm_ids)
        + " raw="
        + str(stats["raw_rows"])
        + " parsed="
        + str(stats["parsed_rows"])
        + " skipped="
        + str(stats["skipped_rows"])
        + " unique="
        + str(len(records))
    )

    if validate_only:
        log_info("validate-only: " + summary, quiet=quiet)
        return signature

    changed = previous_signature != signature
    if changed:
        generated_utc = now_utc_display()
        generated_epoch_ms = int(time.time() * 1000)
        source = "online_list_new.php?realm_id=" + ",".join(str(realm_id) for realm_id in realm_ids)
        write_csv(
            output_csv,
            records,
            generated_utc=generated_utc,
            generated_epoch_ms=generated_epoch_ms,
            source=source,
            stats=population_stats,
        )
        log_info("csv updated: " + summary + " -> " + str(output_csv), quiet=quiet)
    else:
        log_info("no change: " + summary, quiet=quiet)

    return signature


def parse_args() -> argparse.Namespace:
    default_output = Path(__file__).resolve().with_name("AutoBand_RealmRank.csv")
    default_realms = ",".join(str(value) for value in DEFAULT_REALMS)
    parser = argparse.ArgumentParser(
        description="Poll online list and write AutoBand realm-rank CSV (BuildTableFromCSV format)."
    )
    parser.add_argument(
        "--output-csv",
        default=str(default_output),
        help="output CSV path (default: %(default)s)",
    )
    parser.add_argument(
        "--realms",
        default=default_realms,
        help="comma-separated realm ids to fetch (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="HTTP timeout in seconds (default: %(default)s)",
    )
    parser.add_argument(
        "--poll-seconds",
        type=int,
        default=DEFAULT_POLL_SECONDS,
        help="sleep interval between polls (default: %(default)s)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="run once and exit",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="fetch + parse + report live payload stats without writing CSV",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress non-error logs",
    )
    parser.add_argument(
        "--deps-help",
        action="store_true",
        help="print dependency/setup help and exit",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.deps_help:
        print_dependency_help()
        return 0

    try:
        realm_ids = parse_realm_ids(args.realms)
    except ValueError as exc:
        log_error(str(exc))
        return 2

    timeout_seconds = max(1.0, float(args.timeout))
    poll_seconds = max(1, int(args.poll_seconds))
    output_csv = Path(args.output_csv).expanduser().resolve()

    try:
        scraper = create_scraper()
    except RuntimeError as exc:
        log_error(str(exc))
        return 2

    previous_signature: Optional[str] = None
    while True:
        started_at = time.time()
        try:
            previous_signature = poll_once(
                scraper=scraper,
                realm_ids=realm_ids,
                output_csv=output_csv,
                timeout_seconds=timeout_seconds,
                previous_signature=previous_signature,
                validate_only=args.validate_only,
                quiet=args.quiet,
            )
        except Exception as exc:
            log_error(str(exc))

        if args.once:
            break

        elapsed = time.time() - started_at
        sleep_for = poll_seconds - elapsed
        if sleep_for < 1:
            sleep_for = 1
        time.sleep(sleep_for)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
