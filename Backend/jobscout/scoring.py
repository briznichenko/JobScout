import re

from .model import Assessment, Vacancy


def matches(patterns: list[str], text: str) -> bool:
    return any(re.search(pattern, text, re.I) for pattern in patterns)


def requirement_lines(description: str, rules: dict) -> list[tuple[str, bool]]:
    state = "unknown"
    result = []
    for line in description.splitlines():
        if matches(rules["optional_headings"], line):
            state = "optional"
        elif matches(rules["requirement_headings"], line):
            state = "required"
        elif matches(rules["section_endings"], line):
            state = "unknown"
        negated = matches(rules["negation"], line)
        optional = state == "optional" or matches(rules["optional"], line)
        mandatory = not negated and not optional and (state == "required" or matches(rules["required"], line))
        result.append((line, mandatory))
    return result


def assess(job: Vacancy, config: dict) -> Assessment:
    rules, profile, scoring = config["rules"], config["profile"], config["scoring"]
    weights = scoring["weights"]
    text = "\n".join((job.title, job.location, job.description))
    lines = requirement_lines(text, rules)
    apple = matches(rules["apple_titles"], job.title)
    support = matches(rules["support_titles"], job.title)
    technical = matches(rules["technical_support"], job.description)
    result = Assessment(0, "review", "apple" if apple else "support" if support else "other")

    def points(component: str, fraction: float, reason: str):
        value = round(weights[component] * fraction)
        result.components[component] = value
        if value:
            result.positive.append(f"{component}: +{value}/{weights[component]} — {reason}")

    for rule in rules.get("hard", []):
        if not rule.get("enabled", True):
            continue
        candidates = [(job.title, True)] if rule["scope"] == "title" else lines
        for line, mandatory in candidates:
            if rule["scope"] == "requirements" and not mandatory:
                continue
            if rule["scope"] != "title" and (matches(rules["negation"], line) or matches(rules["optional"], line)):
                continue
            if re.search(rule["pattern"], line, re.I):
                result.rejected.append(f"{rule['id']}: {rule['reason']} | Evidence: {line}")
                break

    for skill in profile["unsupported"]:
        evidence = [line for line, mandatory in lines if mandatory and re.search(skill["pattern"], line, re.I)]
        if evidence:
            message = f"{skill['name']} required; no confirmed experience | Evidence: {evidence[0]}"
            result.missing.append(message)
            commercial_patterns = [pattern.replace("{skill}", f"(?:{skill['pattern']})") for pattern in rules["commercial_required"]]
            explicit_commercial = any(matches(commercial_patterns, line) and not matches(rules["alternatives"], line) for line in evidence)
            if skill.get("hard_reject", False) and explicit_commercial:
                result.rejected.append(f"mandatory_{skill['name'].lower().replace(' ', '_')}: {message}")
    points("role", 1 if apple else 0.75 if support and technical else 0.3 if support else 0,
           "Apple engineering title" if apple else "technical support title and investigation signals" if support and technical else "support title; technical scope unconfirmed")
    if not apple and not support:
        result.uncertainty.append("Role is outside configured title patterns; inspect manually")
    if support and not technical:
        result.uncertainty.append("Support role lacks clear investigation/API/debugging evidence")
    found = [s["name"] for s in profile["skills"] if re.search(s["pattern"], text, re.I)]
    points("skills", min(1, len(found) / scoring["skills_for_full_points"]), ", ".join(found) or "no confirmed skill overlap")
    for skill in profile["learning"]:
        if any(mandatory and re.search(skill["pattern"], line, re.I) for line, mandatory in lines):
            result.missing.append(f"{skill['name']}: required; portfolio/study evidence only, commercial depth unconfirmed")
    years = [int(m[1]) for line, mandatory in lines if mandatory for m in re.finditer(r"(?i)(\d{1,2})\s*\+?\s*(?:years?|рок\w*|рік)\s+(?:of\s+)?(?:commercial\s+|professional\s+|комерційн\w*\s+)?(?:experience|досвід\w*)", line)]
    if years:
        needed = max(years)
        gap = max(0, needed - profile["commercial_years"])
        points("experience", max(0, 1 - gap / 4), f"requires {needed} years; profile {profile['commercial_years']} commercial years")
        if gap:
            result.missing.append(f"Experience requirement exceeds profile by {gap} year(s)")
    else:
        points("experience", 0.5, "experience requirement unknown; neutral allocation")
        result.uncertainty.append("Minimum experience not established")
    remote = matches(rules["remote"], text)
    geography_unclear = matches(rules["geography_uncertain"], text)
    format_unclear = matches(rules["work_format_uncertain"], text)
    eligible = matches(rules["ukraine"], text)
    if remote and eligible and not geography_unclear and not format_unclear:
        points("location", 1, "remote and Ukraine/worldwide eligibility stated; confirm contract terms")
    else:
        points("location", 0.65 if remote else 0.3, "remote mentioned; eligibility or attendance needs review" if remote else "work format unconfirmed")
        result.uncertainty.append("Confirm Ukraine eligibility and regular office/relocation requirements")
    if matches(rules["phone"], text):
        points("communication", 0.2, "phone communication mentioned")
        result.negative.append("Confirm share of phone work, hours, and on-call expectations")
    elif support and technical:
        points("communication", 0.8, "technical investigation signals; asynchronous schedule unconfirmed")
        result.uncertainty.append("Support hours, on-call, and phone share unknown")
    else:
        points("communication", 0.5, "communication format unknown; neutral allocation")
    if matches(rules["seniority_mismatch"], job.title):
        points("seniority", 0.2, "title suggests a seniority mismatch")
        result.negative.append("Check seniority and expected scope")
    else:
        points("seniority", 1 if matches(rules["seniority"], job.title) else 0.5, "mid/senior title" if matches(rules["seniority"], job.title) else "seniority unconfirmed")
    salary = re.search(r"\$\s*([\d, ]{3,})\s*[-–—]\s*\$?\s*([\d, ]{3,})", job.salary)
    if salary and re.search(r"(?i)month|місяц|/mo", job.salary):
        low, high = (int(re.sub(r"\D", "", v)) for v in salary.groups())
        target = profile["apple_salary_target_usd"] if apple else profile["support_salary_target_usd"]
        if low > high:
            points("salary", 0.5, "invalid salary range; neutral allocation")
            result.uncertainty.append("Salary range is inconsistent")
        else:
            points("salary", 1 if low >= target else 0.7 if high >= target else 0.1, f"advertised monthly USD range {low}–{high}; configured target {target}")
            if high < target:
                result.negative.append("Advertised upper salary is below the configured target; not a rejection")
        result.uncertainty.append("Salary gross/net and contract basis unconfirmed")
    else:
        points("salary", 0.5, "salary unknown or not comparable monthly USD; neutral allocation")
        result.uncertainty.append("Salary amount, period, currency or tax basis needs confirmation")
    penalty = min(scoring["maximum_missing_penalty"], len(result.missing) * scoring["missing_penalty"])
    result.components["missing_penalty"] = -penalty
    if penalty:
        result.negative.append(f"Missing or unverified mandatory skills: -{penalty} points")
    result.score = max(0, min(100, sum(result.components.values())))
    if len(job.description) < scoring["minimum_description_length"]:
        result.uncertainty.append("Description may be truncated; assess full listing before deciding")
    result.decision = "rejected" if result.rejected else "review" if result.uncertainty or result.missing else "match"
    return result
