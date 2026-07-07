# ocp-trace

**ocp-trace** is a debug container image for OpenShift: Driver Toolkit (RHCOS-matched kernel headers) plus eBPF, network capture, and shell utilities. Use it for **`oc debug`** into pods **or** on nodes.

| Image | Built by | Use for |
| ----- | -------- | ------- |
| **`quay.io/rh_ee_lguoqing/ocp-trace:<OCP-version>`** | [`build.sh`](build.sh) | Pod debug (tcpdump, CoreDNS) **and** node eBPF (bcc, bpftrace, bio*) |

Example: `quay.io/rh_ee_lguoqing/ocp-trace:4.16.37` — tag matches `oc get clusterversion version`. [`build.sh`](build.sh) also tags `:latest` for convenience.

**Why version tags?** The image is built on **Driver Toolkit**, which changes with each OCP release. Pin the tag to your cluster version so kernel headers stay matched after upgrades.

---

## Build and push

**Requires:** subscribed **RHEL** build host, `oc` logged into cluster, Quay push access.

```bash
cd ocp-lab/learning/ebpf
chmod +x build.sh

./build.sh
# tags: quay.io/rh_ee_lguoqing/ocp-trace:4.16.37  (from clusterversion)
# also:  quay.io/rh_ee_lguoqing/ocp-trace:latest

podman logout quay.io
podman login quay.io -u <your-quay-user>
podman push quay.io/rh_ee_lguoqing/ocp-trace:4.16.37
podman push quay.io/rh_ee_lguoqing/ocp-trace:latest
```

Set image reference for commands below:

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
echo "$OCP_TRACE"
```

Custom repo or tag:

```bash
./build.sh -t quay.io/<your-user>/ocp-trace:4.16.37
./build.sh --no-latest          # only the version tag, skip :latest
```

Dockerfile only:

```bash
./build.sh -n
```

Add/remove tools: edit [`packages.txt`](packages.txt), then rebuild.

**After OCP upgrade:** run `./build.sh` and push the new version tag.

---

## Run — debug a pod

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"

NODE=$(oc get pod -n <client-ns> <client-pod> -o jsonpath='{.spec.nodeName}')
DNS_POD=$(oc get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default \
  --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')

oc -n openshift-dns debug -it "$DNS_POD" \
  --image="$OCP_TRACE" \
  --target=dns \
  --share-processes \
  --profile=netadmin
```

Inside:

```bash
ps aux | grep coredns
tcpdump -i eth0 -n -vv 'port 53 or port 5353'
/usr/share/bcc/tools/biosnoop
```

Generic pattern:

```bash
oc -n <namespace> debug -it <pod> \
  --image="$OCP_TRACE" \
  --target=<container> \
  --share-processes \
  --profile=netadmin
```

More DNS examples: [OpenShift network tracing — CoreDNS](../../networking/ocp-network-tracing/ocp-net-tracing.md#coredns-in-the-cluster).

---

## Run — debug a node

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')

oc debug "node/$NODE" -it --image="$OCP_TRACE" -- bash
```

Use **`-it`**. Stay in the **container** shell for eBPF:

```bash
uname -r
rpm -q kernel-headers bpftrace bcc-tools
/usr/share/bcc/tools/biolatency    # Ctrl+C for histogram
```

Long-lived privileged pod — [`ocp-trace-pod.yaml`](ocp-trace-pod.yaml):

```bash
OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')

sed "s/OCP_VERSION/${OCP_VER}/" ocp-trace-pod.yaml | oc apply -f -
oc patch pod ocp-trace-node --type merge -p "{\"spec\":{\"nodeName\":\"$NODE\"}}"
oc wait --for=condition=Ready pod/ocp-trace-node --timeout=120s
oc exec -it ocp-trace-node -- bash
```

Block I/O lab — [`templates/cnv/ddpod.yaml`](../../templates/cnv/ddpod.yaml):

```bash
sed "s/OCP_VERSION/${OCP_VER}/" ../../templates/cnv/ddpod.yaml | oc apply -f -
```

---

## BCC tools (quick reference)

| Path | Contents |
| ---- | -------- |
| `/usr/share/bcc/tools/` | `biolatency`, `biotop`, `biosnoop`, `execsnoop`, … |
| `man bcc-<toolname>` | Man pages |

Upstream: [iovisor/bcc](https://github.com/iovisor/bcc).

---

## Troubleshooting

| Problem | Fix |
| ------- | --- |
| Wrong/missing kernel headers after upgrade | Rebuild and use new **version tag**, not an old one |
| `No package matches '…'` during `./build.sh` | Package not in RHEL 9 BaseOS/AppStream — remove from [`packages.txt`](packages.txt) |
| `cannot install the best candidate` / `curl-minimal` vs `curl` | DTK ships **curl-minimal** — do not install `curl` in packages.txt |
| `unauthorized` on push | Login as Quay user with write access (not cluster robot) |
| Debug exits immediately | Add **`-it`** to `oc debug` |

```bash
podman login quay.io --get-login
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
```

---

## Related docs

- [OpenShift Driver Toolkit](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/specialized_hardware_and_driver_enablement/driver-toolkit)
- [OpenShift network tracing](../../networking/ocp-network-tracing/ocp-net-tracing.md)
