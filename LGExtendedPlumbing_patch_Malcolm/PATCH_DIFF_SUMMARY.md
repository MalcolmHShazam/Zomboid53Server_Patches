# What changed vs LG Extended Plumbing v3.3.1 (Workshop 3779561845)

All edits are marked `[Malcolm_Perf]` in the source. The full unified diff is in `PATCH.diff`. Paths are under `42.20/media/lua/`.

| File | Function / place | Change |
|---|---|---|
| shared/LGExtendedPlumbing/**LGEPRegistry.lua** (NEW) | whole file | Registry of plumbed spots in global ModData `LGEPPerfRegistry` (authority only): `spots` (numeric square key → bits: collector / hidden store / topped-up fixture) and `scanned` (chunk key → true). It derives an in-memory HOT chunk set from:<br>• each spot<br>• each plumbed collector's original discovery box (building ±2, or Reach)<br>• pipe pieces with their boxes<br>• derived pipe-network boxes<br>Classifies each loading square as full / cheap / skip. Queues rescans for chunks that become hot while loaded (1 chunk/tick). One-time migration: unscanned chunks get a cheap relevance look, then are marked scanned 3 s after first sight. Batches unload marks to once per hot or noticed chunk. Seeds hidden-store spots from the original's existing mirror index. No network traffic. |
| server/LGExtendedPlumbing/LGEPPlumbing.lua | `notice` | Registers fed squares, hidden stores, and plumbed-in (`isIncluded`) collectors in the registry. Marks the chunk as noticed. The original logic is otherwise untouched. |
| | new `noticeLoaded` + `Events.LoadGridsquare` | Gated: full `notice` for hot chunks; cheap look then `notice` only if relevant for cold, unscanned chunks; skip for cold, scanned chunks. Without a registry it falls back to the original. |
| | `Events.ReuseGridsquare` | Raises worldChanged/fixturesChanged at most once per chunk, and only for hot or noticed chunks. Falls back to the original when there is no square or no registry. |
| | after `sweepBox` | Exposes `EP.sweepBoxFor` and wires the registry hooks (notice, square access, discovery box, chunk levels). |
| | `EP.setIncluded` | On plumb-in, registers the collector and synchronously runs the full look over its discovery box before the wide service (on-demand building discovery). On unplumb, removes it. |
| | OnTick Reach change | Also invalidates the hot set. |
| shared/LGExtendedPlumbing/LGEPCore.lua | `EP.isFedFixture` | Asks the final "has a FluidContainer" test first (same answer, no type string for ordinary objects). |
| | `EP.setFedPlumbed` | Adds/removes the fed bit in the registry. |
| | after `OnGameBoot` | Warms the building plan index on OnGameStart / OnServerStarted (moves the first-use spike to loading). |
| shared/LGExtendedPlumbing/LGEPGhost.lua | `buildGhost` | Registers the hidden store's square (authority only). |
| | `EP.removeGhost` | Removes the spot once no hidden store is left on it. |
| server/LGExtendedPlumbing/LGEPPipes.lua | `EP.markPipesDirty` | Also invalidates the registry hot set. |
| | new `networkSignature`, registry hooks `eachPipe`/`eachNetBox` | Signature of everything clients and LGEPPlumbing see of the derived networks. |
| | OnTick pipe driver | A re-derive or supply recompute that produces the same signature no longer bumps the generation, fires `onPipeScopeChanged`, or broadcasts. Real changes go through unchanged. |
| | heartbeat | `EveryTenMinutes` full resend → `EveryHours` every 6th hour. Join-time HELLO is unchanged. |
| client/LGExtendedPlumbing/LGEPClient.lua | `hideAll` (client LoadGridsquare) | Skips objects whose sprite name is set and isn't the store sprite before calling `hide`; one pcall per square, as before. |
| 42.20/mod.info | | New id/name/description (credits LittleGroove, marked as a local performance patch), `incompatible=\LGExtendedPlumbing,\LGEP_PerfFix`. |
| ZOMBOID_LAUNCHER_PATCH.txt | | Launcher patch marker. |

**Not changed:** sandbox options, translations, textures, every other function. The pipe arrival re-derive on chunk load is kept: it is needed for player-built houses, it was already limited to chunks containing pipes, and it now only resends when something actually changed.
