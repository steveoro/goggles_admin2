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
 * > const crawler = new CalendarCrawler(seasonId, startURL, ...);
 * > crawler.run();
 */
class CalendarCrawler {
  /**
   * Constructs a new CalendarCrawler instance.
   *
   * The CalendarCrawler is able to detect the actual layout type from the contents of the crawled page.
   *
   * @param {Integer} seasonId - the season ID of the calendar to crawl; defaults to 212 (FIN 2021/2022)
   * @param {String} startURL - starting URL for the crawler
   * @param {String} subMenuText - text to be searched for inside the sub-menu node item (item to be selected)
   * @param {String} yearText - text to be searched in the item list from the clicked sub-menu (typically from the archive section)
   */
  constructor(seasonId = 212, startURL, subMenuText, yearText) {
    this.seasonId = seasonId
    this.startURL = startURL
    this.subMenuText = subMenuText
    this.yearText = yearText
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
      layoutType = await page.$eval('section#component .nat_eve_list.risultati .nat_eve', () => { return 2 }).catch(() => { return 0 })
    }
    if (layoutType == 0) {
      // Table layout ("Riepilogo" / different start URL, only for current season):
      layoutType = await page.$eval('table.records.ris-style', () => { return 3 }).catch(() => { return 0 })
    }
    return layoutType
  };
  //---------------------------------------------------------------------------

  /*
  // *** Notes about simulated "internal browsing" for FIN site / Calendar retrieval ***

  // This is required because currently the site disables accessing direct links and the
  // document.location[source] must come from the domain.

  // 1. Start opening page at the base start URL ("https://www.federnuoto.it/home/master.html")
  //    Each sub-page where the calendar is may be different. The ending result must be the page stored in the calendar
  //    as base URL to retrieve the results.

  // 2. Open side menu w/ links to access submenus & calendars:
  document.querySelector(".module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent span").click()

  // 3. Click on an item of interest:
  // 3.a) "Eventi" ("current events" using layout 2)
  $('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li a:contains("Eventi")')[0].click()

  // 3.b) "Riepilogo eventi" ("current events" using layout 3 - table-like)
  $('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li a:contains("Riepilogo Eventi")')[0].click()

  // 3.c) "Archivio 2012/20xx" (old archive of result lists, each using layout 2)
  // 3.c.1) for this one, open the sub menu:
  $('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li span:contains("Archivio 2012-")')[0].click()

  // 3.c.2) select a season from the archive:
  //        => CURRENTLY THE FOLLOWING EVENT WORKS EVEN IF THE ELEMENT IS NOT DISPLAYED <= (so, skip the above)
  $('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li span:contains("Archivio 2012-")')[0]

  var item = $('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li span:contains("Archivio 2012-")+ul').first().find('li:contains("2021/2022") a')[0]
  item.click()
  */

  /**
    * Asynch pageFunction for retrieving the FIN calendar from the list of current events
    * from the current season.
    * Supports 2018+ FIN website styling.
    * @param {String} baseURL - the browsed url (for serializing purposes)
    * @param {String} subMenuText - text to be searched for inside the sub-menu node item (item to be selected)
    * @param {String} yearText - text to be searched in the item list from the clicked sub-menu (typically from the archive section)
    * @param {Object} browser - a Puppeteer instance
    */
  async processPage(baseURL, subMenuText, yearText, browser) {
    // Create a new incognito browser context:
    const context = await browser.createIncognitoBrowserContext()
    // Create a new page in a pristine context:
    const page = await context.newPage()
    await page.setViewport({ width: 1200, height: 800 })
    await page.setUserAgent('Mozilla/5.0')
    page.on('load', () => { console.log('=> Page fully loaded.') });

    CrawlUtil.updateStatus(`Browsing to ${baseURL} (${subMenuText}-> ${yearText})...`)
    await page.goto(baseURL, { waitUntil: 'load' })

    // Make the cookies dialog disappear:
    await this.cookiesDialogDismiss(page)

    CrawlUtil.updateStatus(`Waiting for side menu to become visible...`)
    await page.waitForSelector('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent').catch((err) => { console.log(err.toString()) })
    // DEBUG
    // await page.screenshot({ path: './screenshot-1.png' });
    CrawlUtil.updateStatus(`Clicking on side menu...`)

    // Click on the sub-menu item to reach the internal page with the calendar:
    var resultsStartURL = ''
    switch(subMenuText) {
      case 'Eventi':
        resultsStartURL = 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html'
        await page.evaluate(() => {
          var nodeArray = Array.from(document.querySelectorAll('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li a'))
          var item = nodeArray.filter(node => { console.log(node.innerHTML); return node.innerHTML.startsWith('Eventi') })[0]
          item.click()
        })
        break;

      case 'Riepilogo Eventi':
        resultsStartURL = 'https://www.federnuoto.it/home/master/circuito-supermaster/riepilogo-eventi.html'
        await page.evaluate(() => {
          var nodeArray = Array.from(document.querySelectorAll('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li a'))
          var item = nodeArray.filter(node => { console.log(node.innerHTML); return node.innerHTML.startsWith('Riepilogo Eventi') })[0]
          item.click()
        })
        break;

      default: // "Archivio 2012-..."
        resultsStartURL = `https://www.federnuoto.it/home/master/circuito-supermaster/archivio-2012-2022/stagione-${yearText.replace('/', '-')}.html`
        console.log(`Using 'archived' calendar page type '${yearText}'`)
        await page.evaluate((yearText) => {
          var nodeArray = Array.from(document.querySelectorAll('.module-menu_acc_interno ul.mixedmenu li.divider.deeper.parent ul.nav-child li a'))
          var item = nodeArray.filter(node => { console.log(node.innerHTML); return node.innerHTML.endsWith(`${yearText}`) })[0]
          item.click()
        }, yearText)
    }

    await page.waitForNetworkIdle({ idleTime: 2000 })
    // DEBUG
    await page.screenshot({ path: './screenshot-2.png' });

    CrawlUtil.updateStatus('Detecting layout type...')
    const layoutType = await this.calendarLayoutDetector(page)
    CrawlUtil.updateStatus(`Detected layout ${layoutType}`)

    var calendar = { layout: layoutType, rows: [] }
    if (layoutType == 1) {
      calendar.rows = await this.processCalendarLayout1(page)
    }
    else if (layoutType == 2) {
      calendar.rows = await this.processCalendarLayout2(resultsStartURL, page)
    }
    else if (layoutType == 3) {
      calendar.rows = await this.processCalendarLayout3(resultsStartURL, page)
    }
    // (ELSE: Unknown layout, skip processing)

    if (calendar.layout > 0 && calendar.rows && calendar.rows.length > 0) {
      console.log(`Calendar parsing done (${calendar.rows.length} rows).`)
      // DEBUG
      // console.log("\r\n---------------------------- calendar.rows -----------------------------")
      // console.log(calendar.rows)
      // console.log("------------------------------------------------------------------------\r\n")
      this.saveOutputFile(calendar)
    }
    else {
      if (calendar.layout > 0) {
        CrawlUtil.updateStatus('Calendar parsing done, but result is empty.')
      }
      else {
        CrawlUtil.updateStatus('Unsupported calendar layout: cannot process.')
      }
    }
  }
  //---------------------------------------------------------------------------

  /**
   * Dismisses the annoying cookies dialog due to GDPR.
   * @param {Object} page - the Puppetter page object
   */
  async cookiesDialogDismiss(page) {
    CrawlUtil.updateStatus(`Getting rid of the cookies dialog...`)
    await page.waitForNetworkIdle({ idleTime: 1000 })
    await page.evaluate(() => {
      if (document.querySelector('#CybotCookiebotDialogBodyButtonDecline')) {
        document.querySelector('#CybotCookiebotDialogBodyButtonDecline').click()
      }
    })
  }

  /**
   * Scroll to the end until no more content is being loaded.
   * @param {Object} page - the Puppetter page object
   */
  async autoScrollToEnd(page) {
    let originalOffset = 0;
    while (true) {
      await page.evaluate('window.scrollBy(0, document.body.scrollHeight)');
      await page.waitForTimeout(650);
      let newOffset = await page.evaluate('window.pageYOffset');
      if (originalOffset === newOffset) {
        break;
      }
      originalOffset = newOffset;
      CrawlUtil.updateStatus('Scrolling...')
    }

    // DEBUG:
    // await page.screenshot({ path: './calendar.png', fullPage: true });
  }
  //---------------------------------------------------------------------------


  /**
   * Calendar page scanner for layout type 1 (pre-2018)
   * @param {Object} page - the Puppetter page object to be scanned
   * @returns {Array} the list of calendar rows extracted from the page
   */
  async processCalendarLayout1(page) {
    await page.waitForSelector('.calendario-container')

    CrawlUtil.updateStatus('Scrolling to the end of content...')
    await this.autoScrollToEnd(page)
    // DEBUG
    CrawlUtil.updateStatus('Processing layout 1...')

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
            const name = node.querySelector('.calendario_all p.titolo') ? node.querySelector('.calendario_all p.titolo').innerText.trim() : null
            const manifestURL = node.querySelector('.calendario_all p.titolo a') ? node.querySelector('.calendario_all p.titolo a').href : null
            const meetingUrl = node.querySelector('.calendario_all p.risultati a') ? node.querySelector('.calendario_all p.risultati a').href : null
            const place = node.querySelector('.calendario_all p.luogo') ? node.querySelector('.calendario_all p.luogo').innerText.trim() : null
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

    CrawlUtil.updateStatus('Scrolling to the end of content...')
    await this.autoScrollToEnd(page)
    // DEBUG
    CrawlUtil.updateStatus('Processing layout 2...')

    const totRowCount = await page.$$eval('.nat_eve_list[data-id="lista"] > .nat_eve_container', (calCells) => { return calCells.length })
                                  .catch((err) => { console.log(err.toString()) })
    CrawlUtil.updateStatus(`Found ${totRowCount} calendar rows`)

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
                      baseURL= "https://www.federnuoto.it/home/master/circuito-supermaster/archivio-2012-2022/stagione-2019-2020.html"
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
    // DEBUG
    CrawlUtil.updateStatus('Processing layout 3...')

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
        await this.processPage(this.startURL, this.subMenuText, this.yearText, browser)
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
   *
   * The difference between this method and the more generic CrawlUtil.writeCSVData() is that the
   * latter expects the dates to be in ISO format, while this method simply stores
   * the data as it is extracted (date formatting varies depending on the crawled layout type).
   *
   * This is perfect for first-time data extraction, as most of the data will be normalized during
   * consumption and eventually re-saved by CrawlUtil.writeCSVData() only after being "normalized".
   *
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
      csvContents += `"${row.startURL}","${row.date}",${row.isCancelled},"${row.name}","${row.place}","${row.meetingUrl}",${row.year}\r\n`
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
