/*
 * API router middleware.
 *
 * Defines all the crawler server API endpoints.
 *
 * -- Note: --
 * Install all modules enlisted below with 'npm install <package-name> --save', except node.js itself:
 *  > sudo apt-get install nodejs
 */
const express = require("express");
const apiRouter = express.Router();

// Local modules:
const CrawlUtil = require('./utility') // Crawler utility functions
const CalendarCrawler = require('./calendar-crawler');
const ResultsCrawler = require('./results-crawler.js');
const MicroplusCrawler = require('./microplus-crawler.js');
//-----------------------------------------------------------------------------

apiRouter.get("/pull_calendar", (req, res) => {
  // DEBUG
  console.log('GET /pull_calendar');
  console.log('- season_id....:', req.query.season_id)
  console.log('- start_url....:', req.query.start_url)
  console.log('- sub_menu_type:', req.query.sub_menu_type)
  console.log('- year_text....:', req.query.year_text)
  const calCrawler = new CalendarCrawler(
    req.query.season_id, req.query.start_url,
    req.query.sub_menu_type, req.query.year_text
  );
  calCrawler.run();
  res.send(CrawlUtil.readStatus());
});

apiRouter.get("/pull_results", (req, res) => {
  // DEBUG
  console.log('GET /pull_results');
  console.log('- season_id:', req.query.season_id)
  console.log('- file_path:', req.query.file_path)
  console.log('- layout:', req.query.layout)
  const resCrawler = new ResultsCrawler(req.query.season_id, req.query.file_path, req.query.layout);
  resCrawler.run();
  res.send(CrawlUtil.readStatus());
});

apiRouter.get("/pull_results_microplus", (req, res) => {
  const seasonId = req.query.season_id;
  const meetingUrl = req.query.meeting_url;
  const targetEventTitle = req.query.target_event;

  console.log('GET /pull_results_microplus');
  console.log(`- season_id: ${seasonId}`);
  console.log(`- meeting_url: ${meetingUrl}`);
  if (targetEventTitle) {
    console.log(`- target_event: ${targetEventTitle}`);
  }

  if ( !seasonId || !meetingUrl ) {
    return res.status(400).json({ error: 'Missing season_id or meeting_url' });
  }

  const crawler = new MicroplusCrawler(seasonId, meetingUrl, targetEventTitle);
  crawler.run();
  res.json(CrawlUtil.readStatus());
});

apiRouter.get("/status", (_req, res) => {
  res.send(CrawlUtil.readStatus());
});
//-----------------------------------------------------------------------------

// Export w/ overriding defaults:
module.exports = apiRouter;
