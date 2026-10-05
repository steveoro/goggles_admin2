# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::ExtractionPrompt, type: :strategy do
  describe '.build_correction' do
    subject(:prompt) { described_class.build_correction('MANIFEST BODY', issues, codes) }

    let(:issues) do
      [
        "event code 'M4X50DO' (relay=true) not found in event_types",
        'possible missing program events not extracted: 100MI, 200DO'
      ]
    end
    let(:codes) { %w[100MI 200DO M4X50MI M4X50SL] }

    it 'lists each detected issue' do
      expect(prompt).to include("- event code 'M4X50DO' (relay=true) not found in event_types")
      expect(prompt).to include('- possible missing program events not extracted: 100MI, 200DO')
    end

    it 'includes the valid code catalog and the manifest text' do
      expect(prompt).to include('Valid event code catalog: 100MI, 200DO, M4X50MI, M4X50SL')
      expect(prompt).to include('MANIFEST BODY')
    end

    it 'instructs to re-verify rather than blindly remap' do
      expect(prompt).to include('keep it as is')
      expect(prompt).to include('same schema')
    end
  end
end
