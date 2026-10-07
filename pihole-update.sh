#!/usr/bin/env bash
#
# pihole-update.sh — Pi-hole-Container auf das neueste Release-Tag heben,
# testen, bei Erfolg committen & pushen, bei Fehlschlag zurückrollen.
#
# Voraussetzungen:
#   - compose.yaml nutzt ein gepinntes Tag:  image: pihole/pihole:2026.09.1
#   - curl, jq, dig, git, docker (compose v2) sind installiert
#   - git push funktioniert nicht-interaktiv (SSH-Key ohne Passphrase o.ä.)
#
# Crontab-Beispiel (montags 04:30):
#   30 4 * * 1  /home/ubu/docker/pihole/pihole-update.sh >> /home/ubu/docker/pihole/update.log 2>&1
#
set -u -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Secrets & lokale Overrides (NTFY_URL, NTFY_TOKEN, ...) – nicht im Git
ENV_FILE="${ENV_FILE:-$HOME/.config/pihole-update.env}"
# shellcheck disable=SC1090
[[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

# ---------------------------------------------------------------- Konfiguration
PIHOLE_DIR="${PIHOLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
CONTAINER="${CONTAINER:-pihole}"
IMAGE_REPO="${IMAGE_REPO:-pihole/pihole}"
DATA_DIR="${DATA_DIR:-etc-pihole}"          # Bind-Mount mit /etc/pihole
TEST_DNS_IP="${TEST_DNS_IP:-192.168.178.146}"
TEST_DOMAIN_OK="${TEST_DOMAIN_OK:-heise.de}"
TEST_DOMAIN_BLOCKED="${TEST_DOMAIN_BLOCKED:-doubleclick.net}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"     # Sekunden bis Container healthy sein muss
NTFY_URL="${NTFY_URL:-}"                    # optional, z.B. https://ntfy.sh/mein-topic
NTFY_TOKEN="${NTFY_TOKEN:-}"                # Token eines Nutzers mit Schreibrecht auf das Topic
GIT_PUSH="${GIT_PUSH:-true}"
TAG_REGEX='^[0-9]{4}\.[0-9]{2}\.[0-9]+$'    # nur Release-Tags wie 2026.09.1

# ---------------------------------------------------------------- Hilfsfunktionen
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err()  { log ERROR "$*"; }

notify() {
    local title="$1" msg="$2" prio="${3:-default}" tags="${4:-}"
    [[ -n "$NTFY_URL" ]] || return 0
    local -a auth=()
    [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -fsS --max-time 10 "${auth[@]}" \
        -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
        -d "$msg" "$NTFY_URL" >/dev/null 2>&1 || warn "ntfy-Benachrichtigung fehlgeschlagen"
}

die() {
    err "$*"
    notify "Pi-hole Update abgebrochen" "$*" high warning
    exit 1
}

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

current_tag() {
    sed -nE "s#^[[:space:]]*image:[[:space:]]*${IMAGE_REPO}:([^[:space:]\"']+).*#\1#p" "$COMPOSE_FILE" | head -1
}

latest_tag() {
    # Docker Hub: alle Tags holen, auf Release-Schema filtern, versionssortiert höchstes nehmen
    curl -fsS --max-time 20 \
        "https://hub.docker.com/v2/repositories/${IMAGE_REPO}/tags?page_size=100&ordering=last_updated" \
      | jq -r '.results[].name' \
      | grep -E "$TAG_REGEX" \
      | sort -V | tail -1
}

wait_healthy() {
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT )) status
    while (( $(date +%s) < deadline )); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo missing)
        case "$status" in
            healthy) return 0 ;;
            exited|dead|missing) err "Container-Status: $status"; return 1 ;;
        esac
        sleep 3
    done
    err "Container nach ${HEALTH_TIMEOUT}s nicht healthy (Status: $status)"
    return 1
}

run_tests() {
    local ok=0 out

    # 1) Container healthy
    wait_healthy || return 1

    # 2) Normale Auflösung liefert eine IP
    out=$(dig +short +time=3 +tries=2 @"$TEST_DNS_IP" "$TEST_DOMAIN_OK" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    if [[ -n "$out" ]]; then
        info "Test OK: $TEST_DOMAIN_OK -> $out"
    else
        err "Test FEHLER: $TEST_DOMAIN_OK wird nicht aufgelöst"; ok=1
    fi

    # 3) Geblockte Domain liefert 0.0.0.0
    out=$(dig +short +time=3 +tries=2 @"$TEST_DNS_IP" "$TEST_DOMAIN_BLOCKED" A 2>/dev/null | head -1)
    if [[ "$out" == "0.0.0.0" ]]; then
        info "Test OK: $TEST_DOMAIN_BLOCKED -> geblockt"
    else
        err "Test FEHLER: $TEST_DOMAIN_BLOCKED -> '${out:-keine Antwort}' (erwartet 0.0.0.0)"; ok=1
    fi

    # 4) Blocking laut Pi-hole aktiv
    if docker exec "$CONTAINER" pihole status 2>/dev/null | grep -q 'blocking is enabled'; then
        info "Test OK: Blocking aktiv"
    else
        err "Test FEHLER: 'pihole status' meldet Blocking nicht als aktiv"; ok=1
    fi

    return $ok
}

# ---------------------------------------------------------------- Start
cd "$PIHOLE_DIR" || die "Verzeichnis $PIHOLE_DIR nicht gefunden"

# Nur eine Instanz gleichzeitig
exec 9>"$PIHOLE_DIR/.update.lock"
flock -n 9 || { warn "Läuft bereits, beende."; exit 0; }

for bin in curl jq dig git docker flock; do
    command -v "$bin" >/dev/null || die "Benötigtes Programm fehlt: $bin"
done
[[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_FILE nicht gefunden"

# ./pihole-update.sh --test  → nur Benachrichtigung und Tests prüfen, nichts ändern
if [[ "${1:-}" == "--test" ]]; then
    info "Testmodus: sende Probe-Benachrichtigung und führe Tests aus"
    [[ -n "$NTFY_URL" ]] || warn "NTFY_URL nicht gesetzt (ENV_FILE: $ENV_FILE)"
    notify "Pi-hole Update: Test" "Benachrichtigung funktioniert. Tag: $(current_tag)" low test_tube
    run_tests && info "Alle Tests OK" || die "Tests fehlgeschlagen"
    exit 0
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$PIHOLE_DIR ist kein Git-Repository"

OLD_TAG=$(current_tag)
[[ -n "$OLD_TAG" ]] || die "Kein 'image: ${IMAGE_REPO}:<tag>' in $COMPOSE_FILE gefunden"
[[ "$OLD_TAG" =~ $TAG_REGEX ]] || die "Image-Tag '$OLD_TAG' ist nicht gepinnt. Bitte zuerst ein Release-Tag (z.B. 2026.09.1) eintragen."

NEW_TAG=$(latest_tag)
[[ -n "$NEW_TAG" ]] || die "Konnte neuestes Tag nicht von Docker Hub ermitteln"

if [[ "$NEW_TAG" == "$OLD_TAG" ]]; then
    info "Bereits aktuell ($OLD_TAG), nichts zu tun."
    notify "Pihole Aktualisierung gelaufen" "Aber nichts neues steht bereit (${OLD_TAG})" default +1
    exit 0
fi
if [[ "$(printf '%s\n%s\n' "$OLD_TAG" "$NEW_TAG" | sort -V | tail -1)" != "$NEW_TAG" ]]; then
    warn "Gepinntes Tag $OLD_TAG ist neuer als Docker-Hub-Tag $NEW_TAG, überspringe."
    exit 0
fi

info "Update verfügbar: $OLD_TAG -> $NEW_TAG"

# Arbeitsbaum muss sauber sein, sonst committen wir Fremdes mit
if [[ -n "$(git status --porcelain -- "$COMPOSE_FILE")" ]]; then
    die "$COMPOSE_FILE hat uncommittete Änderungen, breche ab."
fi

# Vorab-Check: alte Version muss gerade funktionieren, sonst macht ein Rollback-Vergleich keinen Sinn
if ! run_tests; then
    die "Pi-hole ist bereits VOR dem Update defekt — kein Update, bitte manuell prüfen."
fi

# Neues Image zuerst ziehen; schlägt das fehl, wurde noch nichts verändert
info "Ziehe ${IMAGE_REPO}:${NEW_TAG} ..."
docker pull -q "${IMAGE_REPO}:${NEW_TAG}" >/dev/null || die "docker pull fehlgeschlagen"

# ---------------------------------------------------------------- Backup
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$PIHOLE_DIR/.backup-${OLD_TAG}-${STAMP}"
COMPOSE_BACKUP="$BACKUP_DIR/$(basename "$COMPOSE_FILE")"

info "Sichere $DATA_DIR und $COMPOSE_FILE nach $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || die "Backup-Verzeichnis konnte nicht angelegt werden"
cp -a "$COMPOSE_FILE" "$COMPOSE_BACKUP" || die "Backup der Compose-Datei fehlgeschlagen"
# Container kurz stoppen, damit die SQLite-Dateien konsistent kopiert werden
dc stop "$CONTAINER" >/dev/null 2>&1
if ! cp -a "$DATA_DIR" "$BACKUP_DIR/" ; then
    dc start "$CONTAINER" >/dev/null 2>&1
    rm -rf "$BACKUP_DIR"
    die "Backup von $DATA_DIR fehlgeschlagen, Container wieder gestartet"
fi

# ---------------------------------------------------------------- Update
info "Setze Tag in $COMPOSE_FILE auf $NEW_TAG"
sed -i -E "s#(image:[[:space:]]*${IMAGE_REPO}:)${OLD_TAG}#\1${NEW_TAG}#" "$COMPOSE_FILE"

if [[ "$(current_tag)" != "$NEW_TAG" ]]; then
    cp -a "$COMPOSE_BACKUP" "$COMPOSE_FILE"
    dc start "$CONTAINER" >/dev/null 2>&1
    die "Tag-Ersetzung in $COMPOSE_FILE fehlgeschlagen, alte Datei wiederhergestellt"
fi

info "Starte Container mit neuem Image ..."
dc up -d --remove-orphans

# ---------------------------------------------------------------- Test / Commit / Rollback
if run_tests; then
    info "Update auf $NEW_TAG erfolgreich"

    git add -- "$COMPOSE_FILE"
    if git commit -q -m "pihole: ${OLD_TAG} -> ${NEW_TAG}" -m "Automatisches Update via $(basename "$0") am $(date '+%F %T')"; then
        info "Commit erstellt"
        if [[ "$GIT_PUSH" == "true" ]]; then
            if git push -q; then
                info "Push erfolgreich"
            else
                warn "git push fehlgeschlagen — Commit liegt lokal vor"
                notify "Pi-hole aktualisiert, Push fehlgeschlagen" "$OLD_TAG -> $NEW_TAG läuft, aber git push schlug fehl." default warning
            fi
        fi
    else
        warn "git commit fehlgeschlagen"
    fi

    rm -rf "$BACKUP_DIR"
    docker image rm -f "${IMAGE_REPO}:${OLD_TAG}" >/dev/null 2>&1 || true
    notify "Pi-hole aktualisiert" "$OLD_TAG -> $NEW_TAG, alle Tests bestanden." low white_check_mark
    exit 0
fi

# ---- Rollback
err "Tests nach Update fehlgeschlagen — Rollback auf $OLD_TAG"
dc logs --tail 40 "$CONTAINER" 2>&1 | sed 's/^/    | /' || true

dc down >/dev/null 2>&1
cp -a "$COMPOSE_BACKUP" "$COMPOSE_FILE"
# Datenverzeichnis zurückspielen: neues FTL kann die DB migriert haben, altes FTL käme damit nicht klar
rm -rf "$DATA_DIR"
cp -a "$BACKUP_DIR/$(basename "$DATA_DIR")" "$DATA_DIR"
dc up -d --remove-orphans

if run_tests; then
    warn "Rollback auf $OLD_TAG erfolgreich, Pi-hole läuft wieder. Backup bleibt unter $BACKUP_DIR"
    notify "Pi-hole Update FEHLGESCHLAGEN, Rollback ok" "Update $OLD_TAG -> $NEW_TAG hat die Tests nicht bestanden. Läuft wieder auf $OLD_TAG. Logs in $BACKUP_DIR und im Cron-Log." high rotating_light
    exit 1
fi

err "ROLLBACK FEHLGESCHLAGEN — Pi-hole ist nicht funktionsfähig, manuelles Eingreifen nötig!"
notify "Pi-hole DOWN nach fehlgeschlagenem Rollback" "Weder $NEW_TAG noch $OLD_TAG laufen. Backup unter $BACKUP_DIR. DNS im Heimnetz ist aktuell gestört!" urgent sos
exit 2
