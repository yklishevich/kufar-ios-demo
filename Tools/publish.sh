#!/usr/bin/env bash
#
# Публикация и синхронизация: единственное место, откуда воркспейс пишет
# в GitHub. Обратное направление — Tools/bootstrap.sh.
#
# Разовое создание репозиториев (требует gh CLI: brew install gh && gh auth login):
#
#   ./Tools/publish.sh --check              проверить окружение, ничего не делать
#   ./Tools/publish.sh --dry-run OWNER      показать, что будет создано
#   ./Tools/publish.sh OWNER                создать, запушить, проставить тег 1.0.0
#
# Повседневная синхронизация — закоммитить и запушить всё изменённое:
#
#   ./Tools/publish.sh --push --dry-run     показать, что будет закоммичено
#   ./Tools/publish.sh --push               закоммитить и запушить
#   ./Tools/publish.sh --push -m "текст"    своё сообщение вместо автоматического
#   ./Tools/publish.sh --push --tag         + поднять patch и запушить тег
#   ./Tools/publish.sh --push --tag minor   + поднять minor (major/minor/patch)
#
# Про --tag и честность semver. Скрипт поднимает версию, но проверить
# совместимость не может — этого не умеет никто, кроме компилятора чужого
# потребителя. Правило прежнее и оно на авторе:
#
#   patch — поправлена реализация, публичный API не изменился вообще;
#   minor — API расширен: новый тип, метод, кейс с дефолтом. Старый код цел;
#   major — API сломан: изменена сигнатура, удалён символ, добавлен кейс
#           в закрытый enum. Потребители мигрируют, см. раздел 2.3 документа.
#
# По умолчанию patch — самый безобидный вариант. Ставить его на изменение,
# которое ломает потребителя, значит соврать в теге: резолвер молча подтянет
# такую версию всем, кто написал from:, и уронит их сборку.
#
# Зачем отдельный режим. Локально Xcode подменяет пакеты папками и собирает
# рабочую копию, а CI клонирует то, что в гите. Расхождение между ними —
# самая частая причина «у меня собирается, на билд-сервере нет»: правки
# лежат незакоммиченными в восьми репозиториях сразу. Один проход закрывает.
#
# Тегов режим --push сам по себе НЕ ставит: релиз — отдельное решение,
# а не побочный эффект синхронизации.
#
# А вот --tag теперь делает две вещи сразу: ставит тег в гите И публикует
# версию в реестр. Порознь они бессмысленны — резолв идёт через реестр,
# и оттегированная, но неопубликованная версия для потребителей
# не существует. Нужны переменные окружения:
#
#   export REGISTRY_URL=https://spm-registry.byklishevich.com
#   export PUBLISH_TOKEN=…
#
# OWNER — организация или твой логин на GitHub. На резолв зависимостей он
# не влияет: их адресует реестр, а гит хранит только исходники.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="1.0.0"

# Репозиторий на команду; внутри пакеты, каждый в своей папке.
TEAMS=(
  "platform_team:kufar-platform"
  "search_team:kufar-search"
  "posting_team:kufar-posting"
  "goods_team:kufar-goods"
  "auto_team:kufar-auto"
  "identity_team:kufar-identity"
)

# ── режим --push: закоммитить, запушить, оттегировать, опубликовать ─────────
#
# Структура изменилась вместе с переездом в репозитории команд:
#   git-операции идут на уровне РЕПОЗИТОРИЯ (папка команды),
#   теги и публикация — по каждому ПАКЕТУ внутри него.
# Раньше это совпадало, потому что репозиторий и был пакетом.

# Сообщение коммита выводится из того, что реально изменилось: имена пакетов
# плюс «манифест», если тронут Package.swift. Лучше, чем «update», и не требует
# от человека придумывать текст шесть раз подряд.
#
# Правила покрывают все верхнеуровневые папки обоих видов репозитория —
# и команды, и воркспейса. «прочее» осталось как страховка, но если оно
# появляется в сообщении, это не норма, а признак, что завели новую папку
# и забыли про неё здесь: коммит-то уйдёт, только прочитать его будет нельзя.
changed_summary() {
  git -C "$1" status --porcelain | sed 's/^...//' | awk '
      /^kufar\./          { split($0, p, "/"); print p[1];      next }
      /^KufarDemoApp\//   { print "KufarDemoApp";               next }
      /^KufarWorkspace/   { print "воркспейс";                  next }
      /^Tools\//          { print "Tools";                      next }
      /^registry\//       { print "реестр";                     next }
      /^\.github\//       { print "CI";                         next }
      /\.md$/             { print "документация";               next }
                           { print "прочее" }
    ' | sort -u | awk '{ printf "%s%s", sep, $0; sep = ", " } END { if (NR) print "" }'
}

# Тег версии пакета: kufar.Foundation-1.2.0.
#
# Префикс обязателен, потому что в репозитории команды пакетов несколько,
# а тег принадлежит репозиторию целиком. Голая «1.2.0» означала бы, что
# соседний пакет свою 1.2.0 выпустить уже не может.
latest_version() {
  git -C "$1" tag --list "$2-[0-9]*.[0-9]*.[0-9]*" --sort=-v:refname 2>/dev/null \
    | head -1 | sed "s/^$2-//"
}

bump_version() {
  local ver="$1" kind="$2" ma mi pa
  IFS=. read -r ma mi pa <<< "$ver"
  case "$kind" in
    major) echo "$((ma + 1)).0.0" ;;
    minor) echo "$ma.$((mi + 1)).0" ;;
    *)     echo "$ma.$mi.$((pa + 1))" ;;
  esac
}

# Публикация одного пакета: тег в гите + версия в реестре.
#
# Порознь они бессмысленны. Резолв идёт через реестр, поэтому оттегированная,
# но не опубликованная версия для потребителей не существует; а опубликованная
# без тега — это релиз, который не отследить обратно к коммиту.
release_package() {
  # Три отдельных local, а не один с тремя присваиваниями.
  # В bash 3.2 (штатный на macOS) `local a="$1" b="$a/x"` падает под set -u:
  # все имена объявляются как unset до того, как выполнятся присваивания,
  # поэтому $a на той же строке ещё пуст. В bash 4+ работает — потому и
  # не воспроизводится там, где разрабатывали.
  local repo_dir="$1"
  local pkg="$2"
  local pkg_dir="$repo_dir/$pkg"
  [[ -f "$pkg_dir/Package.swift" ]] || return 0

  local head_tag old new
  head_tag="$(git -C "$repo_dir" tag --points-at HEAD --list "$pkg-[0-9]*.[0-9]*.[0-9]*" 2>/dev/null | head -1)"
  [[ -n "$head_tag" ]] && return 0     # текущий коммит уже выпущен

  old="$(latest_version "$repo_dir" "$pkg")"
  if [[ -z "$old" ]]; then new="1.0.0"; old="—"; else new="$(bump_version "$old" "$TAG_KIND")"; fi

  if [[ $DRY -eq 1 ]]; then
    printf "      %-24s %s → %s\n" "$pkg" "$old" "$new"
    return 0
  fi

  # Без -f: версия неизменяема. Переписать выпущенную значит подсунуть другой
  # код тому, кто её уже зарезолвил и закешировал.
  git -C "$repo_dir" tag "$pkg-$new"
  git -C "$repo_dir" push --quiet origin "$pkg-$new"

  if [[ -n "${REGISTRY_URL:-}" && -n "${PUBLISH_TOKEN:-}" ]]; then
    if node "$ROOT/registry/scripts/publish.mjs" \
          --package "$pkg_dir" --scope "${pkg%%.*}" --name "${pkg#*.}" --version "$new" >/dev/null; then
      printf "      ✓ %-24s %s → реестр\n" "$pkg" "$new"
    else
      printf "      ✗ %-24s тег %s есть, публикация не удалась\n" "$pkg" "$new"
      echo "         версия существует в гите и не существует для потребителей"
    fi
  else
    printf "      ! %-24s тег %s, реестр пропущен (нет REGISTRY_URL/PUBLISH_TOKEN)\n" "$pkg" "$new"
  fi
}

sync_repo() {
  local dir="$1" name="$2"
  [[ -d "$dir/.git" ]] || return 0

  # Залипший index.lock остаётся, если git прервали на полуслове.
  # `|| true` не для красоты: если файл есть, но недоступен (права, чужой
  # владелец, примонтированная ФС), rm вернёт ненулевой код и под set -e
  # уронит весь проход — на репозитории, до которого дело даже не дошло.
  if [[ -f "$dir/.git/index.lock" ]]; then rm -f "$dir/.git/index.lock" || true; fi

  local dirty ahead
  dirty="$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')"
  ahead="$(git -C "$dir" log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "$dirty" == "0" && "$ahead" == "0" && -z "$TAG_KIND" ]]; then
    return 0
  fi

  local msg="$PUSH_MSG"
  if [[ -z "$msg" ]]; then
    local what; what="$(changed_summary "$dir")"
    msg="$name: ${what:-обновление}"
  fi

  if [[ $DRY -eq 1 ]]; then
    printf "  %-20s %s изм., %s не запушено\n" "$name" "$dirty" "$ahead"
    [[ "$dirty" != "0" ]] && printf "      сообщение: %s\n" "$msg"
    if [[ -n "$TAG_KIND" ]]; then
      for pkg_dir in "$dir"/kufar.*/; do
        [[ -d "$pkg_dir" ]] && release_package "$dir" "$(basename "$pkg_dir")"
      done
    fi
    return 0
  fi

  if [[ "$dirty" != "0" ]]; then
    git -C "$dir" add -A
    git -C "$dir" commit --quiet -m "$msg"
  fi

  if [[ "$dirty" != "0" || "$ahead" != "0" ]]; then
    if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      git -C "$dir" push --quiet
    else
      git -C "$dir" push --quiet -u origin "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    fi
    printf "  ✓ %-20s %s\n" "$name" "$msg"
  fi

  # Релизим каждый пакет репозитория отдельно: у соседей свои версии.
  if [[ -n "$TAG_KIND" ]]; then
    for pkg_dir in "$dir"/kufar.*/; do
      [[ -d "$pkg_dir" ]] && release_package "$dir" "$(basename "$pkg_dir")"
    done
  fi
}

if [[ "${1:-}" == "--push" ]]; then
  shift
  DRY=0; PUSH_MSG=""; TAG_KIND=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY=1; shift ;;
      -m) PUSH_MSG="${2:?укажи текст сообщения}"; shift 2 ;;
      --tag)
        case "${2:-}" in
          major|minor|patch) TAG_KIND="$2"; shift 2 ;;
          *)                 TAG_KIND="patch"; shift ;;
        esac ;;
      *) echo "неизвестный флаг: $1"; exit 2 ;;
    esac
  done

  echo
  [[ $DRY -eq 1 ]] && echo "Проверка без изменений:" || echo "Коммит, пуш и релиз:"
  [[ -n "$TAG_KIND" ]] && echo "Версия: +1 к $TAG_KIND у каждого изменённого пакета"
  echo

  for entry in "${TEAMS[@]}"; do
    sync_repo "$ROOT/${entry%%:*}" "${entry##*:}"
  done
  # Воркспейс тоже репозиторий: README, документ, Tools, registry, workflow.
  # Пакетов внутри нет, поэтому релизить нечего.
  sync_repo "$ROOT" "kufar-ios"

  echo
  if [[ $DRY -eq 1 ]]; then
    echo "Это был --dry-run. Убери флаг, чтобы выполнить."
  else
    echo "Готово. Теперь CI собирает то же, что и ты локально."
  fi
  exit 0
fi

MODE="${1:-}"
case "$MODE" in
  --check)
    command -v gh >/dev/null || { echo "нет gh CLI: brew install gh"; exit 1; }
    gh auth status || { echo "не залогинен: gh auth login"; exit 1; }
    echo "gh готов. Репозиториев к публикации: ${#REPOS[@]} + сам воркспейс."
    grep -h -o 'github\.com/[^/]*' "$ROOT"/*_team/*/Package.swift | sort -u | sed 's/^/  владелец в манифестах: /'
    exit 0 ;;
  --dry-run)
    OWNER="${2:?укажи владельца}"; DRY=1 ;;
  "")
    echo "укажи владельца или --check. Подробности: head -20 $0"; exit 2 ;;
  *)
    OWNER="$MODE"; DRY=0 ;;
esac

# --dry-run ничего не вызывает, поэтому gh для него не нужен
[[ $DRY -eq 1 ]] || command -v gh >/dev/null || {
  echo "нет gh CLI: brew install gh && gh auth login"; exit 1; }

publish() {
  local dir="$1" name="$2"
  if [[ $DRY -eq 1 ]]; then
    echo "  создать $OWNER/$name  ←  ${dir#$ROOT/}"
    return
  fi

  pushd "$dir" >/dev/null
  if [[ ! -d .git ]]; then
    git init --quiet -b main
    git add .
    git commit --quiet -m "$name: демо архитектуры классифайда"
  fi

  if gh repo view "$OWNER/$name" >/dev/null 2>&1; then
    echo "  $name уже существует, пропускаю создание"
    git remote get-url origin >/dev/null 2>&1 || \
      git remote add origin "https://github.com/$OWNER/$name.git"
    git push --quiet -u origin main
  else
    gh repo create "$OWNER/$name" --public --source=. --remote=origin --push \
      --description "Демо модульной архитектуры классифайда: $name"
  fi

  git tag -f "$TAG" >/dev/null
  git push --quiet --force origin "$TAG"
  echo "  $name → https://github.com/$OWNER/$name  ($TAG)"
  popd >/dev/null
}

echo
echo "Владелец: $OWNER   Тег: $TAG"
echo

for entry in "${REPOS[@]}"; do
  rest="${entry#*:}"
  publish "$ROOT/${entry%%:*}/${rest##*:}" "${rest%%:*}"
done

# воркспейс — тоже репозиторий: README, документ, Tools, .xcworkspace.
# Клоны команд в нём заигнорены, их поднимает bootstrap.sh.
publish "$ROOT" "kufar-ios"

echo
if [[ $DRY -eq 1 ]]; then
  echo "Это был --dry-run. Убери флаг, чтобы создать по-настоящему."
else
  echo "Готово. Проверь: python3 Tools/deplint.py"
  echo "Резолв зависимостей от владельца не зависит — адресует реестр."
fi
