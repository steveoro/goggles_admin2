## Relevant Version History / current working features:

_Please, add the latest build info on top of the list; use Version::MAJOR only after gold release; keep semantic versioning in line with framework's_

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
