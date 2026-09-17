#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# _my_env.sh is operator-supplied and git-ignored: shellcheck cannot follow it.
# shellcheck source=/dev/null
source "$REPO_ROOT/_my_env.sh"
# shellcheck source=build_scripts/lib/redis_version.sh
source "$REPO_ROOT/build_scripts/lib/redis_version.sh"
# shellcheck source=build_scripts/lib/env_file.sh
source "$REPO_ROOT/build_scripts/lib/env_file.sh"

# Absolute paths throughout: the script used to depend on being run from
# build_scripts/ (TODO T-08).
HCL_FILE="$REPO_ROOT/packer/redis_ubuntu_outscale_image.pkr.hcl"
TARGET_REGION="$OUTSCALE_REGION"
MANIFEST_FILE="$REPO_ROOT/build_scripts/manifest.json"

# --- Redis Enterprise tarball: pre-flight ---
# Delegated to fetch_redis_tarball.sh, which (unlike the inline `ls | head -1` this
# replaces) refuses to guess between several tarballs and detects a filename that
# carries no usable version instead of silently mis-parsing it (TODO T-05).
# Set FETCH_OPTS=--download to fetch the latest, or --skip-version-check to stay offline.
: "${FETCH_OPTS:=}"
# shellcheck disable=SC2086  # FETCH_OPTS is a deliberate option list
PREFLIGHT="$("$REPO_ROOT/build_scripts/fetch_redis_tarball.sh" $FETCH_OPTS)" || exit 1
printf '%s\n' "$PREFLIGHT"

REDIS_VERSION="$(printf '%s' "$PREFLIGHT" | sed -n 's/^REDIS_VERSION=//p' | tail -1)"
if ! rcv_is_valid_version "$REDIS_VERSION"; then
  echo "Erreur : version Redis Enterprise invalide ou absente ('$REDIS_VERSION')" >&2
  exit 1
fi

export PKR_VAR_redis_version="$REDIS_VERSION"
echo "REDIS_VERSION : '$REDIS_VERSION'"
echo "Attendu par Packer: redis-software/$(rcv_tarball_name "$REDIS_VERSION")"

# --- Required configuration ---
: "${OUTSCALE_REGION:?OUTSCALE_REGION manquant dans _my_env.sh}"
: "${OUTSCALE_SSH_KEY:?OUTSCALE_SSH_KEY manquant dans _my_env.sh}"
: "${OUTSCALE_KEYPAIR_NAME:=outscale-tmanson-keypair}"

# Packer cannot express a cross-variable precondition, so the region -> OMI lookup is
# checked here where the message can actually help (TODO T-10).
if ! grep -qE "\"${TARGET_REGION}\"[[:space:]]*=" "$HCL_FILE"; then
  echo "Erreur : aucune OMI de base connue pour la région '${TARGET_REGION}'." >&2
  echo "         Ajoutez une entrée à source_omi_by_region dans :" >&2
  echo "           $HCL_FILE" >&2
  echo "         L'ID courant d'Ubuntu 22.04 se trouve avec :" >&2
  echo "           oapi-cli ReadImages --Filters '{\"ImageNames\":[\"Ubuntu-22.04-*\"]}'" >&2
  exit 1
fi

# --- L'OMI de base existe-t-elle encore ? ---
# Outscale republie une OMI Ubuntu 22.04 tous les ~2 mois et dé-enregistre les
# anciennes au bout de ~10 mois. `packer validate` ne le voit PAS : il vérifie
# seulement que source_omi est non vide. Le 2026-09-17, l'ID épinglé avait déjà
# disparu -- le build aurait échoué tardivement, après l'upload du tarball.
# Contrôle en lecture seule ; ignorable avec SKIP_OMI_CHECK=1.
SOURCE_OMI="$(sed -nE "s/^[[:space:]]*\"${TARGET_REGION}\"[[:space:]]*=[[:space:]]*\"(ami-[0-9a-f]+)\".*/\1/p" "$HCL_FILE" | head -1)"

if [[ "${SKIP_OMI_CHECK:-0}" != 1 ]] && command -v oapi-cli >/dev/null; then
  echo "Vérification de l'OMI de base ${SOURCE_OMI} dans ${TARGET_REGION}..."
  if omi_json="$(oapi-cli --profile "${OAPI_PROFILE:-default}" ReadImages \
                   --Filters "{\"ImageIds\":[\"${SOURCE_OMI}\"]}" 2>/dev/null)" \
     && [[ "$(printf '%s' "$omi_json" | jq -r '(.Images // []) | length')" == "1" ]]; then
    echo "  OK : $(printf '%s' "$omi_json" | jq -r '.Images[0].ImageName')"
  else
    echo "" >&2
    echo "Erreur : l'OMI de base ${SOURCE_OMI} est introuvable dans ${TARGET_REGION}." >&2
    echo "         Outscale l'a probablement dé-enregistrée. Trouvez la plus récente :" >&2
    echo "" >&2
    echo "  oapi-cli --profile default ReadImages \\" >&2
    echo "    --Filters '{\"AccountAliases\":[\"Outscale\"],\"Architectures\":[\"x86_64\"],\"States\":[\"available\"]}' \\" >&2
    echo "  | jq -r '.Images[] | select(.ImageName|test(\"ubuntu\";\"i\"))" >&2
    echo "           | select(.ImageName|test(\"22[.-]?04\"))" >&2
    echo "           | \"\\(.ImageId)  \\(.ImageName)  \\(.CreationDate)\"' | sort -k3" >&2
    echo "" >&2
    echo "         Puis mettez à jour source_omi_by_region dans :" >&2
    echo "           $HCL_FILE" >&2
    echo "         (SKIP_OMI_CHECK=1 pour passer outre)" >&2
    exit 1
  fi
else
  echo "Vérification de l'OMI de base ignorée (oapi-cli absent ou SKIP_OMI_CHECK=1)."
fi

# La clé privée n'existe que sur l'hôte : ce contrôle échoue volontairement dans la VM,
# où le build n'est de toute façon pas exécutable (voir le modèle de sécurité global).
if [[ ! -r "$OUTSCALE_SSH_KEY" ]]; then
  echo "Erreur : clé privée illisible : $OUTSCALE_SSH_KEY" >&2
  echo "         Le build s'exécute depuis l'hôte, pas depuis la VM." >&2
  exit 1
fi

# Parse optional -debug flag to enable Packer debug mode
BUILD_OPTS=()
if [[ "${1:-}" == "-debug" ]]; then
  BUILD_OPTS=(-debug -on-error=ask)
fi



# The manifest post-processor writes relative to the CWD, and the HCL's file
# provisioners use ../ paths, so keep packer anchored in build_scripts/.
cd "$REPO_ROOT/build_scripts"

packer init     "$HCL_FILE"
packer validate "$HCL_FILE"


# juste avant packer build
args=(
  -var "region=${TARGET_REGION}"
  -var "keypair_private_file=${OUTSCALE_SSH_KEY}"
  -var "keypair_name=${OUTSCALE_KEYPAIR_NAME}"
  -var "redis_version=${REDIS_VERSION}"
)
# optionnel: si BUILD_OPTS n'est pas vide, on l’ajoute proprement
(( ${#BUILD_OPTS[@]} )) && args+=("${BUILD_OPTS[@]}")

set -x  # pour voir exactement les args passés
PACKER_LOG=1 PACKER_LOG_PATH=packer.out \
  packer build "${args[@]}" "$HCL_FILE"
set +x

# --- Extract the OMI ID from manifest.json ---
# This value is what OSC-RedisEnterprisePacker-Run consumes to launch nodes, so a
# wrong or stale one launches the WRONG IMAGE. Both failure modes used to pass
# silently: a missing manifest only warned and exited 0, and a last_run_uuid
# matching no build produced an empty ID that was written out anyway (TODO T-06).
ENV_FILE="$REPO_ROOT/_my_env.sh"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Erreur : $MANIFEST_FILE introuvable -- le build n'a pas produit d'artefact." >&2
  exit 1
fi

LAST_UUID="$(jq -r '.last_run_uuid // empty' "$MANIFEST_FILE")"
if [[ -z "$LAST_UUID" ]]; then
  echo "Erreur : last_run_uuid absent de $MANIFEST_FILE" >&2
  exit 1
fi

ARTIFACT_ID="$(jq -r --arg uuid "$LAST_UUID" \
  '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' "$MANIFEST_FILE" | tail -1)"
AMI_ID="${ARTIFACT_ID##*:}"

if [[ ! "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]]; then
  echo "Erreur : OMI ID invalide extrait du manifest ('$AMI_ID')" >&2
  echo "         last_run_uuid=$LAST_UUID artifact_id='$ARTIFACT_ID'" >&2
  exit 1
fi

echo "OUTSCALE_AMI_ID for Outscale in region $TARGET_REGION: $AMI_ID"

# Rewritten in place, not appended: appending left several OUTSCALE_AMI_ID lines and
# `source` silently kept the last one (TODO T-01).
env_write_block "$ENV_FILE" outscale-omi "OUTSCALE_AMI_ID=$AMI_ID"
echo "OUTSCALE_AMI_ID written to $ENV_FILE"

# Warn about leftovers from the old append-only behaviour.
dupes="$(env_legacy_duplicates "$ENV_FILE" OUTSCALE_AMI_ID)"
if (( dupes > 1 )); then
  echo "ATTENTION : $ENV_FILE contient $dupes affectations de OUTSCALE_AMI_ID." >&2
  echo "            Les anciennes lignes, hors bloc genere, doivent etre supprimees" >&2
  echo "            a la main -- sinon 'source' peut retenir la mauvaise valeur." >&2
fi
