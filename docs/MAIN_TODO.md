# Goggles Admin2 main TO-DOs

[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

- [ ] GoggleCup preview page with team selection, swimmer list filtering and GoggleCup calculation based



We need to add another feature to the tools section of goggles_admin2 (@_tools.haml ): we can add a "GogglesCup preview" button with a trophy icon.
The goggles cup preview page is essentially similar to the best-result subpages (like @best_50m.html.haml @best_results_controller.rb ): a page that selects data from a view after choosing a team first, with some additional filtering for the swimmers found for the choosen team, a button to perform the actual data query and the 2 button for CSV & XLS export of the result data.
The target domain will be GogglesDb::BestSwimmerCurrentVsPreviousResult (@best_swimmer_current_vs_previous_result.rb @best_swimmer_current_vs_previous_results_v03.sql )
Instead of being a 2-phase page like the "best results" pages, this will be a 3-phase data flow:

1. choose the team -> retrieve all the swimmers names and IDs found for the chosen team (we can use the view for that)
2. present complete_name and year_of_birth for each swimmer found for the chosen team in a list, with a toggle switch for each swimmer, so that the operator can choose which swimmer IDs to select as a form; add also a POST button "Compute", to perform the filtering: by pressing the button, the operator chooses which swimmer ID use to (further) filter the view data
3. with the final filtering given by the post, we can render the final report for the GoggleCup, based on the view data, filtered by all the swimmer IDs selected in the filtering form.
The report basically is a ranking for the selected swimmers, sorted by descending score, where the score is computed aggregating all the rows in the view for the swimmer_id being processed, in this way:
For each swimmer_idrow in the view data:
   improved_timing = old_total_hundredths - total_hundredths;
   row_score = 1000 + improved_timing
Of all swimmer_id rows with the computed row_score, we sort them in descending order and we consider just the first 5 rows with the best row_score. The sum of these first 5 rows will become the overall score for the championship.
We then have to report the data, sorted by the overall score in descending order.
For each swimmer, for the ranking report, we'll render a section displaying:
Header (ranking):

- ranking position
- swimmer complete_name and year of birth
- overall score
- swimmer_id (small, top right)
Section body (ranking computation: one line for each one of 5 rows considered in the computation):
- meeting_name and meeting_date
- event_type_code
- pool_type_code
- total_hundredths
- old_meeting_name and old_meeting_date
- old_total_hundredths
- compute row_score

For the CSV and XLS export, we can probably opt to yield just the header data, without the section body columns.

Decide whatever is best to compute the ranking and display the report. (SQL aggregation, in memory arrays, or a mix of a ruby loop on ActiveRecord queries, or anything else comes to mind).
