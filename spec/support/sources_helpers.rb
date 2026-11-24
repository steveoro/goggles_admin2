# frozen_string_literal: true

# = Sources area specs (phase 15)
#
# shared_context 'with a Sources data root': a signed-in admin and a temporary 'crawler/data' folder
# (SeasonBoard::DiskIndex.default_data_dir, hence Sources.data_root, is stubbed to it), so that nothing reads or
# writes the real crawler/data; the board activity log of the test env is reset around each example.
RSpec.shared_context 'with a Sources data root' do
  include AdminSignInHelpers

  let(:sources_base_dir) { Pathname.new(Dir.mktmpdir('sources-spec-')).realpath }
  let(:data_root) { sources_base_dir.join('crawler', 'data') }
  let(:admin_user) { prepare_admin_user }

  # Writes +content+ at +relative+ (to the data root); returns the Pathname.
  def write_data(relative, content = '')
    path = data_root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  before(:each) do
    FileUtils.mkdir_p(data_root)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    sign_in_admin(admin_user)
  end

  after(:each) do
    FileUtils.rm_rf(sources_base_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end
end
