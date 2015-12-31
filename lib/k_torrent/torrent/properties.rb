module KTorrent
  class Torrent::Properties
    extend Forwardable
    attr_reader :info, :original
    attr_accessor :trackers
    def_delegator :@trackers, :first, :primary_tracker

    # BEncoded Metadata is either
    # Multiple Files:
    # {'announce' => '',
    #  'info' => {'files' => [['length' => 'xxxx', 'path' => ['path', 'to', 'file.txt']]],
    #             'name' => 'suggested_folder_name',
    #             'piece length' => '2^x',
    #             'pieces' => '0123456789ABCDEF0123' * x}}
    # Single File:
    # {'announce' => '',
    #  'info' => {'length' => 'xxxx',
    #             'name' => 'suggested_file_name',
    #             'piece length' => '2^x',
    #             'pieces' => '0123456789ABCDEF0123' * x}}

    def initialize(metadata:)
      @other_fields = metadata.dup.tap { |h| h.delete('info') }
      @info = metadata['info']
      @trackers = []
      @trackers << metadata['announce'] if metadata.key?('announce')
      @trackers += metadata['announce-list'].flatten if metadata.key?('announce-list')

      raise 'Mismatching piece and total size' unless (total_size.to_f / piece_size).ceil == pieces
    end

    def multiple_files?
      @multiple_files ||= info.key?('files')
    end

    def info_hash(hex = true)
      @info_hash ||= Digest::SHA1.hexdigest(BEncoding.encode(info))
      hex and @info_hash or [@info_hash].pack('H*')
    end

    def other_trackers
      @trackers[1..-1]
    end

    def total_size
      @total_size ||= multiple_files? and info['files'].map { |o| o['length'].to_i }.inject(0, :+) or info['length'].to_i
    end

    def piece_size
      info['piece length'].to_i
    end

    def pieces
      info['pieces'].size / 20
    end

    def to_metadata
      {'announce' => primary_tracker, 'announce_list' => other_trackers, 'info' => info}
    end
  end
end
