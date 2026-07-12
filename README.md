# FishLog

A fishing session logger for Windower 4. The FFXI chat log only shows a few
lines and fishing results scroll away into battle spam - FishLog keeps every
result in a draggable on-screen window, timestamped and color coded, with live
identification of what is on your line before you reel it in.

FishLog is an observer: it never casts, reels, or injects packets. It just
watches and reports.

## Installing

FishLog has no dependencies beyond Windower itself. The UI library it uses (`slate.lua`) is bundled in the folder, so there is nothing else to install.

1. Download or clone this repo into a folder named `fishlog` inside your Windower `addons` directory, so you end up with `Windower4/addons/fishlog/fishlog.lua`. If you cloned it the folder will be `ffxi-fishlog`, so rename it to `fishlog` (Windower needs the folder name to match the main lua file).
2. In game, run `//lua load fishlog`.
3. Add `lua load fishlog` to `scripts/init.txt` to load it automatically. Loading it on startup is recommended so the daily fatigue counter stays accurate.

## What it shows

```
» FISHLOG                    Bastok Markets
skill 8 +0.4          moon 67%  0:42:13
──────────────────────────────────────────
21:03:12 + crayfish  (9s)
21:03:44 + moat carp x3  (14s)
21:04:20 - no bite
21:05:02 » rusty bucket  (11s)        ← tracked catch (gold + chime)
21:05:30 ! line snapped!
21:06:02 * fishing skill +0.1
21:06:40 M MONSTER on the line!
──────────────────────────────────────────
» on line: crayfish  (small)
──────────────────────────────────────────
casts 42  catch 28 (67%)  fish/hr 41
skill +0.4  breaks 2  today 37/200
```

- **History**: every catch, no-bite, lost catch, bait loss, line/rod break,
  release, skill-up, and reeled-in monster, timestamped. Catches show the
  fight duration in seconds. Everything is also appended to a daily file in
  `data/logs/` so nothing is ever lost.
- **On the line**: when something bites, the hooked item is identified from
  the fishing packet (rod-specific stamina/arrow signature - logic ported
  from Seth VanHeulen's fisher). You know if it is a crayfish or a rusty
  bucket *before* you land it.
- **Monster warning**: if a monster clamps on, you get a red alert and an
  alarm sound before you reel it into your face.
- **Tracked catches**: `//fl track rusty` - any catch whose name contains
  "rusty" rings a chime, highlights gold in the log, and prints to chat.
  Substring matching, comma-separate multiple: great for quest/goal fishing.
- **Today counter**: fish caught today out of the 200/day fishing fatigue
  cap (resets at JST midnight, same as the game).
- **Session stats**: casts, catch rate, fish per hour, skill gained, breaks.

## Commands (`//fishlog` or `//fl`)

| Command | Effect |
|---|---|
| `//fl` | toggle the window |
| `//fl clear` | reset session (history, stats, timer) |
| `//fl tally` | per-catch counts + lifetime totals to chat |
| `//fl stats <fish>` | full where/when/how analysis of one species (see below) |
| `//fl stats <fish> in <zone>` | same, restricted to zones matching `<zone>` |
| `//fl stats` | list every species in the research data |
| `//fl track <name>` | chime + highlight when a matching catch lands |
| `//fl untrack <name>` | stop tracking |
| `//fl tracked` | list tracked names |
| `//fl lines <n>` | history rows shown (3-25) |
| `//fl compact` | collapse history (stats/status only) |
| `//fl skill <n.n>` | set the exact skill decimal; it also pins itself when a +0.1 skill-up reaches a new level |
| `//fl sound on\|off` | toggle sounds |
| `//fl test` | insert sample entries to position/style the window |
| `//fl help` | command list in game |

**Mouse**: drag to move. Scroll wheel over the window pages back through
older history. Right-click toggles compact mode.

## Sounds

`sounds/tracked.wav` (tracked catch) and `sounds/monster.wav` (monster on
line) - drop in your own .wav files to change them. `monster_command` in
`data/settings.xml` can additionally run any Windower command on a monster
hook (e.g. `input /echo <call14>`).

## Research logging (community catch rates)

Where a fish bites is determined per body of water by the (zone, bait) pair -
wiki bait tables are global and often mislead (e.g. Slice of Carp takes
Crayfish in Port San d'Oria but attracts no fish at all in the Bastok Markets
canal). FishLog records the evidence to settle this with data: every cast is
one CSV row in `data/casts/casts_YYYY-MM.csv`:

```
v,contributor,utc,zone_id,zone,skill,rod_id,rod,bait_id,bait,moon,moon_phase,
vana_min,vana_day,weather_id,outcome,bite_id,p1..p9,identified,caught,count,fight_s,
x,y,z,facing,skillup
```

- **contributor** is an anonymous hash of your character name (djb2, printed as
  8 hex digits), not the name itself. It is a stable pseudonym: the same
  character always hashes to the same value, so many players' files can be
  merged and each contributor's rows deduplicated, but the name can't be
  recovered from it. It exists purely to attribute/dedupe rows in shared data.
- **skill** is your fishing skill at cast time. It is the exact value with
  decimal (e.g. `67.3`) once the addon has pinned your decimal, otherwise the
  game's integer (e.g. `67`).
- **bite_id** is the species-unique Fish Bite ID from packet 0x115, and
  p1..p9 are the raw fishing parameters - so even hooks nobody landed or
  identified can be named later by cross-referencing.
- **outcome** is one of: catch, nobite, lost, baitlost, linebreak, rodbreak,
  release, monster, unknown.
- **x, y, z, facing** are the player's exact world position and heading
  (radians) at the moment the line was cast.
- **skillup** is the fishing skill gained on that cast (e.g. `0.1`, `0.2`),
  blank if none. The "skill rises" message lands a few seconds after the catch,
  so the row is held briefly and the gain is attached before it's written.

Schema versions (the `v` column): **v1** = original; **v2** added
`x,y,z,facing`; **v3** added `skillup`. Older rows simply have fewer trailing
columns - readers should key off `v` and treat a short row as that version, not
as malformed.

`//fl export` merges everything into one shareable file in `data/export/`.
Aggregating community files is a spreadsheet pivot or a few lines of pandas:
group by (zone, bait) for bite pools and rates; slice by moon/vana_min/weather
for condition effects; catch vs linebreak/lost per rod for landing rates.
`//fl research off` disables per-cast logging if you don't want it.

## One-fish analysis: `//fl stats <fish>`

`//fl stats crayfish` reads every recorded cast and answers "where, when and
how do I catch this fish". A headline summary goes to chat; the full report is
written to `data/export/stats_<fish>_<date>.txt`, plain ASCII at 66 columns so
it pastes cleanly into a forum `[code]` block or Discord code fence:

```
==================================================================
 CRAYFISH - where, when and how to catch it
 FishLog catch report | generated 2026-07-07
 data: 848 casts | 2 contributors | 2026-07-03 to 2026-07-07
==================================================================

TOTALS
  catches      22 (22 fish counting stacks)
  hooked       23 times: landed 96%, lost 0%, line broke 4%,
               rod broke 0%, released 0%
  fight time   3-4s on the line, avg 3.5s
  caught at    fishing skill 12 to 66

WHERE TO FISH (hook rate = bites of this fish per cast)
  zone                    bait                casts hooks  rate
  Port San d'Oria         Slice of Carp          20    19   95%
  Windurst Walls          Little Worm             5     4   80% *

SPOTS (average standing position of hooks)
  Windurst Walls          x 10.0, y -20.0  (spread 0.0, 4 hooks)

RODS (landing the fish once hooked)
  rod                     hooks  landed   lost  broke
  Bamboo Fish. Rod           19    100%     0%     0% *

CONDITIONS (hook rate on the waters listed above)
  -- moon phase / time of day / weather / day tables ...

WHAT ELSE TAKES THIS BAIT (share of the 25 casts above)
  crayfish 92% | no bite 8%
```

How it works, and what makes the numbers honest:

- **Hooks, not just catches.** The species-unique Fish Bite ID (packet 0x115)
  identifies the fish the moment it bites, so casts that ended in a line
  break, a lost catch, or a release still count toward hook rates. That is
  what makes the per-rod landing table possible: same fish, different rods,
  who actually gets it out of the water.
- **Denominators that mean something.** Hook rates and condition breakdowns
  only count casts on (zone, bait) pairs where the fish actually bit at least
  once. Casts on water where the fish cannot appear would only dilute rates.
- **Sample sizes everywhere.** Every rate shows its cast count, and anything
  under 20 casts is flagged `*` - a hint, not a rate.
- **Fuzzy names.** `//fl stats cray` resolves to crayfish if unambiguous,
  and tells you the candidates if not. `//fl stats` with no name lists every
  species in the data. `//fl stats monster` works too - it maps where
  monsters take the hook.
- **Zone filter.** `//fl stats moat carp in windurst` restricts everything to
  zones whose name contains "windurst" (separate report file, so it never
  overwrites the full one).

### Community data: `data/import/`

Drop other players' `//fl export` files into `data/import/` and their casts
join every `//fl stats` report automatically - the header credits the number
of contributors. Duplicate rows (the same contributor at the same second,
e.g. overlapping export files) are counted once, so it is safe to import
generously. This is the loop the addon is built for: everyone fishes, everyone
exports, someone imports the pile and posts the report.

## Notes

- Identification requires an equipped rod known to the data tables and works
  on retail; unknown signatures show `???`.
- The daily log files live in `addons/fishlog/data/logs/YYYY-MM-DD_Name.log`.
- History keeps the last 300 entries in memory; the file keeps everything.

## License

GPL-3.0. Hooked-catch identification logic and fishing parameter data
(`data.lua`) ported from [fisher](https://gitlab.com/svanheulen/fisher) by
Seth VanHeulen (GPL-3.0).
