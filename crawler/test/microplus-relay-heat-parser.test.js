const path = require('path');
const fs = require('fs');
const MicroplusCrawler = require('../server/microplus-crawler');

let expect;

describe('MicroplusCrawler - Relay Heat Results Parsing (4x50)', () => {
  let crawler;

  before(async () => {
    const chai = await import('chai');
    expect = chai.expect;
  });

  beforeEach(() => {
    crawler = new MicroplusCrawler(242, 'local-test.html');
    crawler.debug = false;
  });

  it('should parse a 4x50 relay heat page and extract relay blocks with swimmers and laps', () => {
    const sampleHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-heat_results-4x50SL.html');
    const html = fs.readFileSync(sampleHtmlPath, 'utf8');
    const parsed = crawler.processHeatResults(html);

    expect(parsed).to.be.an('object');
    expect(parsed).to.have.property('heats').that.is.an('array').with.length.greaterThan(0);

    // Find at least one relay result in the heats
    const relayResults = parsed.heats.flatMap(h => h.results).filter(r => r.relay === true);
    expect(relayResults.length).to.be.greaterThan(0);

    const firstRelay = relayResults[0];
    expect(firstRelay).to.include.all.keys('relay', 'relay_name', 'team', 'heat', 'lane', 'timing', 'swimmers', 'laps');
    expect(firstRelay.relay).to.equal(true);
    expect(firstRelay.swimmers).to.be.an('array').with.lengthOf(4);
    expect(firstRelay.laps).to.be.an('array').with.lengthOf(4);
    // Lap entries should carry per-leg delta (if available)
    expect(firstRelay.laps[0]).to.have.property('distance');
    expect(firstRelay.laps[0]).to.have.property('delta');
  });
});
