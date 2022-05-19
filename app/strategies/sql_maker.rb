# rubocop:disable Style/FrozenStringLiteralComment

require 'singleton'

# = SqlMaker
#
#   - file vers.: 7-0.3.52
#   - author....: Steve A.
#   - build.....: 20220516
#
# Creates a replayable SQL log of the called methods on record row specified
# with the constructor.
#
# Currently allows also to reuse the same maker object for different assets rows.
#
# === Typical usage flow:
#
# 1. Make sure localhost DB is in-sync w/ remote DB (restore a backup, if not)
# 2. Create or update the imported record row
# 3. Pass the created/updated record to the SqlMaker and log the operation
# 4. Push the generated SQL log to the remote server for the batch update
#
class SqlMaker
  # Creates a new SqlMaker instance.
  #
  # == Params
  # - <tt>asset_row</tt>: a valid ActiveRecord Model instance (*required*)
  # - <tt>force_id_on_insert</tt>: when false, the +id+ column won't be used for INSERTs (default: +true+)
  #
  def initialize(asset_row:, force_id_on_insert: true)
    raise(ArgumentError, 'Invalid asset_row: must be an ActiveRecord Model instance') unless asset_row.is_a?(ActiveRecord::Base)

    @asset_row = asset_row
    @force_id_on_insert = force_id_on_insert
    @sql_log = []
  end

  # Clears the internal log list.
  def clear
    @sql_log.clear
  end

  # Allow to set the same SqlMaker instance to a different data source without clearing
  # the internal log list.
  #
  # == Params
  # - <tt>asset_row</tt>: a valid ActiveRecord Model instance (*required*)
  # - <tt>force_id_on_insert</tt>: when false, the +id+ column won't be used for INSERTs (default: +true+)
  #
  def set(asset_row:, force_id_on_insert: true)
    raise(ArgumentError, 'Invalid asset_row: must be an ActiveRecord Model instance') unless asset_row.is_a?(ActiveRecord::Base)

    @asset_row = asset_row
    @force_id_on_insert = force_id_on_insert
  end

  # Returns the whole log as a single String using the specified end of line separator
  # (default: "\r\n--\r\n\r\n").
  def report(eoln = "\r\n--\r\n\r\n")
    @sql_log.join(eoln)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Adds a new SQL INSERT statement to the result log using the latest <tt>@asset_row</tt> set.
  # (The statement is not executed.)
  #
  # == Returns
  # The last SQL (String) stament added to the log.
  #
  def log_insert
    klass = @asset_row.class
    con = klass.connection
    columns = []
    values  = []

    # Reject all non-columns:
    @asset_row.attributes
              .keep_if { |col_name| klass.column_names.include?(col_name) }
              .each do |key, value|
      next if value.blank? || (!@force_id_on_insert && key == 'id')

      columns << con.quote_column_name(key)
      values  << con.quote(value)
    end

    sql_text = "INSERT INTO #{con.quote_column_name(klass.table_name)} (#{columns.join(', ')})\r\n" \
               "  VALUES (#{values.join(', ')});"
    @sql_log << sql_text
    sql_text
  end

  # Adds a new SQL UPDATE statement to the result log using the latest <tt>@asset_row</tt> set.
  # (The statement is not executed.)
  #
  # == Returns
  # The last SQL (String) stament added to the log.
  #
  def log_update
    klass = @asset_row.class
    con = klass.connection
    sets = []

    # Write always all the attributes, unless the column name is "skippable" (& reject all non-columns):
    @asset_row.attributes
              .keep_if { |col_name| klass.column_names.include?(col_name) }
              .each do |key, value|
      next if key == 'lock_version'

      sets << "#{con.quote_column_name(key)}=#{con.quote(value)}"
    end

    sql_text = "UPDATE #{con.quote_column_name(klass.table_name)}\r\n" \
               "  SET #{sets.join(', ')}\r\n" \
               "  WHERE (#{con.quote_column_name('id')}=#{@asset_row.id});"
    @sql_log << sql_text
    sql_text
  end
  #-- -------------------------------------------------------------------------
  #++

  # Adds a *captured* ActiveRecord _destroy_ statement to the result log after executing it on the
  # latest <tt>@asset_row</tt> set.
  # In other words, this method will actually *destroy* the <tt>@asset_row</tt>, capturing the
  # executed SQL output in the log.
  #
  # Due to validation callbacks, the destroy is always more complete than a direct SQL DELETE.
  # Use this method to replicate the exact behaviour when running the SQL batch on the remote server.
  #
  # == Returns
  # The last SQL (String) script added to the log.
  #
  def log_destroy
    @asset_row.class.connection.class.class_eval do
      attr_accessor :captured_sql
      # Alias the adapter's execute for later use
      alias_method :old_execute, :execute
      # Re-define the execute method:
      def execute(sql, name = nil)
        @captured_sql ||= []
        # DEBUG
        puts "\r\n---- SQL ----"
        puts sql
        puts '-------------'
        # Intercept/log only the statement that we want and log it to the internal text:
        (@captured_sql << "#{sql};") if /^(delete)/i.match(sql)
        # Always execute the SQL statement afterwards:
        old_execute(sql, name)
      end
    end

    # Issue the destroy upon the record:
    @asset_row.destroy
    sql_text = @asset_row.class.connection.captured_sql.join("\r\n")
    @asset_row.class.connection.captured_sql = nil

    # Double Monkey-patch to stop the interception and restore original behaviour
    # (since it's almost safe)
    @asset_row.class.connection.class.class_eval do
      # Restore original implementation of execute:
      alias_method :execute, :old_execute
    end
    return nil unless @asset_row.destroyed? && sql_text.present?

    @sql_log << sql_text
    sql_text
  end
  #-- -------------------------------------------------------------------------
  #++
end
# rubocop:enable Style/FrozenStringLiteralComment
