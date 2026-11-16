const fs = require('fs');
const path = require('path');

const fixture = JSON.parse(fs.readFileSync(
  path.resolve(__dirname, '../../data/samples/goandswim/goandswim-sample.json'),
  'utf8'
));

function response(body) {
  return { ok: true, status: 200, json: async () => body };
}

// Serves the Go&Swim sample fixture by parsing the request URL path.
function fixtureFetch(url) {
  const parts = new URL(url).pathname.split('/').filter(Boolean);
  const id = decodeURIComponent(parts.at(-1));
  const endpoint = parts.at(-2).toLowerCase();

  if (endpoint === 'geteventbyid') return response(fixture.events[id] ?? null);
  if (endpoint === 'getbyevent') return response(fixture.races[id] ?? []);
  if (endpoint === 'getbyid') return response(fixture.race[id] ?? null);
  if (endpoint === 'getresultsbyrace') return response(fixture.results[id] ?? []);
  if (endpoint === 'getsplits') return response(fixture.splits[id] ?? null);
  throw new Error(`No fixture for ${url}`);
}

module.exports = { fixture, fixtureFetch };
