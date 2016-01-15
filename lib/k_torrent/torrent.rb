module KTorrent
  class Torrent
    attr_reader :manager, :properties, :data, :trackers, :peers

    def initialize(manager:, metadata:)
      @manager = manager
      @properties = ::KTorrent::Torrent::Properties.new(metadata: metadata)

      # TODO: Lookup @info.info_hash in persistent store
      @data = DataManager.new(torrent: self)

      @trackers = TrackerManager.new(torrent: self)

      @peers = PeerManager.new(torrent: self)

      @display_thread = nil
    end

    def start
      result = true
      result &&= @data.service_start(restart: false)
      result &&= @trackers.service_start(restart: false)
      result &&= @peers.service_start(restart: false)

      @display_thread = Thread.new do
        loop do
          system "clear" or system "cls" # A bit sketchy for clearing the screen. TODO: replace with better CLI display library

          puts "Torrent state: #{data.have_count}/#{properties.pieces}"
          puts "Tracker state: #{trackers.successful_trackers.size}/#{trackers.status.size}"
          puts "Peers: #{peers.connections_out.size} active, #{peers.failed_peers.size} failed, #{peers.tracker_provided_peers.size} available"

          puts "\n"

          puts "Pieces: #-have *-downloading .-nope"
          have_display = data.have_all.map { |have_piece| have_piece ? '#' : '.' }
          peers.workers_pending_pieces.keys.each { |piece_id| have_display[piece_id] = '*'}
          puts "#{have_display.join('')}"

          puts "\n"

          # puts "Most recent messages:"
          # puts "Log:"
          # ::KTorrent.previous_log.reverse.each do |(time), msg|
          #   puts "#{time.to_s}: #{msg}"
          # end
          # puts "Debug:"
          # ::KTorrent.previous_debug.reverse.each do |(time), msg|
          #   puts "#{time.to_s}: #{msg}"
          # end

          sleep 1
        end
      end

      result
    end

    def stop
      result = true
      @display_thread.kill
      result &&= @data.service_stop
      result &&= @trackers.service_stop
      result &&= @peers.service_stop
      result
    end
  end
end

require 'k_torrent/torrent/properties'
require 'k_torrent/torrent/tracker_manager'
require 'k_torrent/torrent/peer_manager'
require 'k_torrent/torrent/peer_worker'
require 'k_torrent/torrent/data_manager'
