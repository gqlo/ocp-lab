# Calculate block size per process
# 100TiB = 109951162777600 bytes
# 109951162777600 / 256 = 429496729600 bytes (~400GiB per process)

# Using GNU parallel (recommended):
seq 0 255 | parallel -j 256 \
  'dd if=/dev/zero of=/dev/vdb bs=1M count=409600 seek=$((409600 * {})) conv=notrunc status=progress'

# Or using a bash loop with background processes:
for i in {0..255}; do
  dd if=/dev/zero of=/dev/vdb bs=1M count=409600 seek=$((409600 * i)) conv=notrunc oflag=direct &
done
wait

# Or using xargs:
seq 0 255 | xargs -P 256 -I {} \
  dd if=/dev/zero of=/dev/vdb bs=1M count=409600 seek=$((409600 * {})) conv=notrunc oflag=direct
