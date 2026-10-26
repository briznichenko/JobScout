import re
import tomllib
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo


def load_config(path: Path) -> dict:
    with path.open("rb") as stream:
        config = tomllib.load(stream)
    required = {"profile", "scoring", "rules", "sources", "network", "report"}
    if missing := required - config.keys():
        raise ValueError(f"Missing configuration sections: {', '.join(sorted(missing))}")
    scoring = config["scoring"]
    weights = scoring["weights"]
    if set(weights) != {"role", "skills", "experience", "location", "communication", "seniority", "salary"}:
        raise ValueError("Scoring weights must define all seven components")
    if any(not isinstance(v, int) or v < 0 for v in weights.values()) or sum(weights.values()) != 100:
        raise ValueError("Scoring weights must be nonnegative integers summing to 100")
    if not 0 <= scoring["strong_threshold"] <= 100 or not 0 <= config["report"]["minimum_score"] <= 100:
        raise ValueError("Score thresholds must be between 0 and 100")
    for group in ("apple_titles", "support_titles", "technical_support", "remote", "ukraine", "negation", "optional", "required", "requirement_headings", "optional_headings", "section_endings", "phone", "seniority", "seniority_mismatch", "geography_uncertain", "work_format_uncertain", "commercial_required", "alternatives"):
        for pattern in config["rules"][group]:
            re.compile(pattern, re.I)
    for rule in config["rules"].get("hard", []):
        if rule["scope"] not in {"title", "lines", "requirements"}:
            raise ValueError(f"Invalid hard rule scope: {rule['scope']}")
        re.compile(rule["pattern"], re.I)
    for group in ("skills", "unsupported", "learning"):
        for rule in config["profile"][group]:
            re.compile(rule["pattern"], re.I)
    network = config["network"]
    if network["delay_seconds"] < 1 or network["timeout_seconds"] <= 0 or not 0 <= network["retries"] <= 3:
        raise ValueError("Use a delay >= 1s, a positive timeout, and 0–3 retries")
    if config["report"]["limit"] < 1:
        raise ValueError("Report limit must be positive")
    if scoring["skills_for_full_points"] <= 0 or scoring["minimum_description_length"] < 0:
        raise ValueError("Skill count must be positive and description length nonnegative")
    if scoring["missing_penalty"] < 0 or scoring["maximum_missing_penalty"] < 0:
        raise ValueError("Missing-skill penalties must be nonnegative")
    ZoneInfo(config["report"]["timezone"])
    names = [s["name"] for s in config["sources"]]
    if len(names) != len(set(names)):
        raise ValueError("Source names must be unique")
    for source in config["sources"]:
        if source["adapter"] not in {"dou", "djinni"}:
            raise ValueError(f"Unknown adapter: {source['adapter']}")
        if source["enabled"] and not source["urls"]:
            raise ValueError("Enabled sources require at least one feed URL")
        allowed = {"dou": {"category", "search"}, "djinni": {"primary_keyword", "all_keywords", "any_of_keywords", "search_type"}}
        for url in source["urls"]:
            unknown = parse_qs(urlsplit(url).query).keys() - allowed[source["adapter"]]
            if unknown:
                raise ValueError(f"Unsupported feed parameters for {source['adapter']}: {', '.join(sorted(unknown))}")
    return config
