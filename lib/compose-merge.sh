#!/usr/bin/env bash
# lib/compose-merge.sh — merges the selected modules' compose.yml files into a
# single canonical /etc/vibe-sentinel/compose.yml via `docker compose config`.
# Modules stay self-contained (each declares its own networks/volumes; Compose
# unions them on merge); cross-module startup ordering is enforced by the
# install.sh health-gated first-boot sequence, not depends_on.
# shellcheck shell=bash

# Copy module directories (compose + config assets referenced via
# ${SENTINEL_MODULES_DIR}) into /etc/vibe-sentinel/modules so the running
# stack never depends on the installer checkout location.
stage_modules() {
  local m
  mkdir -p "$SENTINEL_ETC/modules"
  for m in $SELECTED_MODULES; do
    rm -rf "$SENTINEL_ETC/modules/$m"
    cp -a "$INSTALLER_ROOT/modules/$m" "$SENTINEL_ETC/modules/$m"
  done
  # relay sub-module ships with mesh but is only merged when enabled
  chmod -R go-rwx "$SENTINEL_ETC/modules"
}

module_compose_files() { # echoes -f args for every selected module with services
  local m
  for m in $SELECTED_MODULES; do
    [ "$m" = "ai" ] && continue   # ai is config-only: no containers (plan §2.5)
    printf ' -f %s/modules/%s/compose.yml' "$SENTINEL_ETC" "$m"
  done
  if module_selected mesh && [ "$(config_get '.modules.mesh.relay_enabled' 'false')" = "true" ]; then
    printf ' -f %s/modules/mesh/relay/compose.yml' "$SENTINEL_ETC"
  fi
}

merge_compose() {
  local files
  files="$(module_compose_files)"
  log "Merging module compose files: $files"
  # shellcheck disable=SC2086
  if ! docker compose --project-name vibe-sentinel --project-directory "$SENTINEL_ETC" \
        --env-file "$SENTINEL_ENV_FILE" $files config -o "$SENTINEL_COMPOSE.tmp"; then
    die "docker compose config failed while merging module files." \
        "Run the command above manually to see the offending module; fix its env.schema values in $SENTINEL_ENV_FILE."
  fi
  mv "$SENTINEL_COMPOSE.tmp" "$SENTINEL_COMPOSE"
  chmod 600 "$SENTINEL_COMPOSE"
  log_ok "Merged compose written to $SENTINEL_COMPOSE"
}

# Validate that every required key in each selected module's env.schema is
# present in the generated .env. Format: KEY=description:required|optional
validate_env_schema() {
  local m schema line key requirement missing=0
  for m in $SELECTED_MODULES; do
    schema="$INSTALLER_ROOT/modules/$m/env.schema"
    [ -f "$schema" ] || continue
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue;; esac
      key="${line%%=*}"
      requirement="${line##*:}"
      if [ "$requirement" = "required" ] && ! grep -q "^${key}=" "$SENTINEL_ENV_FILE"; then
        log_err "Module '$m' requires env key '$key' but it is missing from $SENTINEL_ENV_FILE"
        missing=1
      fi
    done <"$schema"
  done
  [ "$missing" -eq 0 ] || die "Environment is incomplete for the selected modules." \
    "Re-run the wizard (bash install.sh) or add the missing keys to $SENTINEL_ENV_FILE."
  log_ok "env.schema validation passed for: $SELECTED_MODULES"
}
