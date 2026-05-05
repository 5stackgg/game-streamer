## 5Stack Game Streamer

5Stack is a platform for organizing and managing competitive CS2 matches and tournaments.

Please visit [5Stack](https://docs.5stack.gg) for more documentation.

### CS2 perf tunables

The hand-curated low-quality convar set lives in `cs2_perf_autoexec_block` (`src/lib/cs2-perf.sh`) and is appended to the generated `autoexec.cfg` on every launch. That's the source of truth for graphics quality today.

| Env var | Default | Purpose |
|---|---|---|
| `CS2_GRAPHICS_PRESET` | `low` | Picks `resources/video/<preset>.txt`, copied to `cs2_video.txt` before CS2 launches. Valid values are the basenames of files in `resources/video/`. The shipped `low.txt` is an empty stub — once a real CS2 settings file is captured (see below), bump to `medium` / `high` on pods scheduled to stronger GPUs. |

Set this in the pod's k8s env block.

#### Capturing a new graphics preset

The shipped `resources/video/low.txt` is an intentional empty stub — CS2's `cs2_video.txt` is a Source 2 KeyValues3 file with undocumented keys that shift between patches, so hand-authoring it is unreliable. To populate (or add) a preset:

1. On a workstation with CS2 installed, set the in-game graphics options to the desired quality and exit CS2.
2. Copy the resulting `cs2_video.txt` (under `steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg/`) to `resources/video/<preset>.txt` verbatim.
3. Rebuild the image. The new preset becomes selectable via `CS2_GRAPHICS_PRESET=<preset>`.
