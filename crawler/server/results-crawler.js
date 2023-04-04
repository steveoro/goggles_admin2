/*
 * FIN Meeting results crawler.
 *
 * -- Note: --
 * Install all modules enlisted below with 'npm install <package-name> --save', except node.js itself:
 *  > sudo apt-get install nodejs
 */
const Fs        = require('fs')
const jQuery    = require('jquery')
const puppeteer = require('puppeteer')
const cheerio   = require('cheerio')
const fetch     = require('node-fetch')   // do not upgrade: 'require' is unsupported by the latest version of node-fetch
// const Util      = require('util')      // used only in debugging statements

// Local modules:
const CrawlUtil = require('./utility')  // Crawler utility functions
//-----------------------------------------------------------------------------

/**
 * == ResultsCrawler class ==
 *
 * Sample usage:
 * > const crawler = new ResultsCrawler(seasonId, calendarFilePath);
 * > crawler.run();
 */
class ResultsCrawler {
  /**
   * Constructs a new ResultsCrawler instance.
   *
   * @param {Integer} seasonId - the season ID of the calendar to crawl; defaults to 212 (FIN 2021/2022)
   * @param {String} calendarFilePath - the path to the calendar file to process
   * @param {Integer} layoutType - code for the layout type of the result page; defaults to 3 (FIN current season)
   *                               typically this is bound to the format layout of the calendar page.
   */
  constructor(seasonId = 212, calendarFilePath, layoutType = 3) {
    this.seasonId = seasonId
    this.calendarFilePath = calendarFilePath
    this.layoutType = layoutType
  }
  //---------------------------------------------------------------------------

  /**
   * Runs the results crawler.
   *
   * Loops on the specified CSV file, assuming each line contains at least the URL to crawl
   * to get to its results page.
   *
   * Expected CSV format:
   * ----8<----
   * sourceURL,date,isCancelled,name,place,meetingUrl,year
   * <ignoredURL>,dd(-dd)/mm,['canc*'],Meeting Name,City (or Cities separated by ;),urlWithResultsList,YYYY
   * ----8<----
   *
   * When each `meetingUrl` is crawled, the results are extracted from the page as a single JSON
   * object, and saved in a file named after the meeting URL, in a subdirectory named after the
   * specified Season ID.
   *
   * At the end of the loop, the calendar file is moved into the processed files data directory
   * ('calendar.done').
   *
   * Later on, each JSON file can be processed for the actual data-importing.
   */
  run() {
    // Ignore TLS self-signed certificates & any unauthorized certs: (Not secure, but who cares for crawling...)
    process.env["NODE_TLS_REJECT_UNAUTHORIZED"] = 0

    puppeteer
      .launch({
        headless: true,
        args: [
          '--ignore-certificate-errors', '--enable-feature=NetworkService',
          '--no-sandbox', '--disable-setuid-sandbox'
        ]
      })
      .then(async browser => {
        console.log("\r\n*** FIN Results Crawler ***\r\n")
        CrawlUtil.updateStatus(`Season ${this.seasonId} => layout: ${this.layoutType} - reading ${this.calendarFilePath}...`)
        const layout = this.layoutType
        const csvList = await CrawlUtil.readCSVData(this.calendarFilePath)
        var skippedRows = new Array()
        CrawlUtil.updateStatus(`Total rows found: ${csvList.length}`, 'OK, running', 0, csvList.length)

        for (var i = 0; i < csvList.length; i++) {
          var calendarRow = csvList[i]
          // DEBUG
          console.log("\r\n--------------------------------[ calendarRow ]---------------------------------");
          console.log(calendarRow);
          const cancelled = calendarRow.cancelled
          console.log(`=> Processing URL ${i + 1}/${csvList.length} - layout: ${layout}, "${calendarRow.name}" ${cancelled ? '-CANC-' : ''}`)
          CrawlUtil.updateStatus(`Processing "${calendarRow.name}"`, `OK, processing ${i + 1}/${csvList.length}`, i + 1, csvList.length)

          if (calendarRow.url && !cancelled && calendarRow.url != 'undefined' && calendarRow.url != 'null' && calendarRow.url != ' ') {
            if (layout == 1) {
              await this.processResultPageWithLayout1(calendarRow, browser, skippedRows)
            } else if (layout == 2 || layout == 3) {
              await this.processResultPageWithLayout2(calendarRow, browser, skippedRows)
            } else {
              CrawlUtil.updateStatus('Unsupported layout specified in API call', 'ERROR')
            }
          }
          else { // Store skipped calendar rows:
            CrawlUtil.updateStatus("Undefined URL or results unavailable: skipping", `OK, processing ${i + 1}/${csvList.length}`, i + 1, csvList.length)
            skippedRows.push(calendarRow)
          }
        }

        await browser.close()
        console.log(`\r\n\r\n--------------------------------------------------------------------------------\r\n`)
        // "Consume" the calendar file & create the skipped rows output file in its place:
        CrawlUtil.updateStatus(`Moving processed calendar`, 'OK, postprocessing')
        this.moveCalendarFileToDone()

        if (skippedRows.length > 0) {
          CrawlUtil.updateStatus(`Saving skipped rows`, 'OK, postprocessing')
          const skipFilePath = this.calendarFilePath.replace('.csv', '-skip.csv')
          CrawlUtil.writeCSVData(skipFilePath, skippedRows)
        }

        CrawlUtil.updateStatus(`Calendar processing done`, 'OK, done, idle')
        return true
      })
      .catch((error) => {
        CrawlUtil.updateStatus(`${error.toString()}`, 'ERROR')
        return false
      });
  }
  //---------------------------------------------------------------------------

  /**
    * Asynch page function for browsing a single Meeting results URL, assuming it's being rendered
    * using the "FIN layout 1" (pre-2018).
    *
    * The "layout type 1" includes all the result rows for a single event as <pre> nodes, using <h2> as event titles,
    * as in:
    *
    * ----8<----[haml sample]
      .gara#11
        %h2
          a{ name: '11' }
            400 SL
        %pre
          //         400 stile libero  femminile  -  Categoria  Under 25
          // ----------------------------------------------------------------------------------------------
          //       1   SURNAME1 NAME1                 1994   TEAMNAME1                   4'49"74  0,00
          //       2   SURNAME2 NAME2                 1995   TEAMNAME2                   4'55"15  0,00
          // [...]
          //
          //         400 stile libero  femminile  -  Categoria  Master 25      Tempo Base :  4'23"38
          // ----------------------------------------------------------------------------------------------
          //       1   SURNAME3 NAME3                 1990   TEAMNAME3                   4'33"59  962,68
          // [...]
    * ----8<----
    *
    * Different result categories are split by a separator (usually with a return plus the event subtitle
    * and one or more dashed lines).
    *
    * Note that for extracting result values, relying upon the specific number of fixed spaces and their column
    * positions is not feasible, because:
    *
    * - column indexes may vary from Meeting to Meeting;
    * - different text formatting output and decoration is used for from Region to Region.
    *
    * The parsing of the individual result rows for "page layout 1" will be done subsequently by the Rails companion
    * app which is more than capable of handling different text outputs.
    *
    *
    * == Layout extraction examples: ==
    *
    * Total number of events:
    * > document.querySelectorAll('.gara').length
    *
    * First event title:
    * > document.querySelector('.gara h2').textContent
    *
    * First event result w/ fixed spacing:
    * > document.querySelector('.gara pre').textContent
    *
    * Map all event titles:
    * > Array.from(document.querySelectorAll('.gara')).map(node => { return node.querySelector('h2').textContent })
    *
    *
    * @param {Object} calendarRow - a row from the CSV file
    * @param {Object} browser - a Puppeteer instance
    * @param {Array} skippedRows - the array storing "skipped rows" that do not have any result nodes available
    */
  async processResultPageWithLayout1(calendarRow, browser, skippedRows) {
    console.log(`'FIN layout 1' - browsing to ${calendarRow.url}...`)
    // Create a new incognito browser context:
    const context = await browser.createIncognitoBrowserContext()
    // Create a new page in a pristine context:
    const page = await context.newPage()
    await page.setViewport({ width: 1024, height: 768 })
    await page.setUserAgent('Mozilla/5.0')
    page.on('load', () => { console.log('=> Page fully loaded.') })

    await page.goto(calendarRow.url)
    await page.waitForNetworkIdle({ idleTime: 1000 })
    await page.waitForSelector('.gara').catch((err) => { console.log(err.toString()) })
    const totRowCount = await page.$$eval('.gara', (eventNodes) => { return eventNodes.length }).catch((err) => { console.log(err.toString()) })
    console.log(`   Found ${totRowCount} event nodes`)

    const name = await page.$eval('#risultati-master h1.nome', (node) => { return node.textContent }).catch((err) => { console.log(err.toString()) })
    const organization = await page.$eval('#risultati-master h3', (node) => { return node.textContent }).catch((err) => { console.log(err.toString()) })
    // DEBUG
    // await page.screenshot({ path: './screenshot.png' });
    console.log(`   Processing event nodes...`)
    const sections = await page.$$eval('.gara', (eventNodes) => {
      return Array.from(eventNodes)
        .map((node) => {
          return {
            title: node.querySelector('h2') ? node.querySelector('h2').textContent : '',
            rows: node.querySelector('pre') ? node.querySelector('pre').textContent.split("\n") : []
          }
        })
      })
      .catch((err) => { console.log(err.toString()) })

    const meetingResult = {
      layoutType: 1,
      meetingURL: calendarRow.url,
      name: name,
      organization: organization,
      sections: sections
    }
    // DEBUG
    // console.log("\r\n------------------------------[ meetingResult ]--------------------------------");
    // console.log(meetingResult);

    console.log(`   Extracted data for '${meetingResult.name}' with ${meetingResult.sections ? meetingResult.sections.length : 0} sections/events.`)
    this.saveResultOutputFile(calendarRow, meetingResult)
    if (totRowCount < 1) { // Add current calendar row to skipped ones if no nodes were available:
      skippedRows.push(calendarRow)
    }
    console.log('   Closing context...')
    await context.close()
  }
  //---------------------------------------------------------------------------

  /**
    * Asynch page function for browsing a single Meeting results URL, assuming it's being rendered
    * using the "FIN layout 2" (2017/2018+).
    *
    * This "layout type 2" requires individual AJAX calls to a common endpoint in order to have rendered
    * the actual meeting event & program details and results.
    *
    * @param {Object} calendarRow - a row from the CSV file
    * @param {Object} browser - a Puppeteer instance
    * @param {Array} skippedRows - the array storing "skipped rows" that do not have any result nodes available
    */
  async processResultPageWithLayout2(calendarRow, browser, skippedRows) {
    console.log(`'FIN layout 2' - browsing to ${calendarRow.url}...`);
    // Create a new incognito browser context:
    const context = await browser.createIncognitoBrowserContext()
    // Create a new page in a pristine context:
    const page = await context.newPage()
    await page.setViewport({ width: 1024, height: 768 })
    await page.setUserAgent('Mozilla/5.0')
    page.on('load', () => { console.log('=> Page fully loaded.') });

    await page.goto(calendarRow.url, { waitUntil: 'load' });
    await page.waitForSelector('.details_nat_eve_list.master > .infos')
              .catch((err) => { console.log(err.toString()) })
    // DEBUG
    // await page.screenshot({ path: './screenshot.png' });

    const arrayOfParams = await page.$$eval(".categorie span.collegamento", (nodes) =>
        nodes.map((node) => {
          const params = jQuery(node).data('id').split(';') // i.e.: {data-id: "139714;04;M50;F"}
          // Current labels for variable PARAMS (usually unchanged over the years):
          // const labels = jQuery(node).data('value').split(';')
          // => "solr[id_evento];solr[codice_gara];solr[sigla_categoria];solr[sesso]" (params must be in this order!)
          return {
            'solr[id_settore]': 1,
            'solr[id_tipologia_1]': 2,
            'solr[corsi_passati]': 0,
            'solr[id_evento]': params[0],
            'solr[codice_gara]': params[1],
            'solr[sigla_categoria]': params[2],
            'solr[sesso]': params[3]
          }
        })
      ).catch((err) => { console.log(err.toString()) })

    console.log(`=> Found ${arrayOfParams.length} tot. subsections to be fetched. Processing...`)
    console.log('   Extracting Meeting header...');
    const meetingResult = await this.extractMeetingInfoFromLayout2(calendarRow.url, page)
    const sectionData = await this.fetchEventPrgDetailsLayout2(arrayOfParams)

    // Merge the result section rows with the Meeting header info and store the result:
    meetingResult['sections'] = sectionData
    // DEBUG
    // console.log("\r\n------------------------------[ meetingResult ]--------------------------------");
    // console.log(meetingResult);
    this.saveResultOutputFile(calendarRow, meetingResult)
    if (arrayOfParams.length < 1) { // Add current calendar row to skipped ones if no nodes were available:
      skippedRows.push(calendarRow)
    }
    console.log('   Closing context...')
    await context.close()
  }
  //---------------------------------------------------------------------------

  /**
   * Meeting event/program subsection retrieval, using AJAX parameters extracted from the header page.
   *
   * @param {Array} arrayOfParams - Array of objects params, each one needed for a single AJAX call to request the
   *                                additional Meeting event results details (all retrieved from the same single backend page).
   * @returns {Array} the list of result event objects (header & details) for the specified meeting result URL
   */
  async fetchEventPrgDetailsLayout2(arrayOfParams) {
    // Backend base URL (common endpoint for all event result details requests):
    const backendUrl = "https://www.federnuoto.it/index.php?option=com_solrconnect&currentpage=1&view=dettagliorisultati&format=json";
    var sectionData = [], okCount = 0, errorCount = 0, totCount = arrayOfParams.length;

    for (var params of arrayOfParams) {
      const ajaxParams = params;
      console.log(`   - Fetching ${1 + okCount + errorCount}/${totCount}`);
      // POST request used to retrieve the meeting results details:
      const newEventPrgData = await fetch(backendUrl, {
          method: "POST",
          cache: "no-cache",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          redirect: "follow",
          body: this.encodeObjectParamsAsURI(ajaxParams) // The body is supposed to be an encoded string of JSON object params
        })
        .then(response => {
          return response.json()
        })
        .then(jsonData => {
          return this.extractSectionDetailsLayout2(jsonData['content'], ajaxParams)
        })
        .catch(error => {
          console.error(`ERROR: ${error}`);
          console.log(`     *ERROR* on section ${okCount + errorCount}/${totCount} => RETRY needed!`)
          errorCount++
          return {
            retry: params,
            msg: error
          }
        });
      // DEBUG
      // console.log(`newEventPrgData:`, newEventPrgData)
      sectionData.push(newEventPrgData)
      okCount++
      console.log(`     ${okCount}/${totCount} done${errorCount > 0 ? ` - ${errorCount} errors` : ''}`)
    }
    return sectionData;
  }

  /**
   * FIN Meeting header info + result rows object builder.
   *
   * Given the page object, extracts the data from the '.infos' section. (FIN HTML format 2, 2018-2019+)
   *
   * @param {String} meetingUrl - the meeting URL (just for logging purposes)
   * @param {Object} page - the page object to be processed
   * @returns {Object} the meeting header as a single object
   */
  async extractMeetingInfoFromLayout2(meetingUrl, page) {
    return await page.evaluate((srcUrl, implSafeQuerySelector, implSafeFindHTMLContent) => {
      // Inject our custom helper scripts into the page context:
      const safeQuerySelector = eval(implSafeQuerySelector)
      const safeFindHTMLContent = eval(implSafeFindHTMLContent)
      const info = document.querySelector('.infos')

      return {
        layoutType: 2,
        name: safeQuerySelector(info, 'h3'),
        meetingURL: srcUrl,
        manifestURL: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Locandina', 'a', 'href'),
        // Dates:
        dateDay1: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(1) .nat_eve_d'),
        dateMonth1: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(1) .nat_eve_m'),
        dateYear1: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(1) .nat_eve_y'),
        dateDay2: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(2) .nat_eve_d'),
        dateMonth2: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(2) .nat_eve_m'),
        dateYear2: safeQuerySelector(info, '.nat_eve_dates .nat_eve_date:nth-child(2) .nat_eve_y'),
        // Misc info:
        organization: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Organizzazione', '.vle'),
        venue1: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Impianto', '.vle'),
        address1: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Sede', '.vle'),
        venue2: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Impianto', '.vle', 'textContent', true /* get the 2nd child */),
        address2: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Sede', '.vle', 'textContent', true),
        poolLength: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Vasca', '.vle'),
        timeLimit: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Tempi Limite', '.vle'),
        registration: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Inizio/Chiusura', '.vle'),
        resultsPdfURL: safeFindHTMLContent(info, '.nat_eve_infos p', 'span', 'Risultati', 'a', 'href')
      }
    }, meetingUrl, CrawlUtil.safeQuerySelector.toString(), CrawlUtil.safeFindHTMLContent.toString());
  }

  /**
   *  FIN Meeting section details extractor (and object builder).
   *
   *  Extracts data from an already expanded (retrieved) result section. (FIN HTML format 2, 2018-2019+)
   *  Uses cheerio fast parser to retrieve nodes like it was jQuery.
   *
   * @param {String} htmlString - the HTML of the section to be processed
   * @param {Object} ajaxParams - the object storing the AJAX parameters
   * @returns {Object} the extracted data
   */
  extractSectionDetailsLayout2(htmlString, ajaxParams) {
    // DEBUG
    // console.log("\r\n--------------------------------------------------------------");
    // console.log(htmlString);
    // console.log("--------------------------------------------------------------\r\n");
    var doc$ = cheerio.load(htmlString);
    var sectResult = [];
    const sectionTitle = doc$(".risultati_gara h3").text().trim();
    const resultNodes = doc$(".tournament");
    console.log(`     '${sectionTitle}' => tot. ${resultNodes.length}`);

    doc$(".tournament").each(function (i, item) {
      sectResult.push({
        pos: doc$(".positions", item).text(),
        name: doc$(".name", item).text(),
        year: doc$(".anno", item).text(),
        sex: ajaxParams['solr[sesso]'],
        team: doc$(".societa", item).text(),
        timing: doc$(".tempo", item).text(),
        score: doc$(".punteggio", item).text()
      });
    });
    // DEBUG
    //console.log("\r\n--------------------------------------------------------------");
    //console.log(sectResult);
    //console.log("--------------------------------------------------------------\r\n");

    return {
      title: sectionTitle,
      fin_id_evento: ajaxParams['solr[id_evento]'],
      fin_codice_gara: ajaxParams['solr[codice_gara]'],
      fin_sigla_categoria: ajaxParams['solr[sigla_categoria]'],
      fin_sesso: ajaxParams['solr[sesso]'],
      rows: sectResult
    };
  }
  //-------------------------------------------------------------------------------------

  /**
   *  Works as jQuery.param(): encodes a (JSON) data Object into a URI component
   * @param {Object} data - the data to encode
   * @returns {String} the encoded data
   */
  encodeObjectParamsAsURI(data) {
    return Object.keys(data)
                 .map((key) => { return `${encodeURIComponent(key)}=${encodeURIComponent(data[key])}` })
                 .join('&')
  }

  /**
   *  Moves the source calendar file to the processed files directory.
   */
  moveCalendarFileToDone() {
    // Move calendar file to processed files directory & create the skipped rows output calendar file:
    CrawlUtil.assertDestFolder(CrawlUtil.calendarDoneFolder, this.seasonId)
    const doneFilePath = this.calendarFilePath.replace(CrawlUtil.calendarNewFolder, CrawlUtil.calendarDoneFolder)
    Fs.rename(this.calendarFilePath, doneFilePath, (err) => {
      if (err) {
        console.log("An error occurred while writing the contents to the file.")
        return console.log(err)
      }
      CrawlUtil.updateStatus('Calendar "consumed"', 'Calendar processed and moved to "done" folder')
    })
  }

  /**
   * Returns the output JSON filename from the given calendarRow (extracted from the CSV file).
   * @param {Object} calendarRow - a row from the CSV file
   * @returns {string} the output JSON filename
   */
  getOutputJSONFilename(calendarRow) {
    const normalizedDate = calendarRow.dates ? calendarRow.dates[0] : 'xxx'
    const normalizedName = CrawlUtil.normalizeText(calendarRow.name).replace(/\s+/g, '_')
    return `${normalizedDate}-${normalizedName}.json`
  }

  /**
   * Serializes the specified meetingObject to a JSON file preparing the destination pathname using
   * the calendarRow.
   * @param {Object} calendarRow - the currently processed row from the CSV file
   * @param {Object} meetingObject - the object storing the whole meeting data
   */
  saveResultOutputFile(calendarRow, meetingObject) {
    const outFileName = this.getOutputJSONFilename(calendarRow)
    const destResultFolder = CrawlUtil.assertDestFolder(CrawlUtil.resultsNewFolder, this.seasonId)
    const destResultFilePath = `${destResultFolder}/${outFileName}`

    console.log(`=> Generating '${destResultFilePath}'`)
    CrawlUtil.writeJSONFile(destResultFilePath, meetingObject)
    CrawlUtil.updateStatus(`Saved "${outFileName}"`)
  }
}
//-----------------------------------------------------------------------------

/*
  LOW-LEVEL, PLAIN ES6 example selection w/ current "FIN layout 2" format:

  Click to show "Male":
     document.querySelectorAll("section#component div:nth-child(3) > ul > li:nth-child(1)")
     => $("section#component li:nth-child(1) > span").click()

  Event titles:
     document.querySelectorAll("section#component div.active > div > h3")

  All link nodes:
     all Male+Female => document.querySelectorAll(".categorie span.collegamento")
     ~ "section#component div.active > div > div:nth-child(2) > span"
*/
//-----------------------------------------------------------------------------

module.exports = ResultsCrawler
