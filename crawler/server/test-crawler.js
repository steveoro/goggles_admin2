// This is a temporary test harness for running the crawler from the command line.

const fs = require('fs');
const path = require('path');
const MicroplusCrawler = require('./microplus-crawler');

const args = process.argv.slice(2);

if (args.length < 1) {
  console.error('Usage: node test-crawler.js <file_path_or_url> [season_id] [target_event_title]');
  console.error('Example: node test-crawler.js "https://.../Riccione_web.php" 242 "Femmine - 200 m Dorso - Serie"');
  process.exit(1);
}

// Centralized debug log in crawler/data/debug, reset at each run
const debugDir = path.join(__dirname, '../data/debug');
try { fs.mkdirSync(debugDir, { recursive: true }); } catch {}
const debugLogPath = path.join(debugDir, 'debug_log.txt');
try { fs.writeFileSync(debugLogPath, ''); } catch {}

// Tee console output to debug log
const originalLog = console.log;
const originalErr = console.error;
const writeLog = (prefix, args) => {
  const line = args.map(a => (typeof a === 'string' ? a : (() => {
    try { return JSON.stringify(a); } catch { return String(a); }
  })())).join(' ');
  try { fs.appendFileSync(debugLogPath, `${prefix}${line}\n`); } catch {}
};
console.log = (...args) => { originalLog(...args); writeLog('', args); };
console.error = (...args) => { originalErr(...args); writeLog('[ERROR] ', args); };

const meetingUrl = args[0];
const seasonId = args[1] || 242; // Default to 242 if not provided
const targetEventTitle = args[2]; // Optional: focus crawl to a specific event by title substring

console.log(`Starting crawler for season ${seasonId} with URL: ${meetingUrl}`);
if (targetEventTitle) {
  console.log(`Target event filter: "${targetEventTitle}"`);
}

const crawler = new MicroplusCrawler(seasonId, meetingUrl, targetEventTitle);
crawler.run();
