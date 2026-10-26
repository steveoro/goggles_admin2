const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
const latin1Decoder = new TextDecoder('windows-1252');

function encodeSegment(value) {
  return encodeURIComponent(String(value)).replace(/%2A/g, '*');
}

// Tolerant counterpart of encodeSegment: decodes anything decodeURIComponent
// accepts, plus escape()-style single-byte sequences (%B0), %uXXXX, and stray
// '%' characters, without ever throwing.
function decodeSegment(value) {
  const text = String(value);
  try {
    return decodeURIComponent(text);
  } catch (error) {
    // Fall through to the byte-tolerant decode below.
  }
  return text.replace(/%u([0-9A-Fa-f]{4})|((?:%[0-9A-Fa-f]{2})+)|%/g,
    (match, unicode, bytes) => {
      if (unicode) return String.fromCharCode(parseInt(unicode, 16));
      if (!bytes) return match;
      const buffer = Buffer.from(bytes.replace(/%/g, ''), 'hex');
      try {
        return utf8Decoder.decode(buffer);
      } catch (error) {
        return latin1Decoder.decode(buffer);
      }
    });
}

// Repairs double-encoded UTF-8 read as Latin-1 (e.g. "CittÃ " for "Città"),
// as stored in some FICR meeting descriptions. Candidates must be pure
// Latin-1 text containing typical mojibake lead bytes, and the repair is
// kept only when the whole string re-decodes cleanly as UTF-8.
// NOTE: the raw string is inspected on purpose — NBSP (U+00A0) is itself a
// frequent mojibake continuation byte ("Ã " = "à"), so whitespace must not
// be normalized before the repair.
function fixMojibake(value) {
  const text = String(value || '');
  if (/[^\x00-\xFF]/.test(text) || !/[ÂÃâ]/.test(text)) return text;
  const repaired = Buffer.from(text, 'latin1').toString('utf8');
  return repaired.includes('�') ? text : repaired;
}

function clean(value) {
  return value === null || value === undefined ? '' : String(value).replace(/\s+/g, ' ').trim();
}

function cleanNullable(value) {
  const result = clean(value);
  return result || null;
}

function nullable(value) {
  return value === null || value === undefined || value === '' ? null : value;
}

function normalizeGender(value) {
  const text = clean(value).toUpperCase();
  if (text.startsWith('F')) return 'F';
  if (text.startsWith('M')) return 'M';
  if (text.startsWith('X')) return 'X';
  return null;
}

function positiveOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function strokeCode(stroke, eventCode) {
  const value = clean(stroke).toUpperCase();
  const map = { L: 'SL', D: 'DO', R: 'RA', F: 'FA', M: 'MI' };
  if (map[value]) return map[value];
  return eventCode.match(/[A-Z]+$/)?.[0] || value;
}

function normalizeEventCode(sourceCode) {
  return clean(sourceCode).toUpperCase().replace(/MX$/i, 'MI');
}

function normalizeMeetingName(value) {
  return clean(value).replace(/^(\d+)'(?=\s)/, '$1°');
}

function relayDistance(eventCode, distance) {
  const match = eventCode.match(/^(\d+X\d+)/i);
  return match ? match[1].toUpperCase() : String(distance || '');
}

function parseHeaderDates(placeText, referenceDate) {
  const source = clean(placeText);
  const dates = [...source.matchAll(/(\d{1,2})\/(\d{1,2})\/(\d{4})/g)]
    .map((match) => `${match[3]}-${match[2].padStart(2, '0')}-${match[1].padStart(2, '0')}`);
  if (!dates.length && referenceDate) {
    const match = String(referenceDate).match(/(\d{4})-(\d{2})-(\d{2})/);
    if (match) dates.push(`${match[1]}-${match[2]}-${match[3]}`);
  }
  const place = source.split(',')[0].trim();
  return { dates: [...new Set(dates)].join(','), place };
}

function groupHistory(rows) {
  const groups = new Map();
  rows.forEach((row) => {
    const key = [row.TipoGara, row.Categoria, row.Batteria, row.Corsia].join('|');
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  });
  return [...groups.values()];
}

function deltaTiming(current, previous) {
  if (!current) return null;
  if (!previous) return current;
  const currentHundredths = timingToHundredths(current);
  const previousHundredths = timingToHundredths(previous);
  if (currentHundredths === null || previousHundredths === null) return null;
  return formatTiming(currentHundredths - previousHundredths);
}

function timingToHundredths(value) {
  const text = clean(value).replace(',', '.');
  if (!text || !/^\d+(?:'\d{1,2})?(?:\.\d{1,2})?$/.test(text)) return null;
  const [minutesPart, secondsPart] = text.includes("'") ? text.split("'") : ['', text];
  const [seconds, hundredths = '0'] = secondsPart.split('.');
  return ((Number(minutesPart) || 0) * 60 + Number(seconds)) * 100 + Number(hundredths.padEnd(2, '0'));
}

function formatTiming(value) {
  if (value < 0) return null;
  const minutes = Math.floor(value / 6000);
  const seconds = Math.floor((value % 6000) / 100);
  const hundredths = value % 100;
  return minutes > 0
    ? `${minutes}'${String(seconds).padStart(2, '0')}.${String(hundredths).padStart(2, '0')}`
    : `${seconds}.${String(hundredths).padStart(2, '0')}`;
}

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

module.exports = {
  clean,
  cleanNullable,
  decodeSegment,
  delay,
  deltaTiming,
  encodeSegment,
  fixMojibake,
  groupHistory,
  normalizeEventCode,
  normalizeGender,
  normalizeMeetingName,
  nullable,
  parseHeaderDates,
  positiveOrNull,
  relayDistance,
  strokeCode
};
