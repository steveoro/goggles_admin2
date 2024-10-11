# frozen_string_literal: true

# Create logger that ignores messages containing “CACHE”
class CacheFreeLogger < Logger
  def debug(message, *args, &)
    super unless message.include? 'CACHE'
  end
end

# Overwrite ActiveRecord’s logger (2 options, uncomment the preferred one):
# 1. output on $stdout:
# ActiveRecord::Base.logger = ActiveSupport::TaggedLogging.new(CacheFreeLogger.new($stdout)) unless Rails.env.test?

# 2. "classic" logging using Rails.logger (but without "CACHE" statements):
ActiveRecord::Base.logger = ActiveSupport::TaggedLogging.new(Rails.logger) unless Rails.env.test?
