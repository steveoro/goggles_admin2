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
            const htmlFilePath = path.join(__dirname, '..', 'data', 'results.new', '242-sample_microplus-ranking_results-200SL.html');
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
            expect(parsedData).to.be.an('array');
            expect(parsedData).to.have.lengthOf(13); // Check if it finds a good number of results

            // Check the first result in detail (JOHNSON Maria Luisa)
            const firstResult = parsedData[0];
            expect(firstResult).to.deep.equal({
                ranking: '1',
                lane: '9',
                lastName: 'JOHNSON',
                firstName: 'Maria Luisa',
                yearOfBirth: '1943',
                team: 'CSM Swim Team asd',
                timing: "5'48.00",
                category: 'MASTER 80F'
            });

            // Check another result (JACKSON Cristina)
            const anotherResult = parsedData.find(r => r.lastName === 'JACKSON');
            expect(anotherResult).to.deep.equal({
                ranking: '1',
                lane: '4',
                lastName: 'JACKSON',
                firstName: 'Cristina',
                yearOfBirth: '1955',
                team: 'Circolo Canottieri Aniene',
                timing: "2'44.59",
                category: 'MASTER 65F'
            });
        });
    });
});
