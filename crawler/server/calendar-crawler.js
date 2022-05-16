/*
 * FIN Calendar crawler.
 *
 * -- Note: --
 * Install all modules enlisted below with 'npm install <package-name> --save', except node.js itself:
 *  > sudo apt-get install nodejs
 */
const Fs = require('fs')
const puppeteer = require('puppeteer')

// Local modules & constants:
const CrawlUtil = require('./utility') // Crawler utility functions
//-----------------------------------------------------------------------------

/**
 * == CalendarCrawler class ==
 *
 * Sample usage:
 * > const crawler = new CalendarCrawler(seasonId, startURL);
 * > crawler.run();
 */
class CalendarCrawler {
  /**
   * Constructs a new CalendarCrawler instance.
   *
   * The CalendarCrawler is able to detect the actual layout type from the contents of the crawled page.
   *
   * @param {Integer} seasonId - the season ID of the calendar to crawl; defaults to 212 (FIN 2021/2022)
   *
   * @param {String} startURL - starting URL for the crawler; defaults to `CrawlUtil.defaultStartURL`
   */
  constructor(seasonId = 212, startURL = CrawlUtil.defaultStartURL) {
    this.seasonId = seasonId
    this.startURL = startURL
    this.outputCalendarPathname = null
  }
  //---------------------------------------------------------------------------

  /**
   * Searches for the signature CSS classes of the calendar page layout type and returns its
   * coded type.
   *
   * @param {Object} page - the Puppetter page object to be scanned; must respond to `$eval`;
   * @returns the coded type of the calendar page (1 or 2; 3 only for the current season tabular report);
   *          0 for an unknown layout.
   */
  async calendarLayoutDetector(page) {
    var layoutType = 0 // default: unsupported layout
    // Older calendar layout w/ large separator for months (pre-2018):
    layoutType = await page.$eval('.calendario-container', () => { return 1 }).catch(() => { return 0 })
    if (layoutType == 0) {
      // More recent layout, 1 cell for each meeting/event (2018+):
      layoutType = await page.$eval('.nat_eve_list.risultati', () => { return 2 }).catch(() => { return 0 })
    }
    if (layoutType == 0) {
      // Table layout ("Riepilogo" / different start URL, only for current season):
      layoutType = await page.$eval('table.records.ris-style', () => { return 3 }).catch(() => { return 0 })
    }
    return layoutType
  };
  //---------------------------------------------------------------------------

  /**
    * Asynch pageFunction for retrieving the FIN calendar from the list of current events
    * from the current season.
    * Supports 2018+ FIN website styling.
    * @param {String} baseURL - the browsed url (for serializing purposes)
    * @param {Object} browser - a Puppeteer instance
    */
  async processPage(baseURL, browser) {
    const page = await browser.newPage();
    await page.setViewport({ width: 1024, height: 768 })
    await page.setUserAgent('Mozilla/5.0')
    page.on('load', () => { console.log('=> Page fully loaded.') });
    CrawlUtil.updateStatus(`Browsing to ${baseURL}...`)
    await page.goto(baseURL, { waitUntil: 'load' })
    const layoutType = await this.calendarLayoutDetector(page)
    console.log(`Detected layout ${layoutType}: parsing accordingly...`)

    var calendar = { layout: layoutType, rows: [] }
    if (layoutType == 1) {
      calendar.rows = await this.processCalendarLayout1(page)
    }
    else if (layoutType == 2) {
      calendar.rows = await this.processCalendarLayout2(baseURL, page)
    }
    else if (layoutType == 3) {
      calendar.rows = await this.processCalendarLayout3(baseURL, page)
    }
    // (ELSE: Unknown layout, skip processing)

    if (calendar.layout > 0 && calendar.rows && calendar.rows.length > 0) {
      console.log(`Calendar parsing done (${calendar.rows.length} rows).`)
      // DEBUG
      // console.log("\r\n---------------------------- calendar.rows -----------------------------")
      // console.log(calendar.rows)
      // console.log("------------------------------------------------------------------------\r\n")
      this.saveOutputFile(calendar)
      console.log("CSV file saved.")
    }
    else {
      if (calendar.layout > 0) {
        console.log('Calendar parsing done, but result is empty.')
      }
      else {
        console.log('Unsupported calendar layout: cannot process.')
      }
    }
  }
  //---------------------------------------------------------------------------

  /**
   * Calendar page scanner for layout type 1 (pre-2018)
   * @param {Object} page - the Puppetter page object to be scanned
   * @returns {Array} the list of calendar rows extracted from the page
   */
  async processCalendarLayout1(page) {
    await page.waitForSelector('.calendario-container')
    // DEBUG
    // console.log("processCalendarLayout1: before page.evaluate");
    return await page.evaluate(() => {
      const monthNames = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic']
      var monthName = null, monthNumber = 0, yearName = null
      var resultRows = []

      // Loop on all the event containers and add a row to the resulting calendar:
      Array.from(document.querySelectorAll('.calendario-container > *'))
        .forEach(node => {
          if (node.className == 'mesi') {
            var dateTokens = node.innerText.split(' ') // e.g. "Gennaio 2013"
            monthName = dateTokens[0]
            monthNumber = monthNames.indexOf(monthName.substring(0, 3)) + 1
            yearName = dateTokens[1]
          }
          else if (node.className == 'calendario') {
            const dates = node.querySelector('.calendario_all p.data') ? node.querySelector('.calendario_all p.data').innerText : '---' // == '---' when cancelled
            const isCancelled = (dates == '---') || (node.querySelector('.calendario_all p.risultati a') && node.querySelector('.calendario_all p.risultati').innerText.includes('Annull'))
            const name = node.querySelector('.calendario_all p.titolo') ? node.querySelector('.calendario_all p.titolo').innerText : null
            const manifestURL = node.querySelector('.calendario_all p.titolo a') ? node.querySelector('.calendario_all p.titolo a').href : null
            const meetingUrl = node.querySelector('.calendario_all p.risultati a') ? node.querySelector('.calendario_all p.risultati a').href : null
            const place = node.querySelector('.calendario_all p.luogo') ? node.querySelector('.calendario_all p.luogo').innerText : null
            const composedDate = isCancelled ? null : `${dates}/${monthNumber}`

            // Add the extracted calendar row to the list:
            resultRows.push({
              startURL: manifestURL, // Always serialize the manifestURL if present
              date: composedDate,
              isCancelled: isCancelled,
              name: name,
              place: place,
              meetingUrl: meetingUrl,
              year: yearName
            })
          }
        })
      return resultRows
    })
  }

  /**
   * Calendar page scanner for layout type 2 (2018+, minus current season tabular report page)
   * @param {String} baseURL - the browsed calendar url, used also as base for composing the result page sub-request
   * @param {Object} page - the Puppetter page object to be scanned
   * @returns {Array} the list of calendar rows extracted from the page
   */
  async processCalendarLayout2(baseURL, page) {
    await page.waitForSelector('.nat_eve_list .nat_eve_container')
    const totRowCount = await page.$$eval('.nat_eve_list[data-id="lista"] > .nat_eve_container', (calCells) => { return calCells.length })
                                  .catch((err) => { console.log(err.toString()) })
    console.log(`Found ${totRowCount} calendar rows`)
    // DEBUG
    // console.log("processCalendarLayout2: before page.evaluate");
    return await page.evaluate((baseURL) => {
      const monthNames = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic']
      const regEx = /annull/gi
      var resultRows = []

      // Loop on all the event containers and add a row to the resulting calendar:
      document.querySelectorAll('.nat_eve_list[data-id="lista"] > .nat_eve_container')
              .forEach(node => {
                const name = node.querySelector('.nat_eve_title').innerText
                let sYear = ''
                const isoDates = Array.from(node.querySelectorAll('.nat_eve_dates .nat_eve_date'))
                                      .map(dateNode => {
                  sYear = dateNode.querySelector('.nat_eve_y').innerText.padStart(4, '2000')
                  const monthName = dateNode.querySelector('.nat_eve_m').innerText
                  const monthNumber = monthNames.indexOf(monthName.substring(0, 3)) + 1
                  const sMonth = monthNumber.toString().padStart(2, '0')
                  const sDay = dateNode.querySelector('.nat_eve_d').innerText.padStart(2, '0')
                  return `${sYear}-${sMonth}-${sDay}`
                })
                // Usually the following can be retrieved from the header in the details page:
                // const poolLength = node.querySelector('.info > .nat_eve_pool').innerText // (i.e.: "Vasca da 25m")
                const places = Array.from(node.querySelectorAll('.info > .nat_eve_loc')).map(node => { return node.innerText }) // (i.e.: ["Roma (RM)", "Viterbo (VT)"])
                /*
                   *** NOTES on meeting results URL: ***
                   For this type of calendar layout (the "type #2"), the meeting results page can be obtained in 2 ways:

                   1) Using a simple GET request on the same calendar page as base URL + a special anchor stored in the dataset 'alias' field of the button link,
                      like this (acts as a composed backend query):
                      -- Example: --
                      baseURL= "https://www.federnuoto.it/home/master/circuito-supermaster/archivio-2012-2021/stagione-2019-2020.html"
                      anchorURL = `risultati/136714:19-trofeo-citt%C3%A0-di-verolanuova.html` => node.querySelector('.nat_eve .nat_eve_results .results').dataset['alias']
                      GET meetingUrl => `${baseURL}#/${anchorURL}`

                   2) With POST-AJAX call that which replies with in-page changes, using these params:
                      - solr[id_settore]: 1     => (fixed)
                      - solr[id_tipologia_1]: 2 => (fixed)
                      - solr[stagione]: 2021    => from season first year
                      - solr[id_evento]: 139714 => from `node.querySelector('.nat_eve .nat_eve_results .results').dataset['id']`
                      => POST base url: example: "https://www.federnuoto.it/index.php?option=com_solrconnect&currentpage=2&view=risultati&format=json"
                         (the actual payload for the POST must be composed as ResultsCrawler does for each meeting page)
                */
                const anchorURL = node.querySelector('.nat_eve_results .results').dataset['alias']
                const isCancelled = regEx.test(name) // Usually the "cancelled" flag is added to the title itself, either in front or at the end

                // Add the extracted calendar row to the list:
                resultRows.push({
                  startURL: baseURL,
                  date: isoDates.join('; '),
                  isCancelled: isCancelled,
                  name: name,
                  place: places.join('; '),
                  meetingUrl: `${baseURL}#/${anchorURL}`,
                  year: sYear
                })
              })
      return resultRows
    }, baseURL)
  }

  /**
   * Calendar page scanner for layout type 3 ("current season")
   * @param {String} baseURL - the browsed url (for serializing purposes)
   * @param {Object} page - the Puppetter page object to be scanned
   * @returns {Array} the list of calendar rows extracted from the page
   */
  async processCalendarLayout3(baseURL, page) {
    const totRowCount = await page.$$eval('table.records.ris-style tr', (calRows) => { return calRows.length }).catch(() => { return 0 })
    console.log(`Found ${totRowCount} calendar rows`)
    console.log('Injecting scripts...')
    await page.addScriptTag({ content: CrawlUtil.normalizeText.toString() })
    // DEBUG
    console.log("processCalendarLayout3: before page.evaluate");

    return await page.evaluate((baseURL) => {
      var resultRows = []
      Array.from(document.querySelectorAll('table.records.ris-style'))
           .forEach((yearTable) => {
        const meetingYear = yearTable.caption.innerText
        const tableRowNodes = $(yearTable).children('tbody').first().children('tr').toArray()
        tableRowNodes.forEach((tableRowNode) => {
          const urlNode = $(tableRowNode).children().last().children()[0]
          const date = $(tableRowNode).children().toArray()[0].innerText
          const name = normalizeText($(tableRowNode).children().toArray()[1].innerText)
          const place = normalizeText($(tableRowNode).children().toArray()[2].innerText)
          const meetingUrl = (urlNode === undefined) ? '' : urlNode.href
          const isCancelled = $(tableRowNode).children().toArray()[3].innerText

          resultRows.push({
            startURL: baseURL,
            date: date,
            isCancelled: isCancelled,
            name: name,
            place: place,
            meetingUrl: meetingUrl,
            year: meetingYear
          })
        })
      })
      return resultRows
    }, baseURL)
  }
  //---------------------------------------------------------------------------

  /**
   * Runs the Calendar crawler.
   *
   * Retrieves the list of current season Meetings from the FIN website,
   * producing a CSV file with a line for each meeting.
   *
   * Resulting file sample (1 line required header + 1 data line):
   * ----8<----
   * sourceURL,date,isCancelled,name,place,meetingUrl,year
   * <urlContainingThisData>,dd(-dd)/mm,['canc*'],Meeting Name,City (or Cities separated by ;),urlWithResultsList,YYYY
   * ----8<----
   *
   * @returns {Promise} a Promise that resolves when the crawling is done
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
        console.log("\r\n*** Calendar Crawler ***\r\n")
        CrawlUtil.updateStatus(`Processing Season ${this.seasonId}, ${this.startURL}...`)
        await this.processPage(this.startURL, browser)
        await browser.close()
        CrawlUtil.updateStatus(`Done.`, 'OK, done, idle')
        return true
      })
      .catch((error) => {
        CrawlUtil.updateStatus(`${error.toString()}`, 'ERROR')
        return false
      });
  }
  //---------------------------------------------------------------------------

  /**
   * Returns the output filename given the current season ID specified in the constructor.
   * @param {Integer} calendarLayoutType - the code type of the calendar layout
   * @returns {string} the output basename for the file
   */
  getOutputFilename(calendarLayoutType) {
    const calendarBaseName = calendarLayoutType == 3 ? 'FIN-current-meetings' : 'FIN-calendar';
    return `${CrawlUtil.dateStamp()}-${this.seasonId}-${calendarLayoutType}-${calendarBaseName}.csv`
  }

  /**
   * Serializes the specified calendar contents to a CSV file.
   * @param {Object} calendarObject - the calendar object holding the layout type and the rows
   */
  saveOutputFile(calendarObject) {
    // DEBUG
    // console.log('Extracted calendar:', calendarObject)
    let baseName = this.getOutputFilename(calendarObject.layout)
    this.outputCalendarPathname = `${CrawlUtil.assertDestFolder(CrawlUtil.calendarNewFolder, this.seasonId)}/${baseName}`
    CrawlUtil.updateStatus(`Generating '${this.outputCalendarPathname}'...`)

    var csvContents = "startURL,date,isCancelled,name,place,meetingUrl,year\r\n"
    calendarObject.rows.forEach(row => {
      csvContents += `${row.startURL},${row.date},${row.isCancelled},${row.name},${row.place},${row.meetingUrl},${row.year}\r\n`
    })

    Fs.writeFile(this.outputCalendarPathname, csvContents, 'utf8', function (err) {
      if (err) {
        console.log(`An error occurred while writing the calendar to '${baseName}'.`)
        return CrawlUtil.updateStatus(`CSV file output failed: ${err.toString()}`, 'ERROR')
      }
    });
    CrawlUtil.updateStatus(`Saved "${baseName}"`)
  }
  //---------------------------------------------------------------------------
}
//-----------------------------------------------------------------------------

module.exports = CalendarCrawler
