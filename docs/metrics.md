# Metric definitions / 指标口径

All reads are unprivileged. Null means unavailable; it is never converted to zero. Charts have a 60-second wall-clock axis; rates use remote monotonic elapsed time.

| Metric | Source and calculation |
|---|---|
| CPU user | Delta(user + nice) / delta(sum of first eight `/proc/stat` fields) |
| CPU system | Delta(system + irq + softirq) / the same denominator |
| CPU total | User + system; idle, iowait and steal are not attributed to either series. Guest fields are already included in user/nice and are not added again. |
| CPU frequency | Mean of available `scaling_cur_freq` readings; a driver-reported frequency, not an independent measurement of effective work. |
| CPU temperature | Maximum of the Spark ACPI CPU zones `TS0E`, `TS0P`, `TS1E`, `TS1P`, found by `device/path`, not enumeration order. Individual zones appear below the chart. TSOC/TGPU/TUNC are not substituted. |
| Memory | `/proc/meminfo`: OS-visible total, available, in-use = total − available, cache = Cached + SReclaimable, Swap used = SwapTotal − SwapFree. Cache overlaps reclaimable memory and is not an additional allocation to sum with used/available. |
| Disk active time | Delta(io_ticks) / elapsed milliseconds, displayed at 0–100%; this is device busy time, not percent of SSD capacity or bandwidth. |
| Disk read/write | Sector counter deltas × 512 / elapsed seconds, from `/proc/diskstats`. |
| Disk capacity/free | Physical sectors plus `statvfs` for the disk's mounted filesystems, deduplicated by major:minor. “Free” is filesystem space available to the user. |
| Disk temperature | NVMe `Composite` hwmon sensor whose parent device matches that disk. |
| Network | Per-interface receive/transmit byte deltas and error/drop counters; link speed and state from sysfs. Each logical interface has its own page. |
| RDMA | Interface mapping via `gid_attrs/ndevs`; `port_xmit_data` and `port_rcv_data` count four-byte units, converted to cumulative bytes. These overlap the fabric's network traffic and should not be summed with Ethernet totals. |
| GPU | `nvidia-smi` utilization, memory activity, temperature, graphics clock and power. Memory activity is interface activity, **not allocated memory capacity**. Power is the driver reading, not CPU or wall power. |

Spark CPU/GPU share physical memory. The memory page is the common pool; the GPU page does not fabricate a dedicated VRAM allocation. Unsupported Windows-specific fields such as separate 3D/Copy engine percentages are not synthesized.

Counter resets or the initial baseline yield unavailable rates. Broken streams retain old history only as historical samples; current values are cleared. Authentication and host-key failures stop automatic reconnect. Transient network failures are retried after five seconds.

The Windows-style detail layout includes explicit unavailable fields: CPU base frequency and virtualization state, Windows handle counts, DIMM timing/reserved-memory information, and dedicated/shared GPU allocations. GPU subgraphs use the metrics actually available on GB10 (overall GPU activity, memory activity, encoder, decoder), not invented 3D/Copy-engine data. CPU process/thread counts are Linux process and schedulable-task counts; cache sizes are summed over distinct sysfs shared-cache groups. Disk response time is the read/write time delta divided by completed operations. Network graph labels use decimal bits per second; memory/disk capacities retain binary units.
