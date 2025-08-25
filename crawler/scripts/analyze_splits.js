#!/usr/bin/env node
/*
 * analyze_splits.js
 *
 * Usage:
 *   node crawler/scripts/analyze_splits.js <results.json> [--min=50] [--max=800] [--step=50] [--continuation-only]
 *
 * Outputs lines with swimmer/relay identifiers and which distances are missing.
 */

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { file: null, min: 50, max: null, step: 50, continuationOnly: false };
  for (const a of argv.slice(2)) {
    if (!a.startsWith('--')) { args.file = a; continue; }
    if (a.startsWith('--min=')) args.min = parseInt(a.split('=')[1], 10);
    else if (a.startsWith('--max=')) args.max = parseInt(a.split('=')[1], 10);
    else if (a.startsWith('--step=')) args.step = parseInt(a.split('=')[1], 10);
    else if (a === '--continuation-only') args.continuationOnly = true;
  }
  return args;
}

function inferMaxFromFilename(filePath) {
  const base = path.basename(filePath).toLowerCase();
  // Try to match common pool events
  const known = [200, 400, 800, 1500];
  const m = base.match(/(\d{3,4})\s*(sl|stile|mi|ra|fa|do|mx)?/i);
  if (m) {
    const val = parseInt(m[1], 10);
    if (known.includes(val)) return val;
  }
  return null;
}

function collectObservedMax(results) {
  let max = 0;
  for (const res of results) {
    for (const lap of (res.laps || [])) {
      const d = (lap.distance || '').toString().toLowerCase().trim();
      const mv = parseInt(d.replace(/[^0-9]/g, ''), 10);
      if (Number.isFinite(mv) && mv > max) max = mv;
    }
  }
  return max;
}

function expectedDistances(min, max, step, continuationOnly) {
  const out = [];
  const start = continuationOnly ? Math.max(min, 450) : min;
  for (let d = start; d < max; d += step) out.push(`${d}m`);
  return out;
}

function nameForResult(res, swimmersMap) {
  const ln = res.lastName || res.lastname || '';
  const fn = res.firstName || res.firstname || '';
  let base = (ln || fn) ? `${ln} ${fn}`.trim() : '';
  if (!base && res.swimmer && swimmersMap && swimmersMap[res.swimmer]) {
    const s = swimmersMap[res.swimmer];
    if (s && (s.lastName || s.firstName)) {
      base = `${s.lastName || ''} ${s.firstName || ''}`.trim();
    }
  }
  if (!base) base = res.relay || res.team || 'N/A';
  const lane = res.lane ? ` (lane ${res.lane})` : '';
  return `${base}${lane}`;
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.file) {
    console.error('Usage: node crawler/scripts/analyze_splits.js <results.json> [--min=50] [--max=800] [--step=50] [--continuation-only]');
    process.exit(1);
  }
  const raw = fs.readFileSync(args.file, 'utf8');
  const data = JSON.parse(raw);

  const swimmersMap = data.swimmers || {};
  let allResults = [];
  if (Array.isArray(data.heats) && data.heats.length > 0) {
    allResults = data.heats.flatMap(h => Array.isArray(h.results) ? h.results : []);
  } else if (Array.isArray(data.events) && data.events.length > 0) {
    allResults = data.events.flatMap(e => Array.isArray(e.results) ? e.results : []);
  }

  // Determine max distance to expect
  let max = args.max;
  if (!Number.isFinite(max)) {
    max = inferMaxFromFilename(args.file);
  }
  if (!Number.isFinite(max) || max <= 0) {
    const obs = collectObservedMax(allResults);
    // If observed max is 400 or less, we still use that; otherwise clamp to nearest known long distance (800/1500)
    if (obs >= 700 && obs <= 800) max = 800; else if (obs > 800 && obs <= 1500) max = 1500; else max = Math.max(400, obs || 400);
  }

  const expected = new Set(expectedDistances(args.min, max, args.step, args.continuationOnly));

  let missingCount = 0;
  for (const res of allResults) {
    const distances = new Set((res.laps || []).map(l => (l.distance || '').toString().toLowerCase().trim()));
    const missing = Array.from(expected).filter(d => !distances.has(d));
    if (missing.length > 0) {
      missingCount++;
      console.log(`${nameForResult(res, swimmersMap)} -> missing: ${missing.join(', ')}`);
    }
  }

  console.error(`\nAnalyzed ${allResults.length} results. Rows with missing distances: ${missingCount}. Expected set: [${Array.from(expected).join(', ')}]`);
}

if (require.main === module) {
  try { main(); } catch (e) { console.error('Error:', e && e.message); process.exit(2); }
}
