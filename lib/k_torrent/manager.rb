module KTorrent
  class Manager
    attr_accessor :torrents

    def load_torrent_from_file(path)
      return nil unless File.readable?(path)
      contents = File.open(path, 'rb') { |file| file.read }
      metadata = ::KTorrent::BEncoding.decode(contents)

      ::KTorrent::Torrent.new(manager: self, metadata: metadata)
    end

    def self.manager
      @manager ||= self.new
    end

    private

    def initialize
      @torrents = []

      FileUtils.mkdir_p(::KTorrent.download_dir)
    end
  end
end
