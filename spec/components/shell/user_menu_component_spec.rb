# frozen_string_literal: true

require 'rails_helper'
require 'version'

RSpec.describe Shell::UserMenuComponent, type: :component do
  subject(:html) { render_inline(described_class.new(user:)) }

  let(:user) { FactoryBot.build(:user) }

  it 'shows the user name' do
    expect(html.at_css('#user-menu').text).to include(user.name)
    expect(html.at_css('.dropdown-menu .dropdown-header').text).to include(user.name)
  end

  it 'has the locale switch to the other locale' do
    I18n.with_locale(:en) do
      link = html.at_css('a#href-locale-switch.dropdown-item')
      expect(link['href']).to include('locale=it')
      expect(link.text).to include('🇮🇹')
    end
    I18n.with_locale(:it) do
      link = render_inline(described_class.new(user:)).at_css('a#href-locale-switch')
      expect(link['href']).to include('locale=en')
      expect(link.text).to include('🇬🇧')
    end
  end

  it 'shows the app version' do
    expect(html.at_css('#app-version').text).to include(Version::FULL)
  end

  it 'logs out through a Turbo DELETE' do
    link = html.at_css('a#btn-log-out')
    expect(link['href']).to eq('/users/sign_out')
    expect(link['data-turbo-method']).to eq('delete')
    expect(link.text).to include(I18n.t('home.log_out'))
  end

  it 'renders nothing without a user' do
    expect(render_inline(described_class.new(user: nil)).to_html).to be_empty
  end
end
