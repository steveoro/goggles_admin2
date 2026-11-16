const fetch = require('node-fetch');
const { delay } = require('./ficr-crawler-utils');

const API_BASE_URL = 'https://risultati.goandswim.it/GasRestApi';
const USER_AGENT = 'Mozilla/5.0 (compatible; results-crawler)';
const ENDPOINTS = {
  event: 'publicevent/GetEventById',
  races: 'publiceventrace/getbyevent',
  race: 'publiceventrace/GetById',
  results: 'publiceventracemember/getResultsByRace',
  splits: 'publiceventracemember/getSplits'
};

class GoAndSwimApiClient {
  constructor({ apiBaseUrl = API_BASE_URL, fetchImpl = fetch, maxRetries = 2, requestDelayMs = 150 } = {}) {
    this.apiBaseUrl = apiBaseUrl;
    this.fetchImpl = fetchImpl;
    this.maxRetries = maxRetries;
    this.requestDelayMs = requestDelayMs;
  }

  async loadEvent(eventId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.event, eventId));
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
  }

  async loadRaces(eventId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.races, eventId));
    return Array.isArray(payload) ? payload : [];
  }

  async loadRace(eventRaceId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.race, eventRaceId));
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
  }

  async loadResults(eventRaceId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.results, eventRaceId));
    return Array.isArray(payload) ? payload : [];
  }

  async loadSplits(eventRaceMemberId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.splits, eventRaceMemberId));
    if (!payload || typeof payload !== 'object' || !payload.splitDetails) return null;
    return payload;
  }

  async request(url, init = {}) {
    let lastError;
    for (let attempt = 0; attempt <= this.maxRetries; attempt += 1) {
      try {
        if (this.requestDelayMs > 0) await delay(this.requestDelayMs);
        const response = await this.fetchImpl(url, {
          ...init,
          headers: {
            Accept: 'application/json',
            'User-Agent': USER_AGENT,
            ...(init.headers || {})
          }
        });
        if (!response.ok) throw new Error(`HTTP ${response.status} from ${url}`);
        return await response.json();
      } catch (error) {
        lastError = error;
        if (attempt < this.maxRetries) await delay(250 * (attempt + 1));
      }
    }
    throw lastError;
  }

  endpoint(name, id) {
    return `${this.apiBaseUrl}/${name}/${encodeURIComponent(String(id))}`;
  }
}

module.exports = GoAndSwimApiClient;
