const { expect } = require('chai');
const CalendarCrawler = require('../server/calendar-crawler');

// The "cancelled" flag of the layout 2 calendar rows (the FIN "Eventi" and "Archivio" pages): no network needed.
describe('CalendarCrawler - cancelled rows', () => {
  const { isCancelledTitle } = CalendarCrawler;

  it('flags every cancelled title, also two in a row', () => {
    const titles = ['Trofeo Città di Napoli - ANNULLATO', 'Meeting annullata', 'Annullato: 3° Trofeo', 'Trofeo Regolare'];
    expect(titles.map(isCancelledTitle)).to.deep.equal([true, true, true, false]);
  });

  it('shows why a shared /g regexp was wrong (lastIndex kept between calls)', () => {
    const shared = /annull/gi;
    expect(shared.test('Meeting della Solidarietà ANNULLATO')).to.equal(true);
    expect(shared.test('Trofeo annullato')).to.equal(false); // the bug the helper avoids
    expect(isCancelledTitle('Meeting della Solidarietà ANNULLATO')).to.equal(true);
    expect(isCancelledTitle('Trofeo annullato')).to.equal(true);
  });

  it('is false for blank titles', () => {
    expect([undefined, null, ''].map(isCancelledTitle)).to.deep.equal([false, false, false]);
  });

  it('is self-contained, as injected into the calendar page', () => {
    const injected = new Function(`${isCancelledTitle.toString()}; return isCancelledTitle`)();
    expect(['Gara annullata', 'Gara annullata', 'Gara'].map(injected)).to.deep.equal([true, true, false]);
  });

  it('is the check used by the layout 2 scanner, with no global regexp left', () => {
    const source = CalendarCrawler.prototype.processCalendarLayout2.toString();
    expect(source).to.include('isCancelledTitle(name)');
    expect(source).to.include('addScriptTag({ content: isCancelledTitle.toString() })');
    expect(source).not.to.match(/\/annull\/g/);
  });
});
