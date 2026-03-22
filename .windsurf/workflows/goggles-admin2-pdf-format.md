---
description: Create a new PDF result format definition for goggles_admin2 — YAML layout, context hierarchy, field regex, and testing
auto_execution_mode: 2
---

# New PDF Result Format

Use this skill when adding a new PDF result format definition to the `goggles_admin2` parser engine. The parser uses YAML files to define how text extracted from PDFs is matched and structured.

## Background

- Format definitions live in `/home/steve/Projects/goggles_admin2/app/strategies/pdf_results/formats/`
- Currently 46+ format files covering FICR, GoSwim, FIN regional, and other timing systems
- The parser engine is in `/home/steve/Projects/goggles_admin2/app/strategies/pdf_results/`
- Key classes: `FormatParser`, `LayoutDef`, `ContextDef`, `FieldDef`, `ContextDAO`

## Naming Convention

Format files follow the pattern:

```text
<priority>-<family_name>.<subformat>.yml
```

- **Priority** (`1`, `2`, `3`...): Detection order. Lower = checked first.
- **Family name** (e.g. `ficr1`, `goswim1`, `fin1`): Groups related subformats together.
- **Subformat** (optional, e.g. `100m`, `400m`, `4x050m`, `teamrank`): Variant for specific event lengths or layouts.

Examples: `1-ficr1.yml`, `1-ficr1.100m.yml`, `2-goswim1.4x100m.yml`, `3-finfvg.100m.yml`

When a "main" format wins detection, all subformats in the same family are kept and tried page-by-page. This handles multi-format files where the layout changes at page breaks.

## Step-by-step Procedure

### 1. Identify the Source Layout

Examine the text output from the PDF. Key things to identify:

- **Header pattern**: meeting name, date, place (typically first 2–3 lines per page)
- **Event pattern**: event length + stroke type (e.g. "100 Stile Libero Master Misti")
- **Column headers**: "Pos. Nominativo Naz Anno Società..." etc.
- **Category pattern**: age group label (e.g. "M25 Master Maschi 25 - 29")
- **Result row pattern**: rank, swimmer name, nation, year, team, heat/lane, timing, scores
- **Footer/page delimiter**: timing organization credit line, page numbers
- **Relay patterns** (if applicable): relay code, team results, relay swimmer sub-rows
- **Team ranking** (if applicable): different column layout for team scores

### 2. Choose a Starting Template

Find the closest existing format file as a base. Common starting points:

- **FICR-style** (most common Italian format): start from `1-ficr1.yml`
- **GoSwim/MyResults**: start from `2-goswim1.yml`
- **FIN regional**: start from `3-fin1.yml` or a regional variant like `3-finfvg.yml`

Copy the template:

```bash
cp app/strategies/pdf_results/formats/1-ficr1.yml \
   app/strategies/pdf_results/formats/<priority>-<family_name>.yml
```

### 3. Define the YAML Structure

The YAML file defines a list of `ContextDef` objects under a top-level key (the format name). Each context has:

```yaml
<format-name>:
  - name: <context_name>        # Unique identifier within this format
    repeat: true/false          # Whether this context repeats on each page
    parent: <parent_ctx_name>   # Parent context (for hierarchy)
    required: true/false        # Whether detection fails without this (default: true)
    at_fixed_row: N             # Fixed row position (page-relative, 0-indexed)
    eop: true                   # End-of-page context (searched from bottom)
    row_span: N                 # Number of source lines this context spans
    lambda: strip               # Pre-processing (currently only 'strip' supported)
    format: "regex"             # Single-line regex for simple contexts
    alternative_of: <ctx_name>  # Acts as substitute for another context

    # For multi-line contexts:
    rows:
      - fields:                 # First row's field definitions
        - name: <field_name>
          format: "regex_with_(capture_group)"
          required: true/false
          pop_out: true/false   # Remove matched text before next field tries
          token_start: N        # Positional: start column index
          token_end: N          # Positional: end column index
          lambda: strip         # Pre-processing
      - fields:                 # Second row's field definitions
        - name: <field_name>
          format: "..."
```

### 4. Required Context Hierarchy

A typical format defines these contexts in order:

1. **`header`** — Meeting name, date, place. `repeat: true`, `at_fixed_row: 0`.
2. **`event`** — Event length and type. `repeat: true`, `parent: header`.
3. **`results_hdr`** — Column header row. `repeat: true`, `parent: event` (optional).
4. **`category`** — Age group. `repeat: true`, `parent: event`.
5. **`results`** — Individual result rows. `repeat: true`, `parent: category`.
6. **`results_ext`** — Optional extra row (DSQ details). `parent: results`, `required: false`.
7. **`disqualified`** — "Non Classificati" separator. `parent: category`, `required: false`.
8. **`relay_header`** — Relay result header (if relays exist). `parent: category`, `required: false`.
9. **`relay_results`** — Relay team rows. `parent: relay_header`, `required: false`.
10. **`footer`** / **`footer_alt`** — Page delimiter. `eop: true`, `parent: event`.

### 5. Key Field Names

The L2 converter (`PdfResults::L2Converter`) expects specific field names to map parsed data into the import pipeline:

**Header fields:**

- `edition`, `meeting_name`, `meeting_date`, `meeting_place`

**Event fields:**

- `event_length`, `event_type`

**Category fields:**

- `cat_title` (parsed to extract category code and gender)

**Result fields (individual):**

- `rank`, `swimmer_name`, `nation`, `year_of_birth`, `team_name`
- `timing` (format: `MM'SS"HH` or `SS"HH`)
- `heat_num`, `lane_num`, `heat_rank`
- `team_score`, `std_score`, `disqualify_type`

**Result fields (relay):**

- `relay_name` or `team_name`, `timing`, `rank`
- Relay swimmer sub-rows: `swimmer_name`, `year_of_birth`, `timing` (delta/absolute)

### 6. Regex Tips

- Use `pop_out: false` when fields share the same line and regexes must not consume text from each other
- Use `token_start` / `token_end` for positional extraction (column-based)
- Use non-capturing groups `(?>...)` for performance
- Escape regex special chars in the YAML string (backslashes need doubling in some cases)
- Test regexes against actual PDF text output, not the visual PDF rendering
- The `lambda: strip` option strips leading/trailing whitespace before matching

### 7. Test the Format

#### 7a. Quick Test via Rails Console

```ruby
# From goggles_admin2 rails console:
fp = PdfResults::FormatParser.new('/path/to/converted_text_file.txt')
fp.scan
fp.result_format_type  # Should return your format name
fp.root_dao            # Should contain parsed data hierarchy
```

#### 7b. Run Existing Specs

```bash
cd /home/steve/Projects/goggles_admin2
bundle exec rspec spec/strategies/pdf_results/ --format documentation
```

#### 7c. Full Pipeline Test

Process the file through the full import pipeline to verify the L2 conversion:

```ruby
fp = PdfResults::FormatParser.new('/path/to/file.txt')
fp.scan
l2 = PdfResults::L2Converter.new(fp.root_dao, fp.season)
data_hash = l2.to_hash
# Inspect data_hash for correct structure
```

### 8. Handling Sub-formats

If the same timing system produces different layouts for different event distances (e.g. longer events have lap rows), create sub-format files:

```text
3-newfamily.yml          # Main format (50m events, no laps)
3-newfamily.100m.yml     # 100m events (with 50m split row)
3-newfamily.400m.yml     # 400m events (with 50m/100m/200m/300m splits)
3-newfamily.4x050m.yml   # Relay 4x50 events
3-newfamily.teamrank.yml # Team ranking page
```

All sub-formats in the same family are tried when the main format wins detection.

## Existing Format Families

| Priority | Family | Source | Count |
|----------|--------|--------|-------|
| 1 | `ficr1` | FICR (Federazione Italiana Cronometristi) | 18 files |
| 1 | `ficr2` | FICR variant 2 | 5 files |
| 1 | `ficrnologo` | FICR without logo | 4 files |
| 2 | `goswim1` | GoSwim / MyResults | 8 files |
| 3 | `fin1` | FIN national | 1 file |
| 3 | `finbasilicata` | FIN Basilicata regional | 5 files |
| 3 | `finfvg` | FIN Friuli-Venezia Giulia | 4+ files |

## Common Pitfalls

- **Regex too greedy**: swimmer names eating into team names. Use fixed-width constraints or `\s{2,}` as separators.
- **Optional rows causing misalignment**: Set `required: false` on spacer rows and let `consumed_rows` handle advancement.
- **Page breaks mid-event**: The `repeat: true` + `parent` chain handles this — the event context carries over from the previous page via `valid_parent_defs`.
- **Encoding issues**: Ensure the text file is UTF-8. Watch for accented Italian characters in city/swimmer names.
- **Relay vs individual**: Different result row patterns. Use separate contexts with different parents.
