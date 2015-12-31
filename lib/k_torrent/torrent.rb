module KTorrent
  class Torrent
    attr_reader :manager, :raw_metadata, :properties, :client, :trackers, :peers

    def initialize(manager:, metadata:)
      @manager = manager
      @properties = ::KTorrent::Torrent::Properties.new(metadata: metadata)

      # TODO: Lookup @info.info_hash in persistent store
      @data = DataManager.new(torrent: self)

      @trackers = TrackerManager.new(torrent: self)

      @peers = PeerManager.new(torrent: self)
    end
  end
end

require 'k_torrent/torrent/properties'
require 'k_torrent/torrent/tracker_manager'
require 'k_torrent/torrent/peer_manager'
require 'k_torrent/torrent/data_manager'
