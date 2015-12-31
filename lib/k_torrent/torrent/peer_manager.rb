module KTorrent
  class Torrent::PeerManager
    DEFAULT_PORT = 22096

    PeerState = Struct.new(:am_choking, :am_interested, :peer_choking, :peer_interested) do
      def initialize(*args)
        args = [true, false, true, false] if args == []
        super(*args)
      end
    end

    def initialize(torrent:)
      @torrent = torrent
      @connections_out = {}
      # @server = nil
      # @server_thread = nil
      # @connections_in = Set.new
    end

    # def start_tcp_server
    #   unless @server
    #     @server_connections = []
    #     @server = TCPServer.new('127.0.0.1', DEFAULT_PORT)
    #     @server_thread = Thread.start do
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

    def handshake_encode
      pstr = "BitTorrent protocol"
      pstrlen = [pstr.size].pack('C')
      reserved = ([0] * 8).pack('C*')
      info_hash = ["07eb4e5900f48102c5ff149e995c9590101dc7a3"].pack('H*')#@torrent.properties.info_hash(hex = false)
      peer_id = peer_id(hex = false)

      [pstrlen, pstr, reserved, info_hash, peer_id].join('')
    end

    def handshake_decode(str)
      pstrlen = str.unpack('C').first
      str.unpack("C a#{pstrlen} a8 a20 a20") # [pstrlen, pstr, reserved, info_hash, peer_id]
    end

    def peer_id(hex = true)
      @client_id ||= '-KW2221-' + ("%012d" % 1451194202)
      hex and @client_id.unpack('H*').first or @client_id
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
