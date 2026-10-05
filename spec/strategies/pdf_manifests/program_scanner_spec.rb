# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::ProgramScanner, type: :strategy do
  let(:scanner) { described_class.new }

  # Mirrors the real Gonzaga program section (morning + afternoon sessions).
  let(:gonzaga_text) do
    <<~TEXT
      09.00 inizio gare        200 sl – 50 fa – 100 ra – 100 do – 50 sl – 200 fa – 100mix
                               Staff 4x50 mix mista
      14.45 inizio gare        200 Mix – 200 ra –50do – 100sl – 100 fa – 50 ra – 200 do
                               Staff 4x50 sl mista
    TEXT
  end

  let(:full_events) do
    %w[200SL 50FA 100RA 100DO 50SL 200FA 100MI M4X50MI
       200MI 200RA 50DO 100SL 100FA 50RA 200DO M4X50SL].map { |c| { 'eventCode' => c } }
  end

  describe '#missing_mentions' do
    it 'returns an empty list when extracted events cover the program' do
      expect(scanner.missing_mentions(gonzaga_text, full_events)).to eq([])
    end

    it 'reports individual events dropped from the extraction' do
      dropped = %w[100MI 200DO]
      events = full_events.reject { |e| dropped.include?(e['eventCode']) }
      missing = scanner.missing_mentions(gonzaga_text, events)
      expect(missing).to include('100MI', '200DO')
      expect(missing.size).to eq(2)
    end

    it 'reports a relay extracted with the wrong stroke' do
      events = full_events.map do |e|
        e['eventCode'] == 'M4X50SL' ? { 'eventCode' => 'M4X50DO' } : e
      end
      expect(scanner.missing_mentions(gonzaga_text, events)).to eq(['staffetta 4x50sl'])
    end

    it 'ignores registration prose mentioning staffette without an NxM style' do
      text = <<~TEXT
        •   La quota di iscrizione è di € 16,00 a staffetta
        •   Ogni atleta può partecipare ad una staffetta per ogni tipo e sesso
        - staffette entro le ore 12.00 alle 19/11/26
      TEXT
      expect(scanner.missing_mentions(text, [])).to eq([])
    end

    it 'ignores venue descriptions like lane-size NxM mentions' do
      text = 'impianto con vasca da 8x25 metri e spogliatoi'
      expect(scanner.missing_mentions(text, [])).to eq([])
    end

    it 'does not count the relay leg length as an individual event' do
      text = 'Staff 4x50 sl mista'
      events = [{ 'eventCode' => 'M4X50SL' }]
      expect(scanner.missing_mentions(text, events)).to eq([])
    end

    it 'normalizes medley aliases (mix, misti, mx) to MI codes' do
      text = '100mix – 200 misti – 400 mx'
      events = [{ 'eventCode' => '100MI' }, { 'eventCode' => '400MI' }]
      expect(scanner.missing_mentions(text, events)).to eq(['200MI'])
    end

    it 'matches strokeless relay mentions on style alone' do
      text = 'staffetta 4x100'
      expect(scanner.missing_mentions(text, [{ 'eventCode' => 'S4X100MI' }])).to eq([])
      expect(scanner.missing_mentions(text, [{ 'eventCode' => 'S4X50MI' }])).to eq(['staffetta 4x100'])
    end
  end
end
