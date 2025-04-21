# Introduction & Overview

## Purpose

`goggles_admin2` is the administrative web interface for the Goggles framework. Its primary purpose is to provide tools for data managers and administrators to:

*   Import competition results and related data from various sources.
*   Manually create, view, update, and delete core data entities (like Swimmers, Teams, Seasons, Meetings, Results).
*   Manage application users and their permissions.
*   Monitor data import processes and potentially trigger background jobs.
*   Ensure data integrity and consistency across the Goggles ecosystem.

## Target Audience

This application is intended for users who are responsible for maintaining the data integrity and operational aspects of the Goggles framework, typically:

*   System Administrators
*   Data Entry Personnel
*   Federation or Competition Managers

## Relationship with Other Goggles Projects

`goggles_admin2` is a key component of the larger Goggles framework and interacts closely with the other sub-projects:

*   **`goggles_db`:** This is the core Rails Engine gem containing all database models, migrations, associations, and core business logic (like data import strategies). `goggles_admin2` uses `goggles_db` as a dependency to interact with the database and leverage its shared logic.
*   **`goggles_api`:** The API backend, likely consuming data managed via `goggles_admin2`. Data consistency ensured by `goggles_admin2` is crucial for the API's reliability.
*   **`goggles_main`:** The main user-facing frontend application. It displays the curated and managed data that originates from or is processed by `goggles_admin2`.
*   **`goggles_db.wiki`:** Contains supplementary documentation, though it might be outdated. This project aims to consolidate and update relevant administrative documentation within `goggles_admin2/docs`.

Essentially, `goggles_admin2` acts as the central hub for managing the data that powers the entire Goggles suite.
