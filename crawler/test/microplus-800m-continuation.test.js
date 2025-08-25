const path = require('path');
const fs = require('fs');
const MicroplusCrawler = require('../server/microplus-crawler');

let expect;

describe('MicroplusCrawler - 800m continuation row parsing', () => {
  let crawler;

  before(async () => {
    const chai = await import('chai');
    expect = chai.expect;
  });

  beforeEach(() => {
    crawler = new MicroplusCrawler(242, 'local-test.html');
  });

  it('should append continuation laps (>=450m) from second row to the last result', () => {
    const sampleHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-heat_results-800SL.html');
    const html = fs.readFileSync(sampleHtmlPath, 'utf8');

    const parsed = crawler.processHeatResults(html);
    expect(parsed).to.have.property('heats');
    expect(parsed.heats.length).to.be.greaterThan(0);

    // Find a result that has 450m split, which should come from continuation row
    let found = null;
    for (const heat of parsed.heats) {
      for (const res of (heat.results || [])) {
        const lapLabels = (res.laps || []).map(l => (l.distance || '').toLowerCase());
        if (lapLabels.includes('450m')) { found = res; break; }
      }
      if (found) break;
    }

    expect(found, 'No result with 450m continuation lap found').to.not.be.null;

    const labels = found.laps.map(l => l.distance);
    // Ensure we have both primary (<450m) and continuation (>=450m) laps
    expect(labels).to.include('50m');
    expect(labels).to.include('400m');
    expect(labels).to.include('450m');
    // May or may not include 700m depending on sample; ensure at least 450m exists

    // Sanity check: lap entries should carry timing and optional delta
    const lap450 = found.laps.find(l => l.distance === '450m');
    expect(lap450).to.have.property('timing');
  });
});
