const path = require('path');
const fs = require('fs');
const { expect } = require('chai');
const MicroplusCrawler = require('../server/microplus-crawler');
const CrawlUtil = require('../server/utility');

// helpers mirroring crawler merge logic
const norm = (s) => (s || '').toString().normalize('NFKC').replace(/\u00A0/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();
const simplifyTime = (t) => norm(t).replace(/[^0-9':.]/g, '');

describe('MicroplusCrawler - Relay merge attaches swimmers and laps', () => {
  let crawler;

  beforeEach(() => {
    crawler = new MicroplusCrawler(242, 'local');
  });

  it('matches RIEPILOGO relay rows to heat relay results and sees swimmers/laps', () => {
    const heatHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-heat_results-4x50SL.html');
    const rankHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-ranking_results-4x50SL.html');

    const heatHtml = fs.readFileSync(heatHtmlPath, 'utf8');
    const rankHtml = fs.readFileSync(rankHtmlPath, 'utf8');

    const heatData = crawler.processHeatResults(heatHtml);
    const rankingData = crawler.processRankingResults(rankHtml, { isRelay: true });

    // Build heatResultsMap keyed by relay key
    const heatResultsMap = new Map();
    for (const h of heatData.heats) {
      for (const r of h.results) {
        if (r.relay) {
          const relayKey = CrawlUtil.createRelayKey(r.relay_name, r.team, r.heat, r.lane, r.timing);
          heatResultsMap.set(relayKey, r);
        }
      }
    }

    // Ensure we have at least one relay in ranking
    const rankingRelays = (rankingData.results || []).filter(r => r.relay === true);
    expect(rankingRelays.length).to.be.greaterThan(0);

    // Try to find a matching heatResult for at least one ranking relay, using relaxed matching
    const found = rankingRelays.some(rr => {
      // exact key
      let hr = heatResultsMap.get(CrawlUtil.createRelayKey(rr.relay_name, rr.team, rr.heat, rr.lane, rr.timing));
      if (!hr) {
        const base = norm((rr.relay_name && rr.relay_name.length > 0) ? rr.relay_name : rr.team);
        const heatStr = norm(rr.heat || '');
        const timeStr = simplifyTime(rr.timing || '');
        hr = Array.from(heatResultsMap.values()).find(hv => hv.relay === true &&
          (norm(hv.relay_name || '') === base || norm(hv.team || '') === base) &&
          norm(hv.heat || '') === heatStr &&
          simplifyTime(hv.timing || '') === timeStr
        ) || null;
        if (!hr) {
          hr = Array.from(heatResultsMap.values()).find(hv => hv.relay === true &&
            (norm(hv.relay_name || '') === base || norm(hv.team || '') === base) &&
            simplifyTime(hv.timing || '') === timeStr
          ) || null;
        }
        if (!hr) {
          hr = Array.from(heatResultsMap.values()).find(hv => hv.relay === true &&
            (norm(hv.relay_name || '') === base || norm(hv.team || '') === base)
          ) || null;
        }
      }
      if (!hr) return false;
      // Assert swimmers and laps exist
      expect(hr.swimmers).to.be.an('array').with.lengthOf(4);
      expect(hr.laps).to.be.an('array').with.length.greaterThan(0);
      // Each lap should belong to a swimmer key if provided
      if (hr.laps[0] && hr.laps[0].swimmer) {
        const keys = new Set(hr.swimmers.map(s => s.key));
        expect(keys.has(hr.laps[0].swimmer)).to.equal(true);
      }
      return true;
    });

    expect(found, 'No matching heat relay found for any ranking relay using relaxed matching').to.equal(true);
  });
});
