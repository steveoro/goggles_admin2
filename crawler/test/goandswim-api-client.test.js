const { expect } = require('chai');
const GoAndSwimApiClient = require('../server/goandswim-api-client');
const { fixture, fixtureFetch } = require('./support/goandswim-fixture-fetch');

const BASE = 'https://risultati.goandswim.it/GasRestApi';
const EVENT_ID = '5ce2d74fd05d4a659b511251caec6132';
const RACE_ID = '2ca8343b39aa4c859fe28d9a6dcb04e8';
const MEMBER_ID = 'd39f4e61ba244b248f3ac9c31ecd30c3';

function response(body, { ok = true, status = 200 } = {}) {
  return { ok, status, json: async () => body };
}

function recorder(body) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return response(body);
  };
  return { calls, fetchImpl };
}

describe('GoAndSwimApiClient', () => {
  it('builds the URL of each endpoint and sends generic headers', async () => {
    const { calls, fetchImpl } = recorder({});
    const client = new GoAndSwimApiClient({ fetchImpl, requestDelayMs: 0 });

    await client.loadEvent(EVENT_ID);
    await client.loadRaces(EVENT_ID);
    await client.loadRace(RACE_ID);
    await client.loadResults(RACE_ID);
    await client.loadSplits(MEMBER_ID);

    expect(calls.map((c) => c.url)).to.deep.equal([
      `${BASE}/publicevent/GetEventById/${EVENT_ID}`,
      `${BASE}/publiceventrace/getbyevent/${EVENT_ID}`,
      `${BASE}/publiceventrace/GetById/${RACE_ID}`,
      `${BASE}/publiceventracemember/getResultsByRace/${RACE_ID}`,
      `${BASE}/publiceventracemember/getSplits/${MEMBER_ID}`
    ]);
    expect(calls[0].init.headers.Accept).to.equal('application/json');
    expect(calls[0].init.headers['User-Agent']).to.be.a('string').and.not.empty;
  });

  it('honours a custom apiBaseUrl', async () => {
    const { calls, fetchImpl } = recorder([]);
    const client = new GoAndSwimApiClient({ apiBaseUrl: 'http://localhost:1/api', fetchImpl, requestDelayMs: 0 });
    await client.loadRaces(EVENT_ID);
    expect(calls[0].url).to.equal(`http://localhost:1/api/publiceventrace/getbyevent/${EVENT_ID}`);
  });

  it('serves the fixture through the shared helper', async () => {
    const client = new GoAndSwimApiClient({ fetchImpl: fixtureFetch, requestDelayMs: 0 });

    const event = await client.loadEvent(EVENT_ID);
    expect(event.eventDescription).to.equal('23° Trofeo DE AKKER');
    expect((await client.loadRaces(EVENT_ID)).length).to.equal(fixture.races[EVENT_ID].length);
    expect((await client.loadRace(RACE_ID)).length).to.equal(800);
    expect(await client.loadResults(RACE_ID)).to.have.length(2);
    expect((await client.loadSplits(MEMBER_ID)).splitDetails).to.match(/^01'21"11-/);
    expect(await client.loadResults('unknown')).to.deep.equal([]);
    expect(await client.loadRaces('unknown')).to.deep.equal([]);
    expect(await client.loadSplits('unknown')).to.equal(null);
  });

  it('retries a failing request and then succeeds', async () => {
    let attempts = 0;
    const fetchImpl = async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('network down');
      if (attempts === 2) return response(null, { ok: false, status: 503 });
      return response([{ eventRaceId: RACE_ID }]);
    };
    const client = new GoAndSwimApiClient({ fetchImpl, requestDelayMs: 0, maxRetries: 2 });
    const races = await client.loadRaces(EVENT_ID);
    expect(attempts).to.equal(3);
    expect(races).to.have.length(1);
  });

  it('throws after the retries are exhausted', async () => {
    let attempts = 0;
    const fetchImpl = async () => {
      attempts += 1;
      return response(null, { ok: false, status: 500 });
    };
    const client = new GoAndSwimApiClient({ fetchImpl, requestDelayMs: 0, maxRetries: 1 });
    let error;
    try {
      await client.loadEvent(EVENT_ID);
    } catch (e) {
      error = e;
    }
    expect(error).to.be.instanceOf(Error);
    expect(error.message).to.match(/HTTP 500/);
    expect(attempts).to.equal(2);
  });

  it('returns empty defaults for null or malformed bodies', async () => {
    const client = new GoAndSwimApiClient({ fetchImpl: async () => response(null), requestDelayMs: 0 });
    expect(await client.loadRaces(EVENT_ID)).to.deep.equal([]);
    expect(await client.loadResults(RACE_ID)).to.deep.equal([]);
    expect(await client.loadSplits(MEMBER_ID)).to.equal(null);

    const odd = new GoAndSwimApiClient({ fetchImpl: async () => response({ foo: 1 }), requestDelayMs: 0 });
    expect(await odd.loadResults(RACE_ID)).to.deep.equal([]);
    expect(await odd.loadSplits(MEMBER_ID)).to.equal(null);

    const noDetails = new GoAndSwimApiClient({ fetchImpl: async () => response({ splitDetails: '' }), requestDelayMs: 0 });
    expect(await noDetails.loadSplits(MEMBER_ID)).to.equal(null);
  });

  it('returns null splits for a 404, an empty body or invalid JSON without retrying', async () => {
    const invalid = () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError('Unexpected end of JSON input'); } });
    for (const reply of [() => response(null, { ok: false, status: 404 }), invalid]) {
      let attempts = 0;
      const client = new GoAndSwimApiClient({
        fetchImpl: async () => { attempts += 1; return reply(); },
        requestDelayMs: 0,
        maxRetries: 2
      });
      expect(await client.loadSplits(MEMBER_ID)).to.equal(null);
      expect(attempts).to.equal(1);
    }
  });

  it('still throws on a 404 for the other endpoints', async () => {
    const client = new GoAndSwimApiClient({ fetchImpl: async () => response(null, { ok: false, status: 404 }), requestDelayMs: 0, maxRetries: 0 });
    let error;
    try { await client.loadResults(RACE_ID); } catch (caught) { error = caught; }
    expect(error).to.be.instanceOf(Error);
    expect(error.message).to.match(/HTTP 404/);
  });
});
