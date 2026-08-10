---
name: goggles-dev-setup
description: Set up a local development environment for the Goggles Framework apps (goggles_main, goggles_api, goggles_admin2) using the shared goggles_db engine and its test SQL dump.
---

# Goggles development environment setup

When asked to set up the dev environment for a Goggles Framework app, follow this procedure.

## Scope

Supported projects:
- `goggles_api`
- `goggles_main`
- `goggles_admin2`
- `goggles_db` (engine test dummy app)

Default target environment is `development`; use `test` if the user asks to run the test suite.

## 0. Identify project and target

- Use the current repo name if not explicitly specified.
- If you cannot determine the project, ask the user.

## 1. Ensure system dependencies

- Ruby 3.4.7 active (see `.ruby-version`). Install with `rbenv`/`ruby-build` or your version manager if missing.
- MariaDB 11.8 server & client packages (`mariadb-server`, `mariadb-client`, `libmariadb-dev` or `default-libmysqlclient-dev`) running and reachable.
- `bunzip2`, `git`, `curl`.
- Node.js and Yarn only for `goggles_admin2` (and optionally for `goggles_main` JS linting).

## 2. Clone/check `goggles_db`

All apps use `goggles_db` as a git-sourced gem and need its `test.sql.bz2` dump.

- If `goggles_db` is not cloned, clone `https://github.com/steveoro/goggles_db.git` next to the app repo.
- Ensure `goggles_db/spec/dummy/db/dump/test.sql.bz2` is present and is an actual bzip2 file, not a Git LFS pointer. If it is a pointer, run `git lfs pull` inside `goggles_db`.

## 3. Install gems

- For `goggles_db`: `bundle install`.
- For apps: `GIT_LFS_SKIP_SMUDGE=1 bundle install` (avoids downloading the dump through the gem; we copy it manually).
- To refresh the `goggles_db` gem later, use `GIT_LFS_SKIP_SMUDGE=1 bundle update goggles_db` or run `./update_engine.sh` when available.

## 4. Install JS dependencies

- `goggles_admin2`: `yarn install --check-files`.
- `goggles_main`: `yarn install` (optional; only needed for JS linting with `standard`).
- `goggles_api`: none.

## 5. Configure the app

### Secrets
- Request the `RAILS_MASTER_KEY` secret. If it is not already set in the environment or in `config/master.key`, write it:
  `printf '%s' "$RAILS_MASTER_KEY" > config/master.key`
- Request the `MYSQL_ROOT_PASSWORD` secret when the database requires a password.

### Database config
- `goggles_db`: copy `spec/dummy/config/database.yml.example` to `spec/dummy/config/database.yml` and adjust user/password/host.
- Apps: copy `config/database.yml.example` (or `config/database_ci.yml` for a CI-like setup) to `config/database.yml` and adjust user/password/host.
  - For a local MariaDB socket, use `socket: /var/run/mysqld/mysqld.sock` and `username: root`.
  - For a containerized DB, use `host`/`port` (`127.0.0.1:33060` for Docker Compose default).

### Optional Docker Compose
- If using Docker, create `.env` from `.env.example`, set `MYSQL_ROOT_PASSWORD` and `TAG`, and run the appropriate compose file:
  - `goggles_api`: `docker-compose -f docker-compose.dev.yml up -d`
  - `goggles_main`: `docker-compose -f docker-compose.dev.yml up -d`
  - `goggles_admin2`: `docker-compose up -d`

## 6. Prepare the test dump

- Make sure the target `db/dump` directory exists.
- Copy (or download) the `test.sql.bz2` dump:
  - From local clone: `cp <path-to-goggles_db>/spec/dummy/db/dump/test.sql.bz2 db/dump/test.sql.bz2`
  - Or download: `curl -L -o db/dump/test.sql.bz2 https://github.com/steveoro/goggles_db/raw/master/spec/dummy/db/dump/test.sql.bz2`
- For `goggles_db` the dump is already at `spec/dummy/db/dump/test.sql.bz2`.

## 7. Rebuild the database

Wait for MariaDB to be reachable (`mariadb-admin ping -h ... -u root` or `dockerize -wait tcp://...`).

Run the custom `goggles_db` rake task:

- `goggles_db` test environment:
  `RAILS_ENV=test bin/rails app:db:rebuild from=test to=test`
  `RAILS_ENV=test bin/rails db:migrate`
- Apps, development:
  `RAILS_ENV=development bin/rails db:rebuild from=test to=development`
  `RAILS_ENV=development bin/rails db:migrate`
- Apps, test:
  `RAILS_ENV=test bin/rails db:rebuild from=test to=test`
  `RAILS_ENV=test bin/rails db:migrate`

For `goggles_main` and `goggles_admin2`, ensure `storage/` exists so the SQLite SolidQueue/SolidCache DBs can be created by migrations.

## 8. `goggles_admin2` API connection

`goggles_admin2` needs a running `goggles_api`. After the API is started, point the DB setting at it from the app console or with a runner:

`bin/rails runner "GogglesDb::AppParameter.config.settings(:framework_urls).update!(api: 'http://localhost:8081')"`

Use `http://host.docker.internal:8081` or the Docker service name (`http://goggles-api.dev:8081`) when both run in Docker.

## 9. Start the app

- `goggles_api`: `bin/rails s -p 8081` (or `-e staging -p 8081`).
- `goggles_main`: `bin/dev` (uses `Procfile.dev` on port 3000, runs web, `dartsass:watch`, and Solid Queue worker) or `bin/rails s -p 3000`.
- `goggles_admin2`: `bin/dev` (uses `Procfile.dev`) or `bin/rails s -p 3000`.

## 10. Verify

- `bin/rails zeitwerk:check`
- `curl -f http://localhost:<port>/` or open the browser.
- `goggles_api` Swagger docs at `/api/docs` in development.

## Validation notes & troubleshooting

- MariaDB may not start automatically in containerized environments. If `mariadb-admin ping` fails, start it with:
  `sudo nohup mariadbd --user=mysql --skip-networking=0 > /tmp/mariadb.log 2>&1 &`
- If the DB user uses `unix_socket` auth, create a password-authenticated user and use `host`/`port` in `database.yml`:
  `CREATE USER 'goggles'@'%' IDENTIFIED BY '<password>'; GRANT ALL PRIVILEGES ON *.* TO 'goggles'@'%'; FLUSH PRIVILEGES;`
- `goggles_main` and `goggles_admin2` both default to port 3000. Run one on a different port when both are up:
  `bin/rails s -p 3001`
- `goggles_main` uses SQLite for `cache`/`queue`/`cable` while the `goggles_db` `scenic` initializer forces a MySQL adapter. If `db:migrate` fails with `SHOW FULL TABLES` on SQLite, set `schema_format: :sql` for the SQLite DB blocks in `config/database.yml` and ensure the `sqlite3` CLI is installed.
- `goggles_admin2` may ship a broken `storage` symlink. Remove it and create a real directory before starting:
  `rm -f storage && mkdir storage`
- `goggles_db` uses Git LFS for the dump; `GIT_LFS_SKIP_SMUDGE=1` prevents `bundle install` from fetching the dump through the gem. Copy/download the dump manually instead.

## Notes

- Do not use `rails db:setup`/`db:prepare`; the `goggles_db` `db:rebuild` task is the supported way to seed from the portable `test.sql.bz2` dump.
- The dump contains no `USE`/`CREATE database` or explicit definer clauses, so it can be restored to any database name.
- The app's `bin/setup` scripts are generic Rails stubs; do not rely on them for the Goggles DB restore.
- For production-like environments, precompile assets for `goggles_main`/`goggles_admin2`:
  `RAILS_ENV=production NODE_ENV=production bin/rails dartsass:build assets:precompile`.
