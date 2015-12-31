module KTorrent
  class Torrent::TrackerManager
    BadTrackerResponse = Class.new(StandardError)

    attr_reader :updating, :status

    def initialize(torrent:)
      @torrent = torrent
      @status = {}
      @updating = false
    end

    def http_trackers
      @torrent.properties.trackers.select { |t| t[0...4] == 'http' }
    end

    def request_url(tracker_url = @torrent.properties.primary_tracker)
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

    def update_trackers(blocking: false)
      return @status if @updating

      @updating = true
      thr = Thread.start do
        begin
          trackers = http_trackers
          threads = []

          trackers.each do |tracker_url|
            threads << Thread.start do
              begin
                request_url = request_url(tracker_url)
                uri = URI(request_url)
                ::KTorrent.log("Requesting: #{tracker_url}")
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
                    results << {"ip" => ip, "port" => port}
                  end
                  data['peers'] = results
                end

                ::KTorrent.log("Request to #{tracker_url} succeeded")
                @status[tracker_url] ||= {}
                @status[tracker_url].merge!(state: :success, time: Time.now, response: content, data: data)
              rescue StandardError => e
                ::KTorrent.log("Request to #{tracker_url} failed with error #{e.inspect}")
                @status[tracker_url] ||= {}
                @status[tracker_url].merge!(state: e, time: Time.now, response: content, data: nil)
              end
            end
          end

          threads.each(&:join)
        ensure
          @updating = false
        end
      end

      thr.join if blocking

      @status
    end

    def successful_trackers
      @status.select { |url, data| data[:state] == :success }
    end
  end
end
