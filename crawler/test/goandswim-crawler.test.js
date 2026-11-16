const { expect } = require('chai');
const GoAndSwimCrawler = require('../server/goandswim-crawler');
const GasUtil = require('../server/goandswim-crawler-utils');
const { fixture, fixtureFetch } = require('./support/goandswim-fixture-fetch');

const MEETING_A = '5ce2d74fd05d4a659b511251caec6132';
const MEETING_B = 'bf3fc1475f4449e0a46451ee53e8c00c';
const RACE_800_M35 = '2ca8343b39aa4c859fe28d9a6dcb04e8';
const RELAY_RACE = '89a7b24ca72c46c6b402f0d544240f2a';
const PANZETTI_800 = 'd39f4e61ba244b248f3ac9c31ecd30c3';

const clone = (value) => JSON.parse(JSON.stringify(value));
const raceById = (eventId, raceId) => fixture.races[eventId].find((race) => race.eventRaceId === raceId);

// Builds the crawler on top of the captured fixture (no network, no delay).
function fixtureCrawler(url = `https://risultati.goandswim.it/evento/${MEETING_A}`) {
  return new GoAndSwimCrawler(262, url, { fetchImpl: fixtureFetch, requestDelayMs: 0, maxRetries: 0 });
}

// In-memory API client stub counting the calls per method.
function stubClient({ event = {}, races = [], results = {}, splits = {} }) {
  const calls = { loadEvent: 0, loadRaces: 0, loadRace: 0, loadResults: [], loadSplits: [] };
  return {
    calls,
    async loadEvent() { calls.loadEvent += 1; return event; },
    async loadRaces() { calls.loadRaces += 1; return races; },
    async loadRace() { calls.loadRace += 1; return {}; },
    async loadResults(id) { calls.loadResults.push(id); return results[id] || []; },
    async loadSplits(id) { calls.loadSplits.push(id); return splits[id] ? { splitDetails: splits[id] } : null; }
  };
}

function stubCrawler(data) {
  const apiClient = stubClient(data);
  const crawler = new GoAndSwimCrawler(262, 'https://risultati.goandswim.it/evento/E1', { apiClient });
  return { crawler, apiClient };
}

function race(overrides) {
  return {
    eventRaceId: 'R1',
    eventId: 'E1',
    eventRaceDescription: '50 STILE LIBERO MASTER 35 FEMMINILE',
    raceDate: '2026-11-15T00:00:00',
    poolName: 'Pool',
    categoryId: 'M35',
    sex: 'F',
    length: 50,
    styleId: 'S',
    raceStatus: '2',
    ...overrides
  };
}

function row(overrides) {
  return {
    eventRaceMemberId: 'RM1',
    clubName: 'TEAM ONE',
    officialTime: '00\'40"00',
    internalGroupNr: '010',
    laneNr: 4,
    raceTime: '00\'38"00',
    finalPosition: 1,
    raceStatus: 'T',
    calculationFlag: null,
    athleteId: 'A1',
    athleteName: 'ROSSI ANNA',
    categoryId: 'M35',
    birthYear: 1990,
    isRelay: null,
    relayTeamMembers: null,
    point: 700,
    point2: 0,
    nation: null,
    ...overrides
  };
}

describe('GoAndSwim crawler utils', () => {
  it('parses event and race URLs and rejects other hosts', () => {
    expect(GasUtil.parseMeetingUrl(`https://risultati.goandswim.it/evento/${MEETING_A}`))
      .to.deep.equal({ type: 'event', eventId: MEETING_A });
    expect(GasUtil.parseMeetingUrl(`https://risultati.goandswim.it/gara/${RACE_800_M35}`))
      .to.deep.equal({ type: 'race', eventRaceId: RACE_800_M35, mode: null });
    expect(GasUtil.parseMeetingUrl(`https://risultati.goandswim.it/gara/${RACE_800_M35}/split`))
      .to.deep.equal({ type: 'race', eventRaceId: RACE_800_M35, mode: 'split' });
    expect(() => GasUtil.parseMeetingUrl(`https://example.com/evento/${MEETING_A}`)).to.throw(/goandswim/);
    expect(() => GasUtil.parseMeetingUrl('https://risultati.goandswim.it/eventi')).to.throw(/Unsupported/);
    expect(() => GasUtil.parseMeetingUrl(null)).to.throw();
  });

  it('converts Go&Swim timings to the FICR format', () => {
    expect(GasUtil.convertTiming('12\'01"84')).to.equal('12\'01.84');
    expect(GasUtil.convertTiming('01\'21"11')).to.equal('1\'21.11');
    expect(GasUtil.convertTiming('00\'37"54')).to.equal('37.54');
    expect(GasUtil.convertTiming('00\'00"00')).to.equal(null);
    expect(GasUtil.convertTiming('99\'99"99')).to.equal(null);
    expect(GasUtil.convertTiming('Squalif.')).to.equal(null);
    expect(GasUtil.convertTiming('Non part')).to.equal(null);
    expect(GasUtil.convertTiming(null)).to.equal(null);
  });

  it('maps strokes, relays and relay categories', () => {
    expect(['S', 'D', 'R', 'F', 'M'].map(GasUtil.strokeCode)).to.deep.equal(['SL', 'DO', 'RA', 'FA', 'MI']);
    expect(GasUtil.isRelay('4X50 MISTI STAFFETTA MASTER 120-159 MISTI')).to.equal(true);
    expect(GasUtil.isRelay('4 x 100 stile libero')).to.equal(true);
    expect(GasUtil.isRelay('Staffetta mista')).to.equal(true);
    expect(GasUtil.isRelay('800 STILE LIBERO MASTER 35 FEMMINILE')).to.equal(false);
    expect(GasUtil.relayCategory('4X50 MISTI STAFFETTA MASTER 120-159 MISTI', 'M120')).to.equal('120-159');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M120')).to.equal('120-159');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M80S')).to.equal('80-99');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M100')).to.equal('100-119');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M160')).to.equal('160-199');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M200')).to.equal('200-239');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M240')).to.equal('240-279');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M280')).to.equal('280-319');
    expect(GasUtil.relayCategory('4X50 STAFFETTA', 'M320')).to.equal('320-359');
  });

  it('splits athlete names like the Rails SwimmerNameSplitter', () => {
    expect(GasUtil.splitAthleteName('PANZETTI NAILA')).to.deep.equal({ lastName: 'PANZETTI', firstName: 'NAILA' });
    expect(GasUtil.splitAthleteName('DE LUCA MARIA')).to.deep.equal({ lastName: 'DE LUCA', firstName: 'MARIA' });
    expect(GasUtil.splitAthleteName('ROSSI MARIA GRAZIA')).to.deep.equal({ lastName: 'ROSSI', firstName: 'MARIA GRAZIA' });
    expect(GasUtil.splitAthleteName('DE LA CRUZ ANNA MARIA')).to.deep.equal({ lastName: 'DE LA', firstName: 'CRUZ ANNA MARIA' });
    expect(GasUtil.splitAthleteName('CHER')).to.deep.equal({ lastName: 'CHER', firstName: '' });
  });

  it('builds 100 m laps from the real 800 m splits, ignoring the step field', () => {
    const splits = GasUtil.parseSplits(fixture.splits[PANZETTI_800].splitDetails);
    expect(splits).to.have.length(8);
    const { laps, warning } = GasUtil.buildLaps({ length: 800, splits, finalTiming: '12\'01.84' });
    expect(warning).to.equal(null);
    expect(laps.map((lap) => lap.distance)).to.deep.equal(['100m', '200m', '300m', '400m', '500m', '600m', '700m']);
    expect(laps[0]).to.deep.equal({ distance: '100m', timing: '1\'21.11', delta: '1\'21.11', position: null });
    expect(laps[1]).to.include({ timing: '2\'50.76', delta: '1\'29.65' });
    expect(laps[6]).to.include({ timing: '10\'32.04', delta: '1\'32.51' });
  });

  it('builds 50 m laps from 16 splits and handles lists without the final time', () => {
    const cumulative = Array.from({ length: 16 }, (_, index) => GasUtil.formatHundredths((index + 1) * 3500));
    const { laps, warning } = GasUtil.buildLaps({ length: 800, splits: cumulative, finalTiming: cumulative[15] });
    expect(warning).to.equal(null);
    expect(laps).to.have.length(15);
    expect(laps[0]).to.include({ distance: '50m', timing: '35.00', delta: '35.00' });
    expect(laps[14]).to.include({ distance: '750m', delta: '35.00' });

    // Same splits without the final one: still 50 m laps (count + 1 rule)
    const withoutFinal = GasUtil.buildLaps({ length: 800, splits: cumulative.slice(0, 15), finalTiming: cumulative[15] });
    expect(withoutFinal.warning).to.equal(null);
    expect(withoutFinal.laps).to.have.length(15);
  });

  it('emits no laps for a single split equal to the final time, without warning', () => {
    const splits = GasUtil.parseSplits(fixture.splits['45a6871fb27745c9adce3e69f1c1174d'].splitDetails);
    expect(GasUtil.buildLaps({ length: 100, splits, finalTiming: '1\'23.57' }))
      .to.deep.equal({ laps: [], warning: null });
  });

  it('emits no laps and a warning when the split count does not divide the length', () => {
    const splits = GasUtil.parseSplits(fixture.splits[PANZETTI_800].splitDetails).slice(1);
    const { laps, warning } = GasUtil.buildLaps({ length: 800, splits, finalTiming: '12\'01.84' });
    expect(laps).to.deep.equal([]);
    expect(warning).to.match(/7 splits/);
  });

  it('builds one relay lap per leg, folding sub-leg splits', () => {
    const splits = GasUtil.parseSplits(fixture.splits['545a7c4f8d1d49e18af1c0c1e693125c'].splitDetails);
    const result = GasUtil.buildRelayLaps({ legLength: 50, legCount: 4, splits, finalTiming: '1\'59.85' });
    expect(result.warning).to.equal(null);
    expect(result.laps).to.deep.equal([
      { distance: '50m', delta: '29.55' },
      { distance: '100m', delta: '31.16' },
      { distance: '150m', delta: '30.40' },
      { distance: '200m', delta: '28.74' }
    ]);

    const eight = ['14.00', '29.55', '45.00', '1\'00.71', '1\'15.00', '1\'31.11', '1\'45.00', '1\'59.85'];
    expect(GasUtil.buildRelayLaps({ legLength: 50, legCount: 4, splits: eight, finalTiming: '1\'59.85' }).laps.map((lap) => lap.delta))
      .to.deep.equal(['29.55', '31.16', '30.40', '28.74']);

    const odd = GasUtil.buildRelayLaps({ legLength: 50, legCount: 4, splits: splits.slice(1), finalTiming: '1\'59.85' });
    expect(odd.laps).to.deep.equal([]);
    expect(odd.warning).to.match(/3 splits/);
  });
});

describe('GoAndSwimCrawler', () => {
  it('builds the output file name like the FICR crawler', () => {
    const crawler = fixtureCrawler();
    expect(crawler.layoutType).to.equal(4);
    expect(crawler.outputFilename({ dates: '2026-11-15', meetingName: '23° Trofeo DE AKKER' }))
      .to.equal('2026-11-15-23_Trofeo_DE_AKKER-lt4.json');
  });

  it('resolves a race URL to its meeting through loadRace', async () => {
    const crawler = fixtureCrawler(`https://risultati.goandswim.it/gara/${RACE_800_M35}/split`);
    const source = await crawler.resolveSource(crawler.parseMeetingUrl());
    expect(source).to.deep.equal({ eventId: MEETING_A });
  });

  it('crawls meeting A into an LT4 output without writing anything', async () => {
    const progress = [];
    const output = await fixtureCrawler().crawlFromApi({ eventId: MEETING_A }, {
      onProgress: (detail, current, total) => progress.push([current, total])
    });

    expect(output).to.include({
      title: '23° Trofeo DE AKKER',
      meetingName: '23° Trofeo DE AKKER',
      dates: '2026-11-15',
      place: 'Carmen Longo',
      venueName: 'Carmen Longo',
      competitionType: 'Master',
      layoutType: 4,
      seasonId: 262,
      meetingURL: `https://risultati.goandswim.it/evento/${MEETING_A}`
    });
    expect(output.crawlerWarnings).to.equal(undefined);
    expect(progress).to.deep.equal([[1, 4], [2, 4], [3, 4], [4, 4]]);

    // The two 800 SL F races (M35 and M30) are merged into one event
    expect(output.events.map((event) => `${event.eventCode}|${event.eventGender}|${event.relay}`))
      .to.deep.equal(['800SL|F|false', '50SL|F|false', '100DO|F|false']);
    const event800 = output.events[0];
    expect(event800).to.include({ eventLength: '800', eventStroke: 'SL', eventDescription: '800m Stile Libero' });
    expect(event800.results.map((result) => result.category)).to.deep.equal(['M35', 'M35', 'M30']);

    const panzetti = event800.results[1];
    expect(panzetti).to.include({
      ranking: 2,
      swimmer: 'F|PANZETTI|NAILA|1990|COOPERNUOTO',
      team: 'COOPERNUOTO',
      timing: '12\'01.84',
      category: 'M35',
      gender: 'F',
      heat: 90,
      heat_position: null,
      lane: 2,
      standard_points: 776,
      team_points: null,
      meeting_points: null,
      disqualified: false,
      nation: null,
      source_category: 'M35',
      source_competitor_id: PANZETTI_800,
      source_athlete_id: 'e1f74c7bdcb8488fb2f96608d7347f0b',
      source_entry_time: '12\'10.00'
    });
    expect(panzetti).not.to.have.property('source_calculation_flag');
    expect(panzetti.laps).to.have.length(7);
    expect(panzetti.laps[0]).to.deep.equal({ distance: '100m', timing: '1\'21.11', delta: '1\'21.11', position: null });
    expect(event800.results[2].laps).to.deep.equal([]); // LONARDINI: no splits published

    expect(output.events[1].results[0]).to.include({ timing: '37.54', ranking: 1 });
    expect(output.events[1].results[0].laps).to.deep.equal([]);

    expect(Object.keys(output.swimmers)).to.have.members([
      'F|CHERICI|ARIANNA|1991|SO.GE.SE SOC. COOP',
      'F|PANZETTI|NAILA|1990|COOPERNUOTO',
      'F|LONARDINI|CRISTINA|1993|G.A.M. TEAM SSD - BRESCIA',
      'F|POMPILI|GIULIA|1992|SEVEN MASTER NUOTO ASD'
    ]);
    expect(output.swimmers['F|PANZETTI|NAILA|1990|COOPERNUOTO']).to.deep.equal({
      lastName: 'PANZETTI',
      firstName: 'NAILA',
      complete_name: 'PANZETTI NAILA',
      gender: 'F',
      year: 1990,
      team: 'COOPERNUOTO',
      source_athlete_id: 'e1f74c7bdcb8488fb2f96608d7347f0b'
    });
    expect(output.teams).to.deep.equal({
      'SO.GE.SE SOC. COOP': { name: 'SO.GE.SE SOC. COOP' },
      COOPERNUOTO: { name: 'COOPERNUOTO' },
      'G.A.M. TEAM SSD - BRESCIA': { name: 'G.A.M. TEAM SSD - BRESCIA' },
      'SEVEN MASTER NUOTO ASD': { name: 'SEVEN MASTER NUOTO ASD' }
    });
    const json = JSON.stringify(output);
    expect(json).not.to.include('__');
  });

  it('crawls meeting B with a relay, a no-show and point2 scores', async () => {
    const output = await fixtureCrawler().crawlFromApi({ eventId: MEETING_B });

    expect(output).to.include({
      title: 'CAMPIONATI REGIONALI MASTER EMILIA ROMAGNA 2026',
      dates: '2026-02-21',
      place: 'Stadio del Nuoto'
    });
    expect(output.events.map((event) => `${event.eventCode}|${event.eventGender}|${event.relay}`))
      .to.deep.equal(['4X50MI|X|true', '200SL|M|false']);

    const relayEvent = output.events[0];
    expect(relayEvent).to.include({ eventLength: '4X50', eventStroke: 'MI', eventDescription: '4X50m Misti' });
    const [first, second, third] = relayEvent.results;
    expect(first).to.include({
      relay: true,
      ranking: 1,
      team: 'AQUATIC TEAM RAVENNA',
      relay_name: 'AQUATIC TEAM RAVENNA',
      timing: '1\'59.85',
      category: '120-159',
      heat: 80,
      lane: 2,
      standard_points: 917.81,
      disqualified: false,
      source_category: 'M120',
      source_competitor_id: '545a7c4f8d1d49e18af1c0c1e693125c',
      source_entry_time: '2\'02.00'
    });
    expect(first.source_relay_members).to.deep.equal([
      'BRIGLIADORI ANDREA', 'ZANETTI FEDERICO', 'IUFFRIDA LETIZIA', 'PISCEDDA CLAUDIA'
    ]);
    expect(first.laps).to.deep.equal([
      { distance: '50m', delta: '29.55', swimmer: '|BRIGLIADORI|ANDREA||AQUATIC TEAM RAVENNA' },
      { distance: '100m', delta: '31.16', swimmer: '|ZANETTI|FEDERICO||AQUATIC TEAM RAVENNA' },
      { distance: '150m', delta: '30.40', swimmer: '|IUFFRIDA|LETIZIA||AQUATIC TEAM RAVENNA' },
      { distance: '200m', delta: '28.74', swimmer: '|PISCEDDA|CLAUDIA||AQUATIC TEAM RAVENNA' }
    ]);
    expect(second.lane).to.equal(0);
    expect(second.laps).to.have.length(4);
    expect(third.laps).to.deep.equal([]);

    // Relay members are registered only when referenced by laps (no year, gender unknown on X races)
    expect(output.swimmers['|BRIGLIADORI|ANDREA||AQUATIC TEAM RAVENNA']).to.deep.equal({
      lastName: 'BRIGLIADORI',
      firstName: 'ANDREA',
      complete_name: 'BRIGLIADORI ANDREA',
      gender: null,
      year: null,
      team: 'AQUATIC TEAM RAVENNA'
    });
    expect(Object.keys(output.swimmers).filter((key) => key.includes('RICCIONE'))).to.deep.equal([]);
    expect(output.teams).to.have.property('ASD POLISPORTIVA RICCIONE APS');

    const individual = output.events[1];
    expect(individual.results).to.have.length(3); // MANTOVANI (no-show) dropped
    expect(individual.results[0]).to.include({ swimmer: 'M|BENZI|CLAUDIO|1981|RINASCITA TEAM ROMAGNA', standard_points: 848.68 });
    expect(output.crawlerWarnings).to.have.length(2);
    expect(output.crawlerWarnings.join('\n')).to.match(/ASD POLISPORTIVA RICCIONE APS/);
    expect(output.crawlerWarnings.join('\n')).to.match(/1 no-show row/);
  });

  it('reuses the individual swimmer key for relay members of the same team', async () => {
    const relayRace = clone(raceById(MEETING_B, RELAY_RACE));
    const relayRow = clone(fixture.results[RELAY_RACE][0]);
    const indivRace = race({ eventRaceId: 'IND', eventRaceDescription: '50 STILE LIBERO MASTER 25 MASCHILE', sex: 'M', categoryId: 'M25' });
    const indivRow = row({ eventRaceMemberId: 'IR1', athleteName: 'BRIGLIADORI ANDREA', clubName: 'AQUATIC TEAM RAVENNA', birthYear: 1998 });
    const { crawler } = stubCrawler({
      event: { eventDescription: 'X', location: 'Ravenna' },
      races: [relayRace, indivRace],
      results: { [RELAY_RACE]: [relayRow], IND: [indivRow] },
      splits: { [relayRow.eventRaceMemberId]: fixture.splits[relayRow.eventRaceMemberId].splitDetails }
    });

    const output = await crawler.crawlFromApi({ eventId: 'E1' });
    const laps = output.events[0].results[0].laps;
    expect(laps[0].swimmer).to.equal('M|BRIGLIADORI|ANDREA|1998|AQUATIC TEAM RAVENNA');
    expect(laps[1].swimmer).to.equal('|ZANETTI|FEDERICO||AQUATIC TEAM RAVENNA');
    expect(Object.keys(output.swimmers).filter((key) => key.includes('BRIGLIADORI')))
      .to.deep.equal(['M|BRIGLIADORI|ANDREA|1998|AQUATIC TEAM RAVENNA']);
    expect(output.place).to.equal('Ravenna');
  });

  it('uses the race gender for members of single-gender relays', async () => {
    const relayRace = race({ eventRaceId: 'REL', eventRaceDescription: '4X50 STILE LIBERO STAFFETTA MASTER FEMMINILE', categoryId: 'M80S', length: 50 });
    const relayRow = row({
      eventRaceMemberId: 'RR1', athleteName: 'TEAM ONE', categoryId: 'M80S', raceTime: '02\'00"00', point: 0, point2: 800,
      relayTeamMembers: 'ROSSI ANNA<br/>DE LUCA MARIA<br/>BIANCHI EVA<br/>VERDI IDA'
    });
    const { crawler } = stubCrawler({
      races: [relayRace],
      results: { REL: [relayRow] },
      splits: { RR1: '00\'30"00-01\'00"00-01\'30"00-02\'00"00-' }
    });

    const output = await crawler.crawlFromApi({ eventId: 'E1' });
    const result = output.events[0].results[0];
    expect(output.events[0]).to.include({ eventCode: '4X50SL', eventGender: 'F', eventLength: '4X50' });
    expect(result).to.include({ category: '80-99', standard_points: 800 });
    expect(result.laps[1].swimmer).to.equal('F|DE LUCA|MARIA||TEAM ONE');
    expect(output.swimmers['F|DE LUCA|MARIA||TEAM ONE']).to.include({ gender: 'F', year: null });
  });

  it('probes the first 50 m results and skips 50 m splits when they carry no lap', async () => {
    const { crawler, apiClient } = stubCrawler({
      races: [
        race({ eventRaceId: 'R50A' }),
        race({ eventRaceId: 'R50B', categoryId: 'M40', eventRaceDescription: '50 STILE LIBERO MASTER 40 FEMMINILE' }),
        race({ eventRaceId: 'R100', length: 100, eventRaceDescription: '100 STILE LIBERO MASTER 35 FEMMINILE' })
      ],
      results: {
        R50A: [row({ eventRaceMemberId: 'a1' }), row({ eventRaceMemberId: 'a2', athleteName: 'NERI LIA' })],
        R50B: ['b1', 'b2', 'b3'].map((id, index) => row({ eventRaceMemberId: id, athleteName: `NAME${index} X`, categoryId: 'M40' })),
        R100: [row({ eventRaceMemberId: 'c1', raceTime: '01\'20"00' }), row({ eventRaceMemberId: 'c2', athleteName: 'NERI LIA', raceTime: '01\'21"00' })]
      },
      splits: { a1: '00\'38"00-', a2: '00\'38"00-', b1: '00\'38"00-' }
    });

    await crawler.crawlFromApi({ eventId: 'E1' });
    expect(apiClient.calls.loadSplits).to.deep.equal(['a1', 'a2', 'b1', 'c1', 'c2']);
  });

  it('fetches every 50 m split when a probe returns 25 m splits', async () => {
    const { crawler, apiClient } = stubCrawler({
      races: [race({ eventRaceId: 'R50A' })],
      results: {
        R50A: ['a1', 'a2', 'a3', 'a4'].map((id, index) => row({ eventRaceMemberId: id, athleteName: `NAME${index} X` }))
      },
      splits: { a1: '00\'18"00-00\'38"00-' }
    });

    const output = await crawler.crawlFromApi({ eventId: 'E1' });
    expect(apiClient.calls.loadSplits).to.deep.equal(['a1', 'a2', 'a3', 'a4']);
    expect(output.events[0].results[0].laps).to.deep.equal([
      { distance: '25m', timing: '18.00', delta: '18.00', position: null }
    ]);
  });

  it('applies the disqualified, no-show and unknown-status row rules', async () => {
    const realRow = fixture.results['9a5eac5a2fb842b1a80b910e2aa98f27'][0];
    const dsq = { ...clone(realRow), eventRaceMemberId: 'DSQ', raceTime: 'Squalif.', finalPosition: 1000, raceStatus: 'S' };
    const noShow = clone(fixture.results['9a5eac5a2fb842b1a80b910e2aa98f27'][3]);
    const odd = { ...clone(realRow), eventRaceMemberId: 'ODD', athleteName: 'STRANO ADA', raceTime: 'Rit.', finalPosition: 1000, raceStatus: 'R', calculationFlag: 'F' };
    const { crawler, apiClient } = stubCrawler({
      races: [
        clone(raceById(MEETING_B, '9a5eac5a2fb842b1a80b910e2aa98f27')),
        race({ eventRaceId: 'EMPTY' }),
        race({ eventRaceId: 'HIDDEN', raceStatus: '0' }),
        race({ eventRaceId: 'ENTRIES', raceStatus: '1' })
      ],
      results: { '9a5eac5a2fb842b1a80b910e2aa98f27': [dsq, noShow, odd] }
    });

    const output = await crawler.crawlFromApi({ eventId: 'E1' });
    expect(apiClient.calls.loadResults).to.deep.equal(['9a5eac5a2fb842b1a80b910e2aa98f27', 'EMPTY']);
    expect(apiClient.calls.loadSplits).to.deep.equal([]); // no timing, no splits
    expect(output.events).to.have.length(1);
    const [dsqResult, oddResult] = output.events[0].results;
    expect(output.events[0].results).to.have.length(2);
    expect(dsqResult).to.include({ disqualified: true, timing: null, ranking: null });
    expect(oddResult).to.include({ disqualified: false, timing: null, ranking: null, source_calculation_flag: 'F' });
    expect(output.crawlerWarnings.join('\n')).to.match(/status "R"/);
    expect(output.crawlerWarnings.join('\n')).to.match(/1 no-show row/);
  });

  it('fails when the meeting has no published results', async () => {
    const { crawler } = stubCrawler({ races: [race({ raceStatus: '1' })] });
    let error;
    try { await crawler.crawlFromApi({ eventId: 'E1' }); } catch (caught) { error = caught; }
    expect(error).to.be.an('error');
    expect(error.message).to.match(/no results/i);
  });
});
