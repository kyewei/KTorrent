module KTorrent
  class Torrent::TrackerManager
    BadTrackerResponse = Class.new(StandardError)
    TrackerStatus = Struct.new(:state, :time, :response, :data)
    DEFAULT_UPDATE_TIME = 300 # 5 minutes

    attr_reader :torrent, :service_thread, :updating, :status

    def initialize(torrent:)
      @torrent = torrent
      @status = {}
      @updating = false

      @service_thread = nil
    end

    def service_start(restart: false)
      return false unless @service_thread.nil? || restart
      service_stop if restart

      @service_thread = Thread.new do
        ::KTorrent.log("Tracker service has started")
        loop do
          update_trackers(blocking: false, notify: true)
          sleep(DEFAULT_UPDATE_TIME)
        end
      end

      true
    end

    def service_stop
      @service_thread.kill unless @service_thread.nil?
      ::KTorrent.log("Tracker service has stopped")
      @service_thread = nil
    end

    def http_trackers
      @torrent.properties.trackers.select { |t| t[0...4] == 'http' }
    end

    def request_url(tracker_url: torrent.properties.primary_tracker)
      return nil if tracker_url.nil?
      params =
      {
        info_hash: @torrent.properties.info_hash(hex = false),
        peer_id: @torrent.peers.peer_id(hex = false),
        port: @torrent.peers.port,
        uploaded: @torrent.peers.uploaded,
        downloaded: @torrent.peers.downloaded,
        left: @torrent.properties.total_size,
      }
      path = [tracker_url, URI.encode_www_form(params)].join('?')
    end

    def update_trackers(blocking: false, notify: true)
      return @status if @updating

      @updating = true
      thr = Thread.new do
        begin
          trackers = http_trackers
          threads = []
          ::KTorrent.log("Updating #{trackers.size} trackers")
          trackers.each do |tracker_url|
            threads << Thread.new do
              begin
                request_url = request_url(tracker_url: tracker_url)
                uri = URI(request_url)
                ::KTorrent.debug("Requesting: #{tracker_url}")
                content = data = nil
                content = Net::HTTP.get(uri)
                data = ::KTorrent::BEncoding.decode(content)

                raise BadTrackerResponse, data['failure reason'] if data.key?('failure reason')
                raise BadTrackerResponse, "Failed due to code: #{data['failure code']}" if data.key?('failure code')
                ::KTorrent.log(data['warning message']) if data.key?('warning message')
                raise BadTrackerResponse unless ['peers'].all? { |k| data.key?(k) }

                if (data['peers'].is_a?(String)) # Handle binary format of peers information
                  grouped_data = data['peers'].chars.each_slice(6).to_a
                  raise BadTrackerResponse, "Improper binary peer information" unless grouped_data.all? { |b| b.size == 6 }
                  results = []
                  grouped_data.each do |bytes|
                    result = bytes.map(&:ord)
                    ip = result[0...4].join('.')
                    port = result[4] * 256 + result[5]
                    results << {"peer id" => nil, "ip" => ip, "port" => port}
                  end
                  data['peers'] = results
                end

                ::KTorrent.debug("Request to #{tracker_url} succeeded")
                @status[tracker_url] = TrackerStatus.new(:success, Time.now, content, data)
              rescue StandardError => e
                case e
                when Errno::ETIMEDOUT
                  # A connection attempt failed because the connected party did not properly respond after a period of time,
                  # or established connection failed because connected host has failed to respond
                  ::KTorrent.log("Tracker #{tracker_url} failed with Errno::ETIMEDOUT")
                when Errno::ECONNREFUSED
                  # No connection could be made because the target machine actively refused it
                  ::KTorrent.log("Tracker #{tracker_url} failed with Errno::ECONNREFUSED")
                when Errno::ECONNRESET
                  # An existing connection was forcibly closed by the remote host
                  ::KTorrent.log("Tracker #{tracker_url} failed with Errno::ECONNRESET")
                when SocketError
                  # getaddrinfo: This is usually a temporary error during hostname resolution and means that the local server did not receive a response from an authoritative server.
                  # getaddrinfo: No such host is known
                  ::KTorrent.log("Tracker #{tracker_url} failed with SocketError")
                when ::KTorrent::Torrent::TrackerManager::BadTrackerResponse
                  ::KTorrent.log("Tracker #{tracker_url} failed with error from tracker: #{e.message}")
                else
                  ::KTorrent.log("Tracker #{tracker_url} failed with #{error.inspect + "\n" + error.backtrace[0..2].join("\n")}")
                end
                @status[tracker_url] = TrackerStatus.new(e, Time.now, content, nil)
              end
            end
          end

          threads.each(&:join)
        ensure
          Thread.new { @torrent.peers.notify_on_tracker_update } if torrent.peers && notify
          @updating = false
          successful = @status.select { |tracker_url, status| status.state == :success && Time.now - status.time < DEFAULT_UPDATE_TIME }
          failed = @status.select { |tracker_url, status| status.state != :success && Time.now - status.time < DEFAULT_UPDATE_TIME }
          ::KTorrent.log("Trackers updated: #{successful.size} succeeded, #{failed.size} failed")
        end
      end

      thr.join if blocking

      @status
    end

    def successful_trackers
      @status.select { |url, data| data.state == :success }
    end

    def valid_peers
      # [{'peer id' => X, 'ip' => 'x', 'port => 'y}]
      successful_trackers.values.map(&:data).map { |data| data['peers'] }.flatten(1).uniq
    end
  end
end
