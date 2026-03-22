---
description: Add a new crawler layout in the JS crawler subdirectory — HTML scraping, JSON output, manifest files, and Rails integration
auto_execution_mode: 2
---

# New Crawler Layout

Use this skill when adding a new web scraping layout to the Node.js crawler in `goggles_admin2`.

## Background

- Crawler lives in `/home/steve/Projects/goggles_admin2/crawler/`
- Technology: Node.js, Cheerio (HTML parsing), Express, csv-parser
- Input: Official result websites (e.g. Microplus timing, FIN result pages)
- Output: JSON files in L2 format (ready for `Import::MacroSolver`)
- Data lifecycle: `data/results.new/` → processed → `data/results.done/` or `data/results.sent/`

## Directory Structure

```text
crawler/
├── data/
│   ├── calendar.new/        # New calendar data
│   ├── calendar.done/       # Processed calendar data
│   ├── manifests/           # Crawl manifests (what to scrape)
│   ├── results.new/         # Freshly crawled JSON results
│   ├── results.done/        # Successfully processed results
│   ├── results.sent/        # Results sent to remote API
│   ├── pdfs/                # Downloaded PDFs awaiting text extraction
│   ├── pdfs.done/           # Processed PDFs
│   ├── samples/             # Sample data for testing
│   ├── standard_timings/    # Standard timing reference data
│   └── debug/               # Debug output
├── node_modules/            # Dependencies
├── package.json
├── README.md
└── crawler-status.json      # Current crawler state
```

## L2 Output Format

The crawler outputs JSON files with `layoutType: 2`, the format expected by `Import::MacroSolver`. Key structure:

```json
{
  "layoutType": 2,
  "name": "Meeting Description",
  "meetingURL": "https://...",
  "manifestURL": "https://...",
  "dateDay1": "15",
  "dateMonth1": "03",
  "dateYear1": "2025",
  "venue1": "City Name",
  "address1": "Pool Address",
  "organization": "Organizing body",
  "sections": [
    {
      "title": "50 Stile Libero - Femmine",
      "fin_id_evento": "...",
      "category": "M25",
      "gender": "F",
      "event_length": 50,
      "event_type": "Stile Libero",
      "rows": [
        {
          "pos": "1",
          "name": "ROSSI MARIA",
          "year": "1995",
          "team": "Team Name",
          "timing": "0'28\"50",
          "score": "850.00"
        }
      ]
    }
  ]
}
```

## Adding a New Layout

### 1. Identify the Source

Examine the target website's HTML structure:

- How are result pages organized? (single page, paginated, per-event)
- What HTML elements contain the data? (tables, divs, specific classes/IDs)
- How are events and categories separated?
- Is there session/date information on the page?

### 2. Create/Modify the Scraping Logic

The crawler uses Cheerio to parse HTML. A typical scraping function:

```javascript
const cheerio = require('cheerio');

function parseResultPage(html, meetingData) {
  const $ = cheerio.load(html);
  const sections = [];

  // Find each event section:
  $('selector-for-event-blocks').each((i, eventBlock) => {
    const eventTitle = $(eventBlock).find('.event-title').text().trim();
    const rows = [];

    // Parse each result row:
    $(eventBlock).find('tr.result-row').each((j, row) => {
      rows.push({
        pos: $(row).find('.rank').text().trim(),
        name: $(row).find('.swimmer-name').text().trim(),
        year: $(row).find('.year').text().trim(),
        team: $(row).find('.team').text().trim(),
        timing: $(row).find('.timing').text().trim(),
        score: $(row).find('.score').text().trim()
      });
    });

    sections.push({
      title: eventTitle,
      // Parse event_length, event_type, category, gender from title
      rows: rows
    });
  });

  return {
    layoutType: 2,
    name: meetingData.name,
    meetingURL: meetingData.url,
    // ... other meeting-level fields
    sections: sections
  };
}
```

### 3. Handle the Data Flow

```javascript
const fs = require('fs');
const path = require('path');

// Write the output JSON:
const outputPath = path.join(__dirname, 'data/results.new', `${meetingCode}.json`);
fs.writeFileSync(outputPath, JSON.stringify(resultData, null, 2));
```

### 4. Manifest Files

Manifests in `data/manifests/` tell the crawler what to scrape. They typically contain URLs, season info, and meeting metadata needed to construct the output.

### 5. Test the Output

Verify the JSON is valid L2 format by loading it in `goggles_admin2` Rails console:

```ruby
f = File.read('crawler/data/results.new/<filename>.json')
data = JSON.parse(f)
data['layoutType']  # Should be 2
data['sections'].count  # Should match expected event count
data['sections'].first['rows'].count  # Should have result rows
```

Then test through the full pipeline:

```ruby
season = GogglesDb::Season.find(<season_id>)
solver = Import::MacroSolver.new(season_id: season.id, data_hash: data, toggle_debug: true)
# Check solver.data for resolved entities
```

## Rails Integration

The Rails side of `goggles_admin2` picks up files from `crawler/data/results.new/`. The import controllers or services read these JSON files and feed them to `Import::MacroSolver` → `Import::MacroCommitter`.

Key integration points:

- Controllers in `app/controllers/` manage the import workflow UI
- `Import::MacroSolver` processes the L2 JSON hash
- `Import::MacroCommitter` commits to DB and generates SQL
- `ApiProxy` sends the SQL batch to the remote server

## Common Issues

- **Encoding**: Ensure HTML is parsed as UTF-8. Italian characters (à, è, é, ì, ò, ù) must be preserved.
- **Timing format**: Different sites use different formats (`0'28"50`, `28.50`, `0:28.50`). Normalize to what `Parser::Timing` expects.
- **Missing data**: Some result pages omit year of birth, nation, or scores. Use sensible defaults or leave blank.
- **Rate limiting**: Add delays between requests to avoid being blocked.
- **Page structure changes**: Websites change their HTML structure over time. The crawler may need updates.
