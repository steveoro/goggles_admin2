/*
 * FICR swimming results crawler.
 *
 * FICR's Angular application is backed by a JSON API. This crawler uses that
 * API as the primary source and keeps browser acquisition as a fallback for
 * source variants that cannot be reached directly.
 */
const fs = require('fs');
const path = require('path');
const fetch = require('node-fetch');
const puppeteer = require('puppeteer');
const CrawlUtil = require('./utility');
const FicrApiClient = require('./ficr-api-client');
const FicrUtil = require('./ficr-crawler-utils');
const {
  clean,
  cleanNullable,
  deltaTiming,
  groupHistory,
  normalizeEventCode,
  normalizeGender,
  normalizeMeetingName,
  nullable,
  parseHeaderDates,
  positiveOrNull,
  relayDistance,
  strokeCode
} = FicrUtil;

class FicrCrawler {
  constructor(seasonId = 242, meetingUrl, options = {}) {
    this.seasonId = seasonId;
    this.meetingUrl = meetingUrl;
    this.layoutType = 4;
    this.apiClient = new FicrApiClient({
      apiBaseUrl: options.apiBaseUrl,
      fetchImpl: options.fetchImpl || fetch,
      maxRetries: options.maxRetries ?? 2,
      requestDelayMs: options.requestDelayMs ?? 0
    });
    this.browserFactory = options.browserFactory || (() => puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
    }));
    this.fallbackLoader = options.fallbackLoader;
    this.warnings = [];
    this.eventDefinitions = new Map();
    this.categoryDefinitions = new Map();
    this.rankIndex = new Map();
    this.resultIndex = new Map();
    this.athleteIds = new Set();
  }

  async run() {
    let output;
    try {
      const source = this.parseMeetingUrl(this.meetingUrl);
      CrawlUtil.updateStatus(`[ficr-crawler] Starting crawl for season ${this.seasonId}...`);
      try {
        output = await this.crawlFromApi(source);
      } catch (error) {
        this.warn(`Direct FICR API crawl failed: ${error.message}; trying browser fallback.`);
        output = await this.crawlWithBrowser(source);
      }

      if (this.warnings.length && output && !output.crawlerWarnings) {
        output.crawlerWarnings = [...this.warnings];
      }
      const outputPath = this.writeOutput(output);
      CrawlUtil.updateStatus(`Saved "${path.basename(outputPath)}"`, 'OK, done, idle');
      return output;
    } catch (error) {
      CrawlUtil.updateStatus(`FICR crawl failed: ${error.message}`, 'ERROR');
      throw error;
    }
  }

  resetCrawlState() {
    this.warnings = [];
    this.eventDefinitions.clear();
    this.categoryDefinitions.clear();
    this.rankIndex.clear();
    this.resultIndex.clear();
    this.athleteIds.clear();
  }

  parseMeetingUrl(meetingUrl = this.meetingUrl) {
    if (!meetingUrl || !/^https?:\/\/nuoto\.ficr\.it\//i.test(meetingUrl)) {
      throw new Error('meeting_url must be a nuoto.ficr.it URL');
    }

    const parsed = new URL(meetingUrl);
    const hash = parsed.hash.replace(/^#\/?/, '');
    const parts = hash.split('/').map((value) => decodeURIComponent(value));
    if (parts[0] !== 'NUO' || parts[1] !== 'tempi' || parts.length < 6) {
      throw new Error('Unsupported FICR URL; expected #/NUO/tempi/<description>/<year>/<eqCode>/<meeting>');
    }

    const source = {
      sport: parts[0],
      page: parts[1],
      description: parts[2],
      year: parts[3],
      eqCode: parts[4],
      meeting: parts[5],
      category: parts[6] || null,
      event: parts[7] || null,
      battery: parts[8] || null,
      turn: parts[9] || null
    };
    if (!/^\d{4}$/.test(source.year) || !source.eqCode || !source.meeting) {
      throw new Error('Incomplete FICR meeting identifiers in URL');
    }
    return source;
  }

  async crawlFromApi(source) {
    this.resetCrawlState();
    const header = await this.loadDescription(source);
    const categories = await this.loadCategories(source);
    if (!categories.length) throw new Error('FICR returned no result categories');

    const output = this.createOutput(source, header);
    const athleteQueue = new Map();
    let categoryCount = 0;

    for (const category of categories) {
      const categoryId = category.ct_Categoria;
      if (!categoryId) continue;
      const gender = normalizeGender(category.ct_Sesso);
      this.categoryDefinitions.set(categoryId, { ...category, gender });
      const events = await this.loadEvents(source, categoryId);
      categoryCount += 1;
      CrawlUtil.updateStatus(`FICR category ${categoryId}: ${events.length} events`, 'OK, running', categoryCount, categories.length);

      for (const event of events) {
        const definition = this.buildEventDefinition(event, category, source);
        this.eventDefinitions.set(this.eventKey(definition), definition);
        const subcategories = await this.loadSubcategories(source, categoryId, event.tg_TipoGara);
        const requestedCategories = subcategories.length
          ? subcategories.map((item) => item.ct_Categoria).filter(Boolean)
          : ['*'];

        let resultCount = 0;
        const appendRows = (resultPayload, rawCategory) => {
          const rows = Array.isArray(resultPayload.results) ? resultPayload.results : [];
          const isRelay = definition.relay || resultPayload.staffetta === true;
          const normalizedCategory = this.normalizeCategory(rawCategory, subcategories, definition.relay);
          const eventOutput = this.ensureEvent(output, definition);

          rows.forEach((row, index) => {
            const result = this.normalizeResultRow({
              row,
              index,
              definition: { ...definition, relay: isRelay },
              category: normalizedCategory,
              rawCategory,
              sourceCategory: categoryId,
              output,
              athleteQueue
            });
            if (result) this.addResult(eventOutput, result);
          });
          resultCount += rows.length;
        };

        for (const rawCategory of requestedCategories) {
          appendRows(await this.loadResults(source, categoryId, event.tg_TipoGara, rawCategory), rawCategory);
        }
        if (definition.relay && resultCount === 0 && requestedCategories[0] !== '*') {
          this.warn(`FICR relay category filtering returned no rows for ${definition.eventCode}; retrying summary.`);
          appendRows(await this.loadResults(source, categoryId, event.tg_TipoGara, '*'), requestedCategories[0]);
        }
      }
    }

    await this.enrichAthletes(output, source, athleteQueue);
    this.stripInternalFields(output);
    return output;
  }

  async crawlWithBrowser(source) {
    if (typeof this.fallbackLoader === 'function') {
      return this.fallbackLoader(source, this);
    }

    let browser;
    try {
      browser = await this.browserFactory();
      const page = await browser.newPage();
      await page.goto(this.meetingUrl, { waitUntil: 'networkidle2', timeout: 45000 });
      const browserFetch = async (url, init) => page.evaluate(async ({ requestUrl, requestInit }) => {
        const response = await fetch(requestUrl, requestInit);
        return { ok: response.ok, status: response.status, body: await response.json() };
      }, { requestUrl: url, requestInit: init });
      const previousFetch = this.apiClient.fetchImpl;
      this.apiClient.fetchImpl = async (url, init) => {
        const response = await browserFetch(url, init);
        return {
          ok: response.ok,
          status: response.status,
          async json() { return response.body; }
        };
      };
      try {
        return await this.crawlFromApi(source);
      } finally {
        this.apiClient.fetchImpl = previousFetch;
      }
    } finally {
      if (browser) await browser.close();
    }
  }

  loadDescription(source) { return this.apiClient.loadDescription(source); }

  loadCategories(source) { return this.apiClient.loadCategories(source); }

  loadEvents(source, categoryId) { return this.apiClient.loadEvents(source, categoryId); }

  loadSubcategories(source, categoryId, eventId) {
    return this.apiClient.loadSubcategories(source, categoryId, eventId);
  }

  loadResults(source, categoryId, eventId, subcategoryId) {
    return this.apiClient.loadResults(source, categoryId, eventId, subcategoryId);
  }

  loadAthlete(source, athleteId) { return this.apiClient.loadAthlete(source, athleteId); }

  createOutput(source, header) {
    const dateInfo = parseHeaderDates(header.ma_LuogoData, header.ma_DataRiferimento);
    const meetingName = normalizeMeetingName(header.ma_Descrizione || source.description);
    return {
      title: meetingName,
      dates: dateInfo.dates,
      place: dateInfo.place,
      meetingName,
      competitionType: 'Master',
      layoutType: this.layoutType,
      seasonId: this.seasonId,
      meetingURL: this.meetingUrl,
      swimmers: {},
      teams: {},
      events: []
    };
  }

  buildEventDefinition(event, category, source) {
    const sourceEventCode = String(event.tg_Sigla || event.tg_MappaturaImportazione || '').toUpperCase();
    const eventStroke = strokeCode(event.tg_Stile, sourceEventCode);
    const eventCode = normalizeEventCode(sourceEventCode);
    const relay = event.tg_AStaffetta === true || Number(event.tg_NumeroFrazionisti) > 0 || /^\d+X\d+/i.test(eventCode);
    return {
      eventCode,
      sourceEventCode,
      eventGender: normalizeGender(category.ct_Sesso) || 'X',
      eventLength: relay ? relayDistance(eventCode, event.tg_Distanza) : String(event.tg_Distanza || eventCode.match(/^\d+/)?.[0] || ''),
      eventStroke,
      eventDescription: event.tg_Descrizione || eventCode,
      relay,
      sourceCategory: category.ct_Categoria,
      sourceEventId: String(event.tg_TipoGara),
      sourceDescription: source.description
    };
  }

  normalizeResultRow({ row, index, definition, category, rawCategory, sourceCategory, output, athleteQueue }) {
    const teamName = clean(row.Sq || row.Soc);
    const timing = cleanNullable(row.Tempo);
    const ranking = row.Pos !== undefined && row.Pos !== null && row.Pos !== '' ? row.Pos : index + 1;
    const common = {
      ranking,
      team: this.addTeam(output, teamName),
      timing,
      category,
      heat: nullable(row.Batteria),
      heat_position: nullable(row.Batteria),
      lane: nullable(row.Corsia),
      standard_points: positiveOrNull(row.PuntiAss),
      team_points: positiveOrNull(row.PuntiSottoCat),
      meeting_points: positiveOrNull(row.PuntiP),
      disqualified: row.Causa !== null && row.Causa !== undefined && row.Causa !== ''
    };

    if (definition.relay) {
      return {
        relay: true,
        ...common,
        relay_name: teamName,
        source_category: rawCategory,
        source_competitor_id: nullable(row.Conc)
      };
    }

    const firstName = clean(row.Nome);
    const lastName = clean(row.Cognome);
    const year = nullable(row.Anno);
    if (!firstName && !lastName && !row.Numero && !row.Conc) return null;
    const gender = normalizeGender(row.Sex) || definition.eventGender;
    const swimmerKey = this.addSwimmer(output, {
      gender,
      firstName,
      lastName,
      year,
      teamName,
      badge: row.Codice,
      sourceId: row.Numero
    });
    const athleteId = nullable(row.Numero);
    if (athleteId !== null) athleteQueue.set(String(athleteId), { swimmerKey, athleteId });
    const result = {
      ...common,
      swimmer: swimmerKey,
      nation: nullable(row.Naz),
      gender,
      source_category: rawCategory,
      source_competitor_id: nullable(row.Conc),
      source_badge: nullable(row.Codice)
    };
    this.rankIndex.set(this.rankKey(definition, category, athleteId, sourceCategory), result.ranking);
    return result;
  }

  async enrichAthletes(output, source, athleteQueue) {
    let index = 0;
    for (const { swimmerKey, athleteId } of athleteQueue.values()) {
      index += 1;
      CrawlUtil.updateStatus(`FICR athlete enrichment ${index}/${athleteQueue.size}`, 'OK, running', index, athleteQueue.size);
      try {
        const payload = await this.loadAthlete(source, athleteId);
        this.mergeAthlete(output, swimmerKey, payload, athleteId);
      } catch (error) {
        this.warn(`Unable to enrich FICR athlete ${athleteId}: ${error.message}`);
      }
    }
  }

  mergeAthlete(output, swimmerKey, payload, athleteId) {
    const athlete = payload.atleta || {};
    const history = Array.isArray(payload.tempi) ? payload.tempi : [];
    const swimmer = output.swimmers[swimmerKey];
    if (swimmer) {
      swimmer.lastName = swimmer.lastName || clean(athlete.Cognome);
      swimmer.firstName = swimmer.firstName || clean(athlete.Nome);
      swimmer.year = swimmer.year || nullable(athlete.Anno);
      swimmer.team = swimmer.team || this.addTeam(output, clean(athlete.Soc));
      swimmer.gender = swimmer.gender || normalizeGender(athlete.Sex) || null;
      swimmer.source_badge = swimmer.source_badge || nullable(athlete.Codice);
      swimmer.source_athlete_id = swimmer.source_athlete_id || athleteId;
    }
    const groups = groupHistory(history);
    groups.forEach((rows) => {
      const first = rows[0];
      const definition = this.findEventDefinition(first.TipoGara, swimmer?.gender);
      if (!definition || definition.relay) return;
      const sourceCategory = clean(first.Categoria);
      const category = this.findCategoryForHistory(definition, sourceCategory, athleteId);
      const eventOutput = this.ensureEvent(output, definition);
      const existing = eventOutput.results.find((result) =>
        result.swimmer === swimmerKey && result.category === category
      );
      const orderedRows = rows
        .filter((row) => Number(row.Metri) > 0)
        .sort((a, b) => Number(a.Metri) - Number(b.Metri));
      const eventLength = Number(String(definition.eventLength).replace(/\D/g, ''));
      const intermediateRows = eventLength > 50
        ? orderedRows.filter((row) => Number(row.Metri) < eventLength)
        : [];
      const laps = intermediateRows.map((row, index, all) => ({
        distance: `${Number(row.Metri)}m`,
        timing: cleanNullable(row.Tempo),
        delta: deltaTiming(cleanNullable(row.Tempo), index > 0 ? all[index - 1].Tempo : null),
        position: nullable(row.Pos)
      }));
      const finalTiming = cleanNullable(orderedRows[orderedRows.length - 1]?.Tempo);
      const result = existing || {
        ranking: this.rankIndex.get(this.rankKey(definition, category, athleteId, sourceCategory)) ?? null,
        swimmer: swimmerKey,
        team: this.addTeam(output, clean(first.Squadra)),
        timing: finalTiming,
        category,
        gender: swimmer?.gender || normalizeGender(athlete.Sex) || '',
        heat: nullable(first.Batteria),
        heat_position: nullable(first.Batteria),
        lane: nullable(first.Corsia),
        nation: null,
        source_category: sourceCategory,
        source_athlete_id: athleteId
      };
      result.laps = laps;
      result.timing = result.timing || finalTiming;
      if (!existing) this.addResult(eventOutput, result);
    });
  }

  findEventDefinition(eventId, gender) {
    const candidates = [...this.eventDefinitions.values()].filter((definition) => definition.sourceEventId === String(eventId));
    return candidates.find((definition) => !gender || definition.eventGender === gender) || candidates[0];
  }

  findCategoryForHistory(definition, sourceCategory, athleteId) {
    const prefix = `${this.eventKey(definition)}|`;
    const candidates = [...this.rankIndex.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .filter(([key]) => key.endsWith(`|${sourceCategory || ''}`))
      .filter(([key]) => key.includes(`|${athleteId}|`));
    const candidate = candidates[0]?.[0];
    if (candidate) return candidate.slice(prefix.length).split('|')[0];
    return this.normalizeCategory(sourceCategory, [], false);
  }

  ensureEvent(output, definition) {
    const key = this.eventKey(definition);
    let event = output.events.find((item) => this.eventKey(item) === key);
    if (!event) {
      event = {
        eventCode: definition.eventCode,
        eventGender: definition.eventGender,
        eventLength: definition.eventLength,
        eventStroke: definition.eventStroke,
        eventDescription: definition.eventDescription,
        relay: definition.relay,
        results: []
      };
      output.events.push(event);
    }
    return event;
  }

  addResult(event, result) {
    const key = result.relay
      ? `relay|${result.team}|${result.category}|${result.timing}|${result.lane || ''}`
      : `${result.swimmer}|${result.category}`;
    if (!event.results.some((item) => item.__key === key)) {
      result.__key = key;
      event.results.push(result);
    }
  }

  addTeam(output, teamName) {
    const name = clean(teamName);
    if (!name) return '';
    const key = CrawlUtil.createTeamKey(name);
    if (!output.teams[key]) output.teams[key] = { name };
    return key;
  }

  addSwimmer(output, { gender, firstName, lastName, year, teamName, badge, sourceId }) {
    const team = this.addTeam(output, teamName);
    const key = CrawlUtil.createSwimmerKey(gender, lastName, firstName, year, teamName);
    if (!output.swimmers[key]) {
      output.swimmers[key] = {
        lastName: clean(lastName),
        firstName: clean(firstName),
        gender: normalizeGender(gender) || null,
        year: nullable(year),
        team,
        source_badge: nullable(badge),
        source_athlete_id: nullable(sourceId)
      };
    }
    return key;
  }

  normalizeCategory(rawCode, subcategories = [], relay = false) {
    const raw = clean(rawCode);
    const item = subcategories.find((candidate) => candidate.ct_Categoria === raw);
    const description = clean(item?.ct_Descrizione);
    const range = description.match(/(\d{2,3})\s*[-–]\s*(\d{2,3})/);
    if (relay && range) return `${range[1]}-${range[2]}`;
    if (range && /master/i.test(description)) return `M${range[1]}`;
    // "Under"/"assoluti"-style categories have season-dependent codes (e.g., U25);
    // keep the raw source code here and let the DataFix pipeline resolve it.
    if (/under|assolut/i.test(description) || /^UN/i.test(raw)) return raw || null;
    const age = raw.match(/^(?:M)?(\d{2,3})[FMX]?$/i);
    if (age) return `M${age[1]}`;
    if (relay && /^\d{2,3}[FMX]?$/i.test(raw)) {
      const start = Number(raw.match(/\d+/)[0]) * 10;
      return `${start}-${start + (start < 120 ? 19 : 39)}`;
    }
    return raw || null;
  }

  eventKey(event) {
    return `${event.eventCode}|${event.eventGender}|${event.relay ? 'R' : 'I'}`;
  }

  rankKey(definition, category, athleteId, sourceCategory) {
    return `${this.eventKey(definition)}|${category}|${athleteId}|${sourceCategory || ''}`;
  }

  stripInternalFields(output) {
    output.events.forEach((event) => event.results.forEach((result) => delete result.__key));
    if (this.warnings.length) output.crawlerWarnings = this.warnings;
  }

  outputFilename(output) {
    const date = CrawlUtil.parseFirstMeetingDate(output.dates) || 'xxxx-xx-xx';
    const name = CrawlUtil.sanitizeForFilename(output.meetingName || 'ficr-results');
    return `${date}-${name}-lt${this.layoutType}.json`;
  }

  writeOutput(output) {
    const filename = this.outputFilename(output);
    const folder = CrawlUtil.assertDestFolder('data/results.new', this.seasonId);
    const outputPath = path.join(folder, filename);
    fs.writeFileSync(outputPath, JSON.stringify(output, null, 2), 'utf8');
    return outputPath;
  }

  warn(message) {
    this.warnings.push(message);
    console.warn(`[ficr-crawler] ${message}`);
  }
}

module.exports = FicrCrawler;
module.exports.parseHeaderDates = parseHeaderDates;
module.exports.normalizeCategory = (raw, subcategories, relay) => new FicrCrawler().normalizeCategory(raw, subcategories, relay);
module.exports.deltaTiming = deltaTiming;
