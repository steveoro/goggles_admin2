# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See also `AGENTS.md` (checked in) for detailed notes on DataFix V2 canonical-source handling, Phase 1 pool/city rehydration, PDF manifest extraction, and the grid toolbar / lookup endpoints. Don't duplicate it here.

## What this is

Rails 8.1 / Ruby 3.4 admin UI for the Goggles framework (v7+), designed to run **only on a developer's localhost**. It mounts the `GogglesDb::Engine` (git gem `goggles_db`, which provides models and the schema) and talks to a separate `goggles_api` service through `APIProxy` (`app/strategies/api_proxy.rb`). Its main job is turning crawled/extracted meeting results into production DB rows (the "Data-Fix" pipeline), plus merge/purge/normalize maintenance tools. MariaDB via mysql2 (`config/database.yml`, socket-based, DBs `goggles_development` / `goggles_test`); schema format is `:sql` (`db/structure.sql`).

## Commands

```bash
bin/rails server -p 3000            # or: foreman start -f Procfile.dev (web + dartsass:watch)
bin/rails dartsass:watch            # CSS (dartsass), needed in dev

bundle exec rspec                                   # full suite
bundle exec rspec spec/requests/data_fix_controller_phase1_spec.rb          # one file
bundle exec rspec spec/requests/data_fix_controller_phase1_spec.rb:42       # one example
bundle exec rubocop [path]          # lint (rubocop-rails/rspec/performance/rake configured in .rubocop.yml)
bundle exec guard                   # watcher the README expects green before PRs

# Crawler (separate Node service, port 7000; the Rails Pull dashboard expects it running)
cd crawler && npm install && npm start
cd crawler && npm test              # mocha
```

Maintenance rake tasks live in `lib/tasks/` (`manifests`, `normalize`, `merge`, `purge`, `recompute`, `check`, `fix`, `db`, fixtures tasks). List with `bin/rails -T`; read each task's `desc` for its env-style args (e.g. `rake manifests:extract season=<id>`). Some (e.g. `normalize:coded_names`) emit a SQL script instead of touching the DB directly.

## Architecture

### Data-Fix pipeline (the core)
Six phases turning a results source file into production data; docs in `docs/data_fix/` (`README.md` → `PHASES.md` → `TECHNICAL.md`, `DATA_STRUCTURES.md`).
- Principle: **solve early, commit later** — entity matching happens when each phase file is built (`phase1.json`…`phase4.json` hold resolved IDs); Phase 5 stages results/laps in `data_import_*` DB tables; Phase 6 commits atomically and writes an SQL log.
- Controllers: `DataFixController` holds cross-phase utilities; per-phase controllers are in `app/controllers/data_fix/*` (sessions, teams, swimmers, events, results, commits) on a shared `base_controller`. `data_fix_legacy_controller` is the old flow.
- Logic is split between `app/services/data_fix/**` (phase builders, cascades, issue detection, post-commit checks, source resolution) and `app/strategies/import/**` (`macro_solver` + `solvers/`, `macro_committer` + `committers/`, `structure_validator`, `phase5_populator`). SQL generation is `SqlMaker`.
- Source files: crawler output lands in `crawler/data/results.new/<season>/`; layoutType 4 (LT4) is the canonical format (see AGENTS.md for LT2→LT4 working-copy rules). Result-free (manifest) sources follow a shortened Phase 1 → Phase 6 chain.

### Other subsystems
- `app/strategies/pdf_manifests/` and `pdf_results/`: PDF → LT4 extraction (pdftotext + local Ollama; notes in `docs/pdf_processing/ollama_extraction_notes.md`).
- `app/strategies/merge/` + `docs/merge/`: swimmer/team/badge/meeting merge checkers and semantics.
- `crawler/`: standalone Node server (FIN, Microplus, FICR crawlers) writing artifacts under `crawler/data/` and progress to `crawler-status.json` (broadcast to the UI via ActionCable). Docs: `crawler/README.md`, `docs/crawler/`. `crawler/crawler-status.json` changes constantly at runtime — don't commit it incidentally.
- `app/grids/` (DataGrid-based list pages, `Grid::ToolbarComponent`), `app/components/` (ViewComponents), views are HAML, Stimulus controllers in `app/javascript/controllers/`, JS helpers in `app/javascript/*.js`.
- `app/strategies` and `app/grids` plus `app/etls/{sources,transforms,destinations}` are explicit eager-load roots (`config/application.rb`), so files there define top-level constants.
- `API` is registered as an inflection acronym (`config/initializers/inflections.rb`), e.g. `APIProxy` lives in `api_proxy.rb`.

## Conventions
- Every Ruby file starts with `# frozen_string_literal: true`.
- Update `CHANGELOG.md` and bump the version when making user-visible changes (recent commits follow this).
- Specs: `spec/{requests,services,strategies,components,...}`; fixtures live in `spec/fixtures` and can be regenerated with the `fixtures_*` rake tasks.
