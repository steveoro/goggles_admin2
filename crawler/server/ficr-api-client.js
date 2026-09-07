const fetch = require('node-fetch');
const { delay, encodeSegment } = require('./ficr-crawler-utils');

const API_BASE_URL = 'https://apinuoto.ficr.it/NUO';
const ENDPOINTS = {
  description: 'mpcache-30/get/descrizione',
  categories: 'mpcache-30/get/categorie',
  events: 'mpcache-30/get/gare',
  subcategories: 'mpcache-30/get/sottocategorie',
  results: 'mpcache-10/get/result',
  athlete: 'mpcache-30/get/atleta'
};

class FicrApiClient {
  constructor({ apiBaseUrl = API_BASE_URL, fetchImpl = fetch, maxRetries = 2, requestDelayMs = 0 } = {}) {
    this.apiBaseUrl = apiBaseUrl;
    this.fetchImpl = fetchImpl;
    this.maxRetries = maxRetries;
    this.requestDelayMs = requestDelayMs;
  }

  async loadDescription(source) {
    const payload = await this.request(this.endpoint(ENDPOINTS.description, source.year, source.eqCode, source.meeting));
    return Array.isArray(payload.data) ? (payload.data[0] || {}) : {};
  }

  async loadCategories(source) {
    const payload = await this.request(this.endpoint(ENDPOINTS.categories, source.year, source.eqCode, source.meeting));
    return Array.isArray(payload.data) ? payload.data : [];
  }

  async loadEvents(source, categoryId) {
    const payload = await this.request(this.endpoint(ENDPOINTS.events, source.year, source.eqCode, source.meeting, categoryId));
    return Array.isArray(payload.data) ? payload.data : [];
  }

  async loadSubcategories(source, categoryId, eventId) {
    const payload = await this.request(this.endpoint(
      ENDPOINTS.subcategories,
      source.year,
      source.eqCode,
      source.meeting,
      categoryId,
      eventId
    ));
    return Array.isArray(payload.data) ? payload.data : [];
  }

  async loadResults(source, categoryId, eventId, subcategoryId) {
    const payload = await this.request(this.endpoint(
      ENDPOINTS.results,
      source.year,
      source.eqCode,
      source.meeting,
      categoryId,
      eventId,
      '*',
      '*',
      subcategoryId || '*'
    ));
    return payload.data && typeof payload.data === 'object' ? payload.data : {};
  }

  async loadAthlete(source, athleteId) {
    const payload = await this.request(this.endpoint(
      ENDPOINTS.athlete,
      source.year,
      source.eqCode,
      source.meeting,
      athleteId
    ));
    return payload.data && typeof payload.data === 'object' ? payload.data : {};
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
            ...(init.headers || {})
          }
        });
        if (!response.ok) throw new Error(`HTTP ${response.status} from ${url}`);
        const payload = await response.json();
        if (!payload || payload.code !== 200 || payload.status === false) {
          throw new Error(`Invalid FICR response from ${url}`);
        }
        return payload;
      } catch (error) {
        lastError = error;
        if (attempt < this.maxRetries) await delay(250 * (attempt + 1));
      }
    }
    throw lastError;
  }

  endpoint(name, ...segments) {
    return `${this.apiBaseUrl}/${name}/${segments.map(encodeSegment).join('/')}`;
  }
}

module.exports = FicrApiClient;
