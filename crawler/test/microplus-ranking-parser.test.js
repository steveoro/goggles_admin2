const fs = require('fs');
const path = require('path');
const { expect } = require('chai');
const MicroplusCrawler = require('../server/microplus-crawler');

describe('MicroplusCrawler - Ranking Results Parsing', () => {
    let microplusCrawler;

    beforeEach(() => {
        // Provide a dummy meetingURL for local file testing
        microplusCrawler = new MicroplusCrawler(242, 'test.html');
    });

    context('Processing ranking results...', () => {
        it('should correctly parse a ranking results HTML file', () => {
            // Load the sample HTML file
            const htmlFilePath = path.join(__dirname, '..', 'data', 'samples', '242-sample_microplus-ranking_results-200SL.html');
            const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');

            // Define the expected event info extracted from the filename
            const eventInfo = {
                baseName: '242-sample_microplus-ranking_results-200SL',
                eventCode: '200SL',
                isRelay: false,
                gender: 'F' // Assuming 'F' for now, will be part of the context later
            };

            // Process the HTML content
            const parsedData = microplusCrawler.processRankingResults(htmlContent, eventInfo);

            // Assertions
            expect(parsedData).to.be.an('object');
            expect(parsedData).to.have.property('results');
            expect(parsedData.results).to.be.an('array');
            expect(parsedData.results.length).to.equal(13);

            // Check the first result has expected keys and valid values
            const firstResult = parsedData.results[0];
            expect(firstResult).to.include.all.keys('ranking', 'lastName', 'firstName', 'team', 'year', 'timing', 'category');
            expect(firstResult.ranking).to.match(/^\d+/);
            expect(firstResult.timing).to.match(/^(\d+'\d{2}\.\d{2}|\d{1,2}\.\d{2})$/);

            // Check that at least one JACKSON exists with expected fields
            const anotherResult = parsedData.results.find(r => /JACKSON/i.test(r.lastName));
            expect(anotherResult).to.be.an('object');
            expect(anotherResult).to.include.keys('ranking', 'firstName', 'team', 'timing', 'category');
        });
    });
});
