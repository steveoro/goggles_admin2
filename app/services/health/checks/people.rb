# frozen_string_literal: true

require 'fuzzystringmatch'

module Health
  module Checks
    #
    # = Health::Checks::People
    #
    # The 'people' group: swimmers.possible_duplicates (warning only, never an inbox item per finding), one
    # finding per swimmer pair, at least one of the two badged in the season:
    # - (a) same complete_name and gender, a year of birth that looks like a typo (at most MAX_YEAR_GAP apart, or the
    #   same digits swapped) and a team in common (badges of any season). Exact duplicates can't exist (unique key
    #   'name_and_year'); same-name swimmers with distant years or no common team are different people (fathers and
    #   sons, common names), so they are not reported;
    # - (b) inside each (team, gender, birth year) bucket of the season badges, two different swimmers whose complete
    #   names AND last names AND first names have a Jaro-Winkler similarity >= the threshold (siblings and twins share
    #   the last name only, so they are not reported).
    # The threshold (Ops::Setting SIMILARITY_KEY, default DEFAULT_SIMILARITY) and the year gap (YEAR_GAP_KEY,
    # default MAX_YEAR_GAP) are settings. A global team pass (outside the badge buckets) is not done.
    #
    class People < Base
      SIMILARITY_KEY = 'health.people.name_similarity'
      DEFAULT_SIMILARITY = 0.92
      YEAR_GAP_KEY = 'health.people.max_year_gap'
      MAX_YEAR_GAP = 1
      METRIC = FuzzyStringMatch::JaroWinkler.create(:native)

      # Season badge row: swimmer id, team id, gender, year of birth and names.
      BadgeRow = Data.define(:swimmer_id, :team_id, :gender_type_id, :year, :last_name, :first_name, :complete_name)

      def call
        @badges = load_badges
        pairs = same_name_pairs.to_h { |pair, gap| [pair, { 'reason' => 'same_name', 'year_gap' => gap }] }
        similar_name_pairs.each { |pair, score| pairs[pair] ||= { 'reason' => 'similar_name', 'similarity' => format('%.3f', score) } }
        @swimmers = load_swimmers(pairs.keys.flatten.uniq)
        pairs.filter_map { |pair, facts| pair_finding(pair, facts) }
      end

      # The similarity threshold (Ops::Setting, clamped to 0.5..1.0).
      def self.threshold
        setting(SIMILARITY_KEY, DEFAULT_SIMILARITY).to_f.clamp(0.5, 1.0)
      end

      # The largest year-of-birth gap of a same-name pair (Ops::Setting, clamped to 0..5).
      def self.max_year_gap
        setting(YEAR_GAP_KEY, MAX_YEAR_GAP).to_i.clamp(0, 5)
      end

      def self.setting(key, default)
        Ops.safely(default) { Ops.available? ? Ops::Setting.fetch(key, default) : default }
      end
      private_class_method :setting

      private

      def load_badges
        GogglesDb::Badge.unscoped.where(season_id:).joins('INNER JOIN swimmers ON swimmers.id = badges.swimmer_id')
                        .distinct.pluck('badges.swimmer_id', 'badges.team_id', 'swimmers.gender_type_id', 'swimmers.year_of_birth',
                                        'swimmers.last_name', 'swimmers.first_name', 'swimmers.complete_name')
                        .map { |row| BadgeRow.new(*row) }
      end

      # (a) { [id1, id2] (sorted) => year gap }
      def same_name_pairs
        max_gap = self.class.max_year_gap
        candidates = same_name_candidates.select { |_pair, year1, year2| year_typo?(year1, year2, max_gap) }
                                         .to_h { |pair, year1, year2| [pair, (year1.to_i - year2.to_i).abs] }
        teams = teams_by_swimmer(candidates.keys.flatten.uniq)
        candidates.select { |(id1, id2), _gap| teams.fetch(id1, []).intersect?(teams.fetch(id2, [])) }
      end

      # [[id1, id2] (sorted), year1, year2] of the same-name, same-gender pairs with another year of birth.
      def same_name_candidates
        GogglesDb::Badge.unscoped.where(season_id:)
                        .joins('INNER JOIN swimmers s1 ON s1.id = badges.swimmer_id')
                        .joins('INNER JOIN swimmers s2 ON s2.complete_name = s1.complete_name AND s2.id <> s1.id')
                        .where('s2.year_of_birth <> s1.year_of_birth AND s2.gender_type_id = s1.gender_type_id')
                        .distinct.pluck('s1.id', 's2.id', 's1.year_of_birth', 's2.year_of_birth')
                        .map { |id1, id2, year1, year2| id1 < id2 ? [[id1, id2], year1, year2] : [[id2, id1], year2, year1] }
                        .uniq(&:first)
      end

      def year_typo?(year1, year2, max_gap)
        (year1.to_i - year2.to_i).abs <= max_gap || year1.to_s.chars.sort == year2.to_s.chars.sort
      end

      # { swimmer_id => [team ids of all its badges, any season] }
      def teams_by_swimmer(ids)
        return {} if ids.empty?

        GogglesDb::Badge.unscoped.where(swimmer_id: ids).distinct.pluck(:swimmer_id, :team_id)
                        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
      end

      # (b) { [id1, id2] (sorted) => complete-name score }
      def similar_name_pairs
        threshold = self.class.threshold
        buckets = @badges.group_by { |row| [row.team_id, row.gender_type_id, row.year] }.values
        buckets.each_with_object({}) { |rows, pairs| add_similar_pairs(rows.uniq(&:swimmer_id), threshold, pairs) }
      end

      # Adds to +pairs+ the swimmers of one bucket whose complete, last and first names are all similar.
      def add_similar_pairs(rows, threshold, pairs)
        rows.combination(2).each do |row1, row2|
          next if row1.complete_name.blank? || row2.complete_name.blank?

          score = similarity(row1.complete_name, row2.complete_name)
          next if score < threshold || similarity(row1.last_name, row2.last_name) < threshold ||
                  similarity(row1.first_name, row2.first_name) < threshold

          pairs[[row1.swimmer_id, row2.swimmer_id].sort] = score
        end
      end

      def similarity(name1, name2)
        METRIC.getDistance(normalize(name1), normalize(name2))
      end

      def normalize(name)
        I18n.transliterate(name.to_s).upcase.squish
      end

      # { id => { 'name' =>, 'year' =>, 'gender_type_id' => } }
      def load_swimmers(ids)
        GogglesDb::Swimmer.unscoped.where(id: ids).pluck(:id, :complete_name, :year_of_birth, :gender_type_id)
                          .each_with_object({}) do |(id, name, year, gender), memo|
          memo[id] = { 'name' => name, 'year' => year, 'gender_type_id' => gender }
        end
      end

      def season_teams(swimmer_id)
        @teams_by_swimmer ||= @badges.group_by(&:swimmer_id).transform_values { |rows| rows.map(&:team_id).uniq.sort }
        @teams_by_swimmer.fetch(swimmer_id, [])
      end

      def pair_finding(pair, facts)
        first, second = pair.map { |id| @swimmers[id] }
        return unless first && second

        finding('swimmers.possible_duplicates', severity: 'warning', subject_type: 'swimmers', subject_id: pair.first,
                                                subject_ids: pair, identity: "swimmers:#{id_list(pair)}",
                                                title_args: { name1: first['name'], year1: first['year'], name2: second['name'], year2: second['year'] },
                                                payload: pair_payload(pair, facts))
      end

      def pair_payload(pair, facts)
        swimmers = pair.map { |id| @swimmers[id].merge('id' => id, 'season_team_ids' => season_teams(id)) }
        facts.merge('swimmers' => swimmers, 'shared_team_ids' => season_teams(pair.first) & season_teams(pair.second),
                    'rake' => { 'src' => pair.second, 'dest' => pair.first })
      end
    end
  end
end
