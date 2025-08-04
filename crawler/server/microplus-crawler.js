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
        
        console.log(`[DEBUG] About to process ${events.length} events:`);
        events.forEach((event, index) => {
          console.log(`[DEBUG] Event ${index + 1}: "${event.description}" (gender: ${event.gender})`);
        });

        for (const event of events) {
          try {
            console.log(`   Processing event: ${event.description} (gender: ${event.gender})`);
            console.log(`      - Event onclick: ${event.onclick}`);
            console.log('      - Stage 1: Executing onclick and waiting for AJAX response...');
            const onclickParams = event.onclick.match(/\((.*)\)/)[1];
            console.log(`      - Onclick parameters: ${onclickParams}`);
            const [response] = await Promise.all([
              page.waitForResponse(response => response.url().includes('.JSON') && response.status() === 200),
              page.evaluate((params) => {
                eval(`LoadAndManageHistory(${params})`);
              }, onclickParams)
            ]);
            const responseUrl = response.url();
            console.log(`      - Stage 1: AJAX response received from: ${responseUrl}`);
            
            // Debug: Check if the page content changed after AJAX
            const pageTitle = await page.title();
            console.log(`      - Page title after AJAX: ${pageTitle}`);

            const heatResultsHtml = await this.waitForTableToLoad(page, 'Heats');
            console.log(`[DEBUG] heatResultsHtml length: ${heatResultsHtml ? heatResultsHtml.length : 'NULL'}`);
            console.log(`[DEBUG] Calling processHeatResults...`);
            const heatData = this.processHeatResults(heatResultsHtml);
            // DEBUG (extremely verbose!)
            // console.log(`[DEBUG] processHeatResults returned:`, JSON.stringify(heatData, null, 2));
            console.log(`      - Done parsing heats: ${heatData.length} row(s).`);

            console.log('      - Stage 3: Clicking RIEPILOGO tab and waiting for AJAX...');
            
            // Debug: Check what codSummary variable is available
            const codSummaryValue = await page.evaluate(() => {
              return typeof codSummary !== 'undefined' ? codSummary : 'undefined';
            });
            console.log(`      - codSummary value: ${codSummaryValue}`);
            
            await page.evaluate(() => {
              // This is the actual onclick function for the summary tab
              CheckJsonForLoadOnMain(codSummary, true, true);
            });

            const riepilogoResponse = await page.waitForResponse(response => response.url().includes('.JSON') && response.status() === 200, { timeout: 30000 });
            const riepilogoResponseUrl = riepilogoResponse.url();
            console.log(`      - Stage 4: Rankings AJAX response received from: ${riepilogoResponseUrl}`);
            console.log('      - Stage 4: Rankings data loaded.');

            const rankingResultsHtml = await this.waitForRiepilogoToLoad(page);
            console.log(`[DEBUG] rankingResultsHtml length: ${rankingResultsHtml ? rankingResultsHtml.length : 'NULL'}`);
            
            let rankingData = { results: [] }; // Default to empty results
            
            if (rankingResultsHtml && rankingResultsHtml.trim().length > 0) {
              console.log(`[DEBUG] Calling processRankingResults...`);
              rankingData = this.processRankingResults(rankingResultsHtml);
              console.log(`[DEBUG] processRankingResults returned:`, JSON.stringify({
                hasResults: !!rankingData.results,
                resultsLength: rankingData.results ? rankingData.results.length : 'undefined',
                resultsType: typeof rankingData.results,
                firstResult: rankingData.results && rankingData.results.length > 0 ? rankingData.results[0] : 'none'
              }, null, 2));
              console.log(`      - Done parsing rankings: ${rankingData.results.length} result(s).`);
            } else {
              console.log(`[DEBUG] RIEPILOGO data is null/empty, continuing with heat data only...`);
              console.log(`      - Done parsing rankings: 0 result(s) (RIEPILOGO failed to load).`);
            }

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
            console.log(`[DEBUG] Building heat results map...`);
            for (const heat of heatData.heats) {
              for (const heatResult of heat.results) {
                const swimmerKey = CrawlUtil.createSwimmerKey(
                  eventInfo.eventGender,
                  heatResult.lastName,
                  heatResult.firstName, 
                  heatResult.year,
                  heatResult.team
                );
                // DEBUG (verbose)
                // console.log(`[DEBUG] Heat result key: ${swimmerKey} (${heatResult.lastName}|${heatResult.firstName}|${heatResult.year}|${heatResult.team})`);
                heatResultsMap.set(swimmerKey, heatResult);
              }
            }
            console.log(`[DEBUG] Heat results map size: ${heatResultsMap.size}`);
            console.log(`[DEBUG] Heat results keys (first 5):`, Array.from(heatResultsMap.keys()).slice(0, 5)); // Show just first 5 keys

            // Process each RIEPILOGO result and merge with heat data
            console.log(`[DEBUG] Processing ${rankingData.results.length} RIEPILOGO results...`);
            
            if (rankingData.results.length === 0) {
              // No RIEPILOGO data available, create results from heat data only
              console.log(`[DEBUG] No RIEPILOGO data available, creating results from heat data only...`);
              for (const heat of heatData.heats) {
                for (const heatResult of heat.results) {
                  const swimmerKey = CrawlUtil.createSwimmerKey(
                    eventInfo.eventGender,
                    heatResult.lastName,
                    heatResult.firstName, 
                    heatResult.year,
                    heatResult.team
                  );
                  
                  const teamKey = CrawlUtil.createTeamKey(heatResult.team);
                  
                  // Add to lookup tables
                  if (!allResults.swimmers[swimmerKey]) {
                    allResults.swimmers[swimmerKey] = {
                      lastName: heatResult.lastName,
                      firstName: heatResult.firstName,
                      gender: eventInfo.eventGender,
                      year: heatResult.year,
                      team: teamKey
                    };
                  }
                  
                  if (!allResults.teams[teamKey]) {
                    allResults.teams[teamKey] = {
                      name: heatResult.team
                    };
                  }
                  
                  // Create result with heat data only (no ranking info)
                  const heatOnlyResult = {
                    swimmer: swimmerKey,
                    team: teamKey,
                    timing: heatResult.timing,
                    heat_position: heatResult.heat_position,
                    lane: heatResult.lane,
                    nation: heatResult.nation,
                    laps: heatResult.laps || []
                  };
                  
                  mergedResults.push(heatOnlyResult);
                }
              }
            } else {
              // Process RIEPILOGO results and merge with heat data
              rankingData.results.forEach((rankingResult, index) => {
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
              
              if (index < 3) { // Show details for first 3 results
                console.log(`[DEBUG] RIEPILOGO result ${index + 1}: ${rankingResult.lastName}|${rankingResult.firstName}|${rankingResult.year}|${rankingResult.team}`);
                console.log(`[DEBUG] Generated key: ${swimmerKey}`);
                console.log(`[DEBUG] Found in heat results: ${!!heatResult}`);
                if (!heatResult) {
                  // Show similar keys to help debug
                  const similarKeys = Array.from(heatResultsMap.keys()).filter(key => 
                    key.includes(rankingResult.lastName) || key.includes(rankingResult.firstName)
                  );
                  console.log(`[DEBUG] Similar heat keys found:`, similarKeys.slice(0, 3));
                }
              }
              // DEBUG (verbose)
              // console.log(`[DEBUG] Merging RIEPILOGO data for ${swimmerKey}: found heat result = ${!!heatResult}`);
              
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
            }

            // Debug: Check what's in mergedResults
            console.log(`[DEBUG] mergedResults array length: ${mergedResults.length}`);
            if (mergedResults.length > 0) {
              console.log(`[DEBUG] First merged result:`, JSON.stringify(mergedResults[0], null, 2));
              console.log(`[DEBUG] Has ranking field: ${!!mergedResults[0].ranking}`);
              console.log(`[DEBUG] Has category field: ${!!mergedResults[0].category}`);
            }

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
            
            console.log(`[DEBUG] Adding event to allResults.events: ${eventResults.eventCode}-${eventResults.eventGender}`);
            console.log(`[DEBUG] Events array size before push: ${allResults.events.length}`);
            allResults.events.push(eventResults);
            console.log(`[DEBUG] Events array size after push: ${allResults.events.length}`);
            console.log(`[DEBUG] Current events in array:`, allResults.events.map(e => `${e.eventCode}-${e.eventGender}`));
          } catch (e) {
            console.error(`Failed to process event '${event.description}': ${e.message}`);
            const errorTimestamp = new Date().toISOString().replace(/:/g, '-');
            const screenshotPath = path.join(__dirname, `../data/debug/error_screenshot_${errorTimestamp}.png`);
            const htmlPath = path.join(__dirname, `../data/debug/error_page_${errorTimestamp}.html`);

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

        // Generate enhanced filename format: <meeting_date>-<meeting_name>-l<layoutType>
        const meetingDate = CrawlUtil.parseFirstMeetingDate(meetingHeader.dates);
        const sanitizedMeetingName = CrawlUtil.sanitizeForFilename(meetingHeader.meetingName);
        
        let filename, eventInfo;
        if (this.targetEventTitle) {
          eventInfo = CrawlUtil.parseEventInfoFromDescription(this.targetEventTitle, 'FEM'); // Gender ignored
        }
        // DEBUG
        console.log(`[DEBUG] meetingHeader.dates: "${meetingHeader.dates}"`);
        console.log(`[DEBUG] meetingHeader.meetingName: "${meetingHeader.meetingName}"`);
        console.log(`[DEBUG] Meeting date: "${meetingDate}"`);
        console.log(`[DEBUG] Meeting name: "${sanitizedMeetingName}"`);
        console.log(`[DEBUG] Event info:`, JSON.stringify(eventInfo, null, 2));
        console.log(`[DEBUG] Condition (meetingDate && sanitizedMeetingName): ${!!(meetingDate && sanitizedMeetingName)}`);

        if (meetingDate && sanitizedMeetingName) {
          filename = eventInfo.eventCode ? `${meetingDate}-${sanitizedMeetingName}-${eventInfo.eventCode}-l${this.layoutType}.json` :
                                           `${meetingDate}-${sanitizedMeetingName}-l${this.layoutType}.json`;
        } else {
          // Fallback to original format if date and place parsing fails
          filename = eventInfo.eventCode ? `results-${eventInfo.eventCode}-l${this.layoutType}.json` :
                                           `results-l${this.layoutType}.json`;
        }
        
        const outputPath = path.join(__dirname, `../data/results.new/${this.seasonId}/${filename}`);
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
        if (!table) {
          console.log(`[DEBUG] Table not found with selector: ${sel}`);
          return false;
        }
        
        // Debug: Show all available tr elements and their classes
        const allRows = table.querySelectorAll('tr');
        console.log(`[DEBUG] Table has ${allRows.length} total rows`);
        
        // Look for any row containing MASTER category headers (regardless of CSS class)
        // The category headers actually use empty class="" instead of trTitolo
        const allMasterHeaders = Array.from(allRows).filter(row => {
          const text = row.textContent.trim();
          return text.match(/MASTER\s+\d+[FM]?/i);
        });
        
        console.log(`[DEBUG] Found ${allMasterHeaders.length} rows with MASTER age categories`);
        
        // Debug: Show first few row contents regardless of class
        for (let i = 0; i < Math.min(5, allRows.length); i++) {
          const row = allRows[i];
          const rowText = row.textContent.trim();
          const rowClass = row.className;
          console.log(`[DEBUG] Row ${i + 1}: class="${rowClass}" text="${rowText.substring(0, 100)}..."`);
        }
        
        // Check if we have MASTER age category headers (RIEPILOGO loaded)
        if (allMasterHeaders.length > 0) {
          console.log(`[DEBUG] Found RIEPILOGO with ${allMasterHeaders.length} age categories:`);
          allMasterHeaders.forEach((row, i) => {
            const headerText = row.textContent.trim();
            console.log(`[DEBUG] Age category ${i + 1}: "${headerText}"`);
          });
          return true;
        }
        
        // Check if we still have heat series headers (RIEPILOGO not loaded yet)
        const heatSeriesHeaders = Array.from(allRows).filter(row => {
          const text = row.textContent.trim();
          return text.match(/Serie\s+\d+/i);
        });
        
        if (heatSeriesHeaders.length > 0) {
          console.log(`[DEBUG] Still showing ${heatSeriesHeaders.length} heat series headers - waiting for RIEPILOGO...`);
          return false;
        }
        
        console.log(`[DEBUG] No MASTER categories or heat series found - content may be loading...`);
        return false;
        
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
    
    // Debug: Check what tables are available on the page
    const availableTables = await page.evaluate(() => {
      const tables = document.querySelectorAll('table');
      return Array.from(tables).map(table => ({
        className: table.className,
        id: table.id,
        rowCount: table.rows ? table.rows.length : 0
      }));
    });
    console.log(`      - [waitForTableToLoad] Available tables:`, JSON.stringify(availableTables, null, 2));
    
    await page.waitForSelector(selector, { timeout: 30000 });

    let rowCount = 0;
    const startTime = Date.now();
    while (Date.now() - startTime < 10000) { // (It usually doesn't take more than a couple of seconds)
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
    
    // Extract title from the second td element which contains the descriptive title
    const titleCell = headerRow.find('td').eq(1); // Second td element (0-indexed)
    const titleHtml = titleCell.html();
    
    let competitionType = '';
    let meetingName = '';
    let meetingPlace = '';
    let meetingDates = '';
    
    if (titleHtml) {
      // Split by <br> tags to get the three lines
      const lines = titleHtml.split(/<br\s*\/?>/i).map(line => 
        CrawlUtil.normalizeUnicodeText(line.replace(/<[^>]*>/g, '').trim())
      ).filter(line => line.length > 0);
      
      if (lines.length >= 3) {
        competitionType = lines[0]; // e.g., "Master"
        meetingName = lines[1];     // e.g., "Campionati Italiani di Nuoto Master Herbalife"
        
        // Parse the third line for place and dates
        const placeAndDates = lines[2]; // e.g., "Riccione (ITA) - 24/29 giugno 2025"
        const dashIndex = placeAndDates.lastIndexOf(' - ');
        if (dashIndex > 0) {
          meetingPlace = placeAndDates.substring(0, dashIndex).trim();
          meetingDates = placeAndDates.substring(dashIndex + 3).trim();
        } else {
          meetingPlace = placeAndDates;
        }
      }
    }
    
    // Combine meeting name and competition type for the title field
    const title = meetingName && competitionType ? `${meetingName} ${competitionType}` : (meetingName || competitionType || 'Unknown Meeting');
    
    return { 
      title, 
      dates: meetingDates, 
      place: meetingPlace,
      meetingName: meetingName,
      competitionType: competitionType
    };
  }

  processHeatResults(html) {
    const $ = cheerio.load(html);
    const heats = [];
    // DEBUG
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
          // console.log(`[DEBUG] Row with ${cols.length} columns:`);
          for (let i = 0; i < Math.min(cols.length, 15); i++) {
            const colText = $(cols[i]).text().trim();
            const colClass = $(cols[i]).attr('class') || '';
            // DEBUG (extremely verbose)
            // console.log(`  Col ${i}: "${colText}" (class: "${colClass}")`);
          }
          
          // Extract nation from column 3
          const nationHtml = $(cols[3]).html();
          const nation = nationHtml ? $('<div>').html(nationHtml).text().replace(/.*<b>([^<]+)<\/b>.*/, '$1').trim() : 'N/A';
          
          // Find timing column by specifically looking for "Risultato" class
          let timing = '';
          const timingCell = $(row).find('td.Risultato');
          if (timingCell.length > 0) {
            timing = timingCell.text().trim();
            // DEBUG (extremely verbose)
            // console.log(`[DEBUG] Found timing with Risultato class: "${timing}"`);
          } else {
            // DEBUG (extremely verbose)
            // console.log(`[DEBUG] No td.Risultato found in row`);
          }
          
          // Extract name data (but don't fail if missing)
          const nameDataHtml = $(cols[4]).html();
          let nameParts = { lastName: '', firstName: '' }; // Initialize as object, not array
          let year = 'N/A';
          let team = 'N/A';
          // DEBUG (extremely verbose)
          // console.log(`[DEBUG] Heat nameDataHtml: "${nameDataHtml}"`);
          
          if (nameDataHtml) {
            const nameData = nameDataHtml.split('<br>');
            const fullNameHtml = $('<div>').html(nameData[0]).text();
            // DEBUG (extremely verbose)
            // console.log(`[DEBUG] Heat fullNameHtml: "${fullNameHtml}"`);
            nameParts = CrawlUtil.extractNameParts(fullNameHtml); // No redeclaration
            year = nameData[1] ? $('<div>').html(nameData[1]).text().replace(/[()]/g, '').trim() : 'N/A';
            team = nameData[2] ? $('<div>').html(nameData[2]).text().trim() : 'N/A';
            // DEBUG (verbose)
            // console.log(`[DEBUG] Heat extracted: ${nameParts.lastName}|${nameParts.firstName}|${year}|${team}`);
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
          
          // DEBUG (verbose)
          // console.log(`[DEBUG] RIEPILOGO extracted: ${lastName} ${firstName} (${year}) - ${team} - Rank: ${ranking} - Category: ${currentCategory}`);
          
          const result = {
            ranking: ranking,
            lastName: lastName,
            firstName: firstName,
            team: team,
            year: year,
            timing: timing,
            category: currentCategory // Normalized category like "M85", "M70", etc.
          };
        
        // Debug: Log what we're adding to results
        if (results.length < 3) {
          console.log(`[DEBUG] Adding RIEPILOGO result ${results.length + 1}:`, JSON.stringify(result, null, 2));
        }
        
        results.push(result);
        }
      }
    });
    console.log(`[DEBUG] processRankingResults extracted ${results.length} results from RIEPILOGO`);
    return { results };
  }
}

module.exports = MicroplusCrawler;
