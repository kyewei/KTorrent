module KTorrent
  class Torrent::DataManager
    ChunkSize = 134217728 # 128 MiB, or 128 x 1024^2

    def initialize(torrent:)
      @torrent = torrent
      @path = ::KTorrent.download_dir + torrent.properties.info_hash
      FileUtils.mkdir_p(@path)
    end

  end
end
