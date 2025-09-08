const fs = require('fs');
const path = require('path');
const { expect } = require('chai');
const MicroplusCrawler = require('../server/microplus-crawler');

describe('MicroplusCrawler - Relay Ranking Results Parsing (4x50)', () => {
  let microplusCrawler;

  beforeEach(() => {
    microplusCrawler = new MicroplusCrawler(242, 'test.html');
  });

  it('should parse a relay RIEPILOGO page and extract relay summary rows', () => {
    const htmlFilePath = path.join(__dirname, '..', 'data', 'samples', '242-sample_microplus-ranking_results-4x50SL.html');
    const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');

    const parsedData = microplusCrawler.processRankingResults(htmlContent, { isRelay: true });

    expect(parsedData).to.be.an('object');
    expect(parsedData).to.have.property('results');
    expect(parsedData.results).to.be.an('array');

    // Prefer relay rows if present; some Microplus templates list individuals even for relay summaries
    const relayRows = parsedData.results.filter(r => r.relay === true);
    if (relayRows.length > 0) {
      const first = relayRows[0];
      expect(first).to.include.all.keys('relay', 'ranking', 'heat', 'lane', 'relay_name', 'team', 'timing', 'category');
      if (first.categoryRange) {
        expect(first.categoryRange).to.match(/^\d{2,3}-\d{2,3}$/);
      }
    } else {
      // Fallback validation for individual-like rows on relay pages
      const first = parsedData.results[0];
      expect(first).to.include.all.keys('ranking', 'team', 'timing', 'category');
    }
  });
});
