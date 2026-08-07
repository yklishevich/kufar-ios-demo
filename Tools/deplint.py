#!/usr/bin/env python3
"""Линтер зависимостей многопакетного воркспейса.

Границы команд держит SwiftPM: внутренний таргет чужого пакета
импортировать просто нельзя. Линтер проверяет то, что SwiftPM НЕ проверяет:

  1. импорт разрешается либо своим таргетом, либо продуктом пакета-зависимости;
  2. импорт объявлен в dependencies таргета, а пакет — в dependencies пакета;
  3. импорт идёт вниз по уровням (Foundation → Контракты → Platform → Features → Корень);
  4. вертикаль не импортирует вертикаль — только через *Interface;
  5. assembly вертикали импортируется только композиционным корнем;
  6. в *Interface нет SwiftUI;
  7. контрактный пакет зависит только от KufarFoundation — иначе он перестаёт
     быть дешёвым для подключения;
  8. import *Testing только под #if DEBUG;
  9. в графе пакетов нет циклов;
 10. предупреждения о мёртвых зависимостях.

Запуск: python3 Tools/deplint.py
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LAYER_ORDER = ["foundation", "contracts", "platform", "feature", "root"]

TARGET_LAYER = {
    "SharedKernel": "foundation", "Networking": "foundation",
    "NetworkingInterface": "foundation", "NetworkingTesting": "foundation",

    "AnalyticsAPI": "contracts", "SessionInterface": "contracts",
    "SessionInterfaceTesting": "contracts", "CatalogContracts": "contracts",
    "SearchInterface": "contracts", "PostingInterface": "contracts",
    "GoodsInterface": "contracts", "AutoInterface": "contracts",
    "ProfileInterface": "contracts", "AuthInterface": "contracts",

    "AnalyticsImpl": "platform", "Navigation": "platform",
    "DesignTokens": "platform", "DesignComponents": "platform",
    "SchemaKit": "platform", "ListingKit": "platform",

    "SearchDomain": "feature", "SearchData": "feature", "SearchUI": "feature",
    "Search": "feature",
    "PostingDomain": "feature", "PostingData": "feature", "PostingUI": "feature",
    "Posting": "feature",
    "GoodsDomain": "feature", "GoodsData": "feature", "GoodsUI": "feature", "Goods": "feature",
    "AutoDomain": "feature", "AutoData": "feature", "AutoUI": "feature", "Auto": "feature",
    "ProfileUI": "feature", "Profile": "feature",
    "AuthData": "feature", "AuthUI": "feature", "Auth": "feature",

    "AppFeature": "root", "AppComposition": "root",
    "AppFeatureTests": "root", "ArchitectureTests": "root",
}

# Конкретный APIClient называет только composition root — это ровно то, что
# обещает строка «Composition root — единственное место с конкретными
# реализациями» в 7.1. Адаптеры вертикалей держат HTTPPerforming
# из NetworkingInterface и о транспорте не знают.
#
# Auth пока в исключении: он реализует RequestInterceptor, а тот живёт
# в Networking — протоколом владеет поставщик, потому что потребляет его
# APIClient. Переедет отдельной фазой (правка ломающая, в отличие от
# аддитивного HTTPPerforming), после чего список схлопнется до одного имени.
NETWORKING_CONCRETE = {"AppComposition", "Auth", "AuthData"}

VERTICALS = ["Search", "Posting", "Goods", "Auto", "Profile", "Auth"]
ASSEMBLIES = set(VERTICALS)
# Пакеты адресуются идентичностью реестра `scope.Name`, а не именем
# репозитория: с переходом на SE-0292 адрес перестал быть идентичностью.
SCOPE = "kufar"
CONTRACT_PACKAGES = {f"{SCOPE}.CatalogContracts", f"{SCOPE}.SearchContracts",
                     f"{SCOPE}.PostingContracts", f"{SCOPE}.GoodsContracts",
                     f"{SCOPE}.AutoContracts", f"{SCOPE}.IdentityContracts"}
FOUNDATION_PACKAGE = f"{SCOPE}.Foundation"

SYSTEM = {"Foundation", "SwiftUI", "Observation", "Combine", "XCTest",
          "UIKit", "AppKit", "OSLog", "Testing", "PackageDescription"}


def rank(target): return LAYER_ORDER.index(TARGET_LAYER[target])


def vertical_of(name):
    for v in VERTICALS:
        if name == v or name.startswith(v):
            return v
    return None


def balanced(text, start, op, cl):
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
        # .../<команда>_team/<Пакет>/Package.swift
        # Репозиторий = пакет: иначе его не подключить по URL, потому что
        # SwiftPM ищет Package.swift в корне репозитория.
        self.team = self.dir.parent.name
        text = manifest.read_text(encoding="utf-8")

        # Идентичность пакета — ИМЯ ПАПКИ, и это не соглашение, а требование
        # SwiftPM. Для registry-зависимости идентичность выглядит как
        # `kufar.Foundation`, а у локальной копии выводится из имени
        # директории. Разойдутся — Xcode откажется подменять:
        #   unable to override package 'Foundation' because its identity
        #   'kufar.foundation' doesn't match override's identity
        #   (directory name) 'foundation'
        # Проверено экспериментом, см. registry/README.md.
        self.name = self.dir.name

        # Имя из манифеста больше не идентичность — оставлено как есть
        # (KufarSearch), потому что ни на что не влияет. Держим отдельно,
        # чтобы правило ниже могло на него посмотреть.
        self.manifest_name = re.search(r'name:\s*"([\w]+)"', text).group(1)

        # Зависимости по идентичности реестра. Адреса в манифестах нет вообще:
        # где лежат исходники, знает реестр, и он может это изменить,
        # не трогая ни один манифест потребителя.
        self.dep_ids = re.findall(r'\.package\(id:\s*"([^"]+)"', text)
        self.dep_paths = re.findall(r'\.package\(path:\s*"([^"]+)"\)', text)
        self.dep_names = list(self.dep_ids) + [Path(x).name for x in self.dep_paths]

        self.products = {}
        pm = re.search(r"products:\s*\[", text)
        if pm:
            block = balanced(text, pm.end() - 1, "[", "]")
            for lib in re.finditer(r'\.library\(\s*name:\s*"(\w+)",\s*targets:\s*\[([^\]]*)\]', block):
                self.products[lib.group(1)] = re.findall(r'"(\w+)"', lib.group(2))

        self.targets = {}
        self.test_targets = set()
        for m in re.finditer(r"\.(test)?[Tt]arget\(", text):
            body = balanced(text, m.end() - 1, "(", ")")
            name_m = re.search(r'name:\s*"(\w+)"', body)
            if not name_m:
                continue
            name = name_m.group(1)
            if m.group(1):
                self.test_targets.add(name)
            deps = set()
            dm = re.search(r"dependencies:\s*\[", body)
            if dm:
                inner = balanced(body, dm.end() - 1, "[", "]")
                # [\w.]+ во втором захвате: идентичность реестра — kufar.Foundation,
                # а \w точку не берёт. С \w+ линтер молча решал бы, что продукт
                # объявлен без пакета, и ронял проверку на всех 20 манифестах.
                for pr in re.finditer(r'\.product\(\s*name:\s*"(\w+)",\s*package:\s*"([\w.]+)"', inner):
                    deps.add((pr.group(1), pr.group(2)))
                stripped = re.sub(r"\.product\([^)]*\)", "", inner)
                for local in re.findall(r'"(\w+)"', stripped):
                    deps.add((local, None))
            self.targets[name] = deps

    def sources_dir(self, target):
        for base in ("Sources", "Tests"):
            candidate = self.dir / base / target
            if candidate.exists():
                return candidate
        return None


def main() -> int:
    packages = {}
    # Только пакеты команд: rglob по всему дереву цепляет ещё и registry/,
    # где лежат демонстрационные пакеты самого реестра. Они к графу
    # приложения отношения не имеют.
    for manifest in sorted(ROOT.glob("*_team/*/Package.swift")):
        if ".attic" in manifest.parts or ".build" in manifest.parts:
            continue
        pkg = Package(manifest)
        packages[pkg.name] = pkg

    # где какой таргет и какой продукт что отдаёт
    owner = {}
    exported = {}          # target -> [(product, package)]
    for pkg in packages.values():
        for t in pkg.targets:
            owner[t] = pkg.name
        for product, targets in pkg.products.items():
            for t in targets:
                exported.setdefault(t, []).append((product, pkg.name))

    problems, warnings, checked = [], [], 0

    for pkg in packages.values():
        # 0. Папка называется `scope.Name` — идентичностью реестра.
        # Xcode подменяет registry-зависимость локальной копией, сверяя
        # идентичность зависимости с ИМЕНЕМ ПАПКИ. Отступишь от формата —
        # подмена молча выключится, и правка в соседнем пакете перестанет
        # быть видна до публикации версии.
        if not pkg.name.startswith(f"{SCOPE}."):
            problems.append(
                f"[identity] папка {pkg.name} не в формате {SCOPE}.Name; "
                f"Xcode не подменит registry-зависимость локальной копией")

        # 7. контрактный пакет должен оставаться дешёвым
        # Контракт может зависеть от ядра и от других контрактов — граф
        # остаётся дешёвым. Всё остальное делает его дорогим для подключения.
        if pkg.name in CONTRACT_PACKAGES:
            allowed = CONTRACT_PACKAGES | {FOUNDATION_PACKAGE}
            extra = [d for d in pkg.dep_names if d not in allowed]
            if extra:
                problems.append(
                    f"[тяжёлый контракт] {pkg.name} зависит от {extra}; "
                    f"контрактному пакету можно только {FOUNDATION_PACKAGE} "
                    f"и другие контракты")

        for target, declared in pkg.targets.items():
            src = pkg.sources_dir(target)
            if src is None:
                problems.append(f"[нет исходников] {pkg.name}/{target}")
                continue
            if target not in TARGET_LAYER:
                problems.append(f"[неизвестный уровень] {target} нет в TARGET_LAYER")
                continue

            declared_local = {n for n, p in declared if p is None}
            declared_products = {(n, p) for n, p in declared if p is not None}
            own_vertical = vertical_of(target)
            seen_files = set()

            for path in sorted(src.rglob("*.swift")):
                text = path.read_text(encoding="utf-8")
                rel = path.relative_to(ROOT)
                if path not in seen_files:
                    seen_files.add(path)
                    if re.search(r"^\s*import\s+\w+Testing\s*$", text, re.M) and "#if DEBUG" not in text:
                        if target not in pkg.test_targets:
                            problems.append(f"[стаб в проде] {rel} — import *Testing вне #if DEBUG")

                for lineno, line in enumerate(text.splitlines(), 1):
                    m = re.match(r"\s*(?:@testable\s+)?import\s+([A-Za-z_]\w*)", line)
                    if not m:
                        continue
                    module = m.group(1)

                    if module == "SwiftUI" and target.endswith("Interface"):
                        problems.append(f"[SwiftUI в контракте] {rel}:{lineno} — "
                                        f"{target} обязан быть Foundation-only")
                    if module == "Networking" and target not in NETWORKING_CONCRETE:
                        problems.append(f"[конкретный транспорт] {rel}:{lineno} — "
                                        f"{target} импортирует Networking; "
                                        f"адаптеру нужен NetworkingInterface")
                    if module in SYSTEM or module == target:
                        continue
                    if module not in owner:
                        continue
                    checked += 1

                    # 1–2. видимость
                    if owner[module] == pkg.name:
                        if module not in declared_local:
                            problems.append(f"[нет в манифесте] {rel}:{lineno} — {target} "
                                            f"импортирует {module} своего пакета, не объявив его")
                    else:
                        visible = exported.get(module, [])
                        if not visible:
                            problems.append(f"[внутренний таргет] {rel}:{lineno} — {module} "
                                            f"не объявлен продуктом пакета {owner[module]}; "
                                            f"импорт извне невозможен")
                        elif not any((prod, pk) in declared_products for prod, pk in visible):
                            problems.append(f"[нет в манифесте] {rel}:{lineno} — {target} "
                                            f"импортирует {module}, но не объявляет продукт "
                                            f"{visible[0][0]} пакета {visible[0][1]}")
                        elif owner[module] not in pkg.dep_names:
                            problems.append(f"[нет пакета] {rel}:{lineno} — {pkg.name} не объявляет "
                                            f"зависимость от пакета {owner[module]}")

                    if module not in TARGET_LAYER:
                        continue
                    other_vertical = vertical_of(module)
                    same_vertical = own_vertical is not None and own_vertical == other_vertical

                    # 3. направление
                    if rank(module) > rank(target):
                        problems.append(f"[стрелка вверх] {rel}:{lineno} — "
                                        f"{target} импортирует {module} уровнем выше")
                    # 4. горизонталь между вертикалями
                    if (TARGET_LAYER[target] == "feature" and TARGET_LAYER[module] == "feature"
                            and not same_vertical):
                        problems.append(f"[горизонталь] {rel}:{lineno} — {target} импортирует "
                                        f"чужую вертикаль {module}; ходи через "
                                        f"{other_vertical}Interface")
                    # 5. правило одного корня
                    if module in ASSEMBLIES and target != "AppComposition":
                        problems.append(f"[два корня] {rel}:{lineno} — assembly {module} "
                                        f"импортируется из {target}, "
                                        f"а должна только из AppComposition")

    # 9. циклы между пакетами
    graph = {p.name: set(p.dep_names) for p in packages.values()}
    state, stack = {}, []

    def walk(node):
        state[node] = 1
        stack.append(node)
        for dep in sorted(graph.get(node, ())):
            if dep not in graph:
                problems.append(f"[нет пакета] {node} ссылается на несуществующий {dep}")
                continue
            if state.get(dep, 0) == 1:
                problems.append("[цикл пакетов] " + " → ".join(stack[stack.index(dep):] + [dep]))
            elif state.get(dep, 0) == 0:
                walk(dep)
        stack.pop()
        state[node] = 2

    for node in sorted(graph):
        if state.get(node, 0) == 0:
            walk(node)

    # 10. мёртвые зависимости
    for pkg in packages.values():
        used_modules = set()
        for target in pkg.targets:
            src = pkg.sources_dir(target)
            if src is None:
                continue
            for path in src.rglob("*.swift"):
                for line in path.read_text(encoding="utf-8").splitlines():
                    m = re.match(r"\s*(?:@testable\s+)?import\s+([A-Za-z_]\w*)", line)
                    if m:
                        used_modules.add(m.group(1))
        for dep_name in pkg.dep_names:
            dep = packages.get(dep_name)
            if dep and not any(t in used_modules for ts in dep.products.values() for t in ts):
                warnings.append(f"[мёртвый пакет] {pkg.name} объявляет {dep_name}, "
                                f"но ни один его продукт не импортируется")
        for target, deps in pkg.targets.items():
            src = pkg.sources_dir(target)
            if src is None:
                continue
            used = set()
            for path in src.rglob("*.swift"):
                for line in path.read_text(encoding="utf-8").splitlines():
                    m = re.match(r"\s*(?:@testable\s+)?import\s+([A-Za-z_]\w*)", line)
                    if m:
                        used.add(m.group(1))
            for name, owner_pkg in sorted(deps):
                if name not in used:
                    where = f"{owner_pkg}." if owner_pkg else ""
                    warnings.append(f"[мёртвая зависимость] {pkg.name}/{target} "
                                    f"объявляет {where}{name}, но не импортирует")

    # Репозиториев больше не считаем: с переходом на реестр имя репозитория
    # перестало быть идентичностью, и сколько пакетов лежит в одном репозитории —
    # вопрос упаковки, а не графа зависимостей.
    teams = sorted({p.team for p in packages.values()})
    print(f"deplint: команд {len(teams)}, пакетов {len(packages)}, "
          f"таргетов {sum(len(p.targets) for p in packages.values())}, "
          f"проверено импортов {checked}")
    for w in warnings:
        print("  предупреждение: " + w)
    if problems:
        print(f"\nНАРУШЕНИЙ: {len(problems)}\n")
        for p in problems:
            print("  " + p)
        return 1
    print("Нарушений нет: граф соответствует правилу направления зависимостей.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
