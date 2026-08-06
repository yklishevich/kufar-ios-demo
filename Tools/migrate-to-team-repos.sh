#!/usr/bin/env bash
#
# Разовый переезд: 21 репозиторий-на-пакет → 6 репозиториев по командам.
#
# Стало возможным после перехода на реестр. С гит-зависимостями пакет обязан
# быть корнем репозитория: `.package(url:)` указывает на репозиторий, а
# `Package.swift` ищется в корне. Реестр адресует пакет ИМЕНЕМ, поэтому где
# лежат исходники — вопрос упаковки, а не резолва.
#
# Что меняется на диске: ничего. Папка команды сама становится репозиторием,
# `.git` переезжает на уровень выше:
#
#     было:  search_team/kufar.Search/.git
#     стало: search_team/.git
#
# Поэтому воркспейс, манифесты и deplint не трогаются — пути те же.
#
# История переносится через `git subtree`: коммиты переезжают вместе с кодом.
# Цена названа честно — SHA меняются (история переписывается), а PR, ревью
# и обсуждения остаются в старых репозиториях. В рабочем проекте отсюда
# следовало бы архивировать старые репозитории, а не удалять: ссылки на
# коммиты в задачах должны продолжать открываться.
#
# Переезд разовый: повторно запускать его уже не на чем.
#
#   ./Tools/migrate-to-team-repos.sh --dry-run     показать план
#   ./Tools/migrate-to-team-repos.sh               выполнить локально
#   ./Tools/migrate-to-team-repos.sh --push OWNER  + создать репозитории и запушить
#
# Пуш идёт по SSH (ключи у владельца уже есть). Нужен HTTPS —
# KUFAR_REMOTE_PROTO=https перед командой.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/.migrate"

DRY=0; PUSH=0; OWNER=""
case "${1:-}" in
    --dry-run) DRY=1 ;;
    --push)    PUSH=1; OWNER="${2:?укажи владельца на GitHub}" ;;
    "")        ;;
    *)         echo "неизвестный флаг: $1"; exit 2 ;;
esac

TEAMS=(platform_team search_team posting_team goods_team auto_team identity_team)

# Имя репозитория команды: platform_team → kufar-platform
repo_name() { echo "kufar-${1%_team}"; }

# Адрес remote для пуша. По умолчанию SSH.
#
# Клонировать демо удобнее по HTTPS — это умеет любой, ключи не нужны, и
# bootstrap.sh поэтому клонирует именно так. А пушит только владелец, и у него
# ключи есть; HTTPS-пуш потребовал бы токена в credential helper. Отсюда
# асимметрия: чтение по HTTPS, запись по SSH.
#
# Переопределить:  KUFAR_REMOTE_PROTO=https ./Tools/migrate-to-team-repos.sh --push OWNER
remote_url() {
    case "${KUFAR_REMOTE_PROTO:-ssh}" in
        https) echo "https://github.com/$OWNER/$1.git" ;;
        *)     echo "git@github.com:$OWNER/$1.git" ;;
    esac
}

# Пуш вынесен отдельно и идемпотентен намеренно.
#
# Раньше он стоял внутри ветки миграции, после `continue` для уже переехавших —
# и повторный запуск с --push молча ничего не делал: репозиторий есть, значит
# пропускаем, значит до пуша не доходим. Операция «создать» и операция
# «отправить» должны быть независимы, иначе повтор перестаёт чинить.
push_team() {
    local dir="$1" name="$2"

    local url; url="$(remote_url "$name")"

    if ! gh repo view "$OWNER/$name" >/dev/null 2>&1; then
        gh repo create "$OWNER/$name" --public \
            --description "Пакеты команды ${name#kufar-} — демо модульной архитектуры классифайда" \
            >/dev/null
    fi

    # set-url, а не add: remote мог остаться с прошлого запуска и указывать
    # на HTTPS. Тогда add молча ничего не сделает, а пуш попросит токен.
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
        git -C "$dir" remote set-url origin "$url"
    else
        git -C "$dir" remote add origin "$url"
    fi

    local branch
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    git -C "$dir" push --quiet -u origin "$branch"
    git -C "$dir" push --quiet --tags origin
    echo "    → https://github.com/$OWNER/$name"
}

echo
echo "Переезд в репозитории по командам"
echo "─────────────────────────────────"
echo

for team in "${TEAMS[@]}"; do
    dir="$ROOT/$team"
    [[ -d "$dir" ]] || { echo "  пропуск: нет $team"; continue; }

    name="$(repo_name "$team")"

    # Уже переехали — миграцию пропускаем, но пуш всё равно делаем.
    if [[ -d "$dir/.git" ]]; then
        printf "%-16s → %-18s уже репозиторий команды\n" "$team" "$name"
        if [[ $PUSH -eq 1 ]]; then push_team "$dir" "$name"; fi
        continue
    fi

    # Пакеты-источники: папки со своим .git. Массив может оказаться пустым,
    # и обращаться к нему надо осторожно — в bash 3.2 (штатный на macOS)
    # "${arr[*]}" на пустом массиве под set -u падает с «unbound variable».
    # Отсюда :- в раскрытиях и проверка длины до циклов.
    packages=()
    for p in "$dir"/*/; do
        [[ -d "${p}.git" ]] && packages+=("$(basename "$p")")
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        printf "%-16s → %-18s пакетов с .git не найдено\n" "$team" "$name"
        echo "    в $team нет ни одной папки со своим репозиторием."
        echo "    Либо переезд уже сделан частично — тогда смотри .migrate/ и состояние $dir,"
        echo "    либо репозитории не склонированы — тогда сначала ./Tools/bootstrap.sh"
        continue
    fi

    printf "%-16s → %-18s %d пакетов: %s\n" "$team" "$name" "${#packages[@]}" "${packages[*]:-}"

    if [[ $DRY -eq 1 ]]; then
        continue
    fi

    # 1. Отложить пакеты вместе с их .git — они станут источниками для subtree.
    mkdir -p "$STAGE/$team"
    for pkg in "${packages[@]}"; do
        mv "$dir/$pkg" "$STAGE/$team/$pkg"
    done

    # 2. Репозиторий команды. Первый коммит нужен обязательно:
    #    `git subtree add` в пустой репозиторий не работает.
    git -C "$dir" init --quiet -b main
    cat > "$dir/.gitignore" <<'IGNORE'
.DS_Store
.build/
DerivedData/
.swiftpm/
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
xcuserdata/
IGNORE
    cat > "$dir/README.md" <<HEADER
# $name

Репозиторий команды. Внутри — пакеты, каждый в своей папке.

Имя папки совпадает с идентичностью пакета в реестре (\`kufar.Name\`) —
это требование SwiftPM: по нему Xcode подменяет зависимость локальной копией
из воркспейса. Переименуешь папку — подмена молча выключится.

Пакеты релизятся независимо, теги с префиксом имени: \`kufar.Foundation-1.2.0\`.
HEADER
    git -C "$dir" add .gitignore README.md
    git -C "$dir" commit --quiet -m "$name: репозиторий команды"

    # 3. Втянуть каждый пакет вместе с историей.
    for pkg in "${packages[@]}"; do
        git -C "$dir" subtree add --prefix="$pkg" "$STAGE/$team/$pkg" main --squash=false \
            -m "перенос $pkg из отдельного репозитория" >/dev/null 2>&1 \
        || git -C "$dir" subtree add --prefix="$pkg" "$STAGE/$team/$pkg" main >/dev/null
        echo "    ✓ $pkg"
    done

    # 4. Теги пакетов: в общем репозитории версия одного пакета не может
    #    называться просто 1.0.0 — иначе соседи не смогут выпустить свою.
    for pkg in "${packages[@]}"; do
        for tag in $(git -C "$STAGE/$team/$pkg" tag --list '[0-9]*.[0-9]*.[0-9]*'); do
            git -C "$dir" tag -f "$pkg-$tag" HEAD >/dev/null
        done
    done

    if [[ $PUSH -eq 1 ]]; then push_team "$dir" "$name"; fi
done

echo
if [[ $DRY -eq 1 ]]; then
    echo "Это был --dry-run. Убери флаг, чтобы выполнить."
    exit 0
fi

cat <<'NEXT'
Дальше по порядку — каждый шаг проверяет предыдущий:

  1. Граф цел, история на месте:
       python3 Tools/deplint.py
       git -C search_team log --oneline | head

  2. Закоммитить и запушить содержимое:
       ./Tools/publish.sh --push

  3. Собрать в Xcode. До этого шага старое не трогать.

  4. Только теперь убрать промежуточные копии и старые репозитории.
     Здесь удаление, а не архивация: в старых репозиториях по паре коммитов
     и ни одного PR — то есть ровно того, чего subtree не переносит, там нет.
     В рабочем проекте ответ был бы обратным.
       rm -rf .migrate
       gh repo delete ВЛАДЕЛЕЦ/KufarFoundation --yes    # и остальные двадцать
NEXT
echo
