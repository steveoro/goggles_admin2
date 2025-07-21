// This is a temporary test harness for running the crawler from the command line.

const MicroplusCrawler = require('./microplus-crawler');

const args = process.argv.slice(2);

if (args.length < 1) {
  console.error('Usage: node test-crawler.js <file_path_or_url> [season_id]');
  process.exit(1);
}

const meetingUrl = args[0];
const seasonId = args[1] || 242; // Default to 242 if not provided

console.log(`Starting crawler for season ${seasonId} with URL: ${meetingUrl}`);

const crawler = new MicroplusCrawler(seasonId, meetingUrl);
crawler.run();
