#!/usr/bin/env bash
# Runs the Drupal.org GitLab CI template jobs against local module checkouts.
#
#   drupal-ci [all|<module>] [job ...]
#   drupal-ci list <module>
#   drupal-ci origins
set -uo pipefail

: "${MODULES_DIR:?MODULES_DIR is not set}"
: "${TEMPLATES_REPO:?TEMPLATES_REPO is not set}"
: "${TEMPLATES_REF:?TEMPLATES_REF is not set}"
export HOME="${HOME:-/gcl-home}"

# Stand-ins for the instance-level variables drupal.org injects.
mkdir -p "$HOME/.gitlab-ci-local"
cat > "$HOME/.gitlab-ci-local/variables.yml" <<VARS
---
global:
  _GITLAB_TEMPLATES_REPO: ${TEMPLATES_REPO}
  _GITLAB_TEMPLATES_REF: ${TEMPLATES_REF}
VARS

git config --global safe.directory '*'
# Clear an earlier insteadOf rewrite that persisted in the gcl-home volume.
for sec in 'url.git@git.drupalcode.org:' 'url.https://git.drupalcode.org/'; do
  git config --global --remove-section "$sec" 2>/dev/null || true
done

# gitlab-ci-local fetches `project:` includes with `git archive --remote` over SSH,
# which drupal.org does not serve. It skips the fetch when the file is already in
# <module>/.gitlab-ci-local/includes/<origin host>/<project>/<ref>/, so clone the
# templates once over public HTTPS and copy them there before each run.
TEMPLATES_HOST="${TEMPLATES_HOST:-git.drupalcode.org}"
TEMPLATES_DIR="$HOME/templates"
templates_ready=0

fetch_templates() {
  [ "$templates_ready" = 1 ] && return 0
  local url="https://${TEMPLATES_HOST}/${TEMPLATES_REPO}.git"
  if [ -d "$TEMPLATES_DIR/.git" ]; then
    git -C "$TEMPLATES_DIR" fetch --quiet --depth 1 origin "$TEMPLATES_REF" \
      && git -C "$TEMPLATES_DIR" checkout --quiet -f FETCH_HEAD \
      || echo "warning: could not refresh templates, using the cached copy"
  else
    git clone --quiet --depth 1 --branch "$TEMPLATES_REF" "$url" "$TEMPLATES_DIR" \
      || { echo "error: could not clone $url at $TEMPLATES_REF"; return 1; }
  fi
  templates_ready=1
}

# Host part of a module's raw origin URL (ssh scp-style, ssh:// or https://).
host_of() {
  origin_of "$1" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##'
}

# Reading many small files through the macOS bind mount is very slow (a plain
# `find` over one module took 10 minutes), and gitlab-ci-local scans and copies the
# whole working directory several times per run. So each run works on a copy of the
# module kept in the gcl-home Docker volume: sync_module copies it once, skipping
# vendor/ and node_modules/ (CI rebuilds those, and GitLab never sees them), and
# artifacts and the include cache live in the volume too. The module itself is only
# ever read, never written. --state-dir takes a path relative to the working dir.
now_ms() { echo $(( ${EPOCHREALTIME/./} / 1000 )); }

# timed <label> <command...> runs the command and prints its wall time to stderr.
timed() {
  local label="$1" start rc; shift
  start="$(now_ms)"
  "$@"; rc=$?
  echo "[timing] $label: $(( $(now_ms) - start )) ms" >&2
  return $rc
}

work_abs()  { echo "$HOME/work/$1"; }
state_abs() { echo "$HOME/state/$1"; }
state_rel() { realpath -m --relative-to="$(work_abs "$1")" "$(state_abs "$1")"; }

sync_module() {
  local mod="$1"
  mkdir -p "$(work_abs "$mod")"
  # --delete-excluded also clears job output left in the copy by earlier runs (web/,
  # composer.lock, build.env, ...). Without it the excluded node_modules protect
  # web/core from deletion, and stale files change what the `exists:` rules see.
  rsync -a --delete --delete-excluded \
    --exclude /vendor --exclude node_modules --exclude /.gitlab-ci-local \
    "$MODULES_DIR/$mod"/ "$(work_abs "$mod")"/
}

seed_includes() {
  local mod="$1" dir="$MODULES_DIR/$1" host
  host="$(host_of "$mod")"
  fetch_templates || return 1
  local dest="$(state_abs "$mod")/includes/$host/$TEMPLATES_REPO/$TEMPLATES_REF"
  mkdir -p "$dest" && rsync -a --delete --exclude .git "$TEMPLATES_DIR"/ "$dest"/
}

modules() {
  for d in "$MODULES_DIR"/*/; do
    [ -f "${d}.gitlab-ci.yml" ] && basename "$d"
  done
}

origin_of() {
  # config --get returns the raw URL; get-url would apply the insteadOf rewrite.
  git -C "$MODULES_DIR/$1" config --get remote.origin.url 2>/dev/null || echo "none"
}

# List once per module; the listing evaluates `exists:` globs over the working copy.
module_jobs() {
  ( cd "$(work_abs "$1")" && gitlab-ci-local --state-dir "$(state_rel "$1")" --list 2>/dev/null ) \
    | sed 's/\x1b\[[0-9;]*m//g'
}

has_job() {
  grep -qE "(^|[[:space:]])$1([[:space:]]|\$)" <<< "$job_list"
}

run_module() {
  local mod="$1"; shift
  local dir="$MODULES_DIR/$mod" job
  local selected=()

  [ -f "$dir/.gitlab-ci.yml" ] || { echo "no .gitlab-ci.yml in $mod"; return 2; }

  case "$(origin_of "$mod")" in
    *git.drupalcode.org*|*git.drupal.org*) ;;
    *) echo "warning: origin of $mod is $(origin_of "$mod"), so template includes may not resolve" ;;
  esac

  timed "sync $mod" sync_module "$mod"
  timed "seed includes $mod" seed_includes "$mod" || return 1

  local job_list; job_list="$(timed "list jobs $mod" module_jobs "$mod")"
  for job in "$@"; do
    if has_job "$job"; then selected+=("$job"); else echo "skip $job (not defined in $mod)"; fi
  done
  [ ${#selected[@]} -gt 0 ] || { echo "nothing to run for $mod"; return 0; }

  # JOB_PLATFORM (set by `make phpunit`) makes Docker pull job images for another
  # platform. It is applied here only, so this container itself stays native.
  # Composer's download cache lives in a named volume shared by every job container,
  # so packages are fetched once instead of on every run. COMPOSER_CACHE=0 turns it off.
  local cache_args=()
  if [ "${COMPOSER_CACHE:-1}" != 0 ]; then
    cache_args=(--volume composer-cache:/composer-cache --variable COMPOSER_CACHE_DIR=/composer-cache)
  fi

  timed "run jobs $mod (${selected[*]})" bash -c '
    cd "$1" && shift
    [ -z "${JOB_PLATFORM:-}" ] || export DOCKER_DEFAULT_PLATFORM="$JOB_PLATFORM"
    exec gitlab-ci-local "$@"' _ "$(work_abs "$mod")" \
      --state-dir "$(state_rel "$mod")" "${cache_args[@]}" --needs "${selected[@]}"
}

case "${1:-all}" in
  origins)
    for m in $(modules); do printf '%-40s %s\n' "$m" "$(origin_of "$m")"; done
    exit 0 ;;
  list)
    [ -n "${2:-}" ] || { echo "usage: drupal-ci list <module>"; exit 2; }
    timed "sync $2" sync_module "$2"; timed "seed includes $2" seed_includes "$2" || exit 1
    cd "$(work_abs "$2")" && exec gitlab-ci-local --state-dir "$(state_rel "$2")" --list ;;
esac

target="${1:-all}"; shift || true
jobs=("$@")
if [ ${#jobs[@]} -eq 0 ]; then read -r -a jobs <<< "${DEFAULT_JOBS:-composer phpcs phpstan cspell eslint stylelint phpunit}"; fi

if [ "$target" = "all" ]; then mapfile -t targets < <(modules); else targets=("$target"); fi
[ ${#targets[@]} -gt 0 ] || { echo "no modules with .gitlab-ci.yml under $MODULES_DIR"; exit 2; }

failed=()
for m in "${targets[@]}"; do
  echo; echo "===== $m ====="
  run_module "$m" "${jobs[@]}" || failed+=("$m")
done

echo
if [ ${#failed[@]} -eq 0 ]; then echo "All modules passed."; else echo "Failed: ${failed[*]}"; exit 1; fi
