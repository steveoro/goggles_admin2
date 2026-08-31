const fs = require('fs');
const os = require('os');
const path = require('path');
const { expect } = require('chai');
const ResultsCrawler = require('../server/results-crawler');

describe('ResultsCrawler - direct FIN URL mode', () => {
  let crawler;

  describe('input normalization', () => {
    it('returns a single synthetic row in direct mode', async () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://www.federnuoto.it/meeting');
      const rows = await crawler.buildInputRows();
      expect(rows).to.be.an('array').with.lengthOf(1);
      expect(rows[0].url).to.equal('https://www.federnuoto.it/meeting');
      expect(rows[0].cancelled).to.equal(false);
    });

    it('reads CSV rows in legacy mode', async () => {
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rc-test-'));
      const csvPath = path.join(tmpDir, 'test.csv');
      fs.writeFileSync(csvPath, 'startURL,date,isCancelled,name,place,meetingUrl,year\n,01/06,,Test Meeting,Rome,https://x.test/1,2024\n');
      try {
        crawler = new ResultsCrawler(242, csvPath, 2);
        const rows = await crawler.buildInputRows();
        expect(rows).to.be.an('array').with.lengthOf(1);
        expect(rows[0].url).to.equal('https://x.test/1');
        expect(rows[0].name).to.equal('Test Meeting');
      } finally {
        fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    });
  });

  describe('month normalization', () => {
    it('converts Italian month names to two-digit numbers', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test');
      expect(crawler.normalizeMonth('Aprile')).to.equal('04');
      expect(crawler.normalizeMonth('apr')).to.equal('04');
      expect(crawler.normalizeMonth('Maggio')).to.equal('05');
    });

    it('accepts numeric months', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test');
      expect(crawler.normalizeMonth('6')).to.equal('06');
      expect(crawler.normalizeMonth('12')).to.equal('12');
      expect(crawler.normalizeMonth('13')).to.be.null;
    });

    it('returns null for invalid months', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test');
      expect(crawler.normalizeMonth('')).to.be.null;
      expect(crawler.normalizeMonth('foo')).to.be.null;
    });
  });

  describe('direct output row building', () => {
    it('derives the output row from the extracted meeting header', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test/meeting');
      const meetingResult = {
        name: ' 1° Trofeo Città ',
        meetingURL: 'https://x.test/meeting',
        dateDay1: '15',
        dateMonth1: 'Maggio',
        dateYear1: '2024'
      };
      const row = crawler.buildDirectOutputRow(meetingResult);
      expect(row.url).to.equal('https://x.test/meeting');
      expect(row.dates).to.deep.equal(['2024-05-15']);
      expect(row.name).to.not.be.empty;
    });

    it('uses the xxx date fallback when header date is incomplete', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test/meeting');
      const meetingResult = {
        name: 'Incomplete',
        meetingURL: 'https://x.test/meeting'
      };
      const row = crawler.buildDirectOutputRow(meetingResult);
      expect(row.dates).to.deep.equal(['xxx']);
      expect(row.name).to.equal('Incomplete');
    });
  });

  describe('output filename generation', () => {
    it('uses the header-derived row for the direct output filename', () => {
      crawler = new ResultsCrawler(242, null, 2, 'https://x.test/meeting');
      const directRow = {
        url: 'https://x.test/meeting',
        name: 'Trofeo_Citta',
        dates: ['2024-05-15'],
        year: '2024',
        places: [],
        cancelled: false
      };
      const filename = crawler.getOutputJSONFilename(directRow);
      expect(filename).to.equal('2024-05-15-Trofeo_Citta');
    });

    it('keeps the legacy CSV row behavior for filename generation', () => {
      crawler = new ResultsCrawler(242, null, 2);
      const csvRow = {
        url: 'https://x.test/1',
        name: 'Test Meeting',
        dates: ['2024-06-01'],
        year: '2024',
        places: [],
        cancelled: false
      };
      const filename = crawler.getOutputJSONFilename(csvRow);
      expect(filename).to.equal('2024-06-01-Test_Meeting');
    });
  });
});
