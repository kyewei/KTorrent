module KTorrent
  class Torrent::PeerWorker
    State = Struct.new(:am_choking, :am_interested, :peer_choking, :peer_interested, :have) do
      def initialize(*args)
        torrent = yield
        args = [true, false, true, false, [false] * torrent.properties.pieces] if args == []
        super(*args)
      end
    end
    HandShakeFailed = Class.new(StandardError)

    MAX_REQUESTED_PIECES = 20
    REQUESTED_PIECE_CHUNK_SIZE = 2**14 # 16KB, not 32KB in the specs since most torrent software enforce this size

    attr_reader :manager, :torrent, :ip, :port, :peer_id
    attr_reader :socket, :thread, :state, :queue

    def initialize(manager:, ip:, port:, peer_id:)
      @manager = manager
      @torrent = manager.torrent
      @manager_command_queue = manager_command_queue
      @ip = ip
      @port = port
      @peer_id = peer_id

      @socket = nil
      @thread = nil
      @socket_thread = nil
      @state = nil
      @queue = nil
    end

    def manager_command_queue
      @manager.service_commands
    end

    def clean_up
      ::KTorrent.log("Worker #{ip_port} cleaned up after itself")
      @socket_thread.kill if @socket_thread
      queue.push(['exit'])
      @thread.kill if @thread
      @socket.close if @socket
      @socket_pipelining_thread.kill if @socket_pipelining_thread
    end

    def ip_port
      "#{ip}:#{port}"
    end

    def start_socket_reader_thread
      @socket_thread = Thread.new do
        begin
          error = nil
          loop do
            len = socket.read(4)
            msg_size = len.unpack('N').first
            next if msg_size.zero? # Keepalives
            msg = socket.read(msg_size)

            ::KTorrent.log("#{ip_port} - data received: #{msg.unpack('H*')}")

            msg_id, contents = msg.unpack('Ca*')

            lookup = {0 => 'choke', 1 => 'unchoke', 2 => 'interested', 3 => 'not interested',
                      4 => 'have', 5 => 'bitfield', 6 => 'request', 7 => 'piece', 8 => 'cancel',
                      9 => 'port'}
            action = lookup[msg_id]
            if action
              queue.push([action, contents])
            else
              ::KTorrent.log("Unknown data received: #{msg.unpack('H*')}")
            end

            # when '0' # 'choke'
            # when '1' # 'unchoke'
            # when '2' # 'interested'
            # when '3' # 'not interested'
            # when '4' # 'have'
            # when '5' # 'bitfield'
            # when '6' # 'request'
            # when '7' # 'piece'
            # when '8' # 'cancel'
            # when '9' # 'port'
          end
        rescue StandardError => e
          error = e
          ::KTorrent.log("#{ip_port} - socket reader thread error")
        ensure
          queue.push['socket reader thread stopped', error]
          ::KTorrent.log("#{ip_port} - socket reader thread stopped")
        end
      end
    end
    PIPELINING_INTERVAL = 0.05 # secs

    def start_socket_pipelining_thread
      @socket_pipelining_thread = Thread.new do
        begin
          @socket_response_queue = Queue.new
          error = nil
          exit = false
          until exit do
            bytes = @socket_response_queue.pop
            sleep(PIPELINING_INTERVAL)
            until @socket_response_queue.empty?
              bytes += @socket_response_queue.pop
            end
            socket.write(bytes)
          end
        rescue StandardError => e
          error = e
          ::KTorrent.log("#{ip_port} - socket writer thread error")
        ensure
          @socket_response_queue = nil
          queue.push['socket writer thread stopped', error]
          ::KTorrent.log("#{ip_port} - socket writer thread stopped")
        end
      end
    end

    def socket_write(message)
      bytes = [message.size, message].pack('Na*')
      if ["sleep", "run"].include?(@socket_pipelining_thread.status) && !@socket_response_queue.nil?
        @socket_response_queue.push(bytes)
      else
        socket.write(bytes)
      end
    end

    PIECE_CHUNK_SIZE = 2**14

    def start_thread
      # connect

      @thread = Thread.new(ip, port, peer_id) do |ip, port, peer_id|
        begin
          @queue = Queue.new
          @state = State.new { torrent }
          @socket = TCPSocket.new(ip, port)

          # SEND handshake
          error = nil

          socket.write(handshake_encode)

          # receive handshake
          handshake_str_len = socket.read(1)
          raise HandShakeFailed if handshake_str_len.nil?
          rest = socket.read(handshake_str_len.unpack('C').first + 8 + 20 + 20)

          ::KTorrent.log("#{ip_port} - handshake received: #{(handshake_str_len+rest).unpack('H*')}")

          decoded_handshake = handshake_decode(handshake_str_len + rest)

          # exit if info_hash or peer_id not correct
          if decoded_handshake[3] != torrent.properties.info_hash(hex = false) ||
            (peer_id && decoded_handshake[4] != torrent.peers.peer_id(hex = false)) ||
            decoded_handshake[1] != "BitTorrent protocol"

            manager_command_queue.push(['disconnect', "#{ip}:#{port}"])
            Thread.exit
          end
          queue.push(['initial setup'])

          start_socket_reader_thread

          start_socket_pipelining_thread

          pieces_to_request = {} # piece_id => Bool
          part_of_pieces = {} # piece_id => [byte_string] * size

          cancelled_requests = {}

          exit = false
          until exit do
            command = queue.pop
            case command[0]
            when 'initial setup'
              queue.push(["send bitfield"])
            when 'attempt pieces'
              new_pieces_to_attempt = command[1]
              new_pieces_to_attempt.each do |piece_id|
                pieces_to_request[piece_id] = false
              end
            when 'socket reader thread stopped'
              error = command[1]
              if error
                raise error
              end
            when 'exit'
              exit = true
            when /send (.*)/
              case "#{$1}"
              when 'choke' # 0
                state.am_choking = true
                socket_write([0].pack('C'))
              when 'unchoke'
                state.am_choking = false
                socket_write([1].pack('C'))
              when 'interested'
                state.am_interested = true
                socket_write([2].pack('C'))
              when 'not interested'
                state.am_interested = false
                socket_write([3].pack('C'))
              when 'have'
                piece_id = command[1]
                socket_write([4, piece_id].pack('CN'))
              when 'bitfield'
                bitfield_str = torrent.data.have_all.map { |have| have and '1' or '0'}.join('')
                if bitfield_str.size % 8 != 0
                  bitfield_str += '0' * (8 - bitfield_str.size % 8)
                end
                socket_write([5, bitfield_str].pack('CB*'))
              when 'request'
                piece_id, offset, length = command[1]
                socket_write([6, piece_id, offset, length].pack('CNNN'))
              when 'piece'
                piece_id, offset, length = command[1]
                if cancelled_requests.key?([piece_id, offset, length])
                  cancelled_requests.delete([piece_id, offset, length])
                else
                  socket_write([7, piece_id, offset, torrent.data[piece_id].slice(offset, length)].pack('CNNa*'))
                end
              when 'cancel'
                # noop
              when 'port' # 9

              end
            when 'choke' # 0
              state.peer_choking = true
            when 'unchoke'
              state.peer_choking = false

              # send the requests
              pieces_to_request.each do |piece_id, req_sent|
                next if req_sent
                piece_size = torrent.properties.piece_size(piece_id: piece_id)
                chunks = piece_size.to_f / REQUESTED_PIECE_CHUNK_SIZE

                chunks.floor.times do |chunk_id|
                  queue.push(['send request', [piece_id, chunk_id, REQUESTED_PIECE_CHUNK_SIZE]])
                end
                queue.push(['send request', [piece_id, chunks.floor, piece_size % REQUESTED_PIECE_CHUNK_SIZE]]) if chunks.floor != chunks.ceil
              end

            when 'interested'
              state.peer_interested = true
            when 'not interested'
              state.peer_interested = false
            when 'have'
              piece_id = command[1].unpack('N').first
              state.have[piece_id] = true if piece_id < torrent.properties.pieces
              manager_command_queue.push(['retrieve pieces', self]) # Get manager to decide pieces
            when 'bitfield'
              bitfield = command[1].unpack('B*').first
              if (bitfield.size >= torrent.properties.pieces)
                torrent.properties.pieces.times do |n|
                  state.have[n] = bitfield[n] == '1'
                end
              end

              queue.push(['send interested']) # Will do for now

              manager_command_queue.push(['retrieve pieces', self]) # Get manager to decide pieces
            when 'request'
              piece_id, offset, length = command[1].unpack('NNN')
              queue.push(['send piece', [piece_id, offset, length]])
            when 'piece'
              piece_id, offset, data = command[1].unpack('NNa*')
              piece_size = torrent.properties.piece_size(piece_id: piece_id)

              part_of_pieces[piece_id] ||= [nil] * piece_size
              part_of_pieces[piece_id][offset...(offset + data.size)] = data.chars # save to pieces

              if part_of_pieces[piece_id].all? { |byte| !byte.nil? } # if entire piece is done, save
                entire_piece = part_of_pieces[piece_id].join('')
                part_of_pieces.delete(piece_id)

                expected_hash = torrent.properties.hashes[piece_id]
                received_piece_hash = Digest::SHA1.hexdigest(entire_piece).downcase

                if entire_piece.size != piece_size || expected_hash != received_piece_hash

                  queue.push(["abandoned piece", [self, piece_id]])
                  ::KTorrent.log("Received piece #{piece_id} is hashfail, #{received_piece_hash} instead of #{expected_hash}, will try again")
                  raise "Combined piece not correct size" if entire_piece.size != piece_size
                end
                manager_command_queue.push(["received piece", [self, piece_id, entire_piece]])
              end

            when 'cancel'
              piece_id, offset, length = command[1].unpack('NNN')

              cancelled_requests[[piece_id, offset, length]] = true
            when 'port' # 9
            else

            end
          end


          # send bitfield

          # receive bitfield or things,

          # loop do:
          # queue to main thread "ask for pieces" => receive x pieces (like 5)
          # once all receive, send 'save pieces with pieces as payload' to main queue
          # main verifies and 'saves', send to client queue 'broadcast have', client ask for pieces repeat
          # end state: no more pieces


        rescue StandardError => e
          error = e
          raise
        ensure
          # atexit: remove from @connections_out and add to @failed_peers
          ::KTorrent.log("#{ip_port} - worker thread stopped")
          manager_command_queue.push(['disconnect', [ip_port, self, error]])
        end
      end
    end


    def handshake_encode
      pstr = "BitTorrent protocol"
      pstrlen = [pstr.size].pack('C')
      reserved = ([0] * 8).pack('C*')
      info_hash = torrent.properties.info_hash(hex = false)
      peer_id = manager.peer_id(hex = false)

      [pstrlen, pstr, reserved, info_hash, peer_id].join('')
    end

    def handshake_decode(str)
      pstrlen = str.unpack('C').first
      str.unpack("C a#{pstrlen} a8 a20 a20") # [pstrlen, pstr, reserved, info_hash, peer_id]
    end
  end
end
