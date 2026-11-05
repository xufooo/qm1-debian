# rtw88 (upstream tree) — patches for the RTL8723BS module

Six patches that are applied to the **upstream** rtw88 tree before it is
compiled into the single out-of-tree module `rtw88_qm1`.

* Base tree: `torvalds/linux` at
  `05441d697f7f9a927264f4058cbbc6a03dfcac9d` (a master snapshot of
  2026-11-03), directory `drivers/net/wireless/realtek/rtw88/`.
* The patches are a series: apply them **in order** with GNU patch
  (`patch --batch --forward -p1 < 0001-*.patch`, then 0002 … 0006).
  `scripts/build-rtw88-8723bs-module.sh` does this and refuses to build when
  one of them is missing — a missing patch would still produce a module that
  loads and still brings the interface up, but silently without the fix.
* These patches are **carried patches**, not upstream commits: the mail
  headers carry no upstream `From <sha>` on purpose.  Where a patch is
  upstream's, its upstream commit id is named in the body.

## Why the snapshot does not already contain them

The snapshot contains the whole RTL8723B/RTL8723BS support series
(2026-09-09 … 2026-10-06), merged through
`1f8e4308755e` ("Merge tag 'rtw-next-2026-10-08'").  Upstream's
maintainer tree (`pkshih/rtw`, branch `rtw-next`) kept working on the
chip afterwards, and master did not merge any of that.  So every 8723B
fix from **2026-10-09 onwards is missing** from the tree we ship — about
four weeks of upstream work on exactly this chip.

## 0001 — adapt the mac80211 glue to Linux 6.12

* Local patch (no upstream equivalent).
* The upstream rtw88 tree uses the multi-radio (`radio_idx`) and MLO
  (`link_sta_rc_update`) mac80211 callbacks and the `sdio_driver.shutdown`
  hook, none of which exist in Linux 6.12.  This patch adapts the glue so
  the tree compiles against the Debian 13 kernel.

## 0002 — sdio: reject oversized RX packets

* Upstream: `83ca360e85280ecaf0ded1b84d184a2839fea20f`
  ("wifi: rtw88: sdio: reject oversized RX packets", Luka Gejak, 2026-10-09).
* `rtw_sdio_rxfifo_recv()` takes the last-entry path when the RX descriptor
  claims more data than `rx_len`.  The skb then goes to `rtw_sdio_rx_skb()`,
  which calls `skb_put()` with `pkt_len` without checking it against the
  space that is left — a bad descriptor overflows the skb.
* We carry it because the QM1's RTL8723BS is an SDIO device and its **only**
  network link: an RX path that can corrupt kernel memory is not an
  acceptable risk on the machine that carries the SSH session and the
  provisioning download.  Eight lines, self-contained.

## 0003 — sdio: copy the RX status after updating the frequency

* Upstream: `c76f73c36343` ("wifi: rtw88: sdio: copy RX status after
  updating the frequency", 2026-10-09).
* Moves `*IEEE80211_SKB_RXCB(skb) = *rx_status;` from before
  `rtw_update_rx_freq_for_invalid()` to after it — which is what the PCI
  and USB transports already do.  Upstream's note that "SDIO is
  unaffected" only holds before this change: without it, the corrected
  frequency never reaches mac80211 on the SDIO path.
* We carry it because 0004 changes the frequency on exactly this path, and
  0003 is what makes the change reach mac80211.

## 0004 — 8723b: do not set `channel_invalid` in `query_phy_status()`

* Upstream: `1cca8775c2e5` ("wifi: rtw88: 8723b: don't set channel_invalid
  in query_phy_status()", 2026-10-09).
* The 8723B PHY status does not report the channel, so the driver used to
  mark it invalid.  `rtw_update_rx_freq_for_invalid()` then replaces the
  received frame's frequency with `rtwdev->hal.current_channel` — the
  **center** channel, not the primary one.  On a 40 MHz connection mac80211
  is handed a frequency it rejects in `ieee80211_rx_beacon_freq_valid()`
  and reports **beacon loss**.
* We carry it because beacon loss is one of the ways the original
  complaint ("网络断流") shows up, and the QM1 has no second link to fall
  back to.

## 0005 — 8723b: always report a single spatial stream

* Upstream: `b490cf696ff7` ("wifi: rtw88: 8723b: always report a single
  spatial stream", 2026-10-20).
* Upstream changed `efuse->hw_cap.nss` / `ant_num` to a fixed 1.  The
  effect on our tree is the same as the previous expression
  (`max_t(u8, rtwdev->hal.rf_path_num, 1)`) for this module, but we take
  the upstream version so the tree matches what upstream runs.

## 0006 — 8723b: stay at 20 MHz until the chip variant can be read

* **Local policy patch**, not an upstream commit.
* Upstream's 2026-10-20 series (`51abe866522f`, `10d1312f2f19`,
  `ec2baa4c9317`) reads the package type and the chip variant from the
  efuse (0x1fb, bits 2:0 and 5:4) and **disables 40 MHz** when the chip
  turns out to be the RTL8703AS — a variant of the RTL8723BS that does not
  support 40 MHz at all.  We do not carry those commits: they need the
  physical map in the `read_efuse` chip operation, which changes the
  signature of that operation for every chip in the whole rtw88 tree — a
  backport across the entire driver for one bit of information.
* So this patch reports 20 MHz only:

  ```
  efuse->hw_cap.bw = BIT(RTW_CHANNEL_WIDTH_20);
  ```

  Reasons:
  1. Upstream's own series admits that one RTL8723BS variant does not
     support 40 MHz, and our tree cannot tell that variant apart.
  2. The community reports for this chip family (the staging `rtl8723bs`
     driver, whose default is 40 MHz via `rtw_bw_mode=0x01`) are random
     disconnects at 40 MHz.
  3. On the QM1 this Wi-Fi is the only link — it carries SSH, the time
     sync and the provisioning download.  Stability beats the extra
     throughput of a 40 MHz channel.
* If the QM1 ever proves that 40 MHz is fine on this module, revert this
  patch or backport the upstream efuse series properly.

## Deliberately not carried

| Upstream commit | Why not |
| --- | --- |
| `51abe866522f`, `10d1312f2f19`, `ec2baa4c9317` (efuse package type / chip variant) | They change the `read_efuse` chip operation for every chip in the tree; too wide a backport for one bit.  Their effect on the bandwidth is approximated by 0006. |
| `dc16902cad9c` (firmware recovery when leaving LPS fails) | The image turns the power save off (`rtw_power_mgnt=0` / `rtw_smart_ps=0` / `rtw_ips_mode=0`), so the path it protects is not taken. |

## The vendor fallback tree does not have these

`patches/rtw88/` holds the patches for the *vendor* tree, which is only
used when the upstream tree cannot be built.  That tree carries the TX
report purge timeout fix but **not** the fixes above — it is a fallback,
not the shipping path.  The shipping module is the upstream one.

## Verification

The six patches were applied with GNU patch to the pinned upstream files
(`sdio.c`, `rtw8723b.c` fetched at the pinned SHA) in order: all succeed
with zero fuzz, zero offsets, zero rejects.  The result was checked for
the expected content (the oversized-RX guard, the RX status copy after
the frequency update, no `channel_invalid`, `nss = 1`,
`bw = BIT(RTW_CHANNEL_WIDTH_20)`).  Compiling and loading the module is
covered by CI; nothing here was tested on real hardware yet.
