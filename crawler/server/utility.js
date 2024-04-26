/*
 * Stand-alone generic crawler utility functions.
 *
 * -- Note: --
 * Install all modules enlisted below with 'npm install <package-name> --save', except node.js itself:
 *  > sudo apt-get install nodejs
 */
const Fs = require('fs')
const Csv = require('csv-parser')
const GetStream = require('get-stream')

// Used by downloadFile:
const { Readable } = require('stream');
const { finished } = require('stream/promises');
const path = require("path");

// Shared configuration constants:
const calendarNewFolder = "data/calendar.new";
const calendarDoneFolder = "data/calendar.done";
const resultsNewFolder = "data/results.new";
const resultsDoneFolder = "data/results.done";
const pdfsFolder = "data/pdfs";
const manifestsFolder = "data/manifests";
const statusFilename = "crawler-status.json";
//-----------------------------------------------------------------------------

/**
 * @returns {String} the current date & time as a string timestamp
 */
function fullTimeStamp() {
  return (new Date()).toISOString().split('.')[0].replaceAll('-', '').replaceAll(':', '').replaceAll('T', '-')
}

/**
 * @returns {String} the current date (no time) as a condensed string timestamp
 */
function dateStamp() {
  return (new Date()).toISOString().split('T')[0].replaceAll('-', '')
}
//-----------------------------------------------------------------------------

/**
 * Strips a string of any quote, comma or newlines and tries to remove any other special characters
 * that may mess up the CSV or JSON parsing procedures.
 * All newlines are replaced with a '; '.
 *
 * @param {string} text - a string text
 * @returns {string} the "normalized" string text
 */
function normalizeText(text) {
  if (text) {
    return text.replaceAll(/\r?\n/ig, '; ')
      .replaceAll(/a\'/ig, 'à').replaceAll(/e\'/ig, 'è').replaceAll(/i\'/ig, 'ì')
      .replaceAll(/o\'/ig, 'ò').replaceAll(/u\'/ig, 'ù')
      .replaceAll(/&/ig, 'e').replaceAll(/,/ig, ' ')
      .replaceAll(/[*!£$%|/\\?<>'"`]/ig, '')
  }
  // Return an empty string if the input is null or undefined:
  return ''
}
//-----------------------------------------------------------------------------

/**
 * Reads & returns the parsed contents of a JSON file.
 * -- Synchronous & blocking --
 *
 * @param {string} pathName - the pathname of the file
 * @returns {Object} the parsed JSON file contents
 */
function readJSONFile(pathName) {
    if (!Fs.existsSync(pathName)) {
      return { status: 'no-file', detail: `File '${pathName}' not found.` }
    }

    var contents = Fs.readFileSync(pathName, 'utf8', (error, data) => {
      if (error) { return { status: error.name, detail: error.message, data: data } }
      return data
    })

  // Note: concurrent file updates from different thread may cause the file to be
  // seldomly corrupted (this can happen only for the status file)
  try {
    return JSON.parse(contents)
  }
  catch (error) {
    console.log('Error parsing the JSON file!')
    // Avoid keeping around files with corrupted data:
    if (Fs.existsSync(pathName)) {
      Fs.unlink(pathName, (err) => {
        if (err) throw err;
        console.log('Cleaning up: file removed.');
      })
    }
    return { status: error.name, detail: error.message, data: data }
  }
}

/**
 * Serializes the specified Object as a JSONified string on the destination pathname.
 * -- Synchronous & blocking --
 *
 * @param {Object} obj - the Object to be serialized
 * @param {String} destPathname - the destination pathname
 */
function writeJSONFile(destPathname, obj) {
  // Remove and overwrite any previous version:
  /*
  if (Fs.existsSync(destPathname)) {
    Fs.unlink(destPathname, (err) => { return console.log(err) })
  }
  */
  Fs.writeFileSync(destPathname, JSON.stringify(obj), 'utf8', (err) => {
    if (err) {
      console.log(`An error occurred while writing the object to ${destPathname}.`)
      return console.log(err)
    }
  });
}
//-----------------------------------------------------------------------------

/**
 * High-level helper that simply serializes the specified status object to a JSON status file.
 * -- Synchronous & blocking --
 *
 * @param {String} detail - the detailed status message to be serialized
 * @param {String} terseState - a short label for the current state object
 * @param {int} progress - the current progress of the current state
 * @param {int} total - the total number of steps in the current state
 * @returns {String} the specified `terseState` string
 */
function updateStatus(detail = '', terseState = 'OK, running', progress = 0, total = 0) {
  console.info(`[crawler] ${detail}${total > 0 ? ` (${progress}/${total})` : ''}`)
  const status = {
    timestamp: fullTimeStamp(),
    status: terseState,
    detail: detail,
    progress: progress,
    total: total
  }
  const fullPathname = `${process.cwd()}/${statusFilename}`
  writeJSONFile(fullPathname, status)
  return terseState
}

/**
 * @returns {Object} the current status object read from the JSON status file.
 */
function readStatus() {
  const fullPathname = `${process.cwd()}/${statusFilename}`
  return readJSONFile(fullPathname)
}
//-----------------------------------------------------------------------------

/**
 * Makes sure the destination folder exists; creates it if missing.
 * Assumes the destination folder is the current working directory and the seasonId will be its subfolder.
 * Returns the overall string folder path (cwd / destFolder / seasonId).
 * -- Synchronous & blocking --
 *
 * @param {String} destFolder - the destination folder
 * @param {String} seasonId - the season identifier
 * @param {Boolean} debug - set this to true to enable additional debug output
 * @returns {String} the string folder path used as destination for any newly generated file.
 */
function assertDestFolder(destFolder, seasonId, debug = false) {
  const fullDestFolder = `${process.cwd()}/${destFolder}/${seasonId}`
  if (debug) { // DEBUG
    console.log(`Current folder........: ${process.cwd()}`)
    console.log(`Resulting dest. folder: ${fullDestFolder}`)
  }
  try {
    if (!Fs.existsSync(fullDestFolder)) {
      Fs.mkdirSync(fullDestFolder)
    }
  } catch (err) {
    console.error(err)
  }
  return fullDestFolder
}
//-----------------------------------------------------------------------------

/**
 * Assuming daysDate is in format `DD(-DD)?/MM`, possibly referring to multiple dates,
 * and year is in format 'YYYY', this returns an array of date strings in ISO format ('YYYY-MM-DD').
 *
 * @param {String} daysDate - a string containing the days date(s)
 * @param {String} year - a string containing the year
 * @returns {Array} an array of date strings in ISO format
 */
function parseDaysDate(daysDate, year) {
  if (!daysDate || !year) {
    // DEBUG
    // console.log(`parseDaysDate: returning []`)
    return []
  }
  // DEBUG
  // console.log(`parseDaysDate: '${daysDate}', '${year}'`)

  // Handle "<ISO>(; <ISO>)+" (multiple ISO) format:
  if (daysDate.includes('; ')) {
    // DEBUG
    // console.log(`parseDaysDate: returning [${daysDate.split('; ').join(', ')}]`)
    return daysDate.split('; ')
  }
  // Handle single "<ISO>" format:
  if (daysDate.includes('-') && !daysDate.includes('/')) {
    // DEBUG
    // console.log(`parseDaysDate: returning [${daysDate}]`)
    return [daysDate]
  }

  // Handle variable "dd(-dd)*/mm" format:
  const dateTokens = daysDate && daysDate.includes('/') ? daysDate.split('/') : []
  const days = dateTokens[0] ? dateTokens[0].split('-') : []
  const fullYear = year ? year.toString().padStart(4, '2000') : (new Date()).toISOString().split('-')[0]

  return days.map(day => {
    const sYear = fullYear
    const sMonth = dateTokens.length > 1 ? dateTokens[1].padStart(2, '0') : 'xx'
    const sDay = day ? day.padStart(2, '0') : 'xx'
    // DEBUG
    // console.log(`return => sYear: '${sYear}' / sMonth: '${sMonth}' / sDay: '${sDay}' -- dateTokens: '${dateTokens}'`)
    return `${sYear}-${sMonth}-${sDay}`
  })
}

/**
 * Reads a CSV source file containing a URL list with the following header columns:
 *
 * - sourceURL: starting source URL, crawled to retrieve the data
 * - dates: date of the event, typically in the format 'DD/MM' or 'D1-D2/MM' when spanning multiple days
 * - isCancelled: /canc/i, /annull/ or anything else for true; empty or spaces if not cancelled
 * - name: full name of the meeting
 * - place: city names, separated by "; " when spanning multiple locations
 * - meetingUrl: URL of the meeting results page
 * - year: year of the event ('YYYY')
 *
 * Sample CSV format:
 * ----8<----
 * startURL,date,isCancelled,name,place,meetingUrl,year
 * <ignoredURL>,dd(-dd)/mm,['canc*'],Meeting Name,City (or Cities separated by ;),urlWithResultsList,YYYY
 * ----8<----
 *
 * @param {*} filePath - the path to the CSV file
 * @returns {Array} an array of objects with the parsed CSV data
 */
async function readCSVData(filePath) {
  const parseStream = Csv({ delimiter: ',' })
  const data = await GetStream.array(Fs.createReadStream(filePath).pipe(parseStream))
  return data.map(row => {
    if (row) {
      // DEBUG
      // console.log(row);
      return {
        url: row.meetingUrl,
        name: normalizeText(row.name),
        dates: parseDaysDate(row.date, row.year),
        year: row.year,
        places: row.place ? row.place.split('; ') : [],
        cancelled: row.isCancelled == 'true' || row.isCancelled == 'canc'
      }
    }

    return null // return a null object if the row is empty
  })
}

/**
 * Serializes the specified Array as a CSV file on the destination pathname.
 *
 * Assumes each object in the array has the following properties:
 * - url: the meeting url
 * - name: the meeting name
 * - dates: an array of date strings in ISO format
 * - year: the year of the meeting
 * - places: an array of city names
 * - cancelled: true if the meeting is cancelled
 *
 * The resulting CSV file will have the following header columns:
 *
 * "startURL,date,isCancelled,name,place,meetingUrl,year"
 *
 * @param {Array} arr - the Array to be serialized
 * @param {String} destPathname - the destination pathname
 */
function writeCSVData(destPathname, arr) {
  var csvText = "startURL,date,isCancelled,name,place,meetingUrl,year\r\n"
  arr.map(item => {
    let startURL = '', // starting list URL, currently ignored
        isoDates = item.dates.join('; '),
        cancelled = item.cancelled ? 'canc' : '',
        name = item.name,
        places = item.places.join('; '),
        meetingUrl = item.url,
        year = item.year
    csvText = csvText.concat(`"${startURL}","${isoDates}",${cancelled},"${name}","${places}","${meetingUrl}",${year}\r\n`)
  })

  Fs.writeFile(destPathname, csvText, 'utf8', (err) => {
    if (err) {
      console.log("An error occurred while writing the contents to the file.")
      console.log(`CSV content:\r\n---8<---${csvText}\r\n---8<---`)
      return console.log(err)
    }
  });
}
//-----------------------------------------------------------------------------

/**
 * Queries the specified HTMLElement catching any errors.
 * @param {HTMLElement} htmlElement - the HTML element to be queried
 * @param {String} selector - the CSS selector to be used
 * @param {String} valueMethod - the method to be used to extract the value from the value node (default: `textContent`)
 * @param {Boolean} multiple - `true` => use a `querySelectorAll` call (default: `false` => use a simple `querySelector`)
 * @returns the value returned by the `valueMethod` applied on the resulting node, or null when not found
 */
const safeQuerySelector = (htmlElement, selector, valueMethod = 'textContent', multiple = false) => {
  try {
    if (multiple) {
      return htmlElement.querySelectorAll(selector)[valueMethod]
    }
    else {
      return valueMethod === 'textContent' ? htmlElement.querySelector(selector).textContent.trim() : htmlElement.querySelector(selector)[valueMethod]
    }
  }
  catch {
    return null
  }
}

/**
 * Safe getter for the text content of an HTML element, given a parent and a sub-selector.
 * @param {HTMLElement} htmlElement - the HTML element to be queried
 * @param {String} parentSelector - the parent selector
 * @param {String} textSelector - the sub-selector for the node that contains the text to be searched
 * @param {String} searchText - the text to search for
 * @param {String} subSelector - the sub-selector for the value node
 * @param {String} valueMethod - the method to be used to extract the value from the value node (default: `textContent`)
 * @param {Boolean} multiple - `true` => extract the second matching node (default: `false` => just the first match)
 * @returns the value returned by the `valueMethod` applied on the resulting node of the HTML element, or null when not found
 */
const safeFindHTMLContent = (htmlElement, parentSelector, textSelector, searchText, subSelector,
                             valueMethod = 'textContent', multiple = false) => {
  try {
    // Filter the nodes that can contain the search text as content:
    let subnodes = Array.from(htmlElement.querySelectorAll(parentSelector))
                        .find(el => el.querySelector(textSelector).textContent.includes(searchText))
    // If we want multiple results, just return the second child that matches the subSelector:
    if (multiple && subnodes.querySelectorAll(subSelector).length > 1) {
      return subnodes.querySelector(`:nth-child(2) ${subSelector}`)[valueMethod]
    }
    // By default, return the first child that matches the subSelector:
    else {
      return valueMethod === 'textContent' ? subnodes.querySelector(subSelector).textContent.trim() : subnodes.querySelector(subSelector)[valueMethod]
    }
  }
  catch {
    return null
  }
}
//-----------------------------------------------------------------------------

/**
 * Downloads a file from a given url.
 *
 * @param {String} url full URL for retrieving the file
 * @param {String} fileName the absolute full pathname for the stored file (assumed to be existing)
 */
const downloadFile = (async (url, fileName) => {
  const res = await fetch(url);
  // DEBUG:
  // console.log(`downloadFile('${url}', '${fileName}')`)
  const fileStream = Fs.createWriteStream(fileName, { flags: 'w+' });
  await finished(Readable.fromWeb(res.body).pipe(fileStream));
});
//-----------------------------------------------------------------------------

module.exports = {
  calendarNewFolder, calendarDoneFolder,
  pdfsFolder, manifestsFolder,
  resultsNewFolder, resultsDoneFolder,
  statusFilename,
  fullTimeStamp, dateStamp, normalizeText,
  readJSONFile, writeJSONFile,
  readStatus, updateStatus,
  assertDestFolder,
  parseDaysDate,
  readCSVData, writeCSVData,
  safeQuerySelector, safeFindHTMLContent,
  downloadFile
}
//-----------------------------------------------------------------------------
