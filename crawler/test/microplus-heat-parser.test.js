const path = require('path');
const fs = require('fs');
const MicroplusCrawler = require('../server/microplus-crawler');

let expect;

describe('MicroplusCrawler - Heat Results Parsing', () => {
  let crawler;

  // Use a before hook to dynamically import chai and get the expect function
  before(async () => {
    const chai = await import('chai');
    expect = chai.expect;
  });

  beforeEach(() => {
    // The URL doesn't matter for local testing, but it's required by the constructor.
    crawler = new MicroplusCrawler(242, 'local-test.html');
    crawler.debug = false; // Disable verbose output for tests
  });

  it('should correctly parse a heat results HTML file', () => {
    const sampleHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-heat_results-200SL.html');
    const html = fs.readFileSync(sampleHtmlPath, 'utf8');
    const parsedData = crawler.processHeatResults(html);

    // Heats found
    expect(parsedData.heats).to.be.an('array');
    expect(parsedData.heats.length).to.be.greaterThan(0);
    // Current parser stores heat number as `number`
    expect(parsedData.heats[0]).to.have.property('number');

    // 3. Check the number of results in the first heat
    const firstHeatResults = parsedData.heats[0].results;
    expect(firstHeatResults).to.be.an('array');
    expect(firstHeatResults.length).to.be.greaterThan(0);

    // 4. Deep check of the first result in the first heat
    const firstResult = firstHeatResults[0];
    expect(firstResult).to.have.property('heat_position');
    expect(firstResult).to.have.property('lane');
    expect(firstResult).to.have.property('nation');
    expect(firstResult).to.have.property('lastName').that.is.a('string');
    expect(firstResult).to.have.property('firstName').that.is.a('string');
    expect(firstResult).to.have.property('year').that.matches(/^\d{4}$|^N\/A$/);
    expect(firstResult).to.have.property('team').that.is.a('string');
    expect(firstResult).to.have.property('timing').that.matches(/^(\d+'\d{2}\.\d{2}|\d{1,2}\.\d{2})$/);

    // 5. Check laps for the first result
    expect(firstResult.laps).to.be.an('array');
    expect(firstResult.laps.length).to.be.greaterThan(0);
    // Lap shape: { distance, timing, position?, delta? }
    expect(firstResult.laps[0]).to.have.property('timing');
  });
});

