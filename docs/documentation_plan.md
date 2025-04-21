# Goggles Admin2 Documentation Plan

This document outlines the plan for creating comprehensive documentation for the `goggles_admin2` project.

## Table of Contents

1.  **Introduction & Overview:**
    *   Purpose of `goggles_admin2` within the Goggles ecosystem.
    *   Target audience (administrators, data managers).
    *   Relationship with `goggles_db`, `goggles_api`, and `goggles_main`.
2.  **Project Setup & Configuration:**
    *   Installation instructions (development, production).
    *   Environment variables and configuration files (`.env`, `config/`).
    *   Dependency management (`Gemfile`, `package.json`).
3.  **Core Features & Workflows:**
    *   User Authentication & Authorization (Roles, Permissions).
    *   Data Import & Management (e.g., importing results, managing swimmers/teams).
        *   Data Sources (e.g., FIN Results, manual entry).
        *   Import processes (e.g., `DataImportController`, background jobs).
        *   Data validation and error handling.
    *   CRUD operations for key models (`Swimmer`, `Team`, `Meeting`, `Season`, etc.).
    *   Data visualization/reporting features (if any, e.g., `chart_api_controller.js`).
4.  **Architecture & Key Components:**
    *   Overview of major components (Controllers, Models, Views, Services, Jobs).
    *   Interaction with the `goggles_db` engine gem.
    *   Frontend structure (JavaScript controllers, Stimulus, Turbo?).
    *   Background job processing (Sidekiq/Resque?).
5.  **Development & Contribution:**
    *   Running tests (`rspec`).
    *   Code style guidelines (`rubocop`, `haml-lint`).
    *   Contribution process.
6.  **Deployment:**
    *   Deployment steps (server setup, deployment scripts).
    *   Monitoring and maintenance.

## Next Steps

*   [x] Flesh out Section 1: Introduction & Overview.
*   [x] Analyze `config/routes.rb` to understand available actions.
*   [x] Document Crawler Interaction (`crawler_interaction.md`).
*   [x] Document PDF Processing (`pdf_processing.md`).
*   [x] Document Data Review & Linking (`data_review_and_linking.md`).
*   [x] Document Data Commit & Push (`data_commit_and_push.md`).
*   [ ] Document User Authentication (likely using Devise or similar).
