# Metric definitions / 指标口径

All reads are unprivileged. Null means unavailable; it is never converted to zero. Charts have a 60-second timestamp axis anchored to the latest received sample; redraws do not scroll ahead of the data and a retained boundary sample is clipped at the left edge; rates use remote monotonic elapsed time.

| Metric | Source and calculation |
|---|---|
| CPU user | Delta(user + nice) / delta(sum of first eight `/proc/stat` fields) |
| CPU system | Delta(system + irq + softirq) / the same denominator |
| CPU total | User + system; idle, iowait and steal are not attributed to either series. Guest fields are already included in user/nice and are not added again. |
| CPU frequency | Mean of available `scaling_cur_freq` readings; a driver-reported frequency, not an independent measurement of effective work. |
| CPU temperature | Maximum of the Spark ACPI CPU zones `TS0E`, `TS0P`, `TS1E`, `TS1P`, found by `device/path`, not enumeration order. Individual zones and source names appear in the temperature tooltip. TSOC/TGPU/TUNC are not substituted. |
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

Windows-only placeholders are replaced with Linux data: maximum CPU clock, architecture, 1-minute load, kernel slab/reclaimable slab, shared pages and dirty pages, filesystem available space, network duplex/MAC/DNS, and GPU PCI location. CPU process/thread counts are Linux process and schedulable-task counts; cache sizes are summed over distinct sysfs shared-cache groups. Disk response time is the read/write time delta divided by completed operations. Network graph labels use decimal bits per second; memory/disk capacities retain binary units.

The GPU page's four activity charts are the driver's overall GPU utilization, memory read/write activity, video encoder and video decoder. They are **not four compute engines**. Its single unified-memory chart shows the same whole-system used/total pool as the Memory page, **not a separately measured GPU allocation**.

Network metadata comes from NetworkManager (`nmcli device show`) and sysfs. Wi-Fi SSID, signal in dBm, radio frequency and actual Rx/Tx negotiated rates come from `iw dev <interface> link` without scanning or changing connections. The Wi-Fi protocol is derived from the active link's EHT/HE/VHT/MCS report, not the adapter's advertised maximum. SSID, DNS suffix/server and MAC are refreshed with inventory every 30 seconds; signal and negotiated rates update each sample. A DNS suffix and DNS server address are separate fields. IPv6 includes link-local addresses. An unconfigured DNS field remains unavailable.

## Reference sources

- [NVIDIA SMI](https://docs.nvidia.com/deploy/nvidia-smi/): utilization and encoder/decoder metric definitions.
- [NetworkManager nmcli](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html): device metadata queries.
- [Microsoft Press: Windows 10 Tools](https://download.microsoft.com/download/7/3/8/7381E0E8-CE72-4366-9849-13B2BAFBBA3C/Microsoft_Press_ebook_Windows_10_Tools_8.5x11.pdf): Task Manager Ethernet throughput layout; Linux-specific fields retain explicit Linux names.
