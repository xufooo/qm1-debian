# rtl8723bs (Debian 13 kernel 6.12) — TX stall fixes

Six self-contained patches for the staging driver `r8723bs` (Realtek RTL8723BS,
SDIO) as shipped in Debian 13, kernel source package `linux 6.12.113-1`
(`drivers/staging/rtl8723bs/`).

* Base tree: Debian `linux` source `6.12.113-1`, file `drivers/staging/rtl8723bs/`.
  All line numbers below refer to that unmodified base tree.
* The patches are a series: apply them **in order** with GNU patch
  (`patch --batch --forward -p1 < 0001-*.patch`, then 0002 … 0006).
  0002 and 0003 share the context added by 0001 in `hal/rtl8723bs_xmit.c`, so
  `git apply` in strict mode fails on 0002 (it refuses the shifted context);
  GNU patch applies the series cleanly.
* Source-level work only. Nothing here was compiled, built or tested on hardware:
  this machine is macOS and has no Linux build environment. The patches were
  verified by applying them to a pristine 6.12.113-1 copy of the driver and
  comparing the result with the patched tree byte for byte.
  The series was re-verified against the exact Debian 6.12.113-1 files
  (`patch --dry-run --batch --strip=1` on all six: zero fuzz, zero offsets,
  zero rejects).

## 0001 — rtl8723bs: re-kick TX worker when a pending xmitbuf is put back

**Root cause.** `rtl8723_dequeue_writeport()` cannot get TX free pages from the
hardware TX FIFO. It then puts the xmitbuf back to the head of the pending queue
and returns "queue empty". `enqueue_pending_xmitbuf_to_head()` only re-lists the
buffer — unlike `enqueue_pending_xmitbuf()`, it never completes `xmit_comp`, so
the xmit worker is not kicked again. If the kick that was supposed to report the
free pages is lost (missed SDIO interrupt), the pending xmitbuf is never sent and
the TX path stalls permanently.

**Code path (6.12.113-1).**

* `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:36` `rtl8723_dequeue_writeport()`,
  put-back at `:75-88` (`enqueue_pending_xmitbuf_to_head(); return true;`).
* `drivers/staging/rtl8723bs/core/rtw_xmit.c:2391` `enqueue_pending_xmitbuf_to_head()`
  (no `complete()`), versus `:2376` `enqueue_pending_xmitbuf()` with
  `complete(&pri_adapter->xmitpriv.xmit_comp)` at `:2388`.
* `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:121` `rtl8723bs_xmit_buf_handler()`,
  unbounded `wait_for_completion_interruptible(&pxmitpriv->xmit_comp)` at `:130`;
  this is the handler of the `RTW_XMIT_THREAD` xmit worker
  (`core/rtw_xmit.c:2484`, `hal/rtl8723b_hal_init.c:1924`).

**What the fix changes.**

* After the buffer has been put back, `complete(&pxmitpriv->xmit_comp)` is issued
  so the worker retries the buffer. The number of such kicks is bounded by the
  new `xmitpriv->xmitbuf_retry_cnt` (`include/rtw_xmit.h`), reset whenever an
  xmitbuf is actually written, so the worker cannot retry the same buffer in a
  tight loop.
* The wait for the kick becomes
  `wait_for_completion_interruptible_timeout(…, 100 ms)`, so a lost kick cannot
  stall the TX path forever.
  The retry re-reads the free page count from the hardware
  (`HalQueryTxBufferStatus8723BSdio()`), so a lost SDIO interrupt does not
  leave the driver with a stale count: the retry converges within one timeout
  window (100 ms) even when the kick never arrives.
* The completion is re-armed with `reinit_completion()` after the wait.
  Since Linux v5.9 `complete()` is a counting semaphore: `complete()` increments
  the counter of the completion and the waiter decrements it. The driver never
  re-arms the completion (no `reinit_completion()` anywhere in the 6.12.113-1
  driver), so the counter is never reset and a residue makes the wait return
  immediately instead of sleeping, which turns the worker into a busy loop.

**Risk.** The re-arm after the wait consumes a kick that arrives between the wait
returning and the re-arm; the pending queue is checked right after the wait
(`check_pending_xmitbuf()`), so no xmitbuf is lost — at worst one retry cycle is
delayed by up to the 100 ms timeout. The retry counter is per adapter, not per
xmitbuf. The 100 ms timeout means the worker wakes periodically even when idle
(10 wakeups/s, negligible).

## 0002 — rtl8723bs: bound the wait for SDIO TX OQT space

**Root cause.** `rtw_sdio_wait_enough_TxOQT_space()` loops until the firmware
reports enough free TX OQT space. The loop is unbounded and only sleeps every
60th iteration, so if the firmware stops consuming TX OQT the TX thread stays in
that loop forever and no frame is sent any more.

**Code path (6.12.113-1).**

* `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:11` `rtw_sdio_wait_enough_TxOQT_space()`,
  unbounded loop at `:16-33` (`msleep(1)` only every 60th iteration, `:27-30`).
* Caller: `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:96-97`, failure path
  `:105-110` (`rtw_free_xmitbuf()`; `pxmitbuf->priv_data` is already `NULL` there,
  so no frame leaks).

**What the fix changes.** The wait gets a `jiffies` deadline (1000 ms). On
timeout the function logs an error with `netdev_emerg()` and returns `false`, so
the caller aborts that xmitbuf and the TX path recovers instead of wedging.

**Risk.** On a firmware that is slow but still draining OQT, the deadline drops a
frame that would have been sent later; 1 s is generous compared with the OQT
drain rate. The frames of the dropped xmitbuf were already counted by
`rtw_count_tx_stats()`, so for that frame the tx counters can disagree with what
was actually sent. No new kernel API is used (`jiffies`, `msecs_to_jiffies()` and
`time_after()` are already used elsewhere in the driver).

## 0003 — rtl8723bs: reinit the TX completions to keep complete()/wait counts balanced

**Root cause.** The xmit thread waits for `SdioXmitStart`, which is completed
every time a frame is enqueued. Since Linux v5.9 `complete()` is a counting
semaphore: `complete()` increments the counter of the completion and the waiter
decrements it. Nothing in the driver re-arms the completion, so the counter is
never reset and a residue makes the wait return immediately instead of sleeping,
which turns the `RTWHALXT` thread into a busy loop. The same holds for
`xmit_comp`, which is re-armed by 0001.

**Severity: a busy loop, not a stall.** This defect burns CPU (the `RTWHALXT`
thread spins at 100 %), but it does not stop frames from being sent — the wait
returning early only means the thread re-checks the pending state more often
than necessary. It is a latent risk that has to be fixed (a spinning thread
also starves the TX worker of the CPU it needs to make progress), but it is
**not** one of the paths that permanently break the link.

**Code path (6.12.113-1).**

* `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:358` `rtl8723bs_xmit_handler()`,
  wait at `:366`; the completion is issued at `:514` (`rtl8723bs_hal_xmit()`) and
  `:532` (`rtl8723bs_hal_xmitframe_enqueue()`), plus
  `drivers/staging/rtl8723bs/hal/rtl8723b_hal_init.c:3850` (thread stop).
* `drivers/staging/rtl8723bs/core/rtw_xmit.c:983` `rtw_txframes_pending()` — the
  pending state that is checked right after the wait.

**What the fix changes.** `reinit_completion(&pxmitpriv->SdioXmitStart)` is called
right after the wait, so the complete()/wait pairing stays balanced and the thread
sleeps until the next frame.

**Risk.** A kick consumed by the re-arm is not lost: the pending state is checked
immediately afterwards. Note that `rtw_txframes_pending()` only inspects the
be/bk/vi/vo pending queues and not `bm_pending` (broadcast/multicast in
`wifi_spec` mode); a frame queued in `bm_pending` in that narrow window waits for
the next kick — that is a pre-existing property of the pending check, not
something this patch introduces. The stop path is unaffected: the handler checks
`bDriverStopped`/`bSurpriseRemoved` right after the wait.

## 0004 — rtl8723bs: restart the netdev subqueue that was actually stopped

**Root cause.** `rtw_check_xmit_resource()` stops the netdev subqueue of the queue
the skb belongs to. `rtw_os_pkt_complete()` only wakes the subqueue of the skb
that is being completed, which may belong to a different queue. The stopped
subqueue is therefore never woken again — the driver never calls
`netif_start_subqueue()` either — and the traffic of that queue is not sent any
more.

**Code path (6.12.113-1).**

* `drivers/staging/rtl8723bs/os_dep/xmit_linux.c:104` `rtw_check_xmit_resource()`,
  `netif_stop_subqueue()` at `:113` and `:117`.
* `drivers/staging/rtl8723bs/os_dep/xmit_linux.c:67` `rtw_os_pkt_complete()`,
  `netif_wake_subqueue()` only for the queue of the completed skb, `:73-80`.

**What the fix changes.** The stopped subqueues are tracked in the new bitmap
`xmitpriv->stopped_xmit_queues` (`include/rtw_xmit.h`), set in
`rtw_check_xmit_resource()`. `rtw_os_pkt_complete()` now restarts every tracked
subqueue whose resource condition is relieved again, using
`netif_wake_subqueue()`, which clears `__QUEUE_STATE_DRV_XOFF` and schedules
the queue for transmission.

**Effect on this hardware: defensive, not a fix for a live symptom.** Two
independent reasons:

* The driver never sets `num_tx_queues`, so the netdev has a single TX queue
  and `skb_get_queue_mapping()` is always 0 — the "stopped subqueue belongs to
  another queue" scenario cannot occur here.
* `rtw_os_pkt_complete()` already calls `netif_wake_subqueue()` for the queue of
  the completed skb, which is that same single queue 0.

So on the QM1 this patch changes nothing observable. It is kept because the
defect is real in the code and the driver is one `num_tx_queues` away from
exercising it.

**Risk.** `netif_wake_subqueue()` and `netdev_get_tx_queue()` have no bounds
check, so the helper skips queues `>= pnetdev->num_tx_queues` and
`>= pxmitpriv->hwxmit_entry`. The bitmap is only set for queues that
`rtw_check_xmit_resource()` stopped, so no unrelated queue is woken.

## 0005 — rtl8723bs: release the frame and account the drop when xmit coalescing fails

**Root cause.** `rtw_xmitframe_coalesce()` can fail (e.g. the WLAN header cannot
be built). The failure path of the caller then does neither of the two things it
must do: the frame is not counted in the tx statistics, and — depending on the
state of the aggregation — the frame is not freed either.

The exact leak depends on `k`, the number of frames already merged into the
xmitbuf before the failure:

* `k == 0` (nothing merged yet): the upstream release
  `if (k != 1) rtw_free_xmitframe(...)` *does* run, so the frame itself is
  freed — but `pxmitbuf->priv_data`, which was set to that frame at `:287`,
  keeps pointing at the freed frame. A dangling pointer, not a leak.
* `k == 1` (one frame already merged): `k != 1` is false, so the release does
  **not** run. The failed frame *and* its skb leak, and the tx accounting of
  the netdev is broken — a leaked skb keeps its slot in the netdev queue
  occupied, so that queue stops sending.

So the leak that matters is the `k == 1` case; the `k == 0` case is a dangling
pointer.

**Code path (6.12.113-1).**

* `drivers/staging/rtl8723bs/hal/rtl8723bs_xmit.c:294` the coalesce call in
  `xmit_xmitframes()`, the failure branch `:295-299` (log plus
  `/*  Todo: error handler */`), the release at `:313-314`
  (`if (k != 1) rtw_free_xmitframe(...)`).
* `pxmitbuf->priv_data` is set to the first frame of the aggregation at `:287`.
* `drivers/staging/rtl8723bs/core/rtw_xmit.c:1682` `rtw_free_xmitframe()` →
  `rtw_os_pkt_complete()` → `dev_kfree_skb_any()` and the subqueue wake, so
  releasing the frame restores the accounting.

**What the fix changes.** On `_FAIL` the frame is released with
`rtw_free_xmitframe()`, the drop is accounted with `pxmitpriv->tx_drop++` (the
driver convention, see `hal/rtl8723bs_xmit.c:510`/`:530`), and
`pxmitbuf->priv_data` is cleared when the failed frame was the first one of the
aggregation. The release of the frame on the success path moved into the
success branch, so that no frame is released twice.

**Risk.** The skb of a failed frame is dropped instead of leaked, which is what
the driver already does for other enqueue failures. The failure paths of
`rtw_xmitframe_coalesce()` (`rtw_make_wlanhdr()`, `xmitframe_addmic()`) do not
commit anything to the xmitbuf — `pxmitbuf->len`/`ptail` are only updated on
success — so no partially merged data is sent.

## 0006 — rtl8723bs: protect the TX free page accounting with the lock the driver already has

**Root cause.** The driver keeps a software mirror of the firmware's free TX
page counter in `hal_com_data.SdioTxFIFOFreePage[]`, together with a spinlock
(`SdioTxFIFOFreePageLock`, `include/hal_data.h:373-374`) that the vendor wrote
for exactly this purpose — and then commented the lock out
(`hal/hal_sdio.c:42` and `:53`), leaving the counter unprotected.

Two writers touch the counter:

* `hal/hal_sdio.c:rtw_hal_sdio_update_tx_freepage()` subtracts the pages it is
  about to hand to the firmware — a read-modify-write of one byte.
* `hal/sdio_ops.c:HalQueryTxBufferStatus8723BSdio()` overwrites the whole four
  byte array with the value read back from the hardware (`SDIO_REG_FREE_TXPG`).

If the two interleave, the read-modify-write computes its result from a stale
value and writes it back after the four byte overwrite. The driver then
believes in TX pages the firmware has already given away — which lands right
back in the "no free page" state this whole series is about.

**Call sites and their context (checked in 6.12.113-1).** The two callers of
`HalQueryTxBufferStatus8723BSdio()` are `hal/rtl8723bs_xmit.c:80` (the TX
worker) and `hal/sdio_halinit.c:778` (driver init); the callers of the two
accounting helpers are in `hal/rtl8723bs_xmit.c:77` and `:103` (the TX worker).
All of them run in process context, so `spin_lock_bh()` is the right primitive
and no lock is taken recursively. The narrow window is a driver reset/re-init
while the TX worker is running.

**What the fix changes.** The lock is restored around the counter update and
extended to the reader, and the four byte overwrite in
`HalQueryTxBufferStatus8723BSdio()` is protected as well. The SDIO command
itself stays **outside** the lock: `sdio_local_cmd53_read4byte()` may sleep and
a spinlock must not be held across a sleeping call.

**Risk.** Low. The counter is only ever written under the lock now, so the
readers see either the old or the new value, never a mix. The lock is
initialised in `hal/rtl8723bs_xmit.c:553` (`spin_lock_init()`) before the TX
worker exists.

## Known defects this series does NOT cover

The six patches above close the paths that permanently break the link, but two
defects are deliberately left alone — the series is not a complete rewrite of
the driver, and pretending otherwise would be misleading:

1. **`rtw_xmit_entry()` always reports success.** When the driver refuses a
   frame, the error path still returns `NETDEV_TX_OK`
   (`core/rtw_xmit.c`), so the drop is invisible to the network stack: the
   kernel believes the frame was sent. This does not stall the link, it makes
   the loss invisible — no `tx_drop` counter, no error in `dmesg`, and the
   upper layers cannot retry. Fixing it properly means auditing every error
   return of the xmit entry points, which is a much larger change than a
   stall fix and needs hardware testing.
2. **Everything the driver does not measure.** The driver has no runtime knob
   for the retry limits (`long_retry_lmt`/`short_retry_lmt` are dead registers
   in the firmware) and no way to request a rate: the rate is taken from the
   static table in `core/rtw_wlan_util.c` when the link is associated. A weak
   signal therefore degrades into a low rate that the host cannot ask the
   firmware to change. No patch can fix that; only a different driver (the
   rtw88 backport that this project ships as the primary path) can.

The patches also do not touch the power-saving behaviour: Leisure PS, smart PS
and idle PS are controlled by module parameters, and the parameters are copied
once at load time, so they have to be set on the module command line — see
`/etc/modprobe.d/qm1-rtl8723bs-in-tree.conf` in the image.

## Field observations on the real QM1 (2026-11-04/05)

The QM1 that this project targets was reachable over Wi-Fi on a private LAN
(address and host name withheld) and
was inspected read-only. It runs **Void Linux**, kernel **6.18.60_1**, and it
loads the **staging** driver, not the rtw88 driver:

```
/sys/class/net/wlan0/device/driver -> ../../bus/sdio/drivers/rtl8723bs
dmesg: r8723bs: module is from the staging directory, the quality is unknown …
dmesg: rtl8723bs: acquire FW from file:rtlwifi/rtl8723bs_nic.bin
```

There is **no** `failed to get tx report from firmware` in dmesg, which confirms
that the tx-report/CSTAT machinery of rtw88 is not in play — the failure modes
analysed above are the ones that apply.

Measured state of the driver threads (5 s sampling of `/proc/<pid>/stat`):
`RTW_XMIT_THREAD` 0.2 %, `RTW_CMD_THREAD` 0.2 %, `RTWHALXT` 0.4 %. **The 100 %
CPU busy loop described above was not observed on this machine**; the
complete()/wait counter apparently stays balanced in practice, so treat the
busy-loop as a latent risk of a missing `reinit_completion()` rather than a
confirmed symptom.

What *is* wrong on the machine are the module parameters, all of them at their
bad defaults (`/sys/module/r8723bs/parameters/`):

| parameter | value on the device | effect |
| --- | --- | --- |
| `rtw_power_mgnt` | 1 | Leisure PS on: TX is gated by a 2 s watchdog, so bursts are delayed |
| `rtw_smart_ps` | 2 | smart power save on |
| `rtw_ips_mode` | 1 | idle power save requested |
| `rtw_bw_mode` | 1 | 40 MHz (`iw dev wlan0` confirms `width: 40 MHz`) |

With those values the link itself is fine (signal −55 dBm, `tx bitrate:
150.0 MBit/s`, 0 % packet loss to the router) but the latency is not: 30 ICMP
echoes to the gateway gave `rtt min/avg/max/mdev = 6.4/25.8/87.9/20.3
ms`, while the same test from another machine on the same AP measures 3.3 ms
average. The jitter is therefore produced on the QM1 side, not by the AP.

The staging driver has no runtime knob for any of this. In the 6.12 tree the
iwpriv layer (`os_dep/ioctl_linux.c`) still exists, but it only carries the
legacy WPS/security/ACL/MAC-address ioctls — there is no ioctl that writes a
module parameter (`rtw_power_mgnt`, `rtw_bw_mode`, …), and the driver has no
cfg80211 `.set_power_save` either (the iwpriv layer was dropped upstream after
v6.12, so 6.14+ trees do not even have the file). The parameters are copied
once at load time by `loadparam()`, so `iw dev wlan0 set power_save off` is a
no-op and changing the parameters requires reloading the module or rebooting.

