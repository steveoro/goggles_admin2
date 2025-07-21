const path = require('path');
const fs = require('fs');
const cheerio = require('cheerio');
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
    const sampleHtmlPath = path.resolve(__dirname, '../data/results.new/242-sample_microplus-heat_results-200SL.html');
    const html = fs.readFileSync(sampleHtmlPath, 'utf8');
    const $ = cheerio.load(html);

    const parsedData = crawler.processHeatResults($);


    // 2. Check number of heats found
    expect(parsedData.heats).to.be.an('array').with.lengthOf(2);
    expect(parsedData.heats[0].heatTitle).to.include('Serie 1');
    expect(parsedData.heats[1].heatTitle).to.include('Serie 2');

    // 3. Check the number of results in the first heat
    const firstHeatResults = parsedData.heats[0].results;
    expect(firstHeatResults).to.be.an('array').with.lengthOf(10);

    // 4. Deep check of the first result in the first heat
    const firstResult = firstHeatResults[0];
    expect(firstResult.heatPosition).to.equal('1');
    expect(firstResult.lane).to.equal('4');
    expect(firstResult.nation).to.equal('ITA');
    expect(firstResult.lastName).to.equal('JACKSON');
    expect(firstResult.firstName).to.equal('Cristina');
    expect(firstResult.yearOfBirth).to.equal('1955');
    expect(firstResult.team).to.equal('Circolo Canottieri Aniene');
    expect(firstResult.timing).to.equal("2'43.55");

    // 5. Check laps for the first result
    expect(firstResult.laps).to.be.an('array').with.lengthOf(3);
    expect(firstResult.laps[0].lapTiming).to.equal('37.94');
    expect(firstResult.laps[1].lapTiming).to.equal("1'19.44");
    expect(firstResult.laps[1].lapDelta).to.equal('41.50');
    expect(firstResult.laps[2].lapTiming).to.equal("2'01.27");
    expect(firstResult.laps[2].lapDelta).to.equal('41.83');
  });
});

