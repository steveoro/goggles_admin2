# frozen_string_literal: true

# Create logger that ignores messages containing “CACHE”
class CacheFreeLogger < Logger
  def debug(message, *args, &)
    super unless message.include? 'CACHE'
  end
end

# Overwrite ActiveRecord’s logger
# ActiveRecord::Base.logger = ActiveSupport::TaggedLogging.new(CacheFreeLogger.new($stdout)) unless Rails.env.test?
