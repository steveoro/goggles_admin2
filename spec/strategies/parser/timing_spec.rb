# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe Timing, type: :strategy do
    describe 'self.from_l2_result' do
      describe 'with valid parameters (testing this 10 times w/ random values),' do
        10.times do
          let(:minutes) { [(rand * 15).to_i, 0].sample } # 50-50 chance of 0
          let(:seconds) { (rand * 59).to_i }
          let(:hundredths) { (rand * 99).to_i }

          context "when parsing format #1: {{d}d'}{d}d\"dd," do
            it 'returns the corresponding Timing instance' do
              formatted_text = if minutes.positive?
                                 format("%<min>d'%<sec>d\"%<hun>02d", min: minutes, sec: seconds, hun: hundredths)
                               else
                                 format('%<sec>d"%<hun>02d', sec: seconds, hun: hundredths)
                               end
              expected_value = ::Timing.new(minutes: minutes, seconds: seconds, hundredths: hundredths)
              result = described_class.from_l2_result(formatted_text)
              # DEBUG
              # puts "Parsing \"#{formatted_text}\" vs #{expected_value} => #{result}"
              # DEBUG ----------------------------------------------------------------
              # binding.pry if expected_value != result
              # ----------------------------------------------------------------------
              expect(result).to eq(expected_value)
            end
          end

          context 'when parsing format #2a: {{d}d:}{d}d.{d}d,' do
            it 'returns the corresponding Timing instance' do
              formatted_text = if minutes.positive?
                                 format('%<min>d:%<sec>d.%<hun>02d', min: minutes, sec: seconds, hun: hundredths)
                               else
                                 format('%<sec>d.%<hun>02d', sec: seconds, hun: hundredths)
                               end
              expected_value = ::Timing.new(minutes: minutes, seconds: seconds, hundredths: hundredths)
              result = described_class.from_l2_result(formatted_text)
              # DEBUG
              # puts "Parsing \"#{formatted_text}\" vs #{expected_value} => #{result}"
              # DEBUG ----------------------------------------------------------------
              # binding.pry if expected_value != result
              # ----------------------------------------------------------------------
              expect(result).to eq(expected_value)
            end
          end

          context 'when parsing format #2b: {{d}d.}{d}d.{d}d,' do
            it 'returns the corresponding Timing instance' do
              formatted_text = if minutes.positive?
                                 format('%<min>d.%<sec>d.%<hun>02d', min: minutes, sec: seconds, hun: hundredths)
                               else
                                 format('%<sec>d.%<hun>02d', sec: seconds, hun: hundredths)
                               end
              expected_value = ::Timing.new(minutes: minutes, seconds: seconds, hundredths: hundredths)
              result = described_class.from_l2_result(formatted_text)
              # DEBUG
              # puts "Parsing \"#{formatted_text}\" vs #{expected_value} => #{result}"
              # DEBUG ----------------------------------------------------------------
              # binding.pry if expected_value != result
              # ----------------------------------------------------------------------
              expect(result).to eq(expected_value)
            end
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
