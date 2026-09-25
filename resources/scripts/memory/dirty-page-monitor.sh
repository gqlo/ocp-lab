# Trigger a fresh measurement NOW
sudo virsh qemu-monitor-command 1 \
  '{"execute":"calc-dirty-rate", "arguments":{"calc-time":5, "mode":"dirty-bitmap"}}'

# Wait for it to complete
sleep 3

# Now query — this reflects current state
sudo virsh qemu-monitor-command 1 '{"execute":"query-dirty-rate"}'

