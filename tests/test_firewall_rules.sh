#!/usr/bin/env bash
# The UFW rule set must cover every port a RUNNING cluster needs. Getting this wrong is
# not a cosmetic failure: the previous, commented-out rule set omitted the 3333-3355
# internode range, so enabling it would have prevented a cluster from forming at all.
#
# Checked against two independent sources:
#   1. the Redis Enterprise port matrix
#      https://redis.io/docs/latest/operate/rs/networking/port-configurations/
#   2. `ss -tlnp` measured on a real node -- docs/reference/hardening-baseline.md
set -uo pipefail
source "$(dirname "$0")/assert.sh"
FW="$(cd "$(dirname "$0")/.." && pwd)/image_scripts/redis-enterprise-firewall.sh"

PLAN="$(bash "$FW" --dry-run 2>/dev/null)"

# covered <proto> <port> -- is that port allowed by some rule, singly or in a range?
#
# Deliberately NOT a pipeline ending in `grep -q`: this file runs with `set -o pipefail`,
# `grep -q` exits at its first match, and the upstream stages then die of SIGPIPE, so the
# pipeline returns 141. The result depended on where the matching rule happened to sit in
# the list, which produced failures for 8443, 9443, 3346, 9082, 10000 and 19999 while
# 8070, 9080 and 10050 passed -- with every rule correctly present.
covered() {
  local proto="$1" port="$2" spec lo hi
  while IFS= read -r spec; do
    lo="${spec%%:*}"; hi="${spec##*:}"
    [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ] && return 0
  done <<< "$(
    printf '%s\n' "$PLAN" | grep "proto $proto" \
      | grep -oE 'port [0-9]+(:[0-9]+)?' | sed 's/port //'
  )"
  return 1
}

# ---------- ports measured listening on a real (un-bootstrapped) node ----------
# TCP 53 included: `ss -tlnp` showed 0.0.0.0:53, and DNS uses TCP for large responses.
for p in 22 53 3344 3354 8070 8080 8443 9080 9443 8002 8004 8444 9081; do
  it "covers TCP $p, observed listening on a real node"
  if [ "$p" = 8080 ]; then
    # Deliberately denied: cleartext REST, and 9443 is its TLS twin.
    assert_status 1 covered tcp "$p"
  else
    assert_status 0 covered tcp "$p"
  fi
done

# ---------- ports a FORMED cluster needs, from the Redis matrix ----------
# Absent from the bare-node measurement: these appear once a cluster and databases
# exist, which is exactly the gap that made the old rule set look adequate.
it "covers the proxy port 1968"
assert_status 0 covered tcp 1968

it "covers the internode range at its low end (3333)"
assert_status 0 covered tcp 3333

it "covers the internode range at its high end (3345)"
assert_status 0 covered tcp 3345

it "covers the node bootstrap port 3346"
assert_status 0 covered tcp 3346

it "covers the internal metrics range 3347-3349"
assert_status 0 covered tcp 3348

it "covers the second internode range 3350-3354"
assert_status 0 covered tcp 3351

it "covers the authentication service port 3355"
assert_status 0 covered tcp 3355

it "covers 3357, which the security group still omits (T-29)"
assert_status 0 covered tcp 3357

it "covers 8000, internal metrics"
assert_status 0 covered tcp 8000

it "covers 8006, envoy gossip admin"
assert_status 0 covered tcp 8006

it "covers 8071, internal metrics"
assert_status 0 covered tcp 8071

it "covers 9082, the cluster API"
assert_status 0 covered tcp 9082

it "covers 9091 and 9125, internal metrics"
assert_status 0 covered tcp 9091
it "covers 9125"
assert_status 0 covered tcp 9125

it "covers 10050, Zabbix monitoring"
assert_status 0 covered tcp 10050

it "covers 36379, internode"
assert_status 0 covered tcp 36379

it "covers database traffic at 10000"
assert_status 0 covered tcp 10000

it "covers database traffic at 19999"
assert_status 0 covered tcp 19999

it "covers shard traffic at 20000"
assert_status 0 covered tcp 20000

it "covers shard traffic at 29999"
assert_status 0 covered tcp 29999

it "covers the discovery service on 8001"
assert_status 0 covered tcp 8001

it "covers mDNS on UDP 5353"
assert_status 0 covered udp 5353

it "covers DNS on UDP 53"
assert_status 0 covered udp 53

# ---------- the shape of the policy ----------
it "denies incoming by default"
assert_contains "$PLAN" "default deny incoming"

it "allows outgoing"
assert_contains "$PLAN" "default allow outgoing"

it "allows loopback in -- several Redis ports bind 127.0.0.1 only"
assert_contains "$PLAN" "allow in on lo"

it "resets first, so re-running is idempotent rather than cumulative"
assert_contains "$(printf '%s\n' "$PLAN" | grep '^+ ufw' | head -1)" "ufw --force reset"

it "enables the firewall at the end"
assert_contains "$PLAN" "ufw --force enable"

it "defaults internode ports to RFC1918, never to 'any'"
assert_contains "$PLAN" "from 10.0.0.0/8 proto tcp to any port 3333:3345"

it "does not expose internode ports to the world by default"
# i.e. no unqualified "to any port" rule for the internode range -- only from-CIDR ones.
assert_eq "" "$(printf '%s\n' "$PLAN" | grep -F '+ ufw allow proto tcp to any port 3333:3345' || true)"

# ---------- CIDR scoping at run time ----------
# SSH must stay reachable: losing management access to a running node is worse than
# leaving port 22 open, and there is no console fallback on Outscale. Narrowing it is
# therefore opt-in, so a single wrong --operator-cidr cannot lock the operator out.
it "leaves SSH open to any even when an operator CIDR narrows the admin plane"
assert_contains "$(bash "$FW" --dry-run --operator-cidr 203.0.113.4/32 2>/dev/null)" \
  "+ ufw allow proto tcp to any port 22"

it "and says how to narrow it, rather than silently leaving it open"
assert_contains "$(bash "$FW" --dry-run --operator-cidr 203.0.113.4/32 2>/dev/null)" \
  "pass --scope-ssh"

it "narrows SSH only when --scope-ssh is given as well"
assert_contains "$(bash "$FW" --dry-run --operator-cidr 203.0.113.4/32 --scope-ssh 2>/dev/null)" \
  "from 203.0.113.4/32 proto tcp to any port 22"

it "and then no longer allows SSH from anywhere"
assert_eq "" "$(bash "$FW" --dry-run --operator-cidr 203.0.113.4/32 --scope-ssh 2>/dev/null \
  | grep -F '+ ufw allow proto tcp to any port 22' || true)"

it "still narrows the admin plane itself with --operator-cidr alone"
assert_contains "$(bash "$FW" --dry-run --operator-cidr 203.0.113.4/32 2>/dev/null)" \
  "from 203.0.113.4/32 proto tcp to any port 8443"

it "--scope-ssh without an operator CIDR keeps SSH open rather than denying it"
assert_contains "$(bash "$FW" --dry-run --scope-ssh 2>/dev/null)" \
  "+ ufw allow proto tcp to any port 22"

it "scopes database ports to the client CIDR when given one"
assert_contains "$(bash "$FW" --dry-run --client-cidr 10.20.0.0/16 2>/dev/null)" \
  "from 10.20.0.0/16 proto tcp to any port 10000:10049"

it "opens the cleartext REST API only when explicitly asked"
assert_contains "$(bash "$FW" --dry-run --allow-insecure-rest 2>/dev/null)" "port 8080"

it "rejects an unknown argument"
assert_status 2 bash "$FW" --nope

finish
