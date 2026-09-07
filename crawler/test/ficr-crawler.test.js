const fs = require('fs');
const path = require('path');
const { expect } = require('chai');
const FicrCrawler = require('../server/ficr-crawler');

const fixture = JSON.parse(fs.readFileSync(
  path.resolve(__dirname, '../data/samples/ficr/ficr-brescia.json'),
  'utf8'
));

const meetingUrl = "https://nuoto.ficr.it/#/NUO/tempi/25'%20TROFEO%20ACSI%20CITTA'%20DI%20BRESCIA/2023/29/5/AAF/3";

function response(body) {
  return { ok: true, status: 200, json: async () => body };
}

function fixtureFetch(url) {
  const pathname = new URL(url).pathname;
  const parts = pathname.split('/').filter(Boolean);
  const endpoint = parts.slice(2).join('/');
  const values = endpoint.split('/');
  const marker = values.indexOf('get');
  const type = values[marker + 1];

  if (type === 'descrizione') return response(fixture.description);
  if (type === 'categorie') return response(fixture.categories);
  if (type === 'gare') return response(fixture.events[values.at(-1)]);
  if (type === 'sottocategorie') {
    return response(fixture.subcategories[`${values.at(-2)}/${values.at(-1)}`]);
  }
  if (type === 'result') {
    return response(fixture.results[`${values.at(-5)}/${values.at(-4)}/${values.at(-1)}`]);
  }
  if (type === 'atleta') return response(fixture.athletes[values.at(-1)]);
  throw new Error(`No fixture for ${url}`);
}

describe('FicrCrawler', () => {
  it('parses a FICR hash URL and normalizes category codes', () => {
    const crawler = new FicrCrawler(242, meetingUrl, { fetchImpl: fixtureFetch });
    const source = crawler.parseMeetingUrl();

    expect(source).to.include({ year: '2023', eqCode: '29', meeting: '5', category: 'AAF', event: '3' });
    expect(crawler.normalizeCategory('25F', [
      { ct_Categoria: '25F', ct_Descrizione: 'M25 Master Femmine 25 - 29' }
    ], false)).to.equal('M25');
    expect(crawler.normalizeCategory('10X', [
      { ct_Categoria: '10X', ct_Descrizione: 'Master Misti 100 - 119' }
    ], true)).to.equal('100-119');
  });

  it('builds LT4 events, category-bound ranks, points, and laps from API payloads', async () => {
    const crawler = new FicrCrawler(242, meetingUrl, { fetchImpl: fixtureFetch, maxRetries: 0 });
    const output = await crawler.crawlFromApi(crawler.parseMeetingUrl());

    expect(output.layoutType).to.equal(4);
    expect(output.meetingName).to.equal("25' TROFEO ACSI CITTA' DI BRESCIA");
    expect(output.dates).to.equal('2023-01-29');
    expect(output.place).to.equal('BRESCIA');
    expect(output.events).to.have.lengthOf(2);

    const individualEvent = output.events.find((event) => event.relay === false);
    const individual = individualEvent.results[0];
    expect(individual).to.include({ ranking: 1, category: 'M25', timing: '29.83', lane: 5 });
    expect(individual.standard_points).to.equal(812);
    expect(individual.team_points).to.equal(3);
    expect(individual.meeting_points).to.equal(7);
    expect(individual.laps.map((lap) => lap.distance)).to.deep.equal(['50m', '100m', '200m']);
    expect(individual.laps[1].delta).to.equal("37.90");
    expect(output.swimmers[individual.swimmer]).to.include({ gender: 'F', year: 1997 });

    const relayEvent = output.events.find((event) => event.relay === true);
    expect(relayEvent.eventCode).to.equal('4X50SL');
    expect(relayEvent.eventGender).to.equal('X');
    expect(relayEvent.results[0]).to.include({ ranking: 1, category: '100-119', relay: true });
    expect(relayEvent.results[0].standard_points).to.equal(null);
  });

  it('continues with a fallback loader when direct API acquisition fails', async () => {
    const crawler = new FicrCrawler(242, meetingUrl, {
      fetchImpl: async () => ({ ok: false, status: 503, json: async () => ({}) }),
      maxRetries: 0,
      fallbackLoader: async () => ({ layoutType: 4, events: [], swimmers: {}, teams: {} })
    });

    const output = await crawler.run();
    expect(output.layoutType).to.equal(4);
    expect(output.events).to.deep.equal([]);
    expect(output.crawlerWarnings[0]).to.match(/trying browser fallback/i);
  });

  it('computes cumulative lap deltas', () => {
    expect(FicrCrawler.deltaTiming("1'10.27", '32.37')).to.equal('37.90');
    expect(FicrCrawler.deltaTiming('29.83', null)).to.equal('29.83');
  });
});
