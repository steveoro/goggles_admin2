# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::ExtractionPrompt
  #
  #   - version:  7-0.10.55
  #   - author:   Devin
  #
  # Builds the structured-extraction prompt sent to the local Ollama model
  # for meeting manifest ("locandina") data extraction.
  # The model is asked to output a compact JSON object matching the schema
  # documented below; post-processing and validation is done by Lt4Builder.
  #
  module ExtractionPrompt
    PROMPT_HEADER = <<~TEXT
      You are an extraction tool for Italian swimming meeting manifests ("locandine").
      From the manifest text below, output a JSON object with EXACTLY this shape (compact, no markdown, no comments):

      {"meeting_name": str|null, "edition": int|null, "dates": ["YYYY-MM-DD"], "venue_name": str|null, "address": str|null, "city": str|null, "province": str|null, "pool_length_meters": int|null, "lanes": int|null, "max_individual_events": int|null, "events": [{"session_date": "YYYY-MM-DD"|null, "day_part": "morning"|"afternoon"|null, "distance": int, "stroke": "SL"|"DO"|"RA"|"FA"|"MI", "relay": bool, "relay_style": "4x50"|"4x100"|null, "gender": "M"|"F"|"X"|null, "raw_label": str}]}

      Rules:
      - meeting_name: official title of the meeting, including the edition ordinal when present (e.g. "25° Trofeo Città di Verolanuova")
      - edition: the ordinal number of the edition ("25°" => 25), null when absent
      - dates: all competition days in ISO format. Take them ONLY from the race program / date heading
        (e.g. "8 Novembre - domenica mattina"); never use registration/opening deadlines
        ("iscrizioni aperte dal...", "entro il...", "le iscrizioni dovranno pervenire").
      - venue_name: swimming pool / facility name only (e.g. "Piscina Comunale Nannini")
      - address: street address including civic number, without city
      - city / province: city hosting the pool; 2-letter province code when written (e.g. "(BS)")
      - pool_length_meters: 25 or 50 - race pool only, ignore warm-up/secondary pools
      - lanes: lane count of the race pool
      - max_individual_events: max individual races allowed per athlete ("massimo di TRE gare" => 3), null if not stated
      - events: the race program, in the order listed. IMPORTANT: the program is often a single line
        packing several events separated by dashes (-, – or —). Split EVERY dash-separated
        distance+stroke token into its own event - never merge them into a single event.
        Example: the line "inizio gare 800SL (1 per corsia) max 80 iscritti - 50FA – 50RA – 1 0 0 S L –200MX"
        yields exactly FIVE events: 800SL, 50FA, 50RA, 100SL, 200MI.
        Parenthesized notes and "max N iscritti" quotas annotate the preceding event only.
        For each event:
        - session_date: the day it is swum (null if unclear)
        - day_part: "morning"|"afternoon"|null (mattina/mattino => morning, pomeriggio => afternoon)
        - distance: total distance in meters (relays: 4x50 => 200, 4x100 => 400)
        - stroke: SL=stile libero, DO=dorso, RA=rana, FA=farfalla/delfino, MI=misti/medley. Fix spacing or typos ("1 0 0 S L" => 100 SL, "50DR" => 50 DO)
        - relay: true for staffetta/staff./mistaffetta/saffetta mista
        - relay_style: "4x50"|"4x100" or null
        - gender: "X" for mistaffetta / staffetta mista (mixed relay); "M"|"F" only when the event is explicitly single-gender; null otherwise
        - raw_label: the event text exactly as written in the manifest
      - Only raced events: ignore riscaldamento (warm-up), pausa (break), iscrizioni (registrations), time limits and quotas.
      - Output ONLY the JSON. Use null for anything not stated in the document.
    TEXT

    # Builds the full prompt for the given manifest text contents.
    def self.build(manifest_text)
      "#{PROMPT_HEADER}\nMANIFEST TEXT:\n#{manifest_text}"
    end

    # Builds the prompt variant used with page images (scanned PDFs).
    def self.build_for_images
      "#{PROMPT_HEADER}\nThe manifest content is provided as page images. Read them and output the same JSON.\nMANIFEST IMAGES ATTACHED."
    end
  end
end
