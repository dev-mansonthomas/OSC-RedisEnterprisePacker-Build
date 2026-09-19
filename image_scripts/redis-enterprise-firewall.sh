#!/usr/bin/env bash
# Apply the Redis Enterprise host firewall (UFW).
#
# Installed into the image as /usr/local/sbin/redis-enterprise-firewall.
#
# WHY THIS IS A SCRIPT IN THE IMAGE, NOT A FIXED RULE SET
#
# The image is deliberately unconfigured: one OMI serves every customer, so at build
# time we do not know which CIDRs will need access. A firewall baked with the customer's
# networks hardcoded would be wrong for everyone else.
#
# So the split mirrors the Build/Run split:
#
#   * At BUILD time this runs with no arguments. That applies PORT-scope defence: only
#     SSH and the ports Redis Enterprise actually uses are reachable, everything else is
#     denied. It is defence in depth against anything *else* that might ever listen on a
#     node -- not against the wrong client reaching a database.
#
#   * At RUN time the customer (or OSC-RedisEnterprisePacker-Run) re-runs it with real
#     CIDRs to add CIDR-scope defence:
#
#       redis-enterprise-firewall --cluster-cidr 10.0.0.0/16 \
#                                 --client-cidr  10.20.0.0/16 \
#                                 --operator-cidr 203.0.113.4/32
#
# Port assignments follow the Redis Enterprise port matrix:
# https://redis.io/docs/latest/operate/rs/networking/port-configurations/
# Cross-checked against `ss -tlnp` on a real node -- see
# docs/reference/hardening-baseline.md.
set -euo pipefail

CLUSTER_CIDR=""     # node-to-node; internal-only ports
CLIENT_CIDR="any"   # applications; database and discovery ports
OPERATOR_CIDR="any" # humans and tooling; SSH, UI, REST
ALLOW_INSECURE_REST=0
DRY_RUN=0

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-cidr)   CLUSTER_CIDR="${2:?}"; shift 2 ;;
    --client-cidr)    CLIENT_CIDR="${2:?}"; shift 2 ;;
    --operator-cidr)  OPERATOR_CIDR="${2:?}"; shift 2 ;;
    --allow-insecure-rest) ALLOW_INSECURE_REST=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Default the cluster CIDR to RFC1918 rather than "any": internode ports must never be
# world-reachable, and a private-range default is correct for every topology we support
# while still being narrower than "any".
[ -n "$CLUSTER_CIDR" ] || CLUSTER_CIDR="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

# ---------------------------------------------------------------- port definitions
# Reachable by client applications. 10000-19999 is database traffic: without it, no
# application can use a database at all.
# 53 is included over TCP as well as UDP: `ss -tlnp` on a real node showed
# 0.0.0.0:53 listening, and DNS falls back to TCP for responses over 512 bytes --
# which a cluster with many database endpoints will produce.
CLIENT_TCP="8001 53 10000:10049 10051:19999"
CLIENT_UDP="53 5353"   # cluster/database name resolution

# Reachable by operators and monitoring.
#   8443 Cluster Manager UI (TLS) · 9443 REST API (TLS) · 3346 REST / node bootstrap
#   8070 metrics exported by the web proxy
OPERATOR_TCP="8443 9443 3346 8070"

# Cleartext REST API. NOT opened by default: 9443 is its TLS twin and is already open,
# and a cleartext admin protocol fails a SecNumCloud review. Verified listening on a
# real node, so this is a live service being deliberately fenced off, not a no-op.
INSECURE_REST_TCP="8080"

# Node-to-node only. Omitting any of these breaks cluster formation -- 3344 and 3354
# were observed listening on a bare node, and the old commented-out rule set left out
# the whole 3333-3355 range, which is why enabling it would have broken a cluster.
#   1968 proxy · 3333:3345,3350:3354,36379 internode · 3346 bootstrap · 3355 auth
#   3357 internal · 3347:3349,8000,8071,9091,9125 internal metrics
#   8002,8004,8006 envoy health · 8444,9080 web proxy <-> cnm_http/cm
#   9081 CRDB coordinator · 9082 cluster API · 10050 Zabbix
#   20000:29999 database shard traffic
CLUSTER_TCP="1968 3333:3345 3346 3347:3349 3350:3354 3355 3357 8000 8001 8002 8004 8006 \
8070 8071 8443 8444 9080 9081 9082 9091 9125 9443 10050 10000:10049 10051:19999 20000:29999 36379"
CLUSTER_TCP="$CLUSTER_TCP 53 5353"
CLUSTER_UDP="53 5353"

# ---------------------------------------------------------------------- apply
run() { if [ "$DRY_RUN" -eq 1 ]; then echo "+ $*"; else "$@"; fi; }

allow() {  # allow <proto> <port-or-range> <cidr-list>
  local proto="$1" port="$2" cidrs="$3" cidr
  for cidr in $cidrs; do
    if [ "$cidr" = "any" ]; then
      run ufw allow proto "$proto" to any port "$port"
    else
      run ufw allow from "$cidr" proto "$proto" to any port "$port"
    fi
  done
}

echo "Applying Redis Enterprise firewall rules"
echo "  cluster CIDR : $CLUSTER_CIDR"
echo "  client CIDR  : $CLIENT_CIDR"
echo "  operator CIDR: $OPERATOR_CIDR"
echo "  cleartext REST 8080: $([ "$ALLOW_INSECURE_REST" -eq 1 ] && echo OPEN || echo denied)"

run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing

# Loopback. Several Redis ports bind 127.0.0.1 only (8002, 8004, 8444, 9081 observed),
# so without this the node breaks itself.
run ufw allow in on lo
run ufw allow out on lo

allow tcp 22 "$OPERATOR_CIDR"

for p in $OPERATOR_TCP; do allow tcp "$p" "$OPERATOR_CIDR"; done
for p in $CLIENT_TCP;   do allow tcp "$p" "$CLIENT_CIDR";   done
for p in $CLIENT_UDP;   do allow udp "$p" "$CLIENT_CIDR";   done
for p in $CLUSTER_TCP;  do allow tcp "$p" "$CLUSTER_CIDR";  done
for p in $CLUSTER_UDP;  do allow udp "$p" "$CLUSTER_CIDR";  done

if [ "$ALLOW_INSECURE_REST" -eq 1 ]; then
  for p in $INSECURE_REST_TCP; do allow tcp "$p" "$OPERATOR_CIDR"; done
fi

run ufw --force enable
run ufw status verbose
