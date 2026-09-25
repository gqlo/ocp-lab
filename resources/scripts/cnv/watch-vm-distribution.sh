#!/usr/bin/env bash
# Watch running VM count per worker node.
interval="${1:-5}"
first=1

trap 'tput cnorm' EXIT
tput civis

while true; do
  readarray -t rows < <(
    awk '
      NR==FNR { workers[$1]=0; zone[$1]=($2 == "" || $2 == "<none>" ? "-" : $2); next }
      $0 in workers { workers[$0]++ }
      END { for (n in workers) print workers[n], n, zone[n] }
    ' \
      <(oc get nodes -l node-role.kubernetes.io/worker= -o go-template='{{range .items}}{{.metadata.name}}{{" "}}{{or (index .metadata.labels "topology.kubernetes.io/zone") (index .metadata.labels "failure-domain.beta.kubernetes.io/zone") (index .metadata.labels "machine.openshift.io/zone") "-"}}{{"\n"}}{{end}}') \
      <(oc get vmi -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.nodeName}{"\n"}{end}') \
      | sort -rn
  )

  total=0 min=999999 max=0
  for row in "${rows[@]}"; do
    c=${row%% *}
    total=$((total + c))
    (( c < min )) && min=$c
    (( c > max )) && max=$c
  done
  w=${#rows[@]}
  avg=$([[ $w -gt 0 ]] && awk "BEGIN { print $total / $w }" || echo 0)

  if (( first )); then
    clear
    first=0
  fi

  tput cup 0 0; tput el; printf '%s' "$(date)"
  tput cup 1 0; tput el
  printf 'total=%d  workers=%d  min=%d  max=%d  avg=%.1f' "$total" "$w" "$min" "$max" "$avg"

  tput cup 3 0; tput ed
  i=0
  for row in "${rows[@]}"; do
    read -r c n z <<< "$row"
    printf '%4d %-18s %-6s' "$c" "$n" "$z"
    (( ++i % 5 == 0 )) && echo
  done
  (( i % 5 )) && echo

  sleep "$interval"
done
