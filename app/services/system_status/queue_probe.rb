# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::QueueProbe
  #
  # Liveness of the Solid Queue processes, read inline from the local queue DB (a dead queue could never refresh
  # its own snapshot): the processes with a heartbeat in the last HEARTBEAT_WINDOW (Solid Queue's own "alive"
  # threshold; heartbeats come every minute).
  #
  # Levels: :ok a supervisor and at least one worker for each queue of config/queue.yml; :warn a configured queue
  # has no live worker (its jobs wait); :error no live supervisor (no job runs at all); :unknown when Solid Queue is
  # not the Active Job adapter (e.g. the test environment) or the queue DB can't be read. With
  # SOLID_QUEUE_IN_PUMA=false (config/puma.rb) the :error detail says to run bin/jobs. Never raises.
  #
  class QueueProbe < Probe
    HEARTBEAT_WINDOW = 5.minutes
    QUEUE_CONFIG_PATH = Rails.root.join('config/queue.yml')

    # A live Solid Queue process: kind ('Supervisor(fork)', 'Worker', 'Dispatcher', 'Scheduler'), the queue names
    # of a worker (Array of Strings, '*' for all), last heartbeat time.
    LiveProcess = Data.define(:kind, :queues, :last_heartbeat_at) do
      def supervisor? = kind.to_s.start_with?('Supervisor')
      def worker? = kind.to_s == 'Worker'
    end

    class << self
      # Solid Queue processes with a heartbeat after +since+ (queue DB read), as LiveProcess.
      def live_processes(since:)
        SolidQueue::Process.where(last_heartbeat_at: since..).map do |process|
          metadata = process.metadata.is_a?(Hash) ? process.metadata : {}
          LiveProcess.new(kind: process.kind, queues: metadata['queues'].to_s.split(',').map(&:strip).compact_blank,
                          last_heartbeat_at: process.last_heartbeat_at)
        end
      end

      # Queue names served by the workers of config/queue.yml for the current environment.
      def configured_queues(path: QUEUE_CONFIG_PATH)
        config = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
        workers = Array((config[Rails.env] || config['default'] || {})['workers'])
        workers.flat_map { |worker| Array(worker['queues']).flat_map { |queues| queues.to_s.split(',') } }.map(&:strip).compact_blank.uniq
      rescue StandardError
        []
      end

      # True when the Solid Queue supervisor does not run inside Puma (config/puma.rb).
      def outside_puma?
        ENV['SOLID_QUEUE_IN_PUMA'] == 'false'
      end
    end

    protected

    def evaluate
      return result(:unknown, detail: detail_text(:not_in_use)) unless Dashboard::QueueActivity.solid_queue?

      processes = self.class.live_processes(since: now - HEARTBEAT_WINDOW)
      return result(:error, detail: dead_detail, checked_at: now) if processes.none?(&:supervisor?)

      missing = missing_queues(processes)
      return result(:warn, detail: detail_text(:missing_workers, queues: missing.join(', ')), checked_at: now) if missing.any?

      last_beat = processes.filter_map(&:last_heartbeat_at).max
      result(:ok, detail: detail_text(:ok, count: processes.size, ago: (now - last_beat).round), checked_at: last_beat)
    end

    private

    def missing_queues(processes)
      served = processes.select(&:worker?).flat_map(&:queues)
      return [] if served.include?('*')

      self.class.configured_queues - served
    end

    def dead_detail
      self.class.outside_puma? ? detail_text(:dead_outside_puma) : detail_text(:dead)
    end
  end
end
