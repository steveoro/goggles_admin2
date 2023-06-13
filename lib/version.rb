# frozen_string_literal: true

#
# == Versioning codes
#
#   - version:  7-0.5.10
#   - author:   Steve A.
#
# Framework version number usually differs from core engine versioning number.
# Actual Semantic versioning code is stored into 'goggles_db'.
# To be sure getting the correct Semantic versioning number, either use:
#
# > require 'goggles_db/version'
# > GogglesDb::VERSION
#
# Or:
#
# > require 'version'
# > Version::SEMANTIC
#
module Version
  # Framework Core internal name.
  CORE = 'C7'

  # Major version.
  MAJOR = '0'

  # Minor version.
  MINOR = '5'

  # Patch version.
  PATCH = '10'

  # Current build version.
  BUILD = '20230601'

  # Full versioning for the current release.
  FULL = "#{MAJOR}.#{MINOR}.#{PATCH} (#{CORE}-#{BUILD})"

  # Compact semantic versioning label for the current framework release.
  SEMANTIC = "#{MAJOR}.#{MINOR}.#{PATCH}"

  # Current internal DB version (independent from migrations and framework release)
  DB = '1.99.0'
end
