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

    <!-- gen:teams -->    …  <!-- /gen:teams -->
    <!-- gen:packages -->  …  <!-- /gen:packages -->
    <!-- gen:products -->  …  <!-- /gen:products -->
    <!-- gen:stats -->     …  <!-- /gen:stats -->

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
    "SessionContracts": 1,
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


def balanced(text: str, start: int, op: str, cl: str) -> str:
    """Содержимое скобки, открытой в позиции start. Нужен потому, что
    вложенные `.product(...)` внутри `dependencies: [...]` регуляркой
    не разбираются: жадная съест соседний таргет, ленивая — оборвётся
    на первой внутренней скобке."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == op:
            depth += 1
        elif text[i] == cl:
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    raise ValueError("несбалансированные скобки")


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

        # продукт -> таргеты, которые он отдаёт наружу
        self.product_targets: dict[str, list[str]] = {}
        products_block = re.search(r"products:\s*\[", text)
        if products_block:
            block = balanced(text, products_block.end() - 1, "[", "]")
            for lib in re.finditer(
                r'\.library\(\s*name:\s*"(\w+)",\s*targets:\s*\[([^\]]*)\]', block
            ):
                self.product_targets[lib.group(1)] = re.findall(r'"(\w+)"', lib.group(2))

        # таргет -> (свои таргеты пакета, чужие продукты)
        self.target_local: dict[str, set[str]] = {}
        self.target_products: dict[str, set[tuple[str, str]]] = {}
        self.test_targets: set[str] = set()
        for m in re.finditer(r"\.(test)?[Tt]arget\(", text):
            body = balanced(text, m.end() - 1, "(", ")")
            name_m = re.search(r'name:\s*"(\w+)"', body)
            if not name_m:
                continue
            name = name_m.group(1)
            if m.group(1):
                self.test_targets.add(name)
            local: set[str] = set()
            foreign: set[tuple[str, str]] = set()
            deps_block = re.search(r"dependencies:\s*\[", body)
            if deps_block:
                inner = balanced(body, deps_block.end() - 1, "[", "]")
                for pr in re.finditer(
                    r'\.product\(\s*name:\s*"(\w+)",\s*package:\s*"([\w.]+)"', inner
                ):
                    foreign.add((pr.group(1), pr.group(2)))
                # голые строки — это таргеты своего пакета; `.product(...)`
                # вырезаем, иначе их аргументы попадут сюда же
                stripped = re.sub(r"\.product\([^)]*\)", "", inner)
                local |= set(re.findall(r'"(\w+)"', stripped))
            self.target_local[name] = local
            self.target_products[name] = foreign

    @property
    def layer(self) -> int:
        return LAYER.get(self.short, 3)

    def closure(self, product: str) -> set[str]:
        """Таргеты, которые реально приезжают потребителю продукта.

        Не только те, что перечислены в `targets:`, но и внутренние,
        до которых они дотягиваются: код внутреннего таргета линкуется
        в потребителя, даже если импортировать его нельзя."""
        seen: set[str] = set()
        stack = list(self.product_targets.get(product, []))
        while stack:
            target = stack.pop()
            if target in seen or target not in self.target_local:
                continue
            seen.add(target)
            stack.extend(self.target_local[target])
        return seen


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


def products_diagram(packages: list[Package]) -> str:
    """Граф ПРОДУКТОВ — то, что реально линкуется, в отличие от графа пакетов.

    Две границы, которые постоянно путают, здесь видны одновременно:
    коробка — пакет, единица РЕЗОЛВА; узел внутри — продукт, единица
    ЛИНКОВКИ. Стрелка входит в узел, но версию тянет вся коробка.

    Рёбра считаются по замыканию: продукт отвечает не только за таргеты
    из своего `targets:`, но и за внутренние, до которых те дотягиваются.
    Иначе картинка врала бы в самом интересном месте — `Goods` выглядел бы
    независимым от дизайн-системы, хотя тянет её через GoodsUI.

    Узел без входящих стрелок извне своей коробки — продукт, которым никто
    не пользуется. Это не ошибка сама по себе, но повод спросить, зачем он
    публичный: каждый его мажор оплачивают все потребители пакета.
    """
    by_identity = {p.identity: p for p in packages}
    order = sorted(packages, key=lambda p: (p.layer, p.short))

    edges: set[tuple[str, str]] = set()
    for pkg in packages:
        for product in pkg.products:
            for target in pkg.closure(product):
                for name, dep in sorted(pkg.target_products.get(target, ())):
                    if dep in by_identity:
                        edges.add((f"{pkg.identity}::{product}", f"{dep}::{name}"))

    def nid(key: str) -> str:
        return key.replace(".", "_").replace("::", "__")

    lines = ["```mermaid", "graph BT"]
    for pkg in order:
        if not pkg.products:
            continue
        lines.append(f'    subgraph {nid(pkg.identity)}["{pkg.short}"]')
        lines.append("        direction TB")
        for product in sorted(pkg.products):
            lines.append(f'        {nid(f"{pkg.identity}::{product}")}["{product}"]')
        lines.append("    end")
    lines.append("")

    for src, dst in sorted(edges):
        lines.append(f"    {nid(src)} --> {nid(dst)}")
    lines.append("")

    for pkg in order:
        for product in sorted(pkg.products):
            lines.append(f'    style {nid(f"{pkg.identity}::{product}")} {STYLE[pkg.layer]}')
    lines.append("```")

    # Сводка тоже генерируется: числа в прозе устаревают тише всего,
    # потому что их никто не перечитывает.
    team_of = {p.identity: p.team for p in packages}
    demand: dict[str, int] = defaultdict(int)
    consumed_across_teams: set[str] = set()
    for src, dst in edges:
        src_pkg, dst_pkg = src.split("::")[0], dst.split("::")[0]
        if src_pkg != dst_pkg:
            demand[dst] += 1
        if team_of[src_pkg] != team_of[dst_pkg]:
            consumed_across_teams.add(dst)

    total = sum(len(p.products) for p in packages)
    top = sorted(demand.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
    hubs = ", ".join(f"`{k.split('::')[1]}` — {v}" for k, v in top)
    orphans = sorted(
        f"{p.identity}::{prod}"
        for p in packages for prod in p.products
        if f"{p.identity}::{prod}" not in consumed_across_teams
    )
    names = ", ".join(f"`{o.split('::')[1]}`" for o in orphans)

    lines += [
        "",
        f"Продуктов {total}, рёбер между ними {len(edges)}. "
        f"Самые востребованные снаружи своего пакета: {hubs}. "
        f"Это и есть цена мажора в платформе — ломающее изменение здесь "
        f"встаёт в релизную очередь у всех перечисленных.",
        "",
        f"Продуктов, которые не импортирует ни одна чужая команда: "
        f"{len(orphans)} — {names}. Часть из них такова по замыслу "
        f"(потребитель — композиционный корень, он же платформа), "
        f"остальные стоит перечитать: публичный продукт без потребителей "
        f"ничего не развязывает, но участвует в каждом мажоре своего пакета.",
    ]
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
    "products": products_diagram,
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
