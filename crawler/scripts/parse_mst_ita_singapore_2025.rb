#!/usr/bin/env ruby
# frozen_string_literal: true

# One-shot script: parses mst_ita_singapore_2025.txt into LT2 JSON.
# Usage: ruby crawler/scripts/parse_mst_ita_singapore_2025.rb

require 'json'

DEBUG = ENV.fetch('DEBUG', '0') != '0'

def dbg(msg)
  warn msg if DEBUG
end

BASE_DIR = File.expand_path('../data/pdfs/fina', __dir__)
TXT_PATH = File.join(BASE_DIR, 'mst_ita_singapore_2025-edited.txt')
JSON_PATH = File.join(BASE_DIR, 'mst_ita_singapore_2025-edited.json')

STROKE_MAP = {
  /freestyle/i => 'Stile Libero',
  /backstroke/i => 'Dorso',
  /breaststroke/i => 'Rana',
  /butterfly/i => 'Farfalla',
  /indivi?dual\s+medley/i => 'Misti',
  /medley/i => 'Misti'
}.freeze

# Timing matches: M:SS.hh, MM:SS.hh, SS.hh, NT, DNS, DSQ-
TIMING_RE = /\d{1,2}:\d{2}\.\d{2}|\d{2}\.\d{2}|NT|DNS|DSQ-?/i

# --- Helpers ---

def italian_stroke(english)
  STROKE_MAP.each { |regexp, ita| return ita if english&.match?(regexp) }
  english
end

def normalize_race_title(raw)
  # "50m Freestyle" => "50 Stile Libero"
  # "400m Individual Medley" => "400 Misti"
  # "4x50m Freestyle" => "4x50 Stile Libero"
  # "4x50m Medley" => "4x50 Misti"
  raw = raw.strip.gsub(/\s+/, ' ')
  m = raw.match(/\A(\d+x?\d+)m?\s+(.+)\z/i)
  return raw unless m

  "#{m[1]} #{italian_stroke(m[2])}"
end

def convert_timing(raw)
  # "1:00.66" => "1'00.66", keep "NT"/"DNS"/"DSQ"/"DSQ-" as-is
  return raw if /\A[A-Z]/i.match?(raw)

  raw.sub(':', "'")
end

def parse_athlete_and_rest(line)
  # Split by 2+ spaces to get columns, then interpret them.
  # Strip trailing "RI" or "RI/WR" record markers
  line = line.sub(%r{\s+RI(?:/WR)?\s*$}i, '')
  parts = line.strip.split(/\s{2,}/)
  return nil if parts.length < 3

  category = nil

  # Check if first part is a category code (M25, F30, etc.)
  category = parts.shift if /\A[MF]\d{2}\z/.match?(parts[0])

  # Now parts should be: [pos+name or pos, name?, team, timing, score?]
  # Case 1: pos and name are separate (2+ spaces between them)
  # Case 2: pos and name are combined (1 space between them)
  pos = nil
  name = nil

  if /\A(\d{1,3}|NT|DNS|DSQ)\z/i.match?(parts[0])
    # pos is separate from name
    pos = parts.shift
    name = parts.shift
  else
    # pos and name are combined: "33 DE ROSA Gabriele"
    combined = parts.shift
    m = combined.match(/\A(NT|DNS|DSQ|\d{1,3})\s+(.+)/i)
    return nil unless m

    pos = m[1]
    name = m[2]
  end

  return nil if parts.length < 2 # need at least team + timing

  team = parts.shift
  timing_raw = parts.shift

  # Timing and score may be joined by 1 space (e.g. "1:00.66 834")
  # Split them if timing_raw contains a space
  extracted_score = nil
  if timing_raw =~ /\A(#{TIMING_RE})\s+(\d{1,4})\z/io
    timing_raw = Regexp.last_match(1)
    extracted_score = Regexp.last_match(2)
  end

  # Validate timing_raw looks like a timing value; if not, this is likely
  # a split row where "team" is actually the timing and "timing" is the score
  return nil unless /\A#{TIMING_RE}\z/io.match?(timing_raw)

  result = {
    'pos' => pos,
    'name' => name.strip,
    'team' => team.strip,
    'timing' => convert_timing(timing_raw)
  }

  # Optional score (prefer extracted, then from remaining parts)
  if extracted_score
    result['std_score'] = extracted_score
  else
    score = parts.shift
    result['std_score'] = score if score && score =~ /\A\d{1,4}\z/
  end

  result['category_from_line'] = category if category
  result
end

def parse_athlete_only(line)
  # Line has pos+name but no team (split row). May have timing+score.
  parts = line.strip.split(/\s{2,}/)
  return nil if parts.empty?

  pos = nil
  name = nil

  if /\A(\d{1,3}|NT|DNS|DSQ)\z/i.match?(parts[0])
    pos = parts.shift
    name = parts.shift if parts.any?
  else
    combined = parts.shift
    m = combined.match(/\A(NT|DNS|DSQ|\d{1,3})\s+(.+)/i)
    return nil unless m

    pos = m[1]
    name = m[2]
  end

  return nil unless name && name.length > 2

  result = { 'pos' => pos, 'name' => name.strip }

  # Check for timing+score in remaining parts
  if parts.any? && parts[0] =~ /\A(#{TIMING_RE})\s+(\d{1,4})\z/io
    result['timing'] = convert_timing(Regexp.last_match(1))
    result['std_score'] = Regexp.last_match(2)
  elsif parts.any? && parts[0] =~ /\A#{TIMING_RE}\z/io
    result['timing'] = convert_timing(parts.shift)
    score = parts.shift
    result['std_score'] = score if score && score =~ /\A\d{1,4}\z/
  end

  result
end

def parse_team_only(line)
  # Line has only team name (continuation of split row)
  # "                                                          COOPERNUOTO S.C.S.D."
  m = line.match(/\A\s+(\S.{2,})\s*\z/)
  m && m[1].strip
end

# --- Individual results parser ---

def parse_individuals(lines)
  sections = {} # key: [title, cat, gender] => { section_hash }
  current_gender = nil
  current_race = nil
  current_category = nil
  pending_row = nil # for split rows
  pending_status = nil # for NT/DNS on separate line

  lines.each_with_index do |line, idx|
    stripped = line.strip
    dbg "[IND L#{idx + 1}] #{stripped[0..80]}"

    # Skip blank lines
    next if stripped.empty?

    # Detect gender header
    if /UOMINI/i.match?(stripped)
      current_gender = 'M'
      pending_row = nil
      pending_status = nil
      next
    elsif /DONNE/i.match?(stripped)
      current_gender = 'F'
      pending_row = nil
      pending_status = nil
      next
    end

    # Skip page headers and column headers
    next if /World Aquatics|Risultati atleti|RACE\s+CAT/i.match?(stripped)
    next if /\A\s*CAT\s+R-RNK/i.match?(stripped)

    # Detect relay section start
    break if /Staffette/i.match?(stripped)

    # Detect race title (e.g. "50m Freestyle", "100m Backstroke", "400m Individual")
    if /\A\s*\d+x?\d+m?\s+(Freestyle|Backstroke|Breaststroke|Butterfly|Indivi?dual|Medley)(\s+Medley)?\s*\z/i.match?(stripped)
      # Check for multi-line title (e.g. "400m Individual" followed by "Medley")
      if stripped =~ /Indivi?dual\s*\z/i && idx + 1 < lines.length
        next_line = lines[idx + 1].strip
        if /\A\s*Medley\s*\z/i.match?(next_line)
          current_race = normalize_race_title("#{stripped} #{next_line}")
          next
        end
      end
      current_race = normalize_race_title(stripped)
      current_category = nil
      pending_row = nil
      pending_status = nil
      next
    end

    # Detect "Medley" continuation line (already handled above, skip if standalone)
    next if /\A\s*Medley\s*\z/i.match?(stripped)

    # Detect category on same line as result: "M25     41 MOTTA Dennis..."
    # parse_athlete_and_rest handles this via category_from_line
    row = parse_athlete_and_rest(line)
    if row
      # Flush any pending partial row first
      if pending_row
        pending_row['year_of_birth'] = nil
        add_section_row(sections, current_race, current_category, current_gender, pending_row)
        pending_row = nil
      end

      cat_from_line = row.delete('category_from_line')
      current_category = cat_from_line if cat_from_line
      cat = cat_from_line || current_category

      # If there was a pending status and row has no explicit NT/DNS
      if pending_status && row['pos'] =~ /\A\d+\z/
        row['pos'] = pending_status
        row['timing'] = pending_status
      end
      pending_status = nil

      row['year_of_birth'] = nil
      add_section_row(sections, current_race, cat, current_gender, row)
      pending_row = nil
      next
    end

    # Category alone on a line
    cat_only = line.match(/\A\s+([MF]\d{2})\s*\z/)
    if cat_only
      current_category = cat_only[1]
      next
    end

    # Category with DNS/NT status but no athlete (e.g. "M60    DNS")
    cat_status = line.match(/\A\s+([MF]\d{2})\s+(DNS|NT|DSQ)\s*\z/i)
    if cat_status
      current_category = cat_status[1]
      pending_status = cat_status[2].upcase
      next
    end

    # Standalone DNS/NT/DSQ line (applies to next athlete)
    if /\A(DNS|NT|DSQ)\s*\z/i.match?(stripped)
      pending_status = stripped.upcase
      next
    end

    # Try partial row (name without team)
    partial = parse_athlete_only(line)
    if partial
      if pending_row
        # Two partials in a row - flush first as-is
        pending_row['year_of_birth'] = nil
        add_section_row(sections, current_race, current_category, current_gender, pending_row)
      end
      pending_row = partial
      next
    end

    # Try team-only line (continuation of split row)
    team = parse_team_only(line)
    if team && pending_row
      pending_row['team'] = team
      pending_row['year_of_birth'] = nil
      add_section_row(sections, current_race, current_category, current_gender, pending_row)
      pending_row = nil
      next
    end

    # If we have a pending row and this line has timing+score
    next unless pending_row && !pending_row['timing']

    m = line.match(/\A\s*(#{TIMING_RE})\s+(\d{1,4})\s*\z/io)
    if m
      pending_row['timing'] = convert_timing(m[1])
      pending_row['std_score'] = m[2]
      pending_row['year_of_birth'] = nil
      add_section_row(sections, current_race, current_category, current_gender, pending_row)
      pending_row = nil
      next
    end
    m = line.match(/\A\s*(#{TIMING_RE})\s*\z/io)
    next unless m

    pending_row['timing'] = convert_timing(m[1])
    pending_row['year_of_birth'] = nil
    add_section_row(sections, current_race, current_category, current_gender, pending_row)
    pending_row = nil
    next
  end

  # Flush any pending row
  if pending_row
    pending_row['year_of_birth'] = nil
    add_section_row(sections, current_race, current_category, current_gender, pending_row)
  end

  dbg "[IND] Done: #{sections.length} sections"
  sections.values
end

def add_section_row(sections, race, category, gender, row)
  return unless race && category && gender

  title = "#{race} - #{category}"
  key = [title, category, gender]
  sections[key] ||= {
    'title' => title,
    'fin_sigla_categoria' => category,
    'fin_sesso' => gender,
    'rows' => []
  }
  sections[key]['rows'] << row
end

# --- Relay results parser ---

def parse_relays(lines)
  sections = {}
  # First relay results appear before the "4x50m Freestyle" title line,
  # so default to Freestyle:
  current_relay_race = '4x50 Stile Libero'

  dbg "[REL] Starting relay parse with #{lines.length} lines"
  i = 0
  while i < lines.length
    line = lines[i]
    stripped = line.strip
    dbg "[REL L#{i}] #{stripped[0..80]}"

    # Skip blanks and headers
    if stripped.empty? || stripped =~ /World Aquatics|Risultati atleti|RACE\s+GENDER/i
      i += 1
      next
    end

    # Detect relay race title
    if /\A\s*4x50m\s+(Freestyle|Medley)\s*\z/i.match?(stripped)
      current_relay_race = normalize_relay_title(stripped)
      i += 1
      next
    end

    # Detect gender+category+pos+timing line
    # "  M      200-239     16                                                                                     2:00.76"
    # "  W      200-239     2"
    # "  X      200-239    DNS                                                                                      DNS"
    gcp_match = line.match(/\A\s+([MWX])\s+(\d{3}-\d{3})\s+(\d{1,3}|DNS)\s+(.+)?\s*\z/i)
    if gcp_match
      gender = gcp_match[1].upcase == 'W' ? 'F' : gcp_match[1].upcase
      category = gcp_match[2]
      pos = gcp_match[3]
      rest = gcp_match[4].to_s.strip

      # Extract timing from rest (may be on this line or need to find it)
      timing = nil
      tm = rest.match(/(#{TIMING_RE})/io)
      timing = if tm
                 convert_timing(tm[1])
               else
                 (/DNS/i.match?(pos) ? 'DNS' : nil)
               end

      # If no timing on this line, look at next lines for timing
      if timing.to_s.empty?
        # Look forward for timing
        ((i + 1)..[i + 5, lines.length - 1].min).each do |j|
          tm2 = lines[j].match(/(#{TIMING_RE})/io)
          if tm2
            timing = convert_timing(tm2[1])
            break
          end
        end
      end

      timing ||= (/DNS/i.match?(pos) ? 'DNS' : '')

      # Look backwards for team name
      team = nil
      (i - 1).downto([i - 5, 0].max).each do |j|
        candidate = lines[j].strip
        next if candidate.empty?
        next if /\A\s*4x50m/i.match?(candidate)
        next if /\A\s*[MWX]\s+\d{3}-\d{3}/i.match?(candidate)
        next if /\(.*\)/.match?(candidate) # swimmer line

        # Strip trailing timing from team name (e.g. "KLAB SPORT          1:51.89")
        candidate = candidate.sub(/\s+#{TIMING_RE}\s*$/io, '').strip
        team = candidate
        break
      end

      # Look forward for swimmer names in parentheses
      swimmers = nil
      ((i + 1)..[i + 5, lines.length - 1].min).each do |j|
        sm = lines[j].match(/\(([^)]+)\)/)
        if sm
          swimmers = sm[1].split(';').map(&:strip)
          break
        end
      end

      # If team wasn't found backwards, look forward (before swimmers)
      unless team
        ((i + 1)..[i + 5, lines.length - 1].min).each do |j|
          candidate = lines[j].strip
          next if candidate.empty?
          next if /\(.*\)/.match?(candidate)
          next if /\A\s*[MWX]\s+\d{3}-\d{3}/i.match?(candidate)

          candidate = candidate.sub(/\s+#{TIMING_RE}\s*$/io, '').strip
          team = candidate
          break
        end
      end

      unless current_relay_race && team && swimmers
        dbg "[REL] Skipping row at L#{i}: missing data (race=#{current_relay_race}, team=#{team}, swimmers=#{swimmers})"
        i += 1
        next
      end

      row = {
        'pos' => pos,
        'relay' => true,
        'team' => team,
        'timing' => timing
      }

      swimmers.each_with_index do |sw, idx|
        n = idx + 1
        row["swimmer#{n}"] = sw
        row["year_of_birth#{n}"] = nil
        row["gender_type#{n}"] = (gender == 'X' ? nil : gender)
      end

      title = "#{current_relay_race} - #{category}"
      key = [title, category, gender]
      sections[key] ||= {
        'title' => title,
        'fin_sigla_categoria' => category,
        'fin_sesso' => gender,
        'rows' => []
      }
      sections[key]['rows'] << row

      i += 1
      next
    end

    i += 1
  end

  dbg "[REL] Done: #{sections.length} sections"
  sections.values
end

def normalize_relay_title(raw)
  raw = raw.strip.gsub(/\s+/, ' ')
  m = raw.match(/\A(4x50)m?\s+(.+)\z/i)
  return raw unless m

  "#{m[1]} #{italian_stroke(m[2])}"
end

# --- Main ---

puts "Reading #{TXT_PATH}..."
raw_lines = File.readlines(TXT_PATH, chomp: true)
puts "Read #{raw_lines.length} lines."

# Find relay section start
relay_start_idx = raw_lines.index { |l| l =~ /Staffette/i } || raw_lines.length
puts "Relay section starts at line #{relay_start_idx + 1}."

ind_lines = raw_lines[0...relay_start_idx]
relay_lines = raw_lines[relay_start_idx..]

puts "Parsing #{ind_lines.length} individual lines..."
ind_sections = parse_individuals(ind_lines)
puts "Individual parsing done: #{ind_sections.length} sections, #{ind_sections.sum { |s| s['rows'].length }} rows."

puts "Parsing #{relay_lines.length} relay lines..."
relay_sections = parse_relays(relay_lines)
puts "Relay parsing done: #{relay_sections.length} sections, #{relay_sections.sum { |s| s['rows'].length }} rows."

# Load existing JSON to preserve header fields
existing = JSON.parse(File.read(JSON_PATH))
existing['sections'] = ind_sections + relay_sections

File.write(JSON_PATH, "#{JSON.pretty_generate(existing, indent: '  ')}\n")

puts "Done. #{ind_sections.length} individual sections, #{relay_sections.length} relay sections."
puts "Total rows: #{(ind_sections + relay_sections).sum { |s| s['rows'].length }}"
