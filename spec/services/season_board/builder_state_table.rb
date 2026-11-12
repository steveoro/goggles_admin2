# frozen_string_literal: true

# State table for builder_spec.rb: one entry per case, as
# [description, setup, FIN row overrides, expected state, expected action kind, expected params (subset)].
# The setup & params lambdas are instance_exec'ed inside the example (helpers: fin_id, link!,
# write_json, write_file, lt2_hash, lt4_hash, path_for, results_url).
module SeasonBoardBuilderStateTable
  ROWS = [
    ['info says cancelled', -> {}, { info: 'Manifestazione ANNULLATA' }, :cancelled, nil, nil],
    ['info says postponed (rinviata), even with work pending',
     -> { write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true)) }, { info: 'Rinviata' }, :cancelled, nil, nil],
    ['calendar cancelled', -> { link!(cancelled: true) }, {}, :cancelled, nil, nil],
    ['meeting cancelled, even with a pending SQL',
     lambda {
       link!(meeting_cancelled: true)
       write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
       write_file('results.new', '0420-m-lt4.sql')
     }, {}, :cancelled, nil, nil],
    ['SQL waiting in results.new (wins over a new review)',
     lambda {
       write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
       write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true))
       write_json('results.new', 'm-lt4-phase1.json', {})
       write_file('results.new', '0421-m-lt4.sql')
       write_file('results.new', '0420-m-lt4.sql')
     }, {}, :sql_pending, :push,
     lambda {
       oldest = path_for('results.new', '0420-m-lt4.sql')
       { sql_path: oldest, sql_paths: [oldest, path_for('results.new', '0421-m-lt4.sql')] }
     }],
    ['phase files in results.new',
     lambda {
       write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true))
       write_json('results.new', 'm-lt4.json', lt4_hash(results: true))
       write_json('results.new', 'm-lt4-phase1.json', {})
       write_json('results.new', 'm-lt4-phase2.json', {})
     }, {}, :in_review, :resume_review, -> { { file_path: path_for('results.new', 'm.json'), phase: 2 } }],
    ['phase files for a meeting already linked with results (re-review)',
     lambda {
       link!(results_acquired: true, mir_count: 10)
       write_json('results.new', 'm-lt4.json', lt4_hash(fin_id: fin_id, results: true))
       write_json('results.new', 'm-lt4-phase4.json', {})
     }, {}, :in_review, :resume_review, -> { { file_path: path_for('results.new', 'm-lt4.json'), phase: 4 } }],
    ['crawled results, no phase files',
     -> { write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true)) },
     {}, :results_ready, :review_results, -> { { file_path: path_for('results.new', 'm.json') } }],
    ['crawled results for a structure-committed meeting (results after manifest)',
     lambda {
       link!
       write_json('results.done', 'm-lt4.json', lt4_hash(meeting_only: true))
       write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true))
       write_json('results.new', 'm-lt4.json', lt4_hash(meeting_only: true)) # collision: LT2 results win
     }, {}, :results_ready, :review_results, -> { { file_path: path_for('results.new', 'm.json') } }],
    ['LT4-only results source',
     -> { write_json('results.new', 'pdf-lt4.json', lt4_hash(fin_id: fin_id, results: true)) },
     {}, :results_ready, :review_results, -> { { file_path: path_for('results.new', 'pdf-lt4.json') } }],
    ['extracted manifest LT4 waiting for review',
     lambda {
       write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id))
       write_json('results.new', 'm-lt4.json', lt4_hash(meeting_only: true))
     }, {}, :structure_ready, :review_structure, -> { { file_path: path_for('results.new', 'm-lt4.json') } }],
    ['manifest PDF pending, result-free crawl, no meeting',
     lambda {
       write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id))
       write_file('manifests', 'manifest-m.pdf')
     }, {}, :manifest_pending, :extract_manifest, -> { { pdf_path: path_for('manifests', 'manifest-m.pdf') } }],
    ['linked meeting with MIR/MRR', -> { link!(mir_count: 3, mrr_count: 1) }, {}, :committed_with_results, nil, nil],
    ['linked meeting flagged results_acquired (no counts)', -> { link!(results_acquired: true) }, {}, :committed_with_results, nil, nil],
    ['linked meeting without results, past date',
     -> { link! }, {}, :structure_committed, :check_results, -> { { url: results_url(fin_id), meeting_id: 19_000 } }],
    ['linked meeting without results, future date', -> { link! }, { date: '21-22/11' }, :structure_committed, nil, nil],
    ['linked meeting + a pending manifest PDF (no re-extraction)',
     lambda {
       link!
       write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
       write_file('manifests', 'manifest-m.pdf')
     }, { date: '21-22/11' }, :structure_committed, nil, nil],
    ['result-free crawl, no manifest PDF, no meeting',
     -> { write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id)) },
     {}, :crawled_no_manifest, :review_header, -> { { file_path: path_for('results.new', 'm.json') } }],
    ['archived files but no linked calendar (committed before the FIN id was stored)',
     lambda {
       write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
       write_json('results.done', 'm-lt4.json', lt4_hash(meeting_only: true))
       write_file('results.sent', '0414-m-lt4.sql')
     }, {}, :archived_unlinked, :link, { bases: ['m'] }],
    ['pending manifest PDF but its LT4 was already archived (no meeting link)',
     lambda {
       write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
       write_json('results.done', 'm-lt4.json', lt4_hash(meeting_only: true))
       write_file('manifests', 'manifest-m.pdf')
     }, {}, :archived_unlinked, :link, { bases: ['m'] }],
    ['FIN id, nothing local', -> {}, {}, :link_not_crawled, :crawl, -> { { url: results_url(fin_id) } }],
    ['calendar pointing to a missing meeting', -> { link!(meeting: false) }, {}, :link_not_crawled, :crawl, nil],
    ['no URL on the FIN row', -> {}, { url: '' }, :not_linked, nil, nil]
  ].freeze
end
