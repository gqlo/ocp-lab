# OpenShift cluster upgrade

Commands and pitfalls for upgrading an OCP cluster with `oc adm upgrade`, including
**RC → GA** on the same minor (e.g. `4.22.0-rc.1` → `4.22.0`).

## Check status

```bash
oc adm upgrade
oc get clusterversion
oc get clusterversion version -o jsonpath='{.spec.channel}{"\n"}{.status.desired.version}{"\n"}'
```

## Channels

List current + available (from `oc adm upgrade`):

```text
Channel: candidate-4.22 (available channels: candidate-4.22, candidate-5.0, eus-4.22, fast-4.22, stable-4.22)
```

| Channel | What it is | When to use |
| --- | --- | --- |
| `candidate-4.y` | Pre-GA: RCs / nightlies for that minor | Lab, early access; some builds unsupported |
| `candidate-5.0` | Pre-GA for the next major | Only if intentionally tracking 5.0 candidates |
| `fast-4.y` | GA as soon as errata is published | Production that wants updates ASAP |
| `stable-4.y` | Same GA builds after a bake period | Default production; delays regressions |
| `eus-4.y` | Extended Update Support even minors | Long-lived clusters; EUS-to-EUS paths |

**fast vs stable:** same supported GA releases; stable just lags (days–weeks for z-streams; often longer right after a new minor GA).

**candidate vs fast/stable:** candidate includes RCs; fast/stable are GA-only. An RC cluster must use `candidate-4.y` or Cincinnati returns `VersionNotFound`.

**eus:** even-numbered minors with longer support; use when you plan EUS lifecycle, not for chasing every z-stream faster.

Set channel:

```bash
oc adm upgrade channel candidate-4.22
# after landing on GA:
oc adm upgrade channel fast-4.22   # or stable-4.22 / eus-4.22
```

### `VersionNotFound` / incompatible channel

`fast-4.22` / `stable-4.22` only contain GA nodes. If the cluster is still on an RC:

```text
Unable to retrieve available updates: currently reconciling cluster version 4.22.0-rc.1
not found in the "fast-4.22" channel
```

Switch back to `candidate-4.y`. Recommendations only appear when the **current**
version exists in that channel’s update graph.

You may also see:

```text
warning: No channels known to be compatible with the current version "4.22.0-rc.1"
```

Set the channel anyway, then re-run `oc adm upgrade`. Once Cincinnati knows the RC,
recommended updates (including GA) show up.

## Working path: RC → same-minor GA

Example that worked: `4.22.0-rc.1` → `4.22.0`.

```bash
oc adm upgrade channel candidate-4.22
oc adm upgrade
```

When GA is listed under **Recommended updates**:

```text
Recommended updates:

  VERSION     IMAGE
  4.22.0      quay.io/openshift-release-dev/ocp-release@sha256:...
  4.22.0-rc.5 ...
  ...
```

Upgrade:

```bash
oc adm upgrade --to=4.22.0
```

Prefer `--to=<version>` when the version is in Recommended updates.

### Explicit image (if not in the graph)

If the current RC has aged out of Cincinnati and nothing is recommended:

```bash
oc get clusterversion version -o jsonpath='{.status.desired.image}{"\n"}'

oc adm upgrade \
  --to-image=quay.io/openshift-release-dev/ocp-release:4.22.0-x86_64 \
  --allow-explicit-upgrade
```

Match arch (`x86_64`, `aarch64`, …). Add `--force` only if CVO still refuses.

After GA is installed:

```bash
oc adm upgrade channel fast-4.22
```

## `Upgradeable=False` vs same-minor updates

`oc adm upgrade` may show:

```text
Upgradeable=False
  Reason: MultipleReasons
  ... ClusterVersionOverridesSet, IncompatibleOperatorsInstalled
  ... blocking minor version upgrades to 4.23 or major version upgrades to 5.0
  ... odf-operator ... maximum supported OCP version ... is 4.22
```

That blocks **y-stream / major** moves (e.g. 4.22 → 4.23). It does **not** block
same-minor RC → GA (`4.22.0-rc.1` → `4.22.0`).

Before a real minor upgrade:

- Remove `spec.overrides` on ClusterVersion
- Bump operators (ODF, LSO, …) to versions that support the target OCP

## Watch progress

```bash
watch -n 30 oc get clusterversion
oc adm upgrade
oc get clusteroperators
oc get mcp
```
