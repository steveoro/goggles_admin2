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
          args: [
            '--no-sandbox',
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--lang=it-IT,it',
            '--window-size=1366,900'
          ]
        });
        const page = await browser.newPage();
        page.on('console', msg => console.log('BROWSER LOG:', msg.text()));
        // Timeouts and viewport
        page.setDefaultNavigationTimeout(45000);
        page.setDefaultTimeout(30000);
        await page.setViewport({ width: 1366, height: 900, deviceScaleFactor: 1 });
        // Realistic browser fingerprint
        const userAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';
        await page.setUserAgent(userAgent);
        await page.setExtraHTTPHeaders({
          'Accept-Language': 'it-IT,it;q=0.9,en-US;q=0.8,en;q=0.7',
          'Upgrade-Insecure-Requests': '1'
        });
        await page.emulateTimezone('Europe/Rome');
        await page.setJavaScriptEnabled(true);
        await page.setCacheEnabled(false);
        // Spoof some navigator properties before any script runs
        await page.evaluateOnNewDocument(() => {
          Object.defineProperty(navigator, 'webdriver', { get: () => false });
          Object.defineProperty(navigator, 'languages', { get: () => ['it-IT', 'it', 'en-US', 'en'] });
          Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64' });
          const getPlugins = () => [1, 2, 3, 4, 5];
          Object.defineProperty(navigator, 'plugins', { get: getPlugins });
        });

        // Start crawl
        console.log(`  Navigating to ${this.meetingUrl}...`);
        await page.goto(this.meetingUrl, { waitUntil: 'networkidle2' });

        // Handle possible cookie/consent overlays
        try {
          await page.evaluate(() => {
            const buttons = Array.from(document.querySelectorAll('button, a'));
            const matchText = (el, texts) => texts.some(t => (el.textContent || el.innerText || '').toLowerCase().includes(t));
            const candidates = buttons.filter(b => matchText(b, ['accetta', 'accept', 'consenti', 'consent', 'ok']));
            candidates.slice(0, 2).forEach(b => { try { b.click(); } catch(_) {} });
          });
        } catch (_) {}

        const meetingHeader = await this.processMeetingHeader(await page.content());
        
        // Parse place and dates from URL
        const urlInfo = CrawlUtil.parsePlaceAndDatesFromUrl(this.meetingUrl);
        if (urlInfo.place) meetingHeader.place = urlInfo.place;
        if (urlInfo.dates) meetingHeader.dates = urlInfo.dates;
        
        console.log(`  Meeting: ${meetingHeader.title} (${meetingHeader.dates}) at ${meetingHeader.place}`);

        console.log(`      Selecting PER EVENTO via LoadHistory_Calendar('1')...`);
        // Wait for helpers (or fallback link) to be ready
        try {
          await page.waitForFunction(() => {
            const hasHelper = typeof window.LoadHistory_Calendar === 'function';
            const hasLink = !!document.querySelector('a#divByEvent');
            return hasHelper || hasLink;
          }, { timeout: 8000 });
        } catch(_) {}
        await page.evaluate(() => {
          try {
            if (typeof AddItemToHistory === 'function') {
              AddItemToHistory("LoadHistory_Calendar('1');");
            }
            if (typeof LoadHistory_Calendar === 'function') {
              LoadHistory_Calendar('1');
            } else {
              const link = document.querySelector('a#divByEvent');
              if (link) link.click();
            }
          } catch (e) {
            console.log('[DEBUG] Error invoking PER EVENTO helpers:', e && e.message);
            const link = document.querySelector('a#divByEvent');
            if (link) link.click();
          }
        });
        try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 5000 }); } catch(_) {}
        await page.waitForSelector('#tblMainSxScroll', { timeout: 30000 });
        // Verify we're on PER EVENTO (and not PER GIORNO)
        try {
          const mode = await page.evaluate(() => ({
            byEvent: !!document.querySelector('td#tdTitleCalendarByEvent'),
            byDay: !!document.querySelector('td#tdTitleCalendarByDay')
          }));
          if (!mode.byEvent) {
            console.log(`      - Detected non-PER EVENTO mode (byDay=${mode.byDay}). Forcing PER EVENTO...`);
            await page.evaluate(() => {
              try {
                if (typeof AddItemToHistory === 'function') {
                  AddItemToHistory("LoadHistory_Calendar('1');");
                }
                if (typeof LoadHistory_Calendar === 'function') {
                  LoadHistory_Calendar('1');
                } else {
                  const link = document.querySelector('a#divByEvent');
                  if (link) link.click();
                }
              } catch (_) {}
            });
            try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 5000 }); } catch(_) {}
            await page.waitForSelector('#tblMainSxScroll', { timeout: 30000 });
          }
          const finalMode = await page.evaluate(() => ({
            byEvent: !!document.querySelector('td#tdTitleCalendarByEvent'),
            byDay: !!document.querySelector('td#tdTitleCalendarByDay')
          }));
          console.log(`      - Page mode: PER EVENTO=${finalMode.byEvent} PER GIORNO=${finalMode.byDay}`);
        } catch (modeErr) {
          console.log(`      - Warning: could not assert page mode: ${modeErr.message}`);
        }

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

            console.log('      - Stage 3: Switching to RIEPILOGO tab...');
            
            // Debug: Check what codSummary variable is available
            const codSummaryValue = await page.evaluate(() => {
              return typeof codSummary !== 'undefined' ? codSummary : 'undefined';
            });
            console.log(`      - codSummary value: ${codSummaryValue}`);
            
            // Ensure helper function exists or fallback is available
            try {
              await page.waitForFunction(() => {
                const hasHelper = typeof window.CheckJsonForLoadOnMain === 'function';
                const hasTab = !!document.querySelector('#divSummary');
                return hasHelper || hasTab;
              }, { timeout: 8000 });
            } catch(_) {}
            await page.evaluate(() => {
              try {
                if (typeof AddItemToHistory === 'function') {
                  AddItemToHistory('CheckJsonForLoadOnMain(codSummary, true, true);');
                }
                if (typeof CheckJsonForLoadOnMain === 'function') {
                  CheckJsonForLoadOnMain(codSummary, true, true);
                } else {
                  const tab = document.querySelector('#divSummary');
                  if (tab) tab.click();
                }
              } catch (e) {
                console.log('[DEBUG] Error invoking RIEPILOGO helpers:', e && e.message);
                const tab = document.querySelector('#divSummary');
                if (tab) tab.click();
              }
            });
            console.log('      - Stage 4: Waiting for RIEPILOGO DOM to load...');

            let rankingResultsHtml = await this.waitForRiepilogoToLoad(page);
            // Retry once if no category headers are detected
            const hasCategory = await page.evaluate(() => {
              const tbl = document.querySelector('table.tblContenutiRESSTL#tblContenuti');
              if (!tbl) return false;
              const text = tbl.innerText || '';
              return /\bMASTER\s+\d{2,3}\s*[FM]?\b/i.test(text);
            });
            if (!hasCategory) {
              console.log('      - RIEPILOGO appears without category headers. Retrying tab switch once...');
              await page.evaluate(() => {
                try {
                  if (typeof CheckJsonForLoadOnMain === 'function') {
                    CheckJsonForLoadOnMain(codSummary, true, true);
                  }
                } catch(_) {}
              });
              try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 4000 }); } catch(_) {}
              rankingResultsHtml = await this.waitForRiepilogoToLoad(page);
              // Extra fallback: toggle back to Heats then Summary again
              const stillNoCat = await page.evaluate(() => {
                const tbl = document.querySelector('table.tblContenutiRESSTL#tblContenuti');
                return !(tbl && /\bMASTER\s+\d{2,3}\s*[FM]?\b/i.test(tbl.innerText || ''));
              });
              if (stillNoCat) {
                console.log('      - RIEPILOGO still without categories. Toggling Heats -> Summary as fallback...');
                await page.evaluate(() => {
                  try {
                    const heatsTab = document.querySelector('#divHeats');
                    const summaryTab = document.querySelector('#divSummary');
                    if (heatsTab) heatsTab.click();
                    if (typeof CheckJsonForLoadOnMain === 'function') {
                      CheckJsonForLoadOnMain(codSummary, true, true);
                    } else if (summaryTab) {
                      setTimeout(() => summaryTab.click(), 300);
                    }
                  } catch(_) {}
                });
                try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 4000 }); } catch(_) {}
                rankingResultsHtml = await this.waitForRiepilogoToLoad(page);
              }
            }
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

            // Fallback gender detection from #tdGaraRound header if eventGender is empty
            if (!eventInfo.eventGender) {
              console.log(`[DEBUG] eventGender is empty, trying fallback from #tdGaraRound header...`);
              const headerGender = await page.evaluate(() => {
                const genderCell = document.querySelector('#tdGaraRound');
                return genderCell ? genderCell.innerText.trim() : '';
              });
              if (headerGender) {
                const fallbackGender = CrawlUtil.extractGenderFromEventHeader(headerGender);
                if (fallbackGender) {
                  // For relays, allow 'X'; for individual events, only 'M' or 'F'
                  if (eventInfo.relay || fallbackGender !== 'X') {
                    eventInfo.eventGender = fallbackGender;
                    console.log(`[DEBUG] Fallback gender from header: "${fallbackGender}"`);
                  } else {
                    console.log(`[DEBUG] Ignoring 'X' gender for non-relay event`);
                  }
                }
              }
            }

            // Second fallback: extract gender from category headers in RIEPILOGO (e.g., "MASTER 80F")
            // SKIP this fallback for mixed individual events - gender must be detected per-swimmer
            if (!eventInfo.eventGender && rankingData.detectedGenderFromCategory && !eventInfo.isMixedIndividual) {
              const catGender = rankingData.detectedGenderFromCategory;
              // For relays, allow 'X'; for individual events, only 'M' or 'F'
              if (eventInfo.relay || catGender !== 'X') {
                eventInfo.eventGender = catGender;
                console.log(`[DEBUG] Fallback gender from category header: "${catGender}"`);
              }
            } else if (eventInfo.isMixedIndividual) {
              console.log(`[DEBUG] Skipping event-level gender fallback for mixed individual event - gender will be per-swimmer`);
            }

            // Force debug output to file to capture what's happening
            const fs = require('fs');
            const debugInfo = {
              timestamp: new Date().toISOString(),
              eventDescription: event.description,
              eventGender: event.gender,
              parsedEventInfo: eventInfo
            };
            fs.appendFileSync('/tmp/crawler_debug_detailed.log', JSON.stringify(debugInfo, null, 2) + '\n\n');

            // For relay events, ensure RIEPILOGO items are treated as relay summaries (team rows)
            const isRelayEvent = !!(eventInfo && (String(eventInfo.eventLength || '').includes('4x') || eventInfo.relay === true));
            if (isRelayEvent && rankingData && Array.isArray(rankingData.results)) {
              rankingData.results = rankingData.results.map(r => ({
                ...r,
                relay: true,
                relay_name: r.relay_name || r.team,
                // Keep any existing values for heat/lane if present; most RIEPILOGO rows won't have them
                heat: r.heat || null,
                lane: r.lane || null
              }));
            }

            // Create merged results array combining ranking and heat data
            const mergedResults = [];
            
            // First, collect all heat results (individual or relay)
            const heatResultsMap = new Map();
            console.log(`[DEBUG] Building heat results map...`);
            for (const heat of heatData.heats) {
              for (const heatResult of heat.results) {
                if (heatResult.relay) {
                  const relayKey = CrawlUtil.createRelayKey(heatResult.relay_name, heatResult.team, heatResult.heat, heatResult.lane, heatResult.timing);
                  heatResultsMap.set(relayKey, heatResult);
                } else {
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
                  if (heatResult.relay) {
                    const teamKey = CrawlUtil.createTeamKey(heatResult.team);
                    if (!allResults.teams[teamKey]) {
                      allResults.teams[teamKey] = { name: heatResult.team };
                    }
                    // Build relay swimmer keys using event gender and add to global swimmers
                    const swimmerKeys = [];
                    if (Array.isArray(heatResult.swimmers)) {
                      heatResult.swimmers.forEach((s) => {
                        const sTeamName = s.team || heatResult.team;
                        const sTeam = CrawlUtil.createTeamKey(sTeamName);
                        if (!allResults.teams[sTeam]) allResults.teams[sTeam] = { name: sTeamName };

                        let key;
                        if (eventInfo.eventGender === 'X') {
                          const maleKey = CrawlUtil.createSwimmerKey('M', s.lastName, s.firstName, s.year, sTeamName);
                          const femaleKey = CrawlUtil.createSwimmerKey('F', s.lastName, s.firstName, s.year, sTeamName);
                          const noGenKey = CrawlUtil.createSwimmerKeyNoGender(s.lastName, s.firstName, s.year, sTeamName);
                          // Reuse existing swimmer if found, preferring gendered entries
                          if (allResults.swimmers[maleKey]) key = maleKey;
                          else if (allResults.swimmers[femaleKey]) key = femaleKey;
                          else key = noGenKey;

                          if (!allResults.swimmers[key]) {
                            allResults.swimmers[key] = {
                              lastName: s.lastName,
                              firstName: s.firstName,
                              gender: null,
                              year: s.year,
                              team: sTeam
                            };
                          }
                        } else {
                          key = CrawlUtil.createSwimmerKey(
                            eventInfo.eventGender,
                            s.lastName,
                            s.firstName,
                            s.year,
                            sTeamName
                          );
                          if (!allResults.swimmers[key]) {
                            // Swimmer gender: only 'M' or 'F' are valid; 'X' or unknown -> null
                            const swimmerGender = (eventInfo.eventGender === 'M' || eventInfo.eventGender === 'F') ? eventInfo.eventGender : null;
                            allResults.swimmers[key] = {
                              lastName: s.lastName,
                              firstName: s.firstName,
                              gender: swimmerGender,
                              year: s.year,
                              team: sTeam
                            };
                          }
                        }
                        swimmerKeys.push(key);
                      });
                    }

                    // Map laps to swimmer keys by relay leg order
                    const lapsOut = Array.isArray(heatResult.laps)
                      ? heatResult.laps.map((lap, idx) => ({
                          ...lap,
                          swimmer: swimmerKeys[idx] || null
                        }))
                      : [];

                    mergedResults.push({
                      relay: true,
                      relay_name: heatResult.relay_name,
                      team: teamKey,
                      timing: heatResult.timing,
                      heat_position: heatResult.heat_position,
                      lane: heatResult.lane,
                      laps: lapsOut
                    });
                  } else {
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
                      // Swimmer gender: only 'M' or 'F' are valid; 'X' or unknown -> null
                      const swimmerGender = (eventInfo.eventGender === 'M' || eventInfo.eventGender === 'F') ? eventInfo.eventGender : null;
                      allResults.swimmers[swimmerKey] = {
                        lastName: heatResult.lastName,
                        firstName: heatResult.firstName,
                        gender: swimmerGender,
                        year: heatResult.year,
                        team: teamKey
                      };
                    }
                    if (!allResults.teams[teamKey]) {
                      allResults.teams[teamKey] = { name: heatResult.team };
                    }
                    mergedResults.push({
                      swimmer: swimmerKey,
                      team: teamKey,
                      timing: heatResult.timing,
                      heat_position: heatResult.heat_position,
                      lane: heatResult.lane,
                      nation: heatResult.nation,
                      laps: heatResult.laps || [],
                      gender: eventInfo.eventGender || '' // Explicit gender for Phase 5 processing
                    });
                  }
                }
              }
            } else {
              // Process RIEPILOGO results and merge with heat data
              rankingData.results.forEach((rankingResult, index) => {
              // Create unique swimmer key for RIEPILOGO result with gender prefix
              let heatResult = null;
              let teamKey = null;
              if (rankingResult.relay) {
                const relayKey = CrawlUtil.createRelayKey(rankingResult.relay_name, rankingResult.team, rankingResult.heat, rankingResult.lane, rankingResult.timing);
                heatResult = heatResultsMap.get(relayKey);
                // Fallbacks: progressively relax constraints and normalize values
                const norm = (s) => (s || '').toString().normalize('NFKC').replace(/\u00A0/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();
                const simplifyTime = (t) => norm(t).replace(/[^0-9':.]/g, ''); // keep digits and time punctuation only
                if (!heatResult) {
                  const targetBase = (rankingResult.relay_name && rankingResult.relay_name.trim().length > 0) ? rankingResult.relay_name : rankingResult.team;
                  const base = norm(targetBase);
                  const heatStr = norm(rankingResult.heat || '');
                  const timeStr = simplifyTime(rankingResult.timing || '');
                  // Pass 1: match by team/relay_name + heat (if any) + simplified timing
                  heatResult = Array.from(heatResultsMap.values()).find(hr => hr.relay === true &&
                    (norm(hr.relay_name || '') === base || norm(hr.team || '') === base) &&
                    norm(hr.heat || '') === heatStr &&
                    simplifyTime(hr.timing || '') === timeStr
                  ) || null;
                  // Pass 2: match by team/relay_name + simplified timing (ignore heat)
                  if (!heatResult) {
                    heatResult = Array.from(heatResultsMap.values()).find(hr => hr.relay === true &&
                      (norm(hr.relay_name || '') === base || norm(hr.team || '') === base) &&
                      simplifyTime(hr.timing || '') === timeStr
                    ) || null;
                  }
                  // Pass 3: match by team/relay_name only (pick first)
                  if (!heatResult) {
                    heatResult = Array.from(heatResultsMap.values()).find(hr => hr.relay === true &&
                      (norm(hr.relay_name || '') === base || norm(hr.team || '') === base)
                    ) || null;
                  }
                }
                teamKey = CrawlUtil.createTeamKey(rankingResult.team);
              } else {
                const swimmerKey = CrawlUtil.createSwimmerKey(
                  eventInfo.eventGender,
                  rankingResult.lastName,
                  rankingResult.firstName,
                  rankingResult.year,
                  rankingResult.team
                );
                heatResult = heatResultsMap.get(swimmerKey);
                teamKey = CrawlUtil.createTeamKey(rankingResult.team);
                if (index < 3) {
                  console.log(`[DEBUG] RIEPILOGO result ${index + 1}: ${rankingResult.lastName}|${rankingResult.firstName}|${rankingResult.year}|${rankingResult.team}`);
                  console.log(`[DEBUG] Generated key: ${swimmerKey}`);
                  console.log(`[DEBUG] Found in heat results: ${!!heatResult}`);
                }
                if (!heatResult && index < 3) {
                  const similarKeys = Array.from(heatResultsMap.keys()).filter(key => key.includes(rankingResult.lastName) || key.includes(rankingResult.firstName));
                  console.log(`[DEBUG] Similar heat keys found:`, similarKeys.slice(0, 3));
                }
              }

              // DEBUG (verbose)
              // console.log(`[DEBUG] Merging RIEPILOGO data for ${swimmerKey}: found heat result = ${!!heatResult}`);
              
              // teamKey already set above
              
              // Add to lookup tables if not already present
              if (!allResults.teams[teamKey]) {
                allResults.teams[teamKey] = {
                  name: rankingResult.team
                };
              }

              // Create merged result combining RIEPILOGO data with heat lap timings
              let mergedResult;
              if (rankingResult.relay) {
                mergedResult = {
                  relay: true,
                  ranking: rankingResult.ranking,
                  relay_name: rankingResult.relay_name,
                  team: teamKey,
                  timing: rankingResult.timing,
                  category: rankingResult.category,
                  categoryRange: rankingResult.categoryRange,
                  heat: rankingResult.heat,
                  lane: rankingResult.lane
                };
              } else {
                // For mixed individual events, use per-swimmer gender from category header
                let effectiveGender = eventInfo.eventGender;
                if (eventInfo.isMixedIndividual && rankingResult.categoryGender) {
                  effectiveGender = rankingResult.categoryGender;
                  console.log(`[DEBUG] Mixed individual: using categoryGender '${effectiveGender}' for ${rankingResult.lastName}`);
                }
                
                const swimmerKey = CrawlUtil.createSwimmerKey(
                  effectiveGender,
                  rankingResult.lastName,
                  rankingResult.firstName,
                  rankingResult.year,
                  rankingResult.team
                );
                if (!allResults.swimmers[swimmerKey]) {
                  // Swimmer gender: only 'M' or 'F' are valid; 'X' or unknown -> null
                  const swimmerGender = (effectiveGender === 'M' || effectiveGender === 'F') ? effectiveGender : null;
                  allResults.swimmers[swimmerKey] = {
                    lastName: rankingResult.lastName,
                    firstName: rankingResult.firstName,
                    gender: swimmerGender,
                    year: rankingResult.year,
                    team: teamKey
                  };
                }
                if (rankingResult.category && rankingResult.category !== 'N/A' && rankingResult.category !== '') {
                  const swimmerRef = allResults.swimmers[swimmerKey];
                  if (!swimmerRef.category || swimmerRef.category === '' || swimmerRef.category === 'N/A') {
                    swimmerRef.category = rankingResult.category;
                  }
                }
                mergedResult = {
                  ranking: rankingResult.ranking,
                  swimmer: swimmerKey,
                  team: teamKey,
                  timing: rankingResult.timing,
                  category: rankingResult.category,
                  gender: effectiveGender || '' // Explicit gender for Phase 5 processing
                };
              }
              
              // Add heat-specific data if available
              if (heatResult) {
                mergedResult.heat_position = heatResult.heat_position;
                mergedResult.lane = heatResult.lane;
                // Preserve heat number from heat results if present, avoiding null from RIEPILOGO
                if (!mergedResult.heat || mergedResult.heat === '' || mergedResult.heat === 'N/A') {
                  mergedResult.heat = heatResult.heat;
                }
                // Prioritize timing from RISULTATI (heats with laps) over RIEPILOGO
                if (heatResult.timing && heatResult.timing.trim().length > 0) {
                  mergedResult.timing = heatResult.timing;
                }
                if (!rankingResult.relay) mergedResult.nation = heatResult.nation;
                if (rankingResult.relay) {
                  // Populate global swimmers using event gender and create lap swimmer references by leg order
                  const swimmerKeys = [];
                  if (Array.isArray(heatResult.swimmers)) {
                    heatResult.swimmers.forEach((s) => {
                      const sTeamName = s.team || heatResult.team;
                      const sTeamKey = CrawlUtil.createTeamKey(sTeamName);
                      if (!allResults.teams[sTeamKey]) allResults.teams[sTeamKey] = { name: sTeamName };

                      let key;
                      if (eventInfo.eventGender === 'X') {
                        const maleKey = CrawlUtil.createSwimmerKey('M', s.lastName, s.firstName, s.year, sTeamName);
                        const femaleKey = CrawlUtil.createSwimmerKey('F', s.lastName, s.firstName, s.year, sTeamName);
                        const noGenKey = CrawlUtil.createSwimmerKeyNoGender(s.lastName, s.firstName, s.year, sTeamName);
                        if (allResults.swimmers[maleKey]) key = maleKey;
                        else if (allResults.swimmers[femaleKey]) key = femaleKey;
                        else key = noGenKey;

                        if (!allResults.swimmers[key]) {
                          allResults.swimmers[key] = {
                            lastName: s.lastName,
                            firstName: s.firstName,
                            gender: null,
                            year: s.year,
                            team: sTeamKey
                          };
                        }
                      } else {
                        key = CrawlUtil.createSwimmerKey(
                          eventInfo.eventGender,
                          s.lastName,
                          s.firstName,
                          s.year,
                          sTeamName
                        );
                        if (!allResults.swimmers[key]) {
                          // Swimmer gender: only 'M' or 'F' are valid; 'X' or unknown -> null
                          const swimmerGender = (eventInfo.eventGender === 'M' || eventInfo.eventGender === 'F') ? eventInfo.eventGender : null;
                          allResults.swimmers[key] = {
                            lastName: s.lastName,
                            firstName: s.firstName,
                            gender: swimmerGender,
                            year: s.year,
                            team: sTeamKey
                          };
                        }
                      }
                      swimmerKeys.push(key);
                    });
                  }
                  mergedResult.laps = Array.isArray(heatResult.laps)
                    ? heatResult.laps.map((lap, idx) => ({ ...lap, swimmer: swimmerKeys[idx] || null }))
                    : [];
                } else {
                  mergedResult.laps = heatResult.laps || [];
                }
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
              eventGender: eventInfo.eventGender || '',
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
            console.log(`      - Navigating back to event list (PER EVENTO) via LoadHistory_Calendar('1')...`);
            try {
              await page.evaluate(() => {
                try {
                  if (typeof AddItemToHistory === 'function') {
                    AddItemToHistory("LoadHistory_Calendar('1');");
                  }
                  if (typeof LoadHistory_Calendar === 'function') {
                    LoadHistory_Calendar('1');
                  } else {
                    const link = document.querySelector('a#divByEvent');
                    if (link) link.click();
                  }
                } catch (e) {
                  console.log('[DEBUG] Error invoking PER EVENTO helpers (return):', e && e.message);
                  const link = document.querySelector('a#divByEvent');
                  if (link) link.click();
                }
              });
              try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 5000 }); } catch(_) {}
              // Wait for the left event list table to be present and populated
              await page.waitForSelector('#tblMainSxScroll', { timeout: 30000 });
              await page.waitForFunction(() => {
                const tbl = document.querySelector('#tblMainSxScroll');
                if (!tbl) return false;
                const rows = tbl.querySelectorAll('tr');
                return rows && rows.length > 0;
              }, { timeout: 10000 });
              console.log(`      - Returned to PER EVENTO tab successfully.`);
            } catch (navErr) {
              console.log(`      - Warning: navigation back to PER EVENTO may have failed: ${navErr.message}`);
            }
            // Final guard: ensure PER EVENTO is active
            try {
              const modeBack = await page.evaluate(() => ({
                byEvent: !!document.querySelector('td#tdTitleCalendarByEvent'),
                byDay: !!document.querySelector('td#tdTitleCalendarByDay')
              }));
              if (!modeBack.byEvent) {
                console.log(`      - Final guard: not on PER EVENTO (byDay=${modeBack.byDay}). Re-invoking switch...`);
                await page.evaluate(() => {
                  try {
                    if (typeof AddItemToHistory === 'function') {
                      AddItemToHistory("LoadHistory_Calendar('1');");
                    }
                    if (typeof LoadHistory_Calendar === 'function') {
                      LoadHistory_Calendar('1');
                    } else {
                      const link = document.querySelector('a#divByEvent');
                      if (link) link.click();
                    }
                  } catch(_) {}
                });
                try { await page.waitForNetworkIdle({ idleTime: 500, timeout: 5000 }); } catch(_) {}
                await page.waitForSelector('#tblMainSxScroll', { timeout: 30000 });
              }
              const finalBack = await page.evaluate(() => ({
                byEvent: !!document.querySelector('td#tdTitleCalendarByEvent'),
                byDay: !!document.querySelector('td#tdTitleCalendarByDay')
              }));
              console.log(`      - After return: PER EVENTO=${finalBack.byEvent} PER GIORNO=${finalBack.byDay}`);
            } catch (guardErr) {
              console.log(`      - Warning: PER EVENTO guard failed: ${guardErr.message}`);
            }
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
          filename = eventInfo && eventInfo.eventCode ? `${meetingDate}-${sanitizedMeetingName}-${eventInfo.eventCode}-l${this.layoutType}.json` :
                                                        `${meetingDate}-${sanitizedMeetingName}-l${this.layoutType}.json`;
        } else {
          // Fallback to original format if date and place parsing fails
          filename = eventInfo && eventInfo.eventCode ? `results-${eventInfo.eventCode}-l${this.layoutType}.json` :
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
    // Track split columns (e.g., 50 m, 100 m, 150 m, ... ) for the current heat header
    // Each item: { index: <td index>, label: '50 m' }
    let currentSplitCols = [];
    // For relays, group 1 header + 4 swimmer rows
    let skipUntilRowIdx = -1;
    // DEBUG
    console.log(`[DEBUG] processHeatResults: HTML length = ${html.length}`);
    let $tables = $('table.tblContenutiRESSTL_Sotto_Heats');
    if ($tables.length === 0) {
      // Fallback for samples: allow table#tblContenuti
      $tables = $('table#tblContenuti');
    }
    const $rows = $tables.find('tr');
    console.log(`[DEBUG] processHeatResults: Found ${$tables.length} target tables; ${$rows.length} rows in total`);
    $rows.each((i, row) => {
      if (i <= skipUntilRowIdx) return; // skip rows already grouped under a relay header
      const header = $(row).find('td.headerContenuti');
      if (header.length > 0) {
        // Extract heat number from header text. Samples: "Serie 1 di 18", "Serie 3", "Serie 12 of 20"
        const rawHeader = header.text().trim();
        let heatNo = '';
        // Prefer explicit "Serie <n> [di|of] <m>" pattern
        const serieRe = /Serie\s*(\d+)(?:\s*(?:di|of)\s*\d+)?/i;
        const mSerie = rawHeader.match(serieRe);
        if (mSerie && mSerie[1]) {
          heatNo = mSerie[1];
        } else {
          // Fallback: first integer in the header
          const mAny = rawHeader.match(/(\d{1,3})/);
          if (mAny && mAny[1]) heatNo = mAny[1];
        }
        heats.push({ number: heatNo, results: [] });
        // Reset split columns when a new heat header is found
        currentSplitCols = [];
      // Capture the header row that contains split labels (50 m, 100 m, 150 m, ...)
      } else if ($(row).find('td.tdHeaderCont').length > 0 && heats.length > 0) {
        const cols = $(row).find('td');
        // Accumulate split columns across multiple header rows within the same heat
        // (e.g., 800m has 50–400 and 450–750 headers on separate rows)
        if (!Array.isArray(currentSplitCols)) currentSplitCols = [];
        cols.each((idx, td) => {
          const idAttr = ($(td).attr('id') || '').toString();
          const text = $(td).text().trim();
          // Identify split columns either by id like td50m1 / td100m1 / td150m1 ... or by text like "50 m"
          if (/^td\d{2,3}m\d+$/i.test(idAttr) || /\b\d{2,3}\s*m\b/i.test(text)) {
            // Exclude the final time (TEMPO) and other non-split columns
            if (!$(td).hasClass('Risultato')) {
              const already = currentSplitCols.find(c => c.index === idx);
              if (!already) {
                currentSplitCols.push({ index: idx, label: text || idAttr.replace(/^td|\d+$/g, '') });
              }
            }
          }
        });
        // DEBUG
        if (currentSplitCols.length > 0) {
          console.log(`[DEBUG] Detected split columns: ${currentSplitCols.map(c => `${c.label}@${c.index}`).join(', ')}`);
        }
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

          // Handle continuation rows (e.g., 800m second TR with deltas):
          // These typically have the first cell with colspan="7", no name cell content and no timing cell.
          const hasTimingCellHere = $(row).find('td.Risultato').length > 0;
          const nameCellTextHere = $(cols[4]).text().trim();
          const colspan0 = (($(cols[0]).attr('colspan')) || '').toString();
          const colspanInt0 = parseInt(colspan0 || '0', 10) || 0;
          // Fallback: detect rows that are mostly small continuation cells starting with a time token
          const allTdsHere = $(row).find('td');
          let contSmallCount = 0;
          const timeTokenHere = "(?:\\d+'\\d{2}\\.\\d{2}|\\d{1,2}\\.\\d{2})";
          const timeStartReHere = new RegExp(`^\\s*${timeTokenHere}`);
          for (let j = 0; j < allTdsHere.length; j++) {
            const td = allTdsHere[j];
            if ($(td).hasClass('tdContSmall')) {
              const txt = $(td).text().trim();
              if (timeStartReHere.test(txt)) contSmallCount++;
            }
          }
          const mostlyContSmall = contSmallCount >= Math.max(2, Math.floor(allTdsHere.length / 3));
          const looksContinuation = !hasTimingCellHere && (colspanInt0 >= 7 || nameCellTextHere.length === 0 || mostlyContSmall);
          if (looksContinuation && currentSplitCols.length > 0) {
            const currentHeat = heats[heats.length - 1];
            if (currentHeat.results && currentHeat.results.length > 0) {
              const lastResult = currentHeat.results[currentHeat.results.length - 1];
              console.log(`[DEBUG][cont] Continuation row detected. reason: colspan>=7? ${colspanInt0 >= 7}, nameEmpty? ${nameCellTextHere.length === 0}, mostlyContSmall? ${mostlyContSmall}; colspan0="${colspan0}", lastResult has ${lastResult.laps.length} laps so far`);
              // Map continuation row split cells sequentially to >=450m distances
              let secondHalf = currentSplitCols
                .map(({ label }) => ({ label, meters: parseInt((label || '').replace(/[^0-9]/g, ''), 10) }))
                .filter(x => Number.isFinite(x.meters) && x.meters >= 450)
                .sort((a, b) => a.meters - b.meters);
              console.log(`[DEBUG][cont] secondHalf split headers: ${secondHalf.map(x => x.label + ':' + x.meters).join(', ')}`);

              // Build split cells by skipping the initial colspan cell, then collecting td.tdContSmall
              const allTds = $(row).find('td');
              const startIdx = (parseInt(($(allTds[0]).attr('colspan') || '0'), 10) >= 7) ? 1 : 0;
              const splitCells = [];
              for (let j = startIdx; j < allTds.length; j++) {
                const td = allTds[j];
                if ($(td).hasClass('tdContSmall')) splitCells.push(td);
              }
              console.log(`[DEBUG][cont] collected splitCells=${splitCells.length} (startIdx=${startIdx}, allTds=${allTds.length})`);
              // Use all continuation cells in order (even empty ones) to preserve alignment.
              const timeToken = "(?:\\d+'\\d{2}\\.\\d{2}|\\d{1,2}\\.\\d{2})";
              const timeStartRe = new RegExp(`^\\s*${timeToken}`);
              console.log(`[DEBUG][cont] splitCells(all)=${splitCells.length}; samples=[${splitCells.slice(0,4).map(td => $(td).text().trim().replace(/\\s+/g,' ')).join(' | ')}]`);
              // If we have more continuation cells than detected headers (e.g., missing 750m), synthesize remaining distances by +50m steps
              if (splitCells.length > secondHalf.length) {
                let nextMeters = secondHalf.length > 0 ? (secondHalf[secondHalf.length - 1].meters + 50) : 450;
                while (secondHalf.length < splitCells.length) {
                  secondHalf.push({ label: `${nextMeters} m`, meters: nextMeters });
                  nextMeters += 50;
                }
                if (process.env.MICROPLUS_DEBUG === '1') {
                  console.log(`[DEBUG][cont] augmented split headers: ${secondHalf.map(x => x.label + ':' + x.meters).join(', ')}`);
                }
              }
              const maxPairs = Math.min(secondHalf.length, splitCells.length);
              for (let i = 0; i < maxPairs; i++) {
                const cell = splitCells[i];
                const label = secondHalf[i].label;
                const raw = $(cell).text().trim().replace(/\s+/g, ' ');
                if (!raw || !timeStartRe.test(raw)) continue;
                // time/delta tokens: accept m'ss.xx or ss.xx; delta may have leading '+'
                const deltaToken = '(?:\\+?' + timeToken + ')';
                let lapTiming = null;
                let positionAtSplit = null;
                let delta = null;
                const m = raw.match(new RegExp(`^\\s*(${timeToken})\\s*(?:\\((\\d+)\\))?\\s*(${deltaToken})?\\s*$`));
                if (m) {
                  lapTiming = m[1];
                  positionAtSplit = m[2] ? m[2] : null;
                  delta = m[3] ? m[3] : null;
                } else {
                  // Fallback: try to extract trailing delta and optional position
                  const posMatch = raw.match(/\\((\\d+)\\)/);
                  if (posMatch) positionAtSplit = posMatch[1];
                  const deltaMatch = raw.match(/(\\+?\\d+'\\d{2}\\.\\d{2}|\\+?\\d{1,2}\\.\\d{2})\\s*$/);
                  if (deltaMatch) delta = deltaMatch[1];
                }
                // Normalize distance label strictly as '<meters>m' (e.g., '450m') to avoid spaces/case variance
                const distNorm = `${secondHalf[i].meters}m`;
                const lap = { distance: distNorm, timing: lapTiming };
                if (positionAtSplit) lap.position = positionAtSplit;
                if (delta) lap.delta = delta;
                lastResult.laps.push(lap);
              }
              // DEBUG: show distances now on lastResult
              if (process.env.MICROPLUS_DEBUG === '1') {
                try {
                  const dbgDists = (lastResult.laps || []).map(l => l.distance).join(', ');
                  console.log(`[DEBUG][cont] lastResult distances now: ${dbgDists}`);
                } catch(_) {}
              }
              // Proceed to next row without creating a new result
              return; // continue .each loop
            }
          }
          
          // Relay detection: header row has relay name + team in a nobr with <b> and a <font size="1"> team line
          const nameCellHtml = $(cols[4]).html() || '';
          let isRelayHeader = /<nobr>\s*<b>/.test(nameCellHtml) && /<font[^>]*size\s*=\s*"?1"?/i.test(nameCellHtml);
          // Strengthen detection by verifying next 4 rows look like swimmer rows (name in td[4], year in td[5], delta in td[7])
          if (isRelayHeader) {
            let looksLikeRelay = true;
            for (let j = i + 1; j < Math.min($rows.length, i + 5); j++) {
              const $next = $($rows[j]);
              if (!($next.hasClass('trContenutiToggle') || $next.hasClass('trContenuti'))) { looksLikeRelay = false; break; }
              const tds = $next.find('td');
              if (tds.length < 8) { looksLikeRelay = false; break; }
              const nm = CrawlUtil.normalizeUnicodeText($(tds[4]).text() || '');
              const yr = ($(tds[5]).text() || '').trim();
              const hasDelta = $(tds[7]).find('font.tdContSmall').length > 0;
              if (nm.length === 0 || !/^[12][0-9]{3}$/.test(yr) || !hasDelta) { looksLikeRelay = false; break; }
            }
            if (!looksLikeRelay) {
              isRelayHeader = false;
            }
          }
          if (isRelayHeader) {
            const currentHeat = heats[heats.length - 1];
            const heatNo = currentHeat ? currentHeat.number : '';
            const relayName = CrawlUtil.normalizeUnicodeText($(cols[4]).find('nobr > b').first().text() || '');
            const teamName = CrawlUtil.normalizeUnicodeText($(cols[4]).find('nobr > font').first().text() || '');
            const heat_position = $(cols[0]).find('b').text().trim() || $(cols[0]).text().trim();
            const lane = $(cols[1]).text().trim();
            const timing = ($(row).find('td.Risultato').first().text() || '').trim();
            // Collect next 4 swimmer rows
            const swimmers = [];
            const laps = [];
            const relayDistances = ['50m','100m','150m','200m'];
            let lastIdx = i;
            for (let j = i + 1; j < Math.min($rows.length, i + 5); j++) {
              const nextRow = $rows[j];
              const $next = $(nextRow);
              if (!($next.hasClass('trContenutiToggle') || $next.hasClass('trContenuti'))) break;
              const tds = $next.find('td');
              if (tds.length < 6) break;
              const fullName = CrawlUtil.normalizeUnicodeText($(tds[4]).text() || '');
              const parts = CrawlUtil.extractNameParts(fullName);
              const year = ($(tds[5]).text() || '').trim();
              // delta in td[7] font.tdContSmall
              let delta = '';
              const deltaCell = $(tds[7]).find('font.tdContSmall').first();
              if (deltaCell && deltaCell.length > 0) delta = deltaCell.text().trim();
              const leg = swimmers.length + 1;
              swimmers.push({ lastName: parts.lastName, firstName: parts.firstName, year });
              laps.push({ distance: relayDistances[Math.min(leg - 1, 3)], delta });
              lastIdx = j;
            }
            skipUntilRowIdx = Math.max(skipUntilRowIdx, lastIdx);
            const relayResult = {
              relay: true,
              relay_name: relayName,
              team: teamName,
              heat_position,
              lane,
              timing,
              heat: heatNo,
              swimmers,
              laps
            };
            currentHeat.results.push(relayResult);
            return; // processed relay group
          }

          // Extract nation from column 3 (individuals)
          const nationHtml = $(cols[3]).html();
          const nation = nationHtml ? $('<div>').html(nationHtml).text().replace(/.*<b>([^<]+)<\/b>.*/, '$1').trim() : '';
          
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
          
          // Extract name data (but don't fail if missing) - individual rows
          const nameDataHtml = $(cols[4]).html();
          let nameParts = { lastName: '', firstName: '' }; // Initialize as object, not array
          let year = '';
          let team = '';
          // DEBUG (extremely verbose)
          // console.log(`[DEBUG] Heat nameDataHtml: "${nameDataHtml}"`);
          
          if (nameDataHtml) {
            const nameData = nameDataHtml.split('<br>');
            const fullNameHtml = $('<div>').html(nameData[0]).text();
            // DEBUG (extremely verbose)
            // console.log(`[DEBUG] Heat fullNameHtml: "${fullNameHtml}"`);
            nameParts = CrawlUtil.extractNameParts(fullNameHtml); // No redeclaration
            year = nameData[1] ? $('<div>').html(nameData[1]).text().replace(/[()]/g, '').trim() : '';
            team = nameData[2] ? $('<div>').html(nameData[2]).text().trim() : '';
            // DEBUG (verbose)
            // console.log(`[DEBUG] Heat extracted: ${nameParts.lastName}|${nameParts.firstName}|${year}|${team}`);
          }
          
          // Extract correct data based on actual HTML structure (individuals):
          // Col 0: heat position (inside <b>), Col 1: lane, Col 3: nation, Col 4: name/year/team
          // Splits: detected dynamically from currentSplitCols; Final timing in td.Risultato
          const result = {
            heat_position: $(cols[0]).find('b').text().trim() || $(cols[0]).text().trim(),
            lane: $(cols[1]).text().trim(),
            nation: nation,
            lastName: nameParts.lastName || '',
            firstName: nameParts.firstName || '',
            year: year,
            team: team,
            timing: timing,
            heat: heats.length > 0 ? heats[heats.length - 1].number : '', // Heat number, not category
            laps: []
          };

          // Build laps array from detected split columns, if any
          if (timing && currentSplitCols.length > 0) {
            currentSplitCols.forEach(({ index, label }) => {
              // For the primary row, only use first-half distances (e.g., < 450m)
              const meters = parseInt((label || '').replace(/[^0-9]/g, ''), 10);
              if (!Number.isFinite(meters) || meters >= 450) return;
              if (index < cols.length) {
                const raw = $(cols[index]).text().trim().replace(/\s+/g, ' ');
                if (raw) {
                  // Expected formats:
                  //  - "1'11.87" (first split)
                  //  - "2'30.47 (8)1'18.60"  => time, (position), delta
                  //  - sometimes without position: "2'30.47 1'18.60"
                  //  - seconds-only values (no minutes) for timing or delta: "59.87" or with plus "+59.87"
                  let lapTiming = null;
                  let positionAtSplit = null;
                  let delta = null;
                  const timeTokenP = "(?:\\d+'\\d{2}\\.\\d{2}|\\d{1,2}\\.\\d{2})";
                  const deltaTokenP = '(?:\\+?' + timeTokenP + ')';
                  const m = raw.match(new RegExp(`^\\s*(${timeTokenP})\\s*(?:\\((\\d+)\\))?\\s*(${deltaTokenP})?\\s*$`));
                  if (m) {
                    lapTiming = m[1];
                    positionAtSplit = m[2] ? m[2] : null;
                    delta = m[3] ? m[3] : null;
                  } else {
                    // Fallback: take first token as timing
                    const parts = raw.split(' ');
                    lapTiming = parts[0];
                    // Try to find parentheses for position
                    const posMatch = raw.match(/\((\d+)\)/);
                    if (posMatch) positionAtSplit = posMatch[1];
                    // Try to find a trailing time as delta
                    const deltaMatch = raw.match(/(\+?\d+'\d{2}\.\d{2}|\+?\d{1,2}\.\d{2})\s*$/);
                    if (deltaMatch && deltaMatch[1] !== lapTiming) delta = deltaMatch[1];
                  }
                  const distance = (label || '').replace(/\s+/g, '').toLowerCase(); // e.g., '50 m' -> '50m'
                  const distNorm = /\d+m/i.test(distance) ? distance : (label || '').replace(/\s+/g, '');
                  const lap = { distance: distNorm, timing: lapTiming };
                  if (positionAtSplit) lap.position = positionAtSplit;
                  if (delta) lap.delta = delta;
                  result.laps.push(lap);
                }
              }
            });
          } else if (timing && $(cols[7]).text().trim()) {
            // Fallback to original behavior if we couldn't detect header splits
            result.laps = [{ distance: '50m', timing: $(cols[7]).text().trim() }];
          }
          heats[heats.length - 1].results.push(result);
        }
      }
    });
    return { heats };
  }

  processRankingResults(html, options = {}) {
    const $ = cheerio.load(html);
    const results = [];
    let currentCategory = '';
    let currentGenderFromCategory = ''; // Track gender for current category section
    let detectedGenderFromCategory = ''; // Track first gender detected (for non-mixed events)
    // Decide per row whether it's relay or individual; category headers appear in both

    const rows = $('table.tblContenutiRESSTL#tblContenuti tr');
    console.log(`[DEBUG] processRankingResults: Found ${rows.length} rows in total`);

    rows.each((i, row) => {
      const $row = $(row);
      const rowText = CrawlUtil.normalizeUnicodeText($row.text() || '').replace(/\s+/g, ' ').trim();

      // Detect category header rows (robust): "MASTER 75F" -> currentCategory = "M75"
      // Also extract gender suffix (F/M) for per-swimmer gender detection
      const headerMatch = rowText.match(/\bMASTER\s+(\d{2,3})\s*([FMX])?\b/i);
      const isResultRow = $row.hasClass('trContenuti') || $row.hasClass('trContenutiToggle');

      if (headerMatch && !isResultRow) {
        const age = headerMatch[1];
        currentCategory = `M${age}`;
        // Extract gender from category header suffix (e.g., "MASTER 80F" -> 'F')
        if (headerMatch[2]) {
          const genderChar = headerMatch[2].toUpperCase();
          if (genderChar === 'F' || genderChar === 'M') {
            currentGenderFromCategory = genderChar; // Update current gender for this section
            if (!detectedGenderFromCategory) {
              detectedGenderFromCategory = genderChar; // First detected gender for fallback
            }
            console.log(`[DEBUG] Detected gender from category header: "${genderChar}" (current section)`);
          }
        }
        console.log(`[DEBUG] Category header: "${rowText}" -> ${currentCategory}`);
        return; // continue
      }

      if (!isResultRow) return; // skip non-result rows

      const cols = $row.find('td');
      if (cols.length < 7) return; // defensive

      // Heuristic: Individuals usually have >=10 columns with name at index ~6 and year/team columns present.
      // Relay summary rows often have fewer columns (7-9) with ranking, heat, lane, relay name, team, timing.
      if (cols.length <= 9) {
        // Relay summary columns (expected): 0:ranking,1:heat,2:lane,3:relay name,4:team,5:unused,6+: timing
        const ranking = ($(cols[0]).find('b').text() || $(cols[0]).text() || '').trim();
        const heat = ($(cols[1]).text() || '').trim();
        const lane = ($(cols[2]).text() || '').trim();
        const relayName = CrawlUtil.normalizeUnicodeText($(cols[3]).text() || '');
        const team = CrawlUtil.normalizeUnicodeText($(cols[4]).text() || '');
        const timingCell = $row.find('td.Risultato').last();
        const timing = (timingCell.length ? timingCell.text() : ($(cols[cols.length - 1]).text() || '')).trim();
        // Compute category range (e.g., 240 -> 240-259)
        let categoryRange = '';
        const ageMatch = currentCategory.match(/M(\d{2,3})/i);
        if (ageMatch) {
          const base = parseInt(ageMatch[1], 10);
          if (!isNaN(base)) categoryRange = `${base}-${base + 19}`;
        }
        const result = {
          relay: true,
          ranking,
          heat,
          lane,
          relay_name: relayName,
          team,
          timing,
          category: currentCategory,
          categoryRange
        };
        if (results.length < 3) {
          console.log(`[DEBUG] Adding RIEPILOGO relay result ${results.length + 1}:`, JSON.stringify(result, null, 2));
        }
        results.push(result);
        return;
      }

      // Individual summary (fallback)
      if (cols.length < 10) return; // defensive for individuals

      const ranking = $(cols[1]).find('b').text().trim() || $(cols[1]).text().trim();
      const timing = $(cols[9]).hasClass('Risultato') ? $(cols[9]).text().trim() : $(cols[9]).text().trim();

      // Name extraction
      const nameHtml = $(cols[6]).find('nobr b').text() || $(cols[6]).text();
      const nameParts = CrawlUtil.extractNameParts(nameHtml);
      const lastName = nameParts.lastName || '';
      const firstName = nameParts.firstName || '';

      // Team and year
      const teamHtml = $(cols[7]).find('nobr').text() || $(cols[7]).text();
      const team = CrawlUtil.normalizeUnicodeText(teamHtml);
      const year = $(cols[8]).text().trim();

      let result = {
        ranking,
        lastName,
        firstName,
        team,
        year,
        timing,
        category: currentCategory,
        categoryGender: currentGenderFromCategory // Per-swimmer gender from category header
      };

      // If caller indicates we're parsing a relay RIEPILOGO, ensure relay flag is set
      if (options && options.isRelay === true) {
        result = {
          ...result,
          relay: true,
          relay_name: team,
          heat: null,
          lane: null
        };
      }

      if (results.length < 3) {
        console.log(`[DEBUG] Adding RIEPILOGO result ${results.length + 1}:`, JSON.stringify(result, null, 2));
      }
      results.push(result);
    });

    console.log(`[DEBUG] processRankingResults extracted ${results.length} results from RIEPILOGO`);
    return { results, detectedGenderFromCategory };
  }
}

module.exports = MicroplusCrawler;
