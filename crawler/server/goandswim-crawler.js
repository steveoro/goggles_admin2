/*
 * Go&Swim swimming results crawler (risultati.goandswim.it).
 *
 * The site is a React SPA backed by a public JSON API: this crawler reads the
 * meeting, its races, their results and the per-swimmer splits, and writes one
 * layoutType 4 file shaped like the FICR crawler output.
 */
const fs = require('fs');
const path = require('path');
const CrawlUtil = require('./utility');
const GoAndSwimApiClient = require('./goandswim-api-client');
const { clean, nullable, normalizeGender, positiveOrNull } = require('./ficr-crawler-utils');
const {
  buildLaps,
  buildRelayLaps,
  convertTiming,
  dateRange,
  isRelay,
  isoDate,
  parseMeetingUrl,
  parseSplits,
  relayCategory,
  relayLegCount,
  splitAthleteName,
  splitRelayMembers,
  strokeCode,
  strokeName
} = require('./goandswim-crawler-utils');

const MEETING_BASE_URL = 'https://risultati.goandswim.it/evento';
const UNRANKED_POSITION = 1000;
const FIFTY_METERS_PROBES = 3;

class GoAndSwimCrawler {
  constructor(seasonId, meetingUrl, options = {}) {
    this.seasonId = seasonId;
    this.meetingUrl = meetingUrl;
    this.layoutType = 4;
    this.apiClient = options.apiClient || new GoAndSwimApiClient({
      apiBaseUrl: options.apiBaseUrl,
      fetchImpl: options.fetchImpl,
      maxRetries: options.maxRetries,
      requestDelayMs: options.requestDelayMs
    });
    this.resetCrawlState();
  }

  async run() {
    try {
      const parsed = this.parseMeetingUrl(this.meetingUrl);
      CrawlUtil.updateStatus(`[goandswim-crawler] Starting crawl for season ${this.seasonId}...`);
      const source = await this.resolveSource(parsed);
      const output = await this.crawlFromApi(source, {
        onProgress: (detail, current, total) => CrawlUtil.updateStatus(detail, 'OK, running', current, total)
      });
      const outputPath = this.writeOutput(output);
      CrawlUtil.updateStatus(`Saved "${path.basename(outputPath)}"`, 'OK, done, idle');
      return output;
    } catch (error) {
      CrawlUtil.updateStatus(`Go&Swim crawl failed: ${error.message}`, 'ERROR');
      throw error;
    }
  }

  resetCrawlState() {
    this.warnings = [];
    this.noShowCount = 0;
    this.fiftyProbes = 0;
    this.fiftySplits = null; // null = undecided; true/false after probing
    this.relayResults = [];
  }

  parseMeetingUrl(meetingUrl = this.meetingUrl) {
    return parseMeetingUrl(meetingUrl);
  }

  // A race ("/gara/<id>") URL is resolved to its meeting.
  async resolveSource(parsed) {
    if (parsed.type === 'event') return { eventId: parsed.eventId };
    const race = await this.apiClient.loadRace(parsed.eventRaceId);
    if (!race.eventId) throw new Error(`Go&Swim race ${parsed.eventRaceId} not found`);
    return { eventId: race.eventId };
  }

  // Crawls the whole meeting and returns the LT4 output (writes nothing).
  async crawlFromApi(source, { onProgress = () => {} } = {}) {
    this.resetCrawlState();
    const eventId = typeof source === 'string' ? source : source.eventId;
    const header = await this.apiClient.loadEvent(eventId);
    const races = (await this.apiClient.loadRaces(eventId)).filter((race) => Number(race.raceStatus) >= 2);
    const output = this.createOutput(eventId, header);
    const crawledRaces = [];

    for (const [index, race] of races.entries()) {
      onProgress(`Go&Swim race ${clean(race.eventRaceDescription)}`, index + 1, races.length);
      const rows = await this.apiClient.loadResults(race.eventRaceId);
      if (!rows.length) continue;

      crawledRaces.push(race);
      const definition = this.buildEventDefinition(race, rows);
      const event = this.ensureEvent(output, definition);
      for (const row of rows) {
        const result = await this.normalizeResultRow({ row, race, definition, output });
        if (result) this.addResult(event, result);
      }
    }

    if (!output.events.length) throw new Error(`Go&Swim meeting ${eventId} has no results`);
    this.resolveRelayMembers(output);
    this.fillHeader(output, header, crawledRaces);
    if (this.noShowCount) this.warn(`${this.noShowCount} no-show row(s) (status N) skipped`);
    this.stripInternalFields(output);
    return output;
  }

  createOutput(eventId, header) {
    const meetingName = clean(header.eventDescription);
    return {
      title: meetingName,
      dates: '',
      place: '',
      venueName: '',
      meetingName,
      competitionType: 'Master',
      layoutType: this.layoutType,
      seasonId: this.seasonId,
      meetingURL: `${MEETING_BASE_URL}/${eventId}`,
      swimmers: {},
      teams: {},
      events: []
    };
  }

  fillHeader(output, header, races) {
    const raceDates = [...new Set(races.map((race) => isoDate(race.raceDate)).filter(Boolean))].sort();
    output.dates = (raceDates.length ? raceDates : dateRange(header.startDate, header.endDate)).join(',');
    const location = clean(header.location);
    const pools = [...new Set(races.map((race) => clean(race.poolName)).filter(Boolean))];
    const place = location && location !== '-' ? location : pools.join(' / ');
    output.place = place;
    output.venueName = place;
  }

  buildEventDefinition(race, rows = []) {
    const description = clean(race.eventRaceDescription);
    const relay = isRelay(description);
    const eventStroke = strokeCode(race.styleId);
    const length = Number(race.length) || 0;
    const legCount = relay
      ? relayLegCount(description) || splitRelayMembers(rows.find((row) => row.relayTeamMembers)?.relayTeamMembers).length || 4
      : null;
    const eventLength = relay ? `${legCount}X${length}` : String(length);
    return {
      eventCode: `${eventLength}${eventStroke}`,
      eventGender: normalizeGender(race.sex) || 'X',
      eventLength,
      eventStroke,
      eventDescription: `${eventLength}m ${strokeName(eventStroke)}`,
      relay,
      legLength: length,
      legCount
    };
  }

  async normalizeResultRow({ row, race, definition, output }) {
    const status = clean(row.raceStatus).toUpperCase();
    if (status === 'N') {
      this.noShowCount += 1;
      return null;
    }

    const name = clean(row.athleteName);
    const disqualified = status === 'S';
    let timing = disqualified ? null : convertTiming(row.raceTime);
    if (!disqualified && timing === null) {
      this.warn(`Row with status "${status}" and no valid time ("${clean(row.raceTime)}") kept without timing: ${name} (${this.label(definition, row)})`);
    }
    const position = Number(row.finalPosition);
    const ranking = timing && Number.isInteger(position) && position > 0 && position < UNRANKED_POSITION ? position : null;
    const teamName = clean(row.clubName);
    const heat = parseInt(row.internalGroupNr, 10);
    const common = {
      ranking,
      team: this.addTeam(output, teamName),
      timing,
      heat: Number.isNaN(heat) ? null : heat,
      heat_position: null,
      lane: nullable(row.laneNr),
      team_points: null,
      meeting_points: null,
      disqualified,
      nation: nullable(row.nation)
    };
    const sourceFields = {
      source_category: nullable(row.categoryId),
      source_competitor_id: nullable(row.eventRaceMemberId),
      source_athlete_id: nullable(row.athleteId),
      source_entry_time: convertTiming(row.officialTime)
    };
    if (clean(row.calculationFlag)) sourceFields.source_calculation_flag = clean(row.calculationFlag);

    const splitDetails = timing && this.shouldLoadSplits(definition)
      ? await this.loadSplitDetails(row.eventRaceMemberId, definition)
      : null;

    if (definition.relay) {
      const members = splitRelayMembers(row.relayTeamMembers);
      const result = {
        relay: true,
        ...common,
        relay_name: name || teamName,
        category: relayCategory(race.eventRaceDescription, row.categoryId || race.categoryId),
        standard_points: positiveOrNull(row.point2) ?? positiveOrNull(row.point),
        laps: [],
        ...sourceFields,
        source_relay_members: members
      };
      if (timing) {
        const { laps, warning } = buildRelayLaps({
          legLength: definition.legLength,
          legCount: members.length || definition.legCount,
          splits: parseSplits(splitDetails),
          finalTiming: timing
        });
        result.laps = laps;
        if (warning) this.splitWarning(result, splitDetails, `${warning}; relay members not attached`, name, definition, row);
      }
      if (result.laps.length) {
        result.__members = members;
        result.__teamName = teamName;
        this.relayResults.push({ result, gender: definition.eventGender });
      }
      return result;
    }

    const { lastName, firstName } = splitAthleteName(name);
    if (!lastName) return null;
    const gender = ['M', 'F'].includes(definition.eventGender) ? definition.eventGender : null;
    const year = positiveOrNull(row.birthYear);
    const swimmer = this.addSwimmer(output, {
      gender, lastName, firstName, completeName: name, year, teamName, sourceId: nullable(row.athleteId)
    });
    const result = {
      ...common,
      swimmer,
      category: nullable(row.categoryId) || nullable(race.categoryId),
      gender,
      standard_points: positiveOrNull(row.point) ?? positiveOrNull(row.point2),
      laps: [],
      ...sourceFields
    };
    if (splitDetails) {
      const { laps, warning } = buildLaps({ length: definition.legLength, splits: parseSplits(splitDetails), finalTiming: timing });
      result.laps = laps;
      if (warning) this.splitWarning(result, splitDetails, warning, name, definition, row);
    }
    return result;
  }

  // Splits are requested for every relay and every race of 100 m or more;
  // 50 m splits only when one of the first probed 50 m results (across the
  // first 50 m races of the meeting) carries a 25 m split.
  shouldLoadSplits(definition) {
    if (definition.relay || definition.legLength >= 100) return true;
    if (definition.legLength !== 50) return false;
    return this.fiftySplits !== false;
  }

  async loadSplitDetails(eventRaceMemberId, definition) {
    const payload = await this.apiClient.loadSplits(eventRaceMemberId);
    const splitDetails = payload ? clean(payload.splitDetails) || null : null;
    if (!definition.relay && definition.legLength === 50 && this.fiftySplits === null) {
      this.fiftyProbes += 1;
      if (parseSplits(splitDetails).length >= 2) this.fiftySplits = true;
      else if (this.fiftyProbes >= FIFTY_METERS_PROBES) this.fiftySplits = false;
    }
    return splitDetails;
  }

  splitWarning(result, splitDetails, reason, name, definition, row) {
    if (splitDetails) result.source_splits = splitDetails;
    this.warn(`No laps for ${name} (${this.label(definition, row)}): ${reason}`);
  }

  label(definition, row) {
    return `${definition.eventCode} ${definition.eventGender} ${clean(row.categoryId)}`.trim();
  }

  // Relay members carry a name only: reuse the individual swimmer of the same
  // meeting when name, team and (for M/F races) gender match unambiguously;
  // otherwise register a year-less swimmer ("G|LAST|FIRST||TEAM").
  resolveRelayMembers(output) {
    const index = new Map();
    Object.entries(output.swimmers).forEach(([key, swimmer]) => {
      const lookup = this.memberLookupKey(swimmer.lastName, swimmer.firstName, swimmer.team);
      if (!index.has(lookup)) index.set(lookup, []);
      index.get(lookup).push({ key, swimmer });
    });

    this.relayResults.forEach(({ result, gender }) => {
      const teamName = result.__teamName;
      const raceGender = ['M', 'F'].includes(gender) ? gender : null;
      result.laps.forEach((lap, legIndex) => {
        const fullName = result.__members[legIndex];
        if (!fullName) {
          lap.swimmer = null;
          return;
        }
        const { lastName, firstName } = splitAthleteName(fullName);
        const candidates = (index.get(this.memberLookupKey(lastName, firstName, teamName)) || [])
          .filter(({ swimmer }) => swimmer.year && (!raceGender || swimmer.gender === raceGender));
        lap.swimmer = candidates.length === 1
          ? candidates[0].key
          : this.addSwimmer(output, { gender: raceGender, lastName, firstName, completeName: fullName, year: null, teamName });
      });
    });
  }

  memberLookupKey(lastName, firstName, team) {
    return [lastName, firstName, team].map((value) => clean(value).toUpperCase()).join('|');
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

  eventKey(event) {
    return `${event.eventCode}|${event.eventGender}|${event.relay ? 'R' : 'I'}`;
  }

  addResult(event, result) {
    const id = result.source_competitor_id;
    if (id && event.results.some((item) => item.source_competitor_id === id)) return;
    event.results.push(result);
  }

  addTeam(output, teamName) {
    const name = clean(teamName);
    if (!name) return '';
    const key = CrawlUtil.createTeamKey(name);
    if (!output.teams[key]) output.teams[key] = { name };
    return key;
  }

  addSwimmer(output, { gender, lastName, firstName, completeName, year, teamName, sourceId }) {
    const team = this.addTeam(output, teamName);
    const key = CrawlUtil.createSwimmerKey(gender, lastName, firstName, year, teamName);
    if (!output.swimmers[key]) {
      output.swimmers[key] = {
        lastName: clean(lastName),
        firstName: clean(firstName),
        complete_name: clean(completeName),
        gender: normalizeGender(gender) || null,
        year: nullable(year),
        team
      };
      if (sourceId) output.swimmers[key].source_athlete_id = sourceId;
    }
    return key;
  }

  stripInternalFields(output) {
    output.events.forEach((event) => event.results.forEach((result) => {
      Object.keys(result).filter((key) => key.startsWith('__')).forEach((key) => delete result[key]);
    }));
    if (this.warnings.length) output.crawlerWarnings = this.warnings;
  }

  outputFilename(output) {
    const date = CrawlUtil.parseFirstMeetingDate(output.dates) || 'xxxx-xx-xx';
    const name = CrawlUtil.sanitizeForFilename(output.meetingName || 'goandswim-results');
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
    console.warn(`[goandswim-crawler] ${message}`);
  }
}

module.exports = GoAndSwimCrawler;
