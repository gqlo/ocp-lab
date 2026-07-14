# NetApp setup notes

Apply all static NNCPs (run from this directory):

```bash
oc apply $(printf ' -f %s' storage-e*-nncp.yaml)
```

(`oc apply -f` accepts only one path per flag; the glob alone passes extra positional args.)

Check `ens2f0np0` IPv4 on all 9 storage workers:

```bash
for n in e26-h15-000-r640 e26-h17-000-r640 e29-h01-000-r640 e29-h03-000-r640 e29-h06-000-r640 e34-h01-000-r650 e45-h11-000-r650 e45-h13-000-r650 e45-h14-000-r650; do printf "%-22s %s\n" "$n" "$(oc debug node/$n --quiet -- chroot /host ip -4 -br addr show ens2f0np0 2>/dev/null | awk '{print $3}')"; done
```

Blank output = no IP assigned. Expected output:

```
e26-h15-000-r640       10.200.0.20/24
e26-h17-000-r640       10.200.0.21/24
e29-h01-000-r640       10.200.0.22/24
e29-h03-000-r640       10.200.0.23/24
e29-h06-000-r640       10.200.0.24/24
e34-h01-000-r650       10.200.0.25/24
e45-h11-000-r650       10.200.0.26/24
e45-h13-000-r650       10.200.0.27/24
e45-h14-000-r650       10.200.0.28/24
```
