module KTorrent
  class Torrent::PeerManager
    DEFAULT_PORT = 22096
    MAX_CONNECTIONS = 10
    PEER_RETRY_TIME = 300 # 5 minutes

    attr_reader :torrent, :service_thread, :service_commands, :connections_out, :tracker_provided_peers, :failed_peers

    attr_reader :pieces_being_retrieved, :workers_pending_pieces

    def initialize(torrent:)
      @torrent = torrent

      cleanup
    end

    def cleanup
      @service_thread = nil
      @service_commands = Queue.new

      # service_thread variables
      @connections_out = {} # "#{IP}:#{PORT}" => PeerWorker
      @tracker_provided_peers = {} # "#{IP}:#{PORT}" => peer_id in 20-bytes binary or nil
      @failed_peers = {} # "#{IP}:#{PORT}" => Time


      @pieces_being_retrieved = {} # Worker => [piece_id*]
      @workers_pending_pieces = {} # piece_id => Worker

      # @server = nil
      # @server_thread = nil
      # @connections_in = Set.new
    end

    # def start_tcp_server # For seeding
    #   unless @server
    #     @server_connections = []
    #     @server = TCPServer.new('127.0.0.1', DEFAULT_PORT)
    #     @server_thread = Thread.new do
    #       loop do
    #         Thread.new(@server.accept) do |connection_in|
    #           server_connection_handler(connection_in)
    #         end
    #       end
    #     end
    #   end
    #   @server
    # end

    # def server_connection_handler(connection_in)

    # end



    def service_start(restart: false)
      return false unless @service_thread.nil? || restart
      @service_thread.kill unless @service_thread.nil?

      cleanup

      @service_thread = Thread.new do
        begin
          exit = false
          until exit do
            command = @service_commands.pop # blocks, does not wait spin
            @failed_peers = @failed_peers.select { |host, time| time + PEER_RETRY_TIME > Time.now } # sliding window

            case command[0]
            when 'tracker updated'
              @tracker_provided_peers = command[1].map { |host_info| ["#{host_info['ip']}:#{host_info['port']}", host_info['peer id']]}.to_h
              @service_commands.push(['more connections'])
            when 'connect'
              ip, port, peer_id = command[1]
              worker = ::KTorrent::Torrent::PeerWorker.new(manager: self, ip: ip, port: port, peer_id: peer_id)
              @connections_out[worker.ip_port] = worker
              worker.start_thread

            when 'disconnect'
              ip_port, worker, error = command[1]

              if error
                case error
                when Errno::ETIMEDOUT
                  # A connection attempt failed because the connected party did not properly respond after a period of time,
                  # or established connection failed because connected host has failed to respond
                  ::KTorrent.log("Worker #{worker.ip_port} failed with Errno::ETIMEDOUT")
                when Errno::ECONNREFUSED
                  # No connection could be made because the target machine actively refused it
                  ::KTorrent.log("Worker #{worker.ip_port} failed with Errno::ECONNREFUSED")
                when Errno::ECONNRESET
                  # An existing connection was forcibly closed by the remote host
                  ::KTorrent.log("Worker #{worker.ip_port} failed with Errno::ECONNRESET")
                when SocketError
                  # getaddrinfo: This is usually a temporary error during hostname resolution and means that the local server did not receive a response from an authoritative server.
                  # getaddrinfo: No such host is known
                  ::KTorrent.log("Worker #{worker.ip_port} failed with SocketError")
                when ::KTorrent::Torrent::TrackerManager::BadTrackerResponse
                  ::KTorrent.log("Worker #{worker.ip_port} failed with error from tracker: #{e.message}")
                when ::KTorrent::Torrent::PeerWorker::HandShakeFailed
                  ::KTorrent.log("Worker #{worker.ip_port} failed with bad peer handshake")
                else
                  ::KTorrent.log("Worker #{worker.ip_port} failed with #{error.inspect + "\n" + error.backtrace[0..2].join("\n")}")
                end
              end
              worker.clean_up

              @connections_out.delete(ip_port)
              @failed_peers[ip_port] = Time.now
              @pieces_being_retrieved.delete(worker)
              @workers_pending_pieces.reject! {|piece_id, wk| wk == worker }

              @service_commands.push(['more connections'])
            when 'more connections'
              # try to add more connections, if not at quota yet and possible
              @tracker_provided_peers.select { |ip_port, peer_id|
                !@failed_peers.key?(ip_port)
              }.to_a
               .sample([MAX_CONNECTIONS - @connections_out.size, 0].max)
               .to_h
               .each { |ip_port, peer_id|
                ip, port = ip_port.split(':')
                service_commands.push(['connect', [ip, port, peer_id]])
              }
            when 'retrieve pieces'
              worker = command[1]
              pieces = worker.state.have
              worker_can_request = torrent.data.have_all.zip(pieces).map.with_index do |(self_have, worker_have), piece_id|
                !self_have && worker_have && !@workers_pending_pieces.key?(piece_id)
              end

              piece_ids = worker_can_request.each_index.select { |piece_id| worker_can_request[piece_id] }
              @pieces_being_retrieved[worker] ||= []
              want = piece_ids.take([::KTorrent::Torrent::PeerWorker::MAX_REQUESTED_PIECES - @pieces_being_retrieved[worker].size, 0].max)
              want.each do |piece_id|
                @pieces_being_retrieved[worker].push(piece_id)
                @workers_pending_pieces[piece_id] = worker
              end
              worker.queue.push(['attempt pieces', want])
            when 'received piece'
              worker, piece_id, data = command[1]
              ::KTorrent.log("received piece #{piece_id} from #{worker.ip_port}")

              torrent.data[piece_id] = data

              service_commands.push(['retrieve pieces', worker])
            when 'abandoned piece'
              worker, piece_id = command[1]

              # remove piece id from pieces_being_retrieved
              @workers_pending_pieces.delete(piece_id)
              @pieces_being_retrieved[worker].delete(piece_id)

            when 'saved piece'
              piece_id = command[1]

              # remove piece id from pieces_being_retrieved
              worker = @workers_pending_pieces[piece_id]
              @workers_pending_pieces.delete(piece_id)
              @pieces_being_retrieved[worker].delete(piece_id)

              ::KTorrent.log("saved piece #{piece_id} from #{worker.ip_port}")

              connections_out.each { |ip_port, worker| worker.queue.push(['send have', piece_id]) }
            when 'exit'
              exit = true
            end
          end
        rescue StandardError => e
          ::KTorrent.log("Peer Manager crashed with #{e.inspect + "\n" + e.backtrace[0..2].join("\n")}")
        ensure
          ::KTorrent.log("Peer Manager has stopped")
        end
      end
    end

    def service_stop
      # @service_commands.push(['exit'])

      @connections_out.each do |ip_port, worker|
        worker.clean_up
      end
      @service_thread.kill unless @service_thread.nil?
      @service_thread = nil
    end

    def notify_on_tracker_update
      @service_commands.push(['tracker updated', @torrent.trackers.valid_peers])
    end

    def peer_id(hex = true)
      @client_id ||= '-KW2221-' + ("%012d" % 1451199765)
      hex and @client_id.unpack('H*').first or @client_id.downcase
    end

    def port
      @port ||= DEFAULT_PORT
    end

    def uploaded
      self.class.uploaded
    end

    def downloaded
      self.class.downloaded
    end

    def self.uploaded
      @uploaded ||= 0
    end

    def self.downloaded
      @downloaded ||= 0
    end
  end
end
