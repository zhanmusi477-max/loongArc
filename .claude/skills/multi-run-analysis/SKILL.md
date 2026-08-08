---
name: multi-run-analysis
description: >
  Compare multiple Vivado implementation runs by parsing existing report
  files (timing summary, utilization, DRC, methodology, power) to produce a ranked QoR
  comparison table, strategy extraction, winner recommendation, and anomaly callouts.
  Use when user asks to "compare implementation runs", "analyze multi-run results",
  "which impl run is best", "compare run strategies", "rank implementation results",
  "multi-run QoR comparison", "compare placement directives", "analyze DoE sweep results",
  "compare timing across runs", or when a project has multiple impl_* runs.
  Also trigger for "best run", "run comparison table", "strategy sweep analysis",
  "implementation sweep", or "directive exploration results". Works with any AMD FPGA
  device family (UltraScale+, Versal, 7-series, etc.).
---

# Multi-Run Implementation Analysis

## Overview

**Purpose:** Compare multiple implementation runs by parsing existing report files to rank QoR, extract strategies, and identify anomalies. Works with any AMD FPGA device family.

**Output:** `vivado_agentic_ai_reports/multi-run-analysis/`
- `REPORT.md` — insight-focused analysis: executive dashboard, timing progression, congestion device map, strategy impact, critical path patterns, actionable next steps
- `report_data.json` — structured JSON of all extracted data for visualization/plotting
- `dashboard.html` — interactive Chart.js dashboard (dark theme, 5 tabs) that reads report_data.json

> **TOOL CONSTRAINT (NON-NEGOTIABLE):**
> This skill parses **existing report files** from completed implementation runs.
> It does NOT require a live Vivado session — no `vivado_execute` calls needed.
> Use `run_in_terminal` with `grep`/`sed`/`awk` for data extraction from report files.
> Use `read_file` only for small files (<200 lines) like TCL scripts or constraint files.

> **SCOPE:** Any AMD FPGA device family. Device-specific checks (e.g., NoC paths
> on Versal, LAGUNA crossings on UltraScale+ SSI) are applied conditionally.

## Prerequisites

| Requirement | Details |
|---|---|
| Target family | Any AMD FPGA (UltraScale+, Versal, 7-series, etc.) |
| Vivado version | 2023.2+ (timing summary format and `Physopt 32-619` message IDs are version-dependent) |
| Design state | At least 2 implementation runs completed with report files present |
| Open project | A Vivado project (`.xpr` with `.runs/impl_*` directories) or a set of directories containing implementation DCPs and reports |
| Vivado session | **Not required** — skill parses existing report files only |

---

## Efficiency Guidelines

- **Write reports to file** — do not output full report content in chat. Give a short summary only.
- **Read reports efficiently** — use `grep`, `sed`, or `awk` via terminal to extract specific sections instead of reading entire files into context.
- **Do NOT** read entire timing summary reports into context — they can be 10K+ lines. Extract only the summary table.
- **Batch extractions** — when extracting the same metric from N runs, use a shell loop rather than N separate terminal commands.
- **Do NOT** open DCPs or start Vivado. If report files are missing, tell the user which files are needed and how to generate them.

---

## Workflow (Autonomous)

**⚠️ CRITICAL: Execute steps SEQUENTIALLY. Wait for each command to complete.**

**⚠️ The workflow is incomplete until REPORT.md, report_data.json, AND dashboard.html exist.** Do not end your turn before writing all three files. Invoke the write tool first, then give a short summary.

```
Multi-Run Analysis Progress:
- [ ] Step 1: Discover runs and validate report files
- [ ] Step 2: Extract timing QoR from all runs
- [ ] Step 3: Extract strategies/directives from all runs
- [ ] Step 4: Extract utilization summary from all runs
- [ ] Step 5: Extract timing progression (post-place → phys_opt → post-route)
- [ ] Step 6: Extract congestion metrics (global + per-SLR) from all runs
- [ ] Step 6b: Extract detailed congestion analysis (OPTIONAL — only if report_design_analysis output exists)
- [ ] Step 7: Extract critical path patterns (failing clock domains)
- [ ] Step 8: Detect anomalies and incomplete runs
- [ ] Step 9: Generate REPORT.md and report_data.json
- [ ] Step 10: Generate dashboard.html
```

### Step 1: Discover Runs and Validate Report Files

**Mode A — Project mode (.xpr with .runs/):**

Find all implementation run directories and create the output directory:
```bash
ls -d <project>.runs/impl_* 2>/dev/null | head -50
mkdir -p vivado_agentic_ai_reports/multi-run-analysis
```

**Mode B — DCP mode (user-specified directories):**

Ask the user for the list of directories or a parent directory containing run outputs. Each directory should contain report files from a completed (or partially completed) implementation run.

**Validate each run directory** — check for the minimum required files:
```bash
for d in <run_dirs>; do
  echo "=== $(basename $d) ==="
  ls "$d"/*report_timing_summary* "$d"/*_routed.dcp "$d"/*.tcl 2>/dev/null | head -5
  if [ ! -f "$d"/*report_timing_summary* ] 2>/dev/null; then echo "  !! NO TIMING SUMMARY — INCOMPLETE"; fi
done
```

**Required files per run** (for full analysis):
| File Pattern | Purpose | Required? |
|---|---|---|
| `*report_timing_summary*.rpt` | WNS, WHS, TNS, THS | Yes |
| `*report_utilization*.rpt` | LUT, FF, BRAM, URAM, DSP | Recommended |
| `*.tcl` (run script) | Directives used | Recommended |
| `tight_setup_hold_pins.txt` | Worst violating pins | Optional |
| `*report_methodology*.rpt` | Methodology violations | Optional |
| `*report_power*.rpt` | Power estimate | Optional |
| `*report_bus_skew*.rpt` | Bus skew violations | Optional |
| `clockInfo.txt` | Clock details | Optional |
| `runme.log` (or vivado.log) | Congestion metrics, wirelength | Recommended |

If a run is missing the timing summary report, mark it as **INCOMPLETE** — do not skip it.

### Step 2: Extract Timing QoR from All Runs

Extract WNS, WHS, TNS, THS from each run's timing summary report using a single batched command:
```bash
for d in <run_dirs>; do
  rpt=$(ls "$d"/*report_timing_summary*.rpt 2>/dev/null | grep -v "post_route_phys_opt" | tail -1)
  if [ -n "$rpt" ]; then
    echo "=== $(basename $d) === $rpt"
    grep -A 2 "Design Timing Summary" "$rpt" | head -5
    echo "---"
    sed -n '/^  WNS/,/^$/p' "$rpt" | head -5
    grep "WNS\|WHS\|TNS\|THS\|WPWS" "$rpt" | head -10
  else
    echo "=== $(basename $d) === INCOMPLETE (no timing summary)"
  fi
done
```

**Also check for post-route phys_opt timing** (some runs have an additional stage):
```bash
for d in <run_dirs>; do
  prpo=$(ls "$d"/*post_route_phys_opt*timing_summary*.rpt 2>/dev/null | tail -1)
  if [ -n "$prpo" ]; then echo "=== $(basename $d) has post-route phys_opt timing ==="; fi
done
```

**Parsing the timing summary table:**

The Vivado timing summary has this format:
```
            WNS(ns)      TNS(ns)  TNS Failing Endpoints  ...  WHS(ns)      THS(ns)  ...
            -------      -------  ---------------------  ...  -------      -------  ...
              0.010        0.000                      0  ...    0.002        0.000  ...
```

Extract the numeric values. Use:
```bash
grep -A 3 "WNS(ns)" "$rpt" | tail -1
```
This returns the data row. Fields are space-separated: WNS, TNS, TNS_endpoints, TNS_total_endpoints, WHS, THS, THS_endpoints, THS_total_endpoints, WPWS, TPWS.

### Step 3: Extract Strategies/Directives from All Runs

**From TCL run scripts** (project mode — usually named `<top>.tcl` or `runme.tcl`):
```bash
for d in <run_dirs>; do
  tcl=$(ls "$d"/*.tcl 2>/dev/null | grep -v "pre_\|post_\|hook" | head -1)
  if [ -n "$tcl" ]; then
    echo "=== $(basename $d) ==="
    grep -i "opt_design\|place_design\|phys_opt_design\|route_design" "$tcl" | grep -i "directive\|subdirective\| -dir" | head -10
  fi
done
```

**From gen_run.xml** (alternative source in project mode):
```bash
for d in <run_dirs>; do
  xml="$d/gen_run.xml"
  if [ -f "$xml" ]; then
    echo "=== $(basename $d) ==="
    grep -i "directive\|strategy" "$xml" | head -10
  fi
done
```

Build a per-run strategy table:
| Run | opt_design | place_design | phys_opt_design | route_design |
|---|---|---|---|---|
| impl_1 | Default | Default | AggressiveExplore | AggressiveExplore -tns_cleanup |

### Step 4: Extract Utilization Summary from All Runs

```bash
for d in <run_dirs>; do
  urpt=$(ls "$d"/*report_utilization*.rpt 2>/dev/null | tail -1)
  if [ -n "$urpt" ]; then
    echo "=== $(basename $d) ==="
    grep -A 2 "Slice Logic\|CLB Logic" "$urpt" | head -6
    grep "LUT as Logic\|LUT as Memory\|Register as Flip Flop\|Block RAM Tile\|URAM\|DSPs" "$urpt" | head -10
  fi
done
```

For SSI (multi-SLR) designs, also extract per-SLR utilization if available:
```bash
for d in <run_dirs>; do
  urpt=$(ls "$d"/*report_utilization*.rpt 2>/dev/null | tail -1)
  if [ -n "$urpt" ]; then
    grep -c "SLR" "$urpt" > /dev/null 2>&1 && echo "=== $(basename $d) has SLR data ==="
    sed -n '/SLR CLB Logic/,/^$/p' "$urpt" 2>/dev/null | head -20
  fi
done
```

### Step 5: Extract Timing Progression (Post-Place → Phys_Opt → Post-Route)

The `runme.log` contains `Physopt 32-619` messages showing WNS/TNS at each phys_opt iteration. The **first** entry is the post-placement estimated timing (before phys_opt), the **last** is the final phys_opt result. Combined with the post-route timing from the timing summary report, this reveals where timing degrades.

```bash
for d in <run_dirs>; do
  log=$(ls "$d"/runme.log "$d"/vivado.log 2>/dev/null | head -1)
  rpt=$(ls "$d"/*report_timing_summary*.rpt 2>/dev/null | grep -v "post_route_phys_opt" | tail -1)
  if [ -n "$log" ] && [ -n "$rpt" ]; then
    first_wns=$(grep 'Physopt 32-619' "$log" | head -1 | grep -oP 'WNS=\S+' | sed 's/WNS=//')
    last_wns=$(grep 'Physopt 32-619' "$log" | tail -1 | grep -oP 'WNS=\S+' | sed 's/WNS=//')
    first_tns=$(grep 'Physopt 32-619' "$log" | head -1 | grep -oP 'TNS=\S+' | sed 's/TNS=//')
    last_tns=$(grep 'Physopt 32-619' "$log" | tail -1 | grep -oP 'TNS=\S+' | sed 's/TNS=//')
    iters=$(grep -c 'Physopt 32-619' "$log")
    route_wns=$(grep -A 6 "Design Timing Summary" "$rpt" | tail -1 | awk '{print $1}')
    route_tns=$(grep -A 6 "Design Timing Summary" "$rpt" | tail -1 | awk '{print $2}')
    printf "$(basename $d): place_WNS=%s → physopt_WNS=%s (%d iters) → route_WNS=%s | place_TNS=%s → physopt_TNS=%s → route_TNS=%s\n" \
      "$first_wns" "$last_wns" "$iters" "$route_wns" "$first_tns" "$last_tns" "$route_tns"
  fi
done
```

Key metrics to derive from this data:
- **Phys_opt WNS recovery** = post-place WNS - post-physopt WNS (how much phys_opt improved WNS)
- **Route degradation** = post-route WNS - post-physopt WNS (how much routing worsened WNS)
- **Phys_opt iteration count** — indicates optimization effort; 100+ iterations suggests AggressiveExplore is working hard
- **Diminishing returns** — if post-physopt is much better than post-route, routing is undoing phys_opt gains

### Step 6: Extract Congestion Metrics from All Runs

Congestion data is logged by the placer in `runme.log` (or `vivado.log`). Extract the **post-placement estimated congestion** (global MaxCong per direction) and **total wirelength**:

```bash
for d in <run_dirs>; do
  log=$(ls "$d"/runme.log "$d"/vivado.log 2>/dev/null | head -1)
  if [ -n "$log" ]; then
    echo "=== $(basename $d) ==="
    # Extract global MaxCong per direction from post-placement congestion table
    north=$(sed -n '/Post-Placement Estimated Congestion/,/Total net WL/{/NORTH/p}' "$log" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    south=$(sed -n '/Post-Placement Estimated Congestion/,/Total net WL/{/SOUTH/p}' "$log" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    east=$(sed -n '/Post-Placement Estimated Congestion/,/Total net WL/{/EAST/p}' "$log" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    west=$(sed -n '/Post-Placement Estimated Congestion/,/Total net WL/{/WEST/p}' "$log" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    wl=$(sed -n '/Post-Placement Estimated Congestion/,/Phase.*Placer/{/Total net WL/p}' "$log" | head -1 | awk '{print $4}')
    printf "  N=%s S=%s E=%s W=%s WL=%s\n" "$north" "$south" "$east" "$west" "$wl"
  else
    echo "=== $(basename $d) === NO LOG FILE"
  fi
done
```

The congestion values represent MaxCong ratio (>1.0 means congested). Values are extracted from the **global summary table**. The total wirelength is in scientific notation (e.g., `1.26e+09`). Lower wirelength generally correlates with better timing.

**Per-SLR congestion (SSI devices):** For multi-SLR devices, the log contains per-SLR congestion tables immediately after the global table (labeled `SLR0:`, `SLR1:`, etc.). **Always extract per-SLR data** — it reveals hotspots masked by the global summary. Extract for runs where any global direction exceeds 0.95 OR for the top-3 and bottom-3 runs by WNS:

```bash
for d in <run_dirs>; do
  log=$(ls "$d"/runme.log "$d"/vivado.log 2>/dev/null | head -1)
  if [ -n "$log" ]; then
    # Check if per-SLR data exists
    if grep -q '^SLR[0-9]:' "$log" 2>/dev/null; then
      echo "=== $(basename $d) per-SLR ==="
      # Extract per-SLR MaxCong (Global column, field $4) for each SLR
      sed -n '/Post-Placement Estimated Congestion/,/Phase.*Placer/p' "$log" | \
        awk '/^SLR[0-9]:/{slr=$1} /NORTH|SOUTH|EAST|WEST/{split($0,a,"|"); gsub(/^ +| +$/,"",a[4]); if(slr!="") printf "%s %s MaxCong=%s\n", slr, a[2], a[4]}'
      # Extract per-SLR wirelength
      sed -n '/Post-Placement Estimated Congestion/,/Phase.*Placer/p' "$log" | \
        awk '/^SLR[0-9]:/{slr=$1} /Total net WL:/{if(slr!="") printf "%s WL=%s\n", slr, $4; slr=""}'
    fi
  fi
done
```

**Router congestion hotspot tiles** (from Route 35-449): The router also reports congestion bounded by specific INT tile coordinates. These pinpoint physical hotspot locations on the die but do NOT map to logical hierarchy — hierarchy attribution requires a loaded DCP with `report_design_analysis -congestion`. Extract tile locations for reference:

```bash
for d in <run_dirs>; do
  log=$(ls "$d"/runme.log "$d"/vivado.log 2>/dev/null | head -1)
  if [ -n "$log" ] && grep -q 'Route 35-449' "$log" 2>/dev/null; then
    echo "=== $(basename $d) router hotspots ==="
    sed -n '/Route 35-449/,/Route 35-448/p' "$log" | grep 'INT_X' | head -10
  fi
done
```

If a run's log file is missing or doesn't contain `Post-Placement Estimated Congestion`, note "congestion data unavailable" for that run.

> **NOTE:** The log provides physical tile coordinates for congestion hotspots but does NOT attribute congestion to logical hierarchies or RTL modules. To identify which modules cause congestion, load the DCP in Vivado and run `report_design_analysis -congestion` — this is covered by the `place-design-congestion-analysis` skill, not this multi-run comparison skill.

### Step 6b: Extract Detailed Congestion Analysis (OPTIONAL)

> **This step is NOT part of the baseline workflow.** Only execute it if report files are discovered. Do NOT warn or prompt the user if no files are found — silently skip.

Some users generate `report_design_analysis -congestion` or `-complexity` output via run hooks, custom TCL, or post-implementation scripts. File names vary across users and projects. **Discover them from the log** by scanning for the Vivado command-echo pattern:

```bash
for d in <run_dirs>; do
  log=$(ls "$d"/runme.log "$d"/vivado.log 2>/dev/null | head -1)
  [ -z "$log" ] && continue
  # Find report_design_analysis commands in log
  grep "Executing command : report_design_analysis" "$log" 2>/dev/null | while IFS= read -r line; do
    # Extract -file argument (output file path)
    file=$(echo "$line" | grep -oP '\-file\s+\K\S+')
    # Determine flags used (-congestion, -complexity, -qor_summary, etc.)
    flags=$(echo "$line" | sed 's/.*report_design_analysis//' | sed 's/-file\s*\S*//' | xargs)
    # Resolve file path (may be relative to run dir)
    resolved=""
    if [ -n "$file" ]; then
      if [ -f "$d/$file" ]; then resolved="$d/$file"
      elif [ -f "$file" ]; then resolved="$file"
      fi
    fi
    if [ -n "$resolved" ]; then
      echo "=== $(basename $d) | flags: $flags | file: $resolved ==="
    fi
  done
done
```

**Parse discovered files based on flags:**

For `-congestion` reports — extract Rent exponent, per-clock-region congestion, and top congested modules:
```bash
# Per-clock-region congestion table
sed -n '/Clock Region/,/^$/p' "$resolved" | head -40
# Rent exponent
grep -i "rent" "$resolved" | head -3
# Top congested modules
sed -n '/Top Coverage/,/^$/p' "$resolved" | head -20
```

For `-complexity` reports — extract logic level distribution:
```bash
grep -A 20 "Logic Level Distribution" "$resolved" | head -25
```

For `-qor_summary` reports — extract composite QoR metric:
```bash
grep -i "qor\|score\|grade" "$resolved" | head -10
```

Store discovered data in the JSON `detailed_congestion` field per run (see TEMPLATES.md). If a run has no `report_design_analysis` output, set `"detailed_congestion": null`.

### Step 7: Extract Critical Path Patterns (Failing Clock Domains)

Extract per-clock-group WNS from the post-route timing summary report. This identifies which clock domain(s) are failing and whether it's a single domain problem or widespread.

```bash
for d in <run_dirs>; do
  rpt=$(ls "$d"/*report_timing_summary*.rpt 2>/dev/null | grep -v "post_route_phys_opt" | tail -1)
  if [ -n "$rpt" ]; then
    echo "=== $(basename $d) failing clocks ==="
    # Extract intra-clock entries with negative WNS
    awk '/Intra Clock Table/,/Inter Clock Table/{print}' "$rpt" | \
      awk '{
        # Match lines with clock name followed by negative WNS
        if ($0 ~ /^ +[a-zA-Z]/ && NF >= 2) {
          for (i=1; i<=NF; i++) {
            if ($i ~ /^-[0-9]/) { print $0; break }
          }
        }
      }' | head -10
  fi
done
```

For the **winner run**, also extract the top failing clocks with their WNS, TNS, and failing endpoint count. This tells the user exactly which clock domain to focus optimization on.

Additionally, check if timing failures are concentrated on **inter-clock paths** (CDC-related):
```bash
for d in <run_dirs>; do
  rpt=$(ls "$d"/*report_timing_summary*.rpt 2>/dev/null | grep -v "post_route_phys_opt" | tail -1)
  if [ -n "$rpt" ]; then
    inter_fail=$(awk '/Inter Clock Table/,/Other Path Groups Table/{print}' "$rpt" | grep -c '\-[0-9]')
    if [ "$inter_fail" -gt 0 ]; then
      echo "$(basename $d): $inter_fail inter-clock timing failures"
    fi
  fi
done
```

### Step 8: Detect Anomalies and Incomplete Runs

**6a. Flag incomplete runs** — runs missing key output files:
```bash
for d in <run_dirs>; do
  status="COMPLETE"
  [ ! -f "$d"/*_routed.dcp ] 2>/dev/null && [ ! -f "$d"/*routed*.dcp ] 2>/dev/null && status="INCOMPLETE (no routed DCP)"
  [ ! -f "$d"/*report_timing_summary*.rpt ] 2>/dev/null && status="INCOMPLETE (no timing report)"
  echo "$(basename $d): $status"
done
```

**6b. Detect hold anomalies** — from tight_setup_hold_pins.txt if present:
```bash
for d in <run_dirs>; do
  thp="$d/tight_setup_hold_pins.txt"
  if [ -f "$thp" ]; then
    worst_hold=$(grep "hold" "$thp" | head -1)
    pin_count=$(grep -c "hold" "$thp" 2>/dev/null)
    echo "=== $(basename $d): $pin_count hold pins, worst: $worst_hold ==="
  fi
done
```

Watch for these anomalies:
- **Hold degradation after post-route phys_opt** — WHS getting much worse (>10ns) after post-route phys_opt
- **SLR crossing timing** (SSI devices) — timing failures concentrated on inter-SLR paths (look for `SLR` or `LAGUNA` in timing paths)
- **NoC-related timing** (Versal only) — paths through NoC NMU/NSU endpoints
- **Clock skew anomalies** — abnormally large clock uncertainty on some runs but not others

**6c. Check for DRC violations** (if methodology reports exist):
```bash
for d in <run_dirs>; do
  mrpt=$(ls "$d"/*report_methodology*.rpt 2>/dev/null | tail -1)
  if [ -n "$mrpt" ]; then
    viol_count=$(grep -c "VIOLATION" "$mrpt" 2>/dev/null)
    echo "=== $(basename $d): $viol_count methodology violations ==="
  fi
done
```

### Step 9: Generate REPORT.md and report_data.json

**Action:** Call the write tool to create BOTH output files. **Invoke the write tool FIRST, then give a short summary.** Do not narrate before writing.

Create the output directory and write both files:
```bash
mkdir -p vivado_agentic_ai_reports/multi-run-analysis
```

Write to:
- `vivado_agentic_ai_reports/multi-run-analysis/REPORT.md`
- `vivado_agentic_ai_reports/multi-run-analysis/report_data.json`

**Important:** The `report_data.json` must include `anomalies` and `next_steps` arrays at the top level (see TEMPLATES.md schema). These fields power the dashboard's "Run Details" tab.

### Step 10: Generate dashboard.html

Copy the dashboard template from the skill folder to the output directory:
```bash
cp <skill_folder>/DASHBOARD_TEMPLATE.html vivado_agentic_ai_reports/multi-run-analysis/dashboard.html
```

Where `<skill_folder>` is the directory containing this SKILL.md file. The dashboard is a self-contained HTML file that loads `report_data.json` via `fetch()` at runtime. To view it:
```bash
cd vivado_agentic_ai_reports/multi-run-analysis && python3 -m http.server 8080
```
Then open `http://localhost:8080/dashboard.html` in a browser.

The dashboard has 5 tabs: Timing (WNS/TNS charts + table), PnR Progression (place→physopt→route), Strategy Impact (grouped analysis), Congestion (per-SLR device maps + heatmap), and Run Details (anomalies + next steps + full comparison table). All content is rendered dynamically from the JSON — no manual editing needed.

---

## Output Templates

See [TEMPLATES.md](TEMPLATES.md) for the full REPORT.md section structure (7 sections: executive dashboard, timing progression, critical path pattern, strategy impact, congestion device map, anomalies, next steps) and the report_data.json JSON schema.

---

## Decision Tree

```
User provides multi-run project/directory
  ├─ Has .xpr? → Mode A (project mode) — auto-discover impl_* runs
  └─ No .xpr? → Mode B (DCP mode) — ask user for run directories
      │
      ├─ Runs found < 2 → Tell user: need at least 2 runs to compare
      └─ Runs found >= 2
          │
          ├─ All runs have timing summary? → Full analysis
          └─ Some missing timing summary? → Flag INCOMPLETE, analyze available runs
              │
              ├─ Only timing requested? → Steps 1-2, 6-7 (skip util/strategy/congestion)
              └─ Full comparison? → Steps 1-7
```

---

## Error Handling

| Error | Symptom | Action |
|-------|---------|--------|
| No impl runs found | `ls` returns empty | Ask user to confirm project path or provide run directories |
| No timing summary in any run | All runs INCOMPLETE | Tell user to run implementation first, or provide correct paths |
| TCL scripts missing | Can't extract directives | Note "Strategy: Unknown" in table; check gen_run.xml as fallback |
| Unknown device family | Can't determine part | Note device family; apply generic checks |
| Timing report format differs | Old Vivado version | Try alternate grep patterns; note Vivado version mismatch |
| Log file missing | Can't extract congestion | Note "congestion data unavailable" in table; congestion step is recommended, not required |
| Huge number of runs (>50) | Slow extraction | Process first 50, ask user if they want the rest |

---

## Troubleshooting: REPORT.md Not Created

**Symptom:** Steps 1–6 complete (data extracted from all runs) but REPORT.md never appears.

**Root cause:** The agent outputs text ("Now I'll generate REPORT.md...") instead of invoking the write tool. A text-only response may end the turn before the file is written.

**Prevention:** Follow Step 7 order strictly — invoke the write tool first, then summarize. Do not narrate before acting.

---

## Validation

After generating REPORT.md and report_data.json, verify:
1. Executive dashboard names a winner with WNS and closure gap
2. Timing progression table has one row per run with post-place, post-physopt, post-route WNS
3. Critical path pattern names the failing clock domain(s)
4. Strategy impact table groups runs by shared strategy (not 1:1 run per row)
5. Congestion device map uses ASCII art showing per-SLR hotspots (SSI devices)
6. Anomalies section only contains actionable findings (no filler)
7. Recommendations are numbered, specific (name run, clock, directive), and prioritized
8. report_data.json is valid JSON with all runs in the `runs` array
9. Utilization is condensed to one line unless it varies significantly across runs

---

## References

- **UG949**: UltraFast Design Methodology — multi-strategy exploration
- **UG1788**: Versal Adaptive SoC Timing Closure — directive recommendations
- **UG904**: Vivado Design Suite User Guide: Implementation — run strategies
- **UG835**: Vivado Design Suite Tcl Command Reference

<p class="sphinxhide" align="center"><sub>Copyright © 2026 Advanced Micro Devices, Inc</sub></p>
<p class="sphinxhide" align="center"><sup><a href="https://www.amd.com/en/corporate/copyright">Terms and Conditions</a></sup></p>
