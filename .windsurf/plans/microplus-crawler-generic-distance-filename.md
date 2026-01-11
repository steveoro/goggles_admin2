# Microplus crawler generic distance filename token
Implement a filename token for generic distance filters so crawls filtered by distance-only (e.g., "50 m") save with an appropriate token instead of falling back to the default layout suffix.

## Plan
1. Review current event parsing and filename composition to see where eventCode is derived and why generic distance filters yield an empty token (utility.js parseEventInfoFromDescription and microplus-crawler.js filename block).
2. Define and implement logic to produce a fallback token (e.g., `all<distance>`) when targetEventTitle lacks stroke but includes distance, keeping existing behavior for full eventCode cases.
3. Add/adjust tests or lightweight run checks (if present) to cover both specific and generic filters, and update any relevant docs/comments if needed.
