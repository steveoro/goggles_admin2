/*
 *  microplus-crawler.js
 *
 *  This is a crawler for the new Microplus Timing results layout.
 *  It is designed to be run from the API server.
 */
const fs = require('fs');
const puppeteer = require('puppeteer');
const cheerio = require('cheerio');
const path = require('path');
const CrawlUtil = require('./utility');

//-----------------------------------------------------------------------------

class MicroplusCrawler {
  constructor(seasonId, meetingUrl, targetEventTitle = null) {
    this.seasonId = seasonId;
    this.meetingUrl = meetingUrl;
    this.targetEventTitle = targetEventTitle;
    this.layoutType = 4; // New layout type for Microplus

    // Set this to true to limit the crawling to just the first available event page:
    this.limitEvents = false;
  }

  /**
   * Main entry point for the crawler.
   */
  /**
   * Waits for the results table to be loaded and populated.
   * @param {object} page - The Puppeteer page object.
   * @param {string} stage - The current crawl stage for logging (e.g., 'Heats', 'Rankings').
   * @returns {Promise<string>} - A promise that resolves with the HTML of the loaded table.
   */
  async run() {
    let browser;
    // This is the main promise chain that will be returned
    const promise = new Promise(async (resolve, reject) => {
      try {
        CrawlUtil.updateStatus(`[microplus-crawler] Starting crawl for season ${this.seasonId}, layout ${this.layoutType}...`);
        browser = await puppeteer.launch({
          headless: true,
          args: ['--no-sandbox', '--disable-setuid-sandbox']
        });
        const page = await browser.newPage();
        page.on('console', msg => console.log('BROWSER LOG:', msg.text()));
        await page.setViewport({ width: 1280, height: 1024 });

        // Start crawl
        console.log(`  Navigating to ${this.meetingUrl}...`);
        await page.goto(this.meetingUrl, { waitUntil: 'networkidle2' });

        const meetingHeader = await this.processMeetingHeader(await page.content());
        console.log(`  Meeting: ${meetingHeader.title} (${meetingHeader.dates})`);

        console.log(`      Clicking on 'PER_EVENTO_tab'...`);
        await page.waitForSelector('a#divByEvent', { visible: true, timeout: 30000 });
        await page.evaluate(() => document.querySelector('a#divByEvent').click());
        await page.waitForSelector('#tblMainSxScroll', { timeout: 30000 });

        let eventsToProcess = await page.evaluate(() => {
          const events = [];
          let currentGender = '';
          const rows = document.querySelectorAll('#tblMainSxScroll tr');

          rows.forEach(row => {
            const genderCell = row.querySelector('td.GaraRound.aCenter');
            if (genderCell) {
              currentGender = genderCell.innerText.trim();
            } else {
              const descriptionCell = row.querySelector('td.wCalCategory nobr');
              const onclickAttr = row.getAttribute('onclick');
              if (descriptionCell && onclickAttr && onclickAttr.startsWith('LoadAndManageHistory')) {
                events.push({
                  onclick: onclickAttr,
                  description: descriptionCell.innerText.trim(),
                  gender: currentGender
                });
              }
            }
          });
          return events;
        });

        console.log(`   Found ${eventsToProcess.length} events to process.`);
        let allResults = { ...meetingHeader, layoutType: this.layoutType, seasonId: this.seasonId, meetingURL: this.meetingUrl, events: [] };

        if (this.targetEventTitle) {
          eventsToProcess = eventsToProcess.filter(event => event.description.includes(this.targetEventTitle));
          console.log(`[microplus-crawler] Target event specified. Filtered to ${eventsToProcess.length} event(s).`);
        }

        const events = this.limitEvents ? eventsToProcess.slice(0, 1) : eventsToProcess;

        for (const event of events) {
          try {
            console.log(`   Processing event: ${event.description}`);
            console.log('      - Stage 1: Executing onclick and waiting for AJAX response...');
            const onclickParams = event.onclick.match(/\((.*)\)/)[1];
            const [response] = await Promise.all([
              page.waitForResponse(response => response.url().includes('.JSON') && response.status() === 200),
              page.evaluate((params) => {
                eval(`LoadAndManageHistory(${params})`);
              }, onclickParams)
            ]);
            const responseUrl = response.url();
            console.log(`      - Stage 1: AJAX response received from: ${responseUrl}`);

            const heatResultsHtml = await this.waitForTableToLoad(page, 'Heats');
            const heatData = this.processHeatResults(heatResultsHtml);
            console.log('      - Done parsing heats.');

            console.log('      - Stage 3: Clicking RIEPILOGO tab and waiting for AJAX...');
            await page.evaluate(() => {
              // This is the actual onclick function for the summary tab
              CheckJsonForLoadOnMain(codSummary, true, true);
            });

            await page.waitForResponse(response => response.url().includes('.JSON') && response.status() === 200, { timeout: 30000 });
            console.log('      - Stage 4: Rankings data loaded.');

            const rankingResultsHtml = await this.waitForTableToLoad(page, 'Rankings');
            const rankingData = this.processRankingResults(rankingResultsHtml);
            console.log('      - Done parsing rankings.');

            const eventResults = {
              ...CrawlUtil.parseEventInfoFromDescription(event.description, event.gender),
              eventDescription: event.description,
              eventDate: CrawlUtil.parseEventDate(event.date, meetingHeader.dates),
              eventGender: event.gender,
              results: rankingData.results,
              heats: heatData.heats
            };

            eventResults.results.forEach(result => {
              for (const heat of eventResults.heats) {
                const heatResult = heat.results.find(hr =>
                  hr.lastName === result.lastName &&
                  hr.firstName === result.firstName &&
                  hr.year === result.year
                );
                if (heatResult) {
                  result.heat_position = heatResult.heat_position;
                  result.laps = heatResult.laps;
                }
              }
            });
            allResults.events.push(eventResults);
          } catch (e) {
            console.error(`Failed to process event '${event.description}': ${e.message}`);
            const errorTimestamp = new Date().toISOString().replace(/:/g, '-');
            const screenshotPath = path.join(__dirname, `../data/error_screenshot_${errorTimestamp}.png`);
            const htmlPath = path.join(__dirname, `../data/error_page_${errorTimestamp}.html`);

            try {
              await page.screenshot({ path: screenshotPath, fullPage: true });
              console.log(`[microplus-crawler] Screenshot saved to ${screenshotPath}`);
              const htmlContent = await page.content();
              fs.writeFileSync(htmlPath, htmlContent);
              console.log(`[microplus-crawler] Page HTML saved to ${htmlPath}`);
            } catch (saveError) {
              console.error(`[microplus-crawler] Failed to save error artifacts: ${saveError.message}`);
            }
          } finally {
            // Go back to the event list to process the next one
            console.log(`      - Navigating back to event list...`);
            await page.click('#divByEvent');
            await page.waitForTimeout(500); // Wait a bit for the tab to switch
          }
        }

        const outputPath = path.join(__dirname, `../data/results/results_s${this.seasonId}_l${this.layoutType}.json`);
        const outputDir = path.dirname(outputPath);
        if (!fs.existsSync(outputDir)) {
          fs.mkdirSync(outputDir, { recursive: true });
        }
        fs.writeFileSync(outputPath, JSON.stringify(allResults, null, 2));
        console.log(`[microplus-crawler] Crawl finished. Results saved to ${outputPath}`);
        CrawlUtil.updateStatus('Crawl finished.', 'DONE');
        resolve();

      } catch (error) {
        console.error(`[microplus-crawler] A critical error occurred: ${error.message}`);
        console.error(error.stack);
        CrawlUtil.updateStatus('An error occurred.', 'ERROR');
        reject(error);
      } finally {
        if (browser) {
          await browser.close();
        }
      }
    });
    return promise;
  }

  async waitForTableToLoad(page, stage) {
    console.log(`      - [waitForTableToLoad] Waiting for ${stage} content to render...`);
    const selector = 'div#tblContenutiHeats table.tblContenutiRESSTL_Sotto_Heats';
    await page.waitForSelector(selector, { timeout: 30000 });

    let rowCount = 0;
    const startTime = Date.now();
    while (Date.now() - startTime < 30000) {
      try {
        const result = await page.evaluate((sel) => {
          const table = document.querySelector(sel);
          if (!table) return { rowCount: 0, found: false };
          const tbody = table.querySelector('tbody');
          if (!tbody) return { rowCount: 0, found: true, noTbody: true };
          return { rowCount: tbody.rows.length, found: true };
        }, selector);

        rowCount = result.rowCount;
        if (!result.found) {
          console.log(`      - [waitForTableToLoad] Polling... table not found yet.`);
        } else if (result.noTbody) {
          console.log(`      - [waitForTableToLoad] Polling... table found, but tbody not yet.`);
        } else {
          console.log(`      - [waitForTableToLoad] Polling... table found with ${rowCount} rows.`);
        }

        if (rowCount > 1) {
          console.log(`      - [waitForTableToLoad] ${stage} table loaded with ${rowCount} rows.`);
          return await page.evaluate((sel) => document.querySelector(sel).outerHTML, selector);
        }
      } catch (e) {
        console.log(`      - [waitForTableToLoad] Polling error: ${e.message}`);
      }
      await new Promise(resolve => setTimeout(resolve, 500)); // Poll every 500ms
    }
    throw new Error(`Timeout waiting for ${stage} table to be populated with data.`);
  }

  processMeetingHeader(html) {
    const $ = cheerio.load(html);
    const headerRow = $('table.tblHeader tr.tblHeaderTr1');
    const title = headerRow.find('td.Meeting').text().trim();
    const dates = headerRow.find('td.Date').text().trim();
    const place = headerRow.find('td.Place').text().trim();
    return { title, dates, place };
  }

  processHeatResults(html) {
    const $ = cheerio.load(html);
    const heats = [];
    $('table#tblContenutiRESSTL_Sotto_Heats tr').each((i, row) => {
      const header = $(row).find('td.headerContenuti');
      if (header.length > 0) {
        heats.push({ number: header.text().trim().replace('Serie', '').trim(), results: [] });
      } else if (heats.length > 0 && ($(row).hasClass('trContenutiToggle') || $(row).hasClass('trContenuti'))) {
        const cols = $(row).find('td');
        if (cols.length > 5) {
          const nameDataHtml = $(cols[4]).html();
          if (!nameDataHtml) return;

          const nameData = nameDataHtml.split('<br>');
          const timingData = [];
          for (let i = 5; i < cols.length; i++) {
            timingData.push($(cols[i]).text().trim());
          }

          const fullName = $('<div>').html(nameData[0]).text().replace(/&nbsp;/g, ' ').trim();
          const nameParts = fullName.split(/\s+/);

          const result = {
            heat_position: $(cols[0]).text().trim(),
            lane: $(cols[1]).text().trim(),
            lastName: nameParts[0] || '',
            firstName: nameParts.slice(1).join(' ') || '',
            year: nameData[1] ? $('<div>').html(nameData[1]).text().replace(/[()]/g, '').trim() : 'N/A',
            team: nameData[2] ? $('<div>').html(nameData[2]).text().trim() : 'N/A',
            timing: timingData.pop() || '',
            laps: timingData
          };
          heats[heats.length - 1].results.push(result);
        }
      }
    });
    return { heats };
  }

  processRankingResults(html) {
    const $ = cheerio.load(html);
    const results = [];
    let currentCategory = 'N/A';

    $('table#tblContenutiRESSTL_Sotto_Summary tr').each((i, row) => {
      const header = $(row).find('td.headerContenuti');
      if (header.length > 0) {
        currentCategory = header.text().trim();
      } else if ($(row).hasClass('trContenutiToggle') || $(row).hasClass('trContenuti')) {
        const cols = $(row).find('td');
        if (cols.length > 4) {
          const nameDataHtml = $(cols[3]).html();
          if (!nameDataHtml) return;

          const nameData = nameDataHtml.split('<br>');
          const fullName = $('<div>').html(nameData[0]).text().replace(/&nbsp;/g, ' ').trim();
          const nameParts = fullName.split(/\s+/);

          const result = {
            position: $(cols[0]).text().trim(),
            lane: $(cols[1]).text().trim(),
            lastName: nameParts[0] || '',
            firstName: nameParts.slice(1).join(' ') || '',
            year: nameData[1] ? $('<div>').html(nameData[1]).text().replace(/[()]/g, '').trim() : 'N/A',
            team: nameData[2] ? $('<div>').html(nameData[2]).text().trim() : 'N/A',
            timing: $(cols[4]).text().trim(),
            category: currentCategory
          };
          results.push(result);
        }
      }
    });
    return { results };
  }
}

module.exports = MicroplusCrawler;
