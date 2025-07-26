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
        
        // Parse place and dates from URL
        const urlInfo = CrawlUtil.parsePlaceAndDatesFromUrl(this.meetingUrl);
        if (urlInfo.place) meetingHeader.place = urlInfo.place;
        if (urlInfo.dates) meetingHeader.dates = urlInfo.dates;
        
        console.log(`  Meeting: ${meetingHeader.title} (${meetingHeader.dates}) at ${meetingHeader.place}`);

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
                  description: descriptionCell.innerText.trim().replace(/\u00A0/g, ' ').replace(/\s+/g, ' '),
                  gender: currentGender
                });
              }
            }
          });
          return events;
        });

        console.log(`   Found ${eventsToProcess.length} events to process.`);
        
        // Initialize optimized output structure with lookup tables
        let allResults = { 
          ...meetingHeader, 
          layoutType: this.layoutType, 
          seasonId: this.seasonId, 
          meetingURL: this.meetingUrl,
          swimmers: {}, // Lookup table for unique swimmers
          teams: {}, // Lookup table for unique teams
          events: [] 
        };

        if (this.targetEventTitle) {
          const originalEvents = [...eventsToProcess]; // Store original list for debugging
          const normalizedTarget = this.targetEventTitle.replace(/\u00A0/g, ' ').replace(/\s+/g, ' ').toUpperCase();
          eventsToProcess = eventsToProcess.filter(event => {
            const normalizedDescription = event.description.replace(/\u00A0/g, ' ').replace(/\s+/g, ' ').toUpperCase();
            return normalizedDescription.includes(normalizedTarget);
          });
          console.log(`[microplus-crawler] Target event specified: "${this.targetEventTitle}". Filtered to ${eventsToProcess.length} event(s).`);
          if (eventsToProcess.length === 0) {
            console.log(`[microplus-crawler] No events matched. Available events:`);
            originalEvents.forEach((event, i) => {
              console.log(`  ${i + 1}. "${event.description}"`);
            });
          }
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
            console.log(`[DEBUG] heatResultsHtml length: ${heatResultsHtml ? heatResultsHtml.length : 'NULL'}`);
            console.log(`[DEBUG] Calling processHeatResults...`);
            const heatData = this.processHeatResults(heatResultsHtml);
            console.log(`[DEBUG] processHeatResults returned:`, JSON.stringify(heatData, null, 2));
            console.log('      - Done parsing heats.');

            console.log('      - Stage 3: Clicking RIEPILOGO tab and waiting for AJAX...');
            await page.evaluate(() => {
              // This is the actual onclick function for the summary tab
              CheckJsonForLoadOnMain(codSummary, true, true);
            });

            await page.waitForResponse(response => response.url().includes('.JSON') && response.status() === 200, { timeout: 30000 });
            console.log('      - Stage 4: Rankings data loaded.');

            const rankingResultsHtml = await this.waitForRiepilogoToLoad(page);
            console.log(`[DEBUG] rankingResultsHtml length: ${rankingResultsHtml ? rankingResultsHtml.length : 'NULL'}`);
            console.log(`[DEBUG] Calling processRankingResults...`);
            const rankingData = this.processRankingResults(rankingResultsHtml);
            console.log(`[DEBUG] processRankingResults returned:`, JSON.stringify(rankingData, null, 2));
            console.log('      - Done parsing rankings.');

            // Parse event info with improved header details
            console.log(`[DEBUG] Parsing event: "${event.description}" with gender: "${event.gender}"`);            
            const eventInfo = CrawlUtil.parseEventInfoFromDescription(event.description, event.gender);
            console.log(`[DEBUG] Parsed eventInfo:`, JSON.stringify(eventInfo, null, 2));
            
            // Force debug output to file to capture what's happening
            const fs = require('fs');
            const debugInfo = {
              timestamp: new Date().toISOString(),
              eventDescription: event.description,
              eventGender: event.gender,
              parsedEventInfo: eventInfo
            };
            fs.appendFileSync('/tmp/crawler_debug_detailed.log', JSON.stringify(debugInfo, null, 2) + '\n\n');
            
            // Create merged results array combining ranking and heat data
            const mergedResults = [];
            
            // First, collect all heat results with lap timings
            const heatResultsMap = new Map();
            for (const heat of heatData.heats) {
              for (const heatResult of heat.results) {
                const swimmerKey = CrawlUtil.createSwimmerKey(
                  eventInfo.eventGender,
                  heatResult.lastName,
                  heatResult.firstName, 
                  heatResult.year,
                  heatResult.team
                );
                heatResultsMap.set(swimmerKey, heatResult);
              }
            }
            
            // Process each RIEPILOGO result and merge with heat data
            rankingData.results.forEach(rankingResult => {
              // Create unique swimmer key for RIEPILOGO result with gender prefix
              const swimmerKey = CrawlUtil.createSwimmerKey(
                eventInfo.eventGender,
                rankingResult.lastName,
                rankingResult.firstName,
                rankingResult.year,
                rankingResult.team
              );
              
              // Find corresponding heat result with lap timings
              const heatResult = heatResultsMap.get(swimmerKey);
              
              console.log(`[DEBUG] Merging RIEPILOGO data for ${swimmerKey}: found heat result = ${!!heatResult}`);
              
              // Create team key
              const teamKey = CrawlUtil.createTeamKey(rankingResult.team);
              
              // Add to lookup tables if not already present
              if (!allResults.swimmers[swimmerKey]) {
                allResults.swimmers[swimmerKey] = {
                  lastName: rankingResult.lastName,
                  firstName: rankingResult.firstName,
                  gender: eventInfo.eventGender,
                  year: rankingResult.year,
                  team: teamKey // Reference to team by key
                };
              }
              
              if (!allResults.teams[teamKey]) {
                allResults.teams[teamKey] = {
                  name: rankingResult.team
                };
              }
              
              // Create merged result combining RIEPILOGO data with heat lap timings
              const mergedResult = {
                ranking: rankingResult.ranking, // From RIEPILOGO
                swimmer: swimmerKey, // Reference to swimmer by unique key
                team: teamKey, // Reference to team by key
                timing: rankingResult.timing, // From RIEPILOGO
                category: rankingResult.category // From RIEPILOGO (normalized like "M85")
              };
              
              // Add heat-specific data if available
              if (heatResult) {
                mergedResult.heat_position = heatResult.heat_position;
                mergedResult.lane = heatResult.lane;
                mergedResult.nation = heatResult.nation;
                mergedResult.laps = heatResult.laps || [];
              }
              
              mergedResults.push(mergedResult);
            });
            
            // Create event object with merged results
            console.log(`[DEBUG] eventInfo before spreading:`, JSON.stringify(eventInfo, null, 2));
            
            // Ensure we don't overwrite parsed values with empty ones
            const eventResults = {
              // Apply parsed event info first
              eventCode: eventInfo.eventCode || '',
              eventGender: eventInfo.eventGender || 'N/A',
              eventLength: eventInfo.eventLength || '',
              eventStroke: eventInfo.eventStroke || '',
              eventDescription: eventInfo.eventDescription || '',
              relay: eventInfo.relay || false,
              // Add results array
              results: mergedResults
            };
            
            console.log(`[DEBUG] eventResults after explicit assignment:`, JSON.stringify({
              eventCode: eventResults.eventCode,
              eventGender: eventResults.eventGender,
              eventLength: eventResults.eventLength,
              eventStroke: eventResults.eventStroke,
              eventDescription: eventResults.eventDescription,
              relay: eventResults.relay
            }, null, 2));
            
            // Only add eventDate if we can extract it from table content
            // Otherwise, fall back to the root header dates
            const parsedEventDate = event.date ? CrawlUtil.parseEventDate(event.date, meetingHeader.dates) : null;
            if (parsedEventDate) {
              eventResults.eventDate = parsedEventDate;
            }
            // Remove any null eventDate that might have been set by eventInfo spread
            if (eventResults.eventDate === null) {
              delete eventResults.eventDate;
            }
            // Note: If no eventDate is set, consumers should use the root-level "dates" field
            
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

        const outputPath = path.join(__dirname, `../data/results.new/${this.seasonId}/results_s${this.seasonId}_l${this.layoutType}.json`);
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

  /**
   * Waits specifically for RIEPILOGO content to load with age category headers.
   * @param {object} page - The Puppeteer page object.
   * @returns {Promise<string>} - A promise that resolves with the HTML of the RIEPILOGO table.
   */
  async waitForRiepilogoToLoad(page) {
    console.log(`      - [waitForRiepilogoToLoad] Waiting for RIEPILOGO content with age categories...`);
    const selector = 'table.tblContenutiRESSTL#tblContenuti';
    await page.waitForSelector(selector, { timeout: 30000 });

    const startTime = Date.now();
    while (Date.now() - startTime < 30000) {
      try {
        const hasAgeCategoryData = await page.evaluate((sel) => {
          const table = document.querySelector(sel);
          if (!table) return false;
          
          // Look for category headers that contain "MASTER" followed by age numbers
          const categoryHeaders = table.querySelectorAll('tr.trTitolo');
          for (let header of categoryHeaders) {
            const headerText = header.textContent.trim();
            // Check if this is an age category header (e.g., "MASTER 85F", "MASTER 70M")
            if (headerText.match(/MASTER\\s+\\d+[FM]?/i)) {
              console.log(`[DEBUG] Found age category header: "${headerText}"`);
              return true;
            }
            // Reject heat series headers (e.g., "Serie 1 - 9:00")
            if (headerText.match(/Serie\\s+\\d+/i)) {
              console.log(`[DEBUG] Still showing heat series header: "${headerText}" - waiting for RIEPILOGO...`);
              return false;
            }
          }
          return false;
        }, selector);
        
        if (hasAgeCategoryData) {
          console.log(`      - [waitForRiepilogoToLoad] RIEPILOGO loaded with age category data.`);
          return await page.evaluate((sel) => document.querySelector(sel).outerHTML, selector);
        } else {
          console.log(`      - [waitForRiepilogoToLoad] Polling... waiting for age categories to replace heat series...`);
        }
      } catch (e) {
        console.log(`      - [waitForRiepilogoToLoad] Polling error: ${e.message}`);
      }
      await new Promise(resolve => setTimeout(resolve, 500)); // Poll every 500ms
    }
    
    // If we timeout, still return the content but log a warning
    console.log(`      - [waitForRiepilogoToLoad] Timeout waiting for age categories, returning current content...`);
    return await page.evaluate((sel) => {
      const table = document.querySelector(sel);
      return table ? table.outerHTML : null;
    }, selector);
  }

  async waitForTableToLoad(page, stage) {
    console.log(`      - [waitForTableToLoad] Waiting for ${stage} content to render...`);
    const selector = 'table.tblContenutiRESSTL_Sotto_Heats';
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

        // Check if we have actual result rows with data, not just headers
        if (rowCount > 1) {
          const hasResultData = await page.evaluate((sel) => {
            const table = document.querySelector(sel);
            if (!table) return false;
            const tbody = table.querySelector('tbody');
            if (!tbody) return false;
            
            // Look for rows with actual swimmer data (trContenuti or trContenutiToggle classes)
            const resultRows = tbody.querySelectorAll('tr.trContenuti, tr.trContenutiToggle');
            if (resultRows.length === 0) return false;
            
            // Check if at least one row has swimmer name data
            for (let row of resultRows) {
              const nameCell = row.querySelector('td:nth-child(5)');
              if (nameCell && nameCell.textContent.trim().length > 5) {
                return true; // Found a row with actual swimmer data
              }
            }
            return false;
          }, selector);
          
          if (hasResultData) {
            console.log(`      - [waitForTableToLoad] ${stage} table loaded with ${rowCount} rows and actual result data.`);
            return await page.evaluate((sel) => document.querySelector(sel).outerHTML, selector);
          } else {
            console.log(`      - [waitForTableToLoad] Polling... table found with ${rowCount} rows but no result data yet.`);
          }
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
    console.log(`[DEBUG] processHeatResults: HTML length = ${html.length}`);
    console.log(`[DEBUG] processHeatResults: Found ${$('table.tblContenutiRESSTL_Sotto_Heats').length} tables with class tblContenutiRESSTL_Sotto_Heats`);
    console.log(`[DEBUG] processHeatResults: Found ${$('table.tblContenutiRESSTL_Sotto_Heats tr').length} rows in total`);
    $('table.tblContenutiRESSTL_Sotto_Heats tr').each((i, row) => {
      const header = $(row).find('td.headerContenuti');
      if (header.length > 0) {
        heats.push({ number: header.text().trim().replace('Serie', '').trim(), results: [] });
      } else if (heats.length > 0 && ($(row).hasClass('trContenutiToggle') || $(row).hasClass('trContenuti'))) {
        const cols = $(row).find('td');
        if (cols.length > 8) {
          // Debug: show content of each column to identify timing column
          console.log(`[DEBUG] Row with ${cols.length} columns:`);
          for (let i = 0; i < Math.min(cols.length, 15); i++) {
            const colText = $(cols[i]).text().trim();
            const colClass = $(cols[i]).attr('class') || '';
            console.log(`  Col ${i}: "${colText}" (class: "${colClass}")`);
          }
          
          // Extract nation from column 3
          const nationHtml = $(cols[3]).html();
          const nation = nationHtml ? $('<div>').html(nationHtml).text().replace(/.*<b>([^<]+)<\/b>.*/, '$1').trim() : 'N/A';
          
          // Find timing column by specifically looking for "Risultato" class
          let timing = '';
          const timingCell = $(row).find('td.Risultato');
          if (timingCell.length > 0) {
            timing = timingCell.text().trim();
            console.log(`[DEBUG] Found timing with Risultato class: "${timing}"`);
          } else {
            console.log(`[DEBUG] No td.Risultato found in row`);
          }
          
          // Extract name data (but don't fail if missing)
          const nameDataHtml = $(cols[4]).html();
          let nameParts = ['', ''];
          let year = 'N/A';
          let team = 'N/A';
          
          if (nameDataHtml) {
            const nameData = nameDataHtml.split('<br>');
            const fullNameHtml = $('<div>').html(nameData[0]).text();
            const nameParts = CrawlUtil.extractNameParts(fullNameHtml);
            year = nameData[1] ? $('<div>').html(nameData[1]).text().replace(/[()]/g, '').trim() : 'N/A';
            team = nameData[2] ? $('<div>').html(nameData[2]).text().trim() : 'N/A';
          }
          
          // Extract correct data based on actual HTML structure:
          // Col 0: heat position (inside <b>), Col 1: lane, Col 3: nation, Col 4: name/year/team
          // Col 7: 50m split, Col 9: final timing (class="Risultato")
          const result = {
            heat_position: $(cols[0]).find('b').text().trim() || $(cols[0]).text().trim(),
            lane: $(cols[1]).text().trim(),
            nation: nation,
            lastName: nameParts.lastName || '',
            firstName: nameParts.firstName || '',
            year: year,
            team: team,
            timing: timing,
            heat: heats.length > 0 ? heats[heats.length - 1].number : 'N/A', // Heat number, not category
            laps: timing ? [{ distance: '50m', timing: $(cols[7]).text().trim() }] : [] // Add 50m split if available
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
    console.log(`[DEBUG] processRankingResults: HTML length = ${html.length}`);
    console.log(`[DEBUG] processRankingResults: Found ${$('table.tblContenutiRESSTL#tblContenuti').length} tables with RIEPILOGO structure`);
    console.log(`[DEBUG] processRankingResults: Found ${$('table.tblContenutiRESSTL#tblContenuti tr').length} rows in total`);

    // Process RIEPILOGO table structure: table.tblContenutiRESSTL#tblContenuti
    $('table.tblContenutiRESSTL#tblContenuti tr').each((i, row) => {
      const header = $(row).find('td.headerContenuti');
      if (header.length > 0) {
        const rawCategory = CrawlUtil.normalizeUnicodeText(header.text());
        // Normalize category from "MASTER 85F" to "M85" format
        // Examples: "MASTER 85F" -> "M85", "MASTER 70F" -> "M70", "MASTER 80M" -> "M80"
        console.log(`[DEBUG] Raw category before normalization: "${header.text()}"`);        
        console.log(`[DEBUG] Normalized category: "${rawCategory}"`);        
        const categoryMatch = rawCategory.match(/MASTER\s+(\d+)[FM]?/i);
        if (categoryMatch) {
          currentCategory = `M${categoryMatch[1]}`;
        } else {
          currentCategory = rawCategory; // Fallback to original if pattern doesn't match
        }
        console.log(`[DEBUG] Category header found: "${rawCategory}" -> normalized to: "${currentCategory}"`);
      } else if ($(row).hasClass('trContenutiToggle') || $(row).hasClass('trContenuti')) {
        const cols = $(row).find('td');
        if (cols.length >= 10) {
          // RIEPILOGO structure based on sample HTML:
          // Col 1: Ranking position (inside <b>)
          // Col 6: Swimmer name (inside <nobr><b>)
          // Col 7: Team name (inside <nobr>)
          // Col 8: Year of birth
          // Col 9: Timing (class="Risultato")
          
          const ranking = $(cols[1]).find('b').text().trim();
          const timing = $(cols[9]).hasClass('Risultato') ? $(cols[9]).text().trim() : '';
          
          // Extract swimmer name from column 6 using enhanced name extraction
          const nameHtml = $(cols[6]).find('nobr b').text();
          const nameParts = CrawlUtil.extractNameParts(nameHtml);
          const lastName = nameParts.lastName || '';
          const firstName = nameParts.firstName || '';
          
          // Extract team from column 7
          const teamHtml = $(cols[7]).find('nobr').text();
          const team = CrawlUtil.normalizeUnicodeText(teamHtml);
          
          // Extract year from column 8
          const year = $(cols[8]).text().trim();
          
          console.log(`[DEBUG] RIEPILOGO extracted: ${lastName} ${firstName} (${year}) - ${team} - Rank: ${ranking} - Category: ${currentCategory}`);
          
          const result = {
            ranking: ranking,
            lastName: lastName,
            firstName: firstName,
            team: team,
            year: year,
            timing: timing,
            category: currentCategory // Normalized category like "M85", "M70", etc.
          };
          results.push(result);
        }
      }
    });
    console.log(`[DEBUG] processRankingResults extracted ${results.length} results from RIEPILOGO`);
    return { results };
  }
}

module.exports = MicroplusCrawler;
