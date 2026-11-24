# frozen_string_literal: true

require 'digest'

module DataFix
  class Pipeline
    #
    # = DataFix::Pipeline::Digests
    #
    # Canonical digests used by the edit markers and the staleness check:
    # - .data_digest(payload, phase): SHA256 of the canonical JSON of the phase data ('_meta' excluded, so retry-flag
    #   or overwrite-metadata writes never count as edits). Phases 1-4 keep their payload under 'data'; the Phase 5
    #   file is flat ('name', 'source_file', 'programs', ...), so everything but '_meta' is digested;
    # - .projections(phase, pipeline): the input projections each phase is built from ('built.inputs'), one SHA256
    #   per upstream, so that unrelated upstream edits do not make a phase stale.
    #
    # | Phase | Inputs                                                                                         |
    # |-------|-----------------------------------------------------------------------------------------------|
    # | 1, 2  | source sha256; season id                                                                       |
    # | 3     | + P1 header_date, season_id; P2 teams key => team_id, affiliations team_key => affiliation id  |
    # | 4     | + P1 id, meeting_session [session_order, id]                                                   |
    # | 5     | + P1 id, header_date, sessions; P2 key => team_id; P3 swimmers / badges ids; P4 events          |
    #
    module Digests
      module_function

      # Upstream (0 = the source file) and label of each input key (for the stale reasons).
      INPUTS = {
        'source' => { upstream: 0, what: 'source file' },
        'season' => { upstream: 0, what: 'season' },
        'p1' => { upstream: 1, what: 'meeting and sessions' },
        'p2' => { upstream: 2, what: 'team ids' },
        'p3' => { upstream: 3, what: 'swimmer and badge ids' },
        'p4' => { upstream: 4, what: 'events' }
      }.freeze

      INPUT_KEYS_BY_PHASE = {
        1 => %w[source season],
        2 => %w[source season],
        3 => %w[source season p1 p2],
        4 => %w[source season p1],
        5 => %w[source season p1 p2 p3 p4]
      }.freeze

      # SHA256 of the canonical JSON (sorted keys, recursively) of +value+.
      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def canonical(value)
        case value
        when Hash then value.keys.map(&:to_s).sort.index_with { |key| canonical(value[key] || value[key.to_sym]) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      # Digest of the data section of a phase payload (whole parsed file Hash).
      def data_digest(payload, phase)
        payload = {} unless payload.is_a?(Hash)
        digest(phase.to_i == 5 ? payload.except(PhaseFileManager::META_KEY) : payload[PhaseFileManager::DATA_KEY])
      end

      # Fresh input projections of +phase+ ({ key => sha256 }), computed from the current files of the pipeline.
      def projections(phase, pipeline)
        INPUT_KEYS_BY_PHASE.fetch(phase.to_i).index_with { |key| send(:"project_#{key}", phase.to_i, pipeline) }
      end

      def project_source(_phase, pipeline)
        pipeline.source_sha256
      end

      def project_season(_phase, pipeline)
        digest(pipeline.season_id_from_path)
      end

      def project_p1(phase, pipeline)
        data = pipeline.phase_data(1)
        sessions = Array(data['meeting_session']).map { |session| [session['session_order'], session['id']] }
        projection = case phase
                     when 3 then { 'header_date' => data['header_date'], 'season_id' => data['season_id'] }
                     when 4 then { 'id' => data['id'], 'sessions' => sessions }
                     else { 'id' => data['id'], 'header_date' => data['header_date'], 'sessions' => sessions }
                     end
        digest(projection)
      end

      def project_p2(phase, pipeline)
        data = pipeline.phase_data(2)
        teams = Array(data['teams']).to_h { |team| [team['key'].to_s, team['team_id']] }
        return digest('teams' => teams) if phase.to_i == 5

        affiliations = Array(data['team_affiliations']).to_h { |row| [row['team_key'].to_s, row['team_affiliation_id']] }
        digest('teams' => teams, 'affiliations' => affiliations)
      end

      def project_p3(_phase, pipeline)
        data = pipeline.phase_data(3)
        swimmers = Array(data['swimmers']).to_h { |row| [row['key'].to_s, [row['swimmer_id'], row['category_type_id']]] }
        badges = Array(data['badges']).map { |row| [row['swimmer_key'], row['team_key'], row['badge_id']] }
        digest('swimmers' => swimmers, 'badges' => badges)
      end

      def project_p4(_phase, pipeline)
        sessions = Array(pipeline.phase_data(4)['sessions']).map do |session|
          events = Array(session['events']).map do |event|
            [event['key'], event['session_order'], event['id'] || event['meeting_event_id'], event['event_type_id']]
          end
          [session['session_order'], events]
        end
        digest(sessions)
      end
    end
  end
end
