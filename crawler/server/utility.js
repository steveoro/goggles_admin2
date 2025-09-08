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
const calendarNewFolder = path.join(__dirname, '../data/calendar.new');
const calendarDoneFolder = path.join(__dirname, '../data/calendar.done');
const resultsNewFolder = path.join(__dirname, '../data/results.new');
const resultsDoneFolder = path.join(__dirname, '../data/results.done');
const pdfsFolder = path.join(__dirname, '../data/pdfs');
const manifestsFolder = path.join(__dirname, '../data/manifests');
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
    // 1. Any hyphenated character at the end of a word should be considered as an accented word;
    // 2. replace all multiple spaces with a single one;
    return text.trim().replaceAll(/\r?\n/ig, '; ')
      .replaceAll(/(a\')(?!\w)/ig, 'à').replaceAll(/(e\')(?!\w)/ig, 'è').replaceAll(/(i\')(?!\w)/ig, 'ì')
      .replaceAll(/(o\')(?!\w)/ig, 'ò').replaceAll(/(u\')(?!\w)/ig, 'ù')
      .replaceAll(/\s+/g, ' ')
      .replaceAll(/[*!£$%|/\?<>"`]/ig, '')
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
 * Reads & returns the contents of a text file.
 * -- Synchronous & blocking --
 *
 * @param {string} pathName - the pathname of the file
 * @returns {string} the file contents
 */
function readTextFile(pathName) {
    if (!Fs.existsSync(pathName)) {
      return `File '${pathName}' not found.`
    }
    return Fs.readFileSync(pathName, 'utf8');
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
    const fullDestFolder = path.resolve(process.cwd(), destFolder, seasonId.toString());
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
  readJSONFile, writeJSONFile, readTextFile,
  readStatus, updateStatus,
  assertDestFolder,
  parseDaysDate,
  readCSVData, writeCSVData,
  safeQuerySelector, safeFindHTMLContent,
  downloadFile,
  splitFullName: (fullName) => {
    if (!fullName) return { lastName: '', firstName: '' };
    const parts = fullName.trim().split(/\s+/);
    const lastName = parts.shift() || '';
    const firstName = parts.join(' ');
    return { lastName, firstName };
  },

  /**
   * Normalizes text by removing invisible Unicode characters and converting &nbsp; to spaces.
   * @param {string} text - The text to normalize.
   * @returns {string} Normalized text with proper spacing.
   */
  normalizeUnicodeText: (text) => {
    if (!text) return '';
    return text
      // Convert HTML entities to spaces
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&quot;/gi, '"')
      // Remove zero-width characters and other invisible Unicode
      .replace(/[\u200B-\u200D\uFEFF]/g, '')
      // Normalize Unicode (NFC normalization)
      .normalize('NFC')
      // Replace all Unicode whitespace with regular spaces
      .replace(/\s+/gu, ' ')
      // Trim and clean up
      .trim();
  },

  /**
   * Parses the event description string to extract structured information.
   * @param {string} description - The event description (e.g., "100 m Rana - Serie").
   * @param {string} gender - The event gender ('FEMMINE', 'MASCHI', 'MISTO', etc.).
   * @returns {object} An object containing eventCode, eventGender, eventLength, eventStroke, eventDescription, and relay.
   */
  parseEventInfoFromDescription: (description, gender) => {
    const info = {
      eventCode: '',
      eventGender: 'N/A',
      eventLength: '',
      eventStroke: '',
      eventDescription: '',
      relay: false
      // Note: eventDate is NOT initialized here - it should only be added when available
    }
    if (!description) return info

    // Normalize Unicode text to handle &nbsp; and invisible characters
    const normalizedDescription = module.exports.normalizeUnicodeText(description);
    const normalizedGender = gender ? module.exports.normalizeUnicodeText(gender) : '';
    
    console.log(`[DEBUG] Original description: "${description}"`);
    console.log(`[DEBUG] Normalized description: "${normalizedDescription}"`);
    console.log(`[DEBUG] Original gender: "${gender}"`);
    console.log(`[DEBUG] Normalized gender: "${normalizedGender}"`);

    // 1.1. Normalize eventGender: F for female, M for male, X for mixed
    if (normalizedGender) {
      const genderUpper = normalizedGender.toUpperCase()
      if (genderUpper.includes('FEM') || genderUpper === 'F') {
        info.eventGender = 'F'
      } else if (genderUpper.includes('MAS') || genderUpper === 'M') {
        info.eventGender = 'M'
      } else if (genderUpper.includes('MIST') || genderUpper.includes('MIX') || genderUpper === 'X') {
        info.eventGender = 'X'
      }
    }

    // 1.2. Split eventDescription at " - " and use first part (use normalized text)
    const descriptionParts = normalizedDescription.split(' - ')
    info.eventDescription = descriptionParts[0].trim()

    // 1. Split the eventDescription using regexp to extract eventLength and stroke label
    // Pattern: /((?>[468]x)?\d{2,4})\sm\s(.+$)/i
    console.log(`[DEBUG] Parsing eventDescription: "${info.eventDescription}"`);
    const eventMatch = info.eventDescription.match(/((?:[468]x)?\d{2,4})\s*m\s(.+$)/i)
    console.log(`[DEBUG] Event match result:`, eventMatch);
    if (eventMatch) {
      const lengthPart = eventMatch[1] // e.g., "4x50", "200", "100"
      const strokeLabel = eventMatch[2].trim() // e.g., "STILE LIBERO", "RANA", "MISTI"
      
      // Check if it's a relay (contains "x")
      info.relay = lengthPart.toLowerCase().includes('x')
      info.eventLength = lengthPart
      
      // 2. Convert stroke label to eventStroke using improved logic
      const strokeLabelUpper = strokeLabel.toUpperCase()
      if (/rana/i.test(strokeLabelUpper)) {
        info.eventStroke = 'RA'
      } else if (/dors/i.test(strokeLabelUpper)) {
        info.eventStroke = 'DO'
      } else if (/stil/i.test(strokeLabelUpper)) {
        info.eventStroke = 'SL'
      } else if (/farf|delf/i.test(strokeLabelUpper)) {
        info.eventStroke = 'FA'
      } else if (/mist/i.test(strokeLabelUpper)) {
        info.eventStroke = 'MI'
      } else {
        info.eventStroke = '' // null/not supported
      }
      
      // 3. Generate eventCode = eventLength + eventStroke
      if (info.eventStroke) {
        info.eventCode = info.eventLength + info.eventStroke
      }
    }
    
    return info
  },

  /**
   * Parses a partial event date and combines it with the meeting's date range to get a full ISO date.
   * @param {string} eventDateStr - The partial date string (e.g., "28/06").
   * @param {string} meetingDatesStr - The meeting's date range (e.g., "24-29 GIUGNO 2025").
   * @returns {string|null} The ISO-formatted date string (e.g., "2025-06-28") or null.
   */
  parseEventDate: (eventDateStr, meetingDatesStr) => {
    if (!eventDateStr || !meetingDatesStr) return null

    const yearMatch = meetingDatesStr.match(/\d{4}/)
    if (!yearMatch) return null
    const year = yearMatch[0]

    const dateParts = eventDateStr.split('/')
    if (dateParts.length < 2) return null
    const day = dateParts[0]
    const month = dateParts[1]

    return `${year}-${month}-${day}`
  },

  /**
   * Parses place and dates from a URL with format like:
   * "https://<main_site_domain>/<ignored_code>_<YYYY>_<MM>_<DD1>-<DD2>_<place>_web.<ext>"
   * @param {string} url - The URL to parse.
   * @returns {object} An object containing place and dates (ISO format comma-separated).
   */
  parsePlaceAndDatesFromUrl: (url) => {
    const result = {
      place: '',
      dates: ''
    }
    
    if (!url) return result
    
    // Extract filename from URL
    const urlParts = url.split('/')
    const filename = urlParts[urlParts.length - 1]
    
    // Remove extension
    const nameWithoutExt = filename.replace(/\.[^.]+$/, '')
    
    // Expected format: <ignored_code>_<YYYY>_<MM>_<DD1>-<DD2>_<place>_web
    const parts = nameWithoutExt.split('_')
    if (parts.length >= 6) {
      const year = parts[1]
      const month = parts[2]
      const dayRange = parts[3]
      const place = parts[4]
      
      // Parse day range (DD1-DD2)
      const dayParts = dayRange.split('-')
      if (dayParts.length === 2) {
        const day1 = dayParts[0].padStart(2, '0')
        const day2 = dayParts[1].padStart(2, '0')
        const monthPadded = month.padStart(2, '0')
        
        result.place = place
        result.dates = `${year}-${monthPadded}-${day1},${year}-${monthPadded}-${day2}`
      }
    }
    
    return result
  },

  /**
   * Enhanced name extraction that properly separates lastName and firstName.
   * Uses &nbsp; as the primary delimiter, with fallback to space-based splitting.
   * @param {string} fullName - The full name string (may contain &nbsp; entities).
   * @returns {object} An object with lastName and firstName properties.
   */
  extractNameParts: (fullName) => {
    if (!fullName) return { lastName: '', firstName: '' };
    
    // First normalize the text to handle HTML entities and invisible characters
    const normalizedName = module.exports.normalizeUnicodeText(fullName);
    
    // Try to split by &nbsp; first (the most reliable delimiter)
    if (normalizedName.includes('\u00A0')) {
      const parts = normalizedName.split('\u00A0');
      if (parts.length >= 2) {
        // Everything before the last &nbsp; is lastName, everything after is firstName
        const lastSpaceIndex = normalizedName.lastIndexOf('\u00A0');
        const lastName = normalizedName.substring(0, lastSpaceIndex).trim();
        const firstName = normalizedName.substring(lastSpaceIndex + 1).trim();
        return { lastName, firstName };
      }
    }
    
    // Fallback to space-based splitting if no &nbsp; found
    const parts = normalizedName.split(/\s+/);
    if (parts.length === 1) {
      return { lastName: parts[0], firstName: '' };
    } else if (parts.length === 2) {
      return { lastName: parts[0], firstName: parts[1] };
    } else {
      // For multiple parts, assume last word is firstName, rest is lastName
      const firstName = parts[parts.length - 1];
      const lastName = parts.slice(0, -1).join(' ');
      return { lastName, firstName };
    }
  },

  /**
   * Creates a unique key for a swimmer.
   *
   * Unified signature with backward compatibility:
   * - Preferred: createSwimmerKey(gender, lastName, firstName, year, team)
   * - Back-compat (no gender): createSwimmerKey(lastName, firstName, year, team)
   *
   * Behavior:
   * - When gender is provided and is not 'X' (mixed), it is prefixed to the key: "G|last|first|year|team".
   * - When gender is omitted, null/empty, or 'X', the key is genderless: "last|first|year|team".
   */
  createSwimmerKey: (...args) => {
    let gender = null, lastName, firstName, year, team;
    if (args.length === 5) {
      [gender, lastName, firstName, year, team] = args;
    } else if (args.length === 4) {
      [lastName, firstName, year, team] = args;
      gender = null;
    } else {
      // Invalid arity; return a safe empty key
      return '';
    }

    const norm = (s) => (s || '').toString().replace(/\s+/g, ' ').trim();
    const g = norm(gender);
    const ln = norm(lastName);
    const fn = norm(firstName);
    const yr = norm(year);
    const tm = norm(team);

    if (g && g.toUpperCase() !== 'X') {
      return `${g}|${ln}|${fn}|${yr}|${tm}`;
    }
    // Gender omitted or 'X' -> genderless key
    return `${ln}|${fn}|${yr}|${tm}`;
  },

  /**
   * Backward-compatible alias for creating a genderless swimmer key.
   * Prefer using createSwimmerKey with optional gender instead.
   */
  createSwimmerKeyNoGender: (lastName, firstName, year, team) => {
    return module.exports.createSwimmerKey(lastName, firstName, year, team);
  },

  /**
   * Creates a unique key for a team.
   * @param {string} team - The team name.
   * @returns {string} A unique key for the team.
   */
  createTeamKey: (team) => {
    return team.replace(/\s+/g, ' ').trim()
  },

  /**
   * Creates a unique key for a relay result used to merge Heats and RIEPILOGO.
   * Uses a normalized identifier (prefer relayName, fallback to team), plus heat, lane and timing.
   * @param {string} relayName - The relay name (may be same as team or a truncated variant).
   * @param {string} team - The team name.
   * @param {string} heat - The heat number as string.
   * @param {string} lane - The lane number as string.
   * @param {string} timing - The overall timing string (e.g., 2'53.69).
   * @returns {string} A stable key for matching summary rows to heat rows.
   */
  createRelayKey: (relayName, team, heat, lane, timing) => {
    const base = (relayName && relayName.trim().length > 0) ? relayName : team;
    const norm = (base || '').replace(/\s+/g, ' ').trim();
    const h = (heat || '').toString().trim();
    const l = (lane || '').toString().trim();
    const t = (timing || '').replace(/\s+/g, ' ').trim();
    return `${norm}|H${h}|L${l}|T${t}`;
  },

  /**
   * Parses meeting dates from Italian format or comma-separated ISO dates and returns the first date in ISO format.
   * Handles formats like "24/29 giugno 2025", "15 marzo 2025", or "2025-06-24,2025-06-29".
   * @param {string} dateString - The date string in Italian format or comma-separated ISO dates.
   * @returns {string} The first meeting date in ISO format (YYYY-MM-DD) or empty string if parsing fails.
   */
  parseFirstMeetingDate: (dateString) => {
    if (!dateString) return '';
    
    // Check if it's already in comma-separated ISO format (e.g., "2025-06-24,2025-06-29")
    if (dateString.includes(',') && dateString.match(/^\d{4}-\d{2}-\d{2}/)) {
      return dateString.split(',')[0].trim(); // Return the first date
    }
    
    // Check if it's a single ISO date (e.g., "2025-06-24")
    if (dateString.match(/^\d{4}-\d{2}-\d{2}$/)) {
      return dateString;
    }
    
    // Italian month names to numbers mapping
    const monthMap = {
      'gennaio': '01', 'febbraio': '02', 'marzo': '03', 'aprile': '04',
      'maggio': '05', 'giugno': '06', 'luglio': '07', 'agosto': '08',
      'settembre': '09', 'ottobre': '10', 'novembre': '11', 'dicembre': '12'
    };
    
    // Match patterns like "24/29 giugno 2025" or "15 marzo 2025"
    const datePattern = /(\d{1,2})(?:\/(\d{1,2}))? (\w+) (\d{4})/;
    const match = dateString.match(datePattern);
    
    if (match) {
      const day = match[1].padStart(2, '0');
      const monthName = match[3].toLowerCase();
      const year = match[4];
      const monthNum = monthMap[monthName];
      
      if (monthNum) {
        return `${year}-${monthNum}-${day}`;
      }
    }
    
    return '';
  },

  /**
   * Sanitizes a meeting name for use in filenames by replacing spaces with underscores
   * and removing invalid filename characters.
   * @param {string} meetingName - The meeting name to sanitize.
   * @returns {string} The sanitized meeting name suitable for filenames.
   */
  sanitizeForFilename: (meetingName) => {
    if (!meetingName) return '';
    
    return meetingName
      .replace(/\s+/g, '_')  // Replace spaces with underscores
      .replace(/[<>:"/\\|?*]/g, '')  // Remove invalid filename characters
      .replace(/[àáâãäå]/g, 'a')  // Replace accented characters
      .replace(/[èéêë]/g, 'e')
      .replace(/[ìíîï]/g, 'i')
      .replace(/[òóôõö]/g, 'o')
      .replace(/[ùúûü]/g, 'u')
      .replace(/[ñ]/g, 'n')
      .replace(/[ç]/g, 'c')
      .replace(/[^a-zA-Z0-9_-]/g, '')  // Remove any remaining special characters
      .replace(/_+/g, '_')  // Replace multiple underscores with single
      .replace(/^_|_$/g, '');  // Remove leading/trailing underscores
  }

}
//-----------------------------------------------------------------------------
