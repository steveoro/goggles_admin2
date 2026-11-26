# goggles_admin2: operations console improvements

## 1. Blocker: pop-up progress dialog isn't auto-dismissed at end

See `docs/plans/review-teams-progressdialog.png`
After browsing back and forth phase 1 and 3, the progress dialog remains open and being modal doesn't allow to interact with the rest of the UI.

## 2. Possible flow improvement: buttons for phase-2 are disabled

See `docs/plans/season-dashboard-with-disabled-phase2-btns.png`
What intuitively appears as a shortcut to go directly to the phase (2, in this example) that could allow to fix the issue shown on the dashboard, is disabled. To actually get to that phase, the operator has to navigate through the UI side menu, but not from the dashboard directly.

## 3. Some automation toggle button could be rendered as switches

Some switches are rendered with a toggle button ("Disable" / "Enable") but a switch would be more intuitive, like the one used on the users list page.

## 4. Auto-dismiss FIN calendar change alert after a calendar crawl that yields parity with the source

If a newly crawled calendar or a data-fix run yields the new or changed meeting/calendar rows so that data parity is achieved, the alert should be automatically dismissed.

## 5. Auto-start a default calendar crawl when a remote calendar change is detected

Same as above but as a completion: when a remote calendar change is detected, automatically start a default FIN calendar crawl for the season the change is related to.
The full automation could be: detect change -> start calendar crawl -> process calendar automatically -> dismiss alert if parity is achieved.

## 6. Auto-clean redundant calendar data and redundant meeting crawls from calendar processing

When a calendar processing is completed autonomously, clean up any redundant or duplicate data files that are already.
See `docs/plans/season-dashboard-with-disabled-phase2-btns.png`, which shows some redundant files present for some meeting rows.
