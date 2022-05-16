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
//-----------------------------------------------------------------------------

apiRouter.get("/pull_calendar", (req, res) => {
  // DEBUG
  console.log('GET /pull_calendar');
  console.log('- season_id:', req.query.season_id)
  console.log('- start_url:', req.query.start_url)
  const calCrawler = new CalendarCrawler(req.query.season_id, req.query.start_url);
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

apiRouter.get("/status", (_req, res) => {
  res.send(CrawlUtil.readStatus());
});
//-----------------------------------------------------------------------------

// Export w/ overriding defaults:
module.exports = apiRouter;
