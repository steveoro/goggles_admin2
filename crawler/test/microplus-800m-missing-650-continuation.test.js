const path = require('path');
const fs = require('fs');
const cheerio = require('cheerio');
const MicroplusCrawler = require('../server/microplus-crawler');

let expect;

describe('MicroplusCrawler - 800m continuation with missing 650m cell', () => {
  let crawler;

  before(async () => {
    const chai = await import('chai');
    expect = chai.expect;
  });

  beforeEach(() => {
    crawler = new MicroplusCrawler(242, 'local-test.html');
  });

  it('should keep mapping aligned and still append 700m and 750m when 650m cell is empty', () => {
    const sampleHtmlPath = path.resolve(__dirname, '../data/samples/242-sample_microplus-heat_results-800SL.html');
    const html = fs.readFileSync(sampleHtmlPath, 'utf8');

    // Load and blank the 5th continuation split cell (which corresponds to 650m)
    const $ = cheerio.load(html);
    const contRows = $('table.tblContenutiRESSTL_Sotto_Heats tr').filter((_, tr) => {
      const $tr = $(tr);
      const tds = $tr.find('td');
      if (tds.length < 3) return false;
      const firstTd = tds.eq(0);
      const colspan = parseInt(firstTd.attr('colspan') || '0', 10);
      const tdContSmallCount = $tr.find('td.tdContSmall').length;
      return (colspan >= 7 || tdContSmallCount >= 6);
    });
    expect(contRows.length, 'No continuation rows found in sample').to.be.greaterThan(0);

    // For the first detected continuation row, blank the 5th split cell
    const row = contRows.first();
    const tds = row.find('td');
    const startIdx = (tds.eq(0).attr('colspan') ? 1 : 0);
    const splitCells = tds.slice(startIdx);
    // i=0->450,1->500,2->550,3->600,4->650 (blank this one)
    const idx650 = startIdx + 4;
    if (tds.get(idx650)) {
      tds.eq(idx650).text('');
    }

    const modifiedHtml = $.html();
    const parsed = crawler.processHeatResults(modifiedHtml);

    expect(parsed).to.have.property('heats');
    expect(parsed.heats.length).to.be.greaterThan(0);

    // Find any result with continuation splits appended
    let found = null;
    for (const heat of parsed.heats) {
      for (const res of (heat.results || [])) {
        const lbls = (res.laps || []).map(l => l.distance);
        if (lbls.includes('450m')) { found = res; break; }
      }
      if (found) break;
    }
    expect(found, 'No result with 450m continuation lap found').to.not.be.null;

    const labels = found.laps.map(l => l.distance);
    // 650m for this particular row was blanked; mapping should still allow 700m and 750m to be appended
    // Note: other continuation rows may legitimately include 650m, so we don't forbid it globally here
    expect(labels).to.include('700m');
    expect(labels).to.include('750m');

    // Sanity: order should remain increasing at tail
    const tail = labels.filter(l => /^(45|5\d\d|6\d\d|7\d\d)m$/.test(l));
    const meters = tail.map(d => parseInt(d.replace(/m$/, ''), 10));
    const sorted = [...meters].sort((a,b)=>a-b);
    expect(meters, 'Continuation distances are not sorted/increasing').to.deep.equal(sorted);
  });
});
