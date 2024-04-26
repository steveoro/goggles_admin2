## Relevant Version History / current working features:

_Please, add the latest build info on top of the list; use Version::MAJOR only after gold release; keep semantic versioning in line with framework's_

- **0.7.10** [Steve A.] re-sync w/ base engine & bundle update; added support for IndividualRecords in Merge::Swimmer/Checker; added filtered CSV export for (localhost) Meetings with zero MIRs; added auto-download for manifests & PDF results during calendar processing with the resultCrawler;
- **0.7.09** [Steve A.] re-sync w/ base engine & bundle update; added Merge::Swimmer & Merge::SwimmerChecker + related rake tasks;
- **0.7.08** [Steve A.] re-sync w/ base engine; bundle update; swimmer merge checker backbone
- **0.7.00** [Steve A.] update to Rails 6.1.7; specs adjustments
- **0.6.12** [Steve A.] Re-sync w/ base engine (0.6.10); updated bundle; support for RelayLaps (relay sub-laps) in MacroSolver & MacroCommitter
- **0.6.00** [Steve A.] upgrade to Ruby 3.1.4
- **0.5.22** [Steve A.] added support for account reactivation request w/ email send; added pass-through filtering parameters for all grids from row actions, including the edit modal; added button links to show filtered lists of specific sub-entities from an associated row (i.e.: from a badge to a team affiliation grid); re-sync w/ base engine & API; bundle update
- **0.5.05** [Steve A.] check & fix actions for the issue controller; additional components & specs
- **0.5.04** [Steve A.] issues controller w/ crude handing (low-level edit)
- **0.5.03** [Steve A.] resync w/ base engine: slight change in ImportQueueDecorator so that #chrono_delta_label can be called also on master chrono rows
- **0.4.25** [Steve A.] make sure that calendar rows do not get consumed unless actual result nodes are found
- **0.4.23** [Steve A.] ensure dest. paths exist when moving files; ensure proper swimmer key is used for internal entity cache, even for same-named swimmers; extended debug & data-fix; improved display for row action toolbar in grids & other minor updates; added auto-detection for corrupted result files (containing a 'retry' error section) with flashing warning display on data-fix pages in header banner
- **0.4.21** [Steve A.] resync w/ base engine
- **0.4.20** [Steve A.] more debug and small improvements to data-import strategies & front-end; resync w/ base engine: some security updates; increased duration of JWTs to 10 hours; removed unconfirmed new user access possibility; added a default scope for Team
- **0.4.10** [Steve A.] resync w/ base engine: forced UTF-8 encoding for downloaded script files in ImportQueues
- **0.4.09** [Steve A.] resync w/ base engine: using proper download method for attachments in ImportQueue
- **0.4.08** [Steve A.] improved & fixed data-import steps, now with onscreen progress modal
- **0.4.07** [Steve A.] resync w/ base engine; added support for 8 additional "external" fields in AutoCompleteComponent (& related JS controller) so that we can auto-update up to 12 detail fields in 1 round
- **0.4.06** [Steve A.] slightly improved API endpoints with more useful default ordering for most; data grids for workshops, calendars & standard timings; resync w/ base engine
- **0.4.05** [Steve A.] support push batch SQL import data to dedicated API endpoint directly into ImportQueues as file attachments; re-sync w/ base Engine; push controller skeleton
- **0.3.53** [Steve A.] bundle security fixes; pull, data-fix & push controllers preliminary versions w/ all related strategy classes
- **0.3.52** [Steve A.] minor bundle security fixes; added meetings management; data-import crawler redux w/ new internal API for background updates via ActionCable; still WIP: process result file as a single macrotransaction using the SqlMaker
- **0.3.51** [Steve A.] re-sync w/ base engine
- **0.3.50** [Steve A.] re-sync with base engine; bump Rails to 6.0.4.7 for security fixes
- **0.3.48** [Steve A.] re-sync with base engine
- **0.3.46** [Steve A.] minor bundle security fixes; re-sync with base engine
- **0.3.40** [Steve A.] meeting reservations management; support for namespaced-grids & 'expanded details' (currently only for meeting reservations); added secondary filtering parameter to autocomplete lookups -- i.e.: filtering autocomplete results for 'badges' by currently selected 'season_id' value or 'team affiliations' by the same 'season_id', similar to what's been done with DBLookup secondary filtering but using a single API call with an additional filtering parameter (configurable); updated Stimulus to v3; added "new" flag icon to DbLookupComponents
- **0.3.39** [Steve A.] re-sync with the base Engine; added JSONEditor for import_queues
- **0.3.33** [Steve A.] dashboard for badges, categories, seasons, swimmers, swimming_pools, team_affiliations & teams
- **0.3.32** [Steve A.] rudimentary dashboard for team managers, settings, users & stats
- **0.3.29** [Steve A.] upgrade to Rails 6.0.4.1 due to security fixes
- **0.3.25** [Steve A.] basic CRUD w/ data grid for /users, /stats & /import_queues (still WIP)
- **0.0.01** [Steve A.] initial Project boilerplate & CI config
