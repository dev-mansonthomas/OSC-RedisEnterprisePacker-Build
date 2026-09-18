#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# _my_env.sh assigns unconditionally, so it would clobber anything already exported.
# Snapshot the knobs first and restore them afterwards, making the environment win over
# the file: needed to override a single value for one run (CI, tests, a pinned base OMI)
# without editing the operator's configuration.
_ENV_OVERRIDES=()
for _v in OUTSCALE_REGION OUTSCALE_SSH_KEY OUTSCALE_KEYPAIR_NAME OUTSCALE_SOURCE_OMI \
          OAPI_PROFILE UBUNTU_RELEASE MANIFEST_FILE ENV_FILE \
          BUILD_LOG_DIR BUILD_LOG_KEEP PACKER_OUT_LINK; do
  [[ -n "${!_v:-}" ]] && _ENV_OVERRIDES+=("$_v=${!_v}")
done

# _my_env.sh is operator-supplied and git-ignored: shellcheck cannot follow it.
# shellcheck source=/dev/null
source "$REPO_ROOT/_my_env.sh"

for _kv in ${_ENV_OVERRIDES[@]+"${_ENV_OVERRIDES[@]}"}; do
  export "${_kv%%=*}=${_kv#*=}"
done
unset _v _kv _ENV_OVERRIDES
# shellcheck source=build_scripts/lib/redis_version.sh
source "$REPO_ROOT/build_scripts/lib/redis_version.sh"
# shellcheck source=build_scripts/lib/env_file.sh
source "$REPO_ROOT/build_scripts/lib/env_file.sh"
# shellcheck source=build_scripts/lib/outscale_omi.sh
source "$REPO_ROOT/build_scripts/lib/outscale_omi.sh"

# Absolute paths throughout: the script used to depend on being run from
# build_scripts/ (TODO T-08).
HCL_FILE="$REPO_ROOT/packer/redis_ubuntu_outscale_image.pkr.hcl"
TARGET_REGION="$OUTSCALE_REGION"
# Surchargeable pour que les tests n'écrasent pas le manifest réel du dépôt.
MANIFEST_FILE="${MANIFEST_FILE:-$REPO_ROOT/build_scripts/manifest.json}"

# --- Redis Enterprise tarball: pre-flight ---
# Delegated to fetch_redis_tarball.sh, which (unlike the inline `ls | head -1` this
# replaces) refuses to guess between several tarballs and detects a filename that
# carries no usable version instead of silently mis-parsing it (TODO T-05).
# Télécharge automatiquement la dernière version si elle n'est pas déjà présente :
# publier une nouvelle image Redis Enterprise sans prendre la version courante n'aurait
# pas de sens. FETCH_OPTS="" pour ne construire qu'avec ce qui est déjà sur disque,
# FETCH_OPTS=--skip-version-check pour ne pas contacter le réseau du tout.
: "${FETCH_OPTS:=--download}"
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

# --- OMI de base : résolution automatique, ou épinglage explicite ---
#
# Par défaut on prend la dernière Ubuntu ${UBUNTU_RELEASE} x86_64/bsu publiée par
# Outscale, pour qu'une nouvelle image Redis Enterprise embarque aussi les correctifs
# système récents. Outscale republie tous les ~2 mois et dé-enregistre les anciennes au
# bout de ~10 : un ID figé dans le dépôt finit donc toujours par casser le build.
#
# Pour une mise à jour de CVE Redis Enterprise, où l'on veut changer le moins de choses
# possible, épinglez la base :
#     OUTSCALE_SOURCE_OMI=ami-xxxxxxxx ./build_and_deploy_redis_image_with_packer.sh
: "${UBUNTU_RELEASE:=22.04}"
SOURCE_OMI=""
SOURCE_OMI_NAME=""

if [[ "${SKIP_OMI_CHECK:-0}" == 1 ]]; then
  SOURCE_OMI="${OUTSCALE_SOURCE_OMI:?SKIP_OMI_CHECK=1 exige OUTSCALE_SOURCE_OMI}"
  SOURCE_OMI_NAME="non-verifie"
  echo "OMI de base : $SOURCE_OMI (épinglée, vérification ignorée)"

elif [[ -n "${OUTSCALE_SOURCE_OMI:-}" ]]; then
  if ! omi_info="$(osc_omi_describe "$OUTSCALE_SOURCE_OMI")"; then
    echo "" >&2
    echo "Erreur : l'OMI épinglée $OUTSCALE_SOURCE_OMI est introuvable dans $TARGET_REGION." >&2
    echo "         Outscale l'a probablement dé-enregistrée (rétention ~10 mois)." >&2
    echo "         Retirez OUTSCALE_SOURCE_OMI pour prendre la plus récente." >&2
    exit 1
  fi
  SOURCE_OMI="$(cut -f1 <<<"$omi_info")"
  SOURCE_OMI_NAME="$(cut -f2 <<<"$omi_info")"
  echo "OMI de base : $SOURCE_OMI  $SOURCE_OMI_NAME  (épinglée)"

else
  echo "Recherche de la dernière Ubuntu ${UBUNTU_RELEASE} x86_64 publiée par Outscale..."
  if ! omi_info="$(osc_latest_ubuntu_omi)"; then
    echo "" >&2
    echo "Erreur : impossible de résoudre une OMI Ubuntu ${UBUNTU_RELEASE}." >&2
    echo "         Vérifiez l'accès Outscale :  oapi-cli --profile default ReadVms" >&2
    echo "         Ou épinglez une base :       OUTSCALE_SOURCE_OMI=ami-xxxxxxxx $0" >&2
    exit 1
  fi
  SOURCE_OMI="$(cut -f1 <<<"$omi_info")"
  SOURCE_OMI_NAME="$(cut -f2 <<<"$omi_info")"
  echo "OMI de base : $SOURCE_OMI  $SOURCE_OMI_NAME  ($(cut -f3 <<<"$omi_info"))"
fi

if [[ ! "$SOURCE_OMI" =~ ^ami-[0-9a-f]+$ ]]; then
  echo "Erreur : OMI de base invalide ('$SOURCE_OMI')" >&2
  exit 1
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

packer init "$HCL_FILE"

# juste avant packer build
args=(
  -var "region=${TARGET_REGION}"
  -var "keypair_private_file=${OUTSCALE_SSH_KEY}"
  -var "keypair_name=${OUTSCALE_KEYPAIR_NAME}"
  -var "redis_version=${REDIS_VERSION}"
  -var "source_omi=${SOURCE_OMI}"
  -var "source_omi_name=${SOURCE_OMI_NAME}"
)
# optionnel: si BUILD_OPTS n'est pas vide, on l’ajoute proprement
# validate AVANT build, avec exactement les mêmes variables : appelé sans -var, il
# échouait sur "a source_omi must be specified" alors que rien n'était cassé.
packer validate "${args[@]}" "$HCL_FILE"

(( ${#BUILD_OPTS[@]} )) && args+=("${BUILD_OPTS[@]}")

# --- Journalisation du build ---
# packer.out était écrasé à chaque build : la trace du build précédent était perdue,
# alors que c'est la seule preuve de ce qu'une OMI publiée contient. Chaque build écrit
# donc un log horodaté dans debug/build-logs/, et packer.out devient un lien vers le
# dernier (le nom est conservé : le README et les habitudes y font référence).
BUILD_LOG_DIR="${BUILD_LOG_DIR:-$REPO_ROOT/debug/build-logs}"
BUILD_LOG_KEEP="${BUILD_LOG_KEEP:-10}"
mkdir -p "$BUILD_LOG_DIR"
BUILD_LOG="$BUILD_LOG_DIR/packer-$(date -u +%Y%m%dT%H%M%SZ)-${REDIS_VERSION}.log"

echo "Journal du build : ${BUILD_LOG#"$REPO_ROOT/"}"

set -x  # pour voir exactement les args passés
PACKER_LOG=1 PACKER_LOG_PATH="$BUILD_LOG" \
  packer build "${args[@]}" "$HCL_FILE"
set +x

# packer.out : lien vers le dernier log, pour ne pas casser les usages existants.
# Surchargeable, et volontairement : un test exécutant ce script avec un BUILD_LOG_DIR
# temporaire a déjà remplacé le packer.out réel par un lien vers ce temporaire, puis
# détruit la cible -- le journal d'un vrai build a été perdu ainsi.
PACKER_OUT_LINK="${PACKER_OUT_LINK:-$REPO_ROOT/build_scripts/packer.out}"
ln -sfn "$BUILD_LOG" "$PACKER_OUT_LINK"

# Rotation : les logs font ~350 Ko chacun.
# Noms générés par nous (packer-<ISO>-<version>.log) donc triables lexicalement :
# pas besoin de ls -t, ce qui évite de parser une sortie de ls.
mapfile -t _old_logs < <(
  printf '%s\n' "$BUILD_LOG_DIR"/packer-*.log \
    | grep -v '\*' | sort -r | tail -n +"$((BUILD_LOG_KEEP + 1))"
)
if (( ${#_old_logs[@]} )); then
  echo "Rotation des journaux : suppression de ${#_old_logs[@]} log(s) au-delà de $BUILD_LOG_KEEP"
  rm -f "${_old_logs[@]}"
fi
unset _old_logs

# --- Extract the OMI ID from manifest.json ---
# This value is what OSC-RedisEnterprisePacker-Run consumes to launch nodes, so a
# wrong or stale one launches the WRONG IMAGE. Both failure modes used to pass
# silently: a missing manifest only warned and exited 0, and a last_run_uuid
# matching no build produced an empty ID that was written out anyway (TODO T-06).
# Surchargeable, comme MANIFEST_FILE : sans cela un test qui exécute le wrapper écrit
# un faux OUTSCALE_AMI_ID dans la configuration réelle de l'opérateur.
ENV_FILE="${ENV_FILE:-$REPO_ROOT/_my_env.sh}"

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

# Résumé lisible à côté du journal : un log de 350 Ko ne dit pas d'un coup d'oeil quelle
# OMI il a produite ni sur quelle base.
cat > "${BUILD_LOG%.log}.summary.txt" <<SUMMARY
build_finished   $(date -u +%Y-%m-%dT%H:%M:%SZ)
omi_id           $AMI_ID
omi_region       $TARGET_REGION
redis_version    $REDIS_VERSION
source_omi       $SOURCE_OMI
source_omi_name  $SOURCE_OMI_NAME
ubuntu_release   $UBUNTU_RELEASE
packer_log       ${BUILD_LOG#"$REPO_ROOT/"}
SUMMARY
echo "Résumé du build : ${BUILD_LOG%.log}.summary.txt" | sed "s#$REPO_ROOT/##"

# --- Le build a réussi : les tarballs de la version précédente ne servent plus ---
# fetch_redis_tarball.sh les parque dans redis-software/old/ au lieu de les supprimer,
# pour qu'un build raté puisse être relancé sur la version d'avant. Une fois l'OMI
# produite et son ID validé, cette sécurité n'a plus d'objet : ~1 Go récupéré.
OLD_DIR="$REPO_ROOT/redis-software/old"
if [[ -d "$OLD_DIR" ]]; then
  shopt -s nullglob
  old_files=("$OLD_DIR"/*)
  shopt -u nullglob
  if (( ${#old_files[@]} )); then
    freed="$(du -sh "$OLD_DIR" 2>/dev/null | cut -f1)"
    echo "Build réussi : purge de redis-software/old/ (${#old_files[@]} fichier(s), ${freed:-?})"
    for f in "${old_files[@]}"; do
      echo "  rm $(basename "$f")"
      rm -f "$f"
    done
    rmdir "$OLD_DIR" 2>/dev/null || true
  fi
fi

# Warn about leftovers from the old append-only behaviour.
dupes="$(env_legacy_duplicates "$ENV_FILE" OUTSCALE_AMI_ID)"
if (( dupes > 1 )); then
  echo "ATTENTION : $ENV_FILE contient $dupes affectations de OUTSCALE_AMI_ID." >&2
  echo "            Les anciennes lignes, hors bloc genere, doivent etre supprimees" >&2
  echo "            a la main -- sinon 'source' peut retenir la mauvaise valeur." >&2
fi
