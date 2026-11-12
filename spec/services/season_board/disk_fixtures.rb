# frozen_string_literal: true

require 'base64'

# Helpers writing Season board disk fixtures under a temporary +data_dir+
# (the including spec must define `data_dir`, e.g. with Dir.mktmpdir).
module SeasonBoardDiskFixtures
  SEASON_DIR = '262'

  def results_url(fin_id)
    "https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/#{fin_id}:some-meeting.html"
  end

  def manifest_url(fin_id)
    encoded = Base64.strict_encode64("/var/www/fin_files/eventi/#{fin_id.to_s.rjust(10, '0')}.pdf")
    "https://www.federnuoto.it/component/solrconnect/download.html?file=#{encoded}"
  end

  def path_for(folder, name)
    File.join(data_dir, folder, SEASON_DIR, name)
  end

  def write_file(folder, name, content = '')
    path = path_for(folder, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def write_json(folder, name, hash)
    write_file(folder, name, JSON.generate(hash))
  end

  def lt2_hash(fin_id: nil, results: false, manifest_only_url: false)
    hash = { 'layoutType' => 2, 'name' => 'Meeting' }
    hash['meetingURL'] = results_url(fin_id) if fin_id && !manifest_only_url
    hash['manifestURL'] = manifest_url(fin_id) if fin_id
    hash['sections'] = results ? [{ 'title' => '50 SL - M25', 'rows' => [{ 'name' => 'ROSSI MARIO', 'timing' => '30.12' }] }] : []
    hash
  end

  def lt4_hash(fin_id: nil, results: false, meeting_only: false)
    hash = { 'layoutType' => 4, 'meetingName' => 'Meeting' }
    hash['meetingURL'] = results_url(fin_id) if fin_id
    hash['events'] = [{ 'eventCode' => '50SL', 'results' => results ? [{ 'swimmer' => 'x', 'timing' => '30.12' }] : [] }]
    hash['_meta'] = { 'meeting_only' => true } if meeting_only
    hash
  end
end
