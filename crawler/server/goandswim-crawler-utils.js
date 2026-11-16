/*
 * Pure helpers for the Go&Swim results crawler (risultati.goandswim.it).
 *
 * Generic helpers (cleaning, timing math) are shared with the FICR crawler;
 * everything here is specific to the Go&Swim API payloads.
 */
const { clean, deltaTiming, formatTiming, timingToHundredths } = require('./ficr-crawler-utils');

const HOST = 'risultati.goandswim.it';
const STROKES = { S: 'SL', D: 'DO', R: 'RA', F: 'FA', M: 'MI' };
const STROKE_NAMES = { SL: 'Stile Libero', DO: 'Dorso', RA: 'Rana', FA: 'Farfalla', MI: 'Misti' };
const LAP_INTERVALS = [25, 50, 100];
// Same particles as Import::SwimmerNameSplitter on the Rails side.
const SURNAME_PARTICLES = ['DA', 'DAL', 'DALLA', 'DALLE', 'DE', 'DEI', 'DEL', 'DELLA', 'DELLE', 'DEGLI', 'DI', 'DO', 'LA', 'LE', 'LI', 'LO'];

// Accepts "/evento/<eventId>" and "/gara/<eventRaceId>[/<mode>]" (path or hash route).
function parseMeetingUrl(meetingUrl) {
  let parsed;
  try {
    parsed = new URL(String(meetingUrl || ''));
  } catch (error) {
    throw new Error(`meeting_url must be a ${HOST} URL`);
  }
  if (parsed.hostname.toLowerCase() !== HOST) throw new Error(`meeting_url must be a ${HOST} URL`);

  const route = parsed.hash && parsed.hash.length > 2 ? parsed.hash.replace(/^#/, '') : parsed.pathname;
  const parts = route.split('/').filter(Boolean).map(decodeURIComponent);
  const id = parts[1];
  if (parts[0] === 'evento' && id) return { type: 'event', eventId: id };
  if (parts[0] === 'gara' && id) return { type: 'race', eventRaceId: id, mode: parts[2] || null };
  throw new Error('Unsupported Go&Swim URL; expected /evento/<id> or /gara/<id>[/<mode>]');
}

// "MM'SS\"CC" → hundredths, or null for zero, out-of-range or textual values.
function timingHundredths(value) {
  const match = clean(value).match(/^(\d{1,3})'(\d{1,2})"(\d{1,2})$/);
  if (!match) return null;
  const [minutes, seconds, hundredths] = match.slice(1).map(Number);
  if (seconds > 59) return null;
  const total = (minutes * 60 + seconds) * 100 + hundredths;
  return total > 0 ? total : null;
}

// "12'01\"84" → "12'01.84"; "00'37\"54" → "37.54" (FICR LT4 format).
function convertTiming(value) {
  const hundredths = timingHundredths(value);
  return hundredths === null ? null : formatTiming(hundredths);
}

function strokeCode(styleId) {
  const value = clean(styleId).toUpperCase();
  return STROKES[value] || value;
}

function strokeName(stroke) {
  return STROKE_NAMES[stroke] || stroke;
}

function isRelay(description) {
  return /staff|\d+\s*x\s*\d+/i.test(clean(description));
}

// Number of legs declared by the description ("4X50 ..." → 4), or null.
function relayLegCount(description) {
  const match = clean(description).match(/(\d+)\s*x\s*\d+/i);
  return match ? Number(match[1]) : null;
}

// Relay category as an age-sum range: from the description ("120-159") or from
// the category id ("M120" → "120-159", "M80S" → "80-99").
function relayCategory(description, categoryId) {
  const range = clean(description).match(/\b(\d{2,3})\s*-\s*(\d{2,3})\b/);
  if (range) return `${range[1]}-${range[2]}`;
  const raw = clean(categoryId).toUpperCase();
  const code = raw.match(/^M(\d{2,3})/);
  if (!code) return raw || null;
  const start = Number(code[1]);
  return `${start}-${start + (start < 120 ? 19 : 39)}`;
}

function splitRelayMembers(value) {
  return String(value || '')
    .split(/<br\s*\/?>/i)
    .map(clean)
    .filter(Boolean);
}

// "LAST FIRST" split mirroring Import::SwimmerNameSplitter (Rails), so that the
// swimmer keys built here survive the Phase 3 name resolution unchanged:
// 2 tokens → 1+1; 3 tokens → 2+1 after a surname particle, else 1+2; 4+ → 2+rest.
function splitAthleteName(fullName) {
  const tokens = clean(fullName).split(' ').filter(Boolean);
  if (tokens.length === 0) return { lastName: '', firstName: '' };
  if (tokens.length === 1) return { lastName: tokens[0], firstName: '' };
  if (tokens.length === 2) return { lastName: tokens[0], firstName: tokens[1] };
  if (tokens.length === 3 && !SURNAME_PARTICLES.includes(tokens[0].toUpperCase())) {
    return { lastName: tokens[0], firstName: tokens.slice(1).join(' ') };
  }
  return { lastName: tokens.slice(0, 2).join(' '), firstName: tokens.slice(2).join(' ') };
}

// Cumulative split string "01'21\"11-02'50\"76-...-" → ["1'21.11", "2'50.76", ...].
// Unparseable entries become null (callers treat the list as invalid).
function parseSplits(splitDetails) {
  return String(splitDetails || '')
    .split('-')
    .map(clean)
    .filter(Boolean)
    .map(convertTiming);
}

// Splits as a cumulative list that always ends with the final time
// (the API usually includes it; when it does not, it is appended).
function withFinal(splits, finalTiming) {
  const last = splits[splits.length - 1];
  if (!finalTiming || sameTiming(last, finalTiming)) return [...splits];
  return [...splits, finalTiming];
}

function sameTiming(left, right) {
  const a = timingToHundredths(left);
  return a !== null && a === timingToHundredths(right);
}

function isIncreasing(timings) {
  const values = timings.map(timingToHundredths);
  return values.every((value, index) => value !== null && (index === 0 || value > values[index - 1]));
}

// Individual laps from cumulative splits. The lap interval is deduced from the
// number of splits (the `step` field of the API is unreliable).
// Returns { laps, warning } where warning is null when the splits are usable.
function buildLaps({ length, splits, finalTiming }) {
  if (!splits || splits.length === 0) return { laps: [], warning: null };
  if (splits.some((split) => split === null)) {
    return { laps: [], warning: 'unparseable split times' };
  }
  const full = withFinal(splits, finalTiming);
  if (full.length === 1) return { laps: [], warning: null };

  const distance = Number(length);
  const interval = distance / full.length;
  if (!Number.isInteger(interval) || !LAP_INTERVALS.includes(interval)) {
    return { laps: [], warning: `${splits.length} splits do not fit ${distance} m` };
  }
  if (!isIncreasing(full)) return { laps: [], warning: 'split times are not increasing' };

  const intermediate = full.slice(0, -1);
  const laps = intermediate.map((timing, index) => ({
    distance: `${interval * (index + 1)}m`,
    timing,
    delta: deltaTiming(timing, index > 0 ? intermediate[index - 1] : null),
    position: null
  }));
  return { laps, warning: null };
}

// Relay legs from cumulative splits: one entry per leg (sub-leg splits folded
// into the leg delta). The member swimmer key is attached by the crawler.
function buildRelayLaps({ legLength, legCount, splits, finalTiming }) {
  if (!splits || splits.length === 0) return { laps: [], warning: 'no splits published' };
  if (splits.some((split) => split === null)) return { laps: [], warning: 'unparseable split times' };
  const full = withFinal(splits, finalTiming);
  if (!legCount || full.length % legCount !== 0) {
    return { laps: [], warning: `${splits.length} splits do not fit ${legCount} legs` };
  }
  if (!isIncreasing(full)) return { laps: [], warning: 'split times are not increasing' };

  const perLeg = full.length / legCount;
  const legEnds = Array.from({ length: legCount }, (_, index) => full[(index + 1) * perLeg - 1]);
  const laps = legEnds.map((timing, index) => ({
    distance: `${Number(legLength) * (index + 1)}m`,
    delta: deltaTiming(timing, index > 0 ? legEnds[index - 1] : null)
  }));
  return { laps, warning: null };
}

// "2026-11-15T00:00:00" → "2026-11-15"
function isoDate(value) {
  return clean(value).match(/^\d{4}-\d{2}-\d{2}/)?.[0] || null;
}

// Every ISO day from start to end (inclusive, at most 31 days).
function dateRange(startDate, endDate) {
  const start = isoDate(startDate);
  if (!start) return [];
  const end = isoDate(endDate) || start;
  const dates = [];
  const cursor = new Date(`${start}T00:00:00Z`);
  const last = new Date(`${end}T00:00:00Z`);
  while (cursor <= last && dates.length < 31) {
    dates.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return dates.length ? dates : [start];
}

module.exports = {
  buildLaps,
  buildRelayLaps,
  convertTiming,
  dateRange,
  formatHundredths: formatTiming,
  isRelay,
  isoDate,
  parseMeetingUrl,
  parseSplits,
  relayCategory,
  relayLegCount,
  splitAthleteName,
  splitRelayMembers,
  strokeCode,
  strokeName,
  timingHundredths
};
