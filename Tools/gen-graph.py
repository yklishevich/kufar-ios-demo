#!/usr/bin/env python3
"""Генерирует диаграммы графа пакетов из манифестов.

Зачем генерировать, а не рисовать. Схема, нарисованная руками, расходится
с кодом молча: пакет добавили, диаграмму поправить забыли, и она врёт до тех
пор, пока кто-нибудь не сверит её построчно. Здесь источник один — те же
Package.swift, что читает deplint.py, — поэтому картинка не может отстать.

    python3 Tools/gen-graph.py            обновить блоки в architecture-overall.md
    python3 Tools/gen-graph.py --check    упали бы блоки — вернуть код 1
    python3 Tools/gen-graph.py --print    вывести в stdout, ничего не писать

Блоки в документе размечены маркерами:

    <!-- gen:teams -->  …  <!-- /gen:teams -->
    <!-- gen:packages --> … <!-- /gen:packages -->

Всё, что между ними, перезаписывается. Всё, что вокруг, — руками.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "architecture-overall.md"

# Порядок уровней задаёт вертикаль на схеме: корень сверху, ядро снизу.
LAYER = {
    "Foundation": 0, "Networking": 0,
    "CatalogContracts": 1, "SearchContracts": 1, "PostingContracts": 1,
    "GoodsContracts": 1, "AutoContracts": 1, "IdentityContracts": 1,
    "Navigation": 2, "DesignTokens": 2, "DesignComponents": 2,
    "SchemaKit": 2, "ListingKit": 2, "Analytics": 2,
    "Search": 3, "Posting": 3, "Goods": 3, "Auto": 3, "Identity": 3,
    "AppFeature": 4, "AppComposition": 5,
}

TEAM_TITLE = {
    "platform_team": "Platform Core",
    "search_team": "Поиск",
    "posting_team": "Подача",
    "goods_team": "Товары",
    "auto_team": "Авто",
    "identity_team": "Identity",
}

STYLE = {
    0: "fill:#f0f7f1,stroke:#8ab99a",      # Foundation
    1: "fill:#fdf6e8,stroke:#c8ab6e",      # контракты
    2: "fill:#f3f0fa,stroke:#a598c8",      # platform
    3: "fill:#eef4ff,stroke:#8aa4c8",      # вертикали и поверхности
    4: "fill:#dce8fb,stroke:#2d6cdf",      # корневой флоу
    5: "fill:#2d6cdf,stroke:#1b4a9c,color:#fff",  # композиционный корень
}


class Package:
    def __init__(self, manifest: Path):
        self.dir = manifest.parent
        self.identity = self.dir.name              # kufar.Foundation
        self.team = self.dir.parent.name           # platform_team
        self.short = self.identity.split(".", 1)[-1]
        text = manifest.read_text(encoding="utf-8")
        self.deps = re.findall(r'\.package\(id:\s*"([^"]+)"', text)
        self.products = re.findall(r'\.library\(\s*name:\s*"(\w+)"', text)
        self.targets = re.findall(r'\.(?:test)?[Tt]arget\(\s*\n?\s*name:\s*"(\w+)"', text)

    @property
    def layer(self) -> int:
        return LAYER.get(self.short, 3)


def load() -> list[Package]:
    found = [Package(m) for m in sorted(ROOT.glob("*_team/*/Package.swift"))]
    unknown = [p.short for p in found if p.short not in LAYER]
    if unknown:
        print(f"gen-graph: нет уровня для {unknown} — добавь в LAYER", file=sys.stderr)
    return found


def node_id(identity: str) -> str:
    return identity.replace(".", "_")


def plural(n: int, one: str, few: str, many: str) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return f"{n} {one}"
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return f"{n} {few}"
    return f"{n} {many}"


def teams_diagram(packages: list[Package]) -> str:
    """Кто от кого зависит НА УРОВНЕ КОМАНД.

    Внутрикомандные рёбра выброшены: они не про координацию, а про личную
    гигиену. Остаётся то, ради чего схема нужна на планёрке, — кто кого
    может заблокировать.

    Рёбра разделены по ТРЁМ видам, и в этом весь смысл картинки:

      пунктир, песочный — через контрактный пакет. Дешёвая связь: маршруты
                и модели, ноль транзитивных ограничений, меняется раз
                в квартал. Таких большинство, и это норма.

      тонкая, серая — через платформенный пакет: ядро, сеть, навигация,
                дизайн-система. Тоже норма: инфраструктура на то и общая.

      жирная, синяя — от ЧУЖОЙ РЕАЛИЗАЦИИ, то есть от assembly вертикали.
                Тянет весь её граф и связывает версиями. Право на такое
                ребро есть ровно у одной команды — той, что владеет
                композиционным корнем.

    Проверять картинку глазами нужно по одному признаку: жирные стрелки
    выходят только из platform_team. Появились из другой команды — граница
    поехала, и видно это здесь раньше, чем в сборке.
    """
    owner = {p.identity: p.team for p in packages}
    layer_of = {p.identity: p.layer for p in packages}

    # (тип ребра) → {(откуда, куда): {пакеты}}
    kinds: dict[str, dict[tuple[str, str], set[str]]] = {
        "contract": defaultdict(set),
        "platform": defaultdict(set),
        "concrete": defaultdict(set),
    }

    for p in packages:
        for dep in p.deps:
            other = owner.get(dep)
            if not other or other == p.team:
                continue
            layer = layer_of.get(dep, 3)
            kind = "contract" if layer == 1 else "platform" if layer in (0, 2) else "concrete"
            kinds[kind][(p.team, other)].add(dep.split(".", 1)[-1])

    lines = ["```mermaid", "graph LR"]
    for team, title in TEAM_TITLE.items():
        count = sum(1 for p in packages if p.team == team)
        lines.append(f'    {team}["<b>{title}</b><br/>{plural(count, "пакет", "пакета", "пакетов")}"]')
    lines.append("")

    ARROW = {"contract": "-.->", "platform": "-->", "concrete": "==>"}
    WORD = {"contract": ("контракт", "контракта", "контрактов"),
            "platform": ("модуль", "модуля", "модулей"),
            "concrete": ("реализация", "реализации", "реализаций")}
    LINK = {
        "contract": "stroke:#c8ab6e,stroke-dasharray:4",
        "platform": "stroke:#b9b3c9",
        "concrete": "stroke:#2d6cdf,stroke-width:3px",
    }

    order: list[str] = []
    for kind in ("contract", "platform", "concrete"):
        for (src, dst), via in sorted(kinds[kind].items()):
            label = plural(len(via), *WORD[kind])
            if kind == "concrete":
                label = "<br/>".join(sorted(via))
            lines.append(f'    {src} {ARROW[kind]}|"{label}"| {dst}')
            order.append(kind)

    lines.append("")
    for index, kind in enumerate(order):
        lines.append(f"    linkStyle {index} {LINK[kind]}")

    lines += ["    style platform_team fill:#f3f0fa,stroke:#7e5bb5",
              "    style search_team fill:#dfeee6,stroke:#3f8f6b",
              "    style posting_team fill:#dfeee6,stroke:#3f8f6b", "```"]
    return "\n".join(lines)


def packages_diagram(packages: list[Package]) -> str:
    """Полный граф пакетов, сгруппированный по командам."""
    by_team: dict[str, list[Package]] = defaultdict(list)
    for p in packages:
        by_team[p.team].append(p)

    lines = ["```mermaid", "graph BT"]
    for team, title in TEAM_TITLE.items():
        members = sorted(by_team.get(team, []), key=lambda p: (p.layer, p.short))
        if not members:
            continue
        lines.append(f'    subgraph {team}["{title}"]')
        lines.append("        direction TB")
        for p in members:
            lines.append(f'        {node_id(p.identity)}["{p.short}"]')
        lines.append("    end")
        lines.append("")

    for p in sorted(packages, key=lambda x: x.identity):
        for dep in sorted(p.deps):
            lines.append(f"    {node_id(p.identity)} --> {node_id(dep)}")
    lines.append("")
    for p in sorted(packages, key=lambda x: x.identity):
        lines.append(f"    style {node_id(p.identity)} {STYLE[p.layer]}")
    lines.append("```")
    return "\n".join(lines)


def stats_table(packages: list[Package]) -> str:
    rows = ["| Команда | Пакетов | Продуктов | Таргетов | Зависит от чужих пакетов |",
            "|---|---|---|---|---|"]
    owner = {p.identity: p.team for p in packages}
    for team, title in TEAM_TITLE.items():
        members = [p for p in packages if p.team == team]
        if not members:
            continue
        foreign = {d for p in members for d in p.deps if owner.get(d) != team}
        rows.append(f"| **{title}** | {len(members)} | "
                    f"{sum(len(p.products) for p in members)} | "
                    f"{sum(len(p.targets) for p in members)} | {len(foreign)} |")
    total = f"| **Всего** | {len(packages)} | " \
            f"{sum(len(p.products) for p in packages)} | " \
            f"{sum(len(p.targets) for p in packages)} | — |"
    return "\n".join(rows + [total])


BLOCKS = {
    "teams": teams_diagram,
    "packages": packages_diagram,
    "stats": stats_table,
}


def render(packages: list[Package], text: str) -> str:
    for name, builder in BLOCKS.items():
        # Маркеры могут стоять вплотную — пустой блок это нормальное
        # начальное состояние документа.
        pattern = re.compile(rf"<!-- gen:{name} -->.*?<!-- /gen:{name} -->", re.S)
        if not pattern.search(text):
            print(f"gen-graph: в документе нет блока gen:{name}", file=sys.stderr)
            continue
        block = f"<!-- gen:{name} -->\n{builder(packages)}\n<!-- /gen:{name} -->"
        text = pattern.sub(lambda _: block, text, count=1)
    return text


def main() -> int:
    packages = load()
    mode = sys.argv[1] if len(sys.argv) > 1 else ""

    if mode == "--print":
        for name, builder in BLOCKS.items():
            print(f"\n<!-- {name} -->\n{builder(packages)}")
        return 0

    if not DOC.exists():
        print(f"gen-graph: нет {DOC.name}", file=sys.stderr)
        return 1

    before = DOC.read_text(encoding="utf-8")
    after = render(packages, before)

    if mode == "--check":
        if before != after:
            print("gen-graph: диаграммы устарели — запусти python3 Tools/gen-graph.py")
            return 1
        print(f"gen-graph: диаграммы актуальны ({len(packages)} пакетов)")
        return 0

    DOC.write_text(after, encoding="utf-8")
    print(f"gen-graph: обновлено, пакетов {len(packages)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
