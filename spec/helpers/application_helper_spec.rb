# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper do
  describe '#current_theme' do
    it "is 'light' without a theme cookie" do
      expect(helper.current_theme).to eq('light')
    end

    %w[light dark].each do |theme|
      it "returns '#{theme}' when the theme cookie says so" do
        helper.request.cookies[:theme] = theme
        expect(helper.current_theme).to eq(theme)
      end
    end

    it "falls back to 'light' for an unsupported theme cookie" do
      helper.request.cookies[:theme] = 'neon" onload="alert(1)'
      expect(helper.current_theme).to eq('light')
    end
  end
end
