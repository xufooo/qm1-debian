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
* **The paths inside a patch are relative to the rtw88 directory**
  (`a/sdio.c`, `a/rtw8723b.c`), *not* to the kernel tree.  The build
  script copies the rtw88 sources into one flat directory and applies the
  patches there with `-p1`, so a path like
  `a/drivers/net/wireless/realtek/rtw88/sdio.c` would be stripped down to
  a path that does not exist in that directory and the patch would not
  apply.  This is checked by `scripts/test-upstream-patches.sh`.

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

## 0007 — ps: trigger firmware recovery when failing to leave LPS state

Carried from upstream rtw-next commit `dc16902cad9c` (Kalpesh Solanki,
2026-11-03).

When the firmware fails to leave the low power state, the driver used to
log a warning, clear `REG_TCR` and carry on.  The chip was then left in a
state where later H2C commands fail and TX traffic hangs indefinitely —
the firmware never comes back on its own.

On the QM1 this is the worst possible failure mode: the Wi-Fi is the
only network, so a chip that does not come back means the machine has no
network at all and no way to fix it remotely.  Upstream's fix calls
`rtw_fw_recovery()`, so the driver resets the hardware and re-syncs by
itself.

> Earlier revisions of this file claimed this fix was unnecessary because
> the image disables power saving.  **That was wrong.**  The parameters
> `rtw_power_mgnt` / `rtw_smart_ps` / `rtw_ips_mode` belong to the
> in-tree *staging* driver (`r8723bs`); rtw88 does not have them — the
> shipping module only sets `disable_lps_deep`, which turns off the
> *deep* low power mode.  The ordinary LPS leave path is still reachable,
> so the path this fix protects is reachable in the configuration we ship.

## 0008 — 8723b: avoid converting RX SNR twice

Carried from upstream rtw-next commit `1d72d0db9111` (Hungyu Lin,
2026-10-10).

`rtw8723b_query_phy_status_ofdm()` divided the reported SNR by two when
filling `pkt_stat->rx_snr` and shifted it again when updating
`dm_info->rx_snr`, so every SNR the driver reported — and the averages
derived from it — was half of what the chip measured.  The fix stores the
raw report and converts once, the way the other chip drivers do.

We care because the on-device self-check reads these statistics to judge
link quality.

## 0009 — allow key removal when the CAM table is full

Carried from upstream rtw-next commit `b60ee9891e40` (Hungyu Lin,
2026-10-19).

`rtw_ops_set_key()` looked for a free CAM entry *before* it looked at the
command.  Once every pairwise entry was in use, `DISABLE_KEY` returned
`-ENOSPC` without clearing the entry that was already there, so the old
key could never be removed from the hardware — for example when the AP
rekeys, or when we reconnect after the link dropped.  Upstream moves the
allocation into `SET_KEY` only; `DISABLE_KEY` reuses the existing
`key->hw_key_idx`.

## Deliberately not carried

| Upstream commit | Why not |
| --- | --- |
| `51abe866522f`, `10d1312f2f19`, `ec2baa4c9317` (efuse package type / chip variant) | They change the `read_efuse` chip operation for every chip in the tree; too wide a backport for one bit.  Their effect on the bandwidth is approximated by 0006. |

## Known gaps — upstream fixes that are not in this tree

The pinned snapshot is a static commit, so it will never pick up later
upstream work by itself.  This is the list of the rtw-next commits that
touch `drivers/net/wireless/realtek/rtw88` between the merge point of
our snapshot (`1f8e4308755e`, "rtw-next-2026-10-08") and 2026-11-03,
and what we did about each one:

| Upstream commit | Date | Subject | Status |
| --- | --- | --- | --- |
| `dc16902cad9c` | 2026-11-03 | ps: trigger firmware recovery when failing to leave LPS state | **carried** (0007) |
| `1d72d0db9111` | 2026-10-10 | 8723b: avoid converting RX SNR twice | **carried** (0008) |
| `b60ee9891e40` | 2026-10-19 | allow key removal when the CAM table is full | **carried** (0009) |
| `1cca8775c2e5` | 2026-10-09 | 8723b: don't set `channel_invalid` in `query_phy_status()` | **carried** (0004) |
| `83ca360e8528` | 2026-10-09 | sdio: reject oversized RX packets | **carried** (0002) |
| `c76f73c36343` | 2026-10-09 | sdio: copy RX status after updating the frequency | **carried** (0003) |
| `b490cf696ff7` | 2026-10-20 | 8723b: always report a single spatial stream | **carried** (0005) |
| `51abe866522f`, `10d1312f2f19`, `ec2baa4c9317` | 2026-10-20 | efuse: read the package type / chip variant | not carried (see above) |
| `04c998418722` | 2026-11-03 | pci: add DMI quirk for HP Laptop 15s-fr5xxx | not applicable (PCI) |
| `62e69ef45567` | 2026-11-02 | usb: don't report the aggregation buffer as a frame | not applicable (USB) |
| `6ac7db1cea43` | 2026-10-23 | pci: wake the TX queues after restart_hw and interface up | not applicable (PCI) |
| `72fa55807619` | 2026-10-19 | usb: drop RX frames received before the device is started | not applicable (USB) |
| `a0756232e960` | 2026-10-13 | usb: download the reserved page synchronously | not applicable (USB) |
| `f65d7df159a2` | 2026-10-09 | pci: preserve the RX ring DMA address on cleanup | not applicable (PCI) |
| `b0435910e47d` | 2026-10-11 | 8822b: relax the ETSI EDCCA threshold on 2.4 GHz | not applicable (other chip) |
| `c3ae9e68e138` | 2026-10-10 | 8703b: avoid converting RX SNR twice | not applicable (other chip) |
| `49a8e00e0db8` | 2026-10-13 | mac80211: replace `ieee80211_iter_keys_rcu()` | not applicable (newer mac80211 API than 6.12) |

Anything merged upstream *after* 2026-11-03 is unknown to us by
construction — re-run the comparison before trusting this table.


## The vendor fallback tree does not have these

`patches/rtw88/` holds the patches for the *vendor* tree, which is only
used when the upstream tree cannot be built.  That tree carries the TX
report purge timeout fix but **not** the fixes above — it is a fallback,
not the shipping path.  The shipping module is the upstream one.

## Verification

`scripts/test-upstream-patches.sh` is the blocking check (it runs in the
`lint` workflow).  It

1. rejects any patch whose diff header carries the kernel-tree prefix,
2. fetches the pinned upstream files (`mac80211.c`, `rtw8723bs.c`, `tx.c`,
   `sdio.c`, `rtw8723b.c`, `ps.c`) at the pinned SHA,
3. applies the whole series **in order** with GNU patch (`-p1`), and
4. checks the result for the expected content: the oversized-RX guard,
   the RX status copy *after* the frequency update, no `channel_invalid`,
   `nss = 1`, `ant_num = 1` and `bw = BIT(RTW_CHANNEL_WIDTH_20)` only,
   the firmware recovery call on the LPS-leave failure path, the raw RX
   SNR, and the CAM allocation sitting inside `case SET_KEY:`.

This check exists because the alternative failure mode is quiet: when a
patch does not apply, `scripts/build-rtw88-8723bs-module.sh` falls back to
the vendor tree, the build does not fail, and the only symptom is an
image that ships the staging driver with its known permanent-hang paths.

Compiling and loading the module is covered by CI; nothing here was
tested on real hardware yet.
