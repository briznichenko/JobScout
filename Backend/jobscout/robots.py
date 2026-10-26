import re
from urllib.parse import unquote, urlsplit


def allowed_by_robots(text: str, agent: str, url: str) -> bool:
    groups = []
    agents, rules = [], []
    has_directives = False
    for raw in text.splitlines() + ["User-agent: __end__"]:
        line = raw.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        if key.lower() == "user-agent":
            if has_directives:
                groups.append((agents, rules))
                agents, rules, has_directives = [], [], False
            agents.append(value.lower())
        elif agents:
            has_directives = True
            if key.lower() in {"allow", "disallow"} and value:
                rules.append((key.lower() == "allow", value))
    product = agent.split("/", 1)[0].lower()
    selected, best = [], -1
    for names, group_rules in groups:
        matching = [len(name) for name in names if name != "*" and name in product]
        specificity = max(matching) if matching else 0 if "*" in names else -1
        if specificity > best:
            selected, best = list(group_rules), specificity
        elif specificity == best and specificity >= 0:
            selected.extend(group_rules)
    parts = urlsplit(url)
    path = unquote(parts.path + ("?" + parts.query if parts.query else ""))
    matches = []
    for allow, pattern in selected:
        end = pattern.endswith("$")
        expression = re.escape(pattern[:-1] if end else pattern).replace(r"\*", ".*")
        if re.match(expression + ("$" if end else ""), path):
            matches.append((len(pattern.replace("*", "").rstrip("$")), allow))
    return max(matches)[1] if matches else True
