# Testing LGExtendedPlumbing_patch_Malcolm

This is a local performance patch of LG Extended Plumbing v3.3.1 by LittleGroove. It replaces the Workshop mod; don't run it alongside it.

**Never enable these together with this variant:**
- **LG Extended Plumbing** (the Workshop original)
- **LGEP_PerfFix** (the earlier add-on; its changes are already in here)

## 0. Before you start
- Copy your save folder, and test only on the copy. Do the same with the server save if you test MP.
- Optional: turn on the mod's own `Debug` sandbox option in the test save. The log then shows lines such as `registry: N plumbed spot(s) on record`.

## 1. Select the variant
1. Open Zomboid Launcher, then the **Patches** page.
2. Select **LG Extended Plumbing [Malcolm Perf]** (`LGExtendedPlumbing_patch_Malcolm`) for LG Extended Plumbing. That swaps it in for the original.
3. Make sure LGEP_PerfFix is **off**.

## 2. FPS test: same route as before
- Drive the same town route at the same speed, 3 times. Use Muldraugh or wherever it stuttered.
- Note the lowest FPS and the number of hitches. Compare with your earlier runs with the original.
- **The first drive through an area you have never visited with this variant is not the fair comparison.** Each chunk gets one cheap migration look the first time. Do the route once, then measure runs 2 and 3.

## 3. Gameplay checks
For each one, compare against what the original did.
- [ ] **Taps.** A plumbed sink on a lower floor than a roof barrel draws water, and the barrels go down.
- [ ] **Right-click.** It shows the plumbing rows and the supply reading. A dry tap still says why.
- [ ] **New barrel.** Place one in a building that had no plumbing and plumb it with the wrench. Every sink in that building connects within a second or two, without being right-clicked.
- [ ] **Unplumb.** Disconnect takes effect right away.
- [ ] **Carry.** Pick up a plumbed barrel and put it down again. It stays plumbed (lid open/close too).
- [ ] **Water cooler.** A plumbed office WaterDispenser gets topped up from the barrels.
- [ ] **Pipes.** "Show piped area" draws the network. A sink in a shed or the next house over the pipe gets water. Lay one more pipe and lift it; colours update.
- [ ] **Generator-pumped barrel.** Power the barrel's square with a generator. A tap on the same floor or above gets water. Turn the generator off; it stops.
- [ ] **Leave and return.** Drive far away (500+ tiles) and come back. Taps, coolers and pipe colours still work, including in a base you built yourself.
- [ ] **Liquid.** Set a tap to beer or whiskey. It pours only that.

## 4. Existing save that already has plumbing (migration)
1. Use a **copy** of a save made with the original mod, with plumbed barrels, taps, a cooler and pipes if you have them.
2. Load it with the variant selected. Go straight to the base.
3. Everything in section 3 should work on the first visit. Nothing should need re-plumbing.
4. Visit a second plumbed location far from where you spawned. It should connect when you arrive.
5. Save, quit, reload, and check again.

## 5. Multiplayer (dedicated server)
- The server and every client must run the variant, not the original. Pick it on the Patches page for the server's mod list, then sync clients the way you normally do.
- Repeat sections 2-4 with two players, one driving through town while the other stands at the base. Watch for rubber-banding.
- Players who join late should still see pipe colours (they ask the server on join).

## If something is wrong
- Note what and where.
- Switch the Patches page back to the original LG Extended Plumbing. The save stays compatible: the variant only adds its own `LGEPPerfRegistry` ModData entry, which the original ignores.
- Tell me.
