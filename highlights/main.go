// Parses a CS2 .dem file and emits one JSON event per line on stdout
// describing a highlight candidate:
//
//	{"match_id":"...","steam_id":"765...","round":12,"start_tick":18342,
//	 "end_tick":18598,"spec_slot":3,"event_type":"ace"}
//
// Downstream consumers turn each line into a render job.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"

	dem "github.com/markus-wa/demoinfocs-golang/v4/pkg/demoinfocs"
	events "github.com/markus-wa/demoinfocs-golang/v4/pkg/demoinfocs/events"
)

type highlight struct {
	MatchID   string `json:"match_id"`
	SteamID   string `json:"steam_id"`
	Round     int    `json:"round"`
	StartTick int    `json:"start_tick"`
	EndTick   int    `json:"end_tick"`
	SpecSlot  int    `json:"spec_slot"`
	EventType string `json:"event_type"`
}

type kill struct {
	tick      int
	round     int
	attacker  uint64
	attackSlot int
}

func main() {
	matchID := flag.String("match", "", "match id to embed in output events")
	demoPath := flag.String("demo", "", "path to .dem file")
	minKills := flag.Int("min-multi", 3, "minimum kills-in-round to emit a multikill event")
	flag.Parse()
	if *demoPath == "" || *matchID == "" {
		fmt.Fprintln(os.Stderr, "usage: highlights -match <id> -demo <path>")
		os.Exit(2)
	}

	f, err := os.Open(*demoPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open demo:", err)
		os.Exit(1)
	}
	defer f.Close()

	p := dem.NewParser(f)
	defer p.Close()

	var kills []kill
	roundKills := map[uint64]int{}     // kills-this-round per attacker
	currentRound := 0

	p.RegisterEventHandler(func(e events.RoundStart) {
		currentRound++
		roundKills = map[uint64]int{}
	})

	p.RegisterEventHandler(func(e events.Kill) {
		if e.Killer == nil || e.Victim == nil {
			return
		}
		if e.Killer.Team == e.Victim.Team {
			return // team kill
		}
		tick := p.GameState().IngameTick()
		roundKills[e.Killer.SteamID64]++
		kills = append(kills, kill{
			tick:       tick,
			round:      currentRound,
			attacker:   e.Killer.SteamID64,
			attackSlot: e.Killer.UserID, // user_id maps to CS2 spec_player slot
		})
	})

	roundEndKillCounts := map[int]map[uint64]int{} // round -> steamid -> kills
	p.RegisterEventHandler(func(e events.RoundEnd) {
		snapshot := map[uint64]int{}
		for k, v := range roundKills {
			snapshot[k] = v
		}
		roundEndKillCounts[currentRound] = snapshot
	})

	if err := p.ParseToEnd(); err != nil {
		fmt.Fprintln(os.Stderr, "parse:", err)
		os.Exit(1)
	}

	enc := json.NewEncoder(os.Stdout)

	// Emit one event per round per attacker that reached min-kills threshold.
	// Clip bounds: first kill tick to last kill tick in that round for that
	// attacker. The render worker applies its own lead-in/tail-out.
	for round, counts := range roundEndKillCounts {
		for sid, n := range counts {
			if n < *minKills {
				continue
			}
			var first, last, slot int
			first = -1
			for _, k := range kills {
				if k.round != round || k.attacker != sid {
					continue
				}
				if first < 0 || k.tick < first {
					first = k.tick
				}
				if k.tick > last {
					last = k.tick
				}
				slot = k.attackSlot
			}
			if first < 0 {
				continue
			}
			eventType := "multikill"
			switch n {
			case 3:
				eventType = "3k"
			case 4:
				eventType = "4k"
			case 5:
				eventType = "ace"
			}
			_ = enc.Encode(highlight{
				MatchID:   *matchID,
				SteamID:   strconv.FormatUint(sid, 10),
				Round:     round,
				StartTick: first,
				EndTick:   last,
				SpecSlot:  slot,
				EventType: eventType,
			})
		}
	}

	// Also emit every individual kill as a "kill" clip, sorted by tick.
	sort.Slice(kills, func(i, j int) bool { return kills[i].tick < kills[j].tick })
	for _, k := range kills {
		_ = enc.Encode(highlight{
			MatchID:   *matchID,
			SteamID:   strconv.FormatUint(k.attacker, 10),
			Round:     k.round,
			StartTick: k.tick,
			EndTick:   k.tick,
			SpecSlot:  k.attackSlot,
			EventType: "kill",
		})
	}
}
