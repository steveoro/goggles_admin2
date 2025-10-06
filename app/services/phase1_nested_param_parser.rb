# frozen_string_literal: true

# Helper module for parsing nested indexed parameters in Phase 1 forms
# Handles the mixed structure from AutoComplete (indexed nested params) + form fields (top-level params)
#
# Example input structure:
#   { "0" => { "swimming_pool_id" => "22" }, "name" => "Stadio Nuoto", "address" => "Via..." }
#
module Phase1NestedParamParser
  # Parse nested parameters that may have both indexed nested structure and top-level structure
  #
  # @param raw_params [ActionController::Parameters, nil] The raw parameters hash
  # @param allowed_keys [Array<String>] List of permitted parameter keys
  # @param index_key [String, Integer] The session index to look for in nested structure
  # @return [Hash] Merged hash with all permitted parameters
  def self.parse(raw_params, allowed_keys, index_key)
    return {} unless raw_params.is_a?(ActionController::Parameters)

    idx_key = index_key.to_s

    # Extract nested indexed params (e.g., pool[0][swimming_pool_id])
    nested_hash = raw_params[idx_key] || raw_params[index_key]
    nested_data = nested_hash.is_a?(ActionController::Parameters) ? nested_hash.permit(allowed_keys).to_h : {}

    # Extract top-level params (e.g., pool[name])
    top_level_data = raw_params.except(idx_key, index_key.to_s).permit(allowed_keys).to_h

    # Merge both (nested params take precedence for IDs, top-level for everything else)
    top_level_data.merge(nested_data)
  end
end
